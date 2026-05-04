import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class MultipleSequenceAlignmentDocumentSectionTests: XCTestCase {
    func testSelectionViewModelStoresMSASelectionAndClearsAnnotationSelection() {
        let viewModel = SelectionSectionViewModel()
        let state = MultipleSequenceAlignmentSelectionState(
            title: "seq2",
            subtitle: "column 3 • residue C",
            detailRows: [
                ("Alignment Column", "3"),
                ("Residue", "C"),
                ("Consensus", "G"),
            ]
        )

        viewModel.select(multipleSequenceAlignmentSelection: state)

        XCTAssertEqual(viewModel.multipleSequenceAlignmentSelection, state)
        XCTAssertNil(viewModel.selectedAnnotation)
    }

    func testInspectorUpdateMSASelectionSwitchesToSelectedItemTab() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        let state = MultipleSequenceAlignmentSelectionState(
            title: "seq2",
            subtitle: "column 3 • residue C",
            detailRows: [("Alignment Column", "3")]
        )

        inspector.updateMultipleSequenceAlignmentSelection(state)

        XCTAssertEqual(inspector.viewModel.selectionSectionViewModel.multipleSequenceAlignmentSelection, state)
        XCTAssertEqual(inspector.viewModel.selectedTab, .selectedItem)
    }

    func testMSADocumentStateOrdersSummaryBeforeWarningsAndArtifacts() {
        let state = MultipleSequenceAlignmentDocumentState(
            title: "sars-cov-2-genomes",
            subtitle: "aligned-fasta • nucleotide",
            summary: "5 sequences • 29,834 aligned columns",
            contextRows: [("Sequences", "5")],
            warningRows: ["No warnings"],
            artifactRows: [
                MultipleSequenceAlignmentDocumentArtifactRow(
                    label: "Aligned FASTA",
                    fileURL: URL(fileURLWithPath: "/project/alignment/primary.aligned.fasta")
                )
            ],
            consensusPreview: "ACGT"
        )

        XCTAssertEqual(
            state.visibleSectionOrder,
            [.header, .alignmentSummary, .warnings, .sourceArtifacts]
        )
    }

    func testDocumentSectionViewModelUpdateMSADocumentStoresMSAContent() {
        let viewModel = DocumentSectionViewModel()
        let state = MultipleSequenceAlignmentDocumentState(
            title: "alignment",
            subtitle: "aligned-fasta • nucleotide",
            summary: "3 sequences • 6 aligned columns",
            contextRows: [("Variable Sites", "1")],
            warningRows: [],
            artifactRows: [],
            consensusPreview: "ACGTTA"
        )

        viewModel.updateMultipleSequenceAlignmentDocument(state)

        XCTAssertEqual(viewModel.multipleSequenceAlignmentDocument, state)
        XCTAssertNil(viewModel.mappingDocument)
        XCTAssertNil(viewModel.assemblyDocument)
        XCTAssertTrue(viewModel.hasAnyContent)
    }

    func testInspectorUpdateMSADocumentBuildsBundleStatistics() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("alignment.fasta")
        try """
        >seq1
        ACGT-A
        >seq2
        ACCTTA
        >seq3
        ACGTTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("alignment.lungfishmsa", isDirectory: true)
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL)

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updateMultipleSequenceAlignmentDocument(bundle)

        let state = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.multipleSequenceAlignmentDocument)
        XCTAssertEqual(state.title, bundle.manifest.name)
        XCTAssertEqual(state.subtitle, "aligned-fasta • dna")
        XCTAssertEqual(state.summary, "3 sequences • 6 aligned columns")
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Variable Sites" && $0.1 == "1" })
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Parsimony Informative" && $0.1 == "0" })
        XCTAssertEqual(state.consensusPreview, "ACGTTA")
        XCTAssertTrue(
            state.artifactRows.contains {
                $0.label == "Aligned FASTA" &&
                    $0.fileURL == bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
            }
        )
    }
}
