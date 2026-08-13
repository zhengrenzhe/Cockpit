import AppKit
import Foundation
import XCTest
import CockpitHostCore
import CockpitTerminalCore
import CockpitTerminalClient
import CockpitTypes
@testable import Cockpit

@MainActor
final class GhosttyTerminalViewTests: XCTestCase {
    func testTerminalViewAcceptsFirstResponderAndMouseDownFocusesIt() throws {
        let view = GhosttyTerminalView(renderer: RecordingGhosttyRenderer())
        let window = TestOcclusionWindow(contentView: view)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertTrue(view.acceptsFirstResponder)
        view.mouseDown(with: event)
        XCTAssertTrue(window.firstResponder === view)
    }

    func testCommittedAndMarkedTextEmitExactlyOnce() {
        let view = GhosttyTerminalView(renderer: RecordingGhosttyRenderer())
        var payloads: [TerminalInput.Payload] = []
        view.inputHandler = { payloads.append($0) }

        view.setMarkedText(
            "你",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(payloads, [])

        view.insertText(
            "你好",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(payloads, [.text("你好")])
    }

    func testCommandVPastesOneNonemptyLiteralAndEmptyPasteboardEmitsNothing() throws {
        let view = GhosttyTerminalView(renderer: RecordingGhosttyRenderer())
        var payloads: [TerminalInput.Payload] = []
        view.inputHandler = { payloads.append($0) }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }

        pasteboard.clearContents()
        pasteboard.setString("paste cockpit", forType: .string)
        view.keyDown(with: try keyEvent(keyCode: 0x09, characters: "v", modifiers: [.command]))
        pasteboard.clearContents()
        view.keyDown(with: try keyEvent(keyCode: 0x09, characters: "v", modifiers: [.command]))

        XCTAssertEqual(payloads, [.paste("paste cockpit")])
    }

    func testSpecialKeysMapToLiteralUSBHIDUsagesAndModifiers() throws {
        let view = GhosttyTerminalView(renderer: RecordingGhosttyRenderer())
        var payloads: [TerminalInput.Payload] = []
        view.inputHandler = { payloads.append($0) }
        let cases: [(UInt16, String, UInt32)] = [
            (0x24, "\r", 0x28),
            (0x30, "\t", 0x2B),
            (0x35, "\u{1B}", 0x29),
            (0x33, "\u{7F}", 0x2A),
            (0x75, "\u{7F}", 0x4C),
            (0x7B, "", 0x50),
            (0x7C, "", 0x4F),
            (0x7D, "", 0x51),
            (0x7E, "", 0x52),
            (0x73, "", 0x4A),
            (0x77, "", 0x4D),
            (0x74, "", 0x4B),
            (0x79, "", 0x4E),
            (0x7A, "", 0x3A),
        ]
        for (keyCode, characters, _) in cases {
            view.keyDown(with: try keyEvent(
                keyCode: keyCode,
                characters: characters,
                modifiers: [.shift, .option]
            ))
        }

        let keys = payloads.compactMap { payload -> TerminalKeyEvent? in
            guard case let .key(key) = payload else { return nil }
            return key
        }
        XCTAssertEqual(keys.map(\.physicalKey), cases.map(\.2))
        XCTAssertEqual(keys.map(\.logicalKey), Array(repeating: 0, count: cases.count))
        XCTAssertEqual(keys.map(\.modifiers), Array(repeating: 0b101, count: cases.count))
        XCTAssertEqual(keys.map(\.action), Array(repeating: .press, count: cases.count))
    }

    func testControlCEmitsKeyAndCommandCWithoutSelectionEmitsNothing() throws {
        let view = GhosttyTerminalView(renderer: RecordingGhosttyRenderer())
        var payloads: [TerminalInput.Payload] = []
        view.inputHandler = { payloads.append($0) }

        view.keyDown(with: try keyEvent(keyCode: 0x08, characters: "c", modifiers: [.control]))
        view.keyDown(with: try keyEvent(keyCode: 0x08, characters: "c", modifiers: [.command]))

        XCTAssertEqual(payloads.count, 1)
        guard case let .key(key) = try XCTUnwrap(payloads.first) else {
            return XCTFail("expected Control-C key payload")
        }
        XCTAssertEqual(key.logicalKey, 0x63)
        XCTAssertEqual(key.physicalKey, 0x06)
        XCTAssertEqual(key.modifiers, 0b10)
        XCTAssertEqual(key.action, .press)
    }

    func testTerminalTabSerializesTextPasteResizeAndClearsInlineInputError() async throws {
        let clientID = ClientInstanceID()
        let sessionID = TerminalSessionID()
        let connection = SerialTerminalDataConnection()
        let terminalView = GhosttyTerminalView(renderer: RecordingGhosttyRenderer())
        let controller = TerminalAttachmentController(
            clientInstanceID: clientID,
            requestedCapabilities: [.view, .input, .resize],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: SerialTerminalDataTransport(connection: connection)
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView,
            requestContext: {
                try RequestContext(
                    validating: .current,
                    clientInstanceID: clientID,
                    windowID: WindowID(),
                    workspaceContextID: .project(ProjectID()),
                    environmentID: EnvironmentID(),
                    activeContextGeneration: 1,
                    requestID: RequestID()
                )
            }
        )
        tab.loadViewIfNeeded()
        try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)

        terminalView.inputHandler?(.text("first"))
        terminalView.inputHandler?(.paste("second"))
        terminalView.inputHandler?(.resize(
            try TerminalResize(validatingColumns: 120, rows: 40)
        ))
        for _ in 0..<200 where !(await connection.firstSendIsBlocked) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let firstSendIsBlocked = await connection.firstSendIsBlocked
        XCTAssertTrue(firstSendIsBlocked)
        await connection.releaseFirstSend()
        for _ in 0..<200 where await connection.payloads.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let orderedPayloads = await connection.payloads
        XCTAssertEqual(
            orderedPayloads,
            [
                .text("first"),
                .paste("second"),
                .resize(try TerminalResize(validatingColumns: 120, rows: 40)),
            ]
        )

        let status: NSTextField = try XCTUnwrap(descendant(
            in: tab.view,
            identifier: "terminal-input-status"
        ))
        await connection.failNextPayload(.paste("bad"))
        terminalView.inputHandler?(.paste("bad"))
        for _ in 0..<200 where status.isHidden {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(status.isHidden)
        XCTAssertFalse(status.stringValue.isEmpty)

        terminalView.inputHandler?(.text("recovered"))
        for _ in 0..<200 where !status.isHidden {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(status.isHidden)
        let recoveredPayloads = await connection.payloads
        XCTAssertEqual(Array(recoveredPayloads.suffix(2)), [.paste("bad"), .text("recovered")])
        tab.detach()
    }

    func testInactiveViewerBuffersLatestFrameWithoutDrawingAndFlushesOnResume() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        let first = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("first".utf8)]
        )
        let latest = try TerminalOutputFrame(
            firstOutputSequence: 2,
            outputSequence: 2,
            kind: .snapshot,
            fragments: [Data("latest".utf8)]
        )

