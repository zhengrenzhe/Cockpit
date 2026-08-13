import Foundation
import XCTest
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes
@testable import Cockpit

@MainActor
final class TabCommandControllerTests: XCTestCase {
    func testShellCodexAndClaudeCreateFreshSessionsAndDetachedListIsContextLocal() async throws {
        let fixture = try TabCommandFixture()
        let terminal = TabTerminalRecorder()
        let controller = fixture.makeController(terminal: terminal)

        let shell = try await controller.createTab(
            for: .shell,
            tabID: TabID(),
            in: fixture.project
        )
        let codex = try await controller.createTab(
            for: .codex,
            tabID: TabID(),
            in: fixture.project
        )
        let claude = try await controller.createTab(
            for: .claude,
            tabID: TabID(),
            in: fixture.project
        )
        let requests = terminal.createRequests

        XCTAssertEqual(requests.map(\.request.kind), [.shell, .agent(.codex), .agent(.claude)])
        XCTAssertEqual(Set(requests.map(\.request.idempotencyKey)).count, 3)
        XCTAssertEqual(requests.map(\.active.contextID), Array(repeating: fixture.project.contextID, count: 3))
        XCTAssertEqual(shell, .shell(terminal.createdSessions[0].sessionID))
        XCTAssertEqual(codex, .codex(terminal.createdSessions[1].sessionID))
        XCTAssertEqual(claude, .claude(terminal.createdSessions[2].sessionID))

        terminal.listedSessions = [
            try fixture.session(state: .running),
            try fixture.session(state: .committed),
            try fixture.session(state: .preparing),
            try fixture.session(state: .exited),
        ]
        let excluded = terminal.listedSessions[0].sessionID
        let detached = try await controller.detachedTerminals(
            in: fixture.project,
            excluding: [excluded]
        )
        XCTAssertEqual(detached.map(\.sessionID), [terminal.listedSessions[1].sessionID])
    }

    func testCreateRejectsTerminalKindThatDoesNotMatchTheRequestedTab() async throws {
        let fixture = try TabCommandFixture()
        let terminal = TabTerminalRecorder()
        terminal.createResults = [
            .success(try fixture.session(state: .running, kind: .shell)),
        ]
        let controller = fixture.makeController(terminal: terminal)

        do {
            _ = try await controller.createTab(
                for: .codex,
                tabID: TabID(),
                in: fixture.project
            )
            XCTFail("expected mismatched terminal kind to be rejected")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .coderInvalidValue)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReattachOffersOnlyCurrentContextDetachedSessionsAndPreservesTerminalKind() async throws {
        let fixture = try TabCommandFixture()
        let terminal = TabTerminalRecorder()
        let attached = try fixture.session(state: .running, kind: .shell)
        let detachedClaude = try fixture.session(
            state: .running,
            kind: .agent(.claude)
        )
        let finished = try fixture.session(
            state: .exited,
            kind: .agent(.codex),
            exitStatus: 17
        )
        terminal.listedSessions = [attached, detachedClaude, finished]
        let picker = TabDetachedTerminalPicker(values: [detachedClaude])
        let controller = fixture.makeController(
            terminal: terminal,
            detachedTerminalPicker: picker.pick
        )

        let result = try await controller.reattachTerminal(
            in: fixture.project,
            excluding: [attached.sessionID]
        )

        XCTAssertEqual(result, .claude(detachedClaude.sessionID))
        XCTAssertEqual(picker.candidates, [[detachedClaude]])
        XCTAssertEqual(terminal.listContexts, [fixture.project])
    }

    func testAgentRestartUsesFreshSessionAndLeavesExitedRecordIntact() async throws {
        let fixture = try TabCommandFixture()
        let terminal = TabTerminalRecorder()
        let exited = try fixture.session(
            state: .exited,
            kind: .agent(.codex),
            exitStatus: 23
        )
        let replacement = try fixture.session(
            state: .running,
            kind: .agent(.codex)
        )
        terminal.listedSessions = [exited]
        terminal.createResults = [.success(replacement)]
        let controller = fixture.makeController(terminal: terminal)
        let tabID = TabID()
        let tab = try WorkspaceTab(record: TabRecord(
            validatingID: tabID,
            resource: .terminal(exited.sessionID),
            terminalKind: .codex,
            fileViewState: nil
        ))

        let restarted = try await controller.restartTerminal(
            tab,
            in: fixture.project,
            switchingTo: nil
        )

        XCTAssertEqual(restarted, .codex(replacement.sessionID))
        XCTAssertNotEqual(replacement.sessionID, exited.sessionID)
        XCTAssertEqual(terminal.createRequests.map(\.request.kind), [.agent(.codex)])
        XCTAssertEqual(terminal.listedSessions, [exited])
        XCTAssertEqual(exited.exitStatus, 23)
    }

    func testAgentSelectionRequiredUsesBookmarkForFreshRetryAndCancellationPreservesTypedError() async throws {
        let fixture = try TabCommandFixture()
        let terminal = TabTerminalRecorder()
        terminal.createResults = [
            .failure(TerminalSupervisorCreateError.agentExecutableSelectionRequired(.codex)),
            .success(try fixture.session(state: .running, kind: .agent(.codex))),
        ]
        let bookmark = Data("agent-bookmark".utf8)
        let picked = TabExecutablePicker(values: [bookmark])
        let controller = fixture.makeController(terminal: terminal, executablePicker: picked.pick)

        let result = try await controller.createTab(
            for: .codex,
            tabID: TabID(),
            in: fixture.project
        )
        XCTAssertEqual(result, .codex(terminal.createdSessions[0].sessionID))
        XCTAssertEqual(terminal.createRequests.count, 2)
        XCTAssertNil(terminal.createRequests[0].request.selectedExecutableBookmark)
        XCTAssertEqual(terminal.createRequests[1].request.selectedExecutableBookmark, bookmark)
        XCTAssertNotEqual(
            terminal.createRequests[0].request.idempotencyKey,
            terminal.createRequests[1].request.idempotencyKey
        )
        XCTAssertEqual(picked.profiles, [.codex])

        let cancelledTerminal = TabTerminalRecorder()
        cancelledTerminal.createResults = [
            .failure(TerminalSupervisorCreateError.agentExecutableSelectionRequired(.claude)),
        ]
        let cancelledPicker = TabExecutablePicker(values: [nil])
        let cancelled = fixture.makeController(
            terminal: cancelledTerminal,
            executablePicker: cancelledPicker.pick
        )
        await XCTAssertThrowsTabError(
            TerminalSupervisorCreateError.agentExecutableSelectionRequired(.claude)
        ) {
            _ = try await cancelled.createTab(
                for: .claude,
                tabID: TabID(),
                in: fixture.project
            )
        }
        XCTAssertEqual(cancelledTerminal.createRequests.count, 1)
    }

    func testFileDocumentControllerIsSharedAcrossContextsAndDirtyLastViewerUsesCloseDecision() async throws {
        let fixture = try TabCommandFixture()
        let documentID = DocumentID()
        let path = try RelativePath("Sources/Shared.swift")
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .dirty
            ),
            clientID: fixture.clientInstanceID
        )
        let secondTransport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .dirty
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentSequenceFactory(values: [transport, secondTransport])
        let files = TabFilePicker(values: [
            TabFileSelection(path: path, language: "swift"),
            TabFileSelection(path: path, language: "swift"),
        ])
        let close = TabCloseDecisionRecorder(values: [.discard])
        let controller = fixture.makeController(
            documentFactory: documents.make,
            filePicker: files.pick,
            closeDecision: close.decide
        )
        let projectTabID = TabID()
        let conversationTabID = TabID()

