import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Selection details, sample comparison, and typography
@MainActor
final class GenotypeResultViewportSelectionAndComparisonTests: GenotypeResultViewportTestCase {
    func testSelectedMultipleRowsShowEveryAlleleAggregateAndGenBankValue() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73),
            makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41),
        ]
        controller.configure(result: makeResult(
            samples: [], calls: calls, referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222", "NHP99999"], sample: nil)

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Alleles: 2"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(text.contains("Mafa-B*002:01"))
        XCTAssertTrue(text.contains("73"))
        XCTAssertTrue(text.contains("41"))
        XCTAssertTrue(text.contains("MHC class I A1 antigen"))
        XCTAssertTrue(text.contains("MHC class I B antigen"))
    }


    func testSelectedSupportedCellPublishesAlleleContextWithoutEvidenceMetrics() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP01222", passedAlignments: 91, passedUniqueReads: 73,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 100, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 91, passedUniqueReads: 73,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]
            )],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Sample", "AnimalA") })
        XCTAssertTrue(rows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(rows.contains { $0 == ("Reference Sequence", "NHP01222") })
        XCTAssertTrue(rows.contains { $0 == ("Product", "MHC class I A1 antigen") })
        XCTAssertFalse(rows.contains { ["Unique Reads", "Alignments", "Support", "Support Metric"].contains($0.0) })
    }


    func testSelectedEmptyCellShowsNoSupportingReadsWithoutZeroCounts() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]),
                ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: []),
            ],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalB")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Evidence", "No supporting reads") })
        XCTAssertFalse(rows.contains { ["Unique Reads", "Alignments", "Support", "Selected Unique", "Selected Support"].contains($0.0) })
    }


    func testSelectedMultipleCellsShowEveryAlleleSamplePairAndExactEvidence() {
        let first = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let second = makeCall(sample: "AnimalB", genotype: "NHP99999", reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [first, second], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        let targets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .cell(locus: "MHC-NHP01222", genotype: "NHP01222", sample: "AnimalA"),
            .cell(locus: "MHC-NHP99999", genotype: "NHP99999", sample: "AnimalA"),
            .cell(locus: "MHC-NHP99999", genotype: "NHP99999", sample: "AnimalB"),
        ]
        controller.testingShowMatrixTargetSelection(targets)

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set(targets))
        let rows = controller.testingCurrentSelectionDetailRows
        let entries = rows.split { $0.0.hasPrefix("Cell ") }
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-A1*001:01") }
                && entry.contains { $0 == ("Sample", "AnimalA") }
                && entry.contains { $0 == ("Unique Reads", "73") }
        })
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-B*002:01") }
                && entry.contains { $0 == ("Sample", "AnimalA") }
                && entry.contains { $0 == ("Evidence", "No supporting reads") }
        })
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-B*002:01") }
                && entry.contains { $0 == ("Sample", "AnimalB") }
                && entry.contains { $0 == ("Unique Reads", "41") }
        })
    }


    func testSelectedGenBankRowPublishesFullAlleleTitle() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

        XCTAssertEqual(try XCTUnwrap(selection).title, "Mafa-A1*001:01")
        XCTAssertEqual(try XCTUnwrap(selection).highlightTarget?.genotype, "NHP01222")
    }


    func testSelectedMultipleColumnsShowCompactSummaryForEachSample() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeMultiSampleSelection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]),
                ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: []),
            ],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalB"])
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Selected cohort note"
        ))

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Samples"))
        XCTAssertTrue(text.contains("AnimalA"))
        XCTAssertTrue(text.contains("AnimalB"))
        XCTAssertFalse(text.contains("Supported Alleles"))
        XCTAssertFalse(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample 1", "AnimalA") })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample 2", "AnimalB") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0.hasPrefix("Allele ") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Support" })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Column Comment", "Selected cohort note")
        })
    }


    func testSelectedMultipleColumnsShowBoundedCanonicalManualHaplotypeSummariesWithoutEditor()
        throws
    {
        let root = try TestTempDirectory.make(prefix: "GenotypeMultiSampleHaplotypeSummary")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
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
                locus: "MHC-A",
                slot: .h1,
                label: "Alpha",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: "Superseded",
                colorTokenIndex: 2,
                diagnosticAlleles: [],
                notes: "",
                assignmentID: "superseded",
                updatedAt: "2026-07-26T00:00:00Z",
                author: "Analyst"
            ),
            ManualHaplotypeAssignment(
                sample: "AnimalA",
                locus: "MHC-A",
                slot: .h1,
                label: "Alpha",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: "",
                assignmentID: "current",
                updatedAt: "2026-07-27T00:00:00Z",
                author: "Analyst"
            ),
            ManualHaplotypeAssignment(
                sample: "AnimalB",
                locus: "MHC-B",
                slot: .h2,
                label: "Beta",
                colorTokenIndex: 3,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let calls = [
            makeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                reads: 42
            ),
            makeCall(
                sample: "AnimalB",
                genotype: "01_Mafa_B_001_01",
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

        controller.testingSelectMatrixColumns(
            samples: ["AnimalA", "AnimalB"]
        )

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains {
            $0 == ("AnimalA Haplotype Completeness", "1 of 14 assigned")
        })
        XCTAssertTrue(rows.contains {
            $0 == ("AnimalA Haplotype Labels", "Alpha")
        })
        XCTAssertTrue(rows.contains {
            $0 == ("AnimalB Haplotype Completeness", "1 of 14 assigned")
        })
        XCTAssertTrue(rows.contains {
            $0 == ("AnimalB Haplotype Labels", "Beta")
        })
        XCTAssertFalse(rows.contains { $0.1.contains("Superseded") })
        XCTAssertNil(controller.testingManualHaplotypeEditorSample)
        XCTAssertLessThanOrEqual(
            rows.filter { $0.0.contains("Haplotype") }.count,
            24
        )
    }


    func testSelectedCellIncludesApplicableRowColumnAndCellComments() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeSelectionComments")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call])],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Row note"))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Column note"))
        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Cell note"))

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Row Comment", "Row note") })
        XCTAssertTrue(rows.contains { $0 == ("Column Comment", "Column note") })
        XCTAssertTrue(rows.contains { $0 == ("Cell Comment", "Cell note") })
    }


    func testKnownRowAndSupportedCellShowApplicableCommentsWithoutStaleViewsOrEvidence() throws {
        let root = try TestTempDirectory.make(prefix: "KnownAlleleComments")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let firstID = "NHP01222"
        let secondID = "NHP99999"
        let first = makeCall(sample: "AnimalA", genotype: firstID, reads: 73)
        let second = makeCall(sample: "AnimalA", genotype: secondID, reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 114, passedUniqueReads: 114,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [first, second]
            )],
            calls: [first, second],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeMHCReferenceVisualizationRecord(rawReferenceID: firstID, alleleName: "Mafa-A1*001:01"),
                    makeMHCReferenceVisualizationRecord(rawReferenceID: secondID, alleleName: "Mafa-B*002:01"),
                ]
            )
        ))

        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "First row note"
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Animal column note"
        ))
        controller.testingSelectMatrixCell(genotype: firstID, sample: "AnimalA")
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "First cell note"
        ))

        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)

        let rowDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let rowText = visibleText(in: rowDetail)
        XCTAssertTrue(rowText.contains("Row Comment"))
        XCTAssertTrue(rowText.contains("First row note"))
        XCTAssertFalse(rowText.contains("Animal column note"))
        XCTAssertFalse(rowText.contains("First cell note"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Row Comment", "First row note")
        })
        assertNoKnownAggregateEvidence(in: rowText)

        controller.testingSelectMatrixCell(genotype: firstID, sample: "AnimalA")

        let cellDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(rowDetail === cellDetail)
        let cellText = visibleText(in: cellDetail)
        for text in [
            "Row Comment", "First row note",
            "Column Comment", "Animal column note",
            "Cell Comment", "First cell note",
        ] {
            XCTAssertTrue(cellText.contains(text), text)
        }
        for row in [
            ("Row Comment", "First row note"),
            ("Column Comment", "Animal column note"),
            ("Cell Comment", "First cell note"),
        ] {
            XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == row })
        }
        assertNoKnownAggregateEvidence(in: cellText)
        let cellDescendantCount = descendants(of: cellDetail).count

        controller.testingSelectMatrixRows(genotypes: [secondID], sample: nil)
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Second row note"
        ))

        let replacementDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(cellDetail === replacementDetail)
        let replacementText = visibleText(in: replacementDetail)
        XCTAssertTrue(replacementText.contains("Second row note"))
        XCTAssertFalse(replacementText.contains("First row note"))
        XCTAssertFalse(replacementText.contains("Animal column note"))
        XCTAssertFalse(replacementText.contains("First cell note"))
        XCTAssertEqual(descendants(of: replacementDetail).filter {
            $0.accessibilityIdentifier().hasPrefix("knownAlleleCommentRow.")
        }.count, 1)
        XCTAssertLessThan(descendants(of: replacementDetail).count, cellDescendantCount)
        assertNoKnownAggregateEvidence(in: replacementText)
    }


    func testMixedMatrixTargetsUseGenericMixedSummary() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)]
        ))

        controller.testingShowMatrixTargetSelection([
            .row(locus: "NHP01222", genotype: "NHP01222"),
            .column(sample: "AnimalA"),
        ])

        XCTAssertTrue(controller.testingDetailText.contains("Matrix Annotation Targets"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Selection Type", "Mixed") })
    }


    func testGeneratedDetailTypographyUpdatesWithoutRebuildingSelectionOrChangingState() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        controller.configure(result: makeResult(
            samples: [], calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)]
        ))
        var displayStateChanges = 0
        controller.onDisplayStateChanged = { _ in displayStateChanges += 1 }
        controller.testingShowMatrixTargetSelection(
            [.row(locus: "NHP01222", genotype: "NHP01222")]
                + (0..<30).map { .column(sample: "Animal\($0)") }
        )
        controller.view.layoutSubtreeIfNeeded()
        controller.testingSetDetailScrollOriginY(7)
        let baselineFont = controller.testingGeneratedDetailLargestFontPointSize
        let baselineText = controller.testingDetailText
        let baselineSubviewCount = controller.testingDetailArrangedSubviewCount
        let baselineBuildCount = controller.testingLegacyNonRowDetailBuildCount
        let baselineRows = controller.testingCurrentSelectionDetailRows.map { "\($0.0)\u{1F}\($0.1)" }

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            controller.testingGeneratedDetailLargestFontPointSize,
            baselineFont * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(controller.testingDetailText, baselineText)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, baselineSubviewCount)
        XCTAssertEqual(controller.testingLegacyNonRowDetailBuildCount, baselineBuildCount)
        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.map { "\($0.0)\u{1F}\($0.1)" },
            baselineRows
        )
        XCTAssertTrue(controller.testingGeneratedDetailFieldsAllowWrapping)
        XCTAssertEqual(controller.testingDetailScrollOriginY, 7, accuracy: 0.01)
        XCTAssertEqual(displayStateChanges, 0)

        settings.contentTextSizePreference = .custom(100)
        settings.save()

        XCTAssertEqual(
            controller.testingGeneratedDetailLargestFontPointSize,
            baselineFont,
            accuracy: 0.01
        )
        XCTAssertEqual(controller.testingLegacyNonRowDetailBuildCount, baselineBuildCount)
        XCTAssertEqual(controller.testingDetailScrollOriginY, 7, accuracy: 0.01)
        XCTAssertEqual(displayStateChanges, 0)
    }


    func testLateGeneratedContentRebuildsUseCurrentTypographyWithoutTypographySideEffects() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(200)
        settings.save()
        let root = try TestTempDirectory.make(prefix: "LateGeneratedTypography")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_LATE_TYPOGRAPHY"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Late Typography Definitions",
            speciesName: "Test species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalA",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: [genotype]
                        ),
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 17)],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingShowMatrixTargetSelection([target])

        var displayCallbacks = 0
        var annotationCallbacks = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onDisplayStateChanged = { _ in displayCallbacks += 1 }
        controller.onAnnotationSidecarChanged = { _ in annotationCallbacks += 1 }
        controller.onCurrentWorkbookSyncRequested = { workbookActions.append($0.action) }

        controller.applySampleMetadataStore(nil)
        controller.testingApplyDisplayState(controller.testingDisplayState)
        controller.testingSelectLens(.review)
        controller.testingSelectLens(.audit)
        controller.applyAIHaplotypingFailed(NSError(domain: "TypographyTest", code: 1))
        controller.editMatrixComment(.init(
            targets: [target],
            intent: .upsert(body: "Late typography annotation")
        ))

        let enlargedSnapshots = GenotypeGeneratedContentSurface.allCases.map {
            controller.testingGeneratedContentSnapshot($0)
        }
        XCTAssertTrue(enlargedSnapshots.allSatisfy { !$0.fontPointSizes.isEmpty })
        XCTAssertTrue(enlargedSnapshots.allSatisfy {
            $0.fontPointSizes.allSatisfy { $0 >= 20 }
                && $0.allFieldsAllowWrapping
        })
        XCTAssertEqual(displayCallbacks, 0)
        XCTAssertEqual(annotationCallbacks, 1)
        XCTAssertEqual(workbookActions, [.markDirty])
        XCTAssertNil(controller.testingCurrentCallEvidenceSample)

        for surface in GenotypeGeneratedContentSurface.allCases {
            controller.testingSetGeneratedContentScrollOriginY(7, surface: surface)
        }
        let stableEnlargedSnapshots = GenotypeGeneratedContentSurface.allCases.map {
            controller.testingGeneratedContentSnapshot($0)
        }
        let rebuildCounts = controller.testingGeneratedContentRebuildCounts
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(
            GenotypeGeneratedContentSurface.allCases.map {
                controller.testingGeneratedContentSnapshot($0)
            },
            stableEnlargedSnapshots
        )
        XCTAssertEqual(controller.testingGeneratedContentRebuildCounts.haplotype, rebuildCounts.haplotype)
        XCTAssertEqual(controller.testingGeneratedContentRebuildCounts.consumer, rebuildCounts.consumer)
        XCTAssertEqual(controller.testingGeneratedContentRebuildCounts.anchor, rebuildCounts.anchor)
        XCTAssertEqual(controller.testingGeneratedContentRebuildCounts.artifact, rebuildCounts.artifact)
        XCTAssertEqual(displayCallbacks, 0)
        XCTAssertEqual(annotationCallbacks, 1)
        XCTAssertEqual(workbookActions, [.markDirty])

        settings.contentTextSizePreference = .system
        settings.save()
        controller.applySampleMetadataStore(nil)
        controller.testingApplyDisplayState(controller.testingDisplayState)
        controller.testingSelectLens(.review)
        controller.testingSelectLens(.audit)
        controller.applyAIHaplotypingFailed(NSError(domain: "TypographyTest", code: 2))
        controller.editMatrixComment(.init(
            targets: [target],
            intent: .upsert(body: "System typography annotation")
        ))
        let systemSnapshots = GenotypeGeneratedContentSurface.allCases.map {
            controller.testingGeneratedContentSnapshot($0)
        }
        XCTAssertTrue(systemSnapshots.allSatisfy { !$0.fontPointSizes.isEmpty })
        XCTAssertTrue(systemSnapshots.allSatisfy {
            $0.fontPointSizes.allSatisfy { $0 >= 10 && $0 < 20 }
                && $0.allFieldsAllowWrapping
        })
        XCTAssertEqual(displayCallbacks, 0)
        XCTAssertEqual(annotationCallbacks, 2)
        XCTAssertEqual(workbookActions, [.markDirty, .markDirty])
        XCTAssertNil(controller.testingCurrentCallEvidenceSample)
    }


    func testComparisonMatrixTypographyUpdatesInPlaceAndRecoversWithoutChangingViewState() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()

        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 240)
        matrix.layoutSubtreeIfNeeded()
        let genotype = try! XCTUnwrap(matrix.testingVisibleGenotypes.first)
        matrix.testingSelectCell(genotype: genotype, sample: "Sample0")
        matrix.testingSetFilter("Mafa-AG")
        matrix.testingResetReloadCounters()

        let identity = ObjectIdentifier(matrix)
        let baselineCellFont = matrix.testingMatrixCellFontPointSize
        let baselineHeaderFont = matrix.testingMatrixHeaderFontPointSize
        let baselineRowHeight = matrix.testingMatrixRowHeight
        let baselineHeaderHeight = matrix.testingMatrixHeaderHeight
        let baselineWidths = matrix.testingAllColumnWidths
        let baselineRows = matrix.testingVisibleGenotypes
        matrix.testingSetContentScrollOrigins(
            pinned: NSPoint(x: 0, y: baselineRowHeight * 2 + 5),
            samples: NSPoint(x: 19, y: baselineRowHeight * 2 + 5)
        )
        let baselineScrollAnchors = matrix.testingContentScrollAnchors

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(ObjectIdentifier(matrix), identity)
        XCTAssertEqual(matrix.testingMatrixCellFontPointSize, baselineCellFont * 2, accuracy: 0.01)
        XCTAssertEqual(matrix.testingMatrixHeaderFontPointSize, baselineHeaderFont * 2, accuracy: 0.01)
        XCTAssertGreaterThan(matrix.testingMatrixRowHeight, baselineRowHeight)
        XCTAssertGreaterThan(matrix.testingMatrixHeaderHeight, baselineHeaderHeight)
        XCTAssertTrue(
            zip(matrix.testingAllColumnWidths, baselineWidths).allSatisfy { $0 > $1 },
            "\(matrix.testingAllColumnWidths) should exceed \(baselineWidths)"
        )
        XCTAssertEqual(matrix.testingVisibleGenotypes, baselineRows)
        XCTAssertTrue(matrix.testingIsSelectedCell(genotype: genotype, sample: "Sample0"))
        XCTAssertTrue(matrix.testingSemanticDecorationFramesAreContained)
        XCTAssertEqual(matrix.testingContentScrollAnchors, baselineScrollAnchors)
        XCTAssertTrue(matrix.testingHeaderTextBandsFit)
        XCTAssertLessThanOrEqual(matrix.testingFullReloadCount, 2)

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(matrix.testingMatrixCellFontPointSize, baselineCellFont, accuracy: 0.01)
        XCTAssertEqual(matrix.testingMatrixHeaderFontPointSize, baselineHeaderFont, accuracy: 0.01)
        XCTAssertEqual(matrix.testingMatrixRowHeight, baselineRowHeight, accuracy: 0.01)
        XCTAssertEqual(matrix.testingMatrixHeaderHeight, baselineHeaderHeight, accuracy: 0.01)
        XCTAssertEqual(matrix.testingAllColumnWidths, baselineWidths)
        XCTAssertEqual(matrix.testingVisibleGenotypes, baselineRows)
        XCTAssertTrue(matrix.testingIsSelectedCell(genotype: genotype, sample: "Sample0"))
        XCTAssertEqual(matrix.testingContentScrollAnchors, baselineScrollAnchors)
        XCTAssertTrue(matrix.testingHeaderTextBandsFit)
        XCTAssertLessThanOrEqual(matrix.testingFullReloadCount, 4)

        let provider = MutableGenotypePreferredFonts(pointSize: 17)
        settings.contentTextSizePreference = .system
        settings.save()
        matrix.testingSetContentPreferredFontProvider(provider)
        matrix.layoutSubtreeIfNeeded()

        XCTAssertEqual(matrix.testingContentScrollAnchors, baselineScrollAnchors)
        XCTAssertTrue(matrix.testingHeaderTextBandsFit)
    }


    func testResultTableSampleFontUsesCanonicalBaselineAtCustomAndSystemSizes() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        let provider = MutableGenotypePreferredFonts(pointSize: 13)
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let table = GenotypeResultTableView()
        table.setContentPreferredFontProvider(provider)
        table.configure(rows: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 40,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ])

        XCTAssertEqual(try sampleCellFontPointSize(in: table), 13, accuracy: 0.01)

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        XCTAssertEqual(try sampleCellFontPointSize(in: table), 26, accuracy: 0.01)

        provider.pointSize = 17
        settings.contentTextSizePreference = .system
        settings.save()
        table.setContentPreferredFontProvider(provider)
        XCTAssertEqual(try sampleCellFontPointSize(in: table), 17, accuracy: 0.01)
    }


    func testComparisonMatrixSynchronizesVerticalScrollingFromEitherPanel() throws {
        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        XCTAssertEqual(matrix.testingSampleMatrixBottomChromeHeight, 0)
        let sampleScrollView = try XCTUnwrap(
            matrix.subviews.compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
        )
        sampleScrollView.setFrameSize(NSSize(width: 99, height: sampleScrollView.frame.height))
        sampleScrollView.tile()

        matrix.testingScrollSampleMatrix(to: NSPoint(x: 37, y: 88))

        XCTAssertEqual(matrix.testingPinnedVerticalScrollOffset, 88)
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)

        matrix.testingScrollPinnedPanel(toY: 132)

        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.y, 132)
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)
    }


    func testComparisonMatrixDisablesVerticalScrollElasticity() throws {
        let matrix = GenotypeComparisonMatrixView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = host
        host.addSubview(matrix)
        NSLayoutConstraint.activate([
            matrix.topAnchor.constraint(equalTo: host.topAnchor),
            matrix.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            matrix.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            matrix.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.layoutIfNeeded()
        matrix.layoutSubtreeIfNeeded()

        let scrollViews = matrix.subviews.compactMap { $0 as? NSScrollView }
        let pinnedScrollView = try XCTUnwrap(scrollViews.first { !$0.hasVerticalScroller })
        let sampleScrollView = try XCTUnwrap(scrollViews.first { $0.hasVerticalScroller })

        XCTAssertEqual(pinnedScrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(sampleScrollView.verticalScrollElasticity, .none)
    }


    func testComparisonMatrixClampsRawVerticalClipOrigins() throws {
        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()

        let scrollViews = matrix.subviews.compactMap { $0 as? NSScrollView }
        let pinnedScrollView = try XCTUnwrap(scrollViews.first { !$0.hasVerticalScroller })
        let sampleScrollView = try XCTUnwrap(scrollViews.first { $0.hasVerticalScroller })

        sampleScrollView.contentView.scroll(to: NSPoint(x: 37, y: -1_000))
        let sampleBounds = sampleScrollView.contentView.bounds
        XCTAssertEqual(
            sampleBounds.origin.y,
            sampleScrollView.contentView.constrainBoundsRect(sampleBounds).origin.y,
            accuracy: 0.001
        )
        XCTAssertEqual(sampleBounds.origin.x, 37, accuracy: 0.001)

        pinnedScrollView.contentView.scroll(to: NSPoint(x: 19, y: 9_999))
        let pinnedBounds = pinnedScrollView.contentView.bounds
        XCTAssertEqual(
            pinnedBounds.origin.y,
            pinnedScrollView.contentView.constrainBoundsRect(pinnedBounds).origin.y,
            accuracy: 0.001
        )
        XCTAssertEqual(pinnedBounds.origin.x, 19, accuracy: 0.001)
    }


    func testComparisonMatrixAlignsBottomRowsWhenSampleScrollerOccupiesBottomChrome() {
        let matrix = makeManyRowComparisonMatrix(sampleCount: 12)
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingConfigureSampleMatrixLegacyHorizontalScroller()

        XCTAssertGreaterThan(matrix.testingSampleMatrixBottomChromeHeight, 0)

        matrix.testingScrollSampleMatrixToBottom(x: 37)

        let finalRow = matrix.testingVisibleRows.count - 1
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)
        XCTAssertEqual(
            matrix.testingPinnedRowYInMatrix(row: finalRow),
            matrix.testingSampleMatrixRowYInMatrix(row: finalRow),
            accuracy: 0.001
        )
    }


    func testComparisonMatrixShowsEverySampleColumnByDefault() {
        let matrix = makeManySampleMatrix(sampleCount: 150)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
    }


    func testComparisonMatrixDoesNotShowSampleLimitBanner() {
        let matrix = makeManySampleMatrix(sampleCount: 150)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
        XCTAssertFalse(matrix.testingColumnWindowBannerVisible)
    }


    func testComparisonMatrixSmallCohortInstantiatesAllColumns() {
        let matrix = makeManySampleMatrix(sampleCount: 40)
        XCTAssertEqual(matrix.testingSampleColumnCount, 40)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
    }


    func testComparisonMatrixPinnedPaneCanResizeAndRemembersWidth() {
        let matrix = makeManySampleMatrix(sampleCount: 4)
        matrix.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        matrix.testingSetPinnedPaneWidth(430)
        XCTAssertEqual(matrix.testingPinnedPaneWidth, 430, accuracy: 1)

        let restored = makeManySampleMatrix(sampleCount: 4)
        restored.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        restored.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.testingPinnedPaneWidth, 430, accuracy: 1)
    }


    func testComparisonMatrixExportSeesEveryVisibleSample() {
        let matrix = makeManySampleMatrix(sampleCount: 150)

        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        // The full logical set is intact.
        XCTAssertEqual(matrix.testingActiveSampleNames.count, 150)
        XCTAssertEqual(matrix.testingVisibleSampleNames.count, 150)

        // Export must include every sample, not just the windowed 60.
        let snapshot = matrix.exportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            analysisName: "Example",
            lens: "summary.matrix"
        )
        XCTAssertEqual(snapshot.sampleNames.count, 150)
        XCTAssertTrue(snapshot.sampleNames.contains("SAMPLE_120"))
        // The single shared row records reads for all 150 samples.
        XCTAssertEqual(snapshot.rows.first?.sampleReads.count, 150)
    }


    func testControllerExportSnapshotIncludesSavedFilterContext() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeExportContext")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW474", genotype: "12_M3_B_075_01", reads: 119),
        ]
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 148,
                    passedUniqueReads: 148,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [calls[0]]
                ),
                ONTGenotypeSampleResult(
                    sample: "DW474",
                    passedAlignments: 119,
                    passedUniqueReads: 119,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [calls[1]]
                ),
            ],
            calls: calls,
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix))

        controller.testingSetUnifiedSampleFilter("DW472")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())

        XCTAssertEqual(snapshot.sampleNames, ["DW472"])
        XCTAssertEqual(snapshot.filters["activeSmartCohortName"], "Filter: DW472")
        XCTAssertEqual(snapshot.filters["activeSmartCohortScope"], "bundle")
        XCTAssertTrue(snapshot.filters["activeSmartCohortPredicate"]?.contains("DW472") ?? false)
    }


    func testControllerExportSnapshotUsesVisibleHaplotypeMatrixRows() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())

        XCTAssertEqual(snapshot.lens, "summary.matrix.haplotypeDefinitions")
        XCTAssertTrue(snapshot.sampleNames.contains("12_M3_B_075_01"))
        XCTAssertTrue(snapshot.rows.contains { $0.genotype == "M3B" && $0.locus == "DW472 MHC-B" })
        XCTAssertFalse(snapshot.rows.contains { $0.genotype == "12_M3_B_075_01" })
    }


    func testExportRevealTargetsExportedWorkbookFile() {
        let controller = GenotypeResultViewController()
        let outputURL = URL(fileURLWithPath: "/tmp/export.xlsx")
        let result = GenotypeViewportExportResult(
            outputURL: outputURL,
            provenanceURL: outputURL.appendingPathExtension("lungfish-provenance.json")
        )

        XCTAssertEqual(controller.testingFileViewerSelectionURLs(for: result), [outputURL])
    }


    func testDisplayStateCanMoveListRightAndTop() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTrailing))

        XCTAssertTrue(controller.testingSplitIsVertical)
        XCTAssertFalse(controller.testingFirstPaneIsMatrix)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    }


    func testTopLayoutSplitMinimumsLeaveUsableViewportContent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        let extents = controller.testingMinimumSplitExtents

        XCTAssertGreaterThanOrEqual(extents.leading, 128)
        XCTAssertGreaterThanOrEqual(extents.trailing, 100)
    }


    func testSplitMaxCoordinateReservesTrailingPaneAndDivider() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        let maxCoordinate = controller.testingConstrainedMaxSplitCoordinate(containerExtent: 600)

        XCTAssertEqual(
            maxCoordinate,
            600 - controller.testingSplitDividerThickness - controller.testingMinimumSplitExtents.trailing,
            accuracy: 0.5
        )
    }


    func testSupportThresholdFiltersRowsAndCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let high = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 990,
            passedUniqueReads: 990,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let low = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_002_01",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [high, low]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: true, minimumSupportPercent: 1.0))

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }


    func testMinimumReadsThresholdHidesRowsWhoseEverySupporterIsBelowThreshold() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let highRow = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_HIGH", reads: 6_000)
        let lowRow = makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_LOW", reads: 1_000)
        controller.configure(result: makeResult(samples: [], calls: [highRow, lowRow]))

        // With the filter off (default 0) both rows stay visible.
        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 0))
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_HIGH", "01_Mafa_A1_LOW"])

        // At 5,000 the low-support row drops because its only supporter has 1,000 reads.
        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 5_000))
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_HIGH"])
    }


    func testMinimumReadsThresholdKeepsRowWithAtLeastOneSupporterAboveThreshold() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        // One shared genotype supported by a strong sample and a weak sample.
        let strong = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SHARED", reads: 6_000)
        let weak = makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_SHARED", reads: 1_000)
        controller.configure(result: makeResult(samples: [], calls: [strong, weak]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 5_000))

        // The row survives because at least one supporter clears the threshold.
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_SHARED"])
    }


    func testFilteredSampleCellsCanHideManualRowHighlights() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let sharedGenotype = "01_Mafa_A1_001_01"
        let denominatorGenotype = "02_Mafa_A2_001_01"
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: sharedGenotype,
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalB",
                genotype: sharedGenotype,
                passedAlignments: 100,
                passedUniqueReads: 100,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 100,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: denominatorGenotype,
                passedAlignments: 995,
                passedUniqueReads: 995,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: GenotypeResultHighlightTarget(genotype: sharedGenotype, locus: "MHC-A"),
            scope: .selectedRow,
            channel: .fill,
            color: AnnotationColor(red: 0.9, green: 0.2, blue: 0.7, alpha: 1.0)
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            hideLowSupport: true,
            minimumSupportPercent: 1.0,
            hideFilteredHighlights: true
        ))

        XCTAssertNil(controller.testingBackgroundColor(genotype: sharedGenotype, sample: "AnimalA"))
        XCTAssertNotNil(controller.testingBackgroundColor(genotype: sharedGenotype, sample: "AnimalB"))
    }


    func testMatrixSearchMatchesImportedSampleMetadata() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\ttreated
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSetComparisonFilter("treated")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }


    func testUnifiedMatrixFilterAppliesGenotypeTextAsRowFilter() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "04_Mafa_B_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSetUnifiedSampleFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
    }


    func testQuickSearchTreatsGenotypeTextAsMatrixRowFilterWithoutSampleColumnNarrowing() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalB", genotype: "04_Mafa_B_001_01", reads: 42),
        ]
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))

        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set(["01_Mafa_A1_001_01", "04_Mafa_B_001_01"]))
        controller.testingSetUnifiedSampleFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingSetUnifiedSampleFilter("AnimalB")
        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
    }


    func testUnifiedMatrixFilterMatchesMetadataFieldQueries() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\ttreated
        AnimalB\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalB",
                genotype: "02_Mafa_A2_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: calls))

        controller.testingSetUnifiedSampleFilter("Cohort=treated")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }


    func testApplyingImportedSampleMetadataRefreshesExistingMatrixSearch() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSetComparisonFilter("treated")
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        let metadata = Data("""
        Sample\tCohort
        AnimalA\ttreated
        """.utf8)
        let store = try SampleMetadataStore(csvData: metadata, knownSampleIds: ["AnimalA"])
        controller.applySampleMetadataStore(store)

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }


    func testUnifiedSampleFilterMatchesImportedMetadataFieldsInOutline() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort\tAnimal Type
        AnimalA\ttreated\tcase
        AnimalB\tcontrol\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalA",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["A1"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalB",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["A2"]
                        )
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))

        controller.testingSetUnifiedSampleFilter("Cohort=treated")

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["AnimalA"])
    }


    func testSaveCurrentFilterPersistsMetadataSmartCohortWithAudit() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingSetUnifiedSampleFilter("Cohort=Kenyon20")

        try controller.testingSaveCurrentFilterAsSmartCohort()

        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        let saved = sidecar.smartCohorts.first { $0.name == "Filter: Cohort=Kenyon20" }
        XCTAssertEqual(saved?.predicate, .metadataFieldContains(field: "Cohort", value: "Kenyon20"))
        XCTAssertEqual(saved?.searchProjectionText, "Cohort=Kenyon20")
        XCTAssertTrue(sidecar.auditLog.contains { $0.action == "saveSmartCohort" && $0.after?.contains("Cohort=Kenyon20") == true })
    }


    func testSavedTextFilterRoundTripsAsMatrixRowFilter() throws {
        let bundleURL = try TestTempDirectory.make(prefix: "SavedTextFilter")
        defer { TestTempDirectory.cleanup(bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalA", genotype: "04_Mafa_B_001_01", reads: 42),
        ]
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingSetUnifiedSampleFilter("MHC-B")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
    }


    func testScopedSaveCurrentFilterOnlyMutatesMatchingWindow() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(root) }
        let bundleA = root.appendingPathComponent("a.lungfishgenotype", isDirectory: true)
        let bundleB = root.appendingPathComponent("b.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)
        let scopeA = WindowStateScope()
        let scopeB = WindowStateScope()
        let controllerA = GenotypeResultViewController()
        let controllerB = GenotypeResultViewController()
        controllerA.windowStateScope = scopeA
        controllerB.windowStateScope = scopeB
        _ = controllerA.view
        _ = controllerB.view
        controllerA.configure(result: makeResult(
            bundleURL: bundleA,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controllerB.configure(result: makeResult(
            bundleURL: bundleB,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controllerA.testingSetUnifiedSampleFilter("Cohort=Kenyon20")
        controllerB.testingSetUnifiedSampleFilter("Cohort=Control")

        NotificationCenter.default.post(
            name: .genotypeResultSmartCohortSaveRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: scopeA]
        )

        let sidecarA = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleA)
        let sidecarB = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleB)
        XCTAssertTrue(sidecarA.smartCohorts.contains { $0.name == "Filter: Cohort=Kenyon20" })
        XCTAssertFalse(sidecarB.smartCohorts.contains { $0.name == "Filter: Cohort=Control" })
    }


    func testOutlineLayoutLeavesViewportVisibleBelowQuickFilterBar() throws {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_500, height: 900)
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .outline, layout: .listTop))

        controller.view.layoutSubtreeIfNeeded()

        let quickFilterBar = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeQuickFilterBarView.self))
        let outlineView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeOutlineView.self))
        XCTAssertLessThanOrEqual(quickFilterBar.frame.height, 72)
        XCTAssertGreaterThan(outlineView.frame.height, 200)
    }


    func testMatrixViewShowsDiagnosticGenotypesUsedForHaplotypeDefinitions() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 123),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M2B",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_098_05", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04", "12_M2_B_150_01_01", "12_M2_B_162"],
                                    observedDiagnosticAlleles: ["12_M2_B_019_03"]
                                ),
                            ],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["12_M2_B_019_03", "12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let text = controller.testingHaplotypeMatrixText

        XCTAssertTrue(text.contains("Diagnostic allele matrix"))
        XCTAssertTrue(text.contains("DW472"))
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        XCTAssertTrue(text.contains("12_M3_B_098_05 [not observed]"))
        XCTAssertTrue(text.contains("M2B"))
        XCTAssertTrue(text.contains("12_M2_B_019_03"))
    }


    func testWeakHaplotypeSlotIsTintedBelowFivePercent() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 3),
        ]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertTrue(slot.h2.testingIsWeakSupport)
    }


    func testWeakHaplotypeTintUsesSameColorAtHalfOpacity() throws {
        let view = GenotypeHaplotypeTapeView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.appearance = NSAppearance(named: .aqua)
        let tokenIndex = HaplotypeColorToken.assigned(forName: "M2B").canonicalIndex
        let referenceColor = try XCTUnwrap(
            view.testingFillColor(for: .reference(tokenIndex: tokenIndex, label: "M2B"))?.testingSRGBComponents
        )
        let weakColor = try XCTUnwrap(
            view.testingFillColor(for: .weakReference(tokenIndex: tokenIndex, label: "M2B"))?.testingSRGBComponents
        )

        XCTAssertEqual(weakColor.red, referenceColor.red, accuracy: 0.001)
        XCTAssertEqual(weakColor.green, referenceColor.green, accuracy: 0.001)
        XCTAssertEqual(weakColor.blue, referenceColor.blue, accuracy: 0.001)
        XCTAssertEqual(weakColor.alpha, 0.5, accuracy: 0.001)
    }


    func testWeakHaplotypeSlotIsTintedBelowFiveReads() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 20),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 4),
        ]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertTrue(slot.h2.testingIsWeakSupport)
    }


    func testManualHaplotypeSlotRestoresFullOpacity() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeResultWeakSupport")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-23T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h2,
                originalCall: "M2B",
                overrideCall: "M2B",
                reasonTag: .analystJudgment,
                rationale: "Manual review accepted the low-read call.",
                author: "test",
                timestamp: "2026-06-23T00:00:01Z"
            )
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 3),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertFalse(slot.h2.testingIsWeakSupport)
    }


    func testObservedOnlyLociDoesNotActivateMatrixView() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "04_M3_AG_04g1_156bp", reads: 100),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            layout: .listTop,
            showsAncillaryLoci: true
        ))

        let haplotypeMatrix = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        let sharedMatrix = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeComparisonMatrixView.self))

        XCTAssertTrue(haplotypeMatrix.isHidden)
        XCTAssertTrue(sharedMatrix.isHidden)
        XCTAssertTrue(controller.testingVisibleOutlineSamples.contains("DW472"))
    }


    func testHaplotypeDefinitionMatrixHeadersExposeSortDescriptors() throws {
        let view = GenotypeHaplotypeDefinitionMatrixView()
        view.configure(rows: [
            GenotypeHaplotypeDefinitionMatrixView.Row(
                sample: "DW472",
                locus: "MHC-B",
                callName: "M3B",
                haplotypeName: "M3B",
                observedCount: 2,
                diagnosticCount: 3,
                minimumMatches: 2,
                status: .called,
                alleles: [GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(name: "12_M3_B_075_01", reads: 100)]
            ),
            GenotypeHaplotypeDefinitionMatrixView.Row(
                sample: "DW472",
                locus: "MHC-A",
                callName: "M1A",
                haplotypeName: "M1A",
                observedCount: 1,
                diagnosticCount: 4,
                minimumMatches: 2,
                status: .candidate,
                alleles: [GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(name: "01_M1_F_01_w_06", reads: 30)]
            ),
        ], definitionName: "Test")

        let table = try XCTUnwrap(view.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })
    }


    func testHaplotypeDefinitionMatrixTypographyUpdatesAndRecoversWithoutReconfiguration() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let view = GenotypeHaplotypeDefinitionMatrixView()
        view.configure(rows: (0..<12).map { index in
            .init(
                sample: "DW\(index)",
                locus: "MHC-B",
                callName: "M3B",
                haplotypeName: "M3B",
                observedCount: 2,
                diagnosticCount: 3,
                minimumMatches: 2,
                status: .called,
                alleles: [.init(name: "12_M3_B_075_01", reads: 100)]
            )
        }, definitionName: "Test")
        let baselineFont = view.testingCellFontPointSize
        let baselineRowHeight = view.testingRowHeight
        let baselineWidths = view.testingColumnWidths
        let configurationCount = view.testingConfigurationCount
        view.testingSetContentScrollOrigin(NSPoint(x: 21, y: baselineRowHeight * 3 + 4))
        let baselineScrollAnchor = view.testingContentScrollAnchor

        settings.contentTextSizePreference = .custom(200)
        settings.save()

        XCTAssertEqual(view.testingCellFontPointSize, baselineFont * 2, accuracy: 0.01)
        XCTAssertGreaterThan(view.testingRowHeight, baselineRowHeight)
        XCTAssertTrue(zip(view.testingColumnWidths, baselineWidths).allSatisfy { $0 > $1 })
        XCTAssertEqual(view.testingConfigurationCount, configurationCount)
        XCTAssertEqual(view.testingContentScrollAnchor, baselineScrollAnchor)

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        XCTAssertEqual(view.testingCellFontPointSize, baselineFont, accuracy: 0.01)
        XCTAssertEqual(view.testingRowHeight, baselineRowHeight, accuracy: 0.01)
        XCTAssertEqual(view.testingColumnWidths, baselineWidths)
        XCTAssertEqual(view.testingConfigurationCount, configurationCount)
        XCTAssertEqual(view.testingContentScrollAnchor, baselineScrollAnchor)
    }


    func testHaplotypeMatrixSearchFiltersDefinitionRowsRatherThanWholeSamples() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: ["01_M1_F_01_w_06"],
                                    observedDiagnosticAlleles: ["01_M1_F_01_w_06"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        controller.testingSetUnifiedSampleFilter("MHC-B")

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertFalse(matrixView.isHidden)
    }


    func testHaplotypeMatrixUsesSavedTextFilterWhenQuickSearchIsCleared() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeSavedMatrixFilter")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: ["01_M1_F_01_w_06"],
                                    observedDiagnosticAlleles: ["01_M1_F_01_w_06"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        controller.testingSetUnifiedSampleFilter("MHC-B")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertFalse(matrixView.isHidden)
    }


    func testHaplotypeDefinitionMatrixUsesSharedSearchIndexAndRefreshesRenderedRowsLive() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeHaplotypeSharedSearch")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        let metadataURL = bundleURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("sample_metadata.tsv")
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        Sample\tCohort
        M3B\tcontrol
        Carrier\tspecial-group
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        let calls = [
            makeCall(sample: "M3B", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "Carrier", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "Carrier", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "Carrier", genotype: "12_M2_B_019_03", reads: 90),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "M3B",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "Carrier",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M2B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "12_M3_B_075_01",
                                "12_M3_B_165_01",
                                "12_M2_B_019_03",
                            ]
                        ),
                    ]
                ),
            ]
        )
        let alleleField = GenBankRecordDatabase.FieldDefinition(
            key: "feature.allele.cross-lens",
            displayTitle: "Allele",
            valueType: "text",
            sourceCategory: "feature",
            preferredOrder: 0
        )
        let referenceMetadata = ONTGenotypeReferenceMetadata(
            fields: [alleleField],
            recordsBySequenceName: [
                "12_M3_B_075_01": [
                    alleleField.key: "Mafa-A1*007:01",
                ],
            ],
            alleleFieldKey: alleleField.key
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis,
            referenceMetadata: referenceMetadata
        ))
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop)
        )
        let matrix = try XCTUnwrap(
            controller.view.firstDescendant(
                ofType: GenotypeHaplotypeDefinitionMatrixView.self
            )
        )
        XCTAssertFalse(matrix.isHidden)
        controller.testingResetSearchPerformanceCounters()

        controller.testingSetQuickFilterSearchText("M3B")
        XCTAssertEqual(Set(matrix.testingRenderedRows.map(\.sample)), ["M3B"])

        controller.testingSetQuickFilterSearchText("12_M3_B_075_01")
        XCTAssertEqual(Set(matrix.testingRenderedRows.map(\.sample)), ["Carrier"])

        controller.testingSetQuickFilterSearchText("M2B")
        XCTAssertEqual(Set(matrix.testingRenderedRows.map(\.sample)), ["Carrier"])

        controller.testingSetQuickFilterSearchText("special-group")
        XCTAssertEqual(Set(matrix.testingRenderedRows.map(\.sample)), ["Carrier"])

        controller.testingSetQuickFilterSearchText("does-not-match")
        XCTAssertTrue(matrix.testingRenderedRows.isEmpty)

        controller.testingSetQuickFilterSearchText("A1*007")
        XCTAssertEqual(Set(matrix.testingRenderedRows.map(\.sample)), ["Carrier"])
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(summaryViewMode: .outline, layout: .listTop)
        )
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["Carrier"])
        controller.testingApplyDisplayState(
            GenotypeResultDisplayState(
                viewportLens: .review,
                summaryViewMode: .outline,
                layout: .listTop
            )
        )
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["Carrier"])
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
        XCTAssertEqual(controller.testingSearchQueryCount, 6)
        XCTAssertEqual(controller.testingSearchHaplotypeRecordBuildCount, 1)
    }


    func testSavingActiveHaplotypeDefinitionRefreshesLiveCalls() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeActiveDefinition")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.active-definition"
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        try store.save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "OldB",
            diagnosticAllele: "12_M8_B_001_01"
        ))
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: definitionID,
            definitionSetName: "Custom test",
            speciesName: "Test species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: NO HAP",
                            haplotype2: "ERR: NO HAP",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        ),
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: definitionID
        ))
        XCTAssertEqual(controller.callEvidence(sample: "DW472", locus: "MHC-B")?.h1Name, "ERR: NO HAP")

        try controller.testingSaveHaplotypeDefinition(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "NewB")
        XCTAssertEqual(evidence.status, .called)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))
        XCTAssertTrue(controller.testingHaplotypeMatrixText.contains("NewB"))
        XCTAssertFalse(controller.testingHaplotypeMatrixText.contains("OldB"))
    }


    func testGenotypeOnlyResultUsesRawMatrixEvenWithResolvedDefinition() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeOnlyRawMatrixDefinition")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.raw-matrix-definition"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        ))
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeDefinitionSetID: definitionID
        ))

        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        let definitionMatrix = try XCTUnwrap(
            controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self)
        )
        XCTAssertTrue(definitionMatrix.isHidden)
    }


    func testCandidateOnlyGenotypeResultDefaultsToRawMatrix() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let result = makeResult(
            samples: [],
            calls: [],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            reviewableRowCatalog: GenotypeReviewableRowCatalog(
                schemaID: GenotypeReviewableRowCatalog.schemaID,
                schemaVersion: GenotypeReviewableRowCatalog.schemaVersion,
                samples: ["DW472"],
                rows: [
                    .init(
                        kind: .candidate,
                        callID: "candidate:MHC-E:candidate-1",
                        displayName: "Mafa-E*02:04:01:01_10nt_nov",
                        locus: "MHC-E",
                        stableID: "candidate-1",
                        section: "candidate",
                        sortKey: "MHC-E|Mafa-E*02:04:01:01_10nt_nov",
                        supportBySample: ["DW472": 17]
                    ),
                ]
            )
        )

        XCTAssertEqual(controller.testingDefaultSummaryViewMode(for: result), .matrix)

        controller.configure(result: result)

        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
    }


    func testAIHaplotypingCompletionResetsGenotypeOnlyMatrixDefaultToOutline() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue
        ))
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)

        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "ai-provisional:test",
            definitionSetName: "AI provisional",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        )
                    ]
                )
            ]
        )

        controller.applyAIHaplotypingCompleted(result: makeResult(
            samples: [],
            calls: calls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))

        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        let lensControl = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSegmentedControl.self)
        )
        XCTAssertEqual(lensControl.segmentCount, 3)
        XCTAssertEqual(
            (0..<lensControl.segmentCount).map {
                lensControl.label(forSegment: $0)
            },
            ["Summary", "Review", "Audit"]
        )
        XCTAssertEqual(lensControl.controlSize, .regular)

        lensControl.selectedSegment = 1
        XCTAssertTrue(lensControl.sendAction(lensControl.action, to: lensControl.target))
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        lensControl.selectedSegment = 2
        XCTAssertTrue(lensControl.sendAction(lensControl.action, to: lensControl.target))
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
    }


    func testHaplotypedCompletionReturningToGenotypeOnlyRestoresMatrixOnlyView() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "ai-provisional:test",
            definitionSetName: "AI provisional",
            speciesName: "Test macaque",
            samples: []
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.audit)

        controller.applyAIHaplotypingCompleted(result: makeResult(
            samples: [],
            calls: calls
        ))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertTrue(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 0)
    }


    func testHaplotypedBundleRemembersGenotypeMatrixSummaryPreference() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeSummaryPreference")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mcm-test",
            definitionSetName: "MCM test",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        )
                    ]
                )
            ]
        )
        let result = makeResult(bundleURL: bundleURL, samples: [], calls: calls, haplotypeAnalysis: analysis)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix))
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertEqual(sidecar.settings.preferredSummaryViewMode, GenotypeSummaryViewMode.matrix.rawValue)

        let restored = GenotypeResultViewController()
        _ = restored.view
        restored.configure(result: result)

        XCTAssertEqual(restored.testingSummaryViewMode, .matrix)
    }


    func testUsingCustomHaplotypeDefinitionPersistsActiveDefinitionAndRefreshesCalls() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeUseDefinition")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.use-definition"
        let customDefinition = makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        )
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(customDefinition)
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis(),
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))
        XCTAssertNotEqual(controller.callEvidence(sample: "DW472", locus: "MHC-B")?.h1Name, "NewB")

        try controller.testingUseHaplotypeDefinition(id: definitionID)

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "NewB")
        XCTAssertEqual(evidence.status, .called)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertEqual(sidecar.settings.activeHaplotypeDefinitionSetID, definitionID)
        XCTAssertEqual(sidecar.settings.activeHaplotypeAssayID, "custom-assay")
        XCTAssertTrue(sidecar.auditLog.contains { entry in
            entry.action == "updateSettings" && (entry.after?.contains(definitionID) ?? false)
        })
        let definitionURL = try XCTUnwrap(HaplotypeDefinitionStore(projectRoot: projectRoot).definitionURL(for: definitionID))
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        XCTAssertTrue(snapshot.provenanceInputURLs.contains(definitionURL))
        XCTAssertEqual(snapshot.filters["activeHaplotypeDefinitionSetID"], definitionID)
        XCTAssertEqual(snapshot.filters["activeHaplotypeAssayID"], "custom-assay")
    }


    func testReviewEvidenceIncludesCrossFamilyMCMClassIDiagnostics() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW474", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW474", genotype: "02_M1_G_02_07_2mis_156bp", reads: 180),
            makeCall(sample: "DW474", genotype: "04_M1_AG_05_3mis_156bp", reads: 160),
            makeCall(sample: "DW474", genotype: "14_M2_DQA1_01_04", reads: 140),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: [
                                        "01_M1_F_01_w_06",
                                        "02_M1_G_02_07_2mis_156bp",
                                        "04_M1_AG_05_3mis_156bp",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "01_M1_F_01_w_06",
                                        "02_M1_G_02_07_2mis_156bp",
                                        "04_M1_AG_05_3mis_156bp",
                                    ]
                                )
                            ],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "01_M1_F_01_w_06",
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                            ]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW474", locus: "MHC-A"))
        let alleles = evidence.diagnosticAlleles.map(\.allele)
        XCTAssertTrue(alleles.contains("01_M1_F_01_w_06"))
        XCTAssertTrue(alleles.contains("02_M1_G_02_07_2mis_156bp"))
        XCTAssertTrue(alleles.contains("04_M1_AG_05_3mis_156bp"))
        XCTAssertFalse(alleles.contains("14_M2_DQA1_01_04"))
    }


    func testReviewEvidenceUsesObservedGenotypeHeaderForAnimalGenotypeDisplay() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let enrichedHeader = "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotypes=M1B|alleles=Mafa-B_073:01:01:01|evidence_classes=primary_expressed"
        let calls = [
            makeCall(sample: "LF2830", genotype: enrichedHeader, reads: 66),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M1B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1B",
                                    diagnosticAlleles: ["MCM_MHC_MiSeq_0073"],
                                    observedDiagnosticAlleles: ["MCM_MHC_MiSeq_0073"]
                                )
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: [enrichedHeader]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF2830", locus: "MHC-B"))
        XCTAssertEqual(evidence.animalGenotypes.first?.genotype, enrichedHeader)
        XCTAssertEqual(
            GenotypeCallEvidenceView.AlleleLabel(evidence.animalGenotypes.first?.genotype ?? "").primary,
            "Mafa-B*073:01:01:01"
        )
    }


    func testConfigureRendersHaplotypeCallFromRecordedAnalysisInOutline() throws {
        let bundleURL = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 400),
            makeCall(sample: "DW472", genotype: "12_M2_B_109_04", reads: 300),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M2B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"],
                                    observedDiagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M2_B_019_03", "12_M2_B_109_04"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })
        XCTAssertEqual(slot.h1.testingLabel, "M2B")
    }


    func testIncludedLociFilterOutlineAndCurrentWorkbookCalls() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "mcm-mhc-miseq",
            definitionSetID: "mcm-mhc-miseq-primary",
            definitionSetName: "MCM MHC MiSeq",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2832",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M1A-read"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-E",
                            sourceLocus: "MHC-E",
                            haplotype1: "M2E",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M2E-read"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "MHC-DRB",
                            haplotype1: "M3DR",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M3DR-read"]
                        ),
                    ]
                ),
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        XCTAssertEqual(controller.testingOutlineSlots(sample: "LF2832").map(\.locus), ["MHC-A", "MHC-DRB"])
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus), ["MHC-A"])

        controller.testingApplyDisplayState(GenotypeResultDisplayState(includedLoci: ["MHC-A", "MHC-E", "MHC-DRB"]))

        XCTAssertEqual(controller.testingOutlineSlots(sample: "LF2832").map(\.locus), ["MHC-A", "MHC-E", "MHC-DRB"])
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus), ["MHC-A"])
    }


    func testApplicableHaplotypedMiSeqWorkbookIgnoresManualAssignments() throws {
        let bundleURL = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-22T00:00:00Z")
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "LF2832",
                locus: "MHC-A",
                slot: .h1,
                label: "Manual-M2B",
                colorTokenIndex: 2,
                diagnosticAlleles: ["M2B-read"],
                notes: "curated in GUI"
            )
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "mcm-mhc-miseq",
            definitionSetID: "mcm-mhc-miseq-primary",
            definitionSetName: "MCM MHC MiSeq",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2832",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M1A-read"]
                        ),
                    ]
                ),
            ]
        )
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))

        XCTAssertEqual(
            controller.testingCurrentWorkbookHaplotypeProjectionMode(),
            .haplotyped
        )
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls(), [
            GenotypeWorkbookHaplotypeCall(
                sample: "LF2832",
                locus: "MHC-A",
                haplotype1: "M1A",
                haplotype2: "-",
                status: GenotypeHaplotypeCallStatus.called.rawValue,
                notes: ""
            )
        ])
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(
                Data(contentsOf: bundleURL.appendingPathComponent(
                    GenotypeAnnotationSidecar.filename
                ))
            ).manualHaplotypeAssignments,
            sidecar.manualHaplotypeAssignments
        )
    }


    func testCurrentWorkbookSnapshotIncludesGenotypeOnlyManualAssignmentsForONTAndMiSeq()
        throws
    {
        for kind in [
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ] {
            let bundleURL = try TestTempDirectory.make(
                prefix: "GenotypeOnlyManualWorkbook-\(kind.rawValue)"
            )
            defer { TestTempDirectory.cleanup(bundleURL) }

            var sidecar = GenotypeAnnotationSidecar.empty(
                generatedAt: "2026-07-27T00:00:00Z"
            )
            sidecar.manualHaplotypeAssignments = [
                ManualHaplotypeAssignment(
                    sample: "Sample-A",
                    locus: "MHC-A",
                    slot: .h1,
                    label: "Newest-A",
                    colorTokenIndex: 2,
                    diagnosticAlleles: [],
                    notes: "newest note",
                    assignmentID: "newest",
                    updatedAt: "2026-07-27T12:00:00Z",
                    author: "analyst"
                ),
                ManualHaplotypeAssignment(
                    sample: "Sample-A",
                    locus: "MHC-A",
                    slot: .h1,
                    label: "Older-A",
                    colorTokenIndex: 1,
                    diagnosticAlleles: [],
                    notes: "older note",
                    assignmentID: "older",
                    updatedAt: "2026-07-26T12:00:00Z",
                    author: "analyst"
                ),
                ManualHaplotypeAssignment(
                    sample: "Sample-A",
                    locus: "MHC-DRB",
                    slot: .h2,
                    label: "=DRB_FORMULA_LIKE",
                    colorTokenIndex: 3,
                    diagnosticAlleles: [],
                    notes: "literal label"
                ),
            ]
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                sidecar,
                forBundleAt: bundleURL
            )
            let samples = ["Sample-A", "Sample-B"].map {
                ONTGenotypeSampleResult(
                    sample: $0,
                    passedAlignments: 0,
                    passedUniqueReads: 0,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: []
                )
            }
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(
                result: makeResult(
                    bundleURL: bundleURL,
                    samples: samples,
                    calls: [],
                    kind: kind.rawValue
                )
            )

            let calls = controller.testingCurrentWorkbookHaplotypeCalls()
            XCTAssertEqual(
                controller.testingCurrentWorkbookHaplotypeProjectionMode(),
                .manualGenotypeOnly,
                kind.rawValue
            )
            XCTAssertEqual(calls.count, 14, kind.rawValue)
            XCTAssertEqual(
                calls.map(\.sample),
                Array(repeating: "Sample-A", count: 7)
                    + Array(repeating: "Sample-B", count: 7),
                kind.rawValue
            )
            XCTAssertEqual(
                Array(calls.prefix(7)).map(\.locus),
                GenotypeManualHaplotypeLocus.allCases.map(\.rawValue),
                kind.rawValue
            )
            XCTAssertTrue(
                calls.allSatisfy {
                    $0.status == GenotypeHaplotypeCallStatus.called.rawValue
                },
                kind.rawValue
            )
            let a = try XCTUnwrap(
                calls.first {
                    $0.sample == "Sample-A" && $0.locus == "MHC-A"
                }
            )
            XCTAssertEqual(a.haplotype1, "Newest-A", kind.rawValue)
            XCTAssertEqual(a.haplotype2, "", kind.rawValue)
            XCTAssertEqual(a.notes, "newest note", kind.rawValue)
            let drb = try XCTUnwrap(
                calls.first {
                    $0.sample == "Sample-A" && $0.locus == "MHC-DRB"
                }
            )
            XCTAssertEqual(drb.haplotype1, "", kind.rawValue)
            XCTAssertEqual(drb.haplotype2, "=DRB_FORMULA_LIKE", kind.rawValue)
            XCTAssertEqual(drb.notes, "literal label", kind.rawValue)
            XCTAssertTrue(
                calls.filter { $0.sample == "Sample-B" }.allSatisfy {
                    $0.haplotype1.isEmpty
                        && $0.haplotype2.isEmpty
                        && $0.notes.isEmpty
                },
                kind.rawValue
            )
        }
    }


    func testConfigureUsesPersistedHaplotypeAnalysisWhenSavedDropoutThresholdsExist() throws {
        let bundleURL = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(bundleURL) }
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.settings.dropoutAbsolute = 50
        sidecar.settings.dropoutSampleFraction = nil
        sidecar.settings.dropoutLocusFraction = 0.05
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W21_01", reads: 5),
            makeCall(sample: "DW472", genotype: "13_M6_DRB1_04_02_01", reads: 2),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W5_01", reads: 1),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: TMH (M1DR, M2DR, M3DR)",
                            haplotype2: "ERR: TMH (M1DR, M2DR, M3DR)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DRB"))
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        XCTAssertEqual(evidence.h1Name, "ERR: TMH (M1DR, M2DR, M3DR)")
        XCTAssertEqual(evidence.h2Name, "ERR: TMH (M1DR, M2DR, M3DR)")
    }


    func testConfigureUsesPersistedHaplotypeAnalysisWithoutSavedSidecar() throws {
        let bundleURL = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W21_01", reads: 5),
            makeCall(sample: "DW472", genotype: "13_M6_DRB1_04_02_01", reads: 2),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W5_01", reads: 1),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: TMH (M1DR, M2DR, M3DR)",
                            haplotype2: "ERR: TMH (M1DR, M2DR, M3DR)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DRB"))
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        XCTAssertEqual(evidence.h1Name, "ERR: TMH (M1DR, M2DR, M3DR)")
        XCTAssertEqual(evidence.h2Name, "ERR: TMH (M1DR, M2DR, M3DR)")
    }


    func testConfigureKeepsPersistedDeterministicHaplotypesWhenDefinitionIsAvailable() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.persisted-deterministic"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "M9B",
            diagnosticAllele: "12_M9_B_001"
        ))

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "PERSISTED-B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definitionID
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "PERSISTED-B")
        XCTAssertEqual(evidence.h2Name, "-")
    }


    func testConfigureRecomputesWhenSavedSidecarSelectsDifferentDefinition() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let activeDefinitionID = "custom.test.active-sidecar-definition"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: activeDefinitionID,
            haplotypeName: "M9B",
            diagnosticAllele: "12_M9_B_001"
        ))
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = activeDefinitionID
        sidecar.settings.activeHaplotypeAssayID = "custom-assay"
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: "custom.test.persisted-old-definition",
            definitionSetName: "Old Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "PERSISTED-B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "custom.test.persisted-old-definition"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "M9B")
        XCTAssertEqual(evidence.h2Name, "-")
    }


    func testCallEvidenceCarriesUnsupportedDefinitionHaplotypesForOverrideMenus() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.unsupported-menu-haplotypes"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(GenotypeHaplotypeDefinitionSet(
            id: definitionID,
            assayID: "custom-assay",
            displayName: "Custom Test Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M9B", diagnosticAlleles: ["12_M9_B_001"]),
                        GenotypeHaplotypeDefinition(name: "M10B", diagnosticAlleles: ["12_M10_B_001"]),
                    ]
                )
            ]
        ))
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definitionID
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.candidateHaplotypes.map(\.name), ["M9B"])
        XCTAssertEqual(evidence.availableHaplotypeNames, ["M9B", "M10B"])

        let menuSections = GenotypeCallEvidenceView.overrideActionSections(for: .h2, evidence: evidence)
        XCTAssertEqual(menuSections.recommended.map(\.haplotypeName), ["M9B"])
        XCTAssertEqual(menuSections.unsupported.map(\.haplotypeName), ["M10B"])
    }


    func testReviewEvidenceReportsDiagnosticAllelesOmittedByRunThresholds() throws {
        let projectRoot = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.threshold-omission"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "M9B",
            diagnosticAlleles: ["12_M9_B_high", "12_M9_B_low"]
        ))

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_high", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M9_B_low", reads: 3),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: NO HAP",
                            haplotype2: "ERR: NO HAP",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_high"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: definitionID,
            stats: ONTGenotypeRunStats(
                totalInputReads: 1_000,
                retainedUniqueReads: 103,
                rawMetrics: ["minSupport": "10"]
            )
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.observedGenotypes, ["12_M9_B_high"])
        XCTAssertEqual(evidence.omittedHaplotypeGenotypes.map(\.genotype), ["12_M9_B_low"])
        XCTAssertEqual(evidence.omittedHaplotypeGenotypes.first?.reads, 3)
        XCTAssertTrue(evidence.omittedHaplotypeGenotypes.first?.reason.contains("read minimum 10") ?? false)
    }


    func testDW472bLikeMHCBReviewEvidenceReflectsRecordedHaplotypeCall() throws {
        let bundleURL = try TestTempDirectory.make(prefix: "GenotypeResultViewportTests")
        defer { TestTempDirectory.cleanup(bundleURL) }

        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472b", genotype: "12_M3_B_165_01", reads: 150),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_04", reads: 100),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_06", reads: 84),
            makeCall(sample: "DW472b", genotype: "12_M2_B_019_03", reads: 75),
            makeCall(sample: "DW472b", genotype: "12_M3_B_075_01", reads: 69),
            makeCall(sample: "DW472b", genotype: "12_M2_B_162", reads: 33),
            makeCall(sample: "DW472b", genotype: "12_M2_B_150_01_01", reads: 26),
            makeCall(sample: "DW472b", genotype: "12_M2M5_B_098g|B_098_01,_B_098_04", reads: 22),
            makeCall(sample: "DW472b", genotype: "12_M3_B_098_05", reads: 20),
            makeCall(sample: "DW472b", genotype: "12_M2M3_B_079g", reads: 15),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472b",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M2B",
                            haplotype2: "M3B",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: [
                                        "12_M2_B_019_03",
                                        "12_M2_B_109_04",
                                        "12_M2_B_150_01_01",
                                        "12_M2_B_162",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "12_M2_B_019_03",
                                        "12_M2_B_109_04",
                                        "12_M2_B_150_01_01",
                                        "12_M2_B_162",
                                    ]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: [
                                        "12_M3_B_075_01",
                                        "12_M3_B_098_05",
                                        "12_M3_B_165_01",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "12_M3_B_075_01",
                                        "12_M3_B_098_05",
                                        "12_M3_B_165_01",
                                    ]
                                ),
                            ],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472b", locus: "MHC-B"))
        XCTAssertEqual(evidence.status, .called)
        XCTAssertEqual(evidence.h1Name, "M2B")
        XCTAssertEqual(evidence.h2Name, "M3B")
        XCTAssertEqual(evidence.errorExplanation, "")
        XCTAssertEqual(evidence.candidateHaplotypes.first?.name, "M2B")
    }

}