        view.isTerminalActive = false
        view.apply(first)
        view.apply(latest)
        XCTAssertEqual(renderer.applied, [])
        XCTAssertEqual(renderer.visibility.last, false)

        view.isTerminalActive = true
        XCTAssertEqual(renderer.applied, [Data("latest".utf8)])
        XCTAssertEqual(renderer.visibility.last, true)
    }

    func testHiddenViewImmediatelyDisablesRendererAndResumesWithNewestFrame() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true
        view.isHidden = true
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 7,
                outputSequence: 7,
                fragments: [Data("hidden".utf8)]
            )
        )
        XCTAssertEqual(renderer.applied, [])
        XCTAssertEqual(renderer.visibility.last, false)

        view.isHidden = false
        XCTAssertEqual(renderer.applied, [Data("hidden".utf8)])
        XCTAssertEqual(renderer.visibility.last, true)
    }

    func testNoWindowAndOccludedWindowRemainInvisibleUntilVisible() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        view.isTerminalActive = true
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                fragments: [Data("waiting".utf8)]
            )
        )
        XCTAssertEqual(renderer.applied, [])
        XCTAssertEqual(renderer.visibility.last, false)

        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = []
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        XCTAssertEqual(renderer.applied, [])
        XCTAssertEqual(renderer.visibility.last, false)

        window.testOcclusionState = [.visible]
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        XCTAssertEqual(renderer.applied, [Data("waiting".utf8)])
        XCTAssertEqual(renderer.visibility.last, true)
    }

    func testNewSessionResetsRendererSequence() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 9,
                outputSequence: 9,
                fragments: [Data("old".utf8)]
            )
        )
        view.beginSession()
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                fragments: [Data("new".utf8)]
            )
        )
        XCTAssertEqual(renderer.applied, [Data("old".utf8), Data("new".utf8)])
    }

    func testNewSessionHidesOldViewportUntilNewSnapshotIsApplied() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 9,
                outputSequence: 9,
                kind: .snapshot,
                fragments: [Data("old".utf8)]
            )
        )

        renderer.resetOperations()
        view.beginSession()
        XCTAssertEqual(renderer.operations, ["visible:false"])

        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                kind: .snapshot,
                fragments: [Data("new".utf8)]
            )
        )
        XCTAssertEqual(renderer.operations, ["visible:false", "apply:new", "visible:true"])
    }

    func testHiddenViewerRetainsEveryDeltaAfterLatestSnapshot() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true
        let snapshot = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("snapshot".utf8)]
        )
        let firstDelta = try TerminalOutputFrame(
            firstOutputSequence: 2,
            outputSequence: 2,
            kind: .delta,
            fragments: [Data("delta-2".utf8)]
        )
        let secondDelta = try TerminalOutputFrame(
            firstOutputSequence: 3,
            outputSequence: 3,
            kind: .delta,
            fragments: [Data("delta-3".utf8)]
        )

        view.apply(snapshot)
        view.isHidden = true
        view.apply(firstDelta)
        view.apply(secondDelta)
        view.isHidden = false

        XCTAssertEqual(
            renderer.applied,
            [Data("snapshot".utf8), Data("delta-2".utf8), Data("delta-3".utf8)]
        )
    }

    func testHiddenScrollbackDoesNotReplaceAuthoritativeViewportFrame() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = false
        let snapshot = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("snapshot".utf8)]
        )
        let scrollback = try TerminalOutputFrame(
            firstOutputSequence: 2,
            outputSequence: 2,
            kind: .scrollback,
            fragments: [Data("scrollback".utf8)]
        )

        view.apply(snapshot)
        view.apply(scrollback)
        view.isTerminalActive = true

        XCTAssertEqual(renderer.applied, [Data("snapshot".utf8), Data("scrollback".utf8)])
    }

    func testPartiallyAppliedFrameRetriesOnlyTheUncommittedFragmentSuffix() throws {
        let renderer = FailingSecondFragmentGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true

        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 2,
                kind: .snapshot,
                fragments: [Data("snapshot".utf8), Data("delta".utf8)]
            )
        )
        XCTAssertEqual(renderer.attempted, [Data("snapshot".utf8), Data("delta".utf8)])
        XCTAssertEqual(renderer.visibility.last, false)

        view.isTerminalActive = false
        view.isTerminalActive = true
        XCTAssertEqual(
            renderer.attempted,
            [Data("snapshot".utf8), Data("delta".utf8), Data("delta".utf8)]
        )
        XCTAssertEqual(renderer.visibility.last, true)
    }

    func testTransientPresentationFailureRetriesWithoutExternalVisibilityChange() async throws {
        let renderer = FailOncePresentationGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true

        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                kind: .snapshot,
                fragments: [Data("snapshot".utf8)]
            )
        )
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 2,
                outputSequence: 2,
                kind: .delta,
                fragments: [Data("delta".utf8)]
            )
        )

        for _ in 0..<200 where renderer.presentationAttempts < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.presentationAttempts, 2)
        XCTAssertEqual(renderer.visibility.last, true)
    }

    func testVisibleFrameDoesNotTriggerASecondPresentation() throws {
        let renderer = DrawingCountGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true

        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                kind: .snapshot,
                fragments: [Data("snapshot".utf8)]
            )
        )
        renderer.presentationCount = 0
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 2,
                outputSequence: 2,
                kind: .delta,
                fragments: [Data("delta".utf8)]
            )
        )

        XCTAssertEqual(renderer.presentationCount, 1)
    }

    func testPresentationRetryStopsWhenHiddenAndWhenRendererIsTornDown() async throws {
        let renderer = AlwaysFailPresentationGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                kind: .snapshot,
                fragments: [Data("snapshot".utf8)]
            )
        )
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 2,
                outputSequence: 2,
                kind: .delta,
                fragments: [Data("delta".utf8)]
            )
        )
        for _ in 0..<200 where renderer.presentationAttempts < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        view.isHidden = true
        let attemptsWhenHidden = renderer.presentationAttempts
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(renderer.presentationAttempts, attemptsWhenHidden)

        view.isHidden = false
        for _ in 0..<200 where renderer.presentationAttempts == attemptsWhenHidden {
            try await Task.sleep(for: .milliseconds(5))
        }
        view.tearDownRenderer()
        let attemptsAtTearDown = renderer.presentationAttempts
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(renderer.presentationAttempts, attemptsAtTearDown)
    }

    func testFinalArchiveSnapshotReplacesLiveViewportWithoutInventingAResumeSequence() throws {
        let renderer = RecordingGhosttyRenderer()
        let view = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: view)
        window.testOcclusionState = [.visible]
        view.isTerminalActive = true
        let sessionID = TerminalSessionID()
        view.beginSession(sessionID, preservingAcknowledgedSequence: nil)
        view.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 7,
                outputSequence: 7,
                kind: .snapshot,
                fragments: [Data("live".utf8)]
            )
        )

        try view.applyFinalSnapshot(Data("final".utf8), for: sessionID)

        XCTAssertEqual(renderer.applied, [Data("live".utf8), Data("final".utf8)])
        XCTAssertNil(view.resumableAcknowledgement(for: sessionID, requested: 7))
    }

    func testNaturalAgentExitLoadsFinalArchiveShowsExitCodeAndSerializesRestartActions() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let sessionID = TerminalSessionID()
        let live = try terminalClientSession(
            sessionID: sessionID,
            lifecycle: .running,
            kind: .agent(.codex)
        )
        let finished = try terminalClientSession(
            sessionID: sessionID,
            lifecycle: .exited,
            kind: .agent(.codex),
            exitStatus: 23,
            latestSequence: 8,
            archiveAvailable: true
        )
        let lifecycle = TerminalTabLifecycleRecorder(
            listResults: [[live], [finished]],
            archiveData: Data("final-agent-screen".utf8)
        )
        let liveFrame = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("live-agent-screen".utf8)]
        )
        let controller = TerminalAttachmentController(
            clientInstanceID: ClientInstanceID(),
            requestedCapabilities: [.view],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: FiniteTerminalDataTransport(
                connection: FiniteTerminalDataConnection(frames: [liveFrame])
            )
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView,
            sessionList: lifecycle.list,
            archiveOpen: lifecycle.openArchive,
            restart: lifecycle.restart
        )
        tab.loadViewIfNeeded()

        try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
        for _ in 0..<200 where !renderer.applied.contains(Data("final-agent-screen".utf8)) {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(renderer.applied.last, Data("final-agent-screen".utf8))
        XCTAssertNil(terminalView.resumableAcknowledgement(for: sessionID, requested: 8))
        let status: NSTextField? = descendant(
            in: tab.view,
            identifier: "terminal-exit-status"
        )
        XCTAssertTrue(status?.stringValue.contains("23") == true)
        let restart: NSButton? = descendant(
            in: tab.view,
            identifier: "terminal-restart"
        )
        let switchAgent: NSButton? = descendant(
            in: tab.view,
            identifier: "terminal-switch-agent"
        )
        guard let restart, let switchAgent else {
            return XCTFail("expected restart and switch-agent controls")
        }

        lifecycle.pauseNextRestart()
        restart.performClick(nil)
        await lifecycle.waitUntilRestartPaused()
        restart.performClick(nil)
        XCTAssertEqual(lifecycle.restartCalls.count, 1)
        XCTAssertEqual(lifecycle.restartCalls.first?.sessionID, sessionID)
        XCTAssertNil(lifecycle.restartCalls.first?.profileID)
        lifecycle.resumeRestart()
        for _ in 0..<200 where !restart.isEnabled {
            try await Task.sleep(for: .milliseconds(5))
        }
        switchAgent.performClick(nil)
        for _ in 0..<200 where lifecycle.restartCalls.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(lifecycle.restartCalls.last?.sessionID, sessionID)
        XCTAssertEqual(lifecycle.restartCalls.last?.profileID, .claude)
        tab.detach()
    }

    func testAttachFailureRechecksDurableStateAndShowsTheFinalArchive() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let sessionID = TerminalSessionID()
        let live = try terminalClientSession(
            sessionID: sessionID,
            lifecycle: .running,
            kind: .agent(.claude)
        )
        let finished = try terminalClientSession(
            sessionID: sessionID,
            lifecycle: .exited,
            kind: .agent(.claude),
            exitStatus: 9,
            latestSequence: 3,
            archiveAvailable: true
        )
        let lifecycle = TerminalTabLifecycleRecorder(
            listResults: [[live], [finished]],
            archiveData: Data("race-final-screen".utf8)
        )
        let tab = TerminalTabViewController(
            attachmentController: TerminalAttachmentController(
                clientInstanceID: ClientInstanceID(),
                requestedCapabilities: [.view],
                controlTransport: ImmediateTerminalControlTransport(),
                dataTransport: FailingTerminalDataTransport()
            ),
            terminalView: terminalView,
            sessionList: lifecycle.list,
            archiveOpen: lifecycle.openArchive,
            restart: lifecycle.restart
        )
        tab.loadViewIfNeeded()

        var attachError: (any Error)?
        do {
            try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
        } catch {
            attachError = error
        }

        XCTAssertNil(attachError)
        XCTAssertEqual(renderer.applied, [Data("race-final-screen".utf8)])
        XCTAssertEqual(lifecycle.listCallCount, 2)
        XCTAssertEqual(lifecycle.archiveRequests, [sessionID])
        tab.detach()
    }

    func testTerminalTabAttachSubscribesBeforeImmediateInitialFrame() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let sessionID = TerminalSessionID()
        let frame = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("initial".utf8)]
        )
        let connection = ImmediateTerminalDataConnection(frame: frame)
        let controller = TerminalAttachmentController(
            clientInstanceID: ClientInstanceID(),
            requestedCapabilities: [.view],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: ImmediateTerminalDataTransport(connection: connection)
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView
        )
        tab.loadViewIfNeeded()

        try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
        for _ in 0..<200 where renderer.applied.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(renderer.applied, [Data("initial".utf8)])
        tab.detach()
    }

    func testSameSessionExactRendererBaselineSurvivesZeroFrameReattach() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let sessionID = TerminalSessionID()
        terminalView.beginSession(sessionID, preservingAcknowledgedSequence: nil)
        terminalView.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 5,
                outputSequence: 5,
                kind: .snapshot,
                fragments: [Data("baseline".utf8)]
            )
        )
        renderer.resetOperations()

        let connection = ImmediateTerminalDataConnection(frame: nil)
        let transport = RecordingTerminalDataTransport(connection: connection)
        let controller = TerminalAttachmentController(
            clientInstanceID: ClientInstanceID(),
            requestedCapabilities: [.view],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: transport
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView
        )
        tab.loadViewIfNeeded()
        try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: 5)
        for _ in 0..<200 {
            if !(await transport.acknowledgements()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let acknowledgements = await transport.acknowledgements()
        XCTAssertEqual(acknowledgements, [5])
        XCTAssertFalse(renderer.operations.contains("visible:false"))
        XCTAssertEqual(renderer.visibility.last, true)
        tab.detach()
    }

    func testFreshRendererDropsStaleAcknowledgementAndWaitsForSnapshot() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let snapshot = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("fresh".utf8)]
        )
        let connection = ImmediateTerminalDataConnection(frame: snapshot)
        let transport = RecordingTerminalDataTransport(connection: connection)
        let controller = TerminalAttachmentController(
            clientInstanceID: ClientInstanceID(),
            requestedCapabilities: [.view],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: transport
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView
        )
        tab.loadViewIfNeeded()

        try await tab.attach(
            sessionID: TerminalSessionID(),
            lastAcknowledgedSequence: 99
        )
        for _ in 0..<200 where renderer.applied.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let acknowledgements = await transport.acknowledgements()
        XCTAssertEqual(acknowledgements, [nil])
        XCTAssertEqual(renderer.applied, [Data("fresh".utf8)])
        XCTAssertEqual(renderer.visibility.last, true)
        tab.detach()
    }

    func testOverlappingSameSessionAttachCannotLetAnOlderEventResetTheNewBaseline() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let sessionID = TerminalSessionID()
        terminalView.beginSession(sessionID, preservingAcknowledgedSequence: nil)
        terminalView.apply(
            try TerminalOutputFrame(
                firstOutputSequence: 5,
                outputSequence: 5,
                kind: .snapshot,
                fragments: [Data("baseline".utf8)]
            )
        )
        renderer.resetOperations()

        let eventBarrier = OneShotAsyncBarrier()
        let transport = QueueingTerminalDataTransport(
            connections: [
                ImmediateTerminalDataConnection(frame: nil),
                ImmediateTerminalDataConnection(frame: nil),
            ]
        )
        let controller = TerminalAttachmentController(
            clientInstanceID: ClientInstanceID(),
            requestedCapabilities: [.view],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: transport
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView,
            beforeHandlingAttached: { _ in await eventBarrier.pauseOnce() }
        )
        tab.loadViewIfNeeded()

        try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: 5)
        for _ in 0..<200 where !(await eventBarrier.isPaused) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let didPause = await eventBarrier.isPaused
        XCTAssertTrue(didPause)
        try await tab.attach(sessionID: sessionID, lastAcknowledgedSequence: 5)
        await eventBarrier.resume()
        for _ in 0..<200 where await transport.acknowledgements().count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))

        let acknowledgements = await transport.acknowledgements()
        XCTAssertEqual(acknowledgements, [5, 5])
        XCTAssertFalse(renderer.operations.contains("visible:false"))
        XCTAssertEqual(renderer.visibility.last, true)
        tab.detach()
    }

    func testOldSessionFrameDeliveredBeforeNewAttachCannotPolluteNewViewport() async throws {
        let renderer = RecordingGhosttyRenderer()
        let terminalView = GhosttyTerminalView(renderer: renderer)
        let window = TestOcclusionWindow(contentView: terminalView)
        window.testOcclusionState = [.visible]
        terminalView.isTerminalActive = true
        let oldSession = TerminalSessionID()
        let newSession = TerminalSessionID()
        let oldFrame = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("old-session".utf8)]
        )
        let newFrame = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("new-session".utf8)]
        )
        let eventBarrier = OneShotAsyncBarrier()
        let transport = BlockingSecondAttachTransport(
            first: ImmediateTerminalDataConnection(frame: oldFrame),
            second: ImmediateTerminalDataConnection(frame: newFrame)
        )
        let controller = TerminalAttachmentController(
            clientInstanceID: ClientInstanceID(),
            requestedCapabilities: [.view],
            controlTransport: ImmediateTerminalControlTransport(),
            dataTransport: transport
        )
        let tab = TerminalTabViewController(
            attachmentController: controller,
            terminalView: terminalView,
            beforeHandlingAttached: { _ in await eventBarrier.pauseOnce() }
        )
        tab.loadViewIfNeeded()

        try await tab.attach(sessionID: oldSession, lastAcknowledgedSequence: nil)
        for _ in 0..<200 where !(await eventBarrier.isPaused) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let attachedEventPaused = await eventBarrier.isPaused
        XCTAssertTrue(attachedEventPaused)
        let attachingNew = Task {
            try await tab.attach(sessionID: newSession, lastAcknowledgedSequence: nil)
        }
        for _ in 0..<200 where !(await transport.secondAttachIsBlocked) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let secondAttachBlocked = await transport.secondAttachIsBlocked
        XCTAssertTrue(secondAttachBlocked)

        await eventBarrier.resume()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(renderer.applied.contains(Data("old-session".utf8)))

        await transport.releaseSecondAttach()
        try await attachingNew.value
        for _ in 0..<200 where !renderer.applied.contains(Data("new-session".utf8)) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.applied, [Data("new-session".utf8)])
        tab.detach()
    }

    func testTerminalTabDestructionClosesRendererAndReleasesTerminalView() async throws {
        weak var terminalViewReference: GhosttyTerminalView?
        do {
            let terminalView = GhosttyTerminalView(frame: .zero)
            terminalViewReference = terminalView
            let frame = try TerminalOutputFrame(
                firstOutputSequence: 1,
                outputSequence: 1,
                kind: .snapshot,
                fragments: [Data("unused".utf8)]
            )
            var tab: TerminalTabViewController? = TerminalTabViewController(
                attachmentController: TerminalAttachmentController(
                    clientInstanceID: ClientInstanceID(),
                    requestedCapabilities: [.view],
                    controlTransport: ImmediateTerminalControlTransport(),
                    dataTransport: ImmediateTerminalDataTransport(
                        connection: ImmediateTerminalDataConnection(frame: frame)
                    )
                ),
                terminalView: terminalView
            )
            tab?.loadViewIfNeeded()
            XCTAssertNotNil(terminalViewReference)
            tab = nil
        }

        for _ in 0..<200 where terminalViewReference != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(terminalViewReference)
    }
}

