import AppKit
import CockpitGhostty
import CockpitTerminalCore
import CockpitTypes

@MainActor
protocol GhosttyRendererDriving: AnyObject {
    func apply(_ frame: Data) throws -> Bool
    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool
    func setVisible(_ visible: Bool) -> Bool
    func tearDown()
}

@MainActor
final class GhosttyRendererDriver: GhosttyRendererDriving {
    private nonisolated(unsafe) var renderer: OpaquePointer?

    init(view: NSView) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        renderer = cockpit_ghostty_renderer_create(
            Unmanaged.passUnretained(view).toOpaque(),
            scale
        )
    }

    deinit {
        if let renderer { cockpit_ghostty_renderer_destroy(renderer) }
    }

    func apply(_ frame: Data) throws -> Bool {
        guard let renderer else { throw CocoaError(.coderInvalidValue) }
        let result = frame.withUnsafeBytes { bytes in
            cockpit_ghostty_renderer_apply(
                renderer,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard result >= 0 else { throw CocoaError(.coderInvalidValue) }
        return result == 1
    }

    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool {
        guard let renderer else { return false }
        return cockpit_ghostty_renderer_resize(renderer, width, height, scale) == 1
    }

    func setVisible(_ visible: Bool) -> Bool {
        guard let renderer else { return false }
        return cockpit_ghostty_renderer_set_visible(renderer, visible) == 1
    }

    func tearDown() {
        guard let renderer else { return }
        self.renderer = nil
        cockpit_ghostty_renderer_destroy(renderer)
    }
}

@MainActor
final class GhosttyTerminalView: NSView {
    private struct PendingFrame {
        let frame: TerminalOutputFrame
        var nextFragmentIndex = 0
    }

    private var renderer: (any GhosttyRendererDriving)?
    private var pendingFrames: [PendingFrame] = []
    private var latestReceivedSequence: UInt64 = 0
    private var lastAppliedSequence: UInt64 = 0
    private var hasSessionViewport = false
    private var sessionID: TerminalSessionID?
    private var rendererWantsVisible = false
    private var rendererIsVisible = false
    private var presentationRetryTask: Task<Void, Never>?
    private var presentationRetryID: UUID?
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?

    var isTerminalActive = false {
        didSet { refreshRendererVisibility() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        renderer = GhosttyRendererDriver(view: self)
        refreshRendererVisibility()
    }

    init(renderer: any GhosttyRendererDriving) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        refreshRendererVisibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        renderer = GhosttyRendererDriver(view: self)
        refreshRendererVisibility()
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override var isHidden: Bool {
        didSet { refreshRendererVisibility() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refreshRendererVisibility() }
            }
        }
        resizeRenderer()
        refreshRendererVisibility()
    }

    override func layout() {
        super.layout()
        resizeRenderer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeRenderer()
    }

    func apply(_ frame: TerminalOutputFrame) {
        guard frame.outputSequence > latestReceivedSequence else { return }
        latestReceivedSequence = frame.outputSequence
        let pending = PendingFrame(frame: frame)
        if frame.kind == .snapshot {
            pendingFrames = [pending]
        } else {
            pendingFrames.append(pending)
        }
        refreshRendererVisibility()
    }

    func beginSession() {
        beginSession(TerminalSessionID(), preservingAcknowledgedSequence: nil)
    }

    func beginSession(
        _ sessionID: TerminalSessionID,
        preservingAcknowledgedSequence: UInt64?
    ) {
        if self.sessionID == sessionID,
           hasSessionViewport,
           preservingAcknowledgedSequence == lastAppliedSequence {
            refreshRendererVisibility()
            return
        }
        self.sessionID = sessionID
        pendingFrames.removeAll(keepingCapacity: true)
        latestReceivedSequence = 0
        lastAppliedSequence = 0
        hasSessionViewport = false
        cancelPresentationRetry()
        rendererWantsVisible = false
        rendererIsVisible = false
        _ = renderer?.setVisible(false)
    }

    func resumableAcknowledgement(
        for sessionID: TerminalSessionID,
        requested: UInt64?
    ) -> UInt64? {
        guard self.sessionID == sessionID,
              hasSessionViewport,
              let requested,
              requested == lastAppliedSequence else { return nil }
        return requested
    }

    func tearDownRenderer() {
        cancelPresentationRetry()
        rendererWantsVisible = false
        rendererIsVisible = false
        renderer?.tearDown()
        renderer = nil
    }

    private var rendererShouldBeVisible: Bool {
        guard isTerminalActive, !isHidden else { return false }
        guard let window else { return false }
        return window.occlusionState.contains(.visible)
    }

    @discardableResult
    private func refreshRendererVisibility(scheduleRetry: Bool = true) -> Bool {
        guard let renderer else { return true }
        guard rendererShouldBeVisible else {
            cancelPresentationRetry()
            rendererWantsVisible = false
            rendererIsVisible = false
            _ = renderer.setVisible(false)
            return true
        }
        do {
            while !pendingFrames.isEmpty {
                let frame = pendingFrames[0].frame
                if frame.outputSequence <= lastAppliedSequence {
                    pendingFrames.removeFirst()
                    continue
                }
                while pendingFrames[0].nextFragmentIndex < frame.fragments.count {
                    let index = pendingFrames[0].nextFragmentIndex
                    let presented = try renderer.apply(frame.fragments[index])
                    if rendererWantsVisible && !presented {
                        rendererIsVisible = false
                        if scheduleRetry { schedulePresentationRetry() }
                        return false
                    }
                    if rendererWantsVisible { rendererIsVisible = true }
                    pendingFrames[0].nextFragmentIndex += 1
                }
                lastAppliedSequence = frame.outputSequence
                if frame.kind == .snapshot { hasSessionViewport = true }
                pendingFrames.removeFirst()
            }
        } catch {
            cancelPresentationRetry()
            rendererWantsVisible = false
            rendererIsVisible = false
            _ = renderer.setVisible(false)
            return false
        }
        guard hasSessionViewport else { return true }
        if !rendererIsVisible {
            rendererWantsVisible = true
            rendererIsVisible = renderer.setVisible(true)
            if !rendererIsVisible {
                if scheduleRetry { schedulePresentationRetry() }
                return false
            }
        }
        if scheduleRetry { cancelPresentationRetry() }
        return true
    }

    private func resizeRenderer() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = UInt32(max(0, min(CGFloat(UInt32.max), bounds.width * scale)))
        let height = UInt32(max(0, min(CGFloat(UInt32.max), bounds.height * scale)))
        guard let renderer else { return }
        let presented = renderer.resize(width: width, height: height, scale: scale)
        if rendererWantsVisible {
            rendererIsVisible = presented
            if rendererShouldBeVisible, hasSessionViewport, !presented {
                schedulePresentationRetry()
            }
        }
    }

    private func schedulePresentationRetry() {
        guard presentationRetryTask == nil,
              rendererShouldBeVisible,
              hasSessionViewport || !pendingFrames.isEmpty else { return }
        let retryID = UUID()
        presentationRetryID = retryID
        presentationRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<8 {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
                guard let self,
                      self.presentationRetryID == retryID,
                      !Task.isCancelled else { return }
                if self.refreshRendererVisibility(scheduleRetry: false) {
                    self.finishPresentationRetry(retryID)
                    return
                }
            }
            self?.finishPresentationRetry(retryID)
        }
    }

    private func finishPresentationRetry(_ retryID: UUID) {
        guard presentationRetryID == retryID else { return }
        presentationRetryID = nil
        presentationRetryTask = nil
    }

    private func cancelPresentationRetry() {
        presentationRetryID = nil
        presentationRetryTask?.cancel()
        presentationRetryTask = nil
    }
}
