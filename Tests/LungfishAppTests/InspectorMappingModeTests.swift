import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO

@MainActor
final class InspectorMappingModeTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector_mapping_mode_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testMappingModeUsesBundleSelectedItemViewAnalysisAndProvenanceInspectorTabs() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping

        XCTAssertEqual(viewModel.availableTabs, [.bundle, .selectedItem, .view, .analysis, .provenance])
    }

    func testMappingModeExposesSeparateViewAndAnalysisTabs() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping

        XCTAssertEqual(
            viewModel.availableTabs.map(\.displayLabel),
            ["Bundle", "Selected Item", "View", "Analysis", "Provenance"]
        )
    }

    func testGenotypeModeExposesDedicatedAnnotationsInspectorTab() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .genotype

        XCTAssertEqual(
            viewModel.availableTabs,
            [.bundle, .selectedItem, .annotations, .view, .provenance]
        )
        XCTAssertEqual(
            viewModel.availableTabs.map(\.displayLabel),
            ["Bundle", "Selected Item", "Annotations", "View", "Provenance"]
        )
    }

    func testMappingAlignmentSectionBindsEmbeddedBundleForWorkflowState() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })

        XCTAssertEqual(vc.selectionSectionViewModel.referenceBundle?.url, bundle.url)
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.bundleURL, bundle.url)
        XCTAssertEqual(
            vc.viewModel.documentSectionViewModel.referenceTrackCapabilities,
            ReferenceBundleTrackCapabilities(bundle: bundle)
        )
    }

    func testMappingAlignmentSectionImmediatelyAppliesCurrentReadStylePayload() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.readStyleSectionViewModel.showReads = false
        vc.readStyleSectionViewModel.maxReadRows = 123
        vc.readStyleSectionViewModel.limitReadRows = true
        vc.readStyleSectionViewModel.verticallyCompressContig = false
        vc.readStyleSectionViewModel.consensusMinDepth = 21
        vc.readStyleSectionViewModel.consensusMaskingMinDepth = 13

        var deliveredPayload: [AnyHashable: Any]?
        vc.updateMappingAlignmentSection(from: bundle) { payload in
            deliveredPayload = payload
        }

        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.showReads] as? Bool, false)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.maxReadRows] as? Int, 123)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.limitReadRows] as? Bool, true)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.verticalCompressContig] as? Bool, false)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.consensusMinDepth] as? Int, 21)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.consensusMaskingMinDepth] as? Int, 13)
    }

    // The mapping viewport treats the visible-track key as a list predicate:
    // "" means "All Alignments" and rebuilds the contig list from scratch,
    // clearing the selected contig. Clicking a contig row focuses the viewer
    // on that row's track without the Inspector knowing, so a display-only
    // toggle (Hide high-gap sites) that re-sent the Inspector's stale "" blanked
    // the viewport and dropped the consensus evidence. Display toggles must
    // carry display settings only.
    func testMappingDisplayToggleDoesNotResendAlignmentIdentity() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        var payloads: [[AnyHashable: Any]] = []
        vc.updateMappingAlignmentSection(from: bundle) { payloads.append($0) }
        XCTAssertNotNil(payloads.last?[NotificationUserInfoKey.visibleAlignmentTrackID],
                        "the first payload establishes the Inspector's track choice")

        vc.readStyleSectionViewModel.consensusMaskingEnabled = true
        vc.readStyleSectionViewModel.onSettingsChanged?()

        let toggle = try XCTUnwrap(payloads.last)
        XCTAssertEqual(toggle[NotificationUserInfoKey.consensusMaskingEnabled] as? Bool, true)
        XCTAssertFalse(toggle.keys.contains(NotificationUserInfoKey.visibleAlignmentTrackID as AnyHashable),
                       "an unchanged track choice must not re-assert All Alignments")
        XCTAssertFalse(toggle.keys.contains(NotificationUserInfoKey.selectedReadGroups as AnyHashable),
                       "an unchanged read-group choice must not override the selected row's samples")

        vc.readStyleSectionViewModel.selectedVisibleAlignmentTrackID = "filtered-track"
        vc.readStyleSectionViewModel.onSettingsChanged?()
        XCTAssertEqual(payloads.last?[NotificationUserInfoKey.visibleAlignmentTrackID] as? String,
                       "filtered-track", "a real track change must still reach the viewport")
    }

    func testDirectReferenceDisplayToggleDoesNotResendAlignmentIdentity() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        var payloads: [[AnyHashable: Any]] = []
        vc.updateReferenceBundleTrackSections(from: bundle) { payloads.append($0) }

        vc.readStyleSectionViewModel.consensusMaskingEnabled = true
        vc.readStyleSectionViewModel.onSettingsChanged?()

        let toggle = try XCTUnwrap(payloads.last)
        XCTAssertEqual(toggle[NotificationUserInfoKey.consensusMaskingEnabled] as? Bool, true)
        XCTAssertFalse(toggle.keys.contains(NotificationUserInfoKey.visibleAlignmentTrackID as AnyHashable))
        XCTAssertFalse(toggle.keys.contains(NotificationUserInfoKey.selectedReadGroups as AnyHashable))
    }

    // A segmented Picker draws its label inline, to the left of the segments.
    // At the default Inspector width the segments take nearly all the room,
    // so the inline "Consensus scope" label was squeezed until AppKit
    // hyphenated it mid-word ("Consen-/sus/scope"). Every segmented picker in
    // the read-style Inspector must hide its inline label and show it as a
    // caption above the segments instead, the way "Coverage scale" does.
    func testSegmentedPickersShowTheirLabelAboveTheSegments() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift")
        let lines = try String(contentsOf: sourceURL, encoding: .utf8)
            .components(separatedBy: "\n")
        let segmentedLines = lines.indices.filter { lines[$0].contains(".pickerStyle(.segmented)") }
        XCTAssertFalse(segmentedLines.isEmpty)
        for index in segmentedLines {
            XCTAssertTrue(
                lines[index + 1].contains(".labelsHidden()"),
                "segmented picker at line \(index + 1) draws an inline label that wraps mid-word"
            )
        }
        for label in ["Consensus Mode", "Consensus scope"] {
            XCTAssertTrue(
                lines.contains { $0.trimmingCharacters(in: .whitespaces) == "Text(\"\(label)\")" },
                "\(label) needs a caption above its segments once the inline label is hidden"
            )
        }
    }

    func testMappingAlignmentSectionWiresFilteredAlignmentWorkflowLaunch() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })

        XCTAssertNotNil(
            vc.readStyleSectionViewModel.onCreateFilteredAlignmentRequested,
            "Mapping mode should wire BAM filtering launches through the Inspector workflow handler"
        )
        XCTAssertNotNil(
            vc.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested,
            "Mapping mode should wire mapped-read annotation conversion through the Inspector workflow handler"
        )
    }

    func testDirectReferenceBundleSectionPopulatesBundleStateAndAppliesReadSettings() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        var deliveredPayload: [AnyHashable: Any]?
        vc.updateReferenceBundleTrackSections(from: bundle) { payload in
            deliveredPayload = payload
        }

        XCTAssertEqual(vc.selectionSectionViewModel.referenceBundle?.url, bundle.url)
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.manifest?.name, bundle.manifest.name)
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.bundleURL, bundle.url)
        XCTAssertEqual(
            vc.viewModel.documentSectionViewModel.referenceTrackCapabilities,
            ReferenceBundleTrackCapabilities(bundle: bundle)
        )
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.selectedChromosome?.name, "chr1")
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.showReads] as? Bool, vc.readStyleSectionViewModel.showReads)
        XCTAssertTrue(vc.readStyleSectionViewModel.supportsConsensusExtraction)
        XCTAssertEqual(
            vc.readStyleSectionViewModel.consensusExtractionAvailabilityMessage,
            AlignmentScientificActionError.contextUnavailable.localizedDescription
        )
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.url, bundle.url)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .referenceBundle)
    }

    func testEmptySidebarDeselectionPreservesActiveBundleContextForInspectorActions() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: nil,
            userInfo: ["items": [SidebarItem]()]
        )

        XCTAssertEqual(vc.selectionSectionViewModel.referenceBundle?.url, bundle.url)
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.bundleURL, bundle.url)
    }

    func testClearSelectionClearsBundleContextAndAlignmentStats() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })
        vc.readStyleSectionViewModel.hasAlignmentTracks = true
        vc.readStyleSectionViewModel.totalMappedReads = 99
        vc.readStyleSectionViewModel.trackNames = ["reads"]

        vc.clearSelection()

        XCTAssertNil(vc.selectionSectionViewModel.referenceBundle)
        XCTAssertNil(vc.viewModel.documentSectionViewModel.bundleURL)
        XCTAssertFalse(vc.readStyleSectionViewModel.hasAlignmentTracks)
        XCTAssertEqual(vc.readStyleSectionViewModel.totalMappedReads, 0)
        XCTAssertEqual(vc.readStyleSectionViewModel.trackNames, [])
    }

    /// The mapping viewer's embedded bundle must offer the same View >
    /// Annotations variant-track toggles as the reference viewer, so an
    /// imported benchmark track can be hidden from the Variants table.
    func testMappingAlignmentSectionOffersEmbeddedVariantTrackToggles() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let base = try makeReferenceBundle()
        let tracks = [
            VariantTrackInfo(id: "vc-b", name: "HG002 bcftools", path: "variants/b.vcf.gz", indexPath: "variants/b.vcf.gz.tbi"),
            VariantTrackInfo(id: "bench", name: "HG002 benchmark", path: "variants/bench.db", indexPath: ""),
        ]
        let manifest = BundleManifest(
            name: base.manifest.name, identifier: base.manifest.identifier,
            source: base.manifest.source, genome: base.manifest.genome,
            variants: tracks, recordStore: nil)
        let bundle = ReferenceBundle(url: base.url, manifest: manifest)

        vc.updateMappingAlignmentSection(from: bundle, hiddenVariantTrackIDs: ["bench"], applySettings: { _ in })

        let model = vc.annotationSectionViewModel
        XCTAssertEqual(model.availableVariantTracks.map(\.id).sorted(), ["bench", "vc-b"])
        XCTAssertEqual(model.hiddenVariantTrackIDs, ["bench"])

        vc.updateReferenceBundleTrackSections(from: bundle) { _ in }
        XCTAssertEqual(model.availableVariantTracks.count, 2, "Reference viewport keeps parity")
        XCTAssertTrue(model.hiddenVariantTrackIDs.isEmpty)
    }

    private func makeReferenceBundle() throws -> ReferenceBundle {
        let bundleURL = tempDir.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "org.test.fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 100,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 100, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            annotations: []
        )
        try manifest.save(to: bundleURL)
        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }
}
