import AppKit
import Foundation
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes

struct TabFileSelection: Hashable, Sendable {
    let path: RelativePath
    let language: String
}

enum TabDirtyFileCloseDecision: Hashable, Sendable {
    case save
    case discard
    case cancel
}

typealias TabActiveContextPort = @MainActor @Sendable (
    WorkspaceContextID
) async throws -> ActiveContext
typealias TabTerminalCreatePort = @MainActor @Sendable (
    ActiveContext,
    TerminalCreateRequest
) async throws -> ClientTerminalSession
typealias TabTerminalListPort = @MainActor @Sendable (
    ActiveContext
) async throws -> [ClientTerminalSession]
typealias TabDocumentTransportFactory = @MainActor @Sendable (
    ActiveContext
) throws -> any DocumentDataTransport
typealias TabFilePickerPort = @MainActor @Sendable (
    ActiveContext
) async throws -> TabFileSelection?
typealias TabExecutablePickerPort = @MainActor @Sendable (
    AgentProfileID
) async throws -> Data?
typealias TabDetachedTerminalPickerPort = @MainActor @Sendable (
    [ClientTerminalSession]
) async throws -> ClientTerminalSession?
typealias TabDirtyFileCloseDecisionPort = @MainActor @Sendable (
    DocumentSnapshot
) async -> TabDirtyFileCloseDecision

@MainActor
protocol TabCommanding: FileRelocationCoordinating {
    func selectFileTab(_ tab: WorkspaceTab, in active: ActiveContext) async throws
    func createTab(
        for option: NewTabPickerOption,
        tabID: TabID,
        in active: ActiveContext
    ) async throws -> WorkspaceTabKind
    func reattachTerminal(
        in active: ActiveContext,
        excluding sessionIDs: Set<TerminalSessionID>
    ) async throws -> WorkspaceTabKind
    func restartTerminal(
        _ tab: WorkspaceTab,
        in active: ActiveContext,
        switchingTo profileID: AgentProfileID?
    ) async throws -> WorkspaceTabKind
    func prepareClose(_ tab: WorkspaceTab, in active: ActiveContext) async throws -> Bool
    func finalizeClose(_ tab: WorkspaceTab, in active: ActiveContext) async throws
}

extension TabCommanding {
    func close(_ tab: WorkspaceTab, in active: ActiveContext) async throws -> Bool {
        guard try await prepareClose(tab, in: active) else { return false }
        try await finalizeClose(tab, in: active)
        return true
    }
}

@MainActor
final class TabCommandController: TabCommanding {
    private struct DocumentLocator: Hashable {
        let workspaceRootIdentity: String
        let path: RelativePath
    }

    private struct DocumentReference: Hashable {
        let contextID: WorkspaceContextID
        let tabID: TabID
        let documentID: DocumentID
    }

    private struct DocumentViewerRegistration {
        let transport: any DocumentDataTransport
        let isControllerTransport: Bool
    }

    private let workspaceService: any WorkspaceServing
    let bridge: MonacoBridge
    private let clientInstanceID: ClientInstanceID
    private let windowID: WindowID
    private let activeContext: TabActiveContextPort
    private let terminalCreate: TabTerminalCreatePort
    private let terminalList: TabTerminalListPort
    private let documentTransportFactory: TabDocumentTransportFactory
    private let filePicker: TabFilePickerPort
    private let executablePicker: TabExecutablePickerPort
    private let detachedTerminalPicker: TabDetachedTerminalPickerPort
    private let dirtyFileCloseDecision: TabDirtyFileCloseDecisionPort
    private let terminalSize: TerminalResize

