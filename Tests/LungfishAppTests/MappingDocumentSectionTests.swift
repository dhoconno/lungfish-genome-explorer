import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class MappingDocumentSectionTests: XCTestCase {
    func testMappingSectionOrderPutsLayoutBeforeSourceAndArtifacts() {
        let state = MappingDocumentState(
            title: "minimap2-2026-04-21T09-20-22",
            subtitle: "minimap2 • Short-read",
            summary: "198 / 200 reads mapped",
            sourceData: [.missing(name: "reads.lungfishfastq", originalPath: "/tmp/reads.lungfishfastq")],
            contextRows: [("Mapper", "minimap2")],
            artifactRows: [MappingDocumentArtifactRow(label: "Sorted BAM", fileURL: URL(fileURLWithPath: "/tmp/test.sorted.bam"))]
        )

        XCTAssertEqual(
            state.visibleSectionOrder,
            [.header, .sourceData, .mappingContext, .sourceArtifacts]
        )
    }

    func testDocumentSectionPrefersMappingViewWhenMappingStateExists() {
        let viewModel = DocumentSectionViewModel()
        viewModel.updateMappingDocument(
            MappingDocumentState(
                title: "mapping",
                subtitle: "minimap2 • Short-read",
                summary: nil,
                sourceData: [],
                contextRows: [],
                artifactRows: []
            )
        )

        let view = DocumentSection(viewModel: viewModel)
        XCTAssertTrue(String(describing: view.body).contains("MappingDocumentSection"))
    }

    func testMappingDocumentSourceUsesRunLabelsAndNoLayoutSection() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift")

        XCTAssertTrue(source.contains("DisclosureGroup(\"Run Inputs\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Run Settings\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Output Files\""))
        XCTAssertFalse(source.contains("Text(\"Panel Layout\")"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)

        return try readRepositorySource(sourceURL)
    }
}
