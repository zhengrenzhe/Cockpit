import Foundation
import XCTest
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import Cockpit

@MainActor
final class ConversationDeletionControllerTests: XCTestCase {
    func testCancelOnDirtyDocumentCreatesNoDeletionOperation() async throws {
        let fixture = try ConversationDeletionAppFixture()
        let service = ConversationDeletionAppService(impact: fixture.impact)
        let recorder = ConversationDeletionAppRecorder()
        let controller = ConversationDeletionController(
            service: service,
            documentDecision: { _ in .cancel },
            saveDocument: { _ in XCTFail("cancel must not save") },
            discardDocument: { _ in XCTFail("cancel must not discard") },
            confirmTermination: { XCTFail("dirty cancel must stop before termination"); return false },
            confirmForce: { _ in XCTFail("dirty cancel must not ask for force"); return false },
            selectProjectContext: { _ in XCTFail("cancel must not change context") }
        )

        let result = try await controller.delete(conversationID: fixture.conversationID)

        XCTAssertEqual(result, .cancelled)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [.impact(fixture.conversationID)])
        XCTAssertEqual(recorder.events, [])
    }

    func testSaveDiscardThenNormalCompletionSelectsProjectContext() async throws {
        let fixture = try ConversationDeletionAppFixture(twoDirtyDocuments: true)
        let refreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000010"
        )!
        let refreshedImpact = fixture.impact(
            dirtyDocuments: [],
            preparationID: refreshedPreparationID
        )
        let service = ConversationDeletionAppService(
            impacts: [fixture.impact, refreshedImpact],
            progress: [.deleted(projectContextID: .project(fixture.projectID))]
        )
        let recorder = ConversationDeletionAppRecorder()
        var decisions: [ConversationDeletionDocumentDecision] = [.save, .discard]
        let controller = ConversationDeletionController(
            service: service,
            operationID: { fixture.operationID },
            documentDecision: { _ in decisions.removeFirst() },
            saveDocument: { recorder.events.append(.saved($0.documentID)) },
            discardDocument: { recorder.events.append(.discarded($0.documentID)) },
            confirmTermination: { true },
            confirmForce: { _ in XCTFail("normal completion must not force"); return false },
            selectProjectContext: { recorder.events.append(.selected($0)) }
        )

        let result = try await controller.delete(conversationID: fixture.conversationID)

        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(
            recorder.events,
            [
                .saved(fixture.impact.dirtyDocuments[0].documentID),
                .discarded(fixture.impact.dirtyDocuments[1].documentID),
                .selected(.project(fixture.projectID)),
            ]
        )
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [
            .impact(fixture.conversationID),
            .impact(fixture.conversationID),
            .begin(
                fixture.conversationID,
                fixture.operationID,
                refreshedPreparationID
            ),
        ])
    }

    func testSaveRefreshesImpactBeforeSingleTerminationConfirmation() async throws {
        let fixture = try ConversationDeletionAppFixture()
        let refreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000009"
        )!
        let refreshedImpact = ConversationDeletionImpact(
            conversationID: fixture.conversationID,
            projectID: fixture.projectID,
            environmentID: fixture.environmentID,
            dirtyDocuments: [],
            preparationID: refreshedPreparationID
        )
        let service = ConversationDeletionAppService(
            impacts: [fixture.impact, refreshedImpact],
            progress: [.deleted(projectContextID: .project(fixture.projectID))]
        )
        var confirmationCount = 0
        let controller = ConversationDeletionController(
            service: service,
            operationID: { fixture.operationID },
            documentDecision: { _ in .save },
            saveDocument: { _ in },
            discardDocument: { _ in XCTFail("save flow must not discard") },
            confirmTermination: {
                confirmationCount += 1
                return true
            },
            confirmForce: { _ in XCTFail("normal completion must not force"); return false },
            selectProjectContext: { XCTAssertEqual($0, .project(fixture.projectID)) }
        )

        let result = try await controller.delete(conversationID: fixture.conversationID)

        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(confirmationCount, 1)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [
            .impact(fixture.conversationID),
            .impact(fixture.conversationID),
            .begin(fixture.conversationID, fixture.operationID, refreshedPreparationID),
        ])
    }

    func testStalePreparationRepeatsDocumentDecisionAgainstFreshImpact() async throws {
        let fixture = try ConversationDeletionAppFixture()
        let original = try XCTUnwrap(fixture.impact.dirtyDocuments.first)
        let freshPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000006"
        )!
        let freshDocument = try DocumentSnapshot(
            validatingDocumentID: original.documentID,
            environmentID: original.environmentID,
            relativePath: original.relativePath,
            text: original.text + " changed",
            documentVersion: original.documentVersion + 1,
            persistedVersion: original.persistedVersion,
            lastAcceptedClientSequence: original.lastAcceptedClientSequence + 1,
            dirtyState: .dirty,
            observedDiskFingerprint: original.observedDiskFingerprint,
            currentLease: original.currentLease,
            maintenance: original.maintenance
        )
        let freshImpact = ConversationDeletionImpact(
            conversationID: fixture.conversationID,
            projectID: fixture.projectID,
            environmentID: fixture.environmentID,
            dirtyDocuments: [freshDocument],
            preparationID: freshPreparationID
        )
        let firstRefreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000020"
        )!
        let secondRefreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000021"
        )!
        let secondOperationID = DeletionOperationID(
            UUID(uuidString: "75000000-0000-4000-8000-000000000007")!
        )
        let service = ConversationDeletionAppService(
            impacts: [
                fixture.impact,
                fixture.impact(
                    dirtyDocuments: [],
                    preparationID: firstRefreshedPreparationID
                ),
                fixture.impact(
                    dirtyDocuments: [],
                    preparationID: secondRefreshedPreparationID
                ),
            ],
            progress: [
                .preparationStale(freshImpact),
                .deleted(projectContextID: .project(fixture.projectID)),
            ]
        )
        var operationIDs = [fixture.operationID, secondOperationID]
        var decidedVersions: [UInt64] = []
        var confirmationCount = 0
        let controller = ConversationDeletionController(
            service: service,
            operationID: { operationIDs.removeFirst() },
            documentDecision: {
                decidedVersions.append($0.documentVersion)
                return .discard
            },
            saveDocument: { _ in XCTFail("discard flow must not save") },
            discardDocument: { _ in },
            confirmTermination: {
                confirmationCount += 1
                return true
            },
            confirmForce: { _ in XCTFail("stale preparation is pre-begin"); return false },
            selectProjectContext: { XCTAssertEqual($0, .project(fixture.projectID)) }
        )

        let result = try await controller.delete(conversationID: fixture.conversationID)

        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(decidedVersions, [2, 3])
        XCTAssertEqual(confirmationCount, 2)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [
            .impact(fixture.conversationID),
            .impact(fixture.conversationID),
            .begin(
                fixture.conversationID,
                fixture.operationID,
                firstRefreshedPreparationID
            ),
            .impact(fixture.conversationID),
            .begin(
                fixture.conversationID,
                secondOperationID,
                secondRefreshedPreparationID
            ),
        ])
    }

    func testStalePreparationAdoptsConcurrentDeletionOperationWithoutReprompting() async throws {
        let fixture = try ConversationDeletionAppFixture()
        let concurrentOperationID = DeletionOperationID(
            UUID(uuidString: "75000000-0000-4000-8000-000000000008")!
        )
        let concurrentImpact = ConversationDeletionImpact(
            conversationID: fixture.conversationID,
            projectID: fixture.projectID,
            environmentID: fixture.environmentID,
            dirtyDocuments: [],
            deletionOperationID: concurrentOperationID
        )
        let refreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000022"
        )!
        let service = ConversationDeletionAppService(
            impacts: [
                fixture.impact,
                fixture.impact(
                    dirtyDocuments: [],
                    preparationID: refreshedPreparationID
                ),
            ],
            progress: [
                .preparationStale(concurrentImpact),
                .deleted(projectContextID: .project(fixture.projectID)),
            ]
        )
        var decisionCount = 0
        var confirmationCount = 0
        let controller = ConversationDeletionController(
            service: service,
            operationID: { fixture.operationID },
            documentDecision: { _ in
                decisionCount += 1
                return .discard
            },
            saveDocument: { _ in XCTFail("discard flow must not save") },
            discardDocument: { _ in },
            confirmTermination: {
                confirmationCount += 1
                return true
            },
            confirmForce: { _ in XCTFail("concurrent normal deletion must not force"); return false },
            selectProjectContext: { XCTAssertEqual($0, .project(fixture.projectID)) }
        )

        let result = try await controller.delete(conversationID: fixture.conversationID)

        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(decisionCount, 1)
        XCTAssertEqual(confirmationCount, 1)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [
            .impact(fixture.conversationID),
            .impact(fixture.conversationID),
            .begin(
                fixture.conversationID,
                fixture.operationID,
                refreshedPreparationID
            ),
            .resume(concurrentOperationID, false),
        ])
    }

    func testForceIsSentOnlyAfterSeparateExplicitConfirmation() async throws {
        let fixture = try ConversationDeletionAppFixture()
        let active = TerminalSessionID(
            UUID(uuidString: "75000000-0000-4000-8000-000000000041")!
        )
        let refreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000023"
        )!
        let service = ConversationDeletionAppService(
            impacts: [
                fixture.impact,
                fixture.impact(
                    dirtyDocuments: [],
                    preparationID: refreshedPreparationID
                ),
            ],
            progress: [
                .forceConfirmationRequired(
                    operationID: fixture.operationID,
                    activeSessionIDs: [active]
                ),
                .deleted(projectContextID: .project(fixture.projectID)),
            ]
        )
        let controller = ConversationDeletionController(
            service: service,
            operationID: { fixture.operationID },
            documentDecision: { _ in .discard },
            saveDocument: { _ in },
            discardDocument: { _ in },
            confirmTermination: { true },
            confirmForce: { sessionIDs in
                XCTAssertEqual(sessionIDs, [active])
                return true
            },
            selectProjectContext: { XCTAssertEqual($0, .project(fixture.projectID)) }
        )

        let result = try await controller.delete(conversationID: fixture.conversationID)

        XCTAssertEqual(result, .deleted)
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [
            .impact(fixture.conversationID),
            .impact(fixture.conversationID),
            .begin(
                fixture.conversationID,
                fixture.operationID,
                refreshedPreparationID
            ),
            .resume(fixture.operationID, true),
        ])
    }

    func testDeclinedForceOperationCanBeResumedAfterControllerRelaunch() async throws {
        let fixture = try ConversationDeletionAppFixture()
        let active = TerminalSessionID()
        let refreshedPreparationID = UUID(
            uuidString: "75000000-0000-4000-8000-000000000024"
        )!
        let firstService = ConversationDeletionAppService(
            impacts: [
                fixture.impact,
                fixture.impact(
                    dirtyDocuments: [],
                    preparationID: refreshedPreparationID
                ),
            ],
            progress: [.forceConfirmationRequired(
                operationID: fixture.operationID,
                activeSessionIDs: [active]
            )]
        )
        let first = ConversationDeletionController(
            service: firstService,
            operationID: { fixture.operationID },
            documentDecision: { _ in .discard },
            saveDocument: { _ in },
            discardDocument: { _ in },
            confirmTermination: { true },
            confirmForce: { _ in false },
            selectProjectContext: { _ in XCTFail("pending deletion must not select") }
        )
        let firstResult = try await first.delete(conversationID: fixture.conversationID)
        XCTAssertEqual(firstResult, .deletionPending(operationID: fixture.operationID))

        let resumedImpact = ConversationDeletionImpact(
            conversationID: fixture.conversationID,
            projectID: fixture.projectID,
            environmentID: fixture.environmentID,
            dirtyDocuments: [],
            deletionOperationID: fixture.operationID
        )
        let resumedService = ConversationDeletionAppService(
            impact: resumedImpact,
            progress: [
                .forceConfirmationRequired(
                    operationID: fixture.operationID,
                    activeSessionIDs: [active]
                ),
                .deleted(projectContextID: .project(fixture.projectID)),
            ]
        )
        let relaunched = ConversationDeletionController(
            service: resumedService,
            documentDecision: { _ in XCTFail("resumed deletion must not repeat dirty decisions"); return .cancel },
            saveDocument: { _ in XCTFail("resumed deletion must not save") },
            discardDocument: { _ in XCTFail("resumed deletion must not discard") },
            confirmTermination: { XCTFail("resumed deletion must not repeat normal confirmation"); return false },
            confirmForce: { sessionIDs in XCTAssertEqual(sessionIDs, [active]); return true },
            selectProjectContext: { XCTAssertEqual($0, .project(fixture.projectID)) }
        )

        let resumedResult = try await relaunched.delete(conversationID: fixture.conversationID)
        XCTAssertEqual(resumedResult, .deleted)
        let resumedCalls = await resumedService.recordedCalls()
        XCTAssertEqual(resumedCalls, [
            .impact(fixture.conversationID),
            .resume(fixture.operationID, false),
            .resume(fixture.operationID, true),
        ])
    }
}

