import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSampleComparisonModelTests: XCTestCase {
    private let targetID = GenotypeCandidateMatrixRowID.known(
        locus: "MHC-A",
        genotype: "Target only"
    )
    private let sharedID = GenotypeCandidateMatrixRowID.candidate(
        stableClusterID: "shared-cluster"
    )
    private let sourceID = GenotypeCandidateMatrixRowID.known(
        locus: "MHC-B",
        genotype: "Source only"
    )

    func testUnionKeepsTargetMatrixOrderThenAppendsSourceOnlyMatrixOrder() {
        let targetRows = [
            row(id: targetID, allele: "Target only", reads: 9),
            row(id: sharedID, allele: "Shared target label", reads: 12),
        ]
        let sourceRows = [
            row(id: sourceID, allele: "Source only", reads: 7),
            row(id: sharedID, allele: "Shared source label", reads: 11),
        ]
        let model = makeModel(
            targetRows: targetRows,
            candidates: [candidate("Source")],
            rows: ["Source": sourceRows]
        )

        model.selectSource("Source")

        XCTAssertEqual(
            model.comparisonRows.map(\.id),
            [targetID, sharedID, sourceID]
        )
        XCTAssertEqual(
            model.comparisonRows.map(\.relationship),
            [.targetOnly, .shared, .sourceOnly]
        )
        XCTAssertEqual(model.summary, .init(shared: 1, targetOnly: 1, sourceOnly: 1))
    }

    func testStableRowIdentityNotDisplayLabelDeterminesSharedRelationship() {
        let targetDuplicate = GenotypeCandidateMatrixRowID.candidate(
            stableClusterID: "target-cluster"
        )
        let sourceDuplicate = GenotypeCandidateMatrixRowID.candidate(
            stableClusterID: "source-cluster"
        )
        let model = makeModel(
            targetRows: [
                row(id: targetDuplicate, allele: "Duplicate label", reads: 4),
                row(id: sharedID, allele: "Target spelling", reads: 5),
            ],
            candidates: [candidate("Source")],
            rows: [
                "Source": [
                    row(id: sourceDuplicate, allele: "Duplicate label", reads: 6),
                    row(id: sharedID, allele: "Source spelling", reads: 7),
                ],
            ]
        )

        model.selectSource("Source")

        XCTAssertEqual(
            model.comparisonRows.map(\.relationship),
            [.targetOnly, .shared, .sourceOnly]
        )
        XCTAssertEqual(
            model.comparisonRows.map(\.id),
            [targetDuplicate, sharedID, sourceDuplicate]
        )
        XCTAssertEqual(model.comparisonRows[1].allele, "Target spelling")
    }

    func testFalseNegativeUsesFNAndAnnotationsHaveTextIndicatorsAndAccessibleLabels() {
        let target = row(
            id: sharedID,
            allele: "Mafa-A1*001:01",
            reads: 18,
            indicators: [.falsePositive, .comment],
            accessibilityLabel:
                "Sample Target, genotype Mafa-A1*001:01. Evidence: 18 unique reads. Review: false positive. Comments: cell 1."
        )
        let source = row(
            id: sharedID,
            allele: "Mafa-A1*001:01",
            reads: nil,
            indicators: [.falseNegative],
            accessibilityLabel:
                "Sample Source, genotype Mafa-A1*001:01. Evidence: no supporting reads. Review: false negative."
        )
        let model = makeModel(
            targetRows: [target],
            candidates: [candidate("Source")],
            rows: ["Source": [source]]
        )

        model.selectSource("Source")

        XCTAssertEqual(
            target.accessibilityLabel,
            "Sample Target, genotype Mafa-A1*001:01. Evidence: 18 unique reads. Review: false positive. Comments: cell 1."
        )
        XCTAssertTrue(target.indicators.contains(.falsePositive))
        XCTAssertTrue(target.indicators.contains(.comment))
        XCTAssertEqual(model.comparisonRows[0].targetReadSupport, "18")
        XCTAssertEqual(model.comparisonRows[0].sourceReadSupport, "FN")
        XCTAssertEqual(
            model.comparisonRows[0].indicatorSummary,
            "Target: FP, comment; Source: FN"
        )
    }

    func testVisibleSampleEvidenceRowsFollowProjectionAndIncludeApplicableFalseNegative() {
        let supported = makeCall(
            sample: "Target",
            genotype: "Mafa-A1*001:01",
            reads: 18
        )
        let unsupported = makeCall(
            sample: "Source",
            genotype: "Mafa-B*002:01",
            reads: 7
        )
        let supportedTarget =
            GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: supported.locusGroup,
                genotype: supported.genotype,
                sample: "Target"
            )
        let unsupportedTarget =
            GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: unsupported.locusGroup,
                genotype: unsupported.genotype,
                sample: "Target"
            )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: supportedTarget,
                disposition: .falsePositive,
                author: "Analyst",
                timestamp: "2026-07-29T00:00:01Z"
            ),
            .init(
                target: unsupportedTarget,
                disposition: .falseNegative,
                author: "Analyst",
                timestamp: "2026-07-29T00:00:02Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: supportedTarget,
                body: "Review evidence.",
                author: "Analyst",
                timestamp: "2026-07-29T00:00:03Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(calls: [unsupported, supported]),
            sidecar: sidecar
        )

        let evidence = matrix.visibleSampleEvidenceRows(sample: "Target")

        XCTAssertEqual(
            evidence.map(\.id),
            matrix.testingVisibleRows.map(\.id)
        )
        XCTAssertEqual(evidence.map(\.readSupport), [18, nil])
        XCTAssertEqual(
            evidence.map(\.indicators),
            [
                [.falsePositive, .comment],
                [.falseNegative],
            ]
        )
        XCTAssertTrue(
            evidence[0].accessibilityLabel.contains(
                "Review: false positive."
            )
        )
        XCTAssertTrue(
            evidence[1].accessibilityLabel.contains(
                "Evidence: no supporting reads."
            )
        )
    }

    func testSelectorIncludesHiddenSamplesAndExcludesCurrentSample() {
        let model = makeModel(
            candidates: [
                candidate("Target"),
                candidate("Visible"),
                candidate("Hidden Sample"),
            ],
            rows: [:]
        )

        XCTAssertEqual(
            model.filteredCandidates.map(\.sample),
            ["Visible", "Hidden Sample"]
        )
    }

    func testSourceSearchUsesCachedCandidatesWithoutBuildingEveryComparison() {
        var sourceBuilds = 0
        let model = GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [],
            candidates: [
                candidate("Alpha", assigned: 2, summary: "MHC-A H1 Family A"),
                candidate("Beta", assigned: 8, summary: "MHC-B H2 Family B"),
                candidate("Gamma", assigned: 14, summary: "Complete"),
            ],
            rowsForSource: { _ in
                sourceBuilds += 1
                return []
            },
            isDraftDirty: { false },
            stageAssignments: { _ in }
        )

        let initialSearchKeyBuilds = model.candidateSearchKeyBuildCount
        for _ in 0..<10 {
            _ = model.filteredCandidates
        }
        model.updateSearch("family b")
        model.updateSearch("family b")

        XCTAssertEqual(model.filteredCandidates.map(\.sample), ["Beta"])
        XCTAssertEqual(sourceBuilds, 0)
        XCTAssertEqual(initialSearchKeyBuilds, 3)
        XCTAssertEqual(model.candidateSearchKeyBuildCount, initialSearchKeyBuilds)
        XCTAssertEqual(model.searchEvaluationCount, 2)
    }

    func testSelectingOneSourceBuildsOnlyOneVisibleRowComparison() {
        var builtSamples: [String] = []
        let model = GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [],
            candidates: [candidate("A"), candidate("B"), candidate("C")],
            rowsForSource: { sample in
                builtSamples.append(sample)
                return []
            },
            isDraftDirty: { false },
            stageAssignments: { _ in }
        )

        model.selectSource("B")
        model.selectSource("B")

        XCTAssertEqual(builtSamples, ["B"])
        XCTAssertEqual(model.selectedSource, "B")
    }

    func testCopyStagesAllFourteenSlotsIncludingBlanksWithoutSaving() {
        let targetAssignments = GenotypeManualHaplotypeLocus.allCases.flatMap {
            locus in
            HaplotypeSlot.allCases.map { slot in
                assignment(
                    sample: "Target",
                    locus: locus,
                    slot: slot,
                    label: "\(locus.rawValue)-\(slot.rawValue)"
                )
            }
        }
        let sourceAssignments = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "Copied"
            ),
        ]
        let allAssignments = targetAssignments + sourceAssignments
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: allAssignments
        )
        var saveCount = 0
        let editor = GenotypeManualHaplotypeEditorModel(
            snapshot: .init(
                draft: .init(sample: "Target", index: index),
                copyCandidates: [index.sampleAssignments(for: "Source")],
                isReadOnly: false
            ),
            onSave: {
                saveCount += 1
                return $0
            },
            onReload: {
                .init(
                    draft: .init(sample: "Target", index: index),
                    copyCandidates: [index.sampleAssignments(for: "Source")],
                    isReadOnly: false
                )
            },
            onExport: {}
        )
        let model = makeModel(
            candidates: [candidate("Source")],
            rows: [:],
            isDirty: { editor.draft.isDirty },
            stage: { editor.copyAssignments(from: $0) }
        )

        model.selectSource("Source")
        model.requestUseAssignments()

        XCTAssertEqual(editor.draft.assignedSlotCount, 1)
        XCTAssertEqual(editor.draft[.a, .h1]?.label, "Copied")
        XCTAssertEqual(saveCount, 0)
        XCTAssertTrue(editor.draft.isDirty)
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source.")
    }

    func testDirtyDraftRequiresNamedConfirmationAndCancelIsByteForByteNoOp() {
        var staged: [String] = []
        var draftBytes = Data("unchanged-draft".utf8)
        let bytesBefore = draftBytes
        let model = makeModel(
            candidates: [candidate("Source Sample")],
            rows: [:],
            isDirty: { true },
            stage: {
                staged.append($0)
                draftBytes = Data("changed-draft".utf8)
            }
        )

        model.selectSource("Source Sample")
        let before = model.stateSnapshot
        model.requestUseAssignments()

        XCTAssertEqual(model.pendingSource, "Source Sample")
        XCTAssertEqual(
            model.confirmationText,
            "Replace the current draft with all 14 haplotype slots from Source Sample? Blank source slots will clear the corresponding draft slots."
        )
        model.cancelUseAssignments()

        XCTAssertEqual(staged, [])
        XCTAssertEqual(draftBytes, bytesBefore)
        XCTAssertNil(model.pendingSource)
        XCTAssertNil(model.confirmationText)
        XCTAssertEqual(model.selectedSource, before.selectedSource)
        XCTAssertEqual(model.comparisonRows, before.comparisonRows)
        XCTAssertNil(model.stagedStatus)
    }

    func testPendingSourceIsRetainedAcrossConfirmationAndConfirmStagesExactlyOnce() {
        var staged: [String] = []
        let model = makeModel(
            candidates: [candidate("Source A"), candidate("Source B")],
            rows: [:],
            isDirty: { true },
            stage: { staged.append($0) }
        )

        model.selectSource("Source A")
        model.requestUseAssignments()
        model.selectSource("Source B")
        model.confirmUseAssignments()
        model.confirmUseAssignments()

        XCTAssertEqual(staged, ["Source A"])
        XCTAssertNil(model.pendingSource)
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source A.")
    }

    func testStagedStatusIsVisibleAndClearsOnlyOnNextSourceOrSave() {
        var staged: [String] = []
        let model = makeModel(
            targetRows: [row(id: targetID, allele: "Target", reads: 1)],
            candidates: [candidate("Source A"), candidate("Source B")],
            rows: [:],
            stage: { staged.append($0) }
        )

        model.selectSource("Source A")
        model.requestUseAssignments()
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source A.")

        model.updateSearch("source")
        model.refreshTargetRows([
            row(id: targetID, allele: "Target refreshed", reads: 2),
        ])
        model.selectSource("Source A")
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source A.")

        model.selectSource("Source B")
        XCTAssertNil(model.stagedStatus)
        model.requestUseAssignments()
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source B.")

        model.saveCompleted()
        XCTAssertNil(model.stagedStatus)
        XCTAssertEqual(staged, ["Source A", "Source B"])
    }

    func testProjectionRefreshAtomicallyRebuildsSelectedSourceAndRetainsSelectionAndStatus() {
        let replacementSourceID =
            GenotypeCandidateMatrixRowID.candidate(
                stableClusterID: "replacement-source"
            )
        var sourceRows = [
            row(id: sharedID, allele: "Shared old", reads: 3),
            row(id: sourceID, allele: "Source old", reads: 4),
        ]
        var requestedSources: [String] = []
        let model = GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [
                row(id: targetID, allele: "Target old", reads: 1),
                row(id: sharedID, allele: "Shared old", reads: 2),
            ],
            candidates: [
                candidate("Source"),
                candidate("Nonselected"),
            ],
            rowsForSource: { sample in
                requestedSources.append(sample)
                return sample == "Source" ? sourceRows : []
            },
            isDraftDirty: { false },
            stageAssignments: { _ in }
        )
        model.selectSource("Source")
        model.requestUseAssignments()
        XCTAssertEqual(requestedSources, ["Source"])
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source.")

        sourceRows = [
            row(
                id: replacementSourceID,
                allele: "Source replacement",
                reads: 9
            ),
            row(id: sharedID, allele: "Shared refreshed", reads: 8),
        ]
        model.refreshTargetRows([
            row(id: sharedID, allele: "Shared refreshed", reads: 7),
            row(id: targetID, allele: "Target refreshed", reads: 6),
        ])

        XCTAssertEqual(requestedSources, ["Source", "Source"])
        XCTAssertEqual(model.selectedSource, "Source")
        XCTAssertEqual(model.stagedStatus, "Assignments staged from Source.")
        XCTAssertEqual(
            model.comparisonRows.map(\.id),
            [sharedID, targetID, replacementSourceID]
        )
        XCTAssertEqual(
            model.comparisonRows.map(\.relationship),
            [.shared, .targetOnly, .sourceOnly]
        )
        XCTAssertFalse(model.comparisonRows.contains { $0.id == sourceID })
    }

    private func makeModel(
        targetRows: [GenotypeSampleEvidenceRow] = [],
        candidates: [GenotypeManualHaplotypeEditorModel.CopyCandidate] = [],
        rows: [String: [GenotypeSampleEvidenceRow]],
        isDirty: @escaping () -> Bool = { false },
        stage: @escaping (String) -> Void = { _ in }
    ) -> GenotypeSampleComparisonModel {
        GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: targetRows,
            candidates: candidates,
            rowsForSource: { rows[$0] ?? [] },
            isDraftDirty: isDirty,
            stageAssignments: stage
        )
    }

    private func row(
        id: GenotypeCandidateMatrixRowID,
        allele: String,
        reads: Int?,
        indicators: GenotypeSampleEvidenceRow.Indicators = [],
        accessibilityLabel: String? = nil
    ) -> GenotypeSampleEvidenceRow {
        GenotypeSampleEvidenceRow(
            id: id,
            allele: allele,
            readSupport: reads,
            indicators: indicators,
            accessibilityLabel:
                accessibilityLabel
                ?? "\(allele), \(reads.map(String.init) ?? "no") reads"
        )
    }

    private func candidate(
        _ sample: String,
        assigned: Int = 0,
        summary: String = "No assignments"
    ) -> GenotypeManualHaplotypeEditorModel.CopyCandidate {
        .init(
            sample: sample,
            assignedSlotCount: assigned,
            completenessSummary: "\(assigned) of 14 assigned",
            compactSummary: summary,
            accessibilityLabel:
                "\(sample), \(assigned) of 14 assigned, \(summary)"
        )
    }

    private func assignment(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot,
        label: String
    ) -> ManualHaplotypeAssignment {
        .init(
            sample: sample,
            locus: locus.rawValue,
            slot: slot,
            label: label,
            colorTokenIndex: 1,
            diagnosticAlleles: [],
            notes: ""
        )
    }

    private func makeCall(
        sample: String,
        genotype: String,
        reads: Int
    ) -> ONTGenotypeCall {
        .init(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeResult(
        calls: [ONTGenotypeCall]
    ) -> ONTGenotypeResultBundleData {
        let samples = Set(calls.map(\.sample)).sorted().map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments:
                    sampleCalls.reduce(0) {
                        $0 + $1.passedAlignments
                    },
                passedUniqueReads:
                    sampleCalls.reduce(0) {
                        $0 + $1.passedUniqueReads
                    },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        return ONTGenotypeResultBundleData(
            bundleURL: URL(
                fileURLWithPath: "/tmp/comparison.lungfishgenotype"
            ),
            manifest: ONTGenotypeResultBundleManifest(
                kind: "full-length-ont-mhc-genotype",
                outputName: "comparison",
                analysisName: "Comparison",
                primaryWorkbookPath: "comparison.xlsx",
                longSummaryCSVPath: "comparison-calls.csv",
                sampleSummaryCSVPath: "comparison-samples.csv",
                statsJSONPath: "comparison-stats.json",
                provenancePath: "comparison-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(
                    fileURLWithPath: "/tmp/comparison.xlsx"
                ),
                longSummaryCSVURL: URL(
                    fileURLWithPath: "/tmp/comparison-calls.csv"
                ),
                sampleSummaryCSVURL: URL(
                    fileURLWithPath: "/tmp/comparison-samples.csv"
                ),
                statsJSONURL: URL(
                    fileURLWithPath: "/tmp/comparison-stats.json"
                ),
                provenanceURL: URL(
                    fileURLWithPath: "/tmp/comparison-provenance.json"
                )
            ),
            stats: .init(
                totalInputReads: calls.reduce(0) {
                    $0 + $1.passedUniqueReads
                },
                retainedUniqueReads: calls.reduce(0) {
                    $0 + $1.passedUniqueReads
                }
            ),
            calls: calls,
            samples: samples,
            haplotypeAnalysis: nil
        )
    }
}
