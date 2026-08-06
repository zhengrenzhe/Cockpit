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
public enum WindowScope: Sendable {}
public enum ClientInstanceScope: Sendable {}
public enum EditLeaseScope: Sendable {}
public enum DocumentScope: Sendable {}
public enum ViewerScope: Sendable {}
public enum InputLeaseScope: Sendable {}
public enum DeletionOperationScope: Sendable {}
public enum TabScope: Sendable {}
public enum DeviceScope: Sendable {}
public enum ConnectionScope: Sendable {}
public enum RequestScope: Sendable {}

public typealias ProjectID = CockpitID<ProjectScope>
public typealias ConversationID = CockpitID<ConversationScope>
public typealias EnvironmentID = CockpitID<EnvironmentScope>
public typealias TerminalSessionID = CockpitID<TerminalSessionScope>
public typealias WorkerInstanceID = CockpitID<WorkerInstanceScope>
public typealias WindowID = CockpitID<WindowScope>
public typealias ClientInstanceID = CockpitID<ClientInstanceScope>
public typealias EditLeaseID = CockpitID<EditLeaseScope>
public typealias DocumentID = CockpitID<DocumentScope>
public typealias ViewerID = CockpitID<ViewerScope>
public typealias InputLeaseID = CockpitID<InputLeaseScope>
public typealias DeletionOperationID = CockpitID<DeletionOperationScope>
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
    public static let terminalOutput = Self(rawValue: 1)
    public static let terminalInput = Self(rawValue: 2)
    public static let documentEdits = Self(rawValue: 3)
    public static let fileTreeEvents = Self(rawValue: 4)
    public static let bulk = Self(rawValue: 5)
}
