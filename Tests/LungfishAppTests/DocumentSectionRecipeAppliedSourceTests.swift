import XCTest
import LungfishTestSupport

final class DocumentSectionRecipeAppliedSourceTests: XCTestCase {
    func testRecipeAppliedSectionShowsExplicitReadDeltaSummaries() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift")
        let source = try readRepositorySource(sourceURL)

        XCTAssertTrue(source.contains(#"metadataRow(label: "Deduplication", value: deduplication.value)"#))
        XCTAssertTrue(source.contains(#"case standaloneReadDelta(String)"#))
        XCTAssertTrue(source.contains(#"metadataRow(label: "Human scrub", value: readDeltaDisplay("#))
    }
}
