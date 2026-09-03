import XCTest
import os
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

private final class MSAStringNotificationCapture: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: String?.none)

    func record(_ value: String?) {
        lock.withLock { $0 = value }
    }

    var value: String? {
        lock.withLock { $0 }
    }
}

private struct MSAReferenceDisplayNotification: Sendable {
    var referenceRowID: String?
    var residueIdentityDisplayMode: String?
    var lowSupportThresholdPercent: Int?
    var highGapThresholdPercent: Int?
    var maskSymbolMode: String?
}

private final class MSAReferenceDisplayNotificationCapture: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: MSAReferenceDisplayNotification())

    func record(_ userInfo: [AnyHashable: Any]?) {
        let referenceRowID = userInfo?[NotificationUserInfoKey.msaReferenceRowID] as? String
        let residueIdentityDisplayMode = userInfo?[NotificationUserInfoKey.msaResidueIdentityDisplayMode] as? String
        let lowSupportThresholdPercent = userInfo?[NotificationUserInfoKey.msaConsensusLowSupportThresholdPercent] as? Int
        let highGapThresholdPercent = userInfo?[NotificationUserInfoKey.msaConsensusHighGapThresholdPercent] as? Int
        let maskSymbolMode = userInfo?[NotificationUserInfoKey.msaConsensusMaskSymbolMode] as? String

        lock.withLock { snapshot in
            snapshot.referenceRowID = referenceRowID
            snapshot.residueIdentityDisplayMode = residueIdentityDisplayMode
            snapshot.lowSupportThresholdPercent = lowSupportThresholdPercent
            snapshot.highGapThresholdPercent = highGapThresholdPercent
            snapshot.maskSymbolMode = maskSymbolMode
        }
    }

    var snapshot: MSAReferenceDisplayNotification {
        lock.withLock { $0 }
    }
}

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
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.currentItem?.url, bundleURL)
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .phylogeneticTreeBundle)
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
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.currentItem?.url, bundleURL)
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .multipleSequenceAlignmentBundle)
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
        let receivedMode = MSAStringNotificationCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .readDisplaySettingsChanged,
            object: inspector,
            queue: nil
        ) { notification in
            receivedMode.record(notification.userInfo?[NotificationUserInfoKey.msaNumberingMode] as? String)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        inspector.updateMultipleSequenceAlignmentDocument(bundle)

        XCTAssertTrue(inspector.viewModel.readStyleSectionViewModel.hasMultipleSequenceAlignmentBundle)
        XCTAssertEqual(inspector.viewModel.readStyleSectionViewModel.msaNumberingMode, .both)

        inspector.viewModel.readStyleSectionViewModel.msaNumberingMode = .sourceCoordinates
        inspector.viewModel.readStyleSectionViewModel.onSettingsChanged?()

        XCTAssertEqual(receivedMode.value, MSAAlignmentNumberingMode.sourceCoordinates.rawValue)
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
        let receivedNotification = MSAReferenceDisplayNotificationCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .readDisplaySettingsChanged,
            object: inspector,
            queue: nil
        ) { notification in
            receivedNotification.record(notification.userInfo)
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

        let snapshot = receivedNotification.snapshot
        XCTAssertEqual(snapshot.referenceRowID, bundle.rows[1].id)
        XCTAssertEqual(snapshot.residueIdentityDisplayMode, MSAResidueIdentityDisplayMode.dotsToReference.rawValue)
        XCTAssertEqual(snapshot.lowSupportThresholdPercent, 80)
        XCTAssertEqual(snapshot.highGapThresholdPercent, 20)
        XCTAssertEqual(snapshot.maskSymbolMode, MSAConsensusMaskSymbolMode.x.rawValue)
    }

    // MARK: - Dead control removal (Task 13)

    /// Builds a minimal alignment document state with the real memberwise
    /// initialiser, which requires every stored property.
    private func makeAlignmentDocumentState() -> MultipleSequenceAlignmentDocumentState {
        MultipleSequenceAlignmentDocumentState(
            title: "alignment",
            subtitle: "aligned-fasta • dna",
            summary: "3 sequences • 6 aligned columns",
            contextRows: [("Sequences", "3")],
            warningRows: [],
            artifactRows: [],
            consensusPreview: "ACGTTA"
        )
    }

    func testAIAssistantTabIsHiddenUnlessTheSettingIsOn() {
        let model = InspectorViewModel()
        model.contentMode = .genomics

        let original = AppSettings.shared.aiSearchEnabled
        defer { AppSettings.shared.aiSearchEnabled = original }

        AppSettings.shared.aiSearchEnabled = false
        XCTAssertFalse(
            model.availableTabs.contains(.ai),
            "selecting the assistant with AI off raises a modal alert and leaves an empty pane"
        )

        AppSettings.shared.aiSearchEnabled = true
        XCTAssertTrue(model.availableTabs.contains(.ai))
    }

    func testAnalysisTabIsHiddenForAnAlignmentDocument() {
        let model = InspectorViewModel()
        model.contentMode = .genomics
        XCTAssertTrue(model.availableTabs.contains(.analysis))

        model.documentSectionViewModel.multipleSequenceAlignmentDocument = makeAlignmentDocumentState()
        XCTAssertFalse(
            model.availableTabs.contains(.analysis),
            "the Analysis tab asks the user to import a BAM, which an alignment bundle never has"
        )
    }

    func testSelectedTabFallsBackWhenTheActiveTabDisappears() {
        let model = InspectorViewModel()
        model.contentMode = .genomics
        let original = AppSettings.shared.aiSearchEnabled
        defer { AppSettings.shared.aiSearchEnabled = original }

        AppSettings.shared.aiSearchEnabled = true
        model.selectedTab = .ai
        AppSettings.shared.aiSearchEnabled = false
        model.reconcileSelectedTab()
        XCTAssertEqual(model.selectedTab, .bundle)
    }

    func testReconcileLeavesAStillListedTabAlone() {
        let model = InspectorViewModel()
        model.contentMode = .genomics
        model.selectedTab = .view

        model.reconcileSelectedTab()

        XCTAssertEqual(model.selectedTab, .view)
    }

    func testShowingAnAlignmentDocumentMovesTheSelectionOffTheAnalysisTab() {
        let model = InspectorViewModel()
        model.contentMode = .genomics
        model.selectedTab = .analysis

        model.documentSectionViewModel.multipleSequenceAlignmentDocument = makeAlignmentDocumentState()
        model.reconcileSelectedTab()

        XCTAssertFalse(model.availableTabs.contains(.analysis))
        XCTAssertTrue(
            model.availableTabs.contains(model.selectedTab),
            "the content switch must never render a tab the picker no longer lists"
        )
    }

    func testLegacyAnnotationLoadDisablesTheVariantsAndSamplesTabs() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        drawer.activeTab = .samples
        drawer.tabControl.selectedSegment = AnnotationTableDrawerView.DrawerTab.samples.rawValue

        drawer.setAnnotations([])

        XCTAssertFalse(
            drawer.tabControl.isEnabled(forSegment: AnnotationTableDrawerView.DrawerTab.variants.rawValue),
            "the legacy in-memory path has no variant table behind it"
        )
        XCTAssertFalse(
            drawer.tabControl.isEnabled(forSegment: AnnotationTableDrawerView.DrawerTab.samples.rawValue),
            "Samples otherwise offers Import Metadata and Sample Groups against nothing"
        )
        XCTAssertEqual(drawer.activeTab, .annotations)
        XCTAssertEqual(
            drawer.tabControl.selectedSegment,
            AnnotationTableDrawerView.DrawerTab.annotations.rawValue
        )
    }

    func testDrawerTabControlAccessibilityLabelNamesEverySegment() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        XCTAssertEqual(
            drawer.tabControl.accessibilityLabel(),
            "Switch between annotations, variants, and samples"
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