        let first = try await controller.createTab(
            for: .file,
            tabID: projectTabID,
            in: fixture.project
        )
        let second = try await controller.createTab(
            for: .file,
            tabID: conversationTabID,
            in: fixture.conversation
        )
        XCTAssertEqual(first, .file(documentID))
        XCTAssertEqual(second, .file(documentID))
        XCTAssertEqual(documents.calls, [fixture.project, fixture.conversation])
        let firstRetained = await transport.retainedDocumentIDs()
        let secondRetained = await secondTransport.retainedDocumentIDs()
        XCTAssertEqual(firstRetained, [documentID])
        XCTAssertEqual(secondRetained, [documentID])
        let session = try XCTUnwrap(fixture.bridge.resolver.session(documentID: documentID))
        XCTAssertEqual(session.references.count, 2)
        XCTAssertTrue(session.references.contains {
            $0.workspaceContextID == fixture.project.contextID && $0.tabID == projectTabID
        })
        XCTAssertTrue(session.references.contains {
            $0.workspaceContextID == fixture.conversation.contextID && $0.tabID == conversationTabID
        })

        let projectTab = try WorkspaceTab(
            record: TabRecord(
                validatingID: projectTabID,
                resource: .file(documentID),
                fileViewState: .initial()
            )
        )
        let preparedProject = try await controller.prepareClose(projectTab, in: fixture.project)
        XCTAssertTrue(preparedProject)
        XCTAssertEqual(close.snapshots, [])
        XCTAssertEqual(fixture.bridge.resolver.session(documentID: documentID)?.references.count, 2)
        try await controller.finalizeClose(projectTab, in: fixture.project)
        XCTAssertEqual(fixture.bridge.resolver.session(documentID: documentID)?.references.count, 1)
        let firstReleased = await transport.releasedDocumentIDs()
        let secondReleasedBeforeClose = await secondTransport.releasedDocumentIDs()
        XCTAssertEqual(firstReleased, [documentID])
        XCTAssertEqual(secondReleasedBeforeClose, [])
        let closeCountAfterFirst = await transport.closeCount()
        XCTAssertEqual(closeCountAfterFirst, 0)