@MainActor
private func keyEvent(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}

@MainActor
private final class TestOcclusionWindow: NSWindow {
    var testOcclusionState: NSWindow.OcclusionState = []

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
    }

    override var occlusionState: NSWindow.OcclusionState { testOcclusionState }
}

@MainActor
private final class RecordingGhosttyRenderer: GhosttyRendererDriving {
    private(set) var applied: [Data] = []
    private(set) var visibility: [Bool] = []
    private(set) var operations: [String] = []

    func apply(_ frame: Data) throws -> Bool {
        applied.append(frame)
        operations.append("apply:\(String(decoding: frame, as: UTF8.self))")
        return true
    }
    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool { true }
    func setVisible(_ visible: Bool) -> Bool {
        visibility.append(visible)
        operations.append("visible:\(visible)")
        return true
    }
    func tearDown() {}
    func resetOperations() { operations.removeAll(keepingCapacity: true) }
}

@MainActor
private final class TerminalTabLifecycleRecorder {
    struct RestartCall: Equatable {
        let sessionID: TerminalSessionID
        let profileID: AgentProfileID?
    }

    private var listResults: [[ClientTerminalSession]]
    private let archiveData: Data
    private var pauseRestart = false
    private var restartPaused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var listCallCount = 0
    private(set) var archiveRequests: [TerminalSessionID] = []
    private(set) var restartCalls: [RestartCall] = []

