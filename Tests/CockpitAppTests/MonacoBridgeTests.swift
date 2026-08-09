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
    func testOneInjectedWKWebViewSurvivesContentProcessGenerationRestart() async throws {
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

        let restartLoaded = try await waitUntil {
            fixture.bridge.webContentGeneration == 2
                && original.configuration.userContentController.userScripts.contains {
                    $0.injectionTime == .atDocumentStart
                        && $0.isForMainFrameOnly
                        && $0.source == "globalThis.cockpitWebContentGeneration = 2;"
                }
        }

        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue(original === created)
        XCTAssertTrue(original === controller.webView)
        XCTAssertEqual(fixture.bridge.webContentGeneration, 2)
        XCTAssertTrue(restartLoaded)
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
        guard waiter else { return XCTFail("production runtime navigation did not finish") }
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
        try await fixture.resolver.retain(
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
            try await fixture.resolver.retain(
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
        try await fixture.resolver.retain(
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
        let abandoned = try await fixture.bridge.abandonCommittedRelocation(token)
        XCTAssertEqual(abandoned, .abandonedAllStale)
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
        let closedFixture = makeBridgeFixture(clientID: clientID)
        let closedDocumentID = DocumentID()
        let closedTransport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: closedDocumentID,
            environmentID: EnvironmentID(),
            path: RelativePath("fixture-only.txt")
        )
        let closedController = DocumentClientController(
            clientInstanceID: clientID,
            transport: closedTransport
        )
        try await closedFixture.resolver.retain(
            contextID: closedFixture.contextID,
            tabID: TabID(),
            documentID: closedDocumentID,
            controller: closedController,
            language: "plaintext"
        )
        let closedToken = try await closedFixture.bridge.prepareRelocation(
            workspaceContextID: closedFixture.contextID,
            operation: .rename(source: RelativePath("authoritative-source.txt"), newName: "new.txt")
        )
        XCTAssertEqual(closedToken.affectedDocumentIDs, [])
        let closedMetrics = await closedTransport.metrics()
        XCTAssertEqual(closedMetrics.flushCount, 0)

        let cases: [(MonacoBridgeError, Bool, Bool)] = [
            (.staleDocumentState, true, false),
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
            try await fixture.resolver.retain(
                contextID: fixture.contextID, tabID: TabID(), documentID: documentID,
                controller: controller, language: "plaintext"
            )
            if forceResync { await transport.setFlushError(.recoveryRequired) }
            if forceResync { _ = try? await controller.flush() }
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
        let restartPrepared = try await waitUntil {
            fixture.bridge.webContentGeneration == 2
        }
        XCTAssertTrue(restartPrepared)
        let readyReply = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(readyReply, .failure(.staleDocumentState))
        XCTAssertEqual(fixture.sink.openCount(documentID: first.documentID), 1)
        XCTAssertEqual(fixture.sink.openCount(documentID: second.documentID), 0)
        XCTAssertEqual(fixture.sink.lastSelected?.reference.tabID, first.tabIDs[0])
        XCTAssertEqual(fixture.errors.values[second.documentID], .staleDocumentState)
        let recoveredReply = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(recoveredReply, .success(nil))
        XCTAssertEqual(fixture.sink.openCount(documentID: second.documentID), 1)
        controller.tearDown()
    }

    func testRealWKWebViewGenerationOneRetainReadySelectAndReleaseMirrorsReferenceLifecycle() async throws {
        let clientID = ClientInstanceID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let firstTabID = TabID()
        let secondTabID = TabID()
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("lifecycle.txt")
        )
        let documentController = DocumentClientController(
            clientInstanceID: clientID,
            transport: transport
        )
        _ = try await documentController.open(
            in: environmentID,
            at: RelativePath("lifecycle.txt"),
            requestWriteAccess: true
        )
        let fixture = makeBridgeFixture(clientID: clientID)
        try await fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: documentID,
            controller: documentController,
            language: "plaintext"
        )
        try fixture.resolver.select(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: documentID
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        let runtimeLoaded = try await waitForRuntimeLoad(controller.webView)
        guard runtimeLoaded else { return XCTFail("production runtime navigation did not finish") }
        try await Task.sleep(for: .milliseconds(200))

        let uri = try MonacoFileURI.make(
            environmentID: environmentID,
            path: RelativePath("lifecycle.txt")
        )
        let initialReferenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        XCTAssertEqual(initialReferenceCount, 1)
        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.cockpitEditorProtocol.openText(uri, text, 'plaintext'); return true",
            arguments: ["uri": uri, "text": "acknowledged live edit\nsecond line\n"],
            in: nil,
            contentWorld: .page
        )
        let editAccepted = try await waitUntil {
            await transport.metrics().applyCount == 1
        }
        XCTAssertTrue(editAccepted, "native edit acknowledgement did not complete")
        try await fixture.resolver.storeViewState(
            fixture.contextID,
            secondTabID,
            documentID,
            try makeViewState(line: 2)
        )
        try await fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: documentID,
            controller: documentController,
            language: "plaintext"
        )
        let acknowledgedText = "acknowledged live edit\nsecond line\n"
        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.cockpitEditorProtocol.openText(uri, text, 'plaintext'); return true",
            arguments: ["uri": uri, "text": "post-attach probe\n"],
            in: nil,
            contentWorld: .page
        )
        let postAttachEditAccepted = try await waitUntil {
            await transport.metrics().applyCount == 2
        }
        XCTAssertTrue(postAttachEditAccepted)
        let postAttachMetrics = await transport.metrics()
        XCTAssertEqual(
            postAttachMetrics.lastTransaction?.changes.first?.length,
            UInt64(acknowledgedText.utf16.count)
        )
        let postAttachReferenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        XCTAssertEqual(postAttachReferenceCount, 2)
        try await fixture.bridge.select(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: documentID
        )
        let selectedReferenceCount = try await controller.webView.callAsyncJavaScript(
            "return globalThis.cockpitEditorProtocol.referenceCount(uri)",
            arguments: ["uri": uri],
            in: nil,
            contentWorld: .page
        )
        XCTAssertEqual(selectedReferenceCount as? Int, 2)

        try await fixture.resolver.release(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: documentID
        )
        let retainedReferenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        XCTAssertEqual(retainedReferenceCount, 1)
        try await fixture.resolver.release(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: documentID
        )
        let releasedReferenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        let releasedModelCount = try await javaScriptModelCount(in: controller.webView)
        XCTAssertEqual(releasedReferenceCount, 0)
        XCTAssertEqual(releasedModelCount, 0)
        controller.tearDown()
    }

    func testRealWKWebViewJavaScriptRenameFailureRetainsRelocationForRetry() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let source = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "source.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        let runtimeLoaded = try await waitForRuntimeLoad(controller.webView)
        guard runtimeLoaded else { return XCTFail("production runtime navigation did not finish") }
        try await Task.sleep(for: .milliseconds(200))

        let destinationPath = try RelativePath("destination.txt")
        let collision = try makeOpenMessage(
            contextID: .conversation(ConversationID()),
            tabID: TabID(),
            documentID: DocumentID(),
            environmentID: source.environmentID,
            path: destinationPath,
            text: "collision\n"
        )
        let collisionReply = try await sendNativeMessage(collision, to: controller.webView)
        XCTAssertEqual(collisionReply["ok"] as? Bool, true)
        try await source.transport.setSnapshotPath(destinationPath)
        let sourcePath = try RelativePath("source.txt")
        let token = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: .rename(source: sourcePath, newName: "destination.txt")
        )
        let first = try await fixture.bridge.commitRelocation(
            token,
            result: .relocated(from: sourcePath, to: destinationPath)
        )
        XCTAssertEqual(first, .incomplete(pendingDocumentIDs: [source.documentID]))

        let staleSave = await fixture.bridge.handleMessageBody(try saveBody(
            contextID: fixture.contextID,
            tabID: source.tabIDs[0],
            documentID: source.documentID,
            environmentID: source.environmentID,
            path: "source.txt",
            leaseID: await source.transport.leaseID(),
            writable: true
        ))
        XCTAssertEqual(staleSave, .failure(.resynchronizing))

        let collisionAccess = access(from: collision)
        let disposeCollisionReply = try await sendNativeMessage(
            .disposeModel(webContentGeneration: 1, access: collisionAccess),
            to: controller.webView
        )
        XCTAssertEqual(disposeCollisionReply["ok"] as? Bool, true)
        let retry = try await fixture.bridge.retryRelocation(token)
        XCTAssertEqual(retry, .complete)
        let destinationURI = try MonacoFileURI.make(
            environmentID: source.environmentID,
            path: destinationPath
        )
        let destinationReferenceCount = try await javaScriptReferenceCount(
            destinationURI,
            in: controller.webView
        )
        XCTAssertEqual(destinationReferenceCount, 1)
        controller.tearDown()
    }

    func testRealWKWebViewCrashDispatchFailureKeepsRestartPendingUntilExactSuccessReply() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let session = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "restart.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        let runtimeLoaded = try await waitForRuntimeLoad(controller.webView)
        guard runtimeLoaded else { return XCTFail("production runtime navigation did not finish") }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await controller.webView.evaluateJavaScript(
            "globalThis.savedCockpitMonacoReceive = globalThis.cockpitMonacoReceive; delete globalThis.cockpitMonacoReceive; true"
        )
        try await fixture.bridge.prepareForWebContentRestart(generation: 2)

        let failed = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(failed, .failure(.transportFailure))
        let userContentController = controller.webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(
            forName: "cockpitMonaco",
            contentWorld: .page
        )
        controller.loadRuntime()
        let generationTwoLoaded = try await waitForRuntimeLoad(controller.webView)
        guard generationTwoLoaded else {
            return XCTFail("generation 2 production runtime navigation did not finish")
        }
        userContentController.addScriptMessageHandler(
            try XCTUnwrap(controller.forwarder),
            contentWorld: .page,
            name: "cockpitMonaco"
        )
        let recovered = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(recovered, .success(nil))
        let uri = try MonacoFileURI.make(
            environmentID: session.environmentID,
            path: RelativePath("restart.txt")
        )
        let rebuiltReferenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        XCTAssertEqual(rebuiltReferenceCount, 1)
        controller.tearDown()
    }

    func testRelocationFiltersByLastAuthoritativePathBeforeUnrelatedInvalidStateValidation() async throws {
        let invalidKinds: [UnrelatedInvalidSessionKind] = [.closed, .resynchronizing, .nonOwnerReady]
        for invalidKind in invalidKinds {
            let clientID = ClientInstanceID()
            let fixture = makeBridgeFixture(clientID: clientID)
            let affected = try await attachSession(
                fixture: fixture,
                clientID: clientID,
                path: "source/affected.txt",
                writable: true,
                contexts: [fixture.contextID]
            )
            try await attachUnrelatedInvalidSession(
                invalidKind,
                fixture: fixture,
                clientID: clientID,
                path: RelativePath("unrelated/invalid.txt")
            )
            do {
                let token = try await fixture.bridge.prepareRelocation(
                    workspaceContextID: fixture.contextID,
                    operation: .rename(source: RelativePath("source"), newName: "renamed")
                )
                XCTAssertEqual(token.affectedDocumentIDs, [affected.documentID])
                try fixture.bridge.cancelRelocation(token)
            } catch {
                XCTFail("unrelated \(invalidKind) blocked affected relocation: \(error)")
            }
            let metrics = await affected.transport.metrics()
            XCTAssertEqual(metrics.flushCount, 1)
        }
    }

    func testNativeMessageEncoderEnforcesEverySafeBoundAndRejectsBeforeWebKitDispatch() async throws {
        let maximum = documentJavaScriptMaximum
        let validViewState = try makeViewState(line: maximum)
        let invalidViewState = try makeViewState(line: maximum + 1)
        let contextID = WorkspaceContextID.project(ProjectID())
        let tabID = TabID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let leaseID = EditLeaseID()
        let validAccess = MonacoDocumentAccess(
            reference: MonacoDocumentReference(
                workspaceContextID: contextID,
                tabID: tabID,
                documentID: documentID
            ),
            uri: try MonacoFileURI.make(
                environmentID: environmentID,
                path: RelativePath("bounds.txt")
            ),
            lastAcceptedClientSequence: maximum,
            editLeaseID: leaseID,
            writable: true
        )
        let validSnapshot = try makeSnapshot(
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("bounds.txt"),
            documentVersion: maximum,
            lastAcceptedClientSequence: maximum,
            lease: try EditLease(
                validatingID: leaseID,
                documentID: documentID,
                clientInstanceID: ClientInstanceID()
            )
        )
        let validMessages: [MonacoNativeMessage] = [
            .open(webContentGeneration: maximum, access: validAccess, language: "plaintext", snapshot: validSnapshot, viewState: validViewState),
            .replace(webContentGeneration: maximum, access: validAccess, snapshot: validSnapshot, viewState: validViewState),
            .renameModel(webContentGeneration: maximum, access: validAccess, oldURI: validAccess.uri, language: "plaintext", snapshot: validSnapshot, viewState: validViewState),
            .selectModel(webContentGeneration: maximum, access: validAccess, viewState: validViewState),
        ]
        for message in validMessages {
            XCTAssertNoThrow(try MonacoMessageCodec.javaScriptObject(for: message))
        }
        let invalidMessages: [MonacoNativeMessage] = [
            .open(webContentGeneration: maximum + 1, access: validAccess, language: "plaintext", snapshot: validSnapshot, viewState: validViewState),
            .replace(webContentGeneration: 1, access: validAccess, snapshot: validSnapshot, viewState: invalidViewState),
            .renameModel(webContentGeneration: 1, access: validAccess, oldURI: validAccess.uri, language: "plaintext", snapshot: validSnapshot, viewState: invalidViewState),
            .selectModel(webContentGeneration: 1, access: validAccess, viewState: invalidViewState),
            .disposeModel(webContentGeneration: 1, access: MonacoDocumentAccess(
                reference: validAccess.reference,
                uri: validAccess.uri,
                lastAcceptedClientSequence: maximum + 1,
                editLeaseID: leaseID,
                writable: true
            )),
        ]
        for message in invalidMessages {
            XCTAssertThrowsError(try MonacoMessageCodec.javaScriptObject(for: message)) {
                XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema)
            }
        }
        let unsafePosition = try TextPosition(
            validatingLine: maximum + 1,
            column: 2
        )
        var invalidCursor = validViewState
        invalidCursor.cursor = unsafePosition
        var invalidSelection = validViewState
        invalidSelection.selections = [try TextRange(
            validatingAnchor: unsafePosition,
            active: unsafePosition
        )]
        var invalidFirstVisibleLine = validViewState
        invalidFirstVisibleLine.firstVisibleLine = maximum + 1
        var zeroFirstVisibleLine = validViewState
        zeroFirstVisibleLine.firstVisibleLine = 0
        var invalidInfiniteScroll = validViewState
        invalidInfiniteScroll.horizontalScrollOffset = .infinity
        var invalidNegativeScroll = validViewState
        invalidNegativeScroll.horizontalScrollOffset = -1
        for viewState in [
            invalidCursor,
            invalidSelection,
            invalidFirstVisibleLine,
            zeroFirstVisibleLine,
            invalidInfiniteScroll,
            invalidNegativeScroll,
        ] {
            XCTAssertThrowsError(try MonacoMessageCodec.javaScriptObject(for: .selectModel(
                webContentGeneration: 1,
                access: validAccess,
                viewState: viewState
            ))) {
                XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema)
            }
        }

        let recorder = ViewStateRecorder()
        await recorder.store(
            contextID: contextID,
            tabID: tabID,
            documentID: documentID,
            value: invalidViewState
        )
        let clientID = ClientInstanceID()
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("bounds.txt")
        )
        let documentController = DocumentClientController(clientInstanceID: clientID, transport: transport)
        _ = try await documentController.open(
            in: environmentID,
            at: RelativePath("bounds.txt"),
            requestWriteAccess: true
        )
        let fixture = makeBridgeFixture(clientID: clientID, recorder: recorder)
        try await fixture.resolver.retain(
            contextID: contextID,
            tabID: tabID,
            documentID: documentID,
            controller: documentController,
            language: "plaintext"
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        do {
            try await fixture.bridge.select(
                contextID: contextID,
                tabID: tabID,
                documentID: documentID
            )
            XCTFail("unsafe view state reached WebKit dispatch")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .invalidSchema)
        }
        controller.tearDown()
    }

    func testRemoteAuthorityFileURLIsRejectedByHelperAndRealNavigationAction() async throws {
        let fixture = makeBridgeFixture()
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        let runtimeLoaded = try await waitForRuntimeLoad(controller.webView)
        guard runtimeLoaded else { return XCTFail("production runtime navigation did not finish") }
        let index = runtimeBundleURL().appendingPathComponent("index.html")
        let remote = try XCTUnwrap(URL(string: "file://remote.invalid\(index.path)"))
        XCTAssertFalse(controller.allowsNavigation(
            remote,
            isMainFrame: true,
            opensNewWindow: false,
            isDownload: false
        ))
        _ = try await controller.webView.callAsyncJavaScript(
            "location.href = target; return true",
            arguments: ["target": remote.absoluteString],
            in: nil,
            contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.webView.url?.host?.isEmpty ?? true)
        XCTAssertEqual(controller.webView.url?.standardizedFileURL.path, index.standardizedFileURL.path)
        controller.tearDown()
    }

    func testLiveRelocationOverlapResultDestinationPerReferenceViewStateAndPartialAbandon() async throws {
        let clientID = ClientInstanceID()
        let recorder = ViewStateRecorder()
        let fixture = makeBridgeFixture(clientID: clientID, recorder: recorder)
        let firstDocumentID = DocumentID(
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        )
        let secondDocumentID = DocumentID(
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        )
        let conversationContext = WorkspaceContextID.conversation(ConversationID())
        let first = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            documentID: firstDocumentID,
            path: "batch/a.txt",
            writable: true,
            contexts: [fixture.contextID, conversationContext]
        )
        let second = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            documentID: secondDocumentID,
            path: "batch/b.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        await recorder.store(
            contextID: fixture.contextID,
            tabID: first.tabIDs[0],
            documentID: first.documentID,
            value: try makeViewState(line: 3)
        )
        await recorder.store(
            contextID: conversationContext,
            tabID: first.tabIDs[1],
            documentID: first.documentID,
            value: try makeViewState(line: 7)
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        let runtimeLoaded = try await waitForRuntimeLoad(controller.webView)
        guard runtimeLoaded else { return XCTFail("production runtime navigation did not finish") }
        try await Task.sleep(for: .milliseconds(200))
        _ = try await controller.webView.evaluateJavaScript(
            """
            globalThis.cockpitReceivedNativeMessages = [];
            globalThis.cockpitOriginalReceive = globalThis.cockpitMonacoReceive;
            globalThis.cockpitMonacoReceive = message => {
              globalThis.cockpitReceivedNativeMessages.push(message);
              return globalThis.cockpitOriginalReceive(message);
            };
            true;
            """
        )

        let source = try RelativePath("batch")
        let operation = FileOperation.rename(source: source, newName: "renamed")
        let firstToken = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: operation
        )
        let flushesBeforeOverlap = await first.transport.metrics().flushCount
        do {
            _ = try await fixture.bridge.prepareRelocation(
                workspaceContextID: fixture.contextID,
                operation: operation
            )
            XCTFail("duplicate live operation created a second token")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .staleDocumentState)
        }
        do {
            _ = try await fixture.bridge.prepareRelocation(
                workspaceContextID: fixture.contextID,
                operation: .rename(source: RelativePath("batch/a.txt"), newName: "other.txt")
            )
            XCTFail("overlapping live DocumentID created a second token")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .staleDocumentState)
        }
        let flushesAfterOverlap = await first.transport.metrics().flushCount
        XCTAssertEqual(flushesAfterOverlap, flushesBeforeOverlap)
        do {
            _ = try await fixture.bridge.commitRelocation(
                firstToken,
                result: .relocated(
                    from: RelativePath("wrong-source"),
                    to: RelativePath("renamed")
                )
            )
            XCTFail("mismatched relocated result committed")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .invalidSchema)
        }
        XCTAssertNoThrow(try fixture.bridge.cancelRelocation(firstToken))

        let token = try await fixture.bridge.prepareRelocation(
            workspaceContextID: fixture.contextID,
            operation: operation
        )
        try await first.transport.setSnapshotPath(RelativePath("renamed/a.txt"))
        try await second.transport.setSnapshotPath(RelativePath("wrong/b.txt"))
        let partial = try await fixture.bridge.commitRelocation(
            token,
            result: .relocated(from: source, to: RelativePath("renamed"))
        )
        XCTAssertEqual(partial, .incomplete(pendingDocumentIDs: [second.documentID]))
        try await Task.sleep(for: .milliseconds(200))
        let migratedViewLines = try await controller.webView.callAsyncJavaScript(
            """
            return globalThis.cockpitReceivedNativeMessages
              .filter(message => message.type === 'renameModel' && message.documentID === documentID)
              .map(message => message.viewState.firstVisibleLine);
            """,
            arguments: ["documentID": first.documentID.description],
            in: nil,
            contentWorld: .page
        ) as? [Int]
        XCTAssertEqual(migratedViewLines, [3, 7])

        let firstOldURI = try MonacoFileURI.make(
            environmentID: first.environmentID,
            path: RelativePath("batch/a.txt")
        )
        let firstDestinationURI = try MonacoFileURI.make(
            environmentID: first.environmentID,
            path: RelativePath("renamed/a.txt")
        )
        let secondOldURI = try MonacoFileURI.make(
            environmentID: second.environmentID,
            path: RelativePath("batch/b.txt")
        )
        let firstOldCount = try await javaScriptReferenceCount(firstOldURI, in: controller.webView)
        let firstDestinationCount = try await javaScriptReferenceCount(
            firstDestinationURI,
            in: controller.webView
        )
        let secondOldCount = try await javaScriptReferenceCount(secondOldURI, in: controller.webView)
        XCTAssertEqual(firstOldCount, 0)
        XCTAssertEqual(firstDestinationCount, 2)
        XCTAssertEqual(secondOldCount, 1)

        let abandoned = try await fixture.bridge.abandonCommittedRelocation(token)
        XCTAssertEqual(abandoned, .abandonedAllStale)
        let firstAfterAbandon = try await javaScriptReferenceCount(
            firstDestinationURI,
            in: controller.webView
        )
        let secondAfterAbandon = try await javaScriptReferenceCount(secondOldURI, in: controller.webView)
        XCTAssertEqual(firstAfterAbandon, 0)
        XCTAssertEqual(secondAfterAbandon, 0)
        let modelsAfterAbandon = try await javaScriptModelCount(in: controller.webView)
        XCTAssertEqual(modelsAfterAbandon, 0)
        controller.tearDown()
    }

    func testLifecycleGateSerializesTwoPostReadyRetainsForOneMissingSession() async throws {
        let clientID = ClientInstanceID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let firstTabID = TabID()
        let secondTabID = TabID()
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("double-retain.txt")
        )
        let documentController = DocumentClientController(clientInstanceID: clientID, transport: transport)
        _ = try await documentController.open(
            in: environmentID,
            at: RelativePath("double-retain.txt"),
            requestWriteAccess: true
        )
        let fixture = makeBridgeFixture(clientID: clientID)
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("production runtime navigation did not finish")
        }
        let pausingSink = PausingNativeSink(pauseOn: .open) { message in
            try await dispatchExactSuccess(message, to: controller.webView)
        }
        fixture.bridge.setSink { try await pausingSink.send($0) }

        async let first: Void = fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: documentID,
            controller: documentController,
            language: "plaintext"
        )
        await pausingSink.waitUntilPaused()
        async let second: Void = fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: documentID,
            controller: documentController,
            language: "plaintext"
        )
        _ = try await waitUntil(timeout: .milliseconds(200)) {
            pausingSink.messageCount >= 2
        }
        pausingSink.resume()
        try await first
        try await second

        let session = try XCTUnwrap(fixture.resolver.session(documentID: documentID))
        XCTAssertTrue(session.controller === documentController)
        XCTAssertEqual(Set(session.references.map(\.tabID)), [firstTabID, secondTabID])
        let uri = try MonacoFileURI.make(
            environmentID: environmentID,
            path: RelativePath("double-retain.txt")
        )
        let referenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        let modelCount = try await javaScriptModelCount(in: controller.webView)
        XCTAssertEqual(referenceCount, 2)
        XCTAssertEqual(modelCount, 1)
        controller.tearDown()
    }

    func testLifecycleGateSerializesLastReleaseBeforeSameReferenceRetain() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let attached = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "release-retain.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        let tabID = attached.tabIDs[0]
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("production runtime navigation did not finish")
        }
        let pausingSink = PausingNativeSink(pauseOn: .dispose) { message in
            try await dispatchExactSuccess(message, to: controller.webView)
        }
        fixture.bridge.setSink { try await pausingSink.send($0) }

        async let release: Void = fixture.resolver.release(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: attached.documentID
        )
        await pausingSink.waitUntilPaused()
        async let retain: Void = fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: attached.documentID,
            controller: attached.controller,
            language: "plaintext"
        )
        for _ in 0..<8 { await Task.yield() }
        pausingSink.resume()
        try await release
        try await retain

        let session = try XCTUnwrap(fixture.resolver.session(documentID: attached.documentID))
        XCTAssertTrue(session.controller === attached.controller)
        XCTAssertEqual(session.references.map(\.tabID), [tabID])
        let uri = try MonacoFileURI.make(
            environmentID: attached.environmentID,
            path: RelativePath("release-retain.txt")
        )
        let referenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
        let modelCount = try await javaScriptModelCount(in: controller.webView)
        XCTAssertEqual(referenceCount, 1)
        XCTAssertEqual(modelCount, 1)
        controller.tearDown()
    }

    func testLifecycleGateReconcilesRetainAndReleaseWhileInitialReadyIsPaused() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let attached = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "initial-ready-race.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        let firstTabID = attached.tabIDs[0]
        let secondTabID = TabID()
        try fixture.resolver.select(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: attached.documentID
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        try await loadRuntimeWithoutAutomaticReady(controller)
        let pausingSink = PausingNativeSink(pauseOn: .open) { message in
            try await dispatchExactSuccess(message, to: controller.webView)
        }
        fixture.bridge.setSink { try await pausingSink.send($0) }

        async let ready = fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 1,
        ])
        await pausingSink.waitUntilPaused()
        async let retain: Void = fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: attached.documentID,
            controller: attached.controller,
            language: "plaintext"
        )
        async let release: Void = fixture.resolver.release(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: attached.documentID
        )
        for _ in 0..<8 { await Task.yield() }
        pausingSink.resume()
        let readyReply = await ready
        XCTAssertEqual(readyReply, .success(nil))
        try await retain
        try await release
        try await fixture.bridge.select(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: attached.documentID
        )
        let session = try XCTUnwrap(fixture.resolver.session(documentID: attached.documentID))
        XCTAssertEqual(session.references.map(\.tabID), [secondTabID])
        controller.tearDown()
    }

    func testLifecycleGateReconcilesRetainAndReleaseWhileRestartIsPaused() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let attached = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "restart-race.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        let firstTabID = attached.tabIDs[0]
        let secondTabID = TabID()
        try fixture.resolver.select(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: attached.documentID
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("production runtime navigation did not finish")
        }
        let initialURI = try MonacoFileURI.make(
            environmentID: attached.environmentID,
            path: RelativePath("restart-race.txt")
        )
        let initialReadyCompleted = try await waitUntil {
            (try? await javaScriptReferenceCount(initialURI, in: controller.webView)) == 1
        }
        XCTAssertTrue(initialReadyCompleted)
        try await fixture.bridge.prepareForWebContentRestart(generation: 2)
        try await loadRuntimeWithoutAutomaticReady(controller)
        let pausingSink = PausingNativeSink(pauseOn: .open) { message in
            try await dispatchExactSuccess(message, to: controller.webView)
        }
        fixture.bridge.setSink { try await pausingSink.send($0) }

        async let ready = fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        await pausingSink.waitUntilPaused()
        async let retain: Void = fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: attached.documentID,
            controller: attached.controller,
            language: "plaintext"
        )
        async let release: Void = fixture.resolver.release(
            contextID: fixture.contextID,
            tabID: firstTabID,
            documentID: attached.documentID
        )
        for _ in 0..<8 { await Task.yield() }
        pausingSink.resume()
        let readyReply = await ready
        XCTAssertEqual(readyReply, .success(nil))
        try await retain
        try await release
        try await fixture.bridge.select(
            contextID: fixture.contextID,
            tabID: secondTabID,
            documentID: attached.documentID
        )
        let session = try XCTUnwrap(fixture.resolver.session(documentID: attached.documentID))
        XCTAssertEqual(session.references.map(\.tabID), [secondTabID])
        controller.tearDown()
    }

    func testSelectCommitsOnlyAfterKnownReplyOrRealWebKitSuccess() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let conversation = WorkspaceContextID.conversation(ConversationID())
        let attached = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "select-ack.txt",
            writable: true,
            contexts: [fixture.contextID, conversation]
        )
        let first = MonacoDocumentReference(
            workspaceContextID: fixture.contextID,
            tabID: attached.tabIDs[0],
            documentID: attached.documentID
        )
        let second = MonacoDocumentReference(
            workspaceContextID: conversation,
            tabID: attached.tabIDs[1],
            documentID: attached.documentID
        )
        try fixture.resolver.select(
            contextID: first.workspaceContextID,
            tabID: first.tabID,
            documentID: first.documentID
        )
        fixture.bridge.setSink { message in
            if case let .selectModel(_, access, _) = message, access.reference == second {
                throw MonacoBridgeError.unknownDocument
            }
        }
        do {
            try await fixture.bridge.select(
                contextID: second.workspaceContextID,
                tabID: second.tabID,
                documentID: second.documentID
            )
            XCTFail("known JS rejection must fail selection")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .unknownDocument)
        }
        XCTAssertEqual(fixture.resolver.selectedReference, first)

        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        do {
            try await fixture.bridge.select(
                contextID: second.workspaceContextID,
                tabID: second.tabID,
                documentID: second.documentID
            )
            XCTFail("unloaded real WKWebView must fail selection")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .transportFailure)
        }
        XCTAssertEqual(fixture.resolver.selectedReference, first)
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("production runtime navigation did not finish")
        }
        try await fixture.bridge.select(
            contextID: second.workspaceContextID,
            tabID: second.tabID,
            documentID: second.documentID
        )
        XCTAssertEqual(fixture.resolver.selectedReference, second)
        controller.tearDown()
    }

    func testRestartReservationPreventsPausedSelectionFromCommittingAfterOldGenerationAck() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let conversation = WorkspaceContextID.conversation(ConversationID())
        let attached = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "restart-select.txt",
            writable: true,
            contexts: [fixture.contextID, conversation]
        )
        let first = MonacoDocumentReference(
            workspaceContextID: fixture.contextID,
            tabID: attached.tabIDs[0],
            documentID: attached.documentID
        )
        let second = MonacoDocumentReference(
            workspaceContextID: conversation,
            tabID: attached.tabIDs[1],
            documentID: attached.documentID
        )
        try fixture.resolver.select(
            contextID: first.workspaceContextID,
            tabID: first.tabID,
            documentID: first.documentID
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("generation 1 production runtime navigation did not finish")
        }
        let initialReadyCompleted = try await waitUntil {
            (try? await javaScriptModelCount(in: controller.webView)) == 1
        }
        XCTAssertTrue(initialReadyCompleted)
        let pausingSink = PausingNativeSink(pauseOn: .select) { message in
            try await dispatchExactSuccess(message, to: controller.webView)
        }
        fixture.bridge.setSink { try await pausingSink.send($0) }

        async let selecting: Void = fixture.bridge.select(
            contextID: second.workspaceContextID,
            tabID: second.tabID,
            documentID: second.documentID
        )
        await pausingSink.waitUntilPaused()
        let prepareStarted = expectation(description: "restart reservation entered")
        let preparing = Task { @MainActor in
            prepareStarted.fulfill()
            try await fixture.bridge.prepareForWebContentRestart(generation: 2)
        }
        await fulfillment(of: [prepareStarted], timeout: 2)
        pausingSink.resume()
        var prepareError: MonacoBridgeError?
        do {
            try await preparing.value
        } catch {
            prepareError = error as? MonacoBridgeError
        }
        var selectionError: MonacoBridgeError?
        do {
            try await selecting
        } catch {
            selectionError = error as? MonacoBridgeError
        }

        XCTAssertNil(prepareError)
        XCTAssertEqual(selectionError, .staleGeneration)
        XCTAssertEqual(fixture.resolver.selectedReference, first)
        controller.tearDown()
    }

    func testOutgoingMessageCoherenceRejectsEveryVariantBeforeDispatch() throws {
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let path = try RelativePath("coherence.txt")
        let reference = MonacoDocumentReference(
            workspaceContextID: .project(ProjectID()),
            tabID: TabID(),
            documentID: documentID
        )
        let lease = try EditLease(
            validatingID: EditLeaseID(),
            documentID: documentID,
            clientInstanceID: ClientInstanceID()
        )
        let snapshot = try makeSnapshot(
            documentID: documentID,
            environmentID: environmentID,
            path: path,
            documentVersion: 1,
            lastAcceptedClientSequence: 1,
            lease: lease
        )
        let access = MonacoDocumentAccess(
            reference: reference,
            uri: try MonacoFileURI.make(environmentID: environmentID, path: path),
            lastAcceptedClientSequence: 1,
            editLeaseID: lease.id,
            writable: true
        )
        let otherURI = try MonacoFileURI.make(
            environmentID: environmentID,
            path: RelativePath("other.txt")
        )
        let mismatchedURI = MonacoDocumentAccess(
            reference: reference,
            uri: otherURI,
            lastAcceptedClientSequence: 1,
            editLeaseID: lease.id,
            writable: true
        )
        let mismatchedSequence = MonacoDocumentAccess(
            reference: reference,
            uri: access.uri,
            lastAcceptedClientSequence: 0,
            editLeaseID: lease.id,
            writable: true
        )
        let mismatchedLease = MonacoDocumentAccess(
            reference: reference,
            uri: access.uri,
            lastAcceptedClientSequence: 1,
            editLeaseID: EditLeaseID(),
            writable: true
        )
        let acknowledgement = try EditAcknowledgement(
            validatingDocumentID: documentID,
            clientSequence: 1,
            documentVersion: 1
        )
        let invalidVariants: [MonacoNativeMessage] = [
            .open(webContentGeneration: 1, access: mismatchedURI, language: "plaintext", snapshot: snapshot, viewState: nil),
            .acknowledgement(webContentGeneration: 1, access: mismatchedSequence, acknowledgement: acknowledgement),
            .replace(webContentGeneration: 1, access: mismatchedSequence, snapshot: snapshot, viewState: nil),
            .setWritable(webContentGeneration: 1, access: MonacoDocumentAccess(
                reference: reference,
                uri: access.uri,
                lastAcceptedClientSequence: 1,
                editLeaseID: lease.id,
                writable: false
            )),
            .renameModel(webContentGeneration: 1, access: mismatchedLease, oldURI: otherURI, language: "plaintext", snapshot: snapshot, viewState: nil),
            .disposeModel(webContentGeneration: 1, access: MonacoDocumentAccess(
                reference: reference,
                uri: access.uri,
                lastAcceptedClientSequence: documentJavaScriptMaximum + 1,
                editLeaseID: lease.id,
                writable: true
            )),
            .selectModel(webContentGeneration: 1, access: MonacoDocumentAccess(
                reference: reference,
                uri: "cockpit-file://invalid/path",
                lastAcceptedClientSequence: 1,
                editLeaseID: lease.id,
                writable: true
            ), viewState: nil),
        ]
        XCTAssertEqual(invalidVariants.count, 7)
        for message in invalidVariants {
            XCTAssertThrowsError(try MonacoMessageCodec.javaScriptObject(for: message)) {
                XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema)
            }
        }
    }

    func testRealWKCrashPreservesEveryKnownErrorAttemptsAllSessionsAndRetries() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let crashPaths = ["crash-a.txt", "crash-b.txt", "crash-c.txt"]
        var sessions: [AttachedSession] = []
        for path in crashPaths {
            sessions.append(try await attachSession(
                fixture: fixture,
                clientID: clientID,
                path: path,
                writable: true,
                contexts: [fixture.contextID]
            ))
        }
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("generation 1 production runtime navigation did not finish")
        }
        let initialModelsReady = try await waitUntil {
            (try? await javaScriptModelCount(in: controller.webView)) == sessions.count
        }
        XCTAssertTrue(initialModelsReady)
        try await fixture.bridge.prepareForWebContentRestart(generation: 2)
        try await loadRuntimeWithoutAutomaticReady(controller)
        _ = try await controller.webView.callAsyncJavaScript(
            """
            globalThis.realCockpitMonacoReceive = globalThis.cockpitMonacoReceive;
            globalThis.forcedCrashCode = null;
            globalThis.throwCrashTransport = false;
            globalThis.crashAttempts = [];
            globalThis.cockpitMonacoReceive = message => {
              if (message.type === 'open') {
                globalThis.crashAttempts.push(message.documentID);
                if (globalThis.throwCrashTransport) throw new Error('forced WebKit failure');
                if (globalThis.forcedCrashCode !== null) {
                  return { ok: false, error: globalThis.forcedCrashCode };
                }
              }
              return globalThis.realCockpitMonacoReceive(message);
            };
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let knownErrors: [MonacoBridgeError] = [
            .invalidSchema, .staleGeneration, .staleDocumentState, .unknownDocument,
            .readOnly, .resynchronizing, .fileMissing, .transportFailure,
        ]
        let expectedDocumentIDs = Set(sessions.map { $0.documentID.description })
        for knownError in knownErrors {
            _ = try await controller.webView.callAsyncJavaScript(
                "globalThis.forcedCrashCode = code; globalThis.throwCrashTransport = false; globalThis.crashAttempts = []; return true",
                arguments: ["code": knownError.wireCode],
                in: nil,
                contentWorld: .page
            )
            let reply = await fixture.bridge.handleMessageBody([
                "type": "ready", "webContentGeneration": 2,
            ])
            XCTAssertEqual(reply, .failure(knownError), "ready erased \(knownError)")
            let attempts = try await controller.webView.callAsyncJavaScript(
                "return globalThis.crashAttempts",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? [String]
            XCTAssertEqual(Set(attempts ?? []), expectedDocumentIDs)
            for session in sessions {
                XCTAssertEqual(fixture.errors.values[session.documentID], knownError)
            }
        }
        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.forcedCrashCode = null; globalThis.throwCrashTransport = true; globalThis.crashAttempts = []; return true",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let transportFailureReply = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(transportFailureReply, .failure(.transportFailure))
        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.throwCrashTransport = false; globalThis.crashAttempts = []; return true",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let successReply = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(successReply, .success(nil))
        let rebuiltModelCount = try await javaScriptModelCount(in: controller.webView)
        XCTAssertEqual(rebuiltModelCount, sessions.count)
        for (session, path) in zip(sessions, crashPaths) {
            let uri = try MonacoFileURI.make(
                environmentID: session.environmentID,
                path: RelativePath(path)
            )
            let rebuiltReferenceCount = try await javaScriptReferenceCount(uri, in: controller.webView)
            XCTAssertEqual(rebuiltReferenceCount, 1)
        }
        controller.tearDown()
    }

    func testRestartReleaseCapturedSelectionReconcilesExactRemainingReferences() async throws {
        let sameContext = WorkspaceContextID.project(ProjectID())
        let lastContext = WorkspaceContextID.project(ProjectID())
        let topologies: [(name: String, contexts: [WorkspaceContextID])] = [
            ("same-context", [sameContext, sameContext]),
            ("last-reference", [lastContext]),
            ("cross-context", [.project(ProjectID()), .conversation(ConversationID())]),
        ]
        for topology in topologies {
            let clientID = ClientInstanceID()
            let fixture = makeBridgeFixture(clientID: clientID)
            let attached = try await attachSession(
                fixture: fixture,
                clientID: clientID,
                path: "restart-release-\(topology.name).txt",
                writable: true,
                contexts: topology.contexts
            )
            let selected = MonacoDocumentReference(
                workspaceContextID: topology.contexts[0],
                tabID: attached.tabIDs[0],
                documentID: attached.documentID
            )
            try fixture.resolver.select(
                contextID: selected.workspaceContextID,
                tabID: selected.tabID,
                documentID: selected.documentID
            )
            let controller = MonacoEditorViewController(
                bridge: fixture.bridge,
                runtimeBundleURL: runtimeBundleURL()
            )
            controller.loadViewIfNeeded()
            controller.loadRuntime()
            guard try await waitForRuntimeLoad(controller.webView) else {
                return XCTFail("\(topology.name) generation 1 runtime did not load")
            }
            let uri = try MonacoFileURI.make(
                environmentID: attached.environmentID,
                path: RelativePath("restart-release-\(topology.name).txt")
            )
            let initialReady = try await waitUntil {
                (try? await javaScriptReferenceCount(uri, in: controller.webView))
                    == topology.contexts.count
            }
            XCTAssertTrue(initialReady, topology.name)

            try await fixture.bridge.prepareForWebContentRestart(generation: 2)
            try await fixture.resolver.release(
                contextID: selected.workspaceContextID,
                tabID: selected.tabID,
                documentID: selected.documentID
            )
            try await loadRuntimeWithoutAutomaticReady(controller)
            let generationTwoSink = MessageSink()
            fixture.bridge.setSink { message in
                generationTwoSink.append(message)
                try await dispatchExactSuccess(message, to: controller.webView)
            }
            let ready = await fixture.bridge.handleMessageBody([
                "type": "ready", "webContentGeneration": 2,
            ])
            XCTAssertEqual(ready, .success(nil), topology.name)
            XCTAssertFalse(generationTwoSink.messages.contains { message in
                guard case let .selectModel(_, access, _) = message else { return false }
                return access.reference == selected
            }, topology.name)
            let remainingCount = topology.contexts.count - 1
            let javaScriptReferences = try await javaScriptReferenceCount(
                uri,
                in: controller.webView
            )
            let javaScriptModels = try await javaScriptModelCount(in: controller.webView)
            XCTAssertEqual(
                javaScriptReferences,
                remainingCount,
                topology.name
            )
            XCTAssertEqual(
                javaScriptModels,
                remainingCount == 0 ? 0 : 1,
                topology.name
            )
            if remainingCount == 0 {
                XCTAssertNil(fixture.resolver.session(documentID: attached.documentID))
            } else {
                let session = try XCTUnwrap(
                    fixture.resolver.session(documentID: attached.documentID),
                    topology.name
                )
                XCTAssertEqual(session.references.count, remainingCount, topology.name)
                XCTAssertFalse(session.references.contains(selected), topology.name)
            }
            let messageCount = generationTwoSink.messages.count
            let repeated = await fixture.bridge.handleMessageBody([
                "type": "ready", "webContentGeneration": 2,
            ])
            XCTAssertEqual(repeated, .success(nil), topology.name)
            XCTAssertEqual(generationTwoSink.messages.count, messageCount, topology.name)
            controller.tearDown()
        }
    }

    func testBEditEffectFinishesBeforeRestartLinearizationAndOldRequestsCannotEnterAfterward() async throws {
        let session = try await makeReadySession(path: "src/main.ts")
        let barrier = AsyncBarrier()
        await session.transport.pauseNextApply(at: barrier)
        let body = try editBody(
            generation: 1,
            contextID: session.fixture.contextID,
            tabID: session.tabID,
            documentID: session.documentID,
            environmentID: session.environmentID,
            leaseID: await session.transport.leaseID(),
            changes: [["offset": 0, "length": 0, "replacement": "x"]]
        )
        let handling = Task { @MainActor in
            await session.fixture.bridge.handleMessageBody(body)
        }
        await barrier.waitUntilPaused()
        let restartStarted = expectation(description: "edit restart entered")
        let restarting = Task { @MainActor in
            restartStarted.fulfill()
            try await session.fixture.bridge.prepareForWebContentRestart(generation: 2)
        }
        await fulfillment(of: [restartStarted], timeout: 2)
        let generationWhileApplyPaused = session.fixture.bridge.webContentGeneration
        await barrier.resume()
        let reply = await handling.value
        try await restarting.value

        XCTAssertEqual(generationWhileApplyPaused, 1)
        guard case let .success(.acknowledgement(replyGeneration, _, _)) = reply else {
            return XCTFail("expected generation-1 acknowledgement, got \(reply)")
        }
        XCTAssertEqual(replyGeneration, 1)
        let metricsAfterApply = await session.transport.metrics()
        XCTAssertEqual(metricsAfterApply.applyCount, 1)
        XCTAssertEqual(session.fixture.bridge.webContentGeneration, 2)
        let staleReply = await session.fixture.bridge.handleMessageBody(body)
        XCTAssertEqual(staleReply, .failure(.staleGeneration))
        let metricsAfterStaleEdit = await session.transport.metrics()
        XCTAssertEqual(metricsAfterStaleEdit.applyCount, 1)
    }

    func testSaveEffectFinishesBeforeRestartLinearizationAndOldRequestsCannotEnterAfterward() async throws {
        let session = try await makeReadySession(path: "save-generation.txt")
        let barrier = AsyncBarrier()
        await session.transport.pauseNextSave(at: barrier)
        let body = try saveBody(
            contextID: session.fixture.contextID,
            tabID: session.tabID,
            documentID: session.documentID,
            environmentID: session.environmentID,
            path: "save-generation.txt",
            leaseID: await session.transport.leaseID(),
            writable: true
        )
        let handling = Task { @MainActor in
            await session.fixture.bridge.handleMessageBody(body)
        }
        await barrier.waitUntilPaused()
        let restartStarted = expectation(description: "save restart entered")
        let restarting = Task { @MainActor in
            restartStarted.fulfill()
            try await session.fixture.bridge.prepareForWebContentRestart(generation: 2)
        }
        await fulfillment(of: [restartStarted], timeout: 2)
        let generationWhileSavePaused = session.fixture.bridge.webContentGeneration
        await barrier.resume()
        let reply = await handling.value
        try await restarting.value

        XCTAssertEqual(generationWhileSavePaused, 1)
        guard case let .success(.replace(replyGeneration, _, _, _)) = reply else {
            return XCTFail("expected generation-1 replace, got \(reply)")
        }
        XCTAssertEqual(replyGeneration, 1)
        let metricsAfterSave = await session.transport.metrics()
        XCTAssertEqual(metricsAfterSave.saveCount, 1)
        XCTAssertEqual(session.fixture.bridge.webContentGeneration, 2)
        let staleReply = await session.fixture.bridge.handleMessageBody(body)
        XCTAssertEqual(staleReply, .failure(.staleGeneration))
        let metricsAfterStaleSave = await session.transport.metrics()
        XCTAssertEqual(metricsAfterStaleSave.saveCount, 1)
    }

    func testViewStateEffectFinishesBeforeRestartLinearizationAndOldRequestsCannotEnterAfterward() async throws {
        let clientID = ClientInstanceID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let tabID = TabID()
        let recorder = ViewStateRecorder()
        let barrier = AsyncBarrier()
        let fixture = makeBridgeFixture(
            clientID: clientID,
            recorder: recorder,
            storeViewState: { contextID, tabID, documentID, value in
                await barrier.pause()
                await recorder.store(
                    contextID: contextID,
                    tabID: tabID,
                    documentID: documentID,
                    value: value
                )
            }
        )
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath("view-generation.txt")
        )
        let documentController = DocumentClientController(
            clientInstanceID: clientID,
            transport: transport
        )
        _ = try await documentController.open(
            in: environmentID,
            at: RelativePath("view-generation.txt"),
            requestWriteAccess: true
        )
        try await fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID,
            controller: documentController,
            language: "plaintext"
        )
        let firstState = try makeViewState(line: 3)
        let body = try viewStateBody(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID,
            environmentID: environmentID,
            path: "view-generation.txt",
            leaseID: await transport.leaseID(),
            value: firstState
        )
        let handling = Task { @MainActor in await fixture.bridge.handleMessageBody(body) }
        await barrier.waitUntilPaused()
        let restartStarted = expectation(description: "view-state restart entered")
        let restarting = Task { @MainActor in
            restartStarted.fulfill()
            try await fixture.bridge.prepareForWebContentRestart(generation: 2)
        }
        await fulfillment(of: [restartStarted], timeout: 2)
        let generationWhileStorePaused = fixture.bridge.webContentGeneration
        await barrier.resume()
        let reply = await handling.value
        try await restarting.value

        XCTAssertEqual(generationWhileStorePaused, 1)
        XCTAssertEqual(reply, .success(nil))
        let storedFirstState = await recorder.value(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID
        )
        XCTAssertEqual(
            storedFirstState,
            firstState
        )
        let staleState = try makeViewState(line: 9)
        let leaseID = await transport.leaseID()
        let staleBody = try viewStateBody(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID,
            environmentID: environmentID,
            path: "view-generation.txt",
            leaseID: leaseID,
            value: staleState
        )
        let staleReply = await fixture.bridge.handleMessageBody(staleBody)
        XCTAssertEqual(staleReply, .failure(.staleGeneration))
        let storedAfterStale = await recorder.value(
            contextID: fixture.contextID,
            tabID: tabID,
            documentID: documentID
        )
        XCTAssertEqual(storedAfterStale, firstState)
    }

    func testNewRestartReservationInvalidatesPausedClosedAndResynchronizingRebuilds() async throws {
        for kind in [UnrelatedInvalidSessionKind.closed, .resynchronizing] {
            let clientID = ClientInstanceID()
            let fixture = makeBridgeFixture(clientID: clientID)
            let documentID = DocumentID()
            let environmentID = EnvironmentID()
            let path = try RelativePath("obsolete-\(kind).txt")
            let transport = try TestDocumentTransport.ready(
                clientID: clientID,
                documentID: documentID,
                environmentID: environmentID,
                path: path
            )
            let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
            switch kind {
            case .resynchronizing:
                _ = try await controller.open(
                    in: environmentID,
                    at: path,
                    requestWriteAccess: true
                )
                await transport.setFlushError(.recoveryRequired)
                _ = try? await controller.flush()
            case .closed:
                break
            case .nonOwnerReady:
                XCTFail("non-owner is not part of the obsolete state matrix")
            }
            try await fixture.resolver.retain(
                contextID: fixture.contextID,
                tabID: TabID(),
                documentID: documentID,
                controller: controller,
                language: "plaintext"
            )
            let stateBarrier = AsyncBarrier()
            fixture.bridge.rebuildStateObserver = { observedDocumentID, state in
                guard observedDocumentID == documentID else { return }
                switch (kind, state) {
                case (.closed, .closed), (.resynchronizing, .resynchronizing):
                    await stateBarrier.pause()
                default:
                    XCTFail("unexpected observed rebuild state \(state) for \(kind)")
                }
            }
            try await fixture.bridge.prepareForWebContentRestart(generation: 2)
            let readyTask = Task { @MainActor in
                return await fixture.bridge.handleMessageBody([
                    "type": "ready", "webContentGeneration": 2,
                ])
            }
            await stateBarrier.waitUntilPaused()
            let restartEntered = expectation(description: "generation-3 \(kind) restart entered")
            let restarting = Task { @MainActor in
                restartEntered.fulfill()
                try await fixture.bridge.prepareForWebContentRestart(generation: 3)
            }
            await fulfillment(of: [restartEntered], timeout: 2)
            fixture.bridge.rebuildStateObserver = nil
            await stateBarrier.resume()
            let reply = await readyTask.value
            try await restarting.value

            XCTAssertEqual(reply, .failure(.staleGeneration), "\(kind)")
            XCTAssertTrue(fixture.errors.values.isEmpty, "\(kind)")
            XCTAssertEqual(fixture.bridge.webContentGeneration, 3, "\(kind)")
        }
    }

    func testPostReadyDifferentDocumentOpenAndFailedSelectionKeepRealJSAndNativeOnOldReference() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let first = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "selection-a.txt",
            text: "round three selected A",
            writable: true,
            contexts: [fixture.contextID]
        )
        let firstReference = MonacoDocumentReference(
            workspaceContextID: fixture.contextID,
            tabID: first.tabIDs[0],
            documentID: first.documentID
        )
        try fixture.resolver.select(
            contextID: firstReference.workspaceContextID,
            tabID: firstReference.tabID,
            documentID: firstReference.documentID
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("selection runtime did not load")
        }
        let firstURI = try MonacoFileURI.make(
            environmentID: first.environmentID,
            path: RelativePath("selection-a.txt")
        )
        let firstSelected = try await waitUntil {
            (try? await javaScriptSelectedURI(in: controller.webView)) == firstURI
        }
        XCTAssertTrue(firstSelected)

        let secondContext = WorkspaceContextID.conversation(ConversationID())
        let second = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "selection-b.txt",
            text: "round three background B",
            writable: true,
            contexts: [secondContext]
        )
        let secondReference = MonacoDocumentReference(
            workspaceContextID: secondContext,
            tabID: second.tabIDs[0],
            documentID: second.documentID
        )
        let actualSecondReference = try XCTUnwrap(
            fixture.resolver.session(documentID: second.documentID)?.references.first
        )
        let secondURI = try MonacoFileURI.make(
            environmentID: second.environmentID,
            path: RelativePath("selection-b.txt")
        )
        let secondOpened = try await waitUntil {
            (try? await javaScriptReferenceCount(secondURI, in: controller.webView)) == 1
        }
        XCTAssertTrue(secondOpened)
        XCTAssertEqual(actualSecondReference.tabID, secondReference.tabID)
        XCTAssertEqual(fixture.resolver.selectedReference, firstReference)
        let selectedAfterOpen = try await javaScriptSelectedURI(in: controller.webView)
        XCTAssertEqual(selectedAfterOpen, firstURI)

        _ = try await controller.webView.callAsyncJavaScript(
            """
            globalThis.round3RealReceive = globalThis.cockpitMonacoReceive;
            globalThis.round3SelectMode = 'known';
            globalThis.round3SelectedDocumentID = documentID;
            globalThis.cockpitMonacoReceive = message => {
              if (message.type === 'selectModel'
                  && message.documentID === globalThis.round3SelectedDocumentID) {
                if (globalThis.round3SelectMode === 'known') {
                  return { ok: false, error: 'unknown-document' };
                }
                if (globalThis.round3SelectMode === 'throw') {
                  throw new Error('forced WebKit selection failure');
                }
              }
              return globalThis.round3RealReceive(message);
            };
            return true;
            """,
            arguments: ["documentID": second.documentID.description],
            in: nil,
            contentWorld: .page
        )
        do {
            try await fixture.bridge.select(
                contextID: actualSecondReference.workspaceContextID,
                tabID: actualSecondReference.tabID,
                documentID: actualSecondReference.documentID
            )
            XCTFail("known JS selection failure was accepted")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .unknownDocument)
        }
        XCTAssertEqual(fixture.resolver.selectedReference, firstReference)
        let selectedAfterKnownFailure = try await javaScriptSelectedURI(in: controller.webView)
        XCTAssertEqual(selectedAfterKnownFailure, firstURI)

        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.round3SelectMode = 'throw'; return true",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        do {
            try await fixture.bridge.select(
                contextID: actualSecondReference.workspaceContextID,
                tabID: actualSecondReference.tabID,
                documentID: actualSecondReference.documentID
            )
            XCTFail("WebKit selection failure was accepted")
        } catch {
            XCTAssertEqual(error as? MonacoBridgeError, .transportFailure)
        }
        XCTAssertEqual(fixture.resolver.selectedReference, firstReference)
        let selectedAfterTransportFailure = try await javaScriptSelectedURI(in: controller.webView)
        XCTAssertEqual(selectedAfterTransportFailure, firstURI)

        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.round3SelectMode = 'pass'; return true",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        try await fixture.bridge.select(
            contextID: actualSecondReference.workspaceContextID,
            tabID: actualSecondReference.tabID,
            documentID: actualSecondReference.documentID
        )
        XCTAssertEqual(fixture.resolver.selectedReference, actualSecondReference)
        let selectedAfterRetry = try await javaScriptSelectedURI(in: controller.webView)
        XCTAssertEqual(selectedAfterRetry, secondURI)
        controller.tearDown()
    }

    func testCrashSelectedRestoreReportsExactOwnerRetainsFirstFailureAttemptsAllAndRetries() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let ids = [
            DocumentID(UUID(uuidString: "00000000-0000-4000-8000-000000000011")!),
            DocumentID(UUID(uuidString: "00000000-0000-4000-8000-000000000012")!),
            DocumentID(UUID(uuidString: "00000000-0000-4000-8000-000000000013")!),
        ]
        var sessions: [AttachedSession] = []
        for (index, documentID) in ids.enumerated() {
            sessions.append(try await attachSession(
                fixture: fixture,
                clientID: clientID,
                documentID: documentID,
                path: "selected-restore-\(index).txt",
                writable: true,
                contexts: [fixture.contextID]
            ))
        }
        let selected = sessions[1]
        try fixture.resolver.select(
            contextID: fixture.contextID,
            tabID: selected.tabIDs[0],
            documentID: selected.documentID
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("selected restore generation 1 runtime did not load")
        }
        let initialReady = try await waitUntil {
            (try? await javaScriptModelCount(in: controller.webView)) == sessions.count
        }
        XCTAssertTrue(initialReady)

        try await fixture.bridge.prepareForWebContentRestart(generation: 2)
        try await loadRuntimeWithoutAutomaticReady(controller)
        _ = try await controller.webView.callAsyncJavaScript(
            """
            globalThis.round3CrashReceive = globalThis.cockpitMonacoReceive;
            globalThis.round3CrashAttempts = [];
            globalThis.round3FailOpenDocumentID = failOpenDocumentID;
            globalThis.round3SelectedDocumentID = selectedDocumentID;
            globalThis.round3RejectSelected = true;
            globalThis.round3ThrowSelected = false;
            globalThis.cockpitMonacoReceive = message => {
              if (message.type === 'open') {
                globalThis.round3CrashAttempts.push(message.documentID);
                if (message.documentID === globalThis.round3FailOpenDocumentID) {
                  return { ok: false, error: 'file-missing' };
                }
              }
              if (message.type === 'selectModel'
                  && message.documentID === globalThis.round3SelectedDocumentID) {
                if (globalThis.round3ThrowSelected) throw new Error('selected restore transport');
                if (globalThis.round3RejectSelected) {
                  return { ok: false, error: 'unknown-document' };
                }
              }
              return globalThis.round3CrashReceive(message);
            };
            return true;
            """,
            arguments: [
                "failOpenDocumentID": sessions[0].documentID.description,
                "selectedDocumentID": selected.documentID.description,
            ],
            in: nil,
            contentWorld: .page
        )
        let firstReady = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(firstReady, .failure(.fileMissing))
        let firstAttempts = try await controller.webView.callAsyncJavaScript(
            "return globalThis.round3CrashAttempts",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String]
        XCTAssertEqual(Set(firstAttempts ?? []), Set(ids.map(\.description)))
        XCTAssertEqual(fixture.errors.values[sessions[0].documentID], .fileMissing)
        XCTAssertEqual(fixture.errors.values[selected.documentID], .unknownDocument)

        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.round3FailOpenDocumentID = null; globalThis.round3RejectSelected = false; globalThis.round3CrashAttempts = []; return true",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let generationTwoRetry = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 2,
        ])
        XCTAssertEqual(generationTwoRetry, .success(nil))

        try await fixture.bridge.prepareForWebContentRestart(generation: 3)
        try await loadRuntimeWithoutAutomaticReady(controller)
        _ = try await controller.webView.callAsyncJavaScript(
            """
            globalThis.round3CrashReceive = globalThis.cockpitMonacoReceive;
            globalThis.round3CrashAttempts = [];
            globalThis.round3SelectedDocumentID = selectedDocumentID;
            globalThis.round3ThrowSelected = true;
            globalThis.cockpitMonacoReceive = message => {
              if (message.type === 'open') globalThis.round3CrashAttempts.push(message.documentID);
              if (message.type === 'selectModel'
                  && message.documentID === globalThis.round3SelectedDocumentID
                  && globalThis.round3ThrowSelected) {
                throw new Error('selected restore transport');
              }
              return globalThis.round3CrashReceive(message);
            };
            return true;
            """,
            arguments: ["selectedDocumentID": selected.documentID.description],
            in: nil,
            contentWorld: .page
        )
        let transportReady = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 3,
        ])
        XCTAssertEqual(transportReady, .failure(.transportFailure))
        let transportAttempts = try await controller.webView.callAsyncJavaScript(
            "return globalThis.round3CrashAttempts",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String]
        XCTAssertEqual(Set(transportAttempts ?? []), Set(ids.map(\.description)))
        XCTAssertEqual(fixture.errors.values[selected.documentID], .transportFailure)

        _ = try await controller.webView.callAsyncJavaScript(
            "globalThis.round3ThrowSelected = false; globalThis.round3CrashAttempts = []; return true",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let generationThreeRetry = await fixture.bridge.handleMessageBody([
            "type": "ready", "webContentGeneration": 3,
        ])
        XCTAssertEqual(generationThreeRetry, .success(nil))
        controller.tearDown()
    }

    func testExistingSessionRetainCannotRestorePreAwaitAuthoritativePath() async throws {
        let clientID = ClientInstanceID()
        let fixture = makeBridgeFixture(clientID: clientID)
        let attached = try await attachSession(
            fixture: fixture,
            clientID: clientID,
            path: "retain-source.txt",
            writable: true,
            contexts: [fixture.contextID]
        )
        let controller = MonacoEditorViewController(
            bridge: fixture.bridge,
            runtimeBundleURL: runtimeBundleURL()
        )
        controller.loadViewIfNeeded()
        controller.loadRuntime()
        guard try await waitForRuntimeLoad(controller.webView) else {
            return XCTFail("retain metadata runtime did not load")
        }
        let sourceURI = try MonacoFileURI.make(
            environmentID: attached.environmentID,
            path: RelativePath("retain-source.txt")
        )
        let sourceReady = try await waitUntil {
            (try? await javaScriptReferenceCount(sourceURI, in: controller.webView)) == 1
        }
        XCTAssertTrue(sourceReady)

        let barrier = AsyncBarrier()
        fixture.resolver.setReferenceLifecycle(
            retain: { session, reference in
                await barrier.pause()
                let snapshot: DocumentSnapshot
                let writable: Bool
                switch await session.controller.state {
                case let .ready(value):
                    snapshot = value
                    writable = true
                case let .readOnly(value):
                    snapshot = value
                    writable = false
                case .closed:
                    throw MonacoBridgeError.unknownDocument
                case .resynchronizing:
                    throw MonacoBridgeError.resynchronizing
                }
                session.remember(snapshot)
                let access = MonacoDocumentAccess(
                    reference: reference,
                    uri: try MonacoFileURI.make(
                        environmentID: snapshot.environmentID,
                        path: snapshot.relativePath
                    ),
                    lastAcceptedClientSequence: snapshot.lastAcceptedClientSequence,
                    editLeaseID: writable ? snapshot.currentLease?.id : nil,
                    writable: writable
                )
                try await dispatchExactSuccess(.open(
                    webContentGeneration: 1,
                    access: access,
                    language: session.language,
                    snapshot: snapshot,
                    viewState: nil
                ), to: controller.webView)
            },
            release: { _, _ in }
        )
        let secondContext = WorkspaceContextID.conversation(ConversationID())
        let secondTabID = TabID()
        let retaining = Task { @MainActor in
            try await fixture.resolver.retain(
                contextID: secondContext,
                tabID: secondTabID,
                documentID: attached.documentID,
                controller: attached.controller,
                language: "plaintext"
            )
        }
        await barrier.waitUntilPaused()
        let destinationPath = try RelativePath("retain-destination.txt")
        try await attached.transport.setSnapshotPath(destinationPath)
        _ = try await attached.controller.resynchronize(requestWriteAccess: true)
        await barrier.resume()
        try await retaining.value

        guard case let .ready(controllerSnapshot) = await attached.controller.state else {
            return XCTFail("controller lost ready destination state")
        }
        let destinationURI = try MonacoFileURI.make(
            environmentID: attached.environmentID,
            path: destinationPath
        )
        XCTAssertEqual(controllerSnapshot.relativePath, destinationPath)
        let destinationReferenceCount = try await javaScriptReferenceCount(
            destinationURI,
            in: controller.webView
        )
        XCTAssertEqual(destinationReferenceCount, 1)
        let session = try XCTUnwrap(
            fixture.resolver.session(documentID: attached.documentID)
        )
        XCTAssertEqual(session.lastAuthoritativeEnvironmentID, attached.environmentID)
        XCTAssertEqual(session.lastAuthoritativePath, destinationPath)

        let relocationBridge = MonacoBridge(
            resolver: fixture.resolver,
            sink: { try await dispatchExactSuccess($0, to: controller.webView) }
        )
        let token = try await relocationBridge.prepareRelocation(
            workspaceContextID: secondContext,
            operation: .rename(source: destinationPath, newName: "retain-final.txt")
        )
        XCTAssertEqual(token.affectedDocumentIDs, [attached.documentID])
        try relocationBridge.cancelRelocation(token)
        controller.tearDown()
    }

    func testDecoderRejectsUnknownAndMissingKeysForEveryMonacoToNativeVariantAndUnsafeBounds() throws {
        let contextID = WorkspaceContextID.project(ProjectID())
        let tabID = TabID()
        let documentID = DocumentID()
        let environmentID = EnvironmentID()
        let leaseID = EditLeaseID()
        let viewState = try makeViewState(line: 1)
        let variants: [[String: Any]] = [
            ["type": "ready", "webContentGeneration": 1],
            try editBody(
                generation: 1,
                contextID: contextID,
                tabID: tabID,
                documentID: documentID,
                environmentID: environmentID,
                leaseID: leaseID,
                changes: [["offset": 0, "length": 0, "replacement": "x"]]
            ),
            try saveBody(
                contextID: contextID,
                tabID: tabID,
                documentID: documentID,
                environmentID: environmentID,
                leaseID: leaseID,
                writable: true
            ),
            try viewStateBody(
                contextID: contextID,
                tabID: tabID,
                documentID: documentID,
                environmentID: environmentID,
                leaseID: leaseID,
                value: viewState
            ),
        ]
        for variant in variants {
            var unknown = variant
            unknown["unexpected"] = true
            XCTAssertThrowsError(try MonacoMessageCodec.decode(unknown)) {
                XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema)
            }
            for key in variant.keys {
                var missing = variant
                missing.removeValue(forKey: key)
                XCTAssertThrowsError(try MonacoMessageCodec.decode(missing)) {
                    XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema)
                }
            }
        }
        var unsafe = variants[1]
        unsafe["baseVersion"] = Double(documentJavaScriptMaximum) + 1
        XCTAssertThrowsError(try MonacoMessageCodec.decode(unsafe)) {
            XCTAssertEqual($0 as? MonacoBridgeError, .invalidSchema)
        }
    }
}

private enum MonacoTestScaffoldFailure: Error {
    case missingCSP
    case runtimeDidNotLoad
}

private enum UnrelatedInvalidSessionKind: CaseIterable {
    case closed
    case resynchronizing
    case nonOwnerReady
}

@MainActor
private final class PausingNativeSink {
    enum MessageKind {
        case open
        case dispose
        case select

        func matches(_ message: MonacoNativeMessage) -> Bool {
            switch (self, message) {
            case (.open, .open(_, _, _, _, _)), (.dispose, .disposeModel(_, _)): true
            case (.select, .selectModel(_, _, _)): true
            default: false
            }
        }
    }

    private let pauseOn: MessageKind
    private let downstream: MonacoNativeMessageSink
    private var didPause = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var messages: [MonacoNativeMessage] = []

    init(pauseOn: MessageKind, downstream: @escaping MonacoNativeMessageSink) {
        self.pauseOn = pauseOn
        self.downstream = downstream
    }

    var messageCount: Int { messages.count }

    func send(_ message: MonacoNativeMessage) async throws {
        messages.append(message)
        if !didPause, pauseOn.matches(message) {
            didPause = true
            await withCheckedContinuation { continuation in
                pauseContinuation = continuation
                let waiters = pauseWaiters
                pauseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        try await downstream(message)
    }

    func waitUntilPaused() async {
        if pauseContinuation != nil { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume()
    }
}

private actor AsyncBarrier {
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { pauseContinuation = $0 }
        isPaused = false
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private func dispatchExactSuccess(
    _ message: MonacoNativeMessage,
    to webView: WKWebView
) async throws {
    let reply = try await sendNativeMessage(message, to: webView)
    guard Set(reply.keys) == ["ok"], reply["ok"] as? Bool == true else {
        if Set(reply.keys) == ["ok", "error"],
           reply["ok"] as? Bool == false,
           let code = reply["error"] as? String,
           let error = testBridgeError(code) {
            throw error
        }
        throw MonacoBridgeError.transportFailure
    }
}

private func testBridgeError(_ code: String) -> MonacoBridgeError? {
    switch code {
    case MonacoBridgeError.invalidSchema.wireCode: .invalidSchema
    case MonacoBridgeError.staleGeneration.wireCode: .staleGeneration
    case MonacoBridgeError.staleDocumentState.wireCode: .staleDocumentState
    case MonacoBridgeError.unknownDocument.wireCode: .unknownDocument
    case MonacoBridgeError.readOnly.wireCode: .readOnly
    case MonacoBridgeError.resynchronizing.wireCode: .resynchronizing
    case MonacoBridgeError.fileMissing.wireCode: .fileMissing
    case MonacoBridgeError.transportFailure.wireCode: .transportFailure
    default: nil
    }
}

@MainActor
private func loadRuntimeWithoutAutomaticReady(
    _ controller: MonacoEditorViewController
) async throws {
    let userContentController = controller.webView.configuration.userContentController
    userContentController.removeScriptMessageHandler(
        forName: "cockpitMonaco",
        contentWorld: .page
    )
    controller.loadRuntime()
    guard try await waitForRuntimeLoad(controller.webView) else {
        throw MonacoTestScaffoldFailure.runtimeDidNotLoad
    }
    userContentController.addScriptMessageHandler(
        try XCTUnwrap(controller.forwarder),
        contentWorld: .page,
        name: "cockpitMonaco"
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
private func javaScriptReferenceCount(_ uri: String, in webView: WKWebView) async throws -> Int {
    let result = try await webView.callAsyncJavaScript(
        "return globalThis.cockpitEditorProtocol.referenceCount(uri)",
        arguments: ["uri": uri],
        in: nil,
        contentWorld: .page
    )
    return try XCTUnwrap(result as? Int)
}

@MainActor
private func javaScriptModelCount(in webView: WKWebView) async throws -> Int {
    let result = try await webView.callAsyncJavaScript(
        "return globalThis.cockpitEditorProtocol.modelCount()",
        arguments: [:],
        in: nil,
        contentWorld: .page
    )
    return try XCTUnwrap(result as? Int)
}

@MainActor
private func javaScriptSelectedURI(in webView: WKWebView) async throws -> String? {
    let value = try await webView.callAsyncJavaScript(
        "return document.querySelector('[data-uri]')?.getAttribute('data-uri') ?? null",
        arguments: [:],
        in: nil,
        contentWorld: .page
    )
    return value as? String
}

@MainActor
private func sendNativeMessage(
    _ message: MonacoNativeMessage,
    to webView: WKWebView
) async throws -> [String: Any] {
    let object = try MonacoMessageCodec.javaScriptObject(for: message)
    let result = try await webView.callAsyncJavaScript(
        "return globalThis.cockpitMonacoReceive(message)",
        arguments: ["message": object],
        in: nil,
        contentWorld: .page
    )
    return try XCTUnwrap(result as? [String: Any])
}

private func makeOpenMessage(
    contextID: WorkspaceContextID,
    tabID: TabID,
    documentID: DocumentID,
    environmentID: EnvironmentID,
    path: RelativePath,
    text: String
) throws -> MonacoNativeMessage {
    let access = MonacoDocumentAccess(
        reference: MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        ),
        uri: try MonacoFileURI.make(environmentID: environmentID, path: path),
        lastAcceptedClientSequence: 0,
        editLeaseID: nil,
        writable: false
    )
    return .open(
        webContentGeneration: 1,
        access: access,
        language: "plaintext",
        snapshot: try makeSnapshot(
            documentID: documentID,
            environmentID: environmentID,
            path: path,
            text: text,
            lease: nil
        ),
        viewState: nil
    )
}

private func access(from message: MonacoNativeMessage) -> MonacoDocumentAccess {
    guard case let .open(_, access, _, _, _) = message else {
        preconditionFailure("expected open message")
    }
    return access
}

@MainActor
private func attachUnrelatedInvalidSession(
    _ kind: UnrelatedInvalidSessionKind,
    fixture: BridgeFixture,
    clientID: ClientInstanceID,
    path: RelativePath
) async throws {
    let documentID = DocumentID()
    let environmentID = EnvironmentID()
    switch kind {
    case .closed:
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: path
        )
        let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
        try await fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: TabID(),
            documentID: documentID,
            controller: controller,
            language: "plaintext"
        )
    case .resynchronizing:
        let transport = try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: path
        )
        let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
        _ = try await controller.open(in: environmentID, at: path, requestWriteAccess: true)
        try await fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: TabID(),
            documentID: documentID,
            controller: controller,
            language: "plaintext"
        )
        await transport.setFlushError(.recoveryRequired)
        _ = try? await controller.flush()
    case .nonOwnerReady:
        let transport = try TestDocumentTransport.ready(
            clientID: ClientInstanceID(),
            documentID: documentID,
            environmentID: environmentID,
            path: path
        )
        let controller = DocumentClientController(clientInstanceID: clientID, transport: transport)
        _ = try await controller.open(in: environmentID, at: path, requestWriteAccess: true)
        try await fixture.resolver.retain(
            contextID: fixture.contextID,
            tabID: TabID(),
            documentID: documentID,
            controller: controller,
            language: "plaintext"
        )
    }
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
           (try? await webView.evaluateJavaScript(
               "document.readyState === 'complete' && typeof globalThis.cockpitMonacoReceive === 'function'"
           )) as? Bool == true {
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
    recorder: ViewStateRecorder = ViewStateRecorder(),
    storeViewState: MonacoViewStateStorer? = nil
) -> BridgeFixture {
    let contextID = WorkspaceContextID.project(ProjectID())
    let sink = MessageSink()
    let errors = ErrorRecorder()
    let storer: MonacoViewStateStorer = storeViewState ?? { contextID, tabID, documentID, value in
        await recorder.store(
            contextID: contextID,
            tabID: tabID,
            documentID: documentID,
            value: value
        )
    }
    let resolver = MonacoWindowSessionResolver(
        clientInstanceID: clientID,
        loadViewState: { contextID, tabID, documentID in
            await recorder.load(contextID: contextID, tabID: tabID, documentID: documentID)
        },
        storeViewState: storer
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
    private var applyBarrier: AsyncBarrier?
    private var saveBarrier: AsyncBarrier?

    init(current: DocumentSnapshot, acquired: EditLease) {
        self.current = current
        self.acquired = acquired
    }

    static func ready(
        clientID: ClientInstanceID,
        documentID: DocumentID,
        environmentID: EnvironmentID,
        path: RelativePath,
        text: String = "authoritative\n"
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
                text: text,
                lease: nil
            ),
            acquired: lease
        )
    }

    static func readOnly(
        remoteClientID: ClientInstanceID,
        documentID: DocumentID,
        environmentID: EnvironmentID,
        path: RelativePath,
        text: String = "authoritative\n"
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
                text: text,
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
    func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        if let barrier = applyBarrier {
            applyBarrier = nil
            await barrier.pause()
        }
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
    func save(
        documentID: DocumentID,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DocumentSnapshot {
        if let barrier = saveBarrier {
            saveBarrier = nil
            await barrier.pause()
        }
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
    func pauseNextApply(at barrier: AsyncBarrier) { applyBarrier = barrier }
    func pauseNextSave(at barrier: AsyncBarrier) { saveBarrier = barrier }
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
    try await fixture.resolver.retain(
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
    documentID: DocumentID = DocumentID(),
    path: String,
    text: String = "authoritative\n",
    writable: Bool,
    contexts: [WorkspaceContextID]
) async throws -> AttachedSession {
    let environmentID = EnvironmentID()
    let transport = writable
        ? try TestDocumentTransport.ready(
            clientID: clientID,
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath(path),
            text: text
        )
        : try TestDocumentTransport.readOnly(
            remoteClientID: ClientInstanceID(),
            documentID: documentID,
            environmentID: environmentID,
            path: RelativePath(path),
            text: text
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
        try await fixture.resolver.retain(
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
    lastAcceptedClientSequence: UInt64 = 0,
    lease: EditLease?
) throws -> DocumentSnapshot {
    try DocumentSnapshot(
        validatingDocumentID: documentID,
        environmentID: environmentID,
        relativePath: path,
        text: text,
        documentVersion: documentVersion,
        persistedVersion: 0,
        lastAcceptedClientSequence: lastAcceptedClientSequence,
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
