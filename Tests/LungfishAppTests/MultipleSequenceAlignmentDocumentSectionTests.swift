import XCTest
@testable import LungfishApp
@testable import LungfishCore
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

    func testDocumentSectionViewModelUpdateTreeDocumentStoresTreeContent() {
        let viewModel = DocumentSectionViewModel()
        let state = PhylogeneticTreeDocumentState(
            title: "sarcopterygian-tree",
            subtitle: "newick • rooted",
            summary: "5 tips • 4 internal nodes",
            contextRows: [
                ("Tips", "5"),
                ("Rooting", "Rooted"),
            ],
            warningRows: [],
            artifactRows: [
                PhylogeneticTreeDocumentArtifactRow(
                    label: "Primary Newick",
                    fileURL: URL(fileURLWithPath: "/project/tree/primary.nwk")
                )
            ]
        )

        viewModel.updatePhylogeneticTreeDocument(state)

        XCTAssertEqual(viewModel.phylogeneticTreeDocument, state)
        XCTAssertNil(viewModel.multipleSequenceAlignmentDocument)
        XCTAssertNil(viewModel.mappingDocument)
        XCTAssertNil(viewModel.assemblyDocument)
        XCTAssertTrue(viewModel.hasAnyContent)
    }

    func testInspectorUpdateTreeDocumentBuildsBundleStatistics() throws {
        let scratchRoot = repositoryRoot()
            .appendingPathComponent(".build/test-scratch/tree-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let sourceURL = scratchRoot.appendingPathComponent("tree.nwk")
        try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = scratchRoot.appendingPathComponent("tree.lungfishtree", isDirectory: true)
        let bundle = try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL)

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updatePhylogeneticTreeDocument(bundle)

        let state = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.phylogeneticTreeDocument)
        XCTAssertEqual(state.title, bundle.manifest.name)
        XCTAssertEqual(state.subtitle, "newick • rooted")
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Tips" && $0.1 == "3" })
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Internal Nodes" && $0.1 == "2" })
        XCTAssertTrue(
            state.artifactRows.contains {
                $0.label == "Primary Newick" &&
                    $0.fileURL == bundleURL.appendingPathComponent("tree/primary.nwk")
            }
        )
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

    func testInspectorMSADocumentEnablesNumberingControlsAndBroadcastsMode() throws {
        let scratchRoot = repositoryRoot()
            .appendingPathComponent(".build/test-scratch/msa-numbering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let sourceURL = scratchRoot.appendingPathComponent("alignment.fasta")
        try """
        >seq1
        ACGT-A
        >seq2
        ACCTTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = scratchRoot.appendingPathComponent("alignment.lungfishmsa", isDirectory: true)
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL)

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        var receivedMode: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .readDisplaySettingsChanged,
            object: inspector,
            queue: nil
        ) { notification in
            receivedMode = notification.userInfo?[NotificationUserInfoKey.msaNumberingMode] as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        inspector.updateMultipleSequenceAlignmentDocument(bundle)

        XCTAssertTrue(inspector.viewModel.readStyleSectionViewModel.hasMultipleSequenceAlignmentBundle)
        XCTAssertEqual(inspector.viewModel.readStyleSectionViewModel.msaNumberingMode, .both)

        inspector.viewModel.readStyleSectionViewModel.msaNumberingMode = .sourceCoordinates
        inspector.viewModel.readStyleSectionViewModel.onSettingsChanged?()

        XCTAssertEqual(receivedMode, MSAAlignmentNumberingMode.sourceCoordinates.rawValue)
    }

    func testInspectorMSADocumentBroadcastsConsensusAndReferenceDisplayControls() throws {
        let scratchRoot = repositoryRoot()
            .appendingPathComponent(".build/test-scratch/msa-reference-display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let sourceURL = scratchRoot.appendingPathComponent("alignment.fasta")
        try """
        >seq1
        ACGT-A
        >seq2
        ACCTTA
        >seq3
        ACGTTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = scratchRoot.appendingPathComponent("alignment.lungfishmsa", isDirectory: true)
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL)

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        var receivedUserInfo: [AnyHashable: Any] = [:]
        let observer = NotificationCenter.default.addObserver(
            forName: .readDisplaySettingsChanged,
            object: inspector,
            queue: nil
        ) { notification in
            receivedUserInfo = notification.userInfo ?? [:]
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        inspector.updateMultipleSequenceAlignmentDocument(bundle)

        let vm = inspector.viewModel.readStyleSectionViewModel
        XCTAssertEqual(vm.msaReferenceRowOptions.map(\.name), ["seq1", "seq2", "seq3"])
        XCTAssertEqual(vm.selectedMSAReferenceRowID, bundle.rows.first?.id)
        XCTAssertEqual(vm.msaResidueIdentityDisplayMode, .letters)
        XCTAssertEqual(vm.msaConsensusMaskSymbolMode, .automatic)

        vm.selectedMSAReferenceRowID = bundle.rows[1].id
        vm.msaResidueIdentityDisplayMode = .dotsToReference
        vm.msaConsensusLowSupportThresholdPercent = 80
        vm.msaConsensusHighGapThresholdPercent = 20
        vm.msaConsensusMaskSymbolMode = .x
        vm.onSettingsChanged?()

        XCTAssertEqual(receivedUserInfo[NotificationUserInfoKey.msaReferenceRowID] as? String, bundle.rows[1].id)
        XCTAssertEqual(receivedUserInfo[NotificationUserInfoKey.msaResidueIdentityDisplayMode] as? String, MSAResidueIdentityDisplayMode.dotsToReference.rawValue)
        XCTAssertEqual(receivedUserInfo[NotificationUserInfoKey.msaConsensusLowSupportThresholdPercent] as? Int, 80)
        XCTAssertEqual(receivedUserInfo[NotificationUserInfoKey.msaConsensusHighGapThresholdPercent] as? Int, 20)
        XCTAssertEqual(receivedUserInfo[NotificationUserInfoKey.msaConsensusMaskSymbolMode] as? String, MSAConsensusMaskSymbolMode.x.rawValue)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
