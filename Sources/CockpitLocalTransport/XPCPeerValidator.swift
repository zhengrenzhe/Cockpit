import Darwin

public struct XPCPeerValidator: Sendable {
    public let expectedEffectiveUserIdentifier: uid_t

    public init(expectedEffectiveUserIdentifier: uid_t) {
        self.expectedEffectiveUserIdentifier = expectedEffectiveUserIdentifier
    }

    public static let currentUser = Self(expectedEffectiveUserIdentifier: geteuid())

    public func accepts(effectiveUserIdentifier: uid_t) -> Bool {
        effectiveUserIdentifier == expectedEffectiveUserIdentifier
    }
}