        let conversationTab = try WorkspaceTab(
            record: TabRecord(
                validatingID: conversationTabID,
                resource: .file(documentID),
                fileViewState: .initial()
            )
        )
        let preparedConversation = try await controller.prepareClose(
            conversationTab,
            in: fixture.conversation
        )
        XCTAssertTrue(preparedConversation)
        XCTAssertEqual(close.snapshots.map(\.documentID), [documentID])
        let discardCount = await transport.discardCount()
        XCTAssertEqual(discardCount, 1)
        XCTAssertNotNil(fixture.bridge.resolver.session(documentID: documentID))
        try await controller.finalizeClose(conversationTab, in: fixture.conversation)
        XCTAssertNil(fixture.bridge.resolver.session(documentID: documentID))
        let secondReleased = await secondTransport.releasedDocumentIDs()
        XCTAssertEqual(secondReleased, [documentID])
        let closeCountAfterLast = await transport.closeCount()
        XCTAssertEqual(closeCountAfterLast, 1)
        let secondCloseCount = await secondTransport.closeCount()
        XCTAssertEqual(secondCloseCount, 1)
    }

    func testPersistedFileTabRestoresByDocumentIDBeforeMonacoSelection() async throws {
        let fixture = try TabCommandFixture()
        let documentID = DocumentID()
        let tabID = TabID()
        let path = try RelativePath("Sources/Persisted.swift")
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let controller = fixture.makeController(documentFactory: { _ in transport })
        let tab = try WorkspaceTab(record: TabRecord(
            validatingID: tabID,
            resource: .file(documentID),
            fileViewState: .initial()
        ))

        try await controller.selectFileTab(tab, in: fixture.project)

        let snapshotDocumentIDs = await transport.snapshotDocumentIDs()
        let openRequestCount = await transport.openRequests().count
        let retainedDocumentIDs = await transport.retainedDocumentIDs()
        let lifecycleEvents = await transport.lifecycleEvents()
        XCTAssertEqual(snapshotDocumentIDs, [documentID, documentID])
        XCTAssertEqual(openRequestCount, 0)
        XCTAssertEqual(retainedDocumentIDs, [documentID])
        XCTAssertEqual(
            lifecycleEvents,
            ["snapshot", "retain", "snapshot", "acquire"]
        )
        let session = try XCTUnwrap(fixture.bridge.resolver.session(documentID: documentID))
        XCTAssertEqual(session.lastAuthoritativeEnvironmentID, fixture.project.environmentID)
        XCTAssertEqual(session.lastAuthoritativePath, path)
        XCTAssertEqual(session.language, "swift")
        XCTAssertEqual(
            fixture.bridge.resolver.selectedReference,
            MonacoDocumentReference(
                workspaceContextID: fixture.project.contextID,
                tabID: tabID,
                documentID: documentID
            )
        )
    }

    func testNewFileRegistersViewerBeforeRequestingWriteLease() async throws {
        let fixture = try TabCommandFixture()
        let documentID = DocumentID()
        let path = try RelativePath("Sources/New.swift")
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let controller = fixture.makeController(
            documentFactory: TabDocumentFactory(transport: transport).make,
            filePicker: TabFilePicker(values: [
                TabFileSelection(path: path, language: "swift"),
            ]).pick
        )

        let result = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )

        XCTAssertEqual(result, .file(documentID))
        let lifecycleEvents = await transport.lifecycleEvents()
        XCTAssertEqual(
            lifecycleEvents,
            ["open", "retain", "snapshot", "acquire"]
        )
    }

    func testDirtyLastViewerCancelKeepsReferenceAndSaveUsesObservedFingerprint() async throws {
        let fixture = try TabCommandFixture()
        let documentID = DocumentID()
        let path = try RelativePath("Dirty.txt")
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .dirty
            ),
            clientID: fixture.clientInstanceID
        )
        let files = TabFilePicker(values: [
            TabFileSelection(path: path, language: "plaintext"),
        ])
        let close = TabCloseDecisionRecorder(values: [.cancel, .save])
        let controller = fixture.makeController(
            documentFactory: TabDocumentFactory(transport: transport).make,
            filePicker: files.pick,
            closeDecision: close.decide
        )
        let tabID = TabID()
        _ = try await controller.createTab(for: .file, tabID: tabID, in: fixture.project)
        let tab = try WorkspaceTab(
            record: TabRecord(
                validatingID: tabID,
                resource: .file(documentID),
                fileViewState: .initial()
            )
        )

        let cancelled = try await controller.close(tab, in: fixture.project)
        XCTAssertFalse(cancelled)
        XCTAssertNotNil(fixture.bridge.resolver.session(documentID: documentID))
        let saved = try await controller.close(tab, in: fixture.project)
        XCTAssertTrue(saved)
        let saveCount = await transport.saveCount()
        XCTAssertEqual(saveCount, 1)
        XCTAssertNil(fixture.bridge.resolver.session(documentID: documentID))
    }

    func testLastViewerDirtyDecisionSerializesAConcurrentRetain() async throws {
        let fixture = try TabCommandFixture()
        let documentID = DocumentID()
        let path = try RelativePath("SharedDirty.txt")
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .dirty
            ),
            clientID: fixture.clientInstanceID
        )
        let close = TabCloseDecisionRecorder(values: [.discard])
        let files = TabFilePicker(values: [
            TabFileSelection(path: path, language: "plaintext"),
            TabFileSelection(path: path, language: "plaintext"),
        ])
        let controller = fixture.makeController(
            documentFactory: TabDocumentFactory(transport: transport).make,
            filePicker: files.pick,
            closeDecision: close.decide
        )
        let firstTabID = TabID()
        _ = try await controller.createTab(
            for: .file,
            tabID: firstTabID,
            in: fixture.project
        )
        let firstTab = try WorkspaceTab(record: TabRecord(
            validatingID: firstTabID,
            resource: .file(documentID),
            fileViewState: .initial()
        ))
        close.pauseNextDecision()

        async let prepared = controller.prepareClose(firstTab, in: fixture.project)
        await close.waitUntilDecisionPaused()
        let secondTabID = TabID()
        async let second = controller.createTab(
            for: .file,
            tabID: secondTabID,
            in: fixture.conversation
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: documentID)?.references.count,
            1
        )

        close.resumeDecision()
        let didPrepare = try await prepared
        let secondKind = try await second
        XCTAssertTrue(didPrepare)
        XCTAssertEqual(secondKind, .file(documentID))
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: documentID)?.references.count,
            2
        )
        try await controller.finalizeClose(firstTab, in: fixture.project)
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: documentID)?.references.count,
            1
        )
    }

    func testRelocationRequiresExactHostResultCancelsFailuresAndRetainsPartialTokens() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let controller = fixture.makeController(workspaceService: workspace)
        let source = try RelativePath("Sources/Feature")
        let operation = FileOperation.rename(source: source, newName: "Renamed")
        let exact = FileOperationResult.relocated(
            from: source,
            to: try RelativePath("Sources/Renamed")
        )
        await workspace.setPerformResult(.success(exact))

        let complete = try await controller.performRelocationWithDisposition(
            operation,
            workspaceContextID: fixture.project.contextID
        )
        XCTAssertEqual(complete, .complete)
        let requests = await workspace.performRequests()
        XCTAssertEqual(requests.map(\.operation), [operation])
        XCTAssertEqual(requests[0].context.workspaceContextID, fixture.project.contextID)
        XCTAssertEqual(requests[0].context.environmentID, fixture.project.environmentID)

        await workspace.setPerformResult(.success(.trashed(path: source)))
        await XCTAssertThrowsTabError(MonacoBridgeError.invalidSchema) {
            _ = try await controller.performRelocationWithDisposition(
                operation,
                workspaceContextID: fixture.project.contextID
            )
        }
        await workspace.setPerformResult(.failure(TabCommandTestError.hostFailure))
        await XCTAssertThrowsTabError(TabCommandTestError.hostFailure) {
            _ = try await controller.performRelocationWithDisposition(
                operation,
                workspaceContextID: fixture.project.contextID
            )
        }
        await workspace.setPerformResult(.success(exact))
        let recovered = try await controller.performRelocationWithDisposition(
            operation,
            workspaceContextID: fixture.project.contextID
        )
        XCTAssertEqual(recovered, .complete)
    }

    func testCompletedRelocationRefreshesDocumentLocatorCacheBeforeReopeningOldAndNewPaths() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let oldPath = try RelativePath("Sources/Feature.swift")
        let newPath = try RelativePath("Sources/Renamed.swift")
        let originalDocumentID = DocumentID()
        let recreatedDocumentID = DocumentID()
        let original = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: originalDocumentID,
                environmentID: fixture.project.environmentID,
                path: oldPath,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let recreated = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: recreatedDocumentID,
                environmentID: fixture.project.environmentID,
                path: oldPath,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let reopenedNewViewer = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: originalDocumentID,
                environmentID: fixture.project.environmentID,
                path: newPath,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentSequenceFactory(values: [
            original,
            recreated,
            reopenedNewViewer,
        ])
        let files = TabFilePicker(values: [
            TabFileSelection(path: oldPath, language: "swift"),
            TabFileSelection(path: oldPath, language: "swift"),
            TabFileSelection(path: newPath, language: "swift"),
        ])
        let controller = fixture.makeController(
            workspaceService: workspace,
            documentFactory: documents.make,
            filePicker: files.pick
        )

        let first = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )
        XCTAssertEqual(first, .file(originalDocumentID))
        await workspace.setPerformHandler {
            try await original.setPath(newPath)
            return .relocated(from: oldPath, to: newPath)
        }
        let disposition = try await controller.performRelocationWithDisposition(
            .rename(source: oldPath, newName: "Renamed.swift"),
            workspaceContextID: fixture.project.contextID
        )
        XCTAssertEqual(disposition, .complete)

        let reopenedOld = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )
        let reopenedNew = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )

        XCTAssertEqual(reopenedOld, .file(recreatedDocumentID))
        XCTAssertEqual(reopenedNew, .file(originalDocumentID))
        XCTAssertEqual(documents.calls.count, 3)
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: originalDocumentID)?.lastAuthoritativePath,
            newPath
        )
    }

    func testConcurrentOpenOfSameLocatorSharesOneControllerAcrossContexts() async throws {
        let fixture = try TabCommandFixture()
        let documentID = DocumentID()
        let path = try RelativePath("Sources/Concurrent.swift")
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let secondViewerTransport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: path,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentSequenceFactory(values: [
            transport,
            secondViewerTransport,
        ])
        let files = TabFilePicker(values: [
            TabFileSelection(path: path, language: "swift"),
            TabFileSelection(path: path, language: "swift"),
        ])
        let controller = fixture.makeController(
            documentFactory: documents.make,
            filePicker: files.pick
        )
        let firstTabID = TabID()
        let secondTabID = TabID()
        await transport.pauseNextOpen()

        async let first = controller.createTab(
            for: .file,
            tabID: firstTabID,
            in: fixture.project
        )
        await transport.waitUntilOpenPaused()
        async let second = controller.createTab(
            for: .file,
            tabID: secondTabID,
            in: fixture.conversation
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(documents.calls.count, 1)
        await transport.resumeOpen()

        let opened = try await [first, second]
        XCTAssertEqual(opened, [.file(documentID), .file(documentID)])
        XCTAssertEqual(documents.calls.count, 2)
        let session = try XCTUnwrap(fixture.bridge.resolver.session(documentID: documentID))
        XCTAssertEqual(session.references.count, 2)
    }

    func testOpenWaitsUntilRelocationCommitBeforeResolvingTheSourceLocator() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let source = try RelativePath("Sources/Racing.swift")
        let destination = try RelativePath("Sources/Renamed.swift")
        let originalDocumentID = DocumentID()
        let recreatedDocumentID = DocumentID()
        let original = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: originalDocumentID,
                environmentID: fixture.project.environmentID,
                path: source,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let recreated = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: recreatedDocumentID,
                environmentID: fixture.project.environmentID,
                path: source,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentSequenceFactory(values: [original, recreated])
        let files = TabFilePicker(values: [
            TabFileSelection(path: source, language: "swift"),
            TabFileSelection(path: source, language: "swift"),
        ])
        let controller = fixture.makeController(
            workspaceService: workspace,
            documentFactory: documents.make,
            filePicker: files.pick
        )
        _ = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )
        await workspace.pauseNextPerform()
        await workspace.setPerformHandler {
            try await original.setPath(destination)
            return .relocated(from: source, to: destination)
        }

        let relocation = Task {
            try await controller.performRelocationWithDisposition(
                .rename(source: source, newName: "Renamed.swift"),
                workspaceContextID: fixture.project.contextID
            )
        }
        await workspace.waitUntilPerformPaused()
        let secondTabID = TabID()
        let opening = Task {
            try await controller.createTab(
                for: .file,
                tabID: secondTabID,
                in: fixture.conversation
            )
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: originalDocumentID)?.references.count,
            1
        )
        await workspace.resumePerform()
        let relocationDisposition = try await relocation.value
        let opened = try await opening.value
        XCTAssertEqual(relocationDisposition, .complete)
        XCTAssertEqual(opened, .file(recreatedDocumentID))
        XCTAssertEqual(documents.calls.count, 2)
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: originalDocumentID)?.references.count,
            1
        )
    }

    func testOpenWaitsForAnIncompleteRelocationUntilRetryCompletes() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let source = try RelativePath("Sources/Pending.swift")
        let destination = try RelativePath("Sources/PendingRenamed.swift")
        let originalDocumentID = DocumentID()
        let duplicateDocumentID = DocumentID()
        let original = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: originalDocumentID,
                environmentID: fixture.project.environmentID,
                path: source,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let duplicate = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: duplicateDocumentID,
                environmentID: fixture.project.environmentID,
                path: destination,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentSequenceFactory(values: [original, duplicate])
        let files = TabFilePicker(values: [
            TabFileSelection(path: source, language: "swift"),
            TabFileSelection(path: destination, language: "swift"),
        ])
        let controller = fixture.makeController(
            workspaceService: workspace,
            documentFactory: documents.make,
            filePicker: files.pick
        )
        _ = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )
        await original.failNextSnapshots(1)
        await workspace.setPerformHandler {
            try await original.setPath(destination)
            return .relocated(from: source, to: destination)
        }
        let partial = try await controller.performRelocationWithDisposition(
            .rename(source: source, newName: "PendingRenamed.swift"),
            workspaceContextID: fixture.project.contextID
        )
        guard case .incomplete = partial else {
            return XCTFail("expected incomplete relocation")
        }
        let token = try XCTUnwrap(controller.pendingRelocationTokens.first)
        let secondTabID = TabID()
        let opening = Task {
            try await controller.createTab(
                for: .file,
                tabID: secondTabID,
                in: fixture.conversation
            )
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(documents.calls.count, 1)
        let retried = try await controller.retryRelocation(token)
        let opened = try await opening.value
        XCTAssertEqual(retried, .complete)
        XCTAssertEqual(opened, .file(originalDocumentID))
        XCTAssertEqual(documents.calls.count, 2)
        XCTAssertNil(fixture.bridge.resolver.session(documentID: duplicateDocumentID))
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: originalDocumentID)?.references.count,
            2
        )
    }

    func testRelocationRecoveryIsSingleFlightAndReleasesTheFileGateOnce() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let source = try RelativePath("Sources/Recovery.swift")
        let destination = try RelativePath("Sources/RecoveryRenamed.swift")
        let originalDocumentID = DocumentID()
        let duplicateDocumentID = DocumentID()
        let original = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: originalDocumentID,
                environmentID: fixture.project.environmentID,
                path: source,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let duplicate = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: duplicateDocumentID,
                environmentID: fixture.project.environmentID,
                path: destination,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentSequenceFactory(values: [original, duplicate])
        let files = TabFilePicker(values: [
            TabFileSelection(path: source, language: "swift"),
            TabFileSelection(path: destination, language: "swift"),
        ])
        let controller = fixture.makeController(
            workspaceService: workspace,
            documentFactory: documents.make,
            filePicker: files.pick
        )
        _ = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.project
        )
        await original.failNextSnapshots(1)
        await workspace.setPerformHandler {
            try await original.setPath(destination)
            return .relocated(from: source, to: destination)
        }
        let partial = try await controller.performRelocationWithDisposition(
            .rename(source: source, newName: "RecoveryRenamed.swift"),
            workspaceContextID: fixture.project.contextID
        )
        guard case .incomplete = partial else {
            return XCTFail("expected incomplete relocation")
        }
        let token = try XCTUnwrap(controller.pendingRelocationTokens.first)
        let recovery = TabRelocationRecoveryBarrier()
        controller.relocationRecoveryObserver = recovery.observe

        let retry = Task {
            try await controller.retryRelocation(token)
        }
        await recovery.waitUntilPaused()
        let opening = Task {
            try await controller.createTab(
                for: .file,
                tabID: TabID(),
                in: fixture.conversation
            )
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(documents.calls.count, 1)

        var abandonError: (any Error)?
        do {
            _ = try await controller.abandonRelocation(token)
        } catch {
            abandonError = error
        }
        XCTAssertEqual(
            abandonError as? MonacoBridgeError,
            .staleDocumentState
        )
        XCTAssertEqual(recovery.observedRequestIDs, [token.id])
        XCTAssertEqual(documents.calls.count, 1)

        recovery.resume()
        let retryDisposition = try await retry.value
        let opened = try await opening.value
        XCTAssertEqual(retryDisposition, .complete)
        XCTAssertEqual(opened, .file(originalDocumentID))
        XCTAssertEqual(documents.calls.count, 2)
        XCTAssertEqual(controller.pendingRelocationTokens, [])
        controller.relocationRecoveryObserver = nil
    }

    func testCloseWaitsUntilRelocationCommitsItsFrozenReferences() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let source = try RelativePath("Sources/CloseRace.swift")
        let destination = try RelativePath("Sources/CloseRaceRenamed.swift")
        let documentID = DocumentID()
        let transport = try TabDocumentTransport(
            snapshot: fixture.snapshot(
                documentID: documentID,
                environmentID: fixture.project.environmentID,
                path: source,
                dirtyState: .clean
            ),
            clientID: fixture.clientInstanceID
        )
        let documents = TabDocumentFactory(transport: transport)
        let files = TabFilePicker(values: [
            TabFileSelection(path: source, language: "swift"),
            TabFileSelection(path: source, language: "swift"),
            TabFileSelection(path: destination, language: "swift"),
        ])
        let controller = fixture.makeController(
            workspaceService: workspace,
            documentFactory: documents.make,
            filePicker: files.pick
        )
        let firstTabID = TabID()
        let closingTabID = TabID()
        _ = try await controller.createTab(
            for: .file,
            tabID: firstTabID,
            in: fixture.project
        )
        _ = try await controller.createTab(
            for: .file,
            tabID: closingTabID,
            in: fixture.conversation
        )
        let closingTab = try WorkspaceTab(record: TabRecord(
            validatingID: closingTabID,
            resource: .file(documentID),
            fileViewState: .initial()
        ))
        await workspace.pauseNextPerform()
        await workspace.setPerformHandler {
            try await transport.setPath(destination)
            return .relocated(from: source, to: destination)
        }

        let relocation = Task {
            try await controller.performRelocationWithDisposition(
                .rename(source: source, newName: "CloseRaceRenamed.swift"),
                workspaceContextID: fixture.project.contextID
            )
        }
        await workspace.waitUntilPerformPaused()
        let closing = Task {
            guard try await controller.prepareClose(
                closingTab,
                in: fixture.conversation
            ) else { throw CancellationError() }
            try await controller.finalizeClose(
                closingTab,
                in: fixture.conversation
            )
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            fixture.bridge.resolver.session(documentID: documentID)?.references.count,
            2
        )

        await workspace.resumePerform()
        let disposition = try await relocation.value
        XCTAssertEqual(disposition, .complete)
        if case .incomplete = disposition {
            if let token = controller.pendingRelocationTokens.first {
                _ = try await controller.abandonRelocation(token)
            }
            return
        }
        try await closing.value
        let session = try XCTUnwrap(
            fixture.bridge.resolver.session(documentID: documentID)
        )
        XCTAssertEqual(session.references.count, 1)
        XCTAssertTrue(session.references.contains {
            $0.workspaceContextID == fixture.project.contextID && $0.tabID == firstTabID
        })
        XCTAssertFalse(session.references.contains {
            $0.workspaceContextID == fixture.conversation.contextID
                && $0.tabID == closingTabID
        })

        let reopened = try await controller.createTab(
            for: .file,
            tabID: TabID(),
            in: fixture.conversation
        )
        XCTAssertEqual(reopened, .file(documentID))
    }

    func testPartialRelocationExposesRetryCompleteAndAbandonAllStale() async throws {
        let fixture = try TabCommandFixture()
        let workspace = TabWorkspaceService()
        let source = try RelativePath("dir")
        let destination = try RelativePath("renamed")
        let operation = FileOperation.rename(source: source, newName: "renamed")
        let first = try await fixture.attachDocument(path: "dir/one.txt")
        await first.transport.failNextSnapshots(1)
        await workspace.setPerformHandler {
            try await first.transport.setPath(RelativePath("renamed/one.txt"))
            return .relocated(from: source, to: destination)
        }
        let controller = fixture.makeController(workspaceService: workspace)

        let partial = try await controller.performRelocationWithDisposition(
            operation,
            workspaceContextID: fixture.project.contextID
        )
        guard case let .incomplete(ids) = partial else {
            return XCTFail("expected incomplete relocation")
        }
        XCTAssertEqual(ids, [first.documentID])
        let retryToken = try XCTUnwrap(controller.pendingRelocationTokens.first)
        let retried = try await controller.retryRelocation(retryToken)
        XCTAssertEqual(retried, .complete)
        XCTAssertEqual(controller.pendingRelocationTokens, [])

        let second = try await fixture.attachDocument(path: "dir/two.txt")
        await second.transport.failNextSnapshots(2)
        await workspace.setPerformHandler {
            try await second.transport.setPath(RelativePath("renamed/two.txt"))
            return .relocated(from: source, to: destination)
        }
        let secondPartial = try await controller.performRelocationWithDisposition(
            operation,
            workspaceContextID: fixture.project.contextID
        )
        guard case .incomplete = secondPartial else {
            return XCTFail("expected second incomplete relocation")
        }
        let abandonToken = try XCTUnwrap(controller.pendingRelocationTokens.first)
        let abandoned = try await controller.abandonRelocation(abandonToken)
        XCTAssertEqual(abandoned, .abandonedAllStale)
        XCTAssertEqual(controller.pendingRelocationTokens, [])
    }
}

