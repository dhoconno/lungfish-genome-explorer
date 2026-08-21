import XCTest

final class ProvenanceSectionSourceTests: XCTestCase {
    private var sectionSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift")
    }

    private var viewModelSourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift")
    }

    func testProvenanceSectionUsesHierarchicalDisclosureGroups() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // ProvenanceSection is a pure SwiftUI View; no ViewInspector/snapshot harness
        // exists in this repo to observe rendered structure/identifiers at runtime.
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("LungfishInspectorStyle.sectionTitleFont"))
        XCTAssertTrue(source.contains("ProvenanceExportMenuModel.items"))
        XCTAssertTrue(source.contains("viewModel.export(format:"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-export-menu\")"))
        XCTAssertFalse(source.contains("Color(red:"))
        XCTAssertFalse(source.contains("Color(hex"))
    }

    func testInspectorTabRendersProvenanceSection() throws {
        let source = combinedInspectorViewControllerSource()

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("ProvenanceSection(viewModel: viewModel.provenanceSectionViewModel)"))
        XCTAssertFalse(source.contains("provenanceContextRows"))
    }

    func testFileMetadataRowsDoNotRenderUnknownTextPairs() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)
        let viewModelSource = try String(contentsOf: viewModelSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertFalse(source.contains("Text(row.fileSizeLabel)"))
        XCTAssertFalse(source.contains("Unknown"))
        XCTAssertTrue(source.contains("fileMetadataSummary(for: row)"))
        XCTAssertTrue(viewModelSource.contains("Size not recorded"))
    }

    func testProvenanceSectionUsesSwiftUITextSelectionForSummaryRows() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains(".textSelection(.enabled)"))
        XCTAssertTrue(source.contains("SelectableWrappingText("))
        XCTAssertTrue(source.contains("accessibilityIdentifier: \"provenance-raw-json-text\""))
    }

    func testLineagePathRowsUseSummaryRowTypography() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("summaryRow(label, value: paths.joined(separator: \"\\n\")"))
        XCTAssertFalse(source.contains("font: .monospacedSystemFont(ofSize: 10, weight: .regular),\n                    maximumNumberOfLines: 2,\n                    accessibilityIdentifier: \"provenance-path-list-value\""))
    }

    /// F6 review round 1: `viewModel.isLoading` was write-only -- ProvenanceSection never
    /// rendered it, so a slow off-main sidecar walk silently kept showing the previous
    /// selection's provenance with no affordance. Asserts the section actually observes
    /// `isLoading` and renders a lightweight loading affordance from it, using the same
    /// ProgressView idiom as the surrounding Inspector (ReadStyleSection.swift /
    /// InspectorView.swift's `isDuplicateWorkflowRunning`/`isAlignmentFilterWorkflowRunning`
    /// rows: `ProgressView().scaleEffect(0.7)` + secondary-styled caption `Text`).
    func testProvenanceSectionRendersLoadingIndicatorFromViewModel() throws {
        let source = try String(contentsOf: sectionSourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        XCTAssertTrue(source.contains("if viewModel.isLoading {"))
        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(source.contains(".scaleEffect(0.7)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"provenance-loading-indicator\")"))
    }
}
