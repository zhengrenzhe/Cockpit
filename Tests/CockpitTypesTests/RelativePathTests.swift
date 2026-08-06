import Testing
@testable import CockpitTypes

@Test func relativePathNormalizesComponents() throws {
    let path = try RelativePath("Sources//CockpitTypes/./Identifiers.swift")
    #expect(path.string == "Sources/CockpitTypes/Identifiers.swift")
}

@Test(arguments: ["/tmp/file", "../secret", "Sources/../../secret", ""])
func relativePathRejectsEscapes(value: String) {
    #expect(throws: RelativePath.Error.self) {
        try RelativePath(value)
    }
}
