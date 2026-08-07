import Testing
import CockpitTypes
@testable import CockpitClientCore

@Test func activeContextGenerationRejectsEveryStaleResultKindAcrossRepeatedContextSelection() async throws {
    let controller = ActiveContextController()
    let projectID = ProjectID()
    let environmentID = EnvironmentID()
    let contextA = try ResolvedWorkspaceContext(
        validating: .project(projectID),
        projectID: projectID,
        conversationID: nil,
        environmentID: environmentID,
        workspaceRootIdentity: "root-a"
    )
    let conversationID = ConversationID()
    let contextB = try ResolvedWorkspaceContext(
        validating: .conversation(conversationID),
        projectID: projectID,
        conversationID: conversationID,
        environmentID: environmentID,
        workspaceRootIdentity: "root-a"
    )

    for _ in 1...16 {
        _ = await controller.select(contextA)
    }
    let a17 = await controller.select(contextA)
    let b18 = await controller.select(contextB)
    let a19 = await controller.select(contextA)

    #expect(a17.generation == 17)
    #expect(b18.generation == 18)
    #expect(a19.generation == 19)
    var appliedResultKinds: [String] = []
    for resultKind in ["file-tree", "document", "layout"] {
        if await controller.accepts(generation: a17.generation) {
            appliedResultKinds.append(resultKind)
        }
    }
    #expect(appliedResultKinds.isEmpty)
    #expect(await controller.accepts(generation: b18.generation) == false)
    #expect(await controller.accepts(generation: a19.generation))
    #expect(await controller.current() == a19)
}
