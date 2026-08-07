import Foundation
import Testing
@testable import CockpitLocalTransport

@Test func hostDataPlaneModuleBoundaryKeepsWorkspaceOutOfLocalTransport() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let package = try String(
        contentsOf: repository.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let localTransportDeclaration = try #require(
        package.range(of: ".target(\n            name: \"CockpitLocalTransport\"")
    )
    let declarationTail = package[localTransportDeclaration.lowerBound...]
    let nextTarget = try #require(declarationTail.range(of: #"        .target("#, options: [], range: declarationTail.index(after: declarationTail.startIndex)..<declarationTail.endIndex))
    let declaration = String(declarationTail[..<nextTarget.lowerBound])
    #expect(!declaration.contains("CockpitWorkspace"))
    #expect(declaration.contains(#".linkedFramework("Security")"#))
    #expect(declaration.contains(#".linkedFramework("CryptoKit")"#))

    let sources = repository.appendingPathComponent(
        "Sources/CockpitLocalTransport",
        isDirectory: true
    )
    let files = try FileManager.default.contentsOfDirectory(
        at: sources,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    let combined = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    #expect(!combined.contains("import CockpitWorkspace"))
    #expect(!combined.contains("DocumentCommitRecoveryRequiredError"))
}

@Test func hostDataPlaneModuleBoundaryHasExactApprovedTargetGraph() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let package = try String(
        contentsOf: repository.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let testStart = try #require(
        package.range(of: ".testTarget(\n            name: \"CockpitLocalTransportTests\"")
    )
    let tail = package[testStart.lowerBound...]
    let nextTarget = try #require(
        tail.range(
            of: #"        .testTarget("#,
            range: tail.index(after: tail.startIndex)..<tail.endIndex
        )
    )
    let declaration = String(tail[..<nextTarget.lowerBound])
    #expect(declaration.contains(#""CockpitClientCore""#))
    #expect(declaration.contains(#""CockpitLocalTransport""#))
    #expect(!declaration.contains("CockpitWorkspace"))
}

@Test func hostDataPlaneModuleBoundaryGuardsEverySequenceTransitionBeforeOverflow() {
    #expect(hostDataPlaneAdvanceSequence(UInt64.max - 1) == .value(UInt64.max))
    #expect(hostDataPlaneAdvanceSequence(UInt64.max) == .overflow)
}

@Test func hostDataPlaneModuleBoundaryKeepsSIGTERMCompositionInFrozenOrder() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let main = try String(
        contentsOf: repository.appendingPathComponent("Applications/CockpitHost/main.swift"),
        encoding: .utf8
    )
    let coordinator = try #require(main.range(of: "HostShutdownCoordinator("))
    let invalidateListener = try #require(
        main.range(of: "invalidateListener: { listener.invalidate() }")
    )
    let stopRunLoop = try #require(
        main.range(of: "stopProcess: { CFRunLoopStop(mainRunLoop) }")
    )
    #expect(coordinator.lowerBound < invalidateListener.lowerBound)
    #expect(invalidateListener.lowerBound < stopRunLoop.lowerBound)
}
