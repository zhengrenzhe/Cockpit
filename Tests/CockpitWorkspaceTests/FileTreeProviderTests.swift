import Foundation
import Testing
import CockpitClientCore
import CockpitHostCore
import CockpitTypes
@testable import CockpitWorkspace

@Test func rootExpansionReadsOnlyRootAndSortsDirectoriesBeforeLeaves() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        .root: try [
            entry("zeta.txt", .file),
            entry("Beta", .directory),
            entry("alpha-link", .symbolicLink),
            entry("alpha", .directory),
            entry("Alpha.txt", .file),
        ],
        .relative(try RelativePath("alpha")): try [entry("alpha/nested.txt", .file)],
    ])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    let snapshot = try await provider.children(
        environmentID: environmentID,
        at: .root,
        generation: 41
    )

    #expect(snapshot.environmentID == environmentID)
    #expect(snapshot.directory == .root)
    #expect(snapshot.generation == 41)
    #expect(snapshot.revision == 0)
    #expect(snapshot.children.map(\.identity.path.string) == [
        "alpha", "Beta", "alpha-link", "Alpha.txt", "zeta.txt",
    ])
    #expect(snapshot.children.map(\.kind) == [
        .directory, .directory, .symbolicLink, .file, .file,
    ])
    #expect(await fileSystem.recordedReads() == [.root])
}

@Test func relativeExpansionReadsExactlyTheRequestedDirectory() async throws {
    let environmentID = EnvironmentID()
    let sources = WorkspaceDirectory.relative(try RelativePath("Sources"))
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        sources: try [entry("Sources/main.swift", .file)],
    ])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    let snapshot = try await provider.children(
        environmentID: environmentID,
        at: sources,
        generation: 7
    )

    #expect(snapshot.children.map(\.identity.path.string) == ["Sources/main.swift"])
    #expect(await fileSystem.recordedReads() == [sources])
}

@Test func symbolicLinkDirectoryIsALeafAndTraversalIsRejectedWithoutScanningTarget() async throws {
    let environmentID = EnvironmentID()
    let link = WorkspaceDirectory.relative(try RelativePath("linked-directory"))
    let fileSystem = RecordingFileTreeFileSystem(
        entries: [.root: try [entry("linked-directory", .symbolicLink)]],
        errors: [link: .symbolicLinkTraversal]
    )
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    let root = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    #expect(root.children == [try treeEntry(environmentID, "linked-directory", .symbolicLink)])
    await #expect(throws: FileTreeProviderError.symbolicLinkTraversal) {
        _ = try await provider.children(environmentID: environmentID, at: link, generation: 2)
    }
    #expect(await fileSystem.recordedReads() == [.root, link])
}

@Test func providerRejectsEnvironmentMismatchAndZeroGeneration() async throws {
    let environmentID = EnvironmentID()
    let otherEnvironmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [.root: []])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    await #expect(throws: FileTreeProviderError.environmentMismatch) {
        _ = try await provider.children(environmentID: otherEnvironmentID, at: .root, generation: 1)
    }
    await #expect(throws: FileTreeProviderError.zeroGeneration) {
        _ = try await provider.children(environmentID: environmentID, at: .root, generation: 0)
    }
    #expect(await fileSystem.recordedReads().isEmpty)
}

@Test func snapshotGenerationIsRejectedAfterRepeatedContextSelection() async throws {
    let projectID = ProjectID()
    let environmentID = EnvironmentID()
    let context = try ResolvedWorkspaceContext(
        validating: .project(projectID),
        projectID: projectID,
        conversationID: nil,
        environmentID: environmentID,
        workspaceRootIdentity: "root"
    )
    let controller = ActiveContextController()
    let selected = await controller.select(context)
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: RecordingFileTreeFileSystem(entries: [.root: []])
    )
    let snapshot = try await provider.children(
        environmentID: environmentID,
        at: .root,
        generation: selected.generation
    )

    _ = await controller.select(context)

    #expect(snapshot.generation == 1)
    #expect(await controller.accepts(generation: snapshot.generation) == false)
}

@Test func duplicateEnvironmentRegistrationKeepsTheSameProviderIdentity() async throws {
    let environmentID = EnvironmentID()
    let firstDirectory = try TemporaryDirectory()
    let secondDirectory = try TemporaryDirectory()
    defer {
        firstDirectory.remove()
        secondDirectory.remove()
    }
    let registry = WorkspaceKernelRegistry()
    await registry.register(
        environmentID: environmentID,
        root: resolvedRoot(path: firstDirectory.url.path, identity: "first")
    )
    let first = try #require(await registry.kernel(for: environmentID))

    await registry.register(
        environmentID: environmentID,
        root: resolvedRoot(path: secondDirectory.url.path, identity: "second")
    )
    let second = try #require(await registry.kernel(for: environmentID))

    #expect(first === second)
    #expect(first.fileTreeProvider === second.fileTreeProvider)
    #expect(first.root.canonicalRootIdentity == "first")
}

func entry(_ path: String, _ kind: FileTreeEntryKind) throws -> FileSystemEntryRecord {
    FileSystemEntryRecord(relativePath: try RelativePath(path), kind: kind)
}

func treeEntry(
    _ environmentID: EnvironmentID,
    _ path: String,
    _ kind: FileTreeEntryKind
) throws -> FileTreeEntry {
    FileTreeEntry(
        identity: FileTreeEntryIdentity(
            environmentID: environmentID,
            path: try RelativePath(path)
        ),
        kind: kind
    )
}

actor RecordingFileTreeFileSystem: FileTreeFileSystem {
    private var entries: [WorkspaceDirectory: [FileSystemEntryRecord]]
    private var errors: [WorkspaceDirectory: FileTreeProviderError]
    private var reads: [WorkspaceDirectory] = []

    init(
        entries: [WorkspaceDirectory: [FileSystemEntryRecord]],
        errors: [WorkspaceDirectory: FileTreeProviderError] = [:]
    ) {
        self.entries = entries
        self.errors = errors
    }

    func directChildren(
        rootURL: URL,
        directory: WorkspaceDirectory
    ) async throws -> [FileSystemEntryRecord] {
        reads.append(directory)
        if let error = errors[directory] {
            throw error
        }
        return entries[directory, default: []]
    }

    func setEntries(_ newEntries: [FileSystemEntryRecord], for directory: WorkspaceDirectory) {
        entries[directory] = newEntries
    }

    func recordedReads() -> [WorkspaceDirectory] {
        reads
    }

    func clearReads() {
        reads.removeAll()
    }
}

private final class TestProjectRootAccessToken: ProjectRootAccessToken, @unchecked Sendable {}

private func resolvedRoot(path: String, identity: String) -> ResolvedProjectRoot {
    ResolvedProjectRoot(
        canonicalAbsolutePath: path,
        canonicalRootIdentity: identity,
        gitCommonDirectory: nil,
        accessToken: TestProjectRootAccessToken()
    )
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
