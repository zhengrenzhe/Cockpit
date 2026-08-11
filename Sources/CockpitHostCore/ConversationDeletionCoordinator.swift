import CockpitTypes

public actor ConversationDeletionCoordinator {
    private let repository: any WorkspaceRepository
    private let terminal: any ContextTerminalDeletionControlling
    private var activeOperations: Set<DeletionOperationID> = []
    private var operationWaiters: [
        DeletionOperationID: [CheckedContinuation<Void, Never>]
    ] = [:]

    public init(
        repository: any WorkspaceRepository,
        terminal: any ContextTerminalDeletionControlling
    ) {
        self.repository = repository
        self.terminal = terminal
    }

    public func begin(
        conversationID: ConversationID,
        operationID: DeletionOperationID
    ) async throws {
        await acquire(operationID)
        defer { release(operationID) }
        _ = try await repository.beginConversationDeletion(
            conversationID: conversationID,
            operationID: operationID
        )
        try await run(operationID: operationID, force: false)
    }

    public func resume(operationID: DeletionOperationID) async throws {
        await acquire(operationID)
        defer { release(operationID) }
        try await run(operationID: operationID, force: false)
    }

    public func force(operationID: DeletionOperationID) async throws {
        await acquire(operationID)
        defer { release(operationID) }
        try await run(operationID: operationID, force: true)
    }

    private func acquire(_ operationID: DeletionOperationID) async {
        guard activeOperations.contains(operationID) else {
            activeOperations.insert(operationID)
            return
        }
        await withCheckedContinuation {
            operationWaiters[operationID, default: []].append($0)
        }
    }

    private func release(_ operationID: DeletionOperationID) {
        guard var queued = operationWaiters[operationID], !queued.isEmpty else {
            operationWaiters.removeValue(forKey: operationID)
            activeOperations.remove(operationID)
            return
        }
        let next = queued.removeFirst()
        if queued.isEmpty { operationWaiters.removeValue(forKey: operationID) }
        else { operationWaiters[operationID] = queued }
        next.resume()
    }

    private func run(
        operationID: DeletionOperationID,
        force: Bool
    ) async throws {
        guard var operation = try await repository.conversationDeletion(
            operationID: operationID
        ) else {
            throw ConversationDeletionError.operationMismatch
        }
        let contextID = WorkspaceContextID.conversation(operation.conversationID)

        if operation.phase == .deleting {
            try await terminal.beginContextDeletion(
                contextID: contextID,
                operationID: operationID
            )
            operation = try await repository.advanceConversationDeletion(
                operationID: operationID,
                from: .deleting,
                to: .terminatingSessions
            )
        }

        if operation.phase == .terminatingSessions {
            switch try await terminal.terminateSessions(
                contextID: contextID,
                operationID: operationID,
                force: force
            ) {
            case .complete:
                operation = try await repository.advanceConversationDeletion(
                    operationID: operationID,
                    from: .terminatingSessions,
                    to: .purgingTerminalRecords
                )
            case let .forceConfirmationRequired(activeSessionIDs):
                throw ConversationDeletionError.forceConfirmationRequired(
                    operationID: operationID,
                    activeSessionIDs: activeSessionIDs
                )
            }
        }

        if operation.phase == .purgingTerminalRecords {
            try await terminal.purgeDeletedContext(
                contextID: contextID,
                operationID: operationID
            )
            operation = try await repository.advanceConversationDeletion(
                operationID: operationID,
                from: .purgingTerminalRecords,
                to: .removingClientState
            )
        }

        if operation.phase == .removingClientState {
            try await repository.finishConversationDeletion(operationID: operationID)
        }
    }
}
