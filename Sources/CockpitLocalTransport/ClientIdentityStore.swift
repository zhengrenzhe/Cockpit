import Foundation
import Security
import CockpitTypes

public struct ClientIdentity: Hashable, Sendable {
    public let deviceID: DeviceID
    public let mainWindowID: WindowID
    public let clientInstanceID: ClientInstanceID

    public init(
        deviceID: DeviceID,
        mainWindowID: WindowID,
        clientInstanceID: ClientInstanceID
    ) {
        self.deviceID = deviceID
        self.mainWindowID = mainWindowID
        self.clientInstanceID = clientInstanceID
    }
}

public enum ClientIdentityStoreError: Error, Equatable, Sendable {
    case invalidPersistedDeviceID
    case invalidPersistedMainWindowID
    case keychain(OSStatus)
}

public protocol ClientIdentityKeychain: Sendable {
    func load(service: String, account: String) throws -> Data?
    func save(_ data: Data, service: String, account: String) throws
}

public protocol ClientIdentityPreferences: Sendable {
    func containsValue(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

public struct SecurityClientIdentityKeychain: ClientIdentityKeychain {
    public init() {}

    public func load(service: String, account: String) throws -> Data? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClientIdentityStoreError.keychain(status)
        }
        return data
    }

    public func save(_ data: Data, service: String, account: String) throws {
        var query = Self.query(service: service, account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ClientIdentityStoreError.keychain(status)
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct UserDefaultsClientIdentityPreferences: ClientIdentityPreferences, @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func containsValue(forKey key: String) -> Bool {
        userDefaults.object(forKey: key) != nil
    }

    public func string(forKey key: String) -> String? {
        userDefaults.string(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        userDefaults.set(value, forKey: key)
    }
}

public actor ClientIdentityStore {
    public static let productionKeychainService = "dev.cockpit.client-identity"
    public static let productionKeychainAccount = "device-id-v1"
    public static let productionMainWindowPreferencesKey = "main-window-id-v1"

    private let keychain: any ClientIdentityKeychain
    private let preferences: any ClientIdentityPreferences
    private let keychainService: String
    private let keychainAccount: String
    private let mainWindowPreferencesKey: String
    private let clientInstanceID = ClientInstanceID()
    private var cachedIdentity: ClientIdentity?

    public init(
        keychain: any ClientIdentityKeychain = SecurityClientIdentityKeychain(),
        preferences: any ClientIdentityPreferences = UserDefaultsClientIdentityPreferences(),
        keychainService: String = ClientIdentityStore.productionKeychainService,
        keychainAccount: String = ClientIdentityStore.productionKeychainAccount,
        mainWindowPreferencesKey: String = ClientIdentityStore.productionMainWindowPreferencesKey
    ) {
        self.keychain = keychain
        self.preferences = preferences
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.mainWindowPreferencesKey = mainWindowPreferencesKey
    }

    public func identity() throws -> ClientIdentity {
        if let cachedIdentity { return cachedIdentity }
        let identity = ClientIdentity(
            deviceID: try loadOrCreateDeviceID(),
            mainWindowID: try loadOrCreateMainWindowID(),
            clientInstanceID: clientInstanceID
        )
        cachedIdentity = identity
        return identity
    }

    private func loadOrCreateDeviceID() throws -> DeviceID {
        if let data = try keychain.load(service: keychainService, account: keychainAccount) {
            guard let value = String(data: data, encoding: .utf8),
                  let uuid = UUID(uuidString: value)
            else {
                throw ClientIdentityStoreError.invalidPersistedDeviceID
            }
            return DeviceID(uuid)
        }
        let created = DeviceID()
        try keychain.save(
            Data(created.description.utf8),
            service: keychainService,
            account: keychainAccount
        )
        return created
    }

    private func loadOrCreateMainWindowID() throws -> WindowID {
        if preferences.containsValue(forKey: mainWindowPreferencesKey) {
            guard let value = preferences.string(forKey: mainWindowPreferencesKey),
                  let uuid = UUID(uuidString: value)
            else {
                throw ClientIdentityStoreError.invalidPersistedMainWindowID
            }
            return WindowID(uuid)
        }
        let created = WindowID()
        preferences.set(created.description, forKey: mainWindowPreferencesKey)
        return created
    }
}
