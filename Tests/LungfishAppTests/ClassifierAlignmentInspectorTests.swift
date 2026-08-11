// ClassifierAlignmentInspectorTests.swift - Detached classifier evidence inspector tests

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

@MainActor
final class ClassifierAlignmentInspectorTests: XCTestCase {
    func testViewportBindingPublishesCapabilitiesIntoInspectorWithoutDirectInspectorUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("final.bam")
        let index = directory.appendingPathComponent("final.bam.bai")
        try Data([1]).write(to: bam); try Data([2]).write(to: index)
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .taxTriage,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: bam, index: .init(url: index, kind: .bai), sample: .init(canonicalID: "S1"),
            contig: .init(name: "virus", expectedLength: 4), referenceCandidate: nil,
            presentation: .init(workflowLabel: "TaxTriage", resultLabel: "result", sampleLabel: "S1", contigLabel: "virus")
        )
        let controller = ClassifierAlignmentEvidenceViewportController(
            validator: .init(headerReader: { _ in "@SQ\tSN:virus\tLN:4\n" }, indexQuery: { _, _, _ in })
        )
        let inspector = InspectorViewController()
        _ = inspector.view
        controller.bindInspector(inspector)

        controller.display(request)
        for _ in 0..<100 where inspector.readStyleSectionViewModel.classifierEvidenceCapabilities == nil { await Task.yield() }

        XCTAssertEqual(inspector.readStyleSectionViewModel.trackNames, ["S1"])
        XCTAssertEqual(inspector.viewModel.contentMode, .metagenomics)
        XCTAssertTrue(inspector.viewModel.availableTabs.contains(.view))
        XCTAssertTrue(inspector.viewModel.availableTabs.contains(.analysis))
        controller.clear()
        XCTAssertNil(inspector.readStyleSectionViewModel.classifierEvidenceCapabilities)
    }
    func testReferenceFreeCapabilityMatrixDisablesReferenceAndOutputOperations() {
        let capabilities = ClassifierAlignmentInspectorCapabilities.detachedEvidence(
            workflow: "EsViritu",
            result: "result",
            sample: "S1",
            contig: "virus",
            bamPath: "/results/final.bam",
            indexPath: "/results/final.bam.bai",
            referenceValidation: .absent,
            readGroups: []
        )

        XCTAssertEqual(capabilities.defaultExcludeFlags, 0xD04)
        XCTAssertEqual(capabilities.availability(of: .referenceMismatch), .disabled("A validated reference sequence is required."))
        XCTAssertEqual(capabilities.availability(of: .consensus), .disabled("A validated reference sequence is required."))
        XCTAssertEqual(capabilities.availability(of: .createFilteredAlignment), .disabled("Classifier evidence is read-only; creating derived alignment outputs is unavailable."))
        XCTAssertEqual(capabilities.availability(of: .markDuplicates), .disabled("Classifier evidence is read-only; duplicate workflows are unavailable."))
        XCTAssertEqual(capabilities.availability(of: .annotationAppearance), .hidden("Classifier evidence has no annotation track."))
        XCTAssertFalse(capabilities.showsReadGroupControls)
        XCTAssertEqual(capabilities.selectedTrack.name, "S1")
        XCTAssertEqual(capabilities.status, .idle)
        XCTAssertEqual(capabilities.referenceMismatchExplanation, "A validated reference sequence is required.")
        XCTAssertTrue(capabilities.inventoryRows.contains("Workflow: EsViritu"))
        XCTAssertTrue(capabilities.unavailableReasons.contains("Classifier evidence has no annotation track."))
    }

    func testValidatedReferenceCapabilityMatrixEnablesReferenceRenderingButNotOutputs() {
        let capabilities = ClassifierAlignmentInspectorCapabilities.detachedEvidence(
            workflow: "TaxTriage",
            result: "result",
            sample: "S1",
            contig: "virus",
            bamPath: "/results/final.bam",
            indexPath: "/results/final.bam.bai",
            referenceValidation: .structural,
            readGroups: [.init(id: "rg1", sample: "S1"), .init(id: "rg2", sample: "S1")]
        )

        XCTAssertEqual(capabilities.availability(of: .referenceMismatch), .available)
        XCTAssertEqual(capabilities.availability(of: .consensus), .available)
        XCTAssertEqual(capabilities.availability(of: .variantCalling), .disabled("Classifier evidence has no variant or cohort output target."))
        XCTAssertTrue(capabilities.showsReadGroupControls)
        XCTAssertEqual(capabilities.coveragePolicy, "Coverage uses MAPQ and read-inclusion filters; it is unavailable while read-group filtering is active.")
        XCTAssertNil(capabilities.referenceMismatchExplanation)
    }

    func testApplyingSettingsKeepsDetachedViewerLocusAndSelectionAndDoesNotInstallWorkflowTargets() {
        let inspector = InspectorViewController()
        let viewer = ViewerViewController()
        _ = inspector.view
        _ = viewer.view
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: URL(fileURLWithPath: "/tmp/evidence.bam"),
            contig: .init(name: "virus", length: 100),
            provider: .init(alignmentPath: "/tmp/evidence.bam", indexPath: "/tmp/evidence.bam.bai"),
            referenceSequence: nil
        )
        viewer.displayDetachedAlignment(source)
        viewer.referenceFrame?.start = 12
        viewer.referenceFrame?.end = 34
        let selected = AlignedRead(name: "read", flag: 0, chromosome: "virus", position: 15, mapq: 60, cigar: [.init(op: .match, length: 4)], sequence: "ACTG", qualities: [30, 30, 30, 30])
        viewer.viewerView.testSetCachedPackedReads([(0, selected)])
        viewer.viewerView.testSetSelectedReadIDs([selected.id])

        inspector.updateClassifierAlignmentInspector(
            capabilities: .detachedEvidence(
                workflow: "EsViritu", result: "result", sample: "S1", contig: "virus",
                bamPath: "/tmp/evidence.bam", indexPath: "/tmp/evidence.bam.bai",
                referenceValidation: .absent,
                readGroups: [.init(id: "rg1", sample: "S1"), .init(id: "rg2", sample: "S1")]
            ),
            applySettings: viewer.applyReadDisplaySettings
        )
        let state = inspector.readStyleSectionViewModel
        state.minMapQ = 31
        state.showDuplicates = true
        state.showSecondary = true
        state.showSupplementary = true
        state.selectedReadGroups = ["rg1"]
        state.onSettingsChanged?()

        XCTAssertEqual(viewer.viewerView.minMapQSetting, 31)
        XCTAssertEqual(viewer.viewerView.excludeFlagsSetting, 0x004)
        XCTAssertEqual(viewer.viewerView.selectedReadGroupsSetting, ["rg1"])
        XCTAssertEqual(viewer.referenceFrame?.start, 12)
        XCTAssertEqual(viewer.referenceFrame?.end, 34)
        XCTAssertEqual(viewer.viewerView.testSelectedReadIDs, [selected.id])
        XCTAssertNil(state.onMarkDuplicatesRequested)
        XCTAssertNil(state.onCreateDeduplicatedBundleRequested)
        XCTAssertNil(state.onCreateFilteredAlignmentRequested)
        XCTAssertNil(state.onConvertMappedReadsToAnnotationsRequested)
        XCTAssertNil(state.onPrimerTrimRequested)
        XCTAssertNil(state.onCallVariantsRequested)
    }

    func testProviderPublishesValidatedStatusAndActualReadGroupsThenClearsInventory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("final.bam")
        let index = directory.appendingPathComponent("final.bam.bai")
        try Data([1]).write(to: bam)
        try Data([2]).write(to: index)
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .taxTriage,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: bam,
            index: .init(url: index, kind: .bai),
            sample: .init(canonicalID: "S1"),
            contig: .init(name: "virus", expectedLength: 4),
            referenceCandidate: nil,
            presentation: .init(workflowLabel: "TaxTriage", resultLabel: "result", sampleLabel: "S1", contigLabel: "virus")
        )
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:virus\tLN:4\n@RG\tID:rg1\tSM:S1\n@RG\tID:rg2\tSM:S1\n" },
            indexQuery: { _, _, _ in }
        )
        let controller = ClassifierAlignmentEvidenceViewportController(validator: validator)

        controller.display(request)
        for _ in 0..<100 where controller.inspectorCapabilities?.status != .available(referenceStrength: "not provided", reason: nil) { await Task.yield() }

        let inventory = try XCTUnwrap(controller.inspectorCapabilities)
        XCTAssertEqual(inventory.status, .available(referenceStrength: "not provided", reason: nil))
        XCTAssertEqual(inventory.readGroups.map(\.id), ["rg1", "rg2"])
        XCTAssertTrue(inventory.showsReadGroupControls)

        controller.clear()
        XCTAssertNil(controller.inspectorCapabilities)
    }

    func testDetachedRefetchRemapsSelectedReadByStableAlignmentKeyAndClearsWhenAbsent() {
        let view = SequenceViewerView(frame: .zero)
        let old = AlignedRead(name: "read", flag: 0, chromosome: "chr1", position: 10, mapq: 60, cigar: [.init(op: .match, length: 4)], sequence: "ACTG", qualities: [30, 30, 30, 30])
        let reparsed = AlignedRead(name: "read", flag: 0, chromosome: "chr1", position: 10, mapq: 60, cigar: [.init(op: .match, length: 4)], sequence: "ACTG", qualities: [30, 30, 30, 30])
        view.testSetCachedPackedReads([(0, old)])
        view.testSetSelectedReadIDs([old.id])
        view.invalidateDetachedAlignmentFiltersPreservingSelection()
        let token = view.testBeginReadFetch(bundleURL: URL(fileURLWithPath: "/tmp/a.bam"), trackID: "detached", region: .init(chromosome: "chr1", start: 0, end: 20))
        XCTAssertTrue(view.testCommitReadFetch(token, reads: [reparsed], region: .init(chromosome: "chr1", start: 0, end: 20)))
        view.testSetCachedPackedReads([(0, reparsed)])
        XCTAssertEqual(view.testSelectedReadIDs, [reparsed.id])
        view.invalidateDetachedAlignmentFiltersPreservingSelection()
        let emptyToken = view.testBeginReadFetch(bundleURL: URL(fileURLWithPath: "/tmp/a.bam"), trackID: "detached", region: .init(chromosome: "chr1", start: 0, end: 20))
        XCTAssertTrue(view.testCommitReadFetch(emptyToken, reads: [], region: .init(chromosome: "chr1", start: 0, end: 20)))
        view.testSetCachedPackedReads([])
        XCTAssertTrue(view.testSelectedReadIDs.isEmpty)
    }
}
