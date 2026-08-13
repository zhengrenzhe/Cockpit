import AppKit
import Foundation
import CockpitHostCore
import CockpitLocalTransport
@_spi(CockpitTerminalApp) import CockpitTerminalClient
@_spi(CockpitTerminalApp) import CockpitTerminalCore
import CockpitTypes

typealias TerminalSessionListPort = @MainActor @Sendable () async throws -> [ClientTerminalSession]
typealias TerminalArchiveOpenPort = @MainActor @Sendable (TerminalSessionID) async throws -> FileHandle
typealias TerminalRestartPort = @MainActor @Sendable (
    TerminalSessionID,
    AgentProfileID?
) async throws -> Void
typealias TerminalRequestContextPort = @MainActor @Sendable () throws -> RequestContext

@MainActor
final class TerminalTabViewController: NSViewController {
    private enum PresentationError: Error {
        case sessionNotFound
        case finalArchiveUnavailable
    }

    let terminalView: GhosttyTerminalView
    private let attachmentController: TerminalAttachmentController
    private let sessionList: TerminalSessionListPort?
    private let archiveOpen: TerminalArchiveOpenPort?
    private let restart: TerminalRestartPort?
    private let requestContext: TerminalRequestContextPort?
    private let beforeHandlingAttached: (@MainActor @Sendable (TerminalSessionID) async -> Void)?
    private var eventTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartTaskID: UUID?
    private var inputGeneration = UUID()
    private var inputTail: Task<Void, Never>?
    private var inputTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycleRequestID: UUID?
    private var currentSessionID: TerminalSessionID?
    private var presentedSession: ClientTerminalSession?
    private var pendingAttachRequest: UUID?
    private var currentAttachment: TerminalAttachmentIdentity?
    private var retiredAttachments: Set<TerminalAttachmentIdentity> = []
    private var pendingFrames: [TerminalAttachmentIdentity: [TerminalOutputFrame]] = [:]
    private let exitOverlay = NSStackView()
    private let exitStatusLabel = NSTextField(labelWithString: "")
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private let switchAgentButton = NSButton(title: "Switch Agent", target: nil, action: nil)
    private let inputStatusLabel = NSTextField(wrappingLabelWithString: "")

    init(
        attachmentController: TerminalAttachmentController,
        terminalView: GhosttyTerminalView = GhosttyTerminalView(frame: .zero),
        sessionList: TerminalSessionListPort? = nil,
        archiveOpen: TerminalArchiveOpenPort? = nil,
        restart: TerminalRestartPort? = nil,
        requestContext: TerminalRequestContextPort? = nil,
        beforeHandlingAttached: (@MainActor @Sendable (TerminalSessionID) async -> Void)? = nil
    ) {
        self.attachmentController = attachmentController
        self.terminalView = terminalView
        self.sessionList = sessionList
        self.archiveOpen = archiveOpen
        self.restart = restart
        self.requestContext = requestContext
        self.beforeHandlingAttached = beforeHandlingAttached
        super.init(nibName: nil, bundle: nil)
        if requestContext != nil {
            terminalView.inputHandler = { [weak self] payload in
                self?.enqueueInput(payload)
            }
            terminalView.gridHandler = { [weak self] grid in
                self?.enqueueInput(.resize(grid))
            }
        }
    }

