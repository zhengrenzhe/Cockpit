import Foundation
import Network
import Security

public enum TLSOptionsError: Error, Sendable {
    case identityConversionFailed
}

public enum TLSOptionsFactory {
    public static func server(identity: SecIdentity) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        guard let converted = sec_identity_create(identity) else {
            throw TLSOptionsError.identityConversionFailed
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, converted)
        return options
    }

    public static func client(pinnedCertificateDER: Data) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        let queue = DispatchQueue(label: "dev.cockpit.remote.tls-verify")
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else {
                complete(false)
                return
            }
            complete(SecCertificateCopyData(leaf) as Data == pinnedCertificateDER)
        }, queue)
        return options
    }
}
