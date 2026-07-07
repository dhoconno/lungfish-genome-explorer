import XCTest

final class DocumentSectionRecipeAppliedSourceTests: XCTestCase {
    func testRecipeAppliedSectionShowsExplicitReadDeltaSummaries() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#"metadataRow(label: "Deduplication", value: readDeltaDisplay("#))
        XCTAssertTrue(source.contains(#"metadataRow(label: "Human scrub", value: readDeltaDisplay("#))
    }
}
