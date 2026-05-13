import XCTest

final class ProvenanceSectionSourceTests: XCTestCase {
    private var sectionSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift")
    }

    private var inspectorSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift")
    }

    private var viewModelSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift")
    }

    func testProvenanceSectionUsesHierarchicalDisclosureGroups() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("struct ProvenanceSection: View"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Run Summary\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Warnings\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Lineage\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Files & Outputs\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Invocation & Options\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Runtime\""))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Raw JSON\""))
        XCTAssertTrue(source.contains("ForEach(viewModel.lineageRuns)"))
        XCTAssertTrue(source.contains("ForEach(run.steps)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-root\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-step-list\")"))
    }

    func testProvenanceSectionUsesInspectorStylingAndExportMenu() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("LungfishInspectorStyle.sectionTitleFont"))
        XCTAssertTrue(source.contains("ProvenanceExportMenuModel.items"))
        XCTAssertTrue(source.contains("viewModel.export(format:"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-export-menu\")"))
        XCTAssertFalse(source.contains("Color(red:"))
        XCTAssertFalse(source.contains("Color(hex"))
    }

    func testInspectorTabRendersProvenanceSection() throws {
        let source = try String(contentsOf: inspectorSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ProvenanceSection(viewModel: viewModel.provenanceSectionViewModel)"))
        XCTAssertFalse(source.contains("provenanceContextRows"))
    }

    func testFileMetadataRowsDoNotRenderUnknownTextPairs() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)
        let viewModelSource = try String(contentsOf: viewModelSourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Text(row.fileSizeLabel)"))
        XCTAssertFalse(source.contains("Unknown"))
        XCTAssertTrue(source.contains("fileMetadataSummary(for: row)"))
        XCTAssertTrue(viewModelSource.contains("Size not recorded"))
    }
}