private struct ConversationDeletionAppFixture {
    let projectID = ProjectID(UUID(uuidString: "75000000-0000-4000-8000-000000000001")!)
    let conversationID = ConversationID(UUID(uuidString: "75000000-0000-4000-8000-000000000002")!)
    let environmentID = EnvironmentID(UUID(uuidString: "75000000-0000-4000-8000-000000000003")!)
    let operationID = DeletionOperationID(UUID(uuidString: "75000000-0000-4000-8000-000000000004")!)
    let impact: ConversationDeletionImpact

    init(twoDirtyDocuments: Bool = false) throws {
        var documents = [try Self.snapshot(
            id: "75000000-0000-4000-8000-000000000011",
            environmentID: environmentID,
            path: "first.txt"
        )]
        if twoDirtyDocuments {
            documents.append(try Self.snapshot(
                id: "75000000-0000-4000-8000-000000000012",
                environmentID: environmentID,
                path: "second.txt"
            ))
        }
        impact = ConversationDeletionImpact(
            conversationID: conversationID,
            projectID: projectID,
            environmentID: environmentID,
            dirtyDocuments: documents,
            preparationID: UUID(uuidString: "75000000-0000-4000-8000-000000000005")!
        )
    }

    func impact(
        dirtyDocuments: [DocumentSnapshot],
        preparationID: UUID
    ) -> ConversationDeletionImpact {
        ConversationDeletionImpact(
            conversationID: conversationID,
            projectID: projectID,
            environmentID: environmentID,
            dirtyDocuments: dirtyDocuments,
            preparationID: preparationID
        )
    }

