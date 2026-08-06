import Foundation
import SQLite3

public struct CockpitStorageLocations: Sendable {
    public let applicationSupport: URL
    public let workspaceDatabase: URL
    public let terminalDatabase: URL
    public let documentRecoveryRoot: URL
    public let terminalArchiveRoot: URL

    public static func production(
        fileManager: FileManager = .default
    ) throws -> CockpitStorageLocations {
        let applicationSupport = try requireApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("dev.cockpit.Cockpit", isDirectory: true)
        return try under(applicationSupport, fileManager: fileManager)
    }

    public static func under(
        _ applicationSupport: URL,
        fileManager: FileManager = .default
    ) throws -> CockpitStorageLocations {
        let workspaceDatabase = applicationSupport.appendingPathComponent("workspace.sqlite")
        let terminalDatabase = applicationSupport.appendingPathComponent("terminal.sqlite")
        let documentRecoveryRoot = applicationSupport.appendingPathComponent(
            "DocumentRecovery",
            isDirectory: true
        )
        let terminalArchiveRoot = applicationSupport.appendingPathComponent(
            "TerminalArchives",
            isDirectory: true
        )

        try ensureOwnerOnlyDirectory(applicationSupport, fileManager: fileManager)
        try ensureOwnerOnlyDirectory(documentRecoveryRoot, fileManager: fileManager)
        try ensureOwnerOnlyDirectory(terminalArchiveRoot, fileManager: fileManager)
        try ensureOwnerOnlyFile(workspaceDatabase, fileManager: fileManager)
        try ensureOwnerOnlyFile(terminalDatabase, fileManager: fileManager)

        return CockpitStorageLocations(
            applicationSupport: applicationSupport,
            workspaceDatabase: workspaceDatabase,
            terminalDatabase: terminalDatabase,
            documentRecoveryRoot: documentRecoveryRoot,
            terminalArchiveRoot: terminalArchiveRoot
        )
    }

    private static func requireApplicationSupportDirectory(
        fileManager: FileManager
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport
    }

    private static func ensureOwnerOnlyDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func ensureOwnerOnlyFile(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
