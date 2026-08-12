import Foundation
import CockpitHostCore

public final class SecurityScopedProjectRoot: ProjectRootAccessToken, @unchecked Sendable {
    private let url: URL
    private let boundary: any SecurityScopedBookmarkAccessing

    init(url: URL, boundary: any SecurityScopedBookmarkAccessing) throws {
        guard boundary.startAccessing(url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        self.url = url
        self.boundary = boundary
    }

    deinit {
        boundary.stopAccessing(url)
    }
}

struct SecurityScopedBookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkAccessing: Sendable {
    func createBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions
    ) throws -> Data
    func resolve(
        bookmark: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> SecurityScopedBookmarkResolution
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

private struct FoundationSecurityScopedBookmarkAccess: SecurityScopedBookmarkAccessing {
    func createBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions
    ) throws -> Data {
        try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(
        bookmark: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> SecurityScopedBookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return SecurityScopedBookmarkResolution(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

public struct SecurityScopedExecutableBookmarkResolver: Sendable {
    private let boundary: any SecurityScopedBookmarkAccessing

    public init() {
        boundary = FoundationSecurityScopedBookmarkAccess()
    }

    init(boundary: any SecurityScopedBookmarkAccessing) {
        self.boundary = boundary
    }

    public func resolve(bookmark: Data) throws -> String {
        let resolution = try boundary.resolve(
            bookmark: bookmark,
            options: [.withSecurityScope, .withoutImplicitStartAccessing]
        )
        guard !resolution.isStale else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard boundary.startAccessing(resolution.url) else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { boundary.stopAccessing(resolution.url) }
        return resolution.url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

public struct SecurityScopedProjectRootResolver: ProjectRootResolving {
    private let boundary: any SecurityScopedBookmarkAccessing

    public init() {
        boundary = FoundationSecurityScopedBookmarkAccess()
    }

    init(boundary: any SecurityScopedBookmarkAccessing) {
        self.boundary = boundary
    }

    public func importBookmark(
        _ bookmark: Data
    ) throws -> (persistentBookmark: Data, root: ResolvedProjectRoot) {
        let clientResolution = try boundary.resolve(
            bookmark: bookmark,
            options: [.withoutUI]
        )
        guard !clientResolution.isStale else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let persistentBookmark = try boundary.createBookmark(
            for: clientResolution.url,
            options: .withSecurityScope
        )
        return (
            persistentBookmark,
            try resolve(bookmark: persistentBookmark)
        )
    }

    public func resolve(bookmark: Data) throws -> ResolvedProjectRoot {
        let resolution = try boundary.resolve(
            bookmark: bookmark,
            options: [.withSecurityScope, .withoutImplicitStartAccessing]
        )
        guard !resolution.isStale else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let token = try SecurityScopedProjectRoot(url: resolution.url, boundary: boundary)
        let canonicalURL = resolution.url
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let values = try canonicalURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey,
            .fileResourceIdentifierKey,
        ])
        guard values.isDirectory == true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard let volumeIdentifier = values.volumeIdentifier,
              let fileIdentifier = values.fileResourceIdentifier else {
            throw CocoaError(.fileReadUnknown)
        }
        let identity = "volume:\(String(describing: volumeIdentifier))/file:\(String(describing: fileIdentifier))"
        guard !identity.isEmpty else {
            throw CocoaError(.fileReadUnknown)
        }

        return ResolvedProjectRoot(
            canonicalAbsolutePath: canonicalURL.path,
            canonicalRootIdentity: identity,
            gitCommonDirectory: try gitCommonDirectory(for: canonicalURL),
            accessToken: token
        )
    }

    private func gitCommonDirectory(for rootURL: URL) throws -> String? {
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path, "rev-parse", "--git-common-dir"]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let url = value.hasPrefix("/")
            ? URL(fileURLWithPath: value, isDirectory: true)
            : rootURL.appendingPathComponent(value, isDirectory: true)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