    private static func snapshot(
        id: String,
        environmentID: EnvironmentID,
        path: String
    ) throws -> DocumentSnapshot {
        try DocumentSnapshot(
            validatingDocumentID: DocumentID(UUID(uuidString: id)!),
            environmentID: environmentID,
            relativePath: RelativePath(path),
            text: "dirty",
            documentVersion: 2,
            persistedVersion: 1,
            lastAcceptedClientSequence: 1,
            dirtyState: .dirty,
            observedDiskFingerprint: nil,
            currentLease: nil,
            maintenance: []
        )
    }
}

private actor ConversationDeletionAppService: ConversationDeletionServing {
    enum Call: Equatable {
        case impact(ConversationID)
        case begin(ConversationID, DeletionOperationID, UUID)
        case resume(DeletionOperationID, Bool)
    }

    private var impacts: [ConversationDeletionImpact]
    var calls: [Call] = []
    private var progress: [ConversationDeletionProgress]

    init(
        impact: ConversationDeletionImpact,
        progress: [ConversationDeletionProgress] = []
    ) {
        impacts = [impact]
        self.progress = progress
    }

    init(
        impacts: [ConversationDeletionImpact],
        progress: [ConversationDeletionProgress] = []
    ) {
        precondition(!impacts.isEmpty)
        self.impacts = impacts
        self.progress = progress
    }

    func deletionImpact(conversationID: ConversationID) -> ConversationDeletionImpact {
        calls.append(.impact(conversationID))
        if impacts.count > 1 { return impacts.removeFirst() }
        return impacts[0]
    }

    func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        preparationID: UUID
    ) -> ConversationDeletionProgress {
        calls.append(.begin(conversationID, operationID, preparationID))
        return progress.removeFirst()
    }

    func resumeConversationDeletion(
        operationID: DeletionOperationID,
        force: Bool
    ) -> ConversationDeletionProgress {
        calls.append(.resume(operationID, force))
        return progress.removeFirst()
    }

    func recordedCalls() -> [Call] { calls }
}

@MainActor
private final class ConversationDeletionAppRecorder {
    enum Event: Equatable {
        case saved(DocumentID)
        case discarded(DocumentID)
        case selected(WorkspaceContextID)
    }
    var events: [Event] = []
}
