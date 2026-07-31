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
            }
        )

#if DEBUG
        let initialSearchKeyBuilds = model.candidateSearchKeyBuildCount
#endif
        for _ in 0..<10 {
            _ = model.filteredCandidates
        }
        model.updateSearch("family b")
        model.updateSearch("family b")

        XCTAssertEqual(model.filteredCandidates.map(\.sample), ["Beta"])
        XCTAssertEqual(sourceBuilds, 0)
#if DEBUG
        XCTAssertEqual(initialSearchKeyBuilds, 3)
        XCTAssertEqual(
            model.candidateSearchKeyBuildCount,
            initialSearchKeyBuilds
        )
        XCTAssertEqual(model.searchEvaluationCount, 2)
#endif
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
            }
        )

        model.selectSource("B")
        model.selectSource("B")

        XCTAssertEqual(builtSamples, ["B"])
        XCTAssertEqual(model.selectedSource, "B")
    }

    func testAssignmentChoicesUseCanonicalFourteenSlotOrderAndStartUnselected() {
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A.001"
            ),
        ]
        let model = makeSelectiveModel(sourceAssignments: source)

        model.selectSource("Source")

        XCTAssertEqual(
            model.assignmentChoices.map(\.address),
            [
                address(.a, .h1), address(.a, .h2),
                address(.b, .h1), address(.b, .h2),
                address(.drb, .h1), address(.drb, .h2),
                address(.dqa, .h1), address(.dqa, .h2),
                address(.dqb, .h1), address(.dqb, .h2),
                address(.dpa, .h1), address(.dpa, .h2),
                address(.dpb, .h1), address(.dpb, .h2),
            ]
        )
        XCTAssertTrue(model.selectedSlotAddresses.isEmpty)
        XCTAssertFalse(model.canStageSelected)
    }

    func testChoiceOutcomesNormalizeLabelsAndDisableBlankOrProtectedReplacement() {
        let target = [
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h2,
                label: " Family A ",
                notes: "Legacy note"
            ),
            assignment(
                sample: "Target",
                locus: .b,
                slot: .h1,
                label: "Old B"
            ),
            assignment(
                sample: "Target",
                locus: .b,
                slot: .h2,
                label: "Protected",
                notes: "Legacy note"
            ),
            assignment(
                sample: "Target",
                locus: .drb,
                slot: .h1,
                label: "Target remains"
            ),
        ]
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A.001"
            ),
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h2,
                label: "family a"
            ),
            assignment(
                sample: "Source",
                locus: .b,
                slot: .h1,
                label: "New B"
            ),
            assignment(
                sample: "Source",
                locus: .b,
                slot: .h2,
                label: "New protected B"
            ),
        ]
        let model = makeSelectiveModel(
            targetAssignments: target,
            sourceAssignments: source
        )

        model.selectSource("Source")

        XCTAssertEqual(
            choice(model, .a, .h1).outcome,
            .fillsEmpty
        )
        XCTAssertEqual(
            choice(model, .a, .h2).outcome,
            .sameAssignment
        )
        XCTAssertEqual(
            choice(model, .b, .h1).outcome,
            .replaces("Old B")
        )
        XCTAssertEqual(
            choice(model, .b, .h2).outcome,
            .unavailableHiddenMetadata
        )
        XCTAssertFalse(choice(model, .b, .h2).isSelectable)
        XCTAssertNil(choice(model, .drb, .h1).sourceLabel)
        XCTAssertFalse(choice(model, .drb, .h1).isSelectable)

        var clearedLegacyTarget = targetSlotSnapshots([])
        clearedLegacyTarget[address(.a, .h1)] = .init(
            address: address(.a, .h1),
            label: nil,
            colorTokenIndex: nil,
            hasHiddenCompatibilityMetadata: true,
            isDirty: true
        )
        model.refreshTargetDraft(
            slots: clearedLegacyTarget,
            revision: UUID()
        )
        XCTAssertEqual(
            choice(model, .a, .h1).outcome,
            .unavailableHiddenMetadata
        )
        XCTAssertFalse(choice(model, .a, .h1).isSelectable)
    }

    func testWhitespaceOnlyStoredSourceAssignmentCannotBeSelectedOrStaged() {
        var stagedCount = 0
        let model = makeSelectiveModel(
            sourceAssignments: [
                assignment(
                    sample: "Source",
                    locus: .a,
                    slot: .h1,
                    label: "   \n\t"
                ),
            ],
            stage: {
                stagedCount += 1
                return .init(applied: $0.addresses, skipped: [])
            }
        )

        model.selectSource("Source")
        model.selectAllAssigned()
        model.requestStageSelected()

        XCTAssertFalse(choice(model, .a, .h1).isSelectable)
        XCTAssertTrue(model.selectedSlotAddresses.isEmpty)
        XCTAssertFalse(model.canStageSelected)
        XCTAssertNil(model.pendingSelectiveCopy)
        XCTAssertEqual(stagedCount, 0)
    }

    func testUnsavedRelabelOfProtectedTargetRemainsUnavailableToMatchingSource() {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old",
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "Older notes"
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "New"
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target, source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        draft.setLabel("New", locus: .a, slot: .h1)
        let editedSlots = Dictionary(
            uniqueKeysWithValues: draft.slotSnapshots.map {
                ($0.address, $0)
            }
        )
        let model = makeSelectiveModel(
            targetAssignments: [target],
            targetSlotOverrides: editedSlots,
            sourceAssignments: [source]
        )

        model.selectSource("Source")

        XCTAssertEqual(
            choice(model, .a, .h1).outcome,
            .unavailableHiddenMetadata
        )
        XCTAssertFalse(choice(model, .a, .h1).isSelectable)

        let unchangedModel = makeSelectiveModel(
            targetAssignments: [target],
            sourceAssignments: [
                assignment(
                    sample: "Source",
                    locus: .a,
                    slot: .h1,
                    label: " old "
                ),
            ]
        )
        unchangedModel.selectSource("Source")
        XCTAssertEqual(
            choice(unchangedModel, .a, .h1).outcome,
            .sameAssignment
        )
        XCTAssertTrue(choice(unchangedModel, .a, .h1).isSelectable)
    }

    func testCleanFillAndTrueSameAssignmentStageWithoutConfirmation() {
        var fillRequests: [
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ] = []
        let fillModel = makeSelectiveModel(
            sourceAssignments: [
                assignment(
                    sample: "Source",
                    locus: .a,
                    slot: .h1,
                    label: "A1"
                ),
            ],
            stage: {
                fillRequests.append($0)
                return .init(applied: $0.addresses, skipped: [])
            }
        )
        fillModel.selectSource("Source")
        fillModel.selectAllAssigned()
        fillModel.requestStageSelected()

        XCTAssertNil(fillModel.pendingSelectiveCopy)
        XCTAssertNil(fillModel.confirmationText)
        XCTAssertEqual(fillRequests.count, 1)

        var sameRequests: [
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ] = []
        let same = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "A1"
        )
        let sameModel = makeSelectiveModel(
            targetAssignments: [same],
            sourceAssignments: [
                assignment(
                    sample: "Source",
                    locus: .a,
                    slot: .h1,
                    label: " a1 "
                ),
            ],
            stage: {
                sameRequests.append($0)
                return .init(applied: $0.addresses, skipped: [])
            }
        )
        sameModel.selectSource("Source")
        sameModel.selectAllAssigned()
        sameModel.requestStageSelected()

        XCTAssertNil(sameModel.pendingSelectiveCopy)
        XCTAssertEqual(sameRequests.count, 1)
    }

    func testReplacementConfirmationIncludesStructuredExactLabels() {
        let model = makeSelectiveModel(
            targetAssignments: [
                assignment(
                    sample: "Target",
                    locus: .a,
                    slot: .h1,
                    label: "Target Old"
                ),
            ],
            sourceAssignments: [
                assignment(
                    sample: "Source",
                    locus: .a,
                    slot: .h1,
                    label: "Source New"
                ),
            ]
        )
        model.selectSource("Source")
        model.selectAllAssigned()
        model.requestStageSelected()

        let summary = model.pendingSelectiveCopy?
            .assignmentSummaries.first
        XCTAssertEqual(summary?.address, address(.a, .h1))
        XCTAssertEqual(summary?.sourceLabel, "Source New")
        XCTAssertEqual(summary?.targetLabel, "Target Old")
        XCTAssertEqual(summary?.outcome, .replaces("Target Old"))
        XCTAssertTrue(
            model.confirmationText?.contains("Source New") == true
        )
        XCTAssertTrue(
            model.confirmationText?.contains("Target Old") == true
        )
    }

    func testUnsavedTargetEditRequiresConfirmationEvenWhenLabelsMatch() {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old"
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "New"
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target, source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        draft.setLabel("New", locus: .a, slot: .h1)
        let editedSlots = Dictionary(
            uniqueKeysWithValues: draft.slotSnapshots.map {
                ($0.address, $0)
            }
        )
        var stagedCount = 0
        let model = makeSelectiveModel(
            targetAssignments: [target],
            targetSlotOverrides: editedSlots,
            sourceAssignments: [source],
            stage: {
                stagedCount += 1
                return .init(applied: $0.addresses, skipped: [])
            }
        )
        model.selectSource("Source")
        model.selectAllAssigned()
        model.requestStageSelected()

        XCTAssertNotNil(model.pendingSelectiveCopy)
        XCTAssertEqual(stagedCount, 0)
    }

    func testSelectionsAreIndependentAndBulkSelectionUsesEligibleAssignedSlots() {
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h2,
                label: "A2"
            ),
            assignment(
                sample: "Source",
                locus: .b,
                slot: .h1,
                label: "B1"
            ),
        ]
        let model = makeSelectiveModel(sourceAssignments: source)
        model.selectSource("Source")

        model.setSelected(true, at: address(.a, .h1))
        XCTAssertEqual(model.selectedSlotAddresses, [address(.a, .h1)])
        model.setSelected(true, at: address(.a, .h2))
        XCTAssertEqual(
            model.selectedSlotAddresses,
            [address(.a, .h1), address(.a, .h2)]
        )
        model.setSelected(false, at: address(.a, .h1))
        XCTAssertEqual(model.selectedSlotAddresses, [address(.a, .h2)])

        model.selectAssigned(in: .a)
        XCTAssertEqual(
            model.selectedSlotAddresses,
            [address(.a, .h1), address(.a, .h2)]
        )
        model.selectAllAssigned()
        XCTAssertEqual(
            model.selectedSlotAddresses,
            [
                address(.a, .h1),
                address(.a, .h2),
                address(.b, .h1),
            ]
        )
        XCTAssertTrue(model.canStageSelected)
    }

    func testChangingSourceClearsSlotSelection() {
        let assignments = [
            assignment(
                sample: "Source A",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
            assignment(
                sample: "Source B",
                locus: .b,
                slot: .h1,
                label: "B1"
            ),
        ]
        let model = makeSelectiveModel(
            sourceSamples: ["Source A", "Source B"],
            sourceAssignments: assignments
        )
        model.selectSource("Source A")
        model.selectAllAssigned()

        model.selectSource("Source B")

        XCTAssertTrue(model.selectedSlotAddresses.isEmpty)
        XCTAssertEqual(
            model.assignmentChoices.compactMap(\.sourceLabel),
            ["B1"]
        )
    }

    func testTargetDraftRefreshUpdatesOutcomesWithoutReplacingModel() {
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
        ]
        let initialRevision = UUID()
        let model = makeSelectiveModel(
            sourceAssignments: source,
            revision: initialRevision
        )
        model.selectSource("Source")
        let identity = ObjectIdentifier(model)
        XCTAssertEqual(choice(model, .a, .h1).outcome, .fillsEmpty)

        let changedTarget = targetSlotSnapshots([
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h1,
                label: "Existing"
            ),
        ])
        let changedRevision = UUID()
        model.refreshTargetDraft(
            slots: changedTarget,
            revision: changedRevision
        )

        XCTAssertEqual(ObjectIdentifier(model), identity)
        XCTAssertEqual(
            choice(model, .a, .h1).outcome,
            .replaces("Existing")
        )
    }

    func testVanishedSelectedSourceClearsComparisonAndPendingWithoutStaging() {
        var staged: [
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ] = []
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
        ]
        let model = makeSelectiveModel(
            targetAssignments: [
                assignment(
                    sample: "Target",
                    locus: .a,
                    slot: .h1,
                    label: "Existing"
                ),
            ],
            sourceAssignments: source,
            stage: {
                staged.append($0)
                return .init(applied: $0.addresses, skipped: [])
            }
        )
        model.selectSource("Source")
        model.selectAllAssigned()
        model.requestStageSelected()
        XCTAssertNotNil(model.pendingSelectiveCopy)

        model.refreshCandidates([])

        XCTAssertNil(model.selectedSource)
        XCTAssertTrue(model.assignmentChoices.isEmpty)
        XCTAssertTrue(model.selectedSlotAddresses.isEmpty)
        XCTAssertNil(model.pendingSelectiveCopy)
        XCTAssertEqual(staged, [])
    }

    func testPendingRequestIsImmutableAndConfirmStagesExactlyOnce() {
        var staged: [
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ] = []
        let revision = UUID()
        let source = [
            assignment(
                sample: "Source A",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
            assignment(
                sample: "Source A",
                locus: .b,
                slot: .h2,
                label: "B2"
            ),
            assignment(
                sample: "Source B",
                locus: .drb,
                slot: .h1,
                label: "DRB1"
            ),
        ]
        let model = makeSelectiveModel(
            targetAssignments: [
                assignment(
                    sample: "Target",
                    locus: .a,
                    slot: .h1,
                    label: "Old A"
                ),
                assignment(
                    sample: "Target",
                    locus: .b,
                    slot: .h2,
                    label: "Old B"
                ),
            ],
            sourceSamples: ["Source A", "Source B"],
            sourceAssignments: source,
            revision: revision,
            stage: {
                staged.append($0)
                return .init(
                    applied: [self.address(.a, .h1)],
                    skipped: [
                        .init(
                            address: self.address(.b, .h2),
                            reason: .sourceChanged
                        ),
                    ]
                )
            }
        )
        model.selectSource("Source A")
        model.selectAllAssigned()
        model.requestStageSelected()
        let request = model.pendingSelectiveCopy
        XCTAssertTrue(model.confirmationText?.contains("A1") == true)
        XCTAssertTrue(model.confirmationText?.contains("Old A") == true)

        model.setSelected(false, at: address(.a, .h1))
        model.selectSource("Source B")
        model.refreshTargetDraft(
            slots: targetSlotSnapshots([
                assignment(
                    sample: "Target",
                    locus: .a,
                    slot: .h1,
                    label: "Protected target",
                    notes: "Legacy metadata"
                ),
            ]),
            revision: UUID()
        )

        XCTAssertEqual(model.pendingSelectiveCopy, request)
        XCTAssertEqual(model.selectedSlotAddresses, request?.addresses)
        XCTAssertEqual(request?.sourceSample, "Source A")
        XCTAssertEqual(
            request?.addresses,
            [address(.a, .h1), address(.b, .h2)]
        )
        XCTAssertEqual(request?.targetDraftRevision, revision)
        XCTAssertEqual(
            request?.sourceValues[address(.a, .h1)]?.label,
            "A1"
        )

        model.confirmStageSelected()
        model.confirmStageSelected()

        XCTAssertEqual(staged, [request].compactMap { $0 })
        XCTAssertNil(model.pendingSelectiveCopy)
        XCTAssertTrue(model.selectedSlotAddresses.isEmpty)
        XCTAssertTrue(
            model.stagedStatus?.contains(
                "1 assignment staged from Source A."
            ) == true
        )
        XCTAssertTrue(
            model.stagedStatus?.contains(
                "MHC-B H2: the source assignment changed"
            ) == true
        )
    }

    func testStaleTargetRevisionReportsReviewStatusInsteadOfSuccess() {
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
        ]
        let model = makeSelectiveModel(
            targetAssignments: [
                assignment(
                    sample: "Target",
                    locus: .a,
                    slot: .h1,
                    label: "Old"
                ),
            ],
            sourceAssignments: source,
            stage: { request in
                .init(
                    applied: [],
                    skipped: request.addresses.map {
                        .init(
                            address: $0,
                            reason: .targetChanged
                        )
                    }
                )
            }
        )
        model.selectSource("Source")
        model.selectAllAssigned()
        model.requestStageSelected()

        model.confirmStageSelected()

        XCTAssertEqual(
            model.stagedStatus,
            "Skipped MHC-A H1: the target assignment changed while "
                + "confirmation was open. Review it and try again."
        )
    }

    func testSkippedStatusNamesEverySlotAndUsesPlainReasons() {
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
            assignment(
                sample: "Source",
                locus: .b,
                slot: .h2,
                label: "B2"
            ),
            assignment(
                sample: "Source",
                locus: .drb,
                slot: .h1,
                label: "DRB1"
            ),
        ]
        let target = [
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h1,
                label: "Old A"
            ),
            assignment(
                sample: "Target",
                locus: .b,
                slot: .h2,
                label: "Old B"
            ),
            assignment(
                sample: "Target",
                locus: .drb,
                slot: .h1,
                label: "Old DRB"
            ),
        ]
        let model = makeSelectiveModel(
            targetAssignments: target,
            sourceAssignments: source,
            stage: { _ in
                .init(
                    applied: [],
                    skipped: [
                        .init(
                            address: self.address(.a, .h1),
                            reason: .sourceChanged
                        ),
                        .init(
                            address: self.address(.b, .h2),
                            reason: .hiddenMetadataRequiresSavedClear
                        ),
                        .init(
                            address: self.address(.drb, .h1),
                            reason: .targetChanged
                        ),
                    ]
                )
            }
        )
        model.selectSource("Source")
        model.selectAllAssigned()
        model.requestStageSelected()
        model.confirmStageSelected()

        XCTAssertTrue(
            model.stagedStatus?.contains(
                "MHC-A H1: the source assignment changed"
            ) == true
        )
        XCTAssertTrue(
            model.stagedStatus?.contains(
                "MHC-B H2: clear and save the existing assignment first"
            ) == true
        )
        XCTAssertTrue(
            model.stagedStatus?.contains(
                "older notes cannot attach to a new label"
            ) == true
        )
        XCTAssertTrue(
            model.stagedStatus?.contains(
                "MHC-DRB H1: the target assignment changed"
            ) == true
        )
    }

    func testCancelLeavesDraftUntouchedAndReadOnlyCanBrowseButNotStage() {
        var stagedCount = 0
        let source = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "A1"
            ),
        ]
        let model = makeSelectiveModel(
            sourceAssignments: source,
            isReadOnly: true,
            stage: {
                stagedCount += 1
                return .init(applied: $0.addresses, skipped: [])
            }
        )
        model.selectSource("Source")
        model.selectAllAssigned()

        XCTAssertEqual(model.selectedSlotAddresses, [address(.a, .h1)])
        XCTAssertFalse(model.canStageSelected)
        model.requestStageSelected()
        XCTAssertNil(model.pendingSelectiveCopy)

        model.cancelStageSelected()
        XCTAssertEqual(stagedCount, 0)
        XCTAssertEqual(model.selectedSource, "Source")
        XCTAssertFalse(model.assignmentChoices.isEmpty)
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
            }
        )
        model.selectSource("Source")
        XCTAssertEqual(requestedSources, ["Source"])

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
        XCTAssertNil(model.stagedStatus)
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
        isDirty _: @escaping () -> Bool = { false },
        stage _: @escaping (String) -> Void = { _ in }
    ) -> GenotypeSampleComparisonModel {
        GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: targetRows,
            candidates: candidates,
            rowsForSource: { rows[$0] ?? [] }
        )
    }

    private func makeSelectiveModel(
        targetAssignments: [ManualHaplotypeAssignment] = [],
        targetSlotOverrides: [
            GenotypeManualHaplotypeDraft.SlotAddress:
                GenotypeManualHaplotypeDraft.SlotSnapshot
        ]? = nil,
        sourceSamples: [String] = ["Source"],
        sourceAssignments: [ManualHaplotypeAssignment],
        revision: UUID = UUID(),
        isReadOnly: Bool = false,
        stage: @escaping (
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ) -> GenotypeManualHaplotypeDraft.SelectiveCopyResult = {
            .init(applied: $0.addresses, skipped: [])
        }
    ) -> GenotypeSampleComparisonModel {
        let allAssignments = targetAssignments + sourceAssignments
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: allAssignments
        )
        let sourceBySample = Dictionary(
            uniqueKeysWithValues: sourceSamples.map {
                ($0, index.sampleAssignments(for: $0))
            }
        )
        return GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [],
            candidates: sourceSamples.map { candidate($0) },
            rowsForSource: { _ in [] },
            targetSlots:
                targetSlotOverrides
                ?? targetSlotSnapshots(
                    targetAssignments,
                    index: index
                ),
            targetDraftRevision: revision,
            isReadOnly: isReadOnly,
            assignmentsForSource: { sourceBySample[$0] },
            stageSelectedAssignments: stage
        )
    }

    private func targetSlotSnapshots(
        _ assignments: [ManualHaplotypeAssignment],
        index explicitIndex: GenotypeManualHaplotypeAssignmentIndex? = nil
    ) -> [
        GenotypeManualHaplotypeDraft.SlotAddress:
            GenotypeManualHaplotypeDraft.SlotSnapshot
    ] {
        let index = explicitIndex
            ?? GenotypeManualHaplotypeAssignmentIndex(
                assignments: assignments
            )
        let draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        return Dictionary(
            uniqueKeysWithValues: draft.slotSnapshots.map {
                ($0.address, $0)
            }
        )
    }

    private func address(
        _ locus: GenotypeManualHaplotypeLocus,
        _ slot: HaplotypeSlot
    ) -> GenotypeManualHaplotypeDraft.SlotAddress {
        .init(locus: locus, slot: slot)
    }

    private func choice(
        _ model: GenotypeSampleComparisonModel,
        _ locus: GenotypeManualHaplotypeLocus,
        _ slot: HaplotypeSlot
    ) -> GenotypeSampleComparisonModel.AssignmentChoice {
        model.assignmentChoices.first {
            $0.address == address(locus, slot)
        }!
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
        label: String,
        diagnosticAlleles: [String] = [],
        notes: String = ""
    ) -> ManualHaplotypeAssignment {
        .init(
            sample: sample,
            locus: locus.rawValue,
            slot: slot,
            label: label,
            colorTokenIndex: 1,
            diagnosticAlleles: diagnosticAlleles,
            notes: notes
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
