import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Lens switching and manual haplotype creator/band/tape
@MainActor
final class GenotypeResultViewportLensAndManualHaplotypeTests: GenotypeResultViewportTestCase {
    func testGenotypeOnlyResultUsesMatrixWithoutLensControl() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            summaryViewMode: .outline,
            layout: .listTrailing,
            showsAncillaryLoci: true
        ))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 0)
        let lensControl = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        XCTAssertEqual(lensControl.segmentCount, 2)
        XCTAssertEqual(
            (0..<lensControl.segmentCount).map {
                lensControl.label(forSegment: $0)
            },
            ["Summary", "Audit"]
        )
        XCTAssertEqual(lensControl.controlSize, .small)
    }


    func testFullSizeContentKeepsFullLengthCandidateSearchBelowSafeAreaTop() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_500, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentViewController = controller
        controller.configure(result: makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [
                makeCandidate(
                    id: "candidate",
                    name: "Candidate_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5),
            ]
        ))

        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let quickFilterBar = try XCTUnwrap(
            controller.view.firstDescendant(ofType: GenotypeQuickFilterBarView.self)
        )
        let searchField = try XCTUnwrap(quickFilterBar.firstDescendant(ofType: NSSearchField.self))
        let searchFrame = searchField.convert(searchField.bounds, to: controller.view)
        let safeAreaTop = controller.view.safeAreaLayoutGuide.frame.maxY

        XCTAssertGreaterThan(controller.view.safeAreaInsets.top, 0)
        XCTAssertLessThanOrEqual(searchFrame.maxY, safeAreaTop)
    }


    func testGenotypeOnlyResultKeepsMatrixWhenDefinitionsRequestWouldOpenAudit() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))
        controller.testingSetUnappliedDisplayState(GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing
        ))

        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)

        NotificationCenter.default.post(
            name: .genotypeResultOpenHaplotypeDefinitions,
            object: nil
        )
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)

        controller.testingSetUnappliedDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            summaryViewMode: .outline,
            layout: .listLeading
        ))
        controller.testingSelectLens(.review)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    }


    func testGenotypeOnlySummaryLeavesScrollableEmptySelectionDetailBlank() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertEqual(controller.testingDetailText, "")
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("below threshold"))
    }


    func testClearingGenotypeOnlyMatrixSelectionRestoresBlankDetail() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA")
        XCTAssertNotEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA", modifiers: .command)

        XCTAssertEqual(controller.testingDetailText, "")
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("below threshold"))
    }


    func testHaplotypedResultKeepsLensHeaderAndSideBySideLayout() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            layout: .listTrailing
        ))

        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertEqual(controller.testingPanelLayout, .listTrailing)
        XCTAssertTrue(controller.testingSplitIsVertical)
        XCTAssertFalse(controller.testingFirstPaneIsMatrix)
    }


    func testEmptyTypedGenotypeOnlyResultKeepsMatrixWithoutLensControl()
        throws
    {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertTrue(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 0)
        let lensControl = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        XCTAssertEqual(lensControl.segmentCount, 2)
        XCTAssertEqual(
            (0..<lensControl.segmentCount).map {
                lensControl.label(forSegment: $0)
            },
            ["Summary", "Audit"]
        )
    }


    func testReconfigureFromGenotypeOnlyToHaplotypedRestoresLensHeader() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
            ],
            kind: GenotypeResultWorkflowKind
                .fullLengthONTMHCGenotype.rawValue
        ))
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.review)

        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
    }


    func testViewportPublishesSharedGenotypeSelectionForInspector() {
        let controller = GenotypeResultViewController()
        _ = controller.view

        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02",
                passedAlignments: 42,
                passedUniqueReads: 39,
                sampleTotalReads: 100,
                sampleUniqueRetainedReads: 39,
                sampleUniqueRetainedPercent: 39,
                overallInputReads: 1000,
                overallUniqueRetainedReads: 60,
                overallUniqueRetainedPercent: 6
            )
        ]
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 42,
                    passedUniqueReads: 39,
                    sampleTotalReads: 100,
                    sampleUniqueRetainedPercent: 39,
                    calls: calls
                )
            ]
        )

        var selectedState: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { state in
            selectedState = state
        }

        controller.configure(result: result)
        controller.testingSelectFirstSharedCall()

        XCTAssertEqual(selectedState?.title, "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02")
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Locus" && $0.1 == "MHC-DQB1" }) ?? false)
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Allele" }) ?? false)
        XCTAssertFalse(selectedState?.subtitle?.localizedCaseInsensitiveContains("samples") ?? true)
        XCTAssertFalse(selectedState?.detailRows.contains(where: {
            ["Samples", "Unique Reads", "Alignments", "Support", "Support Metric", "Top Sample"].contains($0.0)
        }) ?? true)
    }


    func testViewportDoesNotGrowToFitLongGenotypeLabels() {
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 820, height: 640)

        let longGenotype = "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34"
        let calls = [
            ONTGenotypeCall(
                sample: "LF2874",
                genotype: longGenotype,
                passedAlignments: 2_945,
                passedUniqueReads: 2_945,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 19_769,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: 11_197_546,
                overallUniqueRetainedReads: 260_534,
                overallUniqueRetainedPercent: 2.326706
            )
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2874",
                passedAlignments: 19_852,
                passedUniqueReads: 19_769,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            layout: .listLeading
        ))

        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.width, 900)
        XCTAssertGreaterThanOrEqual(controller.testingSamplePaneWidth, 300)
        XCTAssertLessThanOrEqual(controller.testingDetailPaneWidth, 520)
    }


    func testLensSwitcherShowsConsumerAndArtifactsContent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.summary)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")

        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
    }


    func testManualHaplotypeCreatorRequiresSharedEligibilityAndShowsDisabledReason() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeEligibility-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let malformed = try JSONDecoder().decode(
            ONTGenotypeResultBundleManifest.self,
            from: Data(#"""
            {
              "schemaVersion": 1,
              "kind": "full-length-ont-mhc-genotype",
              "workflowKind": {"future": "mhc-workflow"},
              "workflowMode": "genotypeOnly",
              "outputName": "malformed",
              "analysisName": "Malformed",
              "primaryWorkbookPath": "malformed.xlsx",
              "longSummaryCSVPath": "calls.csv",
              "sampleSummaryCSVPath": "samples.csv",
              "statsJSONPath": "stats.json",
              "provenancePath": "provenance.json"
            }
            """#.utf8)
        )
        let partial = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: nil,
            outputName: "partial",
            analysisName: "Partial",
            primaryWorkbookPath: "partial.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let declaredHaplotyped = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .haplotyped,
            outputName: "haplotyped",
            analysisName: "Haplotyped",
            primaryWorkbookPath: "haplotyped.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let cases: [(manifest: ONTGenotypeResultBundleManifest, reason: String)] = [
            (
                malformed,
                "The workflow kind declaration must be a JSON string; found object."
            ),
            (
                partial,
                "The workflow declaration is incomplete or partially migrated."
            ),
            (
                declaredHaplotyped,
                "This result declares that haplotyping was performed."
            ),
        ]
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )

        for (index, testCase) in cases.enumerated() {
            let bundleURL = root.appendingPathComponent(
                "ineligible-\(index).lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: [call],
                manifest: testCase.manifest
            ))
            controller.testingSelectLens(.audit)

            let lensText = visibleText(in: controller.view)
            XCTAssertEqual(controller.manualHaplotypeDisabledReason, testCase.reason)
            XCTAssertFalse(controller.testingManualHaplotypingCreatorIsAvailable)
            XCTAssertTrue(lensText.contains("Manual Haplotyping"))
            XCTAssertTrue(lensText.contains(testCase.reason))
            XCTAssertFalse(lensText.contains("Create haplotype"))
            controller.testingAttemptManualHaplotypeCreation(
                selectedGenotypeIDs: ["MHC-A::01_Mafa_A1_001_01"],
                label: "Must Not Be Created"
            )
            XCTAssertTrue(controller.testingManualHaplotypeAssignments.isEmpty)
        }

        let eligibleBundleURL = root.appendingPathComponent(
            "eligible.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: eligibleBundleURL,
            withIntermediateDirectories: true
        )
        let eligibleController = GenotypeResultViewController()
        _ = eligibleController.view
        eligibleController.configure(result: makeResult(
            bundleURL: eligibleBundleURL,
            samples: [],
            calls: [call]
        ))
        XCTAssertTrue(eligibleController.testingManualHaplotypingCreatorIsAvailable)
        eligibleController.testingAttemptManualHaplotypeCreation(
            selectedGenotypeIDs: ["MHC-A::01_Mafa_A1_001_01"],
            label: "Eligible Manual Haplotype"
        )
        XCTAssertEqual(
            eligibleController.testingManualHaplotypeAssignments.map(\.label),
            ["Eligible Manual Haplotype"]
        )
    }


    func testTrulyHaplotypedResultKeepsManualHaplotypingDetailHidden() {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            )],
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectLens(.audit)

        XCTAssertFalse(visibleText(in: controller.view).contains("Manual Haplotyping"))
    }


    func testHaplotypedResultWithManualAssignmentsPreservesFullCreatorBehavior() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HaplotypedManualAssignments-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "LegacyAnimal",
                locus: "MHC-A",
                slot: .h1,
                label: "Existing Manual Haplotype",
                colorTokenIndex: 1,
                diagnosticAlleles: ["legacy-allele"],
                notes: "created before automated haplotyping"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            )],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertEqual(
            controller.testingManualHaplotypeAssignments.map(\.label),
            ["Existing Manual Haplotype"]
        )
        XCTAssertTrue(controller.testingManualHaplotypingCreatorIsAvailable)
        XCTAssertTrue(
            controller.testingUsesLegacyManualHaplotypingSection
        )
        XCTAssertTrue(lensText.contains("Manual Haplotyping"))
        controller.testingAttemptManualHaplotypeCreation(
            selectedGenotypeIDs: ["MHC-A::01_Mafa_A1_001_01"],
            label: "Grandfathered Manual Haplotype"
        )
        XCTAssertEqual(
            Set(controller.testingManualHaplotypeAssignments.map(\.label)),
            ["Existing Manual Haplotype", "Grandfathered Manual Haplotype"]
        )
    }


    func testGenotypeOnlySampleShowsOrphanLegacyAssignmentsReadOnly() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OrphanManualAssignments-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-OPAQUE",
                slot: .h2,
                label: "Legacy Opaque",
                colorTokenIndex: 8,
                diagnosticAlleles: ["opaque"],
                notes: "must survive recognized edits"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call]
        ))

        controller.testingShowMatrixTargetSelection([
            .column(sample: "AnimalA"),
        ])

        XCTAssertEqual(
            controller.testingManualHaplotypeEditorOrphanWarning,
            "1 legacy assignment uses an unrecognized locus. It is read-only and will be preserved when recognized assignments are saved."
        )
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorOrphans
                .map(\.locus),
            ["MHC-OPAQUE"]
        )
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorOrphans
                .map(\.label),
            ["Legacy Opaque"]
        )
        XCTAssertNil(
            controller.testingManualHaplotypeEditorEmptyStateMessage
        )
    }


    func testManualHaplotypeSampleRendererIsSharedByONTAndMiSeqAndKeepsRowsAndCellsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SharedManualHaplotypeRenderer-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let kinds: [GenotypeResultWorkflowKind] = [
            .fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ]

        for kind in kinds {
            let bundleURL = root.appendingPathComponent(
                "\(kind.rawValue).lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-28T00:00:00Z"
            )
            sidecar.manualHaplotypeAssignments = [
                ManualHaplotypeAssignment(
                    sample: "AnimalB",
                    locus: GenotypeManualHaplotypeLocus.a.workbookLabel,
                    slot: .h1,
                    label: "Shared-H1",
                    colorTokenIndex: 0,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ]
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                sidecar,
                forBundleAt: bundleURL
            )
            let manifest = ONTGenotypeResultBundleManifest(
                kind: kind.rawValue,
                workflowKind: kind,
                workflowMode: .genotypeOnly,
                outputName: kind.rawValue,
                analysisName: kind.rawValue,
                primaryWorkbookPath: "result.xlsx",
                longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            )
            try ONTGenotypeResultBundle.writeManifest(
                manifest,
                to: bundleURL
            )
            let calls = [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 21
                ),
            ]
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: calls,
                manifest: manifest
            ))
            var annotationSidecarChangedCount = 0
            var workbookActions:
                [GenotypeCurrentWorkbookUIRequest.Action] = []
            controller.onAnnotationSidecarChanged = { _ in
                annotationSidecarChangedCount += 1
            }
            controller.onCurrentWorkbookSyncRequested = {
                workbookActions.append($0.action)
            }

            controller.testingShowMatrixTargetSelection([
                .column(sample: "AnimalA"),
            ])
            XCTAssertNotNil(
                controller.testingSampleWorkbenchLayoutMode,
                kind.rawValue
            )
            XCTAssertEqual(
                controller.testingManualHaplotypeEditorSample,
                "AnimalA",
                kind.rawValue
            )
            XCTAssertEqual(
                controller.testingManualHaplotypeAutocompleteSuggestions(
                    matching: "Shared"
                ),
                ["Shared-H1"],
                kind.rawValue
            )
            controller.testingCopyManualHaplotypes(from: "AnimalB")
            XCTAssertTrue(
                controller.testingManualHaplotypeEditorIsDirty,
                kind.rawValue
            )
            controller.testingSaveManualHaplotypeDraft()
            XCTAssertFalse(
                controller.testingManualHaplotypeEditorIsDirty,
                kind.rawValue
            )
            XCTAssertEqual(
                controller.testingComparisonMatrix
                    .testingManualHaplotypeBandValues(
                        sample: "AnimalA"
                    ).first,
                "Shared-H1 · —",
                kind.rawValue
            )
            XCTAssertEqual(
                annotationSidecarChangedCount,
                1,
                kind.rawValue
            )
            XCTAssertEqual(
                workbookActions,
                [.markDirty],
                kind.rawValue
            )
            let persisted = try ONTGenotypeResultBundleData
                .loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
            XCTAssertEqual(
                persisted.manualHaplotypeAssignments
                    .filter { $0.sample == "AnimalA" }
                    .map(\.label),
                ["Shared-H1"],
                kind.rawValue
            )

            controller.testingShowMatrixTargetSelection([
                .column(sample: "AnimalA"),
                .column(sample: "AnimalB"),
            ])
            XCTAssertNil(
                controller.testingManualHaplotypeEditorSample,
                kind.rawValue
            )
            XCTAssertEqual(
                controller.testingCurrentSelectionMatrixTargets.count,
                2,
                kind.rawValue
            )

            controller.testingShowMatrixTargetSelection([
                .row(
                    locus: "MHC-A1",
                    genotype: "01_Mafa_A1_001_01"
                ),
            ])
            XCTAssertNil(
                controller.testingManualHaplotypeEditorSample,
                kind.rawValue
            )
            controller.testingShowMatrixTargetSelection([
                .cell(
                    locus: "MHC-A1",
                    genotype: "01_Mafa_A1_001_01",
                    sample: "AnimalA"
                ),
            ])
            XCTAssertNil(
                controller.testingManualHaplotypeEditorSample,
                kind.rawValue
            )
        }
    }


    func testManualHaplotypeSaveHeaderParityForExplicitONTAndMiSeqGenotypeOnlyResults()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeAssaySaveParity-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let kinds: [GenotypeResultWorkflowKind] = [
            .fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ]

        for kind in kinds {
            let bundleURL = root.appendingPathComponent(
                "\(kind.rawValue).lungfishgenotype",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                .empty(generatedAt: "2026-07-28T00:00:00Z"),
                forBundleAt: bundleURL
            )
            let manifest = ONTGenotypeResultBundleManifest(
                kind: kind.rawValue,
                workflowKind: kind,
                workflowMode: .genotypeOnly,
                outputName: kind.rawValue,
                analysisName: kind.rawValue,
                primaryWorkbookPath: "result.xlsx",
                longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            )
            try ONTGenotypeResultBundle.writeManifest(
                manifest,
                to: bundleURL
            )
            let result = makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ],
                manifest: manifest
            )
            XCTAssertEqual(
                GenotypeManualHaplotypeEligibility.evaluate(result),
                .eligible(resultKind: kind),
                kind.rawValue
            )
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: result)
            var annotationSidecarChangedCount = 0
            var workbookActions:
                [GenotypeCurrentWorkbookUIRequest.Action] = []
            controller.onAnnotationSidecarChanged = { _ in
                annotationSidecarChangedCount += 1
            }
            controller.onCurrentWorkbookSyncRequested = {
                workbookActions.append($0.action)
            }

            controller.testingShowMatrixTargetSelection([
                .column(sample: "AnimalA"),
            ])
            controller.testingUpdateManualHaplotypeLabel("Shared-H1")
            controller.testingSaveManualHaplotypeDraft()

            XCTAssertEqual(
                controller.testingComparisonMatrix
                    .testingManualHaplotypeBandValues(
                        sample: "AnimalA"
                    ).first,
                "Shared-H1 · —",
                kind.rawValue
            )
            XCTAssertEqual(
                annotationSidecarChangedCount,
                1,
                kind.rawValue
            )
            XCTAssertEqual(
                workbookActions,
                [.markDirty],
                kind.rawValue
            )
            let persisted = try ONTGenotypeResultBundleData
                .loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
            XCTAssertEqual(
                persisted.manualHaplotypeAssignments.map(\.label),
                ["Shared-H1"],
                kind.rawValue
            )
        }
    }


    func testManualHaplotypeEditorLoadsTrustedGenerationLinkedAnnotations()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LinkedManualHaplotypeEditor-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let annotationRoot = bundleURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("genotype-annotations", isDirectory: true)
        let generationID = "46fc3db4-ea08-483d-9f6c-f67f4e2d6caa"
        let generationURL = annotationRoot
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: generationURL,
            withIntermediateDirectories: true
        )
        let annotationFilename = GenotypeAnnotationSidecar.filename
        let provenanceFilename =
            "\(GenotypeAnnotationSidecar.filename).lungfish-provenance.json"
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-31T12:00:00Z"
        ).encoded().write(
            to: generationURL.appendingPathComponent(annotationFilename)
        )
        try Data(#"{"legacy":"preserved"}"#.utf8).write(
            to: generationURL.appendingPathComponent(provenanceFilename)
        )
        try FileManager.default.createSymbolicLink(
            atPath: annotationRoot.appendingPathComponent("active").path,
            withDestinationPath: "generations/\(generationID)"
        )
        for filename in [annotationFilename, provenanceFilename] {
            try FileManager.default.createSymbolicLink(
                atPath: bundleURL.appendingPathComponent(filename).path,
                withDestinationPath:
                    "artifacts/genotype-annotations/active/\(filename)"
            )
        }
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: "linked-layout",
            analysisName: "Linked layout",
            primaryWorkbookPath: "result.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "CR1178",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
            ],
            manifest: manifest
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingShowMatrixTargetSelection([
            .column(sample: "CR1178"),
        ])

        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "CR1178"
        )
        XCTAssertNotNil(controller.testingSampleWorkbenchLayoutMode)
    }


    func testHaplotypedMiSeqExcludesManualHaplotypeEditorAndContextCommand()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HaplotypedMiSeqManualEditor-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind
                .miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .haplotyped,
            outputName: "haplotyped-miseq",
            analysisName: "Haplotyped MiSeq",
            primaryWorkbookPath: "result.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
            ],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis(),
            manifest: manifest
        )
        guard case .ineligible =
            GenotypeManualHaplotypeEligibility.evaluate(result) else {
            return XCTFail("Haplotyped MiSeq result must be ineligible")
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingShowMatrixTargetSelection([
            .column(sample: "AnimalA"),
        ])

        XCTAssertNil(controller.testingManualHaplotypeEditorSample)
        XCTAssertNil(controller.testingSampleWorkbenchLayoutMode)
        let menu = controller.testingComparisonMatrix
            .testingBuildActualContextMenu(
                for: .column(sample: "AnimalA")
            )
        XCTAssertFalse(
            menu?.items.contains {
                $0.title == "Edit Haplotype Assignments…"
            } ?? true
        )
    }


    func testManualHaplotypeBandShowsSevenRowsH1BeforeH2AndAccessibleHeaderSummary() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h2,
                label: "A-H2",
                colorTokenIndex: 2,
                diagnosticAlleles: [],
                notes: ""
            ),
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: "A-H1",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            ),
            sidecar: sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            matrix.testingManualHaplotypeBandLoci,
            ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
        )
        XCTAssertEqual(matrix.testingHaplotypeBandMode, .manualAssignments)
        XCTAssertEqual(matrix.testingHaplotypeBandExpandedRowCount, 7)
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(sample: "AnimalA").first,
            "A-H1 · A-H2"
        )
        XCTAssertEqual(
            Array(matrix.testingManualHaplotypeBandValues(sample: "AnimalA").dropFirst()),
            Array(repeating: "—", count: 6)
        )
        XCTAssertEqual(matrix.testingManualHaplotypeBandPerSampleControlCount, 0)
        XCTAssertFalse(matrix.testingManualHaplotypeBandCellsAreFocusable)
        let accessibility = matrix.testingColumnAccessibilityLabel(sample: "AnimalA") ?? ""
        XCTAssertTrue(accessibility.contains("MHC-A H1 A-H1, H2 A-H2"))
    }


    func testExpandedBandAutoFitsEachSampleToWidestCompleteAssignmentPair()
        throws
    {
        let longH1 = String(repeating: "H", count: 128)
        let longH2 = "second-manual-haplotype"
        let displayedPair = "\(longH1) · \(longH2)"
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: longH1,
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            ),
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h2,
                label: longH2,
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                    makeCall(
                        sample: "AnimalB-with-a-wide-header",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            ),
            sidecar: sidecar
        )
        let collapsedWidth = matrix.testingSampleColumnWidth(
            sample: "AnimalA"
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        let font = NSFont.systemFont(
            ofSize: matrix.testingManualHaplotypeBandFontPointSize
        )
        let requiredPairWidth = ceil(
            (displayedPair as NSString).size(
                withAttributes: [.font: font]
            ).width + 12
        )
        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            collapsedWidth
        )
        XCTAssertGreaterThanOrEqual(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            requiredPairWidth
        )
        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(
                sample: "AnimalB-with-a-wide-header"
            ),
            68,
            "The ordinary header remains part of the auto-fit floor."
        )
    }


    func testAutoFitNeverOverwritesStoredUserPreferredWidth() {
        let longLabel = String(repeating: "A", count: 128)
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: longLabel,
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            ),
            sidecar: sidecar
        )
        matrix.testingResizeSampleColumnThroughProductionCallback(
            sample: "AnimalA",
            width: 112
        )
        XCTAssertEqual(
            matrix.testingUserPreferredSampleColumnWidth(sample: "AnimalA"),
            112,
            accuracy: 0.5
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            112
        )
        XCTAssertEqual(
            matrix.testingUserPreferredSampleColumnWidth(sample: "AnimalA"),
            112,
            accuracy: 0.5,
            "Programmatic auto-fit must not become the stored preference."
        )
    }


    func testSavedMaximumLengthHaplotypeSettlesColumnAndBandGeometryImmediately()
        throws
    {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: ["AnimalA", "AnimalB"].map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            )
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        let beforeA = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        let beforeB = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalB")
        )
        let beforeBandFrames =
            matrix.testingRenderedManualHaplotypeBandColumnFrames
        let beforeBandB = try XCTUnwrap(beforeBandFrames["AnimalB"])
        let beforeColumnWidth =
            matrix.testingSampleColumnWidth(sample: "AnimalA")
        XCTAssertEqual(
            matrix.testingUserPreferredSampleColumnWidth(sample: "AnimalA"),
            68,
            accuracy: 0.5
        )

        matrix.applyManualHaplotypeAssignments([
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: String(repeating: "W", count: 128),
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            ),
        ])

        // Deliberately do not call layoutSubtreeIfNeeded: a completed save must
        // leave the native table, fixed header, and manual band synchronized.
        let afterA = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        let afterB = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalB")
        )
        let afterBandFrames =
            matrix.testingRenderedManualHaplotypeBandColumnFrames
        let afterBandA = try XCTUnwrap(afterBandFrames["AnimalA"])
        let afterBandB = try XCTUnwrap(afterBandFrames["AnimalB"])
        let widthIncrease =
            afterA.sampleColumnRect.width - beforeA.sampleColumnRect.width

        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            beforeColumnWidth
        )
        XCTAssertGreaterThan(widthIncrease, 0)
        XCTAssertEqual(
            afterB.sampleColumnRect.width,
            beforeB.sampleColumnRect.width,
            accuracy: 0.5
        )
        XCTAssertEqual(
            matrix.testingUserPreferredSampleColumnWidth(sample: "AnimalA"),
            68,
            accuracy: 0.5,
            "Auto-fit is presentation state, not a user width preference."
        )
        XCTAssertEqual(
            afterB.sampleColumnRect.minX - beforeB.sampleColumnRect.minX,
            widthIncrease,
            accuracy: 0.5
        )
        XCTAssertEqual(
            afterBandA.width,
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            accuracy: 0.5
        )
        XCTAssertEqual(
            afterBandB.minX - beforeBandB.minX,
            widthIncrease,
            accuracy: 0.5
        )
    }


    func testUserResizeToExpandedTransientFloorBecomesPreferredWidth() {
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: String(repeating: "W", count: 12),
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            ),
            sidecar: sidecar
        )
        matrix.testingResizeSampleColumnThroughProductionCallback(
            sample: "AnimalA",
            width: 300
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        let assignmentFont = NSFont.systemFont(
            ofSize: matrix.testingManualHaplotypeBandFontPointSize
        )
        let transientFloor = ceil(
            ("\(String(repeating: "W", count: 12)) · —" as NSString)
                .size(withAttributes: [.font: assignmentFont]).width + 12
        )
        XCTAssertLessThan(transientFloor, 300)

        matrix.testingResizeSampleColumnThroughProductionCallback(
            sample: "AnimalA",
            width: transientFloor
        )
        let resizedWidth = matrix.testingSampleColumnWidth(sample: "AnimalA")
        XCTAssertEqual(resizedWidth, transientFloor, accuracy: 0.5)
        XCTAssertEqual(
            matrix.testingUserPreferredSampleColumnWidth(sample: "AnimalA"),
            resizedWidth,
            accuracy: 0.5,
            "A genuine resize callback must capture the analyst's exact width, even when it equals the transient auto-fit floor."
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)

        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            resizedWidth,
            accuracy: 0.5
        )
    }


    func testUserResizeCapturesOnlyNotifiedSampleColumn() {
        let labelsBySample = [
            "AnimalA": String(repeating: "W", count: 12),
            "AnimalB": String(repeating: "W", count: 40),
            "AnimalC": String(repeating: "W", count: 50),
        ]
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = labelsBySample.map {
            sample,
            label in
            ManualHaplotypeAssignment(
                sample: sample,
                locus: "MHC-A",
                slot: .h1,
                label: label,
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            )
        }
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: labelsBySample.keys.sorted().map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            ),
            sidecar: sidecar
        )
        let baselineWidths: [String: CGFloat] = [
            "AnimalA": 300,
            "AnimalB": 100,
            "AnimalC": 110,
        ]
        for sample in baselineWidths.keys.sorted() {
            matrix.testingResizeSampleColumnThroughProductionCallback(
                sample: sample,
                width: baselineWidths[sample]!
            )
        }
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: "AnimalB"),
            baselineWidths["AnimalB"]!
        )
        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: "AnimalC"),
            baselineWidths["AnimalC"]!
        )
        let assignmentFont = NSFont.systemFont(
            ofSize: matrix.testingManualHaplotypeBandFontPointSize
        )
        let animalAFloor = ceil(
            ("\(labelsBySample["AnimalA"]!) · —" as NSString)
                .size(withAttributes: [.font: assignmentFont]).width + 12
        )

        matrix.testingResizeSampleColumnThroughProductionCallback(
            sample: "AnimalA",
            width: animalAFloor
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)

        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            animalAFloor,
            accuracy: 0.5
        )
        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "AnimalB"),
            baselineWidths["AnimalB"]!,
            accuracy: 0.5,
            "Resizing AnimalA must not promote AnimalB's transient floor."
        )
        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "AnimalC"),
            baselineWidths["AnimalC"]!,
            accuracy: 0.5,
            "Resizing AnimalA must not promote AnimalC's transient floor."
        )
    }


    func testCollapseRestoresUserOrHeaderWidth() {
        let longLabel = String(repeating: "B", count: 128)
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: longLabel,
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            ),
            sidecar: sidecar
        )
        let collapsedWidth = matrix.testingSampleColumnWidth(
            sample: "AnimalA"
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        XCTAssertGreaterThan(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            collapsedWidth
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)

        XCTAssertEqual(
            matrix.testingSampleColumnWidth(sample: "AnimalA"),
            collapsedWidth,
            accuracy: 0.5
        )
    }


    func testTypographyRemeasuresAllVisibleSamplesOnceAndSaveRemeasuresOnlyChangedSample() {
        let samples = ["AnimalA", "AnimalB", "AnimalC"]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: samples.map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            )
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.testingResetManualHaplotypeAutoFitMeasurementCounts()

        matrix.testingSetManualHaplotypeBandTypographyScale(1.5)

        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitMeasurementCounts,
            Dictionary(uniqueKeysWithValues: samples.map { ($0, 1) })
        )
        matrix.testingResetManualHaplotypeAutoFitMeasurementCounts()

        matrix.applyManualHaplotypeAssignments([
            ManualHaplotypeAssignment(
                sample: "AnimalB",
                locus: "MHC-A",
                slot: .h1,
                label: "Changed",
                colorTokenIndex: 0,
                diagnosticAlleles: [],
                notes: ""
            ),
        ])

        XCTAssertEqual(
            matrix.testingManualHaplotypeAutoFitMeasurementCounts,
            ["AnimalB": 1]
        )
    }


    func testExpandedManualHaplotypeSectionIsContainedByNativeMatrixHeader() throws {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        let snapshot = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertTrue(
            snapshot.ordinarySampleHeaderRect.contains(
                snapshot.sampleTitleRect
            )
        )
        XCTAssertTrue(
            snapshot.ordinarySampleHeaderRect.contains(
                snapshot.sampleReadTextRect
            )
        )
        XCTAssertFalse(snapshot.manualSectionRect.isEmpty)
        XCTAssertTrue(
            snapshot.nativeHeaderRect.contains(
                snapshot.ordinarySampleHeaderRect
            )
        )
        XCTAssertTrue(
            snapshot.nativeHeaderRect.contains(
                snapshot.manualSectionRect
            ),
            "The manual section must be spatially contained by the native header."
        )
        XCTAssertFalse(
            snapshot.ordinarySampleHeaderRect.intersects(
                snapshot.manualSectionRect
            )
        )
        XCTAssertFalse(
            snapshot.sampleTitleRect.intersects(
                snapshot.manualSectionRect
            )
        )
        XCTAssertFalse(
            snapshot.sampleReadTextRect.intersects(
                snapshot.manualSectionRect
            )
        )
        XCTAssertEqual(
            snapshot.totalNativeHeaderHeight,
            snapshot.ordinarySampleHeaderRect.height
                + snapshot.manualSectionRect.height,
            accuracy: 0.5,
            "The manual section must be part of the native fixed table header."
        )
        let firstRow = try XCTUnwrap(snapshot.firstTableRowRect)
        XCTAssertFalse(
            snapshot.manualSectionRect.intersects(firstRow),
            "The first genotype row must begin below the fixed manual section."
        )
    }


    func testNativeMatrixHeaderRegionsRemainFixedAfterVerticalScrolling() throws {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 300)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: (0..<30).map { index in
                    makeCall(
                        sample: "AnimalA",
                        genotype: String(
                            format: "%02d_Mafa_A1_SCROLL_%02d",
                            index,
                            index
                        ),
                        reads: index + 1
                    )
                }
            )
        )
        matrix.layoutSubtreeIfNeeded()
        let before = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        let beforeScrollY =
            matrix.testingSampleMatrixScrollOffset.y

        matrix.testingScrollSampleMatrixVertically(to: 180)
        matrix.layoutSubtreeIfNeeded()

        let after = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertGreaterThan(
            matrix.testingSampleMatrixScrollOffset.y,
            beforeScrollY
        )
        XCTAssertEqual(
            after.ordinarySampleHeaderRect,
            before.ordinarySampleHeaderRect
        )
        XCTAssertEqual(after.manualSectionRect, before.manualSectionRect)
    }


    func testUnassignedManualHaplotypeValueIsCenteredInSampleColumn() throws {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        let header = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        let value = try XCTUnwrap(
            matrix.testingManualValueSnapshot(
                sample: "AnimalA",
                locus: "MHC-A"
            )
        )
        XCTAssertEqual(value.value, "—")
        XCTAssertEqual(value.alignment, .center)
        XCTAssertEqual(
            value.textRect.midX,
            header.sampleColumnRect.midX,
            accuracy: 0.5
        )
    }


    func testNativeMatrixHeaderHeightTracksExpandedManualRows() throws {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()
        let expanded = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)
        matrix.layoutSubtreeIfNeeded()
        let collapsed = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertEqual(
            expanded.totalNativeHeaderHeight
                - collapsed.totalNativeHeaderHeight,
            matrix.testingManualHaplotypeBandRowHeight * 7,
            accuracy: 0.5
        )
    }


    func testCollapseRemovesSevenRowsAndPreservesSemanticViewportState()
        throws
    {
        let samples = ["AnimalA", "AnimalB", "AnimalC", "AnimalD", "AnimalE"]
        let calls = (0..<24).flatMap { row in
            samples.enumerated().map { sampleIndex, sample in
                makeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_A1", row),
                    reads: row + sampleIndex + 1
                )
            }
        }
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        matrix.configure(result: makeResult(samples: [], calls: calls))
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.testingMoveSampleColumn(sample: "AnimalE", to: 0)
        matrix.testingSetFilter("Mafa")
        let sortKey = try XCTUnwrap(
            matrix.testingSortKey(forSample: "AnimalC")
        )
        matrix.testingSetSortDescriptor(key: sortKey, ascending: false)
        matrix.testingSelectMatrixTargets([
            .cell(
                locus: "MHC-A1",
                genotype: "05_Mafa_A1",
                sample: "AnimalB"
            ),
            .row(locus: "MHC-A1", genotype: "06_Mafa_A1"),
        ])
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(
                x: 0,
                y: matrix.testingMatrixRowHeight * 5 + 3
            ),
            samples: NSPoint(
                x: 70,
                y: matrix.testingMatrixRowHeight * 5 + 3
            )
        )
        let expandedHeader = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        let expectedAnchor = matrix.testingSemanticScrollAnchor
        let expectedTargets = matrix.testingSelectedMatrixTargets
        let expectedSamples = matrix.testingVisibleSampleColumnTitles
        let expectedGenotypes = matrix.testingVisibleGenotypes
        let expectedSort = matrix.testingActiveSortDescriptorKey
        let expectedFilter = matrix.testingFilterModelText

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(false)
        matrix.layoutSubtreeIfNeeded()

        let collapsedHeader = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertEqual(
            expandedHeader.totalNativeHeaderHeight
                - collapsedHeader.totalNativeHeaderHeight,
            matrix.testingManualHaplotypeBandRowHeight * 7,
            accuracy: 0.5
        )
        assertManualDisclosurePreservesViewport(
            matrix,
            anchor: expectedAnchor,
            targets: expectedTargets,
            samples: expectedSamples,
            genotypes: expectedGenotypes,
            sort: expectedSort,
            filter: expectedFilter
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        assertManualDisclosurePreservesViewport(
            matrix,
            anchor: expectedAnchor,
            targets: expectedTargets,
            samples: expectedSamples,
            genotypes: expectedGenotypes,
            sort: expectedSort,
            filter: expectedFilter
        )
    }


    func testHaplotypedMatrixHasOnlyOrdinaryNativeHeader() throws {
        let ineligible = GenotypeComparisonMatrixView()
        ineligible.frame = NSRect(
            x: 0,
            y: 0,
            width: 760,
            height: 520
        )
        ineligible.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ],
                haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
            )
        )
        ineligible.layoutSubtreeIfNeeded()
        let ineligibleSnapshot = try XCTUnwrap(
            ineligible.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertEqual(ineligible.testingHaplotypeBandMode, .none)
        XCTAssertTrue(ineligibleSnapshot.manualSectionRect.isEmpty)
        XCTAssertEqual(
            ineligibleSnapshot.totalNativeHeaderHeight,
            ineligibleSnapshot.ordinarySampleHeaderRect.height,
            accuracy: 0.5
        )
    }


    func testManualHaplotypeBandDisclosurePersistsAndUsesContentTypography() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        matrix.layoutSubtreeIfNeeded()
        XCTAssertFalse(matrix.testingManualHaplotypeBandIsExpanded)
        let baselineHeight = matrix.testingManualHaplotypeBandRowHeight
        let baselineFont = matrix.testingManualHaplotypeBandFontPointSize

        var collapsed = GenotypeResultDisplayState()
        collapsed.manualHaplotypeBandExpanded = false
        matrix.applyDisplayState(collapsed)
        XCTAssertFalse(matrix.testingManualHaplotypeBandIsExpanded)

        var restored = GenotypeResultDisplayState()
        restored.manualHaplotypeBandExpanded = true
        matrix.applyDisplayState(restored)
        matrix.testingSetManualHaplotypeBandTypographyScale(1.8)
        XCTAssertTrue(matrix.testingManualHaplotypeBandIsExpanded)
        XCTAssertGreaterThan(
            matrix.testingManualHaplotypeBandRowHeight,
            baselineHeight
        )
        XCTAssertGreaterThan(
            matrix.testingManualHaplotypeBandFontPointSize,
            baselineFont
        )
    }


    func testManualHaplotypeDisclosureKeepsCompactIconRowAtTwoHundredPercent()
        throws
    {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 427, height: 520)
        matrix.testingSetPinnedPaneWidth(180)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        matrix.testingSetManualHaplotypeBandTypographyScale(2)
        matrix.layoutSubtreeIfNeeded()

        let collapsed = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertEqual(
            collapsed.manualSectionRect.height,
            matrix.testingManualHaplotypeBandRowHeight,
            accuracy: 0.5,
            "The icon-only disclosure row should not grow because a hidden "
                + "accessibility label would have wrapped."
        )

        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()
        let expanded = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        XCTAssertEqual(
            expanded.manualSectionRect.height
                - collapsed.manualSectionRect.height,
            matrix.testingManualHaplotypeBandRowHeight * 7,
            accuracy: 0.5,
            "Only the seven assignment row heights are added on expansion."
        )
    }


    func testManualHaplotypeDisclosureWidthChangesDoNotRetileCompactIcon()
        throws
    {
        let samples = ["AnimalA", "AnimalB", "AnimalC", "AnimalD"]
        let calls = (0..<24).flatMap { row in
            samples.map { sample in
                makeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_A1", row),
                    reads: row + 1
                )
            }
        }
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 800, height: 320)
        matrix.testingSetPinnedPaneWidth(420)
        matrix.configure(result: makeResult(samples: [], calls: calls))
        matrix.testingSetManualHaplotypeBandTypographyScale(2)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(
                x: 0,
                y: matrix.testingMatrixRowHeight * 5 + 3
            ),
            samples: NSPoint(
                x: 60,
                y: matrix.testingMatrixRowHeight * 5 + 3
            )
        )
        let sameLineHeader = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )
        matrix.testingResetManualHaplotypeDisclosureLayoutCounters()

        for width: CGFloat in [400, 380, 360] {
            matrix.testingSetPinnedPaneWidth(width)
            let current = try XCTUnwrap(
                matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
            )
            XCTAssertEqual(
                current.manualSectionRect.height,
                sameLineHeader.manualSectionRect.height,
                accuracy: 0.5
            )
        }
        XCTAssertEqual(
            matrix.testingManualHaplotypeDisclosureLayoutCounters
                .headerRelayouts,
            0
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeDisclosureLayoutCounters
                .anchorPreservations,
            0
        )

        let anchor = matrix.testingSemanticScrollAnchor
        matrix.testingSetPinnedPaneWidth(180)
        let narrowHeader = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA")
        )

        XCTAssertEqual(
            narrowHeader.manualSectionRect.height,
            sameLineHeader.manualSectionRect.height,
            accuracy: 0.5
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeDisclosureLayoutCounters
                .headerRelayouts,
            0
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeDisclosureLayoutCounters
                .anchorPreservations,
            0
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.rowID,
            anchor.rowID
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinRowOffset,
            anchor.withinRowOffset,
            accuracy: 0.01
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.leadingSampleID,
            anchor.leadingSampleID
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinSampleOffset,
            anchor.withinSampleOffset,
            accuracy: 0.01
        )
    }


    func testManualHaplotypeBandRealignsAfterContentTextSizeChanges()
        throws
    {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        let samples = (0..<20).map {
            String(format: "Animal%02d", $0)
        }
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: samples.map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            )
        )
        matrix.layoutSubtreeIfNeeded()
        let fonts = MutableGenotypePreferredFonts(pointSize: 10)
        matrix.testingSetContentPreferredFontProvider(fonts)
        matrix.layoutSubtreeIfNeeded()
        let baselineFrames = matrix.testingManualHaplotypeBandColumnFrames

        fonts.pointSize = 11
        matrix.testingSetContentPreferredFontProvider(fonts)
        matrix.layoutSubtreeIfNeeded()

        let enlargedFrames = matrix.testingManualHaplotypeBandColumnFrames
        for sample in samples.prefix(3) {
            XCTAssertEqual(
                try XCTUnwrap(enlargedFrames[sample]?.width),
                matrix.testingSampleColumnWidth(sample: sample),
                accuracy: 0.5
            )
            XCTAssertGreaterThan(
                try XCTUnwrap(enlargedFrames[sample]?.width),
                try XCTUnwrap(baselineFrames[sample]?.width)
            )
        }
        XCTAssertLessThan(
            try XCTUnwrap(enlargedFrames[samples[0]]?.minX),
            try XCTUnwrap(enlargedFrames[samples[1]]?.minX)
        )
        XCTAssertLessThan(
            try XCTUnwrap(enlargedFrames[samples[1]]?.minX),
            try XCTUnwrap(enlargedFrames[samples[2]]?.minX)
        )
    }


    func testManualHaplotypeBandDisclosurePersistsPerWindowAndBundleAcrossControllerRecreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeDisclosure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = root.appendingPathComponent(
            "first.lungfishgenotype",
            isDirectory: true
        )
        let secondBundle = root.appendingPathComponent(
            "second.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstBundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondBundle,
            withIntermediateDirectories: true
        )
        let store = GenotypeManualHaplotypeBandDisclosureStore()
        var firstController: GenotypeResultViewController? =
            GenotypeResultViewController()
        firstController?.manualHaplotypeBandDisclosureStore = store
        _ = firstController?.view
        firstController?.configure(
            result: makeResult(
                bundleURL: firstBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        firstController?
            .testingSetManualHaplotypeBandDisclosureExpanded(true)
        XCTAssertTrue(firstController?.testingDisplayState
            .manualHaplotypeBandExpanded ?? false)
        firstController = nil

        let recreated = GenotypeResultViewController()
        recreated.manualHaplotypeBandDisclosureStore = store
        _ = recreated.view
        recreated.configure(
            result: makeResult(
                bundleURL: firstBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        XCTAssertTrue(
            recreated.testingDisplayState.manualHaplotypeBandExpanded
        )

        recreated.configure(
            result: makeResult(
                bundleURL: secondBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalB",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 21
                    ),
                ]
            )
        )
        XCTAssertFalse(
            recreated.testingDisplayState.manualHaplotypeBandExpanded
        )
        recreated.configure(
            result: makeResult(
                bundleURL: firstBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        XCTAssertTrue(
            recreated.testingDisplayState.manualHaplotypeBandExpanded
        )
    }


    func testNewBundleStartsCollapsedAndExpansionRemainsWindowBundlePresentationState()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypePresentation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = root.appendingPathComponent(
            "first.lungfishgenotype",
            isDirectory: true
        )
        let secondBundle = root.appendingPathComponent(
            "second.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstBundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondBundle,
            withIntermediateDirectories: true
        )
        let annotationURL = firstBundle.appendingPathComponent(
            "annotations.json"
        )
        let auditURL = firstBundle.appendingPathComponent("audit.jsonl")
        let annotationSentinel = Data("annotation sentinel".utf8)
        let auditSentinel = Data("audit sentinel".utf8)
        try annotationSentinel.write(to: annotationURL)
        try auditSentinel.write(to: auditURL)

        let store = GenotypeManualHaplotypeBandDisclosureStore()
        var controller: GenotypeResultViewController? =
            GenotypeResultViewController()
        controller?.manualHaplotypeBandDisclosureStore = store
        _ = controller?.view
        controller?.configure(
            result: makeResult(
                bundleURL: firstBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1",
                        reads: 42
                    ),
                ]
            )
        )
        XCTAssertFalse(
            controller?.testingDisplayState.manualHaplotypeBandExpanded
                ?? true
        )

        controller?.testingSetManualHaplotypeBandDisclosureExpanded(true)
        XCTAssertTrue(
            controller?.testingDisplayState.manualHaplotypeBandExpanded
                ?? false
        )
        controller = nil

        let recreated = GenotypeResultViewController()
        recreated.manualHaplotypeBandDisclosureStore = store
        _ = recreated.view
        recreated.configure(
            result: makeResult(
                bundleURL: firstBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1",
                        reads: 42
                    ),
                ]
            )
        )
        XCTAssertTrue(
            recreated.testingDisplayState.manualHaplotypeBandExpanded
        )

        recreated.configure(
            result: makeResult(
                bundleURL: secondBundle,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalB",
                        genotype: "01_Mafa_A1",
                        reads: 21
                    ),
                ]
            )
        )
        XCTAssertFalse(
            recreated.testingDisplayState.manualHaplotypeBandExpanded
        )
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationSentinel)
        XCTAssertEqual(try Data(contentsOf: auditURL), auditSentinel)
    }


    func testManualHaplotypeBandLeavesIneligibleAccessibilityAndScrollingUnchanged() {
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixComments = [
            .init(
                target: .column(sample: "AnimalA"),
                body: "Column note.",
                author: "test",
                timestamp: "2026-07-27T00:00:00Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ],
                haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                    assayID: "MHC-exon2-miSeq",
                    definitionSetID: "test",
                    definitionSetName: "Test",
                    speciesName: "Test",
                    samples: []
                )
            ),
            sidecar: sidecar
        )
        matrix.layoutSubtreeIfNeeded()

        let label = matrix.testingColumnAccessibilityLabel(
            sample: "AnimalA"
        ) ?? ""
        XCTAssertTrue(label.contains("1 sample column comment"))
        XCTAssertFalse(label.contains("Manual haplotypes"))
        XCTAssertEqual(matrix.testingManualHaplotypeBandTopInsets, [0, 0])
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandAutomaticInsetAdjustment,
            [true, true]
        )
    }


    func testManualHaplotypeBandUsesApprovedLabelAndCompletePairTooltip() {
        let longH1 = "M1A assignment label that is intentionally long"
        let longH2 = "M2A assignment label that is also intentionally long"
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: longH1,
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h2,
                label: longH2,
                colorTokenIndex: 2,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 520, height: 480)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            ),
            sidecar: sidecar
        )
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            matrix.testingManualHaplotypeBandDisclosureLabel,
            "Manual haplotypes (7 loci)"
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandTooltip(
                sample: "AnimalA",
                locus: "MHC-A"
            ),
            "MHC-A — H1: \(longH1); H2: \(longH2)"
        )
    }


    func testManualHaplotypeBandRefreshesRegisteredTooltipHitRegionAfterScroll()
        throws
    {
        let samples = (0..<20).map {
            String(format: "Animal%02d", $0)
        }
        let trailingSample = try XCTUnwrap(samples.last)
        let longLabel = "Trailing assignment label that requires a tooltip"
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: trailingSample,
                locus: "MHC-A",
                slot: .h1,
                label: longLabel,
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: samples.map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            ),
            sidecar: sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        matrix.testingScrollSampleMatrix(
            to: NSPoint(x: CGFloat.greatestFiniteMagnitude, y: 0)
        )
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            matrix.testingRegisteredManualHaplotypeBandTooltip(
                sample: trailingSample,
                locus: "MHC-A"
            ),
            "MHC-A — H1: \(longLabel); H2: unassigned"
        )
    }


    func testManualHaplotypeBandTracksHorizontalGeometryAcrossScrollReorderResizeAndVisibility() throws {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        let calls = ["AnimalA", "AnimalB", "AnimalC"].map {
            makeCall(
                sample: $0,
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            )
        }
        matrix.configure(result: makeResult(samples: [], calls: calls))
        matrix.layoutSubtreeIfNeeded()

        let initial = matrix.testingManualHaplotypeBandColumnFrames
        matrix.testingScrollSampleMatrix(to: NSPoint(x: 24, y: 0))
        matrix.layoutSubtreeIfNeeded()
        let scrolled = matrix.testingManualHaplotypeBandColumnFrames
        let appliedHorizontalOffset =
            matrix.testingSampleMatrixScrollOffset.x
        XCTAssertEqual(
            try XCTUnwrap(scrolled["AnimalA"]?.minX),
            try XCTUnwrap(initial["AnimalA"]?.minX)
                - appliedHorizontalOffset,
            accuracy: 0.5
        )

        matrix.testingMoveSampleColumn(sample: "AnimalC", to: 0)
        matrix.testingSetSampleColumnWidth(sample: "AnimalC", width: 120)
        matrix.layoutSubtreeIfNeeded()
        let reordered = matrix.testingManualHaplotypeBandColumnFrames
        XCTAssertLessThan(
            try XCTUnwrap(reordered["AnimalC"]?.minX),
            try XCTUnwrap(reordered["AnimalA"]?.minX)
        )
        XCTAssertEqual(
            try XCTUnwrap(reordered["AnimalC"]?.width),
            matrix.testingSampleColumnWidth(sample: "AnimalC"),
            accuracy: 0.5
        )

        matrix.testingSelectMatrixTargets([.column(sample: "AnimalB")])
        XCTAssertTrue(matrix.testingPerformContextCommand(.hideSelectedColumns))
        XCTAssertNil(matrix.testingManualHaplotypeBandColumnFrames["AnimalB"])
    }


    func testManualHaplotypeBandSkipsVerticalGeometryWorkAndBoundsSmallHorizontalWork()
        throws
    {
        let sampleCount = 500
        let sampleNames = (0..<sampleCount).map {
            String(format: "Animal%03d", $0)
        }
        var calls = sampleNames.map {
            makeCall(
                sample: $0,
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            )
        }
        calls.append(
            contentsOf: (1..<50).map {
                makeCall(
                    sample: sampleNames[0],
                    genotype: String(
                        format: "%02d_Mafa_A1_SCROLL_%02d",
                        $0,
                        $0
                    ),
                    reads: $0
                )
            }
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        matrix.configure(result: makeResult(samples: [], calls: calls))
        matrix.layoutSubtreeIfNeeded()

        let initialFrames =
            matrix.testingRenderedManualHaplotypeBandColumnFrames
        XCTAssertLessThan(initialFrames.count, 100)
        XCTAssertLessThan(initialFrames.count, sampleCount)
        matrix.testingResetManualHaplotypeGeometryCounters()
        for y in stride(from: CGFloat(20), through: 180, by: 20) {
            matrix.testingScrollSampleMatrixVertically(to: y)
        }
        let vertical =
            matrix.testingManualHaplotypeGeometryCounters
        XCTAssertEqual(vertical.updates, 0)
        XCTAssertEqual(vertical.recomputations, 0)
        XCTAssertEqual(vertical.inspectedColumns, 0)

        matrix.testingResetManualHaplotypeGeometryCounters()
        matrix.testingScrollSampleMatrix(
            to: NSPoint(x: 12, y: 180)
        )
        let horizontal =
            matrix.testingManualHaplotypeGeometryCounters
        let cachedFrames =
            matrix.testingRenderedManualHaplotypeBandColumnFrames
        XCTAssertGreaterThan(horizontal.updates, 0)
        XCTAssertEqual(horizontal.recomputations, 0)
        XCTAssertEqual(horizontal.inspectedColumns, 0)
        XCTAssertEqual(
            try XCTUnwrap(cachedFrames[sampleNames[0]]?.minX),
            try XCTUnwrap(initialFrames[sampleNames[0]]?.minX),
            accuracy: 0.5
        )

        matrix.testingResetManualHaplotypeGeometryCounters()
        matrix.testingScrollSampleMatrix(
            to: NSPoint(x: 5_000, y: 180)
        )
        let refill =
            matrix.testingManualHaplotypeGeometryCounters
        let refilledFrames =
            matrix.testingRenderedManualHaplotypeBandColumnFrames
        XCTAssertEqual(refill.recomputations, 1)
        XCTAssertGreaterThan(refill.inspectedColumns, 0)
        XCTAssertLessThan(refill.inspectedColumns, 100)
        XCTAssertLessThan(refill.inspectedColumns, sampleCount)
        XCTAssertLessThan(refilledFrames.count, 100)
    }


    func testManualHaplotypeProductionResizeRefreshesRendererImmediately()
        throws
    {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: ["AnimalA", "AnimalB"].map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            )
        )
        matrix.layoutSubtreeIfNeeded()

        matrix.testingResizeSampleColumnThroughProductionCallback(
            sample: "AnimalA",
            width: 120
        )

        XCTAssertEqual(
            try XCTUnwrap(
                matrix.testingRenderedManualHaplotypeBandColumnFrames[
                    "AnimalA"
                ]?.width
            ),
            120,
            accuracy: 0.5
        )
    }


    func testManualHaplotypeProductionMoveRefreshesRendererAndTooltipImmediately()
        throws
    {
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-28T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalC",
                locus: "MHC-A",
                slot: .h1,
                label: "C-H1",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: ["AnimalA", "AnimalB", "AnimalC"].map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            ),
            sidecar: sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()

        matrix.testingMoveSampleColumnThroughProductionCallback(
            sample: "AnimalC",
            to: 0
        )

        let frames =
            matrix.testingRenderedManualHaplotypeBandColumnFrames
        XCTAssertLessThan(
            try XCTUnwrap(frames["AnimalC"]?.minX),
            try XCTUnwrap(frames["AnimalA"]?.minX)
        )
        XCTAssertEqual(
            matrix.testingRegisteredManualHaplotypeTooltipAtLiveColumn(
                sample: "AnimalC",
                locus: "MHC-A"
            ),
            "MHC-A — H1: C-H1; H2: unassigned"
        )
    }


    func testManualHaplotypeSemanticAnchorRefreshesRendererAfterLargeProgrammaticJump()
        throws
    {
        let sampleNames = (0..<500).map {
            String(format: "Animal%03d", $0)
        }
        let anchoredSample = sampleNames[450]
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-28T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: anchoredSample,
                locus: "MHC-A",
                slot: .h1,
                label: "Anchored-H1",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: sampleNames.map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            ),
            sidecar: sidecar
        )
        matrix.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingSetLeadingSampleScrollAnchor(
            sample: anchoredSample,
            offset: 7
        )
        XCTAssertNotNil(
            matrix.testingRenderedManualHaplotypeBandColumnFrames[
                anchoredSample
            ]
        )

        matrix.testingSelectMatrixTargets([
            .column(sample: sampleNames[0]),
        ])
        XCTAssertTrue(
            matrix.testingPerformContextCommand(.hideSelectedColumns)
        )

        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.leadingSampleID,
            anchoredSample
        )
        XCTAssertNotNil(
            matrix.testingRenderedManualHaplotypeBandColumnFrames[
                anchoredSample
            ]
        )
        XCTAssertEqual(
            matrix.testingRegisteredManualHaplotypeBandTooltip(
                sample: anchoredSample,
                locus: "MHC-A"
            ),
            "MHC-A — H1: Anchored-H1; H2: unassigned"
        )
    }


    func testManualHaplotypeBandRedrawsOnlyChangedVisibleSampleColumn() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: ["AnimalA", "AnimalB"].map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            )
        )
        matrix.testingResetManualHaplotypeBandInvalidations()
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalB",
                locus: "MHC-B",
                slot: .h1,
                label: "B-H1",
                colorTokenIndex: 3,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]

        matrix.testingResetReloadCounters()
        matrix.applyManualHaplotypeAssignments(
            sidecar.manualHaplotypeAssignments
        )

        XCTAssertEqual(matrix.testingFullReloadCount, 0)
        XCTAssertEqual(matrix.testingPartialReloadCount, 0)
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandInvalidatedSamples,
            ["AnimalB"]
        )
    }


    func testMatrixContextMenuOffersManualHaplotypeEditForExactlyOneEligibleColumn() throws {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: ["AnimalA", "AnimalB"].map {
                    makeCall(
                        sample: $0,
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    )
                }
            )
        )
        var requestedSample: String?
        matrix.onManualHaplotypeEditRequested = { requestedSample = $0 }

        let single = matrix.testingBuildActualContextMenu(
            for: .column(sample: "AnimalA")
        )
        let editItems = single?.items.filter {
            $0.title == "Edit Haplotype Assignments…"
        } ?? []
        XCTAssertEqual(editItems.count, 1)
        if let item = editItems.first {
            _ = matrix.testingActivateContextMenuItem(item)
        }
        XCTAssertEqual(requestedSample, "AnimalA")

        matrix.testingSelectMatrixTargets([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ])
        XCTAssertFalse(
            matrix.testingBuildContextMenu(
                for: .column(sample: "AnimalA")
            )?.items.contains {
                $0.command == .editManualHaplotypeAssignments
            } ?? true
        )

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeContext-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            .empty(generatedAt: "2026-07-27T00:00:00Z"),
            forBundleAt: bundleURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(
            result: makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ]
            )
        )
        let controllerMenu = controller.testingComparisonMatrix
            .testingBuildActualContextMenu(
                for: .column(sample: "AnimalA")
            )
        if let edit = controllerMenu?.items.first(where: {
            $0.title == "Edit Haplotype Assignments…"
        }) {
            _ = controller.testingComparisonMatrix
                .testingActivateContextMenuItem(edit)
        } else {
            XCTFail("Expected manual haplotype edit command")
        }
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "AnimalA"
        )
        XCTAssertNil(
            controller.testingLastManualHaplotypeFocusedFieldIdentifier,
            "A focus diagnostic must only be published after a window "
                + "accepts the real combo as first responder."
        )

        let haplotyped = GenotypeComparisonMatrixView()
        haplotyped.configure(
            result: makeResult(
                samples: [],
                calls: [
                    makeCall(
                        sample: "AnimalA",
                        genotype: "01_Mafa_A1_001_01",
                        reads: 42
                    ),
                ],
                haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                    assayID: "MHC-exon2-miSeq",
                    definitionSetID: "test",
                    definitionSetName: "Test",
                    speciesName: "Test",
                    samples: []
                )
            )
        )
        XCTAssertFalse(
            haplotyped.testingBuildActualContextMenu(
                for: .column(sample: "AnimalA")
            )?.items.contains {
                $0.title == "Edit Haplotype Assignments…"
            } ?? true
        )
    }


    func testManualHaplotypeContextActionFocusesVisibleMHCATextField()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeFocus-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        controller.configure(
            result: makeResult(
                bundleURL: bundleURL,
                samples: [],
                calls: [call]
            )
        )
        controller.testingApplyDisplayStateImmediately(
            GenotypeResultDisplayState(
                summaryViewMode: .matrix,
                layout: .listTop
            )
        )
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(
            controller.testingPerformMatrixContextCommand(
                .editManualHaplotypeAssignments
            )
        )
        let deadline = Date(timeIntervalSinceNow: 10)
        var focusedCombo: NSComboBox?
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            controller.view.layoutSubtreeIfNeeded()
            if let combo = controller.testingFirstManualHaplotypeComboBox,
               window.firstResponder === combo
                    || combo.currentEditor() === window.firstResponder {
                focusedCombo = combo
                break
            }
        } while Date() < deadline

        let combo = try XCTUnwrap(
            focusedCombo,
            "The context action must focus the real mounted MHC-A H1 field."
        )
        let clipView = try XCTUnwrap(
            sequence(first: combo.superview) { $0?.superview }
                .compactMap { $0 as? NSClipView }
                .first
        )
        let comboFrame = combo.convert(combo.bounds, to: clipView)
        XCTAssertTrue(
            clipView.bounds.intersects(comboFrame),
            "The focused combo must be scrolled into the visible detail clip."
        )
        XCTAssertEqual(
            controller.testingLastManualHaplotypeFocusedFieldIdentifier,
            "manual-haplotype-MHC-A-h1"
        )
    }


    func testManualHaplotypeSaveMarksWorkbookDirtyOnceWithoutProjectionRebuild() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeSaveProjection-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        ).encoded().write(
            to: bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ),
            options: .atomic
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 1_200,
            height: 800
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 21
                ),
            ]
        )
        try ONTGenotypeResultBundle.writeManifest(
            result.manifest,
            to: bundleURL
        )
        controller.configure(result: result)
        controller.view.layoutSubtreeIfNeeded()
        let matrix = controller.testingComparisonMatrix
        var annotationSidecarChangedCount = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            annotationSidecarChangedCount += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(sample: "AnimalA").first,
            "—"
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(sample: "AnimalB").first,
            "—"
        )
        controller.testingResetProjectionPerformanceCounters()
        controller.testingShowMatrixTargetSelection([
            .column(sample: "AnimalA"),
        ])
        controller.testingUpdateManualHaplotypeLabel("M2A")
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertTrue(controller.testingManualHaplotypeEditorCanSave)
        controller.testingResetProjectionPerformanceCounters()
        let performanceBeforeSave =
            controller.testingProjectionPerformanceSnapshot
        matrix.testingResetManualHaplotypeBandInvalidations()
        controller.testingResetMatrixReloadCounters()

        controller.testingSaveManualHaplotypeDraft()

        XCTAssertNil(controller.testingManualHaplotypeEditorPersistenceError)
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertTrue(controller.testingCurrentWorkbookRequiresFullUpdate)
        XCTAssertEqual(
            controller.testingManualHaplotypeWorkbookDirtyMarkCount,
            1
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(sample: "AnimalA").first,
            "M2A · —"
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(sample: "AnimalB").first,
            "—"
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandInvalidatedSamples,
            ["AnimalA"]
        )
        XCTAssertEqual(annotationSidecarChangedCount, 1)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertEqual(controller.testingMatrixPartialReloadCount, 0)
        let performance =
            controller.testingProjectionPerformanceSnapshot
        XCTAssertEqual(
            performance.matrix.baseProjectionBuildCount,
            performanceBeforeSave.matrix.baseProjectionBuildCount
        )
        XCTAssertEqual(
            performance.matrix.derivedProjectionPassCount,
            performanceBeforeSave.matrix.derivedProjectionPassCount
        )
        XCTAssertEqual(
            performance.matrix.columnRebuildCount,
            performanceBeforeSave.matrix.columnRebuildCount
        )
    }


    func testManualHaplotypeClearImmediatelyRestoresHeaderDashWithoutMatrixReload()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeClear-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-28T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: "Seeded-H1",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
            ]
        )
        try ONTGenotypeResultBundle.writeManifest(
            result.manifest,
            to: bundleURL
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 1_200,
            height: 800
        )
        controller.configure(result: result)
        controller.testingShowMatrixTargetSelection([
            .column(sample: "AnimalA"),
        ])
        controller.view.layoutSubtreeIfNeeded()
        let matrix = controller.testingComparisonMatrix
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(
                sample: "AnimalA"
            ).first,
            "Seeded-H1 · —"
        )
        var annotationSidecarChangedCount = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            annotationSidecarChangedCount += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }

        controller.testingClearManualHaplotypeLabel(
            locus: .a,
            slot: .h1
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertTrue(controller.testingManualHaplotypeEditorCanSave)
        controller.testingResetMatrixReloadCounters()
        matrix.testingResetManualHaplotypeBandInvalidations()

        controller.testingSaveManualHaplotypeDraft()

        XCTAssertNil(controller.testingManualHaplotypeEditorPersistenceError)
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandValues(
                sample: "AnimalA"
            ).first,
            "—"
        )
        XCTAssertEqual(
            matrix.testingManualHaplotypeBandInvalidatedSamples,
            ["AnimalA"]
        )
        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertEqual(controller.testingMatrixPartialReloadCount, 0)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertEqual(annotationSidecarChangedCount, 1)

        let persisted = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: bundleURL.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            ))
        )
        XCTAssertTrue(persisted.manualHaplotypeAssignments.isEmpty)
        XCTAssertEqual(
            persisted.auditLog.filter {
                $0.action == "replaceManualHaplotypeAssignments"
            }.count,
            1
        )
    }


    func testManualHaplotypeCancelVetoesSelectionSearchVisibilityLensAndReload() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeCancelTransitions-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let calls = [
            makeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            ),
            makeCall(
                sample: "AnimalB",
                genotype: "01_Mafa_A1_001_01",
                reads: 21
            ),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in .cancel
        }
        let originalSelection =
            controller.testingCurrentSelectionMatrixTargets
        let originalSamples = controller.testingVisibleMatrixSamples

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        await controller.testingWaitForManualHaplotypeTransitions()
        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )

        controller.testingSetComparisonFilter("AnimalB")
        await controller.testingWaitForManualHaplotypeTransitions()
        XCTAssertEqual(
            controller.testingVisibleMatrixSamples,
            originalSamples
        )

        controller.testingHideSelectedMatrixColumns()
        await controller.testingWaitForManualHaplotypeTransitions()
        XCTAssertEqual(
            controller.testingVisibleMatrixSamples,
            originalSamples
        )

        controller.testingSelectLens(.audit)
        await controller.testingWaitForManualHaplotypeTransitions()
        XCTAssertEqual(
            controller.testingVisibleLensIdentifier,
            "summary"
        )

        controller.testingReloadCurrentWorkbookResult()
        await controller.testingWaitForManualHaplotypeTransitions()
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "AnimalA"
        )
    }


    func testManualHaplotypePromptCoalescesMixedMutationsToLatestConfiguration()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ManualHaplotypeCoalescing-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let originalBundle = root.appendingPathComponent(
            "original.lungfishgenotype",
            isDirectory: true
        )
        let replacementBundle = root.appendingPathComponent(
            "replacement.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalBundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementBundle,
            withIntermediateDirectories: true
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: originalBundle,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: "01_Mafa_A1_002_01",
                    reads: 21
                ),
            ]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        let gate = ManualHaplotypeViewportDecisionGate()
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in await gate.wait()
        }

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        await gate.waitUntilPending()
        for index in 0..<100 {
            controller.testingSetComparisonFilter(
                index == 99 ? "AnimalB" : "queued-\(index)"
            )
        }
        controller.configure(result: makeResult(
            bundleURL: replacementBundle,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalC",
                    genotype: "01_Mafa_A1_003_01",
                    reads: 7
                ),
            ]
        ))

        XCTAssertEqual(
            controller.testingPendingManualHaplotypeMutationCount,
            1
        )
        await gate.resume(with: .discard)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingResultBundleURL,
            replacementBundle.standardizedFileURL
        )
        XCTAssertEqual(
            controller.testingPendingManualHaplotypeMutationCount,
            0
        )
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalC"])
    }


    func testPendingLensIntentIsSupersededByRequestForCurrentLens()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeLatestLens-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
            ]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        let gate = ManualHaplotypeViewportDecisionGate()
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in await gate.wait()
        }

        controller.testingSelectLens(.audit)
        await gate.waitUntilPending()
        controller.testingSelectLens(.summary)
        XCTAssertEqual(
            controller.testingPendingManualHaplotypeMutationCount,
            1
        )
        await gate.resume(with: .discard)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingVisibleLensIdentifier,
            "summary"
        )
        XCTAssertEqual(
            controller.testingPendingManualHaplotypeMutationCount,
            0
        )
    }


    func testDeferredMatrixClickReResolvesMissingRowAfterProjectionChanges()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ManualHaplotypeStaleRow-\(UUID().uuidString).lungfishgenotype",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        let firstGenotype = "01_Mafa_A1_001_01"
        let staleGenotype = "01_Mafa_A1_002_01"
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: firstGenotype,
                    reads: 42
                ),
                makeCall(
                    sample: "AnimalA",
                    genotype: staleGenotype,
                    reads: 21
                ),
            ]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        let gate = ManualHaplotypeViewportDecisionGate()
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in await gate.wait()
        }
        let originalSelection =
            controller.testingCurrentSelectionMatrixTargets

        controller.testingClickMatrixCell(
            genotype: staleGenotype,
            sample: "AnimalA"
        )
        await gate.waitUntilPending()
        controller.testingComparisonMatrix.applyFilters(
            allowedSampleIDs: nil,
            text: firstGenotype
        )
        await gate.resume(with: .discard)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )
        XCTAssertEqual(
            controller.testingVisibleMatrixGenotypes,
            [firstGenotype]
        )
    }


    func testDeferredNativeSelectionWithNoSurvivingRowsIsExactNoOp()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeStaleNative-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let first = "01_Mafa_A1_001_01"
        let disappearing = "01_Mafa_A1_002_01"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: first, reads: 42),
                makeCall(
                    sample: "AnimalA",
                    genotype: disappearing,
                    reads: 21
                ),
            ]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        let gate = ManualHaplotypeViewportDecisionGate()
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in await gate.wait()
        }
        let originalSelection =
            controller.testingCurrentSelectionMatrixTargets
        XCTAssertEqual(originalSelection, [.column(sample: "AnimalA")])

        controller.testingApplyNativeMatrixRowSelection(
            IndexSet(integer: 1)
        )
        await gate.waitUntilPending()
        controller.testingComparisonMatrix.applyFilters(
            allowedSampleIDs: nil,
            text: first
        )
        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )
        await gate.resume(with: .discard)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, [first])
    }


    func testDeferredNativeRowSelectionDropsPreferredSampleWhenItsColumnIsHidden()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeHiddenNativeSample-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let genotype = "01_Mafa_A1_001_01"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: genotype, reads: 42),
                makeCall(sample: "AnimalB", genotype: genotype, reads: 21),
            ]
        ))
        controller.testingSelectMatrixCell(
            genotype: genotype,
            sample: "AnimalA"
        )
        var deferredMutation: (@MainActor () -> Void)?
        controller.testingComparisonMatrix
            .onManualHaplotypeTransitionPreflight = { _, mutation in
                deferredMutation = mutation
                return true
            }

        controller.testingApplyNativeMatrixRowSelection(
            IndexSet(integer: 0)
        )
        XCTAssertNotNil(deferredMutation)
        controller.testingComparisonMatrix.applyFilters(
            allowedSampleIDs: ["AnimalB"],
            text: ""
        )
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
        try XCTUnwrap(deferredMutation)()

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            [.row(locus: "MHC-A", genotype: genotype)]
        )
        XCTAssertFalse(
            controller.testingCurrentSelectionDetailRows.contains {
                $0 == ("Sample", "AnimalA")
            }
        )
    }


    func testManualHaplotypeCancelRestoresNativeTableSelectionAndScroll() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeNativeSelection-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let calls = (0..<30).flatMap { index in
            [
                makeCall(
                    sample: "AnimalA",
                    genotype: String(format: "01_Mafa_A1_%03d_01", index),
                    reads: 42 + index
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: String(format: "01_Mafa_A1_%03d_01", index),
                    reads: 21 + index
                ),
            ]
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in .cancel
        }
        controller.testingSetMatrixContentScrollOrigins(
            pinned: NSPoint(x: 0, y: 180),
            samples: NSPoint(x: 35, y: 180)
        )
        let originalSelection =
            controller.testingCurrentSelectionMatrixTargets
        let originalScroll = controller.testingMatrixContentScrollOrigins

        controller.testingApplyNativeMatrixRowSelection(
            IndexSet(integer: 12)
        )
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )
        XCTAssertEqual(
            controller.testingNativeMatrixSelectedRowIndexes,
            []
        )
        XCTAssertEqual(
            controller.testingMatrixContentScrollOrigins,
            originalScroll
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "AnimalA"
        )

        controller.testingApplyNativeMatrixRowSelection([])
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )
        XCTAssertEqual(
            controller.testingMatrixContentScrollOrigins,
            originalScroll
        )
    }


    func testManualHaplotypeCancelRestoresNativeSearchFieldTextAndCaret() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeNativeSearch-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let controller = GenotypeResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 42
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: "01_Mafa_A1_001_01",
                    reads: 21
                ),
            ]
        ))
        XCTAssertTrue(
            controller.testingPerformNativeComparisonFilterAction(
                text: "Animal",
                selectedRange: NSRange(location: 2, length: 0),
                in: window
            )
        )
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in .cancel
        }

        XCTAssertTrue(
            controller.testingPerformNativeComparisonFilterAction(
                text: "AnimalB",
                selectedRange: NSRange(location: 7, length: 0),
                in: window
            )
        )
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingComparisonFilterModelText,
            "Animal"
        )
        XCTAssertEqual(
            controller.testingComparisonFilterNativeText,
            "Animal"
        )
        XCTAssertEqual(
            controller.testingComparisonFilterNativeSelectedRange,
            NSRange(location: 2, length: 0)
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "AnimalA"
        )
    }


    func testManualHaplotypeCancelRestoresPreAppKitAutoScrollSelectionSnapshot()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypePreAutoScroll-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let calls = (0..<40).flatMap { index in
            [
                makeCall(
                    sample: "AnimalA",
                    genotype: String(format: "01_Mafa_A1_%03d_01", index),
                    reads: 42 + index
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: String(format: "01_Mafa_A1_%03d_01", index),
                    reads: 21 + index
                ),
            ]
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            _ in .cancel
        }
        let originalScroll = GenotypeMatrixContentScrollOrigins(
            pinned: NSPoint(x: 0, y: 160),
            samples: NSPoint(x: 31, y: 160)
        )
        let appKitAutoScroll = GenotypeMatrixContentScrollOrigins(
            pinned: NSPoint(x: 0, y: 610),
            samples: NSPoint(x: 31, y: 610)
        )
        controller.testingSetMatrixContentScrollOrigins(
            pinned: originalScroll.pinned,
            samples: originalScroll.samples
        )
        let originalTargets =
            controller.testingCurrentSelectionMatrixTargets

        controller.testingApplyNativeMatrixRowSelection(
            IndexSet(integer: 30),
            simulatedAppKitScrollOrigins: appKitAutoScroll
        )
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalTargets
        )
        XCTAssertEqual(
            controller.testingNativeMatrixSelectedRowIndexes,
            []
        )
        XCTAssertEqual(
            controller.testingMatrixContentScrollOrigins,
            originalScroll
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
    }


    func testManualHaplotypeTransitionWithNoDecisionProviderResolvesAsCancelWithoutPresentingAlert()
        async throws
    {
        // Regression for the swift-test deadlock: a dirty draft + a
        // transition + NO installed decision provider used to fall through
        // to a real blocking NSAlert (`presentManualHaplotypeDraftDecision`)
        // which froze the whole suite under `swift test`. This proves the
        // under-XCTest guard resolves the transition (as .cancel) instead of
        // presenting UI, without ever calling
        // testingSetManualHaplotypeDraftDecisionProvider.
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualHaplotypeNoProviderTransitions-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let calls = [
            makeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            ),
            makeCall(
                sample: "AnimalB",
                genotype: "01_Mafa_A1_001_01",
                reads: 21
            ),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        let originalSelection =
            controller.testingCurrentSelectionMatrixTargets

        // No testingSetManualHaplotypeDraftDecisionProvider call here: this
        // exercises the real presentManualHaplotypeDraftDecision fallback.
        controller.testingSelectMatrixColumn(sample: "AnimalB")
        await controller.testingWaitForManualHaplotypeTransitions()

        // A .cancel resolution vetoes the transition, exactly like the
        // explicit-provider .cancel case above.
        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            originalSelection
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
    }

}