private enum TabCommandTestError: Error, Equatable { case hostFailure }

@MainActor
private final class TabCommandFixture {
    let clientInstanceID = ClientInstanceID()
    let windowID = WindowID()
    let project: ActiveContext
    let conversation: ActiveContext
    let bridge: MonacoBridge

    init() throws {
        let projectID = ProjectID()
        let rootIdentity = "volume:fixture/file:shared"
        let environmentID = EnvironmentID()
        project = try ActiveContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: environmentID,
            workspaceRootIdentity: rootIdentity,
            generation: 1
        )
        let conversationID = ConversationID()
        conversation = try ActiveContext(
            validating: .conversation(conversationID),
            projectID: projectID,
            conversationID: conversationID,
            environmentID: environmentID,
            workspaceRootIdentity: rootIdentity,
            generation: 2
        )
        bridge = MonacoBridge(
            resolver: MonacoWindowSessionResolver(
                clientInstanceID: clientInstanceID,
                loadViewState: { _, _, _ in nil },
                storeViewState: { _, _, _, _ in }
            )
        )
    }

    func makeController(
        workspaceService: any WorkspaceServing = TabWorkspaceService(),
        terminal: TabTerminalRecorder = TabTerminalRecorder(),
        documentFactory: @escaping TabDocumentTransportFactory = { _ in
            throw TabCommandTestError.hostFailure
        },
        filePicker: @escaping TabFilePickerPort = { _ in nil },
        executablePicker: @escaping TabExecutablePickerPort = { _ in nil },
        detachedTerminalPicker: @escaping TabDetachedTerminalPickerPort = { _ in nil },
        closeDecision: @escaping TabDirtyFileCloseDecisionPort = { _ in .discard }
    ) -> TabCommandController {
        TabCommandController(
            workspaceService: workspaceService,
            bridge: bridge,
            clientInstanceID: clientInstanceID,
            windowID: windowID,
            activeContext: { [project, conversation] contextID in
                switch contextID {
                case project.contextID: return project
                case conversation.contextID: return conversation
                default: throw TabCommandTestError.hostFailure
                }
            },
            terminalCreate: terminal.create,
            terminalList: terminal.list,
            documentTransportFactory: documentFactory,
            filePicker: filePicker,
            executablePicker: executablePicker,
            detachedTerminalPicker: detachedTerminalPicker,
            dirtyFileCloseDecision: closeDecision
        )
    }

    func session(
        state: TerminalLifecycleState,
        kind: TerminalKind = .shell,
        exitStatus: Int32? = nil
    ) throws -> ClientTerminalSession {
        let executablePath: String
        switch kind {
        case .shell: executablePath = "/bin/zsh"
        case .agent: executablePath = "/usr/bin/true"
        }
        let launchSpec = try LaunchSpec(
            kind: kind,
            loginShellPath: "/bin/zsh",
            executablePath: executablePath,
            arguments: [],
            workspaceRoot: "/tmp",
            terminalSize: TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: [:]
        )
        return try ClientTerminalSession(validating: TerminalSessionRecord(
            validatingSessionID: TerminalSessionID(),
            contextID: project.contextID,
            environmentID: project.environmentID,
            protocolVersion: .current,
            launchSpecData: JSONEncoder().encode(launchSpec),
            lifecycleState: state,
            startNonce: Data(repeating: 7, count: 16),
            workerID: state == .preparing ? nil : WorkerInstanceID(),
            exitStatus: exitStatus
        ))
    }

    func snapshot(
        documentID: DocumentID,
        environmentID: EnvironmentID,
        path: RelativePath,
        dirtyState: DocumentDirtyState
    ) throws -> DocumentSnapshot {
        try DocumentSnapshot(
            validatingDocumentID: documentID,
            environmentID: environmentID,
            relativePath: path,
            text: "fixture\n",
            documentVersion: 0,
            persistedVersion: 0,
            lastAcceptedClientSequence: 0,
            dirtyState: dirtyState,
            observedDiskFingerprint: DiskFingerprint(
                deviceID: 1,
                inode: 2,
                byteCount: 8,
                modificationTimeSeconds: 3,
                modificationTimeNanoseconds: 4,
                contentSHA256: try SHA256Digest(validating: Data(repeating: 5, count: 32))
            ),
            currentLease: nil,
            maintenance: []
        )
    }

    func attachDocument(path: String) async throws -> TabAttachedDocument {
        let documentID = DocumentID()
        let transport = try TabDocumentTransport(
            snapshot: snapshot(
                documentID: documentID,
                environmentID: project.environmentID,
                path: RelativePath(path),
                dirtyState: .clean
            ),
            clientID: clientInstanceID
        )
        let controller = DocumentClientController(
            clientInstanceID: clientInstanceID,
            transport: transport
        )
        _ = try await controller.open(
            in: project.environmentID,
            at: RelativePath(path),
            requestWriteAccess: true
        )
        try await bridge.resolver.retain(
            contextID: project.contextID,
            tabID: TabID(),
            documentID: documentID,
            controller: controller,
            language: "plaintext"
        )
        return TabAttachedDocument(documentID: documentID, transport: transport)
    }
}