    private var documentIDsByLocator: [DocumentLocator: DocumentID] = [:]
    private var locatorsByDocumentID: [DocumentID: Set<DocumentLocator>] = [:]
    private var controllersByDocumentID: [DocumentID: DocumentClientController] = [:]
    private var viewerRegistrations: [
        DocumentReference: DocumentViewerRegistration
    ] = [:]
    private var pendingRelocations: [RequestID: MonacoRelocationToken] = [:]
    private var relocationRootIdentities: [RequestID: [DocumentID: Set<String>]] = [:]
    private var occupiedDocumentLocators: Set<DocumentLocator> = []
    private var documentLocatorWaiters: [
        DocumentLocator: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var fileLifecycleOccupied = false
    private var fileLifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var fileLifecycleRelocationID: RequestID?
    private var relocationRecoveryInFlight: RequestID?
    var relocationRecoveryObserver: (@MainActor @Sendable (RequestID) async -> Void)?

    init(
        workspaceService: any WorkspaceServing,
        bridge: MonacoBridge,
        clientInstanceID: ClientInstanceID,
        windowID: WindowID,
        activeContext: @escaping TabActiveContextPort,
        terminalCreate: @escaping TabTerminalCreatePort,
        terminalList: @escaping TabTerminalListPort,
        documentTransportFactory: @escaping TabDocumentTransportFactory,
        filePicker: @escaping TabFilePickerPort,
        executablePicker: @escaping TabExecutablePickerPort,
        detachedTerminalPicker: @escaping TabDetachedTerminalPickerPort,
        dirtyFileCloseDecision: @escaping TabDirtyFileCloseDecisionPort,
        terminalSize: TerminalResize = try! TerminalResize(
            validatingColumns: 120,
            rows: 40
        )
    ) {
        self.workspaceService = workspaceService
        self.bridge = bridge
        self.clientInstanceID = clientInstanceID
        self.windowID = windowID
        self.activeContext = activeContext
        self.terminalCreate = terminalCreate
        self.terminalList = terminalList
        self.documentTransportFactory = documentTransportFactory
        self.filePicker = filePicker
        self.executablePicker = executablePicker
        self.detachedTerminalPicker = detachedTerminalPicker
        self.dirtyFileCloseDecision = dirtyFileCloseDecision
        self.terminalSize = terminalSize
    }

    var pendingRelocationTokens: [MonacoRelocationToken] {
        pendingRelocations.values.sorted { $0.id.description < $1.id.description }
    }

    func selectFileTab(_ tab: WorkspaceTab, in active: ActiveContext) async throws {
        guard case let .file(documentID) = tab.kind else {
            throw WorkspaceViewModelError.invalidTabKind
        }
        await acquireFileLifecycle()
        defer { releaseFileLifecycle() }
        try Task.checkCancellation()

        let reference = DocumentReference(
            contextID: active.contextID,
            tabID: tab.id,
            documentID: documentID
        )
        if let session = bridge.resolver.session(documentID: documentID),
           let controller = controllersByDocumentID[documentID],
           session.controller === controller,
           session.lastAuthoritativeEnvironmentID == active.environmentID,
           session.references.contains(where: {
               $0.workspaceContextID == active.contextID && $0.tabID == tab.id
           }),
           viewerRegistrations[reference] != nil
        {
            try await bridge.select(
                contextID: active.contextID,
                tabID: tab.id,
                documentID: documentID
            )
            return
        }

        if let session = bridge.resolver.session(documentID: documentID),
           let controller = controllersByDocumentID[documentID],
           session.controller === controller,
           session.lastAuthoritativeEnvironmentID == active.environmentID,
           let path = session.lastAuthoritativePath
        {
            let transport = try documentTransportFactory(active)
            try await transport.retainViewer(documentID: documentID)
            do {
                try await bridge.resolver.retain(
                    contextID: active.contextID,
                    tabID: tab.id,
                    documentID: documentID,
                    controller: controller,
                    language: Self.languageIdentifier(for: path)
                )
                try await bridge.select(
                    contextID: active.contextID,
                    tabID: tab.id,
                    documentID: documentID
                )
            } catch {
                try? await bridge.resolver.release(
                    contextID: active.contextID,
                    tabID: tab.id,
                    documentID: documentID
                )
                await transport.releaseViewer(documentID: documentID)
                await transport.closeDocument(documentID: documentID)
                throw error
            }
            viewerRegistrations[reference] = DocumentViewerRegistration(
                transport: transport,
                isControllerTransport: false
            )
            return
        }

        let transport = try documentTransportFactory(active)
        let controller = DocumentClientController(
            clientInstanceID: clientInstanceID,
            transport: transport
        )
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await controller.restore(
                documentID: documentID,
                in: active.environmentID,
                requestWriteAccess: true
            )
        } catch {
            await controller.close()
            throw error
        }
        guard snapshot.documentID == documentID,
              snapshot.environmentID == active.environmentID
        else {
            await controller.close()
            throw DocumentProtocolError.invalidValue
        }
        do {
            try await transport.retainViewer(documentID: documentID)
            try await bridge.resolver.retain(
                contextID: active.contextID,
                tabID: tab.id,
                documentID: documentID,
                controller: controller,
                language: Self.languageIdentifier(for: snapshot.relativePath)
            )
            try await bridge.select(
                contextID: active.contextID,
                tabID: tab.id,
                documentID: documentID
            )
        } catch {
            try? await bridge.resolver.release(
                contextID: active.contextID,
                tabID: tab.id,
                documentID: documentID
            )
            await transport.releaseViewer(documentID: documentID)
            await controller.close()
            throw error
        }
        viewerRegistrations[reference] = DocumentViewerRegistration(
            transport: transport,
            isControllerTransport: true
        )
        let locator = DocumentLocator(
            workspaceRootIdentity: active.workspaceRootIdentity,
            path: snapshot.relativePath
        )
        documentIDsByLocator[locator] = documentID
        locatorsByDocumentID[documentID, default: []].insert(locator)
        controllersByDocumentID[documentID] = controller
    }

