import Darwin
import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Test func secureRuntimeRejectsSymlinkComponentsWithoutTouchingTarget() throws {
    try withTemporaryRuntimeRoot { root in
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: SecureRuntimeFailure.self) {
            try SecureRuntimeDirectory.prepare(
                at: link.appendingPathComponent("terminal", isDirectory: true).path
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("terminal").path
        ))
    }
}

@Test func secureRuntimeRejectsExistingComponentOwnedByAnotherUID() throws {
    try withTemporaryRuntimeRoot { root in
        let differentUserID = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1

        #expect(throws: SecureRuntimeFailure.self) {
            try SecureRuntimeDirectory.prepare(
                at: root.appendingPathComponent("terminal", isDirectory: true).path,
                effectiveUserID: differentUserID
            )
        }
    }
}

@Test func secureRuntimeForcesFinalDirectoryModeToOwnerOnly() throws {
    try withTemporaryRuntimeRoot { root in
        let runtime = root.appendingPathComponent("terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runtime.path
        )

        try SecureRuntimeDirectory.prepare(at: runtime.path)

        let attributes = try FileManager.default.attributesOfItem(atPath: runtime.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }
}

@Test func runtimeDescriptorReplacementIsAtomicAndOwnerOnly() throws {
    try withTemporaryRuntimeRoot { root in
        let runtime = root.appendingPathComponent("terminal", isDirectory: true)
        let sessionID = TerminalSessionID(
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000041"))
        )
        let workerID = WorkerInstanceID(
            try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))
        )
        let first = KeeperRuntimeDescriptor(
            sessionID: sessionID,
            workerInstanceID: workerID,
            processID: 101,
            processGroupID: 101
        )
        let second = KeeperRuntimeDescriptor(
            sessionID: sessionID,
            workerInstanceID: workerID,
            processID: 202,
            processGroupID: 202
        )

        try SecureRuntimeDirectory.write(first, at: runtime.path)
        let descriptorURL = runtime.appendingPathComponent(
            "\(sessionID).\(workerID).json"
        )
        let oldFile = try FileHandle(forReadingFrom: descriptorURL)

        try SecureRuntimeDirectory.write(second, at: runtime.path)

        let oldData = try #require(try oldFile.readToEnd())
        try oldFile.close()
        let currentData = try Data(contentsOf: descriptorURL)
        #expect(try JSONDecoder().decode(KeeperRuntimeDescriptor.self, from: oldData) == first)
        #expect(try JSONDecoder().decode(KeeperRuntimeDescriptor.self, from: currentData) == second)
        let attributes = try FileManager.default.attributesOfItem(atPath: descriptorURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: runtime.path)
                == [descriptorURL.lastPathComponent]
        )
    }
}

private func withTemporaryRuntimeRoot(
    _ body: (URL) throws -> Void
) throws {
    let root = URL(
        fileURLWithPath: "/private/tmp/cockpit-secure-runtime-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
