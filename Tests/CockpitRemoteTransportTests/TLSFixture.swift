import Foundation
import Security

enum TLSFixtureError: Error {
    case missingDirectory
    case importFailed(OSStatus)
    case missingIdentity
    case missingCertificate
}

struct TLSFixture {
    let identity: SecIdentity
    let certificate: SecCertificate

    static func load() throws -> Self {
        guard let directory = ProcessInfo.processInfo.environment["COCKPIT_TLS_FIXTURE_DIR"] else {
            throw TLSFixtureError.missingDirectory
        }
        let identityData = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("identity.p12"))
        let options = [
            kSecImportExportPassphrase as String: "cockpit-test",
            kSecImportToMemoryOnly as String: true,
        ] as CFDictionary
        var imported: CFArray?
        let status = SecPKCS12Import(identityData as CFData, options, &imported)
        guard status == errSecSuccess else { throw TLSFixtureError.importFailed(status) }
        guard
            let item = (imported as? [[String: Any]])?.first,
            let identityValue = item[kSecImportItemIdentity as String]
        else { throw TLSFixtureError.missingIdentity }
        let identity = identityValue as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw TLSFixtureError.missingCertificate
        }
        return Self(identity: identity, certificate: certificate)
    }
}
