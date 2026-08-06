import Foundation
import CockpitHostCore

public final class SecurityScopedProjectRoot: ProjectRootAccessToken, @unchecked Sendable {
    private let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public struct SecurityScopedProjectRootResolver: ProjectRootResolving {
    public init() {}

    public func resolve(bookmark: Data) throws -> ResolvedProjectRoot {
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let canonicalURL = resolvedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let token = SecurityScopedProjectRoot(url: canonicalURL)
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
