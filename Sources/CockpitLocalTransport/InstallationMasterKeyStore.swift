import Foundation
import Security
import CockpitTerminalCore

public enum InstallationMasterKeyStoreError: Error, Equatable, Sendable {
    case invalidPersistedMasterKey
    case randomGenerationFailed
    case keychain(OSStatus)
}

public struct SecurityTerminalRandomBytes: TerminalSecurityRandomBytes {
    public init() {}

    public func bytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw TerminalSecurityError.randomGenerationFailed }
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw TerminalSecurityError.randomGenerationFailed
        }
        return bytes
    }
}

public actor InstallationMasterKeyStore: InstallationMasterKeyProviding {
    public static let productionService = "dev.cockpit.terminal.master-key"
    public static let productionAccount = "installation-master-key-v1"

    private let service: String
    private let account: String
    private let randomBytes: any TerminalSecurityRandomBytes
    private let explicitKeychainPath: String?
    private var cachedMasterKey: Data?

    public init(
        service: String = InstallationMasterKeyStore.productionService,
        account: String = InstallationMasterKeyStore.productionAccount,
        randomBytes: any TerminalSecurityRandomBytes = SecurityTerminalRandomBytes(),
        explicitKeychainPath: String? = nil
    ) {
        self.service = service
        self.account = account
        self.randomBytes = randomBytes
        self.explicitKeychainPath = explicitKeychainPath
    }

    public func masterKey() throws -> Data {
        if let cachedMasterKey { return cachedMasterKey }
        if let existing = try load() {
            guard existing.count == 32 else {
                throw InstallationMasterKeyStoreError.invalidPersistedMasterKey
            }
            cachedMasterKey = existing
            return existing
        }

        let generated: [UInt8]
        do {
            generated = try randomBytes.bytes(count: 32)
        } catch {
            throw InstallationMasterKeyStoreError.randomGenerationFailed
        }
        guard generated.count == 32 else {
            throw InstallationMasterKeyStoreError.randomGenerationFailed
        }
        let key = Data(generated)
        let status = SecItemAdd(try addQuery(data: key) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            cachedMasterKey = key
            return key
        case errSecDuplicateItem:
            guard let existing = try load(), existing.count == 32 else {
                throw InstallationMasterKeyStoreError.invalidPersistedMasterKey
            }
            cachedMasterKey = existing
            return existing
        default:
            throw InstallationMasterKeyStoreError.keychain(status)
        }
    }

    private func load() throws -> Data? {
        var query = try baseQuery()
        if let keychain = try explicitKeychain() {
            query[kSecMatchSearchList as String] = [keychain]
        }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw InstallationMasterKeyStoreError.keychain(status)
        }
        return data
    }

    private func baseQuery() throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let keychain = try explicitKeychain() {
            query[kSecUseKeychain as String] = keychain
        }
        return query
    }

    private func explicitKeychain() throws -> SecKeychain? {
        guard let explicitKeychainPath else { return nil }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(explicitKeychainPath, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw InstallationMasterKeyStoreError.keychain(status)
        }
        return keychain
    }

    private func addQuery(data: Data) throws -> [String: Any] {
        var query = try baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }
}