private struct TabAttachedDocument {
    let documentID: DocumentID
    let transport: TabDocumentTransport
}

@MainActor
private final class TabTerminalRecorder {
    struct CreateCall {
        let active: ActiveContext
        let request: TerminalCreateRequest
    }

    var createRequests: [CreateCall] = []
    var createResults: [Result<ClientTerminalSession, Error>] = []
    var createdSessions: [ClientTerminalSession] = []
    var listedSessions: [ClientTerminalSession] = []
    var listContexts: [ActiveContext] = []

    func create(
        _ active: ActiveContext,
        _ request: TerminalCreateRequest
    ) async throws -> ClientTerminalSession {
        createRequests.append(.init(active: active, request: request))
        let value: ClientTerminalSession
        if !createResults.isEmpty {
            value = try createResults.removeFirst().get()
        } else {
            let executablePath: String
            switch request.kind {
            case .shell: executablePath = "/bin/zsh"
            case .agent: executablePath = "/usr/bin/true"
            }
            let launchSpec = try LaunchSpec(
                kind: request.kind,
                loginShellPath: "/bin/zsh",
                executablePath: executablePath,
                arguments: [],
                workspaceRoot: "/tmp",
                terminalSize: request.terminalSize,
                environmentOverrides: [:]
            )
            value = try ClientTerminalSession(validating: TerminalSessionRecord(
                validatingSessionID: TerminalSessionID(),
                contextID: active.contextID,
                environmentID: active.environmentID,
                protocolVersion: .current,
                launchSpecData: JSONEncoder().encode(launchSpec),
                lifecycleState: .running,
                startNonce: Data(repeating: 9, count: 16)
            ))
        }
        createdSessions.append(value)
        return value
    }

