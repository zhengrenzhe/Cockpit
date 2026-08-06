import Foundation
import Testing
import CockpitPersistence

@Test func productionStorageLocationsUseTheFixedApplicationSupportPaths() throws {
    let locations = try CockpitStorageLocations.production()
    let expectedApplicationSupport = try #require(
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    )
    .appendingPathComponent("dev.cockpit.Cockpit", isDirectory: true)

    #expect(locations.applicationSupport == expectedApplicationSupport)
    #expect(locations.workspaceDatabase == expectedApplicationSupport.appendingPathComponent("workspace.sqlite"))
    #expect(locations.terminalDatabase == expectedApplicationSupport.appendingPathComponent("terminal.sqlite"))
    #expect(locations.documentRecoveryRoot == expectedApplicationSupport.appendingPathComponent("DocumentRecovery", isDirectory: true))
    #expect(locations.terminalArchiveRoot == expectedApplicationSupport.appendingPathComponent("TerminalArchives", isDirectory: true))
}

@Test func storageLocationsCanBeCreatedUnderAnInjectedApplicationSupportRoot() throws {
    try withTemporaryStorageRoot { root in
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let locations = try CockpitStorageLocations.under(applicationSupport)

        #expect(locations.applicationSupport == applicationSupport)
        #expect(locations.workspaceDatabase == applicationSupport.appendingPathComponent("workspace.sqlite"))
        #expect(locations.terminalDatabase == applicationSupport.appendingPathComponent("terminal.sqlite"))
        #expect(locations.documentRecoveryRoot == applicationSupport.appendingPathComponent("DocumentRecovery", isDirectory: true))
        #expect(locations.terminalArchiveRoot == applicationSupport.appendingPathComponent("TerminalArchives", isDirectory: true))
    }
}

@Test func storageLocationsUseOwnerOnlyModesForDirectoriesAndDatabases() throws {
    try withTemporaryStorageRoot { root in
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let locations = try CockpitStorageLocations.under(applicationSupport)

        for directory in [
            locations.applicationSupport,
            locations.documentRecoveryRoot,
            locations.terminalArchiveRoot,
        ] {
            #expect(try permissionBits(of: directory) == 0o700)
        }
        for database in [locations.workspaceDatabase, locations.terminalDatabase] {
            #expect(try permissionBits(of: database) == 0o600)
        }
    }
}

@Test func storageLocationsRejectAnApplicationSupportRootThatIsASymbolicLink() throws {
    try withTemporaryStorageRoot { root in
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try CockpitStorageLocations.under(link)
        }
    }
}

private func permissionBits(of url: URL) throws -> Int {
    try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    )
}

private func withTemporaryStorageRoot(
    _ body: (URL) throws -> Void
) throws {
    let root = URL(
        fileURLWithPath: "/private/tmp/cockpit-storage-locations-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
