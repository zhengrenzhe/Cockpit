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
final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
    private struct PendingFrame {
        let frame: TerminalOutputFrame
        var nextFragmentIndex = 0
    }

    private var renderer: (any GhosttyRendererDriving)?
    private var pendingFrames: [PendingFrame] = []
    private var pendingFinalSnapshot: Data?
    private var latestReceivedSequence: UInt64 = 0
    private var lastAppliedSequence: UInt64 = 0
    private var hasSessionViewport = false
    private var hasFinalArchiveViewport = false
    private var sessionID: TerminalSessionID?
    private var rendererWantsVisible = false
    private var rendererIsVisible = false
    private var presentationRetryTask: Task<Void, Never>?
    private var presentationRetryID: UUID?
    private var markedTextStorage = NSAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var interpretingKeyEvent: NSEvent?
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?

    var inputHandler: ((TerminalInput.Payload) -> Void)?

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

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.keyCode {
            case 0x09:
                paste(nil)
            case 0x08:
                break
            default:
                super.keyDown(with: event)
            }
            return
        }
        if let physicalKey = Self.specialPhysicalKeys[event.keyCode] {
            emitKey(logicalKey: 0, physicalKey: physicalKey, event: event)
            return
        }
        if flags.contains(.control),
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           let physicalKey = Self.printablePhysicalKeys[event.keyCode]
        {
            emitKey(logicalKey: scalar.value, physicalKey: physicalKey, event: event)
            return
        }
        interpretingKeyEvent = event
        interpretKeyEvents([event])
        interpretingKeyEvent = nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let committed: String
        if let attributed = string as? NSAttributedString {
            committed = attributed.string
        } else if let plain = string as? String {
            committed = plain
        } else {
            committed = String(describing: string)
        }
        unmarkText()
        guard !committed.isEmpty else { return }
        inputHandler?(.text(committed))
    }

    override func doCommand(by selector: Selector) {
        let name = NSStringFromSelector(selector)
        guard let physicalKey = Self.commandPhysicalKeys[name] else { return }
        if let event = interpretingKeyEvent {
            emitKey(logicalKey: 0, physicalKey: physicalKey, event: event)
        } else if let key = try? TerminalKeyEvent(
            validatingLogicalKey: 0,
            physicalKey: physicalKey,
            modifiers: 0,
            action: .press
        ) {
            inputHandler?(.key(key))
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if let attributed = string as? NSAttributedString {
            markedTextStorage = attributed
        } else if let plain = string as? String {
            markedTextStorage = NSAttributedString(string: plain)
        } else {
            markedTextStorage = NSAttributedString(string: String(describing: string))
        }
        markedSelection = selectedRange
    }

    func unmarkText() {
        markedTextStorage = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedTextStorage.length)
    }

    func hasMarkedText() -> Bool { markedTextStorage.length > 0 }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard hasMarkedText() else { return nil }
        let available = NSRange(location: 0, length: markedTextStorage.length)
        let intersection = NSIntersectionRange(range, available)
        guard intersection.length > 0 else { return nil }
        actualRange?.pointee = intersection
        return markedTextStorage.attributedSubstring(from: intersection)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = hasMarkedText() ? markedRange() : NSRange(location: 0, length: 0)
        let local = NSRect(x: 0, y: 0, width: 1, height: 18)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    @objc func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string),
              !string.isEmpty else { return }
        inputHandler?(.paste(string))
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

    func applyFinalSnapshot(
        _ snapshot: Data,
        for sessionID: TerminalSessionID
    ) throws {
        guard !snapshot.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        beginSession(sessionID, preservingAcknowledgedSequence: nil)
        pendingFinalSnapshot = snapshot
        hasFinalArchiveViewport = true
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
        pendingFinalSnapshot = nil
        latestReceivedSequence = 0
        lastAppliedSequence = 0
        hasSessionViewport = false
        hasFinalArchiveViewport = false
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
              !hasFinalArchiveViewport,
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
            if let finalSnapshot = pendingFinalSnapshot {
                let presented = try renderer.apply(finalSnapshot)
                if rendererWantsVisible && !presented {
                    rendererIsVisible = false
                    if scheduleRetry { schedulePresentationRetry() }
                    return false
                }
                if rendererWantsVisible { rendererIsVisible = true }
                pendingFinalSnapshot = nil
                hasSessionViewport = true
            }
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

    private func emitKey(logicalKey: UInt32, physicalKey: UInt32, event: NSEvent) {
        guard let key = try? TerminalKeyEvent(
            validatingLogicalKey: logicalKey,
            physicalKey: physicalKey,
            modifiers: Self.terminalModifiers(event.modifierFlags),
            action: event.isARepeat ? .repeat : .press
        ) else { return }
        inputHandler?(.key(key))
    }

    private static func terminalModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        let independent = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if independent.contains(.shift) { result |= 1 << 0 }
        if independent.contains(.control) { result |= 1 << 1 }
        if independent.contains(.option) { result |= 1 << 2 }
        if independent.contains(.command) { result |= 1 << 3 }
        if independent.contains(.capsLock) { result |= 1 << 4 }
        if independent.contains(.numericPad) { result |= 1 << 5 }
        return result
    }

    private static let specialPhysicalKeys: [UInt16: UInt32] = [
        0x24: 0x28,
        0x30: 0x2B,
        0x35: 0x29,
        0x33: 0x2A,
        0x75: 0x4C,
        0x7B: 0x50,
        0x7C: 0x4F,
        0x7D: 0x51,
        0x7E: 0x52,
        0x73: 0x4A,
        0x77: 0x4D,
        0x74: 0x4B,
        0x79: 0x4E,
        0x7A: 0x3A,
    ]

    private static let printablePhysicalKeys: [UInt16: UInt32] = [
        0x08: 0x06,
    ]

    private static let commandPhysicalKeys: [String: UInt32] = [
        "insertNewline:": 0x28,
        "insertTab:": 0x2B,
        "cancelOperation:": 0x29,
        "deleteBackward:": 0x2A,
        "deleteForward:": 0x4C,
        "moveLeft:": 0x50,
        "moveRight:": 0x4F,
        "moveDown:": 0x51,
        "moveUp:": 0x52,
        "moveToBeginningOfDocument:": 0x4A,
        "moveToEndOfDocument:": 0x4D,
        "pageUp:": 0x4B,
        "pageDown:": 0x4E,
    ]

    private func schedulePresentationRetry() {
        guard presentationRetryTask == nil,
              rendererShouldBeVisible,
              hasSessionViewport || pendingFinalSnapshot != nil || !pendingFrames.isEmpty
        else { return }
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