    func list(_ active: ActiveContext) async throws -> [ClientTerminalSession] {
        listContexts.append(active)
        return listedSessions
    }
}

@MainActor
private final class TabDetachedTerminalPicker {
    var values: [ClientTerminalSession?]
    var candidates: [[ClientTerminalSession]] = []

    init(values: [ClientTerminalSession?]) { self.values = values }

    func pick(_ sessions: [ClientTerminalSession]) async throws -> ClientTerminalSession? {
        candidates.append(sessions)
        return values.removeFirst()
    }
}

@MainActor
private final class TabExecutablePicker {
    var values: [Data?]
    var profiles: [AgentProfileID] = []

    init(values: [Data?]) { self.values = values }

    func pick(_ profile: AgentProfileID) async throws -> Data? {
        profiles.append(profile)
        return values.removeFirst()
    }
}

@MainActor
private final class TabFilePicker {
    var values: [TabFileSelection?]
    init(values: [TabFileSelection?]) { self.values = values }
    func pick(_ active: ActiveContext) async throws -> TabFileSelection? {
        values.removeFirst()
    }
}

@MainActor
private final class TabDocumentFactory {
    let transport: TabDocumentTransport
    var calls: [ActiveContext] = []
    init(transport: TabDocumentTransport) { self.transport = transport }
    func make(_ active: ActiveContext) throws -> any DocumentDataTransport {
        calls.append(active)
        return transport
    }
}