    convenience init(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        clientInstanceID: ClientInstanceID,
        capabilities: TerminalAttachCapabilities = .all,
        hostClient: HostXPCClient = HostXPCClient(),
        restart: TerminalRestartPort? = nil
    ) {
        let controlTransport = HostTerminalControlTransport(
            client: hostClient,
            contextID: contextID,
            environmentID: environmentID
        )
        self.init(
            attachmentController: TerminalAttachmentController(
                clientInstanceID: clientInstanceID,
                requestedCapabilities: capabilities,
                controlTransport: controlTransport,
                dataTransport: KeeperTerminalDataTransport()
            ),
            sessionList: { try await controlTransport.list() },
            archiveOpen: { try await controlTransport.openArchive(sessionID: $0) },
            restart: restart
        )
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = terminalView
        installExitOverlay()
        installInputStatus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        terminalView.isTerminalActive = true
        Task { [weak self, attachmentController] in
            await self?.startEvents()
            await attachmentController.setVisible(true)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        terminalView.isTerminalActive = false
        Task { await attachmentController.setVisible(false) }
    }

    deinit {
        eventTask?.cancel()
        finalizationTask?.cancel()
        restartTask?.cancel()
        inputTasks.values.forEach { $0.cancel() }
        let terminalView = terminalView
        Task { @MainActor in terminalView.tearDownRenderer() }
        let attachmentController = attachmentController
        Task { await attachmentController.detach() }
    }

    func detach() {
        resetInputQueue()
        lifecycleRequestID = nil
        currentSessionID = nil
        pendingAttachRequest = nil
        currentAttachment = nil
        retiredAttachments.removeAll(keepingCapacity: false)
        pendingFrames.removeAll(keepingCapacity: false)
        finalizationTask?.cancel()
        finalizationTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartTaskID = nil
        presentedSession = nil
        exitOverlay.isHidden = true
        eventTask?.cancel()
        eventTask = nil
        Task { await attachmentController.detach() }
    }

    func signal(_ signal: TerminalSignal) async throws -> Int32 {
        try await attachmentController.signal(signal)
    }

    func terminate(force: Bool) async throws {
        try await attachmentController.terminate(force: force)
    }

    func attach(
        sessionID: TerminalSessionID,
        lastAcknowledgedSequence: UInt64?
    ) async throws {
        resetInputQueue()
        await startEvents()
        let requestID = UUID()
        lifecycleRequestID = requestID
        currentSessionID = sessionID
        pendingAttachRequest = requestID
        currentAttachment = nil
        retiredAttachments.removeAll(keepingCapacity: false)
        pendingFrames.removeAll(keepingCapacity: false)
        hideFinalState()
        if let sessionList {
            let sessions = try await sessionList()
            guard lifecycleRequestID == requestID else { return }
            guard let session = sessions.first(where: { $0.sessionID == sessionID }) else {
                throw PresentationError.sessionNotFound
            }
            if Self.isFinal(session.lifecycleState) {
                try await presentFinalSession(session, requestID: requestID)
                return
            }
        }
        let acknowledgedSequence = terminalView.resumableAcknowledgement(
            for: sessionID,
            requested: lastAcknowledgedSequence
        )
        terminalView.beginSession(
            sessionID,
            preservingAcknowledgedSequence: acknowledgedSequence
        )
        do {
            let identity = try await attachmentController.attach(
                sessionID: sessionID,
                lastAcknowledgedSequence: acknowledgedSequence
            )
            guard pendingAttachRequest == requestID else { return }
            if retiredAttachments.remove(identity) != nil {
                pendingAttachRequest = nil
                pendingFrames.removeAll(keepingCapacity: false)
                if sessionList != nil,
                   await recoverFinalSession(
                       sessionID: sessionID,
                       requestID: requestID
                   )
                {
                    return
                }
                throw TerminalAttachmentError.notAttached
            }
            pendingAttachRequest = nil
            currentAttachment = identity
            let buffered = pendingFrames.removeValue(forKey: identity) ?? []
            pendingFrames.removeAll(keepingCapacity: false)
            for frame in buffered { terminalView.apply(frame) }
        } catch {
            if lifecycleRequestID == requestID,
               sessionList != nil,
               await recoverFinalSession(
                   sessionID: sessionID,
                   requestID: requestID
               )
            {
                return
            }
            if pendingAttachRequest == requestID {
                pendingAttachRequest = nil
                pendingFrames.removeAll(keepingCapacity: false)
            }
            throw error
        }
    }

    private func startEvents() async {
        guard eventTask == nil else { return }
        let events = await attachmentController.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case let .attached(identity):
                    if let beforeHandlingAttached = self?.beforeHandlingAttached {
                        await beforeHandlingAttached(identity.sessionID)
                    }
                case let .frame(identity, frame):
                    self?.handleFrame(frame, identity: identity)
                case let .detached(identity), let .failed(identity, _):
                    guard let self else { return }
                    if self.retire(identity),
                       let requestID = self.lifecycleRequestID
                    {
                        self.startFinalizationRecovery(
                            sessionID: identity.sessionID,
                            requestID: requestID
                        )
                    }
                }
            }
        }
    }

    private func handleFrame(
        _ frame: TerminalOutputFrame,
        identity: TerminalAttachmentIdentity
    ) {
        if currentAttachment == identity {
            terminalView.apply(frame)
        } else if pendingAttachRequest != nil {
            var frames = pendingFrames[identity, default: []]
            TerminalOutputFrame.enqueueForTerminalApp(frame, into: &frames)
            pendingFrames[identity] = frames
        }
    }

    @discardableResult
    private func retire(_ identity: TerminalAttachmentIdentity) -> Bool {
        pendingFrames.removeValue(forKey: identity)
        if currentAttachment == identity {
            currentAttachment = nil
            return currentSessionID == identity.sessionID
        }
        if pendingAttachRequest != nil { retiredAttachments.insert(identity) }
        return false
    }

    private func startFinalizationRecovery(
        sessionID: TerminalSessionID,
        requestID: UUID
    ) {
        finalizationTask?.cancel()
        finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.recoverFinalSession(
                sessionID: sessionID,
                requestID: requestID
            )
            if self.lifecycleRequestID == requestID {
                self.finalizationTask = nil
            }
        }
    }

    private func recoverFinalSession(
        sessionID: TerminalSessionID,
        requestID: UUID
    ) async -> Bool {
        guard let sessionList else { return false }
        for attempt in 0..<50 {
            guard lifecycleRequestID == requestID,
                  currentSessionID == sessionID,
                  !Task.isCancelled else { return false }
            if attempt > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return false
                }
            }
            do {
                let sessions = try await sessionList()
                guard lifecycleRequestID == requestID else { return false }
                guard let session = sessions.first(where: { $0.sessionID == sessionID }) else {
                    continue
                }
                guard Self.isFinal(session.lifecycleState) else { continue }
                try await presentFinalSession(session, requestID: requestID)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private func presentFinalSession(
        _ session: ClientTerminalSession,
        requestID: UUID
    ) async throws {
        guard Self.isFinal(session.lifecycleState),
              session.sessionID == currentSessionID,
              lifecycleRequestID == requestID else { throw CancellationError() }
        if session.archiveAvailable {
            guard let archiveOpen else {
                throw PresentationError.finalArchiveUnavailable
            }
            let handle = try await archiveOpen(session.sessionID)
            defer { try? handle.close() }
            guard let snapshot = try handle.readToEnd(), !snapshot.isEmpty else {
                throw PresentationError.finalArchiveUnavailable
            }
            guard lifecycleRequestID == requestID else { throw CancellationError() }
            try terminalView.applyFinalSnapshot(snapshot, for: session.sessionID)
        } else {
            terminalView.beginSession(
                session.sessionID,
                preservingAcknowledgedSequence: nil
            )
        }
        pendingAttachRequest = nil
        currentAttachment = nil
        retiredAttachments.removeAll(keepingCapacity: false)
        pendingFrames.removeAll(keepingCapacity: false)
        presentedSession = session
        showFinalState(session)
    }

    private func installExitOverlay() {
        guard exitOverlay.superview == nil else { return }
        exitOverlay.orientation = .vertical
        exitOverlay.alignment = .centerX
        exitOverlay.spacing = 8
        exitOverlay.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        exitOverlay.wantsLayer = true
        exitOverlay.layer?.cornerRadius = 8
        exitOverlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        exitOverlay.translatesAutoresizingMaskIntoConstraints = false
        exitOverlay.identifier = NSUserInterfaceItemIdentifier("terminal-exit-overlay")
        exitStatusLabel.identifier = NSUserInterfaceItemIdentifier("terminal-exit-status")
        restartButton.identifier = NSUserInterfaceItemIdentifier("terminal-restart")
        switchAgentButton.identifier = NSUserInterfaceItemIdentifier("terminal-switch-agent")
        restartButton.target = self
        restartButton.action = #selector(restartAgent(_:))
        switchAgentButton.target = self
        switchAgentButton.action = #selector(switchAgent(_:))
        let actions = NSStackView(views: [restartButton, switchAgentButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        exitOverlay.addArrangedSubview(exitStatusLabel)
        exitOverlay.addArrangedSubview(actions)
        terminalView.addSubview(exitOverlay)
        NSLayoutConstraint.activate([
            exitOverlay.centerXAnchor.constraint(equalTo: terminalView.centerXAnchor),
            exitOverlay.centerYAnchor.constraint(equalTo: terminalView.centerYAnchor),
        ])
        exitOverlay.isHidden = true
    }

    private func installInputStatus() {
        guard inputStatusLabel.superview == nil else { return }
        inputStatusLabel.identifier = NSUserInterfaceItemIdentifier("terminal-input-status")
        inputStatusLabel.textColor = .systemRed
        inputStatusLabel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
        inputStatusLabel.drawsBackground = true
        inputStatusLabel.maximumNumberOfLines = 2
        inputStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalView.addSubview(inputStatusLabel)
        NSLayoutConstraint.activate([
            inputStatusLabel.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor, constant: 12),
            inputStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: terminalView.trailingAnchor, constant: -12),
            inputStatusLabel.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor, constant: -10),
        ])
        inputStatusLabel.isHidden = true
    }

    private func enqueueInput(_ payload: TerminalInput.Payload) {
        guard requestContext != nil else { return }
        let taskID = UUID()
        let generation = inputGeneration
        let predecessor = inputTail
        let task = Task { @MainActor [weak self] in
            if let predecessor { await predecessor.value }
            guard let self,
                  self.inputGeneration == generation,
                  !Task.isCancelled,
                  let requestContext = self.requestContext else {
                self?.finishInputTask(taskID, generation: generation)
                return
            }
            do {
                try await self.attachmentController.send(
                    payload,
                    context: requestContext()
                )
                guard self.inputGeneration == generation else { return }
                self.inputStatusLabel.stringValue = ""
                self.inputStatusLabel.isHidden = true
            } catch is CancellationError {
            } catch {
                guard self.inputGeneration == generation else { return }
                self.inputStatusLabel.stringValue = error.localizedDescription
                self.inputStatusLabel.isHidden = false
            }
            self.finishInputTask(taskID, generation: generation)
        }
        inputTasks[taskID] = task
        inputTail = task
    }

    private func finishInputTask(_ taskID: UUID, generation: UUID) {
        guard inputGeneration == generation else { return }
        inputTasks.removeValue(forKey: taskID)
        if inputTasks.isEmpty { inputTail = nil }
    }

    private func resetInputQueue() {
        inputGeneration = UUID()
        inputTasks.values.forEach { $0.cancel() }
        inputTasks.removeAll(keepingCapacity: false)
        inputTail = nil
        inputStatusLabel.stringValue = ""
        inputStatusLabel.isHidden = true
    }

    private func showFinalState(_ session: ClientTerminalSession) {
        exitStatusLabel.stringValue = Self.exitStatusDescription(session)
        let isAgent: Bool
        switch session.kind {
        case .agent: isAgent = true
        case .shell: isAgent = false
        }
        restartButton.isHidden = !isAgent || restart == nil
        switchAgentButton.isHidden = !isAgent || restart == nil
        restartButton.isEnabled = true
        switchAgentButton.isEnabled = true
        exitOverlay.isHidden = false
    }

    private func hideFinalState() {
        finalizationTask?.cancel()
        finalizationTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartTaskID = nil
        presentedSession = nil
        exitOverlay.isHidden = true
    }

    @objc private func restartAgent(_ sender: NSButton) {
        beginRestart(switchAgent: false)
    }

    @objc private func switchAgent(_ sender: NSButton) {
        beginRestart(switchAgent: true)
    }

    private func beginRestart(switchAgent: Bool) {
        guard restartTask == nil,
              let restart,
              let session = presentedSession,
              case let .agent(currentProfile) = session.kind else { return }
        let profileID: AgentProfileID? = switchAgent
            ? (currentProfile == .codex ? .claude : .codex)
            : nil
        restartButton.isEnabled = false
        switchAgentButton.isEnabled = false
        let taskID = UUID()
        restartTaskID = taskID
        restartTask = Task { @MainActor [weak self] in
            do {
                try await restart(session.sessionID, profileID)
            } catch is CancellationError {
            } catch {
                NSApp.presentError(error)
            }
            self?.finishRestart(taskID, sessionID: session.sessionID)
        }
    }

    private func finishRestart(_ taskID: UUID, sessionID: TerminalSessionID) {
        guard restartTaskID == taskID else { return }
        restartTaskID = nil
        restartTask = nil
        if presentedSession?.sessionID == sessionID {
            restartButton.isEnabled = true
            switchAgentButton.isEnabled = true
        }
    }

    private static func isFinal(_ lifecycle: TerminalLifecycleState) -> Bool {
        switch lifecycle {
        case .exited, .terminated, .interrupted: true
        case .preparing, .committed, .running: false
        }
    }

    private static func exitStatusDescription(_ session: ClientTerminalSession) -> String {
        guard let exitStatus = session.exitStatus else { return "Interrupted" }
        if exitStatus >= 0 { return "Exited \(exitStatus)" }
        return "Terminated by signal \(-exitStatus)"
    }

}
