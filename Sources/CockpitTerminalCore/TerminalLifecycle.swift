public enum TerminalLifecycleState: String, Codable, CaseIterable, Sendable {
    case preparing
    case committed
    case running
    case exited
    case terminated
    case interrupted
}
