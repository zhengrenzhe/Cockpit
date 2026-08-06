import Foundation
import Testing
@testable import CockpitTypes

@Test func stableIdentifierRoundTripsThroughCodable() throws {
    let uuid = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    let original = ProjectID(uuid)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ProjectID.self, from: data)
    #expect(decoded == original)
    #expect(decoded.description == "00000000-0000-0000-0000-000000000001")
}

@Test func identifierScopesRemainTypeSafe() throws {
    let raw = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let project = ProjectID(raw)
    let conversation = ConversationID(raw)
    #expect(project.rawValue == conversation.rawValue)
}