    init(listResults: [[ClientTerminalSession]], archiveData: Data) {
        self.listResults = listResults
        self.archiveData = archiveData
    }

    func list() -> [ClientTerminalSession] {
        listCallCount += 1
        if listResults.count == 1 { return listResults[0] }
        return listResults.removeFirst()
    }

    func openArchive(_ sessionID: TerminalSessionID) throws -> FileHandle {
        archiveRequests.append(sessionID)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: archiveData)
        try pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }

    func pauseNextRestart() { pauseRestart = true }

    func waitUntilRestartPaused() async {
        if restartPaused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resumeRestart() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    func restart(
        _ sessionID: TerminalSessionID,
        _ profileID: AgentProfileID?
    ) async {
        restartCalls.append(.init(sessionID: sessionID, profileID: profileID))
        if pauseRestart {
            pauseRestart = false
            restartPaused = true
            pauseWaiter?.resume()
            pauseWaiter = nil
            await withCheckedContinuation { resumeWaiter = $0 }
            restartPaused = false
        }
    }
}

@MainActor
private final class FailingSecondFragmentGhosttyRenderer: GhosttyRendererDriving {
    private(set) var attempted: [Data] = []
    private(set) var visibility: [Bool] = []
    private var failed = false

    func apply(_ frame: Data) throws -> Bool {
        attempted.append(frame)
        if frame == Data("delta".utf8), !failed {
            failed = true
            throw CocoaError(.coderInvalidValue)
        }
        return true
    }

    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool { true }
    func setVisible(_ visible: Bool) -> Bool {
        visibility.append(visible)
        return true
    }
    func tearDown() {}
}

