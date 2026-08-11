import Foundation
import Security
import Testing
@testable import CockpitLocalTransport
@testable import CockpitTerminalCore

@Suite("InstallationMasterKeyStoreTests")
struct InstallationMasterKeyStoreTests {
    @Test func explicitKeychainIsolatedFromDefaultAndPersistsGeneratedKey() async throws {
        let service = "dev.cockpit.tests.explicit-master-key.\(UUID().uuidString)"
        let account = "explicit-master-key.\(UUID().uuidString)"
        let defaultFixture = InstallationMasterKeyFixture(service: service, account: account)
        defer { defaultFixture.cleanup() }
        let defaultKey = Data(repeating: 0x11, count: 32)
        try defaultFixture.saveRaw(defaultKey)

        let explicitFixture = try ExplicitInstallationKeychainFixture()
        defer { explicitFixture.cleanup() }
        let generatedKey = Data(repeating: 0xA5, count: 32)
        let firstStore = InstallationMasterKeyStore(
            service: service,
            account: account,
            randomBytes: FixedMasterKeyRandomBytes(bytes: Array(generatedKey)),
            explicitKeychainPath: explicitFixture.path
        )

        let first = try await firstStore.masterKey()
        let rebuilt = try await InstallationMasterKeyStore(
            service: service,
            account: account,
            randomBytes: FixedMasterKeyRandomBytes(bytes: Array(repeating: 0x5A, count: 32)),
            explicitKeychainPath: explicitFixture.path
        ).masterKey()

        #expect(first == generatedKey)
        #expect(rebuilt == generatedKey)
        #expect(try explicitFixture.load(service: service, account: account) == generatedKey)
        #expect(try defaultFixture.loadItem().data == defaultKey)
    }

    @Test func createsReadsAndPersistsAnOwnerOnlyInstallationKey() async throws {
        let fixture = InstallationMasterKeyFixture()
        defer { fixture.cleanup() }
        let firstStore = InstallationMasterKeyStore(
            service: fixture.service,
            account: fixture.account
        )

        let first = try await firstStore.masterKey()
        let repeated = try await firstStore.masterKey()
        let rebuilt = try await InstallationMasterKeyStore(
            service: fixture.service,
            account: fixture.account
        ).masterKey()

        #expect(first.count == 32)
        #expect(repeated == first)
        #expect(rebuilt == first)
        let persisted = try fixture.loadItem()
        #expect(persisted.data == first)
        #expect(persisted.accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    @Test func constantsAndInvalidPersistedLengthFailClosedWithoutOverwrite() async throws {
        #expect(InstallationMasterKeyStore.productionService == "dev.cockpit.terminal.master-key")
        #expect(InstallationMasterKeyStore.productionAccount == "installation-master-key-v1")

        let fixture = InstallationMasterKeyFixture()
        defer { fixture.cleanup() }
        let invalid = Data(repeating: 0xC3, count: 31)
        try fixture.saveRaw(invalid)
        let store = InstallationMasterKeyStore(service: fixture.service, account: fixture.account)

        await #expect(throws: InstallationMasterKeyStoreError.invalidPersistedMasterKey) {
            _ = try await store.masterKey()
        }
        #expect(try fixture.loadItem().data == invalid)
    }
}

private final class InstallationMasterKeyFixture: @unchecked Sendable {
    let service: String
    let account: String

    init(
        service: String = "dev.cockpit.tests.terminal-master-key.\(UUID().uuidString)",
        account: String = "installation-master-key.\(UUID().uuidString)"
    ) {
        self.service = service
        self.account = account
    }

    func cleanup() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    func saveRaw(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw InstallationMasterKeyFixtureError.keychain(status) }
    }

    func loadItem() throws -> (data: Data, accessibility: String) {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw InstallationMasterKeyFixtureError.keychain(status)
        }

        var accessibilityQuery = baseQuery()
        accessibilityQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        accessibilityQuery[kSecReturnData as String] = true
        accessibilityQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var matchingResult: CFTypeRef?
        let matchingStatus = SecItemCopyMatching(
            accessibilityQuery as CFDictionary,
            &matchingResult
        )
        guard matchingStatus == errSecSuccess, matchingResult as? Data == data else {
            throw InstallationMasterKeyFixtureError.keychain(matchingStatus)
        }
        return (data, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private struct FixedMasterKeyRandomBytes: TerminalSecurityRandomBytes {
    let bytes: [UInt8]

    func bytes(count: Int) throws -> [UInt8] {
        Array(bytes.prefix(count))
    }
}

private final class ExplicitInstallationKeychainFixture: @unchecked Sendable {
    let root: URL
    let path: String
    private let password = "cockpit-explicit-keychain"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-explicit-keychain.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        path = root.appendingPathComponent("fixture.keychain-db").path
        try Self.runSecurity(["create-keychain", "-p", password, path])
        try Self.runSecurity(["unlock-keychain", "-p", password, path])
        try Self.runSecurity(["set-keychain-settings", "-t", "21600", path])
    }

    func load(service: String, account: String) throws -> Data {
        var keychain: SecKeychain?
        let openStatus = SecKeychainOpen(path, &keychain)
        guard openStatus == errSecSuccess, let keychain else {
            throw InstallationMasterKeyFixtureError.keychain(openStatus)
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
            kSecMatchSearchList as String: [keychain],
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw InstallationMasterKeyFixtureError.keychain(status)
        }
        return data
    }

    func cleanup() {
        try? Self.runSecurity(["delete-keychain", path])
        try? FileManager.default.removeItem(at: root)
    }

    private static func runSecurity(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw InstallationMasterKeyFixtureError.securityProcess(process.terminationStatus)
        }
    }
}

private enum InstallationMasterKeyFixtureError: Error {
    case keychain(OSStatus)
    case securityProcess(Int32)
}
