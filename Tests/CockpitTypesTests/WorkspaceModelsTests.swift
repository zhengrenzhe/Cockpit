import Foundation
import Testing
@testable import CockpitTypes

private func workspaceID(_ suffix: Int) throws -> UUID {
    try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)))
}

@Test func workspaceContextTaggedCodablePreservesProjectAndConversation() throws {
    let project = ProjectID(try workspaceID(1))
    let conversation = ConversationID(try workspaceID(2))
    for context in [WorkspaceContextID.project(project), .conversation(conversation)] {
        let data = try JSONEncoder().encode(context)
        #expect(try JSONDecoder().decode(WorkspaceContextID.self, from: data) == context)
    }
}

@Test func resolvedWorkspaceContextEnforcesIdentityAndNonemptyRoot() throws {
    let project = ProjectID(try workspaceID(3))
    let otherProject = ProjectID(try workspaceID(4))
    let conversation = ConversationID(try workspaceID(5))
    let environment = EnvironmentID(try workspaceID(6))

    let projectValue = try ResolvedWorkspaceContext(
        validating: .project(project), projectID: project, conversationID: nil,
        environmentID: environment, workspaceRootIdentity: "workspace-root-1"
    )
    #expect(projectValue.conversationID == nil)
    let conversationValue = try ResolvedWorkspaceContext(
        validating: .conversation(conversation), projectID: project,
        conversationID: conversation, environmentID: environment,
        workspaceRootIdentity: "workspace-root-1"
    )
    #expect(conversationValue.conversationID == conversation)

    #expect(throws: CockpitDomainValidationError.inconsistentWorkspaceContext) {
        _ = try ResolvedWorkspaceContext(
            validating: .project(project), projectID: otherProject, conversationID: nil,
            environmentID: environment, workspaceRootIdentity: "workspace-root-1"
        )
    }
    #expect(throws: CockpitDomainValidationError.inconsistentWorkspaceContext) {
        _ = try ResolvedWorkspaceContext(
            validating: .conversation(conversation), projectID: project, conversationID: nil,
            environmentID: environment, workspaceRootIdentity: "workspace-root-1"
        )
    }
    #expect(throws: CockpitDomainValidationError.emptyWorkspaceRootIdentity) {
        _ = try ResolvedWorkspaceContext(
            validating: .project(project), projectID: project, conversationID: nil,
            environmentID: environment, workspaceRootIdentity: ""
        )
    }
}

@Test func activeContextAndRequestContextValidateGenerationAndProtocol() throws {
    let project = ProjectID(try workspaceID(7))
    let environment = EnvironmentID(try workspaceID(8))
    #expect(throws: CockpitDomainValidationError.zeroActiveContextGeneration) {
        _ = try ActiveContext(
            validating: .project(project), projectID: project, conversationID: nil,
            environmentID: environment, workspaceRootIdentity: "root", generation: 0
        )
    }

    let context = try RequestContext(
        validating: .init(major: 1, minor: 1),
        clientInstanceID: ClientInstanceID(try workspaceID(9)),
        windowID: WindowID(try workspaceID(10)), workspaceContextID: .project(project),
        environmentID: environment, activeContextGeneration: 17,
        requestID: RequestID(try workspaceID(11))
    )
    #expect(try context.validated(negotiatedVersion: .init(major: 1, minor: 1)) == context)
    #expect(throws: CockpitDomainValidationError.protocolVersionMismatch) {
        _ = try context.validated(negotiatedVersion: .init(major: 1, minor: 2))
    }
    #expect(throws: CockpitDomainValidationError.invalidProtocolVersion) {
        _ = try RequestContext(
            validating: .init(major: 0, minor: 1), clientInstanceID: context.clientInstanceID,
            windowID: context.windowID, workspaceContextID: context.workspaceContextID,
            environmentID: environment, activeContextGeneration: 17, requestID: context.requestID
        )
    }
}

@Test func workspaceCodableRejectsTheSameInvalidStateAsInitializers() throws {
    let data = try #require("""
    {"contextID":{"project":{"rawValue":"00000000-0000-0000-0000-000000000012"}},
     "projectID":{"rawValue":"00000000-0000-0000-0000-000000000013"},
     "environmentID":{"rawValue":"00000000-0000-0000-0000-000000000014"},
     "workspaceRootIdentity":"root"}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.inconsistentWorkspaceContext) {
        _ = try JSONDecoder().decode(ResolvedWorkspaceContext.self, from: data)
    }
}

@Test func activeContextCodableRejectsInvalidPersistedValuesWithDomainErrors() throws {
    let zeroGeneration = try #require("""
    {"contextID":{"project":{"rawValue":"00000000-0000-0000-0000-000000000020"}},
     "projectID":{"rawValue":"00000000-0000-0000-0000-000000000020"},
     "environmentID":{"rawValue":"00000000-0000-0000-0000-000000000021"},
     "workspaceRootIdentity":"root","generation":0}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.zeroActiveContextGeneration) {
        _ = try JSONDecoder().decode(ActiveContext.self, from: zeroGeneration)
    }

    let emptyRoot = try #require("""
    {"contextID":{"project":{"rawValue":"00000000-0000-0000-0000-000000000020"}},
     "projectID":{"rawValue":"00000000-0000-0000-0000-000000000020"},
     "environmentID":{"rawValue":"00000000-0000-0000-0000-000000000021"},
     "workspaceRootIdentity":"","generation":1}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.emptyWorkspaceRootIdentity) {
        _ = try JSONDecoder().decode(ActiveContext.self, from: emptyRoot)
    }
}

@Test func requestContextCodableRejectsInvalidPersistedValuesWithDomainErrors() throws {
    let invalidVersion = try #require("""
    {"protocolVersion":{"major":0,"minor":1},
     "clientInstanceID":{"rawValue":"00000000-0000-0000-0000-000000000022"},
     "windowID":{"rawValue":"00000000-0000-0000-0000-000000000023"},
     "workspaceContextID":{"project":{"rawValue":"00000000-0000-0000-0000-000000000024"}},
     "environmentID":{"rawValue":"00000000-0000-0000-0000-000000000025"},
     "activeContextGeneration":17,
     "requestID":{"rawValue":"00000000-0000-0000-0000-000000000026"}}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.invalidProtocolVersion) {
        _ = try JSONDecoder().decode(RequestContext.self, from: invalidVersion)
    }

    let zeroGeneration = try #require("""
    {"protocolVersion":{"major":1,"minor":1},
     "clientInstanceID":{"rawValue":"00000000-0000-0000-0000-000000000022"},
     "windowID":{"rawValue":"00000000-0000-0000-0000-000000000023"},
     "workspaceContextID":{"project":{"rawValue":"00000000-0000-0000-0000-000000000024"}},
     "environmentID":{"rawValue":"00000000-0000-0000-0000-000000000025"},
     "activeContextGeneration":0,
     "requestID":{"rawValue":"00000000-0000-0000-0000-000000000026"}}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.zeroActiveContextGeneration) {
        _ = try JSONDecoder().decode(RequestContext.self, from: zeroGeneration)
    }
}