@MainActor
private final class FailOncePresentationGhosttyRenderer: GhosttyRendererDriving {
    private(set) var presentationAttempts = 0
    private(set) var visibility: [Bool] = []

    func apply(_ frame: Data) throws -> Bool {
        guard frame == Data("delta".utf8) else { return true }
        presentationAttempts += 1
        return presentationAttempts > 1
    }

    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool { true }
    func setVisible(_ visible: Bool) -> Bool {
        visibility.append(visible)
        return true
    }
    func tearDown() {}
}

@MainActor
private final class DrawingCountGhosttyRenderer: GhosttyRendererDriving {
    var presentationCount = 0

    func apply(_ frame: Data) throws -> Bool {
        presentationCount += 1
        return true
    }
    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool { true }
    func setVisible(_ visible: Bool) -> Bool {
        if visible { presentationCount += 1 }
        return true
    }
    func tearDown() {}
}

@MainActor
private final class AlwaysFailPresentationGhosttyRenderer: GhosttyRendererDriving {
    private(set) var presentationAttempts = 0

    func apply(_ frame: Data) throws -> Bool {
        guard frame == Data("delta".utf8) else { return true }
        presentationAttempts += 1
        return false
    }

    func resize(width: UInt32, height: UInt32, scale: Double) -> Bool { true }
    func setVisible(_ visible: Bool) -> Bool { true }
    func tearDown() {}
}

