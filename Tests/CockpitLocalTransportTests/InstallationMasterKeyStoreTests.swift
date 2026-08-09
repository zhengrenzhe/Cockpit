import Foundation
import Security
import Testing
@testable import CockpitLocalTransport
@testable import CockpitTerminalCore

@Suite("InstallationMasterKeyStoreTests")
struct InstallationMasterKeyStoreTests {
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
    let service = "dev.cockpit.tests.terminal-master-key.\(UUID().uuidString)"
    let account = "installation-master-key.\(UUID().uuidString)"

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

private enum InstallationMasterKeyFixtureError: Error {
    case keychain(OSStatus)
}