    func createTab(
        for option: NewTabPickerOption,
        tabID: TabID,
        in active: ActiveContext
    ) async throws -> WorkspaceTabKind {
        switch option {
        case .file:
            return try await openFile(tabID: tabID, in: active)
        case .shell:
            let session = try await createTerminal(kind: .shell, in: active)
            return .shell(session.sessionID)
        case .codex:
            let session = try await createAgent(profileID: .codex, in: active)
            return .codex(session.sessionID)
        case .claude:
            let session = try await createAgent(profileID: .claude, in: active)
            return .claude(session.sessionID)
        case .reattach:
            return try await reattachTerminal(in: active, excluding: [])
        }
    }

    func reattachTerminal(
        in active: ActiveContext,
        excluding sessionIDs: Set<TerminalSessionID>
    ) async throws -> WorkspaceTabKind {
        let candidates = try await detachedTerminals(
            in: active,
            excluding: sessionIDs
        )
        guard let selected = try await detachedTerminalPicker(candidates) else {
            throw CancellationError()
        }
        guard candidates.contains(selected) else {
            throw CocoaError(.coderInvalidValue)
        }
        return try Self.workspaceTabKind(for: selected)
    }

    func restartTerminal(
        _ tab: WorkspaceTab,
        in active: ActiveContext,
        switchingTo profileID: AgentProfileID?
    ) async throws -> WorkspaceTabKind {
        let originalProfile: AgentProfileID
        switch tab.kind {
        case .codex: originalProfile = .codex
        case .claude: originalProfile = .claude
        case .file, .shell, .newTabPicker:
            throw CocoaError(.coderInvalidValue)
        }
        let sessions = try await terminalList(active)
        guard sessions.allSatisfy({
            $0.contextID == active.contextID && $0.environmentID == active.environmentID
        }),
        let original = sessions.first(where: { $0.sessionID == tab.kind.terminalSessionID }),
        Self.isFinalLifecycle(original.lifecycleState),
        original.kind == .agent(originalProfile)
        else { throw CocoaError(.coderInvalidValue) }

        let profileID = profileID ?? originalProfile
        let replacement = try await createAgent(profileID: profileID, in: active)
        return profileID == .codex
            ? .codex(replacement.sessionID)
            : .claude(replacement.sessionID)
    }