private actor ImmediateTerminalControlTransport: TerminalControlTransport {
    func issueAttachTicket(
        sessionID: TerminalSessionID,
        clientInstanceID: ClientInstanceID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> TerminalAttachAuthorization {
        let workerID = WorkerInstanceID()
        return TerminalAttachAuthorization(
            endpoint: try KeeperEndpoint(
                path: "/private/tmp/cockpit-test/keeper.sock",
                sessionID: sessionID,
                workerID: workerID
            ),
            wireTicket: String(repeating: "A", count: 43),
            binding: TerminalAttachBinding(
                sessionID: sessionID,
                workerID: workerID,
                clientInstanceID: clientInstanceID
            ),
            viewerID: viewerID,
            capabilities: capabilities
        )
    }

    func acquireInputLease(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> InputLeaseGrant {
        try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: viewerID,
            sequenceBase: 1,
            capabilities: capabilities
        )
    }

    func releaseInputLease(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    ) async throws {}

    func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32 { 404 }

    func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws {}
}

private struct ImmediateTerminalDataTransport: TerminalDataTransport {
    let connection: ImmediateTerminalDataConnection

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        connection
    }
}

private struct SerialTerminalDataTransport: TerminalDataTransport {
    let connection: SerialTerminalDataConnection

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        connection
    }
}

