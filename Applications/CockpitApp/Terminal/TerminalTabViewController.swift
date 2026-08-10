import AppKit
import CockpitLocalTransport
@_spi(CockpitTerminalApp) import CockpitTerminalClient
@_spi(CockpitTerminalApp) import CockpitTerminalCore
import CockpitTypes

@MainActor
final class TerminalTabViewController: NSViewController {
    let terminalView: GhosttyTerminalView
    private let attachmentController: TerminalAttachmentController
    private let beforeHandlingAttached: (@MainActor @Sendable (TerminalSessionID) async -> Void)?
    private var eventTask: Task<Void, Never>?
    private var pendingAttachRequest: UUID?
    private var currentAttachment: TerminalAttachmentIdentity?
    private var pendingFrames: [TerminalAttachmentIdentity: [TerminalOutputFrame]] = [:]

    init(
        attachmentController: TerminalAttachmentController,
        terminalView: GhosttyTerminalView = GhosttyTerminalView(frame: .zero),
        beforeHandlingAttached: (@MainActor @Sendable (TerminalSessionID) async -> Void)? = nil
    ) {
        self.attachmentController = attachmentController
        self.terminalView = terminalView
        self.beforeHandlingAttached = beforeHandlingAttached
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        clientInstanceID: ClientInstanceID,
        capabilities: TerminalAttachCapabilities = .all,
        hostClient: HostXPCClient = HostXPCClient()
    ) {
        self.init(
            attachmentController: TerminalAttachmentController(
                clientInstanceID: clientInstanceID,
                requestedCapabilities: capabilities,
                controlTransport: HostTerminalControlTransport(
                    client: hostClient,
                    contextID: contextID,
                    environmentID: environmentID
                ),
                dataTransport: KeeperTerminalDataTransport()
            )
        )
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = terminalView
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
        let terminalView = terminalView
        Task { @MainActor in terminalView.tearDownRenderer() }
        let attachmentController = attachmentController
        Task { await attachmentController.detach() }
    }

    func detach() {
        pendingAttachRequest = nil
        currentAttachment = nil
        pendingFrames.removeAll(keepingCapacity: false)
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
        await startEvents()
        let requestID = UUID()
        pendingAttachRequest = requestID
        currentAttachment = nil
        pendingFrames.removeAll(keepingCapacity: false)
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
            pendingAttachRequest = nil
            currentAttachment = identity
            let buffered = pendingFrames.removeValue(forKey: identity) ?? []
            pendingFrames.removeAll(keepingCapacity: false)
            for frame in buffered { terminalView.apply(frame) }
        } catch {
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
                    self?.retire(identity)
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

    private func retire(_ identity: TerminalAttachmentIdentity) {
        pendingFrames.removeValue(forKey: identity)
        if currentAttachment == identity { currentAttachment = nil }
    }

}