@MainActor
private final class TabDocumentSequenceFactory {
    var values: [TabDocumentTransport]
    var calls: [ActiveContext] = []

    init(values: [TabDocumentTransport]) { self.values = values }

    func make(_ active: ActiveContext) throws -> any DocumentDataTransport {
        calls.append(active)
        return values.removeFirst()
    }
}

@MainActor
private final class TabCloseDecisionRecorder {
    var values: [TabDirtyFileCloseDecision]
    var snapshots: [DocumentSnapshot] = []
    private var pauseDecision = false
    private var decisionPaused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    init(values: [TabDirtyFileCloseDecision]) { self.values = values }

    func pauseNextDecision() { pauseDecision = true }

    func waitUntilDecisionPaused() async {
        if decisionPaused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resumeDecision() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    func decide(_ snapshot: DocumentSnapshot) async -> TabDirtyFileCloseDecision {
        snapshots.append(snapshot)
        if pauseDecision {
            pauseDecision = false
            decisionPaused = true
            pauseWaiter?.resume()
            pauseWaiter = nil
            await withCheckedContinuation { resumeWaiter = $0 }
            decisionPaused = false
        }
        return values.removeFirst()
    }
}

@MainActor
private final class TabRelocationRecoveryBarrier {
    private var pauseNext = true
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private(set) var observedRequestIDs: [RequestID] = []