private enum SerialTerminalInputError: Error { case rejected }

private actor SerialTerminalDataConnection: TerminalDataConnection {
    private var outputWaiter: CheckedContinuation<TerminalOutputFrame?, Never>?
    private var firstSendWaiter: CheckedContinuation<Void, Never>?
    private var payloadToFail: TerminalInput.Payload?
    private(set) var payloads: [TerminalInput.Payload] = []

    var firstSendIsBlocked: Bool { firstSendWaiter != nil }

    func nextOutput() async throws -> TerminalOutputFrame? {
        await withCheckedContinuation { outputWaiter = $0 }
    }

    func send(_ input: TerminalInput) async throws -> UInt64 {
        payloads.append(input.payload)
        if payloads.count == 1 {
            await withCheckedContinuation { firstSendWaiter = $0 }
        }
        if payloadToFail == input.payload {
            payloadToFail = nil
            throw SerialTerminalInputError.rejected
        }
        return input.inputSequence
    }

    func setVisible(_ visible: Bool) async throws {}

    func detach() async {
        firstSendWaiter?.resume()
        firstSendWaiter = nil
        outputWaiter?.resume(returning: nil)
        outputWaiter = nil
    }

    func releaseFirstSend() {
        firstSendWaiter?.resume()
        firstSendWaiter = nil
    }

    func failNextPayload(_ payload: TerminalInput.Payload) {
        payloadToFail = payload
    }
}

