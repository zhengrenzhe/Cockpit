import Foundation
import Testing
@testable import CockpitTypes

private func documentUUID(_ suffix: Int) throws -> UUID {
    try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)))
}

@Test func textPositionsAreOneBasedAndRangesPreserveDirection() throws {
    #expect(throws: CockpitDomainValidationError.zeroTextPosition) {
        _ = try TextPosition(validatingLine: 0, column: 1)
    }
    #expect(throws: CockpitDomainValidationError.zeroTextPosition) {
        _ = try TextPosition(validatingLine: 1, column: 0)
    }
    let anchor = try TextPosition(validatingLine: 8, column: 4)
    let active = try TextPosition(validatingLine: 3, column: 2)
    let range = try TextRange(validatingAnchor: anchor, active: active)
    #expect(range.anchor == anchor)
    #expect(range.active == active)
}

@Test func documentViewStateRejectsInvalidScrollAndProvidesInitialState() throws {
    let cursor = try TextPosition(validatingLine: 1, column: 1)
    for offset in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
        #expect(throws: CockpitDomainValidationError.invalidHorizontalScrollOffset) {
            _ = try DocumentViewState(
                validatingCursor: cursor, selections: [], firstVisibleLine: 1,
                horizontalScrollOffset: offset
            )
        }
    }
    #expect(throws: CockpitDomainValidationError.zeroTextPosition) {
        _ = try DocumentViewState(
            validatingCursor: cursor, selections: [], firstVisibleLine: 0,
            horizontalScrollOffset: 0
        )
    }
    let initial = DocumentViewState.initial()
    #expect(initial.cursor == cursor)
    #expect(initial.selections.isEmpty)
    #expect(initial.firstVisibleLine == 1)
    #expect(initial.horizontalScrollOffset == 0)
}

@Test func tabRecordValidatesResourceAndViewStateCombinations() throws {
    let tabID = TabID(try documentUUID(1))
    let documentID = DocumentID(try documentUUID(2))
    let terminalID = TerminalSessionID(try documentUUID(3))
    let state = DocumentViewState.initial()
    #expect(try TabRecord(validatingID: tabID, resource: .file(documentID), fileViewState: state).fileViewState == state)
    #expect(try TabRecord(validatingID: tabID, resource: .terminal(terminalID), fileViewState: nil).fileViewState == nil)
    #expect(try TabRecord(validatingID: tabID, resource: .newTabPicker, fileViewState: nil).fileViewState == nil)
    #expect(throws: CockpitDomainValidationError.invalidTabViewState) {
        _ = try TabRecord(validatingID: tabID, resource: .file(documentID), fileViewState: nil)
    }
    #expect(throws: CockpitDomainValidationError.invalidTabViewState) {
        _ = try TabRecord(validatingID: tabID, resource: .terminal(terminalID), fileViewState: state)
    }
}

@Test func tabRecordUsesTheFrozenTaggedCodableRepresentation() throws {
    let tabID = TabID(try documentUUID(4))
    let documentID = DocumentID(try documentUUID(5))
    let original = try TabRecord(
        validatingID: tabID, resource: .file(documentID), fileViewState: .initial()
    )
    let data = try JSONEncoder().encode(original)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let resource = try #require(object["resource"] as? [String: Any])
    #expect(resource["kind"] as? String == "file")
    #expect(resource["documentID"] as? String == documentID.description)
    #expect(resource["terminalSessionID"] == nil)
    #expect(try JSONDecoder().decode(TabRecord.self, from: data) == original)

    let unknownKind = try #require("""
    {"id":"00000000-0000-0000-0000-000000000004",
     "resource":{"kind":"web"},"fileViewState":null}
    """.data(using: .utf8))
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(TabRecord.self, from: unknownKind)
    }
}

@Test func terminalTabKindRoundTripsAndLegacyRecordsDefaultOnlyToShell() throws {
    let tabID = TabID(try documentUUID(8))
    let terminalID = TerminalSessionID(try documentUUID(9))
    let codex = try TabRecord(
        validatingID: tabID,
        resource: .terminal(terminalID),
        terminalKind: .codex,
        fileViewState: nil
    )

    let encoded = try JSONEncoder().encode(codex)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["terminalKind"] as? String == "codex")
    #expect(try JSONDecoder().decode(TabRecord.self, from: encoded) == codex)

    let legacy = try #require("""
    {"id":"00000000-0000-0000-0000-000000000008",
     "resource":{"kind":"terminal","terminalSessionID":"00000000-0000-0000-0000-000000000009"},
     "fileViewState":null}
    """.data(using: .utf8))
    let decodedLegacy = try JSONDecoder().decode(TabRecord.self, from: legacy)
    #expect(decodedLegacy.terminalKind == .shell)

    #expect(throws: CockpitDomainValidationError.invalidTabViewState) {
        _ = try TabRecord(
            validatingID: tabID,
            resource: .file(DocumentID()),
            terminalKind: .claude,
            fileViewState: .initial()
        )
    }
}

@Test func codableRevalidatesMutatedDocumentAndTabState() throws {
    var state = DocumentViewState.initial()
    state.horizontalScrollOffset = .nan
    #expect(throws: CockpitDomainValidationError.invalidHorizontalScrollOffset) {
        _ = try JSONEncoder().encode(state)
    }

    var tab = try TabRecord(
        validatingID: TabID(try documentUUID(6)),
        resource: .file(DocumentID(try documentUUID(7))), fileViewState: .initial()
    )
    tab.resource = .newTabPicker
    #expect(throws: CockpitDomainValidationError.invalidTabViewState) {
        _ = try JSONEncoder().encode(tab)
    }
}

@Test func textPositionCodableRejectsInvalidPersistedValuesWithDomainErrors() throws {
    let data = try #require(#"{"line":0,"column":1}"#.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.zeroTextPosition) {
        _ = try JSONDecoder().decode(TextPosition.self, from: data)
    }
}

@Test func documentViewStateCodableRejectsInvalidPersistedValuesWithDomainErrors() throws {
    let invalidScroll = try #require("""
    {"cursor":{"line":1,"column":1},"selections":[],
     "firstVisibleLine":1,"horizontalScrollOffset":-1}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.invalidHorizontalScrollOffset) {
        _ = try JSONDecoder().decode(DocumentViewState.self, from: invalidScroll)
    }

    let zeroFirstVisibleLine = try #require("""
    {"cursor":{"line":1,"column":1},"selections":[],
     "firstVisibleLine":0,"horizontalScrollOffset":0}
    """.data(using: .utf8))
    #expect(throws: CockpitDomainValidationError.zeroTextPosition) {
        _ = try JSONDecoder().decode(DocumentViewState.self, from: zeroFirstVisibleLine)
    }
}
