import Foundation
import Security
import Testing
import CockpitTypes
@testable import CockpitLocalTransport

@Test func clientIdentityPersistsDeviceAndMainWindowAcrossStoresButNotClientInstance() async throws {
    let fixture = try ClientIdentityFixture()
    defer { fixture.cleanup() }

    let firstStore = ClientIdentityStore(
        keychain: SecurityClientIdentityKeychain(),
        preferences: UserDefaultsClientIdentityPreferences(userDefaults: fixture.defaults),
        keychainService: fixture.service,
        keychainAccount: fixture.account,
        mainWindowPreferencesKey: fixture.preferencesKey
    )
    let first = try await firstStore.identity()
    let repeated = try await firstStore.identity()
    let rebuiltStore = ClientIdentityStore(
        keychain: SecurityClientIdentityKeychain(),
        preferences: UserDefaultsClientIdentityPreferences(userDefaults: fixture.defaults),
        keychainService: fixture.service,
        keychainAccount: fixture.account,
        mainWindowPreferencesKey: fixture.preferencesKey
    )
    let rebuilt = try await rebuiltStore.identity()

    #expect(repeated == first)
    #expect(rebuilt.deviceID == first.deviceID)
    #expect(rebuilt.mainWindowID == first.mainWindowID)
    #expect(rebuilt.clientInstanceID != first.clientInstanceID)
}

@Test func invalidPersistedDeviceIDFailsClosedWithoutOverwritingKeychain() async throws {
    let fixture = try ClientIdentityFixture()
    defer { fixture.cleanup() }
    let invalid = Data("not-a-uuid".utf8)
    try fixture.storeKeychainData(invalid)
    let store = ClientIdentityStore(
        keychain: SecurityClientIdentityKeychain(),
        preferences: UserDefaultsClientIdentityPreferences(userDefaults: fixture.defaults),
        keychainService: fixture.service,
        keychainAccount: fixture.account,
        mainWindowPreferencesKey: fixture.preferencesKey
    )

    await #expect(throws: ClientIdentityStoreError.invalidPersistedDeviceID) {
        _ = try await store.identity()
    }
    #expect(try fixture.loadKeychainData() == invalid)
}

@Test func invalidPersistedMainWindowIDFailsClosedWithoutOverwritingPreferences() async throws {
    let fixture = try ClientIdentityFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set("not-a-uuid", forKey: fixture.preferencesKey)
    let store = ClientIdentityStore(
        keychain: SecurityClientIdentityKeychain(),
        preferences: UserDefaultsClientIdentityPreferences(userDefaults: fixture.defaults),
        keychainService: fixture.service,
        keychainAccount: fixture.account,
        mainWindowPreferencesKey: fixture.preferencesKey
    )

    await #expect(throws: ClientIdentityStoreError.invalidPersistedMainWindowID) {
        _ = try await store.identity()
    }
    #expect(fixture.defaults.string(forKey: fixture.preferencesKey) == "not-a-uuid")
}

private final class ClientIdentityFixture: @unchecked Sendable {
    let service = "dev.cockpit.tests.\(UUID().uuidString)"
    let account = "device.\(UUID().uuidString)"
    let preferencesKey = "window.\(UUID().uuidString)"
    let suiteName = "dev.cockpit.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        cleanup()
    }

    func cleanup() {
        SecItemDelete(keychainQuery() as CFDictionary)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func storeKeychainData(_ data: Data) throws {
        var query = keychainQuery()
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClientIdentityFixtureError.keychain(status) }
    }

    func loadKeychainData() throws -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClientIdentityFixtureError.keychain(status)
        }
        return data
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private enum ClientIdentityFixtureError: Error {
    case keychain(OSStatus)
}
