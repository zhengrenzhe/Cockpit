public struct ProtocolVersion: Hashable, Codable, Sendable, Comparable {
    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public static let current = ProtocolVersion(major: 1, minor: 0)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public struct ProtocolFeature: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let workspaceControl = Self(rawValue: "workspace-control")
    public static let terminalControl = Self(rawValue: "terminal-control")
    public static let terminalFrames = Self(rawValue: "terminal-frames")
    public static let remoteDirect = Self(rawValue: "remote-direct")
}
