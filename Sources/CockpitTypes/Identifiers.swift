import Foundation

public struct CockpitID<Scope>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ProjectScope: Sendable {}
public enum ConversationScope: Sendable {}
public enum EnvironmentScope: Sendable {}
public enum TerminalSessionScope: Sendable {}
public enum WorkerInstanceScope: Sendable {}
public enum DocumentSessionScope: Sendable {}
public enum TabScope: Sendable {}
public enum DeviceScope: Sendable {}
public enum ConnectionScope: Sendable {}
public enum RequestScope: Sendable {}

public typealias ProjectID = CockpitID<ProjectScope>
public typealias ConversationID = CockpitID<ConversationScope>
public typealias EnvironmentID = CockpitID<EnvironmentScope>
public typealias TerminalSessionID = CockpitID<TerminalSessionScope>
public typealias WorkerInstanceID = CockpitID<WorkerInstanceScope>
public typealias DocumentSessionID = CockpitID<DocumentSessionScope>
public typealias TabID = CockpitID<TabScope>
public typealias DeviceID = CockpitID<DeviceScope>
public typealias ConnectionID = CockpitID<ConnectionScope>
public typealias RequestID = CockpitID<RequestScope>

public struct ChannelID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = Self(rawValue: 0)
}