    func observe(_ requestID: RequestID) async {
        observedRequestIDs.append(requestID)
        guard pauseNext else { return }
        pauseNext = false
        paused = true
        pauseWaiter?.resume()
        pauseWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
        paused = false
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private actor TabWorkspaceService: WorkspaceServing {
    struct PerformCall {
        let context: RequestContext
        let operation: FileOperation
    }

    private var result: Result<FileOperationResult, Error> = .failure(TabCommandTestError.hostFailure)
    private var handler: (@Sendable () async throws -> FileOperationResult)?
    private var calls: [PerformCall] = []
    private var pausePerform = false
    private var performPaused = false
    private var performPauseWaiter: CheckedContinuation<Void, Never>?
    private var performResumeWaiter: CheckedContinuation<Void, Never>?

    func setPerformResult(_ result: Result<FileOperationResult, Error>) {
        self.result = result
        handler = nil
    }

    func setPerformHandler(
        _ handler: @escaping @Sendable () async throws -> FileOperationResult
    ) {
        self.handler = handler
    }

    func performRequests() -> [PerformCall] { calls }

    func pauseNextPerform() { pausePerform = true }

    func waitUntilPerformPaused() async {
        if performPaused { return }
        await withCheckedContinuation { performPauseWaiter = $0 }
    }

    func resumePerform() {
        performResumeWaiter?.resume()
        performResumeWaiter = nil
    }

    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) async throws -> FileOperationResult {
        calls.append(.init(context: context, operation: operation))
        if pausePerform {
            pausePerform = false
            performPaused = true
            performPauseWaiter?.resume()
            performPauseWaiter = nil
            await withCheckedContinuation { performResumeWaiter = $0 }
            performPaused = false
        }
        if let handler { return try await handler() }
        return try result.get()
    }

    func addProject(bookmark: Data, displayName: String) async throws -> ProjectSnapshot {
        throw TabCommandTestError.hostFailure
    }
    func listWorkspace() async throws -> WorkspaceSnapshot { [] }
    func createDirectConversation(projectID: ProjectID) async throws -> Conversation {
        throw TabCommandTestError.hostFailure
    }
    func renameConversation(id: ConversationID, title: String) async throws {
        throw TabCommandTestError.hostFailure
    }
    func resolveContext(_ id: WorkspaceContextID) async throws -> ResolvedWorkspaceContext {
        throw TabCommandTestError.hostFailure
    }
}

private actor TabDocumentTransport: DocumentDataTransport {
    private var current: DocumentSnapshot
    private let lease: EditLease
    private var remainingSnapshotFailures = 0
    private var saves = 0
    private var discards = 0
    private var closes = 0
    private var retained: [DocumentID] = []
    private var released: [DocumentID] = []
    private var pauseOpen = false
    private var openPaused = false
    private var openPauseWaiter: CheckedContinuation<Void, Never>?
    private var openResumeWaiter: CheckedContinuation<Void, Never>?
    private var openedPaths: [(EnvironmentID, RelativePath)] = []
    private var snapshotIDs: [DocumentID] = []
    private var lifecycle: [String] = []

    init(snapshot: DocumentSnapshot, clientID: ClientInstanceID) throws {
        current = snapshot
        lease = try EditLease(
            validatingID: EditLeaseID(),
            documentID: snapshot.documentID,
            clientInstanceID: clientID
        )
    }

    func pauseNextOpen() { pauseOpen = true }

    func waitUntilOpenPaused() async {
        if openPaused { return }
        await withCheckedContinuation { openPauseWaiter = $0 }
    }

    func resumeOpen() {
        openResumeWaiter?.resume()
        openResumeWaiter = nil
    }

    func openDocument(
        in environmentID: EnvironmentID,
        at path: RelativePath
    ) async throws -> DocumentSnapshot {
        lifecycle.append("open")
        openedPaths.append((environmentID, path))
        if pauseOpen {
            pauseOpen = false
            openPaused = true
            openPauseWaiter?.resume()
            openPauseWaiter = nil
            await withCheckedContinuation { openResumeWaiter = $0 }
            openPaused = false
        }
        return current
    }

    func snapshot(documentID: DocumentID) throws -> DocumentSnapshot {
        lifecycle.append("snapshot")
        snapshotIDs.append(documentID)
        if remainingSnapshotFailures > 0 {
            remainingSnapshotFailures -= 1
            throw DocumentProtocolError.recoveryRequired
        }
        return current
    }

    func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) -> EditLease {
        lifecycle.append("acquire")
        return lease
    }
    func transferEditLease(
        documentID: DocumentID,
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) -> EditLease { lease }
    func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        try EditAcknowledgement(
            validatingDocumentID: transaction.documentID,
            clientSequence: transaction.clientSequence,
            documentVersion: max(transaction.clientSequence, transaction.baseVersion + 1)
        )
    }
    func flush(documentID: DocumentID, through clientSequence: UInt64) -> UInt64 {
        current.documentVersion
    }
    func save(
        documentID: DocumentID,
        expectedFingerprint: DiskFingerprint
    ) throws -> DocumentSnapshot {
        saves += 1
        return current
    }
    func discard(documentID: DocumentID) throws -> DocumentSnapshot {
        discards += 1
        return current
    }
    func retainViewer(documentID: DocumentID) {
        lifecycle.append("retain")
        retained.append(documentID)
    }
    func releaseViewer(documentID: DocumentID) { released.append(documentID) }
    func closeDocument(documentID: DocumentID) { closes += 1 }

    func setPath(_ path: RelativePath) throws {
        current = try DocumentSnapshot(
            validatingDocumentID: current.documentID,
            environmentID: current.environmentID,
            relativePath: path,
            text: current.text,
            documentVersion: current.documentVersion,
            persistedVersion: current.persistedVersion,
            lastAcceptedClientSequence: current.lastAcceptedClientSequence,
            dirtyState: current.dirtyState,
            observedDiskFingerprint: current.observedDiskFingerprint,
            currentLease: current.currentLease,
            maintenance: current.maintenance
        )
    }
    func failNextSnapshots(_ count: Int) { remainingSnapshotFailures = count }
    func saveCount() -> Int { saves }
    func discardCount() -> Int { discards }
    func closeCount() -> Int { closes }
    func retainedDocumentIDs() -> [DocumentID] { retained }
    func releasedDocumentIDs() -> [DocumentID] { released }
    func snapshotDocumentIDs() -> [DocumentID] { snapshotIDs }
    func openRequests() -> [(EnvironmentID, RelativePath)] { openedPaths }
    func lifecycleEvents() -> [String] { lifecycle }
}

@MainActor
private func XCTAssertThrowsTabError<E: Error & Equatable>(
    _ expected: E,
    operation: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}
