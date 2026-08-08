import AppKit
import Foundation
import WebKit
import XCTest
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import Cockpit

@MainActor
final class MonacoBridgeTests: XCTestCase {
    func testOneInjectedWKWebViewSurvivesContentProcessGenerationRestart() throws {
        let fixture = makeBridgeFixture()
        var factoryCalls = 0
        var created: WKWebView?
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL(),
            webViewFactory: { configuration in
                factoryCalls += 1
                let value = WKWebView(frame: .zero, configuration: configuration)
                created = value
                return value
            }
        )
        let original = controller.webView

        controller.webViewWebContentProcessDidTerminate(original)

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(original === created)
        XCTAssertTrue(original === controller.webView)
        XCTAssertEqual(fixture.bridge.webContentGeneration, 2)
        XCTAssertTrue(original.configuration.userContentController.userScripts.contains {
            $0.injectionTime == .atDocumentStart
                && $0.isForMainFrameOnly
                && $0.source == "globalThis.cockpitWebContentGeneration = 2;"
        })
        controller.tearDown()
    }

    func testRuntimeBundleCSPIsFirstHeadElementAndBlocksNetworkSubresources() async throws {
        let bundle = runtimeBundleURL()
        let index = bundle.appendingPathComponent("index.html")
        let html = try String(contentsOf: index, encoding: .utf8)
        let csp = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self'; font-src 'self'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; manifest-src 'none'; base-uri 'none'; form-action 'none'"
        guard html.contains("<head><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">") else {
            throw MonacoTestScaffoldFailure.missingCSP
        }

        let webView = WKWebView(frame: .zero)
        let waiter = NavigationWaiter(testCase: self)
        webView.navigationDelegate = waiter
        webView.loadFileURL(index, allowingReadAccessTo: bundle)
        await fulfillment(of: [waiter.finished], timeout: 10)
        let result = try await webView.callAsyncJavaScript(
            """
            const fetchBlocked = await fetch('https://example.invalid/cockpit-csp')
              .then(() => false, () => true);
            const imageBlocked = await new Promise(resolve => {
              const image = new Image();
              image.onload = () => resolve(false);
              image.onerror = () => resolve(true);
              image.src = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';
            });
            const socketBlocked = await new Promise(resolve => {
              let settled = false;
              const done = value => { if (!settled) { settled = true; resolve(value); } };
              try {
                const socket = new WebSocket('wss://example.invalid/cockpit-csp');
                socket.onopen = () => done(false);
                socket.onerror = () => done(true);
              } catch (_) { done(true); }
              setTimeout(() => done(true), 1000);
            });
            return { fetchBlocked, imageBlocked, socketBlocked };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Bool]
        XCTAssertEqual(result, [
            "fetchBlocked": true,
            "imageBlocked": true,
            "socketBlocked": true,
        ])
    }

    func testNewWindowAndExternalNavigationAreFailClosed() async throws {
        let fixture = makeBridgeFixture()
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        let waiter = try await waitForRuntimeLoad(controller.webView)
        XCTAssertTrue(waiter)
        let opened = try await controller.webView.callAsyncJavaScript(
            "return window.open('https://example.invalid/cockpit-window') === null",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertEqual(opened, true)
        XCTAssertFalse(controller.allowsNavigation(
            URL(string: "https://example.invalid")!,
            isMainFrame: true,
            opensNewWindow: false,
            isDownload: false
        ))
        XCTAssertFalse(controller.allowsNavigation(
            URL(fileURLWithPath: "/tmp/outside.html"),
            isMainFrame: true,
            opensNewWindow: false,
            isDownload: false
        ))
        controller.tearDown()
    }

    func testWeakHandlerTearDownAndDeinitReleaseOwnerBridgeForwarderAndWebView() {
        weak var weakOwner: TestWindowOwner?
        weak var weakBridge: MonacoBridge?
        weak var weakForwarder: WeakMonacoScriptMessageHandler?
        weak var weakWebView: WKWebView?
        autoreleasepool {
            var owner: TestWindowOwner? = TestWindowOwner(runtimeBundleURL: runtimeBundleURL())
            weakOwner = owner
            weakBridge = owner?.bridge
            weakForwarder = owner?.controller.forwarder
            weakWebView = owner?.controller.webView
            owner?.controller.tearDown()
            owner?.controller.tearDown()
            owner = nil
        }
        XCTAssertNil(weakOwner)
        XCTAssertNil(weakBridge)
        XCTAssertNil(weakForwarder)
        XCTAssertNil(weakWebView)
    }

    func testURIUsesUppercaseByteEncodingWithoutUnicodeNormalization() throws {
        let environmentID = EnvironmentID(UUID(uuidString: "77777777-7777-4777-8777-777777777777")!)
        let path = try RelativePath("目录/100% ready/e\u{301}.ts")
        XCTAssertEqual(
            try MonacoFileURI.make(environmentID: environmentID, path: path),
            "cockpit-file://77777777-7777-4777-8777-777777777777/%E7%9B%AE%E5%BD%95/100%25%20ready/e%CC%81.ts"
        )
    }

    func testAMessageDecoderEnforcesExactKeysAndStaleGeneration() async throws {
        let fixture = makeBridgeFixture()
        let ready = ["type": "ready", "webContentGeneration": 1] as [String: Any]
        XCTAssertEqual(try MonacoMessageCodec.decode(ready), .ready(webContentGeneration: 1))
        XCTAssertThrowsError(try MonacoMessageCodec.decode([
            "type": "ready", "webContentGeneration": 1, "extra": true,
        ])) { XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema) }
        _ = try await fixture.bridge.prepareForWebContentRestart(generation: 2)
        let staleReply = await fixture.bridge.handleMessageBody(ready)
        XCTAssertEqual(staleReply, .failure(.staleGeneration))
    }

    func testTabIDAwareEditRoutesOnlyExactReferenceAndControllerGeneratesSequence() async throws {
        let clientID = ClientInstanceID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let tabID = TabID()
        let otherTabID = TabID()
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("src/main.ts")
        )
        let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
        _ = try await controller.open(in: environmentID, at: RelativePath("src/main.ts"), requestWriteAccess: true)
        let fixture = makeBridgeFixture(clientID: clientID)
        try fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID,
            controller: controller,
            language: "typescript"
        )
        let body = try editBody(
            generation: 1,
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID,
            environmentID: environmentID,
            leaseID: try await transport.leaseID(),
            changes: [["offset": 0, "length": 0, "replacement": "x"]]
        )
        var mismatched = body
        mismatched["tabID"] = otherTabID.description
        let mismatchedReply = await fixture.bridge.handleMessageBody(mismatched)
        let metricsBeforeEdit = await transport.metrics()
        XCTAssertEqual(mismatchedReply, .failure(.unknownDocument))
        XCTAssertEqual(metricsBeforeEdit.applyCount, 0)

        let reply = await fixture.bridge.handleMessageBody(body)
        guard case let .success(.acknowledgement(_, _, acknowledgement)) = reply else {
            return XCTFail("expected acknowledgement, got \(reply)")
        }
        XCTAssertEqual(acknowledgement.clientSequence, 1)
        let metricsAfterEdit = await transport.metrics()
        XCTAssertEqual(metricsAfterEdit.applyCount, 1)
        XCTAssertEqual(metricsAfterEdit.lastTransaction?.clientSequence, 1)
    }

    func testSameContextDocumentTwoTabsKeepIndependentViewStates() async throws {
        let clientID = ClientInstanceID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let firstTab = TabID()
        let secondTab = TabID()
        let store = ViewStateRecorder()
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("shared.txt")
        )
        let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
        _ = try await controller.open(in: environmentID, at: RelativePath("shared.txt"), requestWriteAccess: true)
        let fixture = makeBridgeFixture(clientID: clientID, recorder: store)
        for tab in [firstTab, secondTab] {
            try fixture.resolver.retain(
                contextID: fixture.contextID,
                tabID: tab,
                documentID: documentID,
                controller: controller,
                language: "plaintext"
            )
        }
        let first = try makeViewState(line: 3)
        let second = try makeViewState(line: 9)
        let lease = try await transport.leaseID()
        let firstReply = await fixture.bridge.handleMessageBody(try viewStateBody(
            contextID: fixture.contextID, tabID: firstTab, documentID: documentID,
            environmentID: environmentID, path: "shared.txt", leaseID: lease, value: first
        ))
        let secondReply = await fixture.bridge.handleMessageBody(try viewStateBody(
            contextID: fixture.contextID, tabID: secondTab, documentID: documentID,
            environmentID: environmentID, path: "shared.txt", leaseID: lease, value: second
        ))
        let storedFirst = await store.value(contextID: fixture.contextID, tabID: firstTab, documentID: documentID)
        let storedSecond = await store.value(contextID: fixture.contextID, tabID: secondTab, documentID: documentID)
        XCTAssertEqual(firstReply, .success(nil))
        XCTAssertEqual(secondReply, .success(nil))
        XCTAssertEqual(storedFirst, first)
        XCTAssertEqual(storedSecond, second)
    }

    func testRemoteOwnerLeaseIsExposedReadOnlyAsNilFalse() async throws {
        let localClient = ClientInstanceID()
        let remoteClient = ClientInstanceID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let tabID = TabID()
        let transport = try TestDocumentTransport.readOnly(
            remoteClientID: remoteClient,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("remote.txt")
        )
        let controller = DocumentClientController(clientInstanceID: localClient, transport: transport)
        _ = try await controller.open(in: environmentID, at: RelativePath("remote.txt"), requestWriteAccess: false)
        let fixture = makeBridgeFixture(clientID: localClient)
        try fixture.resolver.retain(
            contextID: fixture.contextID, tabID: tabID, documentID: documentID,
            controller: controller, language: "plaintext"
        )
        let saveReply = await fixture.bridge.handleMessageBody(try saveBody(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID,
            environmentID: environmentID,
            path: "remote.txt",
            leaseID: nil,
            writable: false
        ))
        let saveMetrics = await transport.metrics()
        XCTAssertEqual(saveReply, .failure(.readOnly))
        XCTAssertEqual(saveMetrics.saveCount, 0)
    }

    func testFingerprintRecoveryMapsToStaleDocumentStateWithoutStaleReplace() async throws {
        let session = try await makeReadySession(path: "save.txt")
        await session.transport.setSaveError(.recoveryRequired)
        let before = session.fixture.sink.messages.count
        let reply = await session.fixture.bridge.handleMessageBody(try saveBody(
            contextID: session.fixture.contextID,
            tabID: session.tabID,
            documentID: session.documentID,
            environmentID: session.environmentID,
            path: "save.txt",
            leaseID: await session.transport.leaseID(),
            writable: true
        ))
        XCTAssertEqual(reply, .failure(.staleDocumentState))
        XCTAssertEqual(session.fixture.sink.messages.count, before)
        let controllerState = await session.controller.state
        XCTAssertEqual(controllerState, .resynchronizing)
    }

    func testRelocationUnopenedSourceCompletesEmptyWithoutHostCall() async throws {
        let fixture = makeBridgeFixture()
        let source = try RelativePath("not-open.txt")
        let token = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: .rename(source: source, newName: "renamed.txt")
        )
        XCTAssertEqual(token.affectedDocumentIDs, [])
        let disposition = try await fixture.bridge.commitRelocation(
            token,
            result: .relocated(from: source, to: RelativePath("renamed.txt"))
        )
        XCTAssertEqual(disposition, .complete)
    }

    func testDirectoryRelocationFlushesOwnedReadyOnlyAndMigratesReadyReadOnlyCrossContextRefs() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let ready = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "dir/owned.txt",
            writable: true,
            contexts: [fixture.contextID, .conversation(ConversationID())]
        )
        let readOnly = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "dir/read-only.txt",
            writable: false,
            contexts: [fixture.contextID]
        )
        let source = try RelativePath("dir")
        let token = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: .move(source: source, destinationDirectory: .relative(RelativePath("archive")))
        )
        XCTAssertEqual(token.affectedDocumentIDs, [ready.documentID, readOnly.documentID].sorted(by: idLess))
        let readyPrepareMetrics = await ready.transport.metrics()
        let readOnlyPrepareMetrics = await readOnly.transport.metrics()
        XCTAssertEqual(readyPrepareMetrics.flushCount, 1)
        XCTAssertEqual(readOnlyPrepareMetrics.flushCount, 0)
        try await ready.transport.setSnapshotPath(RelativePath("archive/dir/owned.txt"))
        try await readOnly.transport.setSnapshotPath(RelativePath("archive/dir/read-only.txt"))

        let disposition = try await fixture.bridge.commitRelocation(
            token,
            result: .relocated(from: source, to: RelativePath("archive/dir"))
        )
        XCTAssertEqual(disposition, .complete)
        let readyCommitMetrics = await ready.transport.metrics()
        let readOnlyCommitMetrics = await readOnly.transport.metrics()
        let readOnlyControllerState = await readOnly.controller.state
        XCTAssertEqual(readyCommitMetrics.writeAccessRequests.last, true)
        XCTAssertTrue(readOnlyCommitMetrics.writeAccessRequests.isEmpty)
        guard case .readOnly = readOnlyControllerState else {
            return XCTFail("read-only relocation must resynchronize without write access")
        }
        XCTAssertEqual(fixture.sink.renameCount(documentID: ready.documentID), ready.tabIDs.count)
        XCTAssertEqual(fixture.sink.renameCount(documentID: readOnly.documentID), readOnly.tabIDs.count)
    }

    func testRelocationPartialCommitRetriesOnlyPendingDocuments() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let first = try await attachSession(
            fixture: fixture, clientID: clientID, path: "dir/a.txt",
            writable: true, contexts: [fixture.contextID]
        )
        let second = try await attachSession(
            fixture: fixture, clientID: clientID, path: "dir/b.txt",
            writable: true, contexts: [fixture.contextID]
        )
        try await first.transport.setSnapshotPath(RelativePath("renamed/a.txt"))
        try await second.transport.setSnapshotPath(RelativePath("renamed/b.txt"))
        let successful = idLess(first.documentID, second.documentID) ? first : second
        let pending = idLess(first.documentID, second.documentID) ? second : first
        await pending.transport.failNextSnapshots(1)
        let source = try RelativePath("dir")
        let token = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: .rename(source: source, newName: "renamed")
        )
        let initialDisposition = try await fixture.bridge.commitRelocation(
            token,
            result: .relocated(from: source, to: RelativePath("renamed"))
        )
        XCTAssertEqual(initialDisposition, .incomplete(pendingDocumentIDs: [pending.documentID]))
        let successfulSnapshotCalls = await successful.transport.metrics().snapshotCount
        let retryDisposition = try await fixture.bridge.retryRelocation(token)
        let successfulRetryMetrics = await successful.transport.metrics()
        let pendingRetryMetrics = await pending.transport.metrics()
        XCTAssertEqual(retryDisposition, .complete)
        XCTAssertEqual(successfulRetryMetrics.snapshotCount, successfulSnapshotCalls)
        XCTAssertEqual(pendingRetryMetrics.snapshotCount, 2)
    }

    func testCommittedRelocationCannotCancelAndAbandonMakesAllAffectedStale() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let session = try await attachSession(
            fixture: fixture, clientID: clientID, path: "dir/fail.txt",
            writable: true, contexts: [fixture.contextID]
        )
        try await session.transport.setSnapshotPath(RelativePath("renamed/fail.txt"))
        await session.transport.failNextSnapshots(2)
        let source = try RelativePath("dir")
        let token = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: .rename(source: source, newName: "renamed")
        )
        let disposition = try await fixture.bridge.commitRelocation(
            token,
            result: .relocated(from: source, to: RelativePath("renamed"))
        )
        XCTAssertEqual(disposition, .incomplete(pendingDocumentIDs: [session.documentID]))
        XCTAssertThrowsError(try fixture.bridge.cancelRelocation(token)) {
            XCTAssertEqual($0 as? MonacoBridgeError, .staleDocumentState)
        }
        XCTAssertEqual(
            try fixture.bridge.abandonCommittedRelocation(token),
            .abandonedAllStale
        )
        let reply = await fixture.bridge.handleMessageBody(try saveBody(
            contextID: fixture.contextID,
            tabID: session.tabIDs[0],
            documentID: session.documentID,
            environmentID: session.environmentID,
            path: "dir/fail.txt",
            leaseID: await session.transport.leaseID(),
            writable: true
        ))
        XCTAssertEqual(reply, .failure(.resynchronizing))
    }

    func testRelocationRejectsNonOwnerClosedAndResynchronizingWithoutTokenOrFlush() async throws {
        let clientID = ClientInstanceID()
        let cases: [(MonacoBridgeError, Bool, Bool)] = [
            (.staleDocumentState, true, false),
            (.unknownDocument, false, false),
            (.resynchronizing, true, true),
        ]
        for (expectedError, opens, forceResync) in cases {
            let fixture = makeBridgeFixture(clientID: clientID)
            let documentID = DocumentID()
            let environmentID = EnvironmentID()
            let transport = try TestDocumentTransport.ready(
                clientID: ClientInstanceID(),
                documentID: documentID,
                environmentID: environmentID,
                path: RelativePath("blocked.txt")
            )
            let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
            if opens {
                _ = try await controller.open(
                    in: environmentID,
                    at: RelativePath("blocked.txt"),
                    requestWriteAccess: true
                )
            }
            if forceResync { await transport.setFlushError(.recoveryRequired) }
            if forceResync { _ = try? await controller.flush() }
            try fixture.resolver.retain(
                contextID: fixture.contextID, tabID: TabID(), documentID: documentID,
                controller: controller, language: "plaintext"
            )
            do {
                _ = try await fixture.bridge.prepareRelocation(
                    workspaceContextID: fixture.contextID,
                    operation: .rename(source: RelativePath("blocked.txt"), newName: "new.txt")
                )
                XCTFail("expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? MonacoBridgeError, expectedError)
            }
            let metrics = await transport.metrics()
            XCTAssertEqual(metrics.flushCount, forceResync ? 1 : 0)
        }
    }

    func testSameWKWebViewCrashReadyRebuildsAllSessionsRestoresSelectedRefAndSkipsFailedText() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let first = try await attachSession(
            fixture: fixture, clientID: clientID, path: "a.txt",
            writable: true, contexts: [fixture.contextID]
        )
        let second = try await attachSession(
            fixture: fixture, clientID: clientID, path: "b.txt",
            writable: true, contexts: [fixture.contextID]
        )
        try fixture.resolver.select(
            contextID: fixture.contextID,
            tabID: first.tabIDs[0],
            documentID: first.documentID
        )
        await second.transport.failNextSnapshots(1)
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        fixture.bridge.setSink { fixture.sink.append($0) }
        let webView = controller.webView
        controller.webViewWebContentProcessDidTerminate(webView)
        XCTAssertTrue(webView === controller.webView)
        let readyReply = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(readyReply, .success(nil))
        XCTAssertEqual(fixture.sink.openCount(documentID: first.documentID), 1)
        XCTAssertEqual(fixture.sink.openCount(documentID: second.documentID), 0)
        XCTAssertEqual(fixture.sink.lastSelected?.reference.tabID, first.tabIDs[0])
        XCTAssertEqual(fixture.errors.values[second.documentID], .transportFailure)
        controller.tearDown()
    }
}

private enum MonacoTestScaffoldFailure: Error {
    case missingCSP
}

@MainActor
private final class TestWindowOwner {
    let bridge: MonacoBridge
    let controller: MonacoEditorViewController

    init(runtimeBundleURL: URL) {
        let fixture = makeBridgeFixture()
        bridge = fixture.bridge
        controller = MonacoEditorViewController(
            bridge: bridge,
            runtimeBundleURL: runtimeBundleURL
        )
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    init(testCase: XCTestCase) {
        finished = testCase.expectation(description: "WKWebView navigation")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("navigation failed: \(error)")
        finished.fulfill()
    }
}

@MainActor
private func waitForRuntimeLoad(_ webView: WKWebView) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if webView.isLoading == false,
           (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
            return true
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private actor ViewStateRecorder {
    private var values: [MonacoDocumentReference: DocumentViewState] = [:]
    func load(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) -> DocumentViewState? {
        values[MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )]
    }
    func store(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID,
        value: DocumentViewState
    ) {
        values[MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )] = value
    }
    func value(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) -> DocumentViewState? {
        load(contextID: contextID, tabID: tabID, documentID: documentID)
    }
}

@MainActor
private final class MessageSink {
    var messages: [MonacoNativeMessage] = []
    func append(_ message: MonacoNativeMessage) { messages.append(message) }
    func renameCount(documentID: DocumentID) -> Int {
        messages.count {
            guard case let .renameModel(_, access, _, _, _, _) = $0 else { return false }
            return access.reference.documentID == documentID
        }
    }
    func openCount(documentID: DocumentID) -> Int {
        messages.count {
            guard case let .open(_, access, _, _, _) = $0 else { return false }
            return access.reference.documentID == documentID
        }
    }
    var lastSelected: MonacoDocumentAccess? {
        messages.reversed().compactMap { message -> MonacoDocumentAccess? in
            guard case let .selectModel(_, access, _) = message else { return nil }
            return access
        }.first
    }
}

@MainActor
private final class ErrorRecorder {
    var values: [DocumentID: MonacoBridgeError] = [:]
}

@MainActor
private struct BridgeFixture {
    let contextID: WorkspaceContextID
    let resolver: MonacoWindowSessionResolver
    let sink: MessageSink
    let errors: ErrorRecorder
    let bridge: MonacoBridge
}

@MainActor
private func makeBridgeFixture(
    clientID: ClientInstanceID = ClientInstanceID(),
    recorder: ViewStateRecorder = ViewStateRecorder()
) -> BridgeFixture {
    let contextID = WorkspaceContextID.project(ProjectID())
    let sink = MessageSink()
    let errors = ErrorRecorder()
    let resolver = MonacoWindowSessionResolver(
        clientInstanceID: clientID,
        loadViewState: { contextID, tabID, documentID in
            await recorder.load(contextID: contextID, tabID: tabID, documentID: documentID)
        },
        storeViewState: { contextID, tabID, documentID, value in
            await recorder.store(
                contextID: contextID,
                tabID: tabID,
                documentID: documentID,
                value: value
            )
        }
    )
    let bridge = MonacoBridge(
        resolver: resolver,
        sink: { sink.append($0) },
        ownerErrorHandler: { errors.values[$0] = $1 }
    )
    return BridgeFixture(
        contextID: contextID,
        resolver: resolver,
        sink: sink,
        errors: errors,
        bridge: bridge
    )
}

private struct TransportMetrics: Sendable {
    var applyCount = 0
    var flushCount = 0
    var saveCount = 0
    var snapshotCount = 0
    var lastTransaction: EditTransaction?
    var writeAccessRequests: [Bool] = []
}

private actor TestDocumentTransport: DocumentDataTransport {
    private var current: DocumentSnapshot
    private let acquired: EditLease
    private var values = TransportMetrics()
    private var saveError: DocumentProtocolError?
    private var flushError: DocumentProtocolError?
    private var snapshotFailures = 0

    init(current: DocumentSnapshot, acquired: EditLease) {
        self.current = current
        self.acquired = acquired
    }

    static func ready(
        clientID: ClientInstanceID,
        documentID: DocumentID,
        environmentID: EnvironmentID,
        path: RelativePath
    ) throws -> TestDocumentTransport {
        let lease = try EditLease(
            validatingID: EditLeaseID(),
            documentID: documentID,
            clientInstanceID: clientID
        )
        return try TestDocumentTransport(
            current: makeSnapshot(
                documentID: documentID,
                environmentID: environmentID,
                path: path,
                lease: nil
            ),
            acquired: lease
        )
    }

    static func readOnly(
        remoteClientID: ClientInstanceID,
        documentID: DocumentID,
        environmentID: EnvironmentID,
        path: RelativePath
    ) throws -> TestDocumentTransport {
        let remote = try EditLease(
            validatingID: EditLeaseID(),
            documentID: documentID,
            clientInstanceID: remoteClientID
        )
        return try TestDocumentTransport(
            current: makeSnapshot(
                documentID: documentID,
                environmentID: environmentID,
                path: path,
                lease: remote
            ),
            acquired: remote
        )
    }

    func openDocument(in environmentID: EnvironmentID, at path: RelativePath) throws -> DocumentSnapshot {
        current
    }
    func snapshot(documentID: DocumentID) throws -> DocumentSnapshot {
        values.snapshotCount += 1
        if snapshotFailures > 0 {
            snapshotFailures -= 1
            throw DocumentProtocolError.recoveryRequired
        }
        return current
    }
    func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) throws -> EditLease {
        values.writeAccessRequests.append(true)
        return acquired
    }
    func transferEditLease(
        documentID: DocumentID,
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) throws -> EditLease { acquired }
    func apply(_ transaction: EditTransaction) throws -> EditAcknowledgement {
        values.applyCount += 1
        values.lastTransaction = transaction
        return try EditAcknowledgement(
            validatingDocumentID: transaction.documentID,
            clientSequence: transaction.clientSequence,
            documentVersion: max(transaction.baseVersion + 1, transaction.clientSequence)
        )
    }
    func flush(documentID: DocumentID, through clientSequence: UInt64) throws -> UInt64 {
        values.flushCount += 1
        if let flushError { throw flushError }
        return current.documentVersion
    }
    func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) throws -> DocumentSnapshot {
        values.saveCount += 1
        if let saveError { throw saveError }
        return current
    }
    func discard(documentID: DocumentID) throws -> DocumentSnapshot { current }
    func metrics() -> TransportMetrics { values }
    func leaseID() -> EditLeaseID { acquired.id }
    func setSaveError(_ error: DocumentProtocolError?) { saveError = error }
    func setFlushError(_ error: DocumentProtocolError?) { flushError = error }
    func failNextSnapshots(_ count: Int) { snapshotFailures = count }
    func setSnapshotPath(_ path: RelativePath) throws {
        current = try makeSnapshot(
            documentID: current.documentID,
            environmentID: current.environmentID,
            path: path,
            text: current.text,
            documentVersion: current.documentVersion,
            lease: current.currentLease
        )
    }
}

private struct ReadySession {
    let fixture: BridgeFixture
    let controller: DocumentClientController
    let transport: TestDocumentTransport
    let documentID: DocumentID
    let environmentID: EnvironmentID
    let tabID: TabID
}

@MainActor
private func makeReadySession(path: String) async throws -> ReadySession {
    let clientID = ClientInstanceID()
    let documentID = DocumentID()
    let environmentID = EnvironmentID()
    let tabID = TabID()
    let transport = try TestDocumentTransport.ready(
        clientID: clientID,
        documentID: documentID,
        environmentID: environmentID,
        path: RelativePath(path)
    )
    let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
    _ = try await controller.open(in: environmentID, at: RelativePath(path), requestWriteAccess: true)
    let fixture = makeBridgeFixture(clientID: clientID)
    try fixture.resolver.retain(
        contextID: fixture.contextID, tabID: tabID, documentID: documentID,
        controller: controller, language: "plaintext"
    )
    return ReadySession(
        fixture: fixture,
        controller: controller,
        transport: transport,
        documentID: documentID,
        environmentID: environmentID,
        tabID: tabID
    )
}

private struct AttachedSession {
    let controller: DocumentClientController
    let transport: TestDocumentTransport
    let documentID: DocumentID
    let environmentID: EnvironmentID
    let tabIDs: [TabID]
}

@MainActor
private func attachSession(
    fixture: BridgeFixture,
    clientID: ClientInstanceID,
    path: String,
    writable: Bool,
    contexts: [WorkspaceContextID]
) async throws -> AttachedSession {
    let documentID = DocumentID()
    let environmentID = EnvironmentID()
    let transport = writable
        ? try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath(path)
        )
        : try TestDocumentTransport.readOnly(
            remoteClientID: ClientInstanceID(),
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath(path)
        )
    let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
    _ = try await controller.open(
        in: environmentID,
        at: RelativePath(path),
        requestWriteAccess: writable
    )
    var tabIDs: [TabID] = []
    for context in contexts {
        let tabID = TabID()
        tabIDs.append(tabID)
        try fixture.resolver.retain(
            contextID: context,
            tabID: tabID,
            documentID: documentID,
            controller: controller,
            language: "plaintext"
        )
        try await fixture.resolver.storeViewState(
            context,
            tabID,
            documentID,
            try makeViewState(line: UInt64(tabIDs.count))
        )
    }
    return AttachedSession(
        controller: controller,
        transport: transport,
        documentID: documentID,
        environmentID: environmentID,
        tabIDs: tabIDs
    )
}

private func makeSnapshot(
    documentID: DocumentID,
    environmentID: EnvironmentID,
    path: RelativePath,
    text: String = "authoritative\n",
    documentVersion: UInt64 = 0,
    lease: EditLease?
) throws -> DocumentSnapshot {
    try DocumentSnapshot(
        validatingDocumentID: documentID,
        environmentID: environmentID,
        relativePath: path,
        text: text,
        documentVersion: documentVersion,
        persistedVersion: 0,
        lastAcceptedClientSequence: 0,
        dirtyState: .clean,
        observedDiskFingerprint: DiskFingerprint(
            deviceID: 1,
            inode: 2,
            byteCount: UInt64(text.utf8.count),
            modificationTimeSeconds: 3,
            modificationTimeNanoseconds: 4,
            contentSHA256: try SHA256Digest(validating: Data(repeating: 5, count: 32))
        ),
        currentLease: lease,
        maintenance: []
    )
}

private func makeViewState(line: UInt64) throws -> DocumentViewState {
    let position = try TextPosition(validatingLine: line, column: 2)
    return try DocumentViewState(
        validatingCursor: position,
        selections: [TextRange(validatingAnchor: position, active: position)],
        firstVisibleLine: line,
        horizontalScrollOffset: Double(line)
    )
}

private func idLess(_ left: DocumentID, _ right: DocumentID) -> Bool {
    left.description < right.description
}

private func runtimeBundleURL() -> URL {
    let url = Bundle.main.url(forResource: "MonacoRuntime", withExtension: "bundle")
    XCTAssertNotNil(url, "MonacoRuntime.bundle must be embedded in the host app")
    return url ?? URL(fileURLWithPath: "/missing/MonacoRuntime.bundle")
}

private func contextWire(_ contextID: WorkspaceContextID) -> [String: Any] {
    switch contextID {
    case let .project(value): ["kind": "project", "projectID": value.description]
    case let .conversation(value): ["kind": "conversation", "conversationID": value.description]
    }
}

private func commonBody(
    type: String,
    contextID: WorkspaceContextID,
    tabID: TabID,
    documentID: DocumentID,
    environmentID: EnvironmentID,
    path: RelativePath,
    leaseID: EditLeaseID?,
    writable: Bool
) throws -> [String: Any] {
    [
        "type": type,
        "webContentGeneration": 1,
        "workspaceContextID": contextWire(contextID),
        "tabID": tabID.description,
        "documentID": documentID.description,
        "uri": try MonacoFileURI.make(environmentID: environmentID, path: path),
        "lastAcceptedClientSequence": 0,
        "editLeaseID": leaseID?.description as Any,
        "writable": writable,
    ]
}

private func editBody(
    generation: UInt64,
    contextID: WorkspaceContextID,
    tabID: TabID,
    documentID: DocumentID,
    environmentID: EnvironmentID,
    leaseID: EditLeaseID,
    changes: [[String: Any]]
) throws -> [String: Any] {
    var value = try commonBody(
        type: "edit", contextID: contextID, tabID: tabID,
        documentID: documentID, environmentID: environmentID,
        path: RelativePath("src/main.ts"),
        leaseID: leaseID, writable: true
    )
    value["webContentGeneration"] = generation
    value["baseVersion"] = 0
    value["changes"] = changes
    return value
}

private func saveBody(
    contextID: WorkspaceContextID,
    tabID: TabID,
    documentID: DocumentID,
    environmentID: EnvironmentID,
    path: String = "src/main.ts",
    leaseID: EditLeaseID?,
    writable: Bool
) throws -> [String: Any] {
    try commonBody(
        type: "save", contextID: contextID, tabID: tabID,
        documentID: documentID, environmentID: environmentID,
        path: RelativePath(path),
        leaseID: leaseID, writable: writable
    )
}

private func viewStateBody(
    contextID: WorkspaceContextID,
    tabID: TabID,
    documentID: DocumentID,
    environmentID: EnvironmentID,
    path: String = "src/main.ts",
    leaseID: EditLeaseID,
    value: DocumentViewState
) throws -> [String: Any] {
    var body = try commonBody(
        type: "viewState", contextID: contextID, tabID: tabID,
        documentID: documentID, environmentID: environmentID,
        path: RelativePath(path),
        leaseID: leaseID, writable: true
    )
    body["value"] = [
        "cursor": ["line": value.cursor.line, "column": value.cursor.column],
        "selections": value.selections.map { [
            "anchor": ["line": $0.anchor.line, "column": $0.anchor.column],
            "active": ["line": $0.active.line, "column": $0.active.column],
        ] },
        "firstVisibleLine": value.firstVisibleLine,
        "horizontalScrollOffset": value.horizontalScrollOffset,
    ]
    return body
}