private struct FailingTerminalDataTransport: TerminalDataTransport {
    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        throw CocoaError(.fileReadUnknown)
    }
}

private struct FiniteTerminalDataTransport: TerminalDataTransport {
    let connection: FiniteTerminalDataConnection

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        connection
    }
}

private actor FiniteTerminalDataConnection: TerminalDataConnection {
    private var frames: [TerminalOutputFrame]

    init(frames: [TerminalOutputFrame]) { self.frames = frames }

    func nextOutput() async throws -> TerminalOutputFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    func send(_ input: TerminalInput) async throws -> UInt64 { input.inputSequence }
    func setVisible(_ visible: Bool) async throws {}
    func detach() async {}
}

private actor RecordingTerminalDataTransport: TerminalDataTransport {
    let connection: ImmediateTerminalDataConnection
    private var receivedAcknowledgements: [UInt64?] = []

    init(connection: ImmediateTerminalDataConnection) {
        self.connection = connection
    }

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        receivedAcknowledgements.append(lastAcknowledgedSequence)
        return connection
    }

    func acknowledgements() -> [UInt64?] { receivedAcknowledgements }
}

private actor QueueingTerminalDataTransport: TerminalDataTransport {
    private var connections: [ImmediateTerminalDataConnection]
    private var receivedAcknowledgements: [UInt64?] = []

    init(connections: [ImmediateTerminalDataConnection]) {
        self.connections = connections
    }

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        receivedAcknowledgements.append(lastAcknowledgedSequence)
        return connections.removeFirst()
    }

    func acknowledgements() -> [UInt64?] { receivedAcknowledgements }
}

private actor BlockingSecondAttachTransport: TerminalDataTransport {
    private let first: ImmediateTerminalDataConnection
    private let second: ImmediateTerminalDataConnection
    private var count = 0
    private var secondContinuation: CheckedContinuation<Void, Never>?

    init(
        first: ImmediateTerminalDataConnection,
        second: ImmediateTerminalDataConnection
    ) {
        self.first = first
        self.second = second
    }

    var secondAttachIsBlocked: Bool { secondContinuation != nil }

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        count += 1
        if count == 1 { return first }
        await withCheckedContinuation { secondContinuation = $0 }
        return second
    }

    func releaseSecondAttach() {
        secondContinuation?.resume()
        secondContinuation = nil
    }
}

private actor OneShotAsyncBarrier {
    private var paused = false
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isPaused: Bool { paused }

    func pauseOnce() async {
        guard !paused else { return }
        paused = true
        if resumed { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ImmediateTerminalDataConnection: TerminalDataConnection {
    private var frame: TerminalOutputFrame?
    private var waiter: CheckedContinuation<TerminalOutputFrame?, Never>?

    init(frame: TerminalOutputFrame?) { self.frame = frame }

    func nextOutput() async throws -> TerminalOutputFrame? {
        if let frame {
            self.frame = nil
            return frame
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func send(_ input: TerminalInput) async throws -> UInt64 { input.inputSequence }
    func setVisible(_ visible: Bool) async throws {}
    func detach() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

@MainActor
private func descendant<View: NSView>(
    in root: NSView,
    identifier: String
) -> View? {
    if root.identifier?.rawValue == identifier, let value = root as? View {
        return value
    }
    for subview in root.subviews {
        if let value: View = descendant(in: subview, identifier: identifier) {
            return value
        }
    }
    return nil
}

private func terminalClientSession(
    sessionID: TerminalSessionID,
    lifecycle: TerminalLifecycleState,
    kind: TerminalKind,
    exitStatus: Int32? = nil,
    latestSequence: UInt64 = 0,
    archiveAvailable: Bool = false
) throws -> ClientTerminalSession {
    let launchSpec = try LaunchSpec(
        kind: kind,
        loginShellPath: "/bin/zsh",
        executablePath: kind == .shell ? "/bin/zsh" : "/usr/bin/true",
        arguments: [],
        workspaceRoot: "/tmp",
        terminalSize: TerminalResize(validatingColumns: 80, rows: 24),
        environmentOverrides: [:]
    )
    return try ClientTerminalSession(validating: TerminalSessionRecord(
        validatingSessionID: sessionID,
        contextID: .project(ProjectID()),
        environmentID: EnvironmentID(),
        protocolVersion: .current,
        launchSpecData: JSONEncoder().encode(launchSpec),
        lifecycleState: lifecycle,
        startNonce: Data(repeating: 1, count: 16),
        workerID: WorkerInstanceID(),
        exitStatus: exitStatus,
        latestSequence: latestSequence,
        archiveManifest: archiveAvailable
            ? try RelativeArchivePath(validating: "\(sessionID)/manifest.json")
            : nil
    ))
}