    func detachedTerminals(
        in active: ActiveContext,
        excluding attachedSessionIDs: Set<TerminalSessionID>
    ) async throws -> [ClientTerminalSession] {
        let sessions = try await terminalList(active)
        guard sessions.allSatisfy({
            $0.contextID == active.contextID && $0.environmentID == active.environmentID
        }) else { throw CocoaError(.coderInvalidValue) }
        return sessions.filter {
            !attachedSessionIDs.contains($0.sessionID)
                && $0.workerID != nil
                && Self.isActiveLifecycle($0.lifecycleState)
        }
    }

    func performRelocation(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws {
        _ = try await performRelocationWithDisposition(
            operation,
            workspaceContextID: workspaceContextID
        )
    }

    @discardableResult
    func performRelocationWithDisposition(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws -> MonacoRelocationDisposition {
        await acquireFileLifecycle()
        var releasesFileLifecycle = true
        defer {
            if releasesFileLifecycle { releaseFileLifecycle() }
        }
        try Task.checkCancellation()
        let active = try await activeContext(workspaceContextID)
        guard active.contextID == workspaceContextID else { throw CancellationError() }
        let token = try await bridge.prepareRelocation(
            workspaceContextID: workspaceContextID,
            operation: operation
        )
        let result: FileOperationResult
        do {
            result = try await workspaceService.performFileOperation(
                context: try RequestContext(
                    validating: .current,
                    clientInstanceID: clientInstanceID,
                    windowID: windowID,
                    workspaceContextID: active.contextID,
                    environmentID: active.environmentID,
                    activeContextGeneration: active.generation,
                    requestID: RequestID()
                ),
                operation: operation
            )
        } catch {
            try bridge.cancelRelocation(token)
            throw error
        }
        guard Self.isExact(result: result, for: operation) else {
            try bridge.cancelRelocation(token)
            throw MonacoBridgeError.invalidSchema
        }
        captureLocatorRoots(for: token)
        let disposition: MonacoRelocationDisposition
        do {
            disposition = try await bridge.commitRelocation(token, result: result)
        } catch {
            relocationRootIdentities.removeValue(forKey: token.id)
            throw error
        }
        reconcileLocatorCache(for: token, disposition: disposition)
        remember(token, for: disposition)
        if case .incomplete = disposition {
            fileLifecycleRelocationID = token.id
            releasesFileLifecycle = false
        }
        return disposition
    }

    func retryRelocation(
        _ token: MonacoRelocationToken
    ) async throws -> MonacoRelocationDisposition {
        guard pendingRelocations[token.id] == token else {
            throw MonacoBridgeError.invalidSchema
        }
        guard fileLifecycleRelocationID == token.id else {
            throw MonacoBridgeError.staleDocumentState
        }
        guard relocationRecoveryInFlight == nil else {
            throw MonacoBridgeError.staleDocumentState
        }
        relocationRecoveryInFlight = token.id
        defer {
            if relocationRecoveryInFlight == token.id {
                relocationRecoveryInFlight = nil
            }
        }
        if let relocationRecoveryObserver {
            await relocationRecoveryObserver(token.id)
        }
        let disposition = try await bridge.retryRelocation(token)
        reconcileLocatorCache(for: token, disposition: disposition)
        remember(token, for: disposition)
        if case .incomplete = disposition {
            return disposition
        }
        fileLifecycleRelocationID = nil
        releaseFileLifecycle()
        return disposition
    }

    func abandonRelocation(
        _ token: MonacoRelocationToken
    ) async throws -> MonacoRelocationDisposition {
        guard pendingRelocations[token.id] == token else {
            throw MonacoBridgeError.invalidSchema
        }
        guard fileLifecycleRelocationID == token.id else {
            throw MonacoBridgeError.staleDocumentState
        }
        guard relocationRecoveryInFlight == nil else {
            throw MonacoBridgeError.staleDocumentState
        }
        relocationRecoveryInFlight = token.id
        defer {
            if relocationRecoveryInFlight == token.id {
                relocationRecoveryInFlight = nil
            }
        }
        if let relocationRecoveryObserver {
            await relocationRecoveryObserver(token.id)
        }
        let disposition = try await bridge.abandonCommittedRelocation(token)
        reconcileLocatorCache(for: token, disposition: disposition)
        remember(token, for: disposition)
        fileLifecycleRelocationID = nil
        releaseFileLifecycle()
        return disposition
    }

    func prepareClose(_ tab: WorkspaceTab, in active: ActiveContext) async throws -> Bool {
        guard case let .file(documentID) = tab.kind else { return true }
        await acquireFileLifecycle()
        defer { releaseFileLifecycle() }
        try Task.checkCancellation()
        return try await bridge.resolver.withLifecycleGate {
            let session = try self.fileSession(
                for: tab,
                documentID: documentID,
                in: active
            )

            if session.references.count == 1 {
                switch await session.controller.state {
                case let .ready(snapshot), let .readOnly(snapshot):
                    if snapshot.dirtyState != .clean {
                        switch await self.dirtyFileCloseDecision(snapshot) {
                        case .cancel:
                            return false
                        case .save:
                            guard let fingerprint = snapshot.observedDiskFingerprint else {
                                throw DocumentProtocolError.invalidValue
                            }
                            _ = try await session.controller.save(
                                expectedFingerprint: fingerprint
                            )
                        case .discard:
                            _ = try await session.controller.discard()
                        }
                    }
                case .closed:
                    throw MonacoBridgeError.unknownDocument
                case .resynchronizing:
                    throw MonacoBridgeError.resynchronizing
                }
            }
            return true
        }
    }

    func finalizeClose(_ tab: WorkspaceTab, in active: ActiveContext) async throws {
        guard case let .file(documentID) = tab.kind else { return }
        await acquireFileLifecycle()
        defer { releaseFileLifecycle() }
        try Task.checkCancellation()
        let controller = try fileSession(
            for: tab,
            documentID: documentID,
            in: active
        ).controller
        let reference = DocumentReference(
            contextID: active.contextID,
            tabID: tab.id,
            documentID: documentID
        )
        guard let registration = viewerRegistrations[reference] else {
            throw MonacoBridgeError.unknownDocument
        }
        try await bridge.resolver.release(
            contextID: active.contextID,
            tabID: tab.id,
            documentID: documentID
        )
        await registration.transport.releaseViewer(documentID: documentID)
        viewerRegistrations.removeValue(forKey: reference)
        if !registration.isControllerTransport {
            await registration.transport.closeDocument(documentID: documentID)
        }
        if bridge.resolver.session(documentID: documentID) == nil {
            await controller.close()
            controllersByDocumentID.removeValue(forKey: documentID)
            removeAllLocators(for: documentID)
        }
    }

    private func fileSession(
        for tab: WorkspaceTab,
        documentID: DocumentID,
        in active: ActiveContext
    ) throws -> MonacoWindowSession {
        guard let session = bridge.resolver.session(documentID: documentID),
              session.references.contains(where: {
                  $0.workspaceContextID == active.contextID && $0.tabID == tab.id
              })
        else { throw MonacoBridgeError.unknownDocument }
        return session
    }

    private func createAgent(
        profileID: AgentProfileID,
        in active: ActiveContext
    ) async throws -> ClientTerminalSession {
        do {
            return try await createTerminal(kind: .agent(profileID), in: active)
        } catch TerminalSupervisorCreateError.agentExecutableSelectionRequired(let required)
            where required == profileID
        {
            guard let bookmark = try await executablePicker(profileID) else {
                throw TerminalSupervisorCreateError.agentExecutableSelectionRequired(profileID)
            }
            return try await createTerminal(
                kind: .agent(profileID),
                selectedExecutableBookmark: bookmark,
                in: active
            )
        }
    }

    private func createTerminal(
        kind: TerminalKind,
        selectedExecutableBookmark: Data? = nil,
        in active: ActiveContext
    ) async throws -> ClientTerminalSession {
        let session = try await terminalCreate(
            active,
            TerminalCreateRequest(
                contextID: active.contextID,
                environmentID: active.environmentID,
                kind: kind,
                arguments: [],
                terminalSize: terminalSize,
                environmentOverrides: [:],
                idempotencyKey: RequestID(),
                selectedExecutableBookmark: selectedExecutableBookmark
            )
        )
        guard session.contextID == active.contextID,
              session.environmentID == active.environmentID,
              session.kind == kind
        else { throw CocoaError(.coderInvalidValue) }
        return session
    }

    private func openFile(
        tabID: TabID,
        in active: ActiveContext
    ) async throws -> WorkspaceTabKind {
        guard let selection = try await filePicker(active) else {
            throw CancellationError()
        }
        let locator = DocumentLocator(
            workspaceRootIdentity: active.workspaceRootIdentity,
            path: selection.path
        )
        await acquireFileLifecycle()
        defer { releaseFileLifecycle() }
        try Task.checkCancellation()
        await acquire(locator)
        defer { release(locator) }
        try Task.checkCancellation()
        if let documentID = documentIDsByLocator[locator],
           let session = bridge.resolver.session(documentID: documentID),
           let controller = controllersByDocumentID[documentID],
           session.controller === controller,
           session.lastAuthoritativeEnvironmentID == active.environmentID,
           session.lastAuthoritativePath == selection.path
        {
            let transport = try documentTransportFactory(active)
            try await transport.retainViewer(documentID: documentID)
            do {
                try await bridge.resolver.retain(
                    contextID: active.contextID,
                    tabID: tabID,
                    documentID: documentID,
                    controller: controller,
                    language: selection.language
                )
                try await bridge.select(
                    contextID: active.contextID,
                    tabID: tabID,
                    documentID: documentID
                )
            } catch {
                try? await bridge.resolver.release(
                    contextID: active.contextID,
                    tabID: tabID,
                    documentID: documentID
                )
                await transport.releaseViewer(documentID: documentID)
                await transport.closeDocument(documentID: documentID)
                throw error
            }
            viewerRegistrations[DocumentReference(
                contextID: active.contextID,
                tabID: tabID,
                documentID: documentID
            )] = DocumentViewerRegistration(
                transport: transport,
                isControllerTransport: false
            )
            return .file(documentID)
        }

        if let staleDocumentID = documentIDsByLocator[locator] {
            remove(locator, from: staleDocumentID)
        }
        let transport = try documentTransportFactory(active)
        let controller = DocumentClientController(
            clientInstanceID: clientInstanceID,
            transport: transport
        )
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await controller.open(
                in: active.environmentID,
                at: selection.path,
                requestWriteAccess: true
            )
        } catch {
            await controller.close()
            throw error
        }
        guard snapshot.environmentID == active.environmentID,
              snapshot.relativePath == selection.path
        else {
            await controller.close()
            throw DocumentProtocolError.invalidValue
        }
        do {
            try await transport.retainViewer(documentID: snapshot.documentID)
            try await bridge.resolver.retain(
                contextID: active.contextID,
                tabID: tabID,
                documentID: snapshot.documentID,
                controller: controller,
                language: selection.language
            )
            try await bridge.select(
                contextID: active.contextID,
                tabID: tabID,
                documentID: snapshot.documentID
            )
        } catch {
            try? await bridge.resolver.release(
                contextID: active.contextID,
                tabID: tabID,
                documentID: snapshot.documentID
            )
            await transport.releaseViewer(documentID: snapshot.documentID)
            await controller.close()
            throw error
        }
        viewerRegistrations[DocumentReference(
            contextID: active.contextID,
            tabID: tabID,
            documentID: snapshot.documentID
        )] = DocumentViewerRegistration(
            transport: transport,
            isControllerTransport: true
        )
        documentIDsByLocator[locator] = snapshot.documentID
        locatorsByDocumentID[snapshot.documentID, default: []].insert(locator)
        controllersByDocumentID[snapshot.documentID] = controller
        return .file(snapshot.documentID)
    }

    private func acquire(_ locator: DocumentLocator) async {
        guard occupiedDocumentLocators.contains(locator) else {
            occupiedDocumentLocators.insert(locator)
            return
        }
        await withCheckedContinuation {
            documentLocatorWaiters[locator, default: []].append($0)
        }
    }

    private func release(_ locator: DocumentLocator) {
        guard var waiters = documentLocatorWaiters[locator], !waiters.isEmpty else {
            occupiedDocumentLocators.remove(locator)
            documentLocatorWaiters.removeValue(forKey: locator)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            documentLocatorWaiters.removeValue(forKey: locator)
        } else {
            documentLocatorWaiters[locator] = waiters
        }
        next.resume()
    }

    private func acquireFileLifecycle() async {
        guard fileLifecycleOccupied else {
            fileLifecycleOccupied = true
            return
        }
        await withCheckedContinuation { fileLifecycleWaiters.append($0) }
    }

    private func releaseFileLifecycle() {
        guard !fileLifecycleWaiters.isEmpty else {
            fileLifecycleOccupied = false
            return
        }
        fileLifecycleWaiters.removeFirst().resume()
    }

    private func captureLocatorRoots(for token: MonacoRelocationToken) {
        guard relocationRootIdentities[token.id] == nil else { return }
        var rootsByDocumentID: [DocumentID: Set<String>] = [:]
        for documentID in token.affectedDocumentIDs {
            rootsByDocumentID[documentID] = Set(
                (locatorsByDocumentID[documentID] ?? []).map(\.workspaceRootIdentity)
            )
        }
        relocationRootIdentities[token.id] = rootsByDocumentID
    }

    private func reconcileLocatorCache(
        for token: MonacoRelocationToken,
        disposition: MonacoRelocationDisposition
    ) {
        let rootsByDocumentID = relocationRootIdentities[token.id] ?? [:]
        let pendingDocumentIDs: Set<DocumentID>
        let restoresMigratedLocators: Bool
        switch disposition {
        case .complete:
            pendingDocumentIDs = []
            restoresMigratedLocators = true
        case let .incomplete(pending):
            pendingDocumentIDs = Set(pending)
            restoresMigratedLocators = true
        case .abandonedAllStale:
            pendingDocumentIDs = Set(token.affectedDocumentIDs)
            restoresMigratedLocators = false
        }

        for documentID in token.affectedDocumentIDs {
            removeAllLocators(for: documentID)
            guard restoresMigratedLocators,
                  !pendingDocumentIDs.contains(documentID),
                  let session = bridge.resolver.session(documentID: documentID),
                  let path = session.lastAuthoritativePath
            else { continue }
            for rootIdentity in rootsByDocumentID[documentID] ?? [] {
                let locator = DocumentLocator(
                    workspaceRootIdentity: rootIdentity,
                    path: path
                )
                documentIDsByLocator[locator] = documentID
                locatorsByDocumentID[documentID, default: []].insert(locator)
            }
        }

        if case .incomplete = disposition {
            return
        }
        relocationRootIdentities.removeValue(forKey: token.id)
    }

    private func remove(_ locator: DocumentLocator, from documentID: DocumentID) {
        documentIDsByLocator.removeValue(forKey: locator)
        locatorsByDocumentID[documentID]?.remove(locator)
        if locatorsByDocumentID[documentID]?.isEmpty == true {
            locatorsByDocumentID.removeValue(forKey: documentID)
        }
    }

    private func removeAllLocators(for documentID: DocumentID) {
        for locator in locatorsByDocumentID.removeValue(forKey: documentID) ?? [] {
            documentIDsByLocator.removeValue(forKey: locator)
        }
    }

    private func remember(
        _ token: MonacoRelocationToken,
        for disposition: MonacoRelocationDisposition
    ) {
        switch disposition {
        case .incomplete:
            pendingRelocations[token.id] = token
        case .complete, .abandonedAllStale:
            pendingRelocations.removeValue(forKey: token.id)
        }
    }

    private static func isActiveLifecycle(_ state: TerminalLifecycleState) -> Bool {
        switch state {
        case .preparing, .committed, .running: true
        case .exited, .terminated, .interrupted: false
        }
    }

    private static func isFinalLifecycle(_ state: TerminalLifecycleState) -> Bool {
        switch state {
        case .exited, .terminated, .interrupted: true
        case .preparing, .committed, .running: false
        }
    }

    private static func workspaceTabKind(
        for session: ClientTerminalSession
    ) throws -> WorkspaceTabKind {
        switch session.kind {
        case .shell: return .shell(session.sessionID)
        case .agent(.codex): return .codex(session.sessionID)
        case .agent(.claude): return .claude(session.sessionID)
        }
    }

    private static func isExact(
        result: FileOperationResult,
        for operation: FileOperation
    ) -> Bool {
        guard case let .relocated(from, to) = result,
              let expected = try? relocationResult(for: operation)
        else { return false }
        return from == expected.from && to == expected.to
    }

    private static func relocationResult(
        for operation: FileOperation
    ) throws -> (from: RelativePath, to: RelativePath) {
        switch operation {
        case let .rename(source, newName):
            let components = source.string.split(separator: "/")
            let parent = components.dropLast().joined(separator: "/")
            return (
                source,
                try RelativePath(parent.isEmpty ? newName : "\(parent)/\(newName)")
            )
        case let .move(source, destinationDirectory):
            let name = source.string.split(separator: "/").last.map(String.init) ?? ""
            let destination: String
            switch destinationDirectory {
            case .root:
                destination = name
            case let .relative(parent):
                destination = "\(parent.string)/\(name)"
            }
            return (source, try RelativePath(destination))
        case .createFile, .createDirectory, .trash:
            throw MonacoBridgeError.invalidSchema
        }
    }

    static func appKitFilePicker(
        _ active: ActiveContext
    ) async throws -> TabFileSelection? {
        let alert = NSAlert()
        alert.messageText = "Open File"
        alert.informativeText = "Enter a path relative to the workspace root."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Sources/File.swift"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let path = try RelativePath(field.stringValue)
        return TabFileSelection(
            path: path,
            language: languageIdentifier(for: path)
        )
    }

    static func appKitExecutablePicker(_ profileID: AgentProfileID) async throws -> Data? {
        let panel = NSOpenPanel()
        panel.message = "Select the \(profileID.rawValue) executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func appKitDetachedTerminalPicker(
        _ sessions: [ClientTerminalSession]
    ) async throws -> ClientTerminalSession? {
        guard !sessions.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Reattach Terminal"
        alert.informativeText = "Select a detached terminal in this context."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        for session in sessions {
            let kind: String
            switch session.kind {
            case .shell: kind = "Shell"
            case .agent(.codex): kind = "Codex"
            case .agent(.claude): kind = "Claude"
            }
            popup.addItem(withTitle: "\(kind) — \(session.sessionID)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Reattach")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              sessions.indices.contains(popup.indexOfSelectedItem)
        else { return nil }
        return sessions[popup.indexOfSelectedItem]
    }

    static func appKitDirtyFileCloseDecision(
        _ snapshot: DocumentSnapshot
    ) async -> TabDirtyFileCloseDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = snapshot.relativePath.string
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    private static func languageIdentifier(for path: RelativePath) -> String {
        switch (path.string as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "js", "mjs", "cjs": "javascript"
        case "ts": "typescript"
        case "json": "json"
        case "md": "markdown"
        case "sh", "zsh", "bash": "shell"
        default: "plaintext"
        }
    }
}
