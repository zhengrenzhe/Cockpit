import Darwin
import Foundation
import CockpitHostCore
import CockpitTerminalClient
import CockpitTerminalCore
import CockpitTypes

public actor HostTerminalControlTransport: TerminalControlTransport {
    private let client: HostXPCClient
    private let contextID: WorkspaceContextID
    private let environmentID: EnvironmentID
    private let runtimeDirectory: String

    public init(
        client: HostXPCClient = HostXPCClient(),
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        runtimeDirectory: String = "/private/tmp/cockpit.\(geteuid())/terminal"
    ) {
        self.client = client
        self.contextID = contextID
        self.environmentID = environmentID
        self.runtimeDirectory = runtimeDirectory
    }

    public func issueAttachTicket(
        sessionID: TerminalSessionID,
        clientInstanceID: ClientInstanceID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> TerminalAttachAuthorization {
        let request = TerminalAttachTicketRequest(
            sessionID: sessionID,
            clientInstanceID: clientInstanceID,
            viewerID: viewerID,
            capabilities: capabilities
        )
        guard case let .attachAuthorization(value) = try await client.terminalCommand(
            .issueAttachTicket(
                contextID: contextID,
                environmentID: environmentID,
                request: request
            )
        ) else { throw CocoaError(.coderInvalidValue) }
        let endpoint = try KeeperEndpoint.runtime(
            directory: runtimeDirectory,
            sessionID: value.binding.sessionID,
            workerID: value.binding.workerID
        )
        return TerminalAttachAuthorization(
            endpoint: endpoint,
            wireTicket: value.wireTicket,
            binding: value.binding,
            viewerID: value.viewerID,
            capabilities: value.capabilities
        )
    }

    public func acquireInputLease(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> InputLeaseGrant {
        guard case let .inputLease(value) = try await client.terminalCommand(
            .acquireInputLease(
                contextID: contextID,
                environmentID: environmentID,
                request: TerminalInputLeaseRequest(
                    sessionID: sessionID,
                    viewerID: viewerID,
                    capabilities: capabilities
                )
            )
        ) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    public func releaseInputLease(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    ) async throws {
        guard case .empty = try await client.terminalCommand(
            .releaseInputLease(
                contextID: contextID,
                environmentID: environmentID,
                sessionID: sessionID,
                leaseID: leaseID
            )
        ) else { throw CocoaError(.coderInvalidValue) }
    }

    public func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32 {
        guard case let .processGroup(group) = try await client.terminalCommand(
            .signal(
                contextID: contextID,
                environmentID: environmentID,
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                signal: signal
            )
        ) else { throw CocoaError(.coderInvalidValue) }
        return group
    }

    public func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws {
        guard case .empty = try await client.terminalCommand(
            .terminate(
                contextID: contextID,
                environmentID: environmentID,
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                force: force
            )
        ) else { throw CocoaError(.coderInvalidValue) }
    }

    public func create(_ request: TerminalCreateRequest) async throws -> ClientTerminalSession {
        guard case let .session(value) = try await client.terminalCommand(.create(request)) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func list() async throws -> [ClientTerminalSession] {
        guard case let .sessions(values) = try await client.terminalCommand(
            .list(contextID: contextID)
        ) else { throw CocoaError(.coderInvalidValue) }
        return values
    }

    public func openArchive(sessionID: TerminalSessionID) async throws -> FileHandle {
        try await client.openTerminalArchive(
            HostTerminalArchiveRequest(
                contextID: contextID,
                environmentID: environmentID,
                sessionID: sessionID
            )
        )
    }
}
