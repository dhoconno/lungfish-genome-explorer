import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI
import XCTest
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSampleComparisonPanelTests: XCTestCase {
    private let sharedID = GenotypeCandidateMatrixRowID.candidate(
        stableClusterID: "shared"
    )
    private let targetID = GenotypeCandidateMatrixRowID.known(
        locus: "MHC-A",
        genotype: "Target only"
    )
    private let sourceID = GenotypeCandidateMatrixRowID.known(
        locus: "MHC-B",
        genotype: "Source only"
    )

    func testComparisonTableUsesWordsAndIndicatorsInMatrixOrder() {
        let model = makeComparison()
        model.selectSource("Source")
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }

        let labels = accessibilityLabels(in: mounted.host)
        XCTAssertEqual(
            model.comparisonRows.map(\.id),
            [targetID, sharedID, sourceID]
        )
        XCTAssertTrue(
            labels.contains { $0.contains("Shared") },
            "\(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("read support —") },
            "\(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("false positive") },
            "\(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("false negative") },
            "\(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("comment") },
            "\(labels)"
        )
        XCTAssertTrue(
            labels.contains {
                $0.contains("4 shared · 2 Target only · 1 Source only")
            }
                == false,
            "The factual summary must use the model's actual counts."
        )
    }

    func testRenderedComparisonPreservesMatrixAlleleAndScopedSemantics()
        throws
    {
        let rawKnown = "raw-reference-a"
        let displayedKnown = "Mafa-A1*001:01"
        let provisional = "Mafa-A1*007:08:01:01_1nt_nov"
        let calls = [
            makeCall(sample: "Target", genotype: rawKnown, reads: 18),
            makeCall(sample: "Target", genotype: provisional, reads: 11),
            makeCall(sample: "Source", genotype: rawKnown, reads: 17),
            makeCall(sample: "Source", genotype: provisional, reads: 9),
        ]
        let provisionalCall = try XCTUnwrap(
            calls.first { $0.genotype == provisional }
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.matrixComments = [
            .init(
                target: .row(
                    locus: provisionalCall.locusGroup,
                    genotype: provisional
                ),
                body: "Allele-wide context",
                author: "Analyst",
                timestamp: "2026-07-29T00:00:01Z"
            ),
            .init(
                target: .column(sample: "Target"),
                body: "Sample context",
                author: "Analyst",
                timestamp: "2026-07-29T00:00:02Z"
            ),
            .init(
                target: .cell(
                    locus: provisionalCall.locusGroup,
                    genotype: provisional,
                    sample: "Target"
                ),
                body: "Cell context",
                author: "Analyst",
                timestamp: "2026-07-29T00:00:03Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeSemanticMatrixResult(
                calls: calls,
                rawKnown: rawKnown,
                displayedKnown: displayedKnown,
                provisional: provisional
            ),
            sidecar: sidecar
        )
        let model = GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: matrix.visibleSampleEvidenceRows(sample: "Target"),
            candidates: [
                .init(
                    sample: "Source",
                    assignedSlotCount: 0,
                    completenessSummary: "0 of 14 assigned",
                    compactSummary: "No assignments",
                    accessibilityLabel:
                        "Source, 0 of 14 assigned, No assignments"
                ),
            ],
            orderedVisibleRowIDs: matrix.visibleComparisonRowIDs,
            rowsForSource: {
                matrix.visibleSampleEvidenceRows(sample: $0)
            }
        )
        model.selectSource("Source")
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }

        XCTAssertTrue(
            model.comparisonRows.map(\.allele).contains(displayedKnown),
            "\(model.comparisonRows)"
        )
        XCTAssertFalse(
            model.comparisonRows.map(\.allele).contains(rawKnown),
            "\(model.comparisonRows)"
        )
        let provisionalRow = try XCTUnwrap(
            model.comparisonRows.first { $0.allele == provisional }
        )
        XCTAssertEqual(
            provisionalRow.semanticQualifiers,
            ["Provisional exon 2"]
        )
        XCTAssertEqual(
            provisionalRow.targetCommentCounts,
            .init(alleleRow: 1, sampleColumn: 1, cell: 1)
        )
        XCTAssertEqual(
            provisionalRow.sourceCommentCounts,
            .init(alleleRow: 1, sampleColumn: 0, cell: 0)
        )

        let labels = accessibilityLabels(in: mounted.host)
        let knownLabel = try XCTUnwrap(
            labels.first { $0.contains(displayedKnown) }
        )
        XCTAssertFalse(knownLabel.contains(rawKnown), knownLabel)
        let provisionalLabel = try XCTUnwrap(
            labels.first {
                $0.contains(provisional)
                    && $0.contains("Designation: Provisional exon 2.")
            }
        )
        XCTAssertTrue(
            provisionalLabel.contains(
                "Target comments: allele row, sample column, cell; "
                    + "Source comments: allele row"
            ),
            provisionalLabel
        )
        XCTAssertTrue(
            provisionalLabel.contains(
                "Comments: allele row 1, sample column 1, cell 1."
            ),
            provisionalLabel
        )
        XCTAssertTrue(
            provisionalLabel.contains(
                "Comments: allele row 1, sample column 0, cell 0."
            ),
            provisionalLabel
        )
    }

    func testCompactWideAndTwoHundredPercentKeepStableControlIdentities() {
        let notifications = NotificationCenter()
        let preference = MutableComparisonTextSizePreference(.custom(100))
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider:
                ComparisonPreferredFontProvider(pointSize: 13)
        )
        let comparison = makeComparison()
        comparison.selectSource("Source")
        comparison.setSelected(
            true,
            at: .init(locus: .a, slot: .h1)
        )
        let trailing = GenotypeSampleCurationTrailingModel(
            evidenceSnapshot: .init(rows: []),
            comparison: comparison
        )
        let host = makeGenotypeSampleCurationTrailingHostingView(
            model: trailing,
            typographyModel: typography
        )
        let mounted = mount(host: host, width: 420)
        defer { mounted.window.close() }
        let baseline = identifiedControlIdentities(in: mounted.host)
        XCTAssertEqual(
            Set(baseline.keys),
            [
                "sample-comparison-back-to-evidence",
                "sample-comparison-source-search",
                "sample-comparison-source-selector",
                "sample-comparison-stage-selected",
            ]
        )

        for scale in [100, 200] {
            preference.value = .custom(scale)
            notifications.post(name: .contentTextSizeDidChange, object: nil)
            for width in [420, 779, 841, 1_200] {
                mounted.window.setContentSize(
                    NSSize(width: width, height: 1_200)
                )
                flush(mounted.host)
                trailing.showEvidence()
                flush(mounted.host)
                let evidenceHeight = mounted.host.fittingSize.height
                assertComparisonControlsAreAbsentFromAXTree(
                    host: mounted.host,
                    file: #filePath,
                    line: #line
                )

                trailing.showCompareAndCopy()
                flush(mounted.host)
                let comparisonHeight = mounted.host.fittingSize.height
                assertComparisonControlsArePresentInAXTree(
                    host: mounted.host,
                    file: #filePath,
                    line: #line
                )
                XCTAssertEqual(
                    identifiedControlIdentities(in: mounted.host),
                    baseline,
                    "Controls remounted at \(width) points and \(scale)%."
                )
                XCTAssertGreaterThan(
                    comparisonHeight,
                    evidenceHeight,
                    "Inactive comparison content affected Evidence height "
                        + "at \(width) points and \(scale)%."
                )
                trailing.showEvidence()
                flush(mounted.host)
                XCTAssertEqual(
                    mounted.host.fittingSize.height,
                    evidenceHeight,
                    accuracy: 1,
                    "Evidence height did not restore at \(width) points "
                        + "and \(scale)%."
                )
            }
        }
    }

    func testMountedSelectiveChooserExposesFourteenStableChoicesAndStagesOnlySelection()
        throws
    {
        var staged: [
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ] = []
        let model = makeSelectiveComparison(stage: {
            staged.append($0)
            return .init(applied: $0.addresses, skipped: [])
        })
        model.selectSource("Source")
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }

        let choiceIdentifiers = Set(
            descendants(of: mounted.host).compactMap {
                $0.accessibilityIdentifier()
            }.filter {
                $0.hasPrefix("sample-comparison-choice-")
            }
        )
        XCTAssertEqual(choiceIdentifiers.count, 14)
        XCTAssertEqual(
            choiceIdentifiers,
            Set(
                GenotypeManualHaplotypeDraft.orderedSlotAddresses.map {
                    "sample-comparison-choice-\($0.locus.rawValue)-"
                        + $0.slot.rawValue
                }
            )
        )
        XCTAssertTrue(model.selectedSlotAddresses.isEmpty)

        let stage = try XCTUnwrap(
            concreteButton(
                identifier: "sample-comparison-stage-selected",
                in: mounted.host
            )
        )
        XCTAssertEqual(stage.title, "Stage 0 Selected Assignments")
        XCTAssertFalse(stage.isEnabled)

        let aH1 = try XCTUnwrap(
            concreteButton(
                identifier: "sample-comparison-choice-MHC-A-h1",
                in: mounted.host
            )
        )
        let aH1Value = aH1.accessibilityValue() as? String
        XCTAssertTrue(
            aH1Value?.contains(
                "Source: Source A1. Target: Unassigned. Fills empty slot."
            ) == true,
            aH1Value ?? "nil"
        )
        aH1.performClick(nil)
        flush(mounted.host)
        XCTAssertEqual(stage.title, "Stage 1 Selected Assignments")
        XCTAssertTrue(stage.isEnabled)

        let selectA = try XCTUnwrap(
            concreteButton(
                identifier: "sample-comparison-select-locus-MHC-A",
                in: mounted.host
            )
        )
        selectA.performClick(nil)
        flush(mounted.host)
        XCTAssertEqual(stage.title, "Stage 2 Selected Assignments")

        stage.performClick(nil)
        flush(mounted.host)
        XCTAssertNotNil(model.pendingSelectiveCopy)
        XCTAssertFalse(stage.isEnabled)
        XCTAssertFalse(aH1.isEnabled)
        let search = try XCTUnwrap(
            descendants(of: mounted.host).first {
                $0.accessibilityIdentifier()
                    == "sample-comparison-source-search"
            } as? NSSearchField
        )
        XCTAssertFalse(search.isEnabled)

        model.confirmStageSelected()
        flush(mounted.host)
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(
            staged.first?.addresses,
            [
                .init(locus: .a, slot: .h1),
                .init(locus: .a, slot: .h2),
            ]
        )
    }

    func testSelectiveChooserShowsReplaceSameAndUnavailableReasonsAndReflowsAtTwoHundredPercent()
        throws
    {
        let model = makeSelectiveComparison()
        model.selectSource("Source")
        let notifications = NotificationCenter()
        let preference = MutableComparisonTextSizePreference(.custom(200))
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider:
                ComparisonPreferredFontProvider(pointSize: 13)
        )
        let mounted = mount(
            model: model,
            width: 420,
            typography: typography
        )
        defer { mounted.window.close() }
        flush(mounted.host)

        let labels = accessibilityLabels(in: mounted.host)
        XCTAssertTrue(labels.contains {
            $0.contains("Replaces Target A2")
        }, "\(labels)")
        XCTAssertTrue(labels.contains {
            $0.contains("Same assignment")
        }, "\(labels)")
        XCTAssertTrue(labels.contains {
            $0.contains("Unavailable until hidden legacy metadata is cleared")
        }, "\(labels)")

        let choiceViews = descendants(of: mounted.host).filter {
            $0.accessibilityIdentifier()
                .hasPrefix("sample-comparison-choice-")
        }
        XCTAssertEqual(choiceViews.count, 14)
        let choiceFrames = choiceViews.map {
            $0.convert($0.bounds, to: mounted.host)
        }
        XCTAssertTrue(choiceFrames.allSatisfy { frame in
            return frame.minX >= -4
                && frame.maxX <= mounted.host.bounds.maxX + 4
        }, "\(choiceFrames), host=\(mounted.host.bounds)")
    }

    func testMountedChoiceAnnouncesSelectedSourceSample() throws {
        let model = makeSelectiveComparison()
        model.selectSource("Source")
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }

        let choice = try XCTUnwrap(
            assignmentCheckbox(
                locus: .a,
                slot: .h1,
                in: mounted.host
            )
        )
        XCTAssertTrue(
            choice.accessibilityLabel()?.contains(
                "Source sample: Source."
            ) == true,
            choice.accessibilityLabel() ?? "Missing accessibility label"
        )
        XCTAssertTrue(
            String(describing: choice.accessibilityValue()).contains(
                "Source sample: Source."
            ),
            String(describing: choice.accessibilityValue())
        )
    }

    func testMountedAssignmentCheckboxesToggleWithSpaceAndMoveWithArrows()
        throws
    {
        let model = makeSelectiveComparison()
        model.selectSource("Source")
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }
        let first = try XCTUnwrap(
            assignmentCheckbox(
                locus: .a,
                slot: .h1,
                in: mounted.host
            )
        )
        let second = try XCTUnwrap(
            assignmentCheckbox(
                locus: .a,
                slot: .h2,
                in: mounted.host
            )
        )

        XCTAssertTrue(mounted.window.makeFirstResponder(first))
        first.keyDown(
            withCharacters: " ",
            keyCode: 49,
            in: mounted.window
        )
        flush(mounted.host)
        XCTAssertTrue(
            model.selectedSlotAddresses.contains(
                .init(locus: .a, slot: .h1)
            )
        )

        first.keyDown(
            withCharacters: String(
                UnicodeScalar(NSRightArrowFunctionKey)!
            ),
            keyCode: 124,
            in: mounted.window
        )
        flush(mounted.host)
        XCTAssertTrue(
            mounted.window.firstResponder === second,
            "Right arrow did not move to the next assignment checkbox."
        )

        second.keyDown(
            withCharacters: String(
                UnicodeScalar(NSLeftArrowFunctionKey)!
            ),
            keyCode: 123,
            in: mounted.window
        )
        flush(mounted.host)
        XCTAssertTrue(
            mounted.window.firstResponder === first,
            "Left arrow did not return to the previous assignment checkbox."
        )
    }

    func testMountedReadOnlyComparisonCanBrowseButCannotStage() throws {
        let model = makeSelectiveComparison(isReadOnly: true)
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }
        let search = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap { $0 as? NSSearchField }
                .first {
                    $0.accessibilityIdentifier()
                        == "sample-comparison-source-search"
                }
        )
        XCTAssertTrue(search.isEnabled)
        XCTAssertTrue(mounted.window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor())
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(
            by: #selector(NSResponder.insertNewline(_:))
        )
        flush(mounted.host)
        XCTAssertEqual(model.selectedSource, "Source")

        let choice = try XCTUnwrap(
            assignmentCheckbox(
                locus: .a,
                slot: .h1,
                in: mounted.host
            )
        )
        let stage = try XCTUnwrap(
            concreteButton(
                identifier: "sample-comparison-stage-selected",
                in: mounted.host
            )
        )
        XCTAssertTrue(choice.isEnabled)
        XCTAssertTrue(mounted.window.makeFirstResponder(choice))
        let labels = accessibilityLabels(in: mounted.host)
        XCTAssertTrue(
            labels.contains { $0.contains("Target only") },
            "Comparison evidence was not available while read-only."
        )
        XCTAssertFalse(stage.isEnabled)
        XCTAssertTrue(
            labels.contains {
                $0.contains("read-only")
                    && $0.contains("cannot stage or save")
            },
            "Missing read-only status announcement: \(labels)"
        )
    }

    func testEvidenceCompareEvidenceCycleKeepsBothModeTreesMounted() {
        let comparison = makeComparison()
        comparison.selectSource("Source")
        let trailing = GenotypeSampleCurationTrailingModel(
            evidenceSnapshot: .init(rows: [
                .init(
                    id: "evidence",
                    allele: "Evidence allele",
                    readSupport: "12"
                ),
            ]),
            comparison: comparison
        )
        let host = makeGenotypeSampleCurationTrailingHostingView(
            model: trailing,
            typographyModel: .shared
        )
        let mounted = mount(host: host, width: 841)
        defer { mounted.window.close() }

        let initialEvidence = try? XCTUnwrap(
            accessibilityView(labelled: "Supported Alleles", in: host)
        )
        trailing.showCompareAndCopy()
        flush(host)
        let sourceControl = descendants(of: host)
            .first {
                $0.accessibilityIdentifier()
                    == "sample-comparison-source-search"
            }
        trailing.showEvidence()
        flush(host)
        let finalEvidence = try? XCTUnwrap(
            accessibilityView(labelled: "Supported Alleles", in: host)
        )
        trailing.showCompareAndCopy()
        flush(host)
        let sourceControlAgain = descendants(of: host)
            .first {
                $0.accessibilityIdentifier()
                    == "sample-comparison-source-search"
            }

        XCTAssertTrue(initialEvidence === finalEvidence)
        XCTAssertTrue(sourceControl === sourceControlAgain)
    }

    func testModeActionsAreConcreteStableButtonsAndInactiveModeIsDisabled() {
        var staged:
            [GenotypeSampleComparisonModel.PendingSelectiveCopy] = []
        let comparison = makeComparison(stage: {
            staged.append($0)
            return .init(applied: $0.addresses, skipped: [])
        })
        comparison.selectSource("Source")
        comparison.selectAllAssigned()
        let trailing = GenotypeSampleCurationTrailingModel(
            evidenceSnapshot: .init(rows: []),
            comparison: comparison
        )
        let host = makeGenotypeSampleCurationTrailingHostingView(
            model: trailing,
            typographyModel: .shared
        )
        let mounted = mount(host: host, width: 841)
        defer { mounted.window.close() }

        guard let back = concreteButton(
            identifier: "sample-comparison-back-to-evidence",
            in: host
        ),
        let use = concreteButton(
            identifier: "sample-comparison-stage-selected",
            in: host
        ),
        let search = descendants(of: host).first(where: {
            $0.accessibilityIdentifier()
                == "sample-comparison-source-search"
        }) as? NSSearchField else {
            return XCTFail("Expected concrete comparison controls")
        }
        XCTAssertFalse(back.isEnabled)
        XCTAssertFalse(use.isEnabled)
        XCTAssertFalse(search.isEnabled)
        XCTAssertNil(back.hitTest(back.bounds.center))
        XCTAssertNil(use.hitTest(use.bounds.center))
        XCTAssertNil(search.hitTest(search.bounds.center))
        assertComparisonControlsAreAbsentFromAXTree(host: host)

        trailing.showCompareAndCopy()
        flush(host)
        XCTAssertTrue(back.isEnabled)
        XCTAssertTrue(use.isEnabled)
        XCTAssertTrue(search.isEnabled)
        XCTAssertNotNil(back.hitTest(back.bounds.center))
        XCTAssertNotNil(use.hitTest(use.bounds.center))
        XCTAssertNotNil(search.hitTest(search.bounds.center))
        assertComparisonControlsArePresentInAXTree(host: host)

        use.performClick(nil)
        comparison.confirmStageSelected()
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.sourceSample, "Source")
        back.performClick(nil)
        flush(host)
        XCTAssertEqual(trailing.mode, .evidence)
        assertComparisonControlsAreAbsentFromAXTree(host: host)
        trailing.showCompareAndCopy()
        flush(host)
        XCTAssertTrue(
            back === concreteButton(
                identifier: "sample-comparison-back-to-evidence",
                in: host
            )
        )
        XCTAssertTrue(
            use === concreteButton(
                identifier: "sample-comparison-stage-selected",
                in: host
            )
        )
    }

    func testSideBySideWorkbenchKeepsComparisonBelowHeaderAndBackButtonHittable()
        throws
    {
        let comparison = makeComparison()
        comparison.selectSource("Source")
        let trailing = GenotypeSampleCurationTrailingModel(
            evidenceSnapshot: .init(rows: []),
            comparison: comparison
        )
        let evidence = makeGenotypeSampleCurationTrailingHostingView(
            model: trailing,
            typographyModel: .shared
        )
        let header = FixedIntrinsicView(
            size: NSSize(width: 1_200, height: 140)
        )
        let assignments = FixedIntrinsicView(
            size: NSSize(width: 800, height: 620)
        )
        let workbench = GenotypeSampleCurationWorkbenchView(
            headerView: header,
            assignmentView: assignments,
            evidenceView: evidence
        )
        let mounted = mount(host: workbench, width: 1_400)
        defer { mounted.window.close() }
        trailing.showCompareAndCopy()
        flush(workbench)

        XCTAssertEqual(workbench.layoutMode, .sideBySide)
        let headerFrame = header.convert(header.bounds, to: workbench)
        let assignmentFrame = assignments.convert(
            assignments.bounds,
            to: workbench
        )
        let evidenceFrame = evidence.convert(evidence.bounds, to: workbench)
        XCTAssertEqual(
            evidenceFrame.maxY,
            assignmentFrame.maxY,
            accuracy: 1,
            "Side-by-side columns must share a top edge."
        )
        XCTAssertLessThanOrEqual(
            evidenceFrame.maxY,
            headerFrame.minY - 11,
            "The comparison column must remain below the shared header."
        )

        let back = try XCTUnwrap(
            concreteButton(
                identifier: "sample-comparison-back-to-evidence",
                in: workbench
            )
        )
        let buttonCenter = back.convert(back.bounds.center, to: workbench)
        let hit = try XCTUnwrap(workbench.hitTest(buttonCenter))
        XCTAssertTrue(
            hit === back || hit.isDescendant(of: back),
            "The real mouse hit must reach Back to Evidence, not \(hit). "
                + "header=\(headerFrame), assignments=\(assignmentFrame), "
                + "evidence=\(evidenceFrame), buttonCenter=\(buttonCenter), "
                + "button=\(back.convert(back.bounds, to: workbench)), "
                + "evidenceFittingSize=\(evidence.fittingSize), "
                + "evidenceIntrinsic=\(evidence.intrinsicContentSize), "
                + "ancestry=\(ancestryDescription(of: back, in: workbench))."
        )
        back.performClick(nil)
        flush(workbench)
        XCTAssertEqual(trailing.mode, .evidence)
    }

    func testTrailingPaneMeasuresOnlyTheActiveMode() {
        let comparison = makeKeyboardComparison()
        comparison.selectSource("Matching First")
        let trailing = GenotypeSampleCurationTrailingModel(
            evidenceSnapshot: .init(rows: []),
            comparison: comparison
        )
        let host = makeGenotypeSampleCurationTrailingHostingView(
            model: trailing,
            typographyModel: .shared
        )
        let mounted = mount(host: host, width: 841)
        defer { mounted.window.close() }

        let evidenceHeight = host.fittingSize.height
        trailing.showCompareAndCopy()
        flush(host)
        let comparisonHeight = host.fittingSize.height
        trailing.showEvidence()
        flush(host)
        let restoredEvidenceHeight = host.fittingSize.height

        XCTAssertGreaterThan(comparisonHeight, evidenceHeight)
        XCTAssertEqual(
            restoredEvidenceHeight,
            evidenceHeight,
            accuracy: 1
        )
    }

    func testRefreshPreservesTrailingComparisonAndSelectorIdentity() {
        let comparison = makeComparison()
        comparison.selectSource("Source")
        let trailing = GenotypeSampleCurationTrailingModel(
            evidenceSnapshot: .init(rows: []),
            comparison: comparison
        )
        trailing.showCompareAndCopy()
        let host = makeGenotypeSampleCurationTrailingHostingView(
            model: trailing,
            typographyModel: .shared
        )
        let mounted = mount(host: host, width: 841)
        defer { mounted.window.close() }
        let search = descendants(of: host).first {
            $0.accessibilityIdentifier()
                == "sample-comparison-source-search"
        }

        trailing.refreshEvidence(
            target: .init(rows: [
                .init(
                    id: "new",
                    allele: "New evidence",
                    readSupport: "99"
                ),
            ]),
            comparisonTargetRows: [
                row(id: sharedID, allele: "Shared refreshed", reads: 99),
            ],
            selectedSourceRows: [
                row(id: sharedID, allele: "Shared refreshed", reads: 88),
            ]
        )
        flush(host)
        let searchAgain = descendants(of: host).first {
            $0.accessibilityIdentifier()
                == "sample-comparison-source-search"
        }

        XCTAssertTrue(search === searchAgain)
        XCTAssertTrue(trailing.comparison === comparison)
        XCTAssertEqual(comparison.selectedSource, "Source")
        XCTAssertEqual(
            comparison.comparisonRows.map(\.targetReadSupport),
            ["99"]
        )
    }

    func testSourceSearchFieldEditorCommandsHighlightAndSelectFilteredCandidate() {
        let model = makeKeyboardComparison()
        let mounted = mount(model: model, width: 841)
        defer { mounted.window.close() }
        guard let search = descendants(of: mounted.host).first(where: {
            $0.accessibilityIdentifier()
                == "sample-comparison-source-search"
        }) as? NSSearchField else {
            return XCTFail("Expected an AppKit source search field")
        }
        let searchIdentity = ObjectIdentifier(search)
        XCTAssertTrue(mounted.window.makeFirstResponder(search))
        guard let editor = search.currentEditor() else {
            return XCTFail("Expected the mounted search field editor")
        }
        XCTAssertTrue(mounted.window.firstResponder === editor)

        search.stringValue = "matching"
        search.delegate?.controlTextDidChange?(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: search
            )
        )
        flush(mounted.host)
        XCTAssertEqual(
            model.filteredCandidates.map(\.sample),
            ["Matching First", "Matching Second"]
        )
        editor.doCommand(
            by: #selector(NSResponder.moveDown(_:))
        )
        flush(mounted.host)
        XCTAssertTrue(mounted.window.firstResponder === editor)
        XCTAssertTrue(
            search.accessibilityHelp()?.contains(
                "Keyboard highlighted sample: Matching First."
            ) == true
        )

        editor.doCommand(
            by: #selector(NSResponder.moveDown(_:))
        )
        flush(mounted.host)
        XCTAssertTrue(mounted.window.firstResponder === editor)
        XCTAssertTrue(
            search.accessibilityHelp()?.contains(
                "Keyboard highlighted sample: Matching Second."
            ) == true
        )
        XCTAssertEqual(model.selectedSource, nil)

        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        editor.doCommand(
            by: #selector(NSResponder.insertNewline(_:))
        )
        flush(mounted.host)

        XCTAssertEqual(model.selectedSource, "Matching First")
        XCTAssertTrue(mounted.window.firstResponder === editor)
        XCTAssertTrue(
            search.accessibilityHelp()?.contains(
                "Keyboard highlighted sample: Matching First."
            ) == true
        )

        mounted.window.setContentSize(
            NSSize(width: 420, height: 1_200)
        )
        model.refreshTargetRows([
            row(id: targetID, allele: "Target refreshed", reads: 19),
        ])
        flush(mounted.host)
        let searchAfterRefresh = descendants(of: mounted.host).first {
            $0.accessibilityIdentifier()
                == "sample-comparison-source-search"
        }
        XCTAssertEqual(
            searchAfterRefresh.map(ObjectIdentifier.init),
            searchIdentity
        )
        XCTAssertEqual(model.selectedSource, "Matching First")
        XCTAssertTrue(
            search.accessibilityHelp()?.contains(
                "Keyboard highlighted sample: Matching First."
            ) == true
        )
    }

    private func makeComparison(
        stage: @escaping (
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ) -> GenotypeManualHaplotypeDraft.SelectiveCopyResult = {
            .init(applied: $0.addresses, skipped: [])
        }
    ) -> GenotypeSampleComparisonModel {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Source A1"
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        let targetDraft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        return GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [
                row(id: targetID, allele: "Target only", reads: 9),
                row(
                    id: sharedID,
                    allele: "Shared",
                    reads: 12,
                    indicators: [.falsePositive, .comment]
                ),
            ],
            candidates: [
                .init(
                    sample: "Source",
                    assignedSlotCount: 8,
                    completenessSummary: "8 of 14 assigned",
                    compactSummary: "A-1, B-2",
                    accessibilityLabel:
                        "Source, 8 of 14 assigned, A-1, B-2"
                ),
            ],
            rowsForSource: { [sharedID, sourceID] sample in
                guard sample == "Source" else { return [] }
                return [
                    self.row(
                        id: sharedID,
                        allele: "Shared",
                        reads: nil,
                        indicators: [.falseNegative]
                    ),
                    self.row(
                        id: sourceID,
                        allele: "Source only",
                        reads: 7
                    ),
                ]
            },
            targetSlots: Dictionary(
                uniqueKeysWithValues: targetDraft.slotSnapshots.map {
                    ($0.address, $0)
                }
            ),
            targetDraftRevision: UUID(),
            isReadOnly: false,
            assignmentsForSource: {
                $0 == "Source"
                    ? index.sampleAssignments(for: "Source")
                    : nil
            },
            stageSelectedAssignments: stage
        )
    }

    private func makeKeyboardComparison() -> GenotypeSampleComparisonModel {
        let candidates = [
            ("Unrelated", "other assignments"),
            ("Matching First", "matching assignments"),
            ("Matching Second", "matching assignments"),
        ].map { sample, summary in
            GenotypeManualHaplotypeEditorModel.CopyCandidate(
                sample: sample,
                assignedSlotCount: 2,
                completenessSummary: "2 of 14 assigned",
                compactSummary: summary,
                accessibilityLabel:
                    "\(sample), 2 of 14 assigned, \(summary)"
            )
        }
        return GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [
                row(id: targetID, allele: "Target only", reads: 9),
            ],
            candidates: candidates,
            rowsForSource: { _ in [] }
        )
    }

    private func makeSelectiveComparison(
        isReadOnly: Bool = false,
        stage: @escaping (
            GenotypeSampleComparisonModel.PendingSelectiveCopy
        ) -> GenotypeManualHaplotypeDraft.SelectiveCopyResult = {
            .init(applied: $0.addresses, skipped: [])
        }
    ) -> GenotypeSampleComparisonModel {
        let sourceAssignments = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "Source A1"
            ),
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h2,
                label: "Source A2"
            ),
            assignment(
                sample: "Source",
                locus: .b,
                slot: .h1,
                label: "Same B1"
            ),
            assignment(
                sample: "Source",
                locus: .drb,
                slot: .h1,
                label: "Source DRB1"
            ),
        ]
        let targetAssignments = [
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h2,
                label: "Target A2"
            ),
            assignment(
                sample: "Target",
                locus: .b,
                slot: .h1,
                label: "Same B1"
            ),
            assignment(
                sample: "Target",
                locus: .drb,
                slot: .h1,
                label: "Protected DRB1",
                notes: "Hidden legacy note"
            ),
        ]
        let all = targetAssignments + sourceAssignments
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: all
        )
        let targetDraft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        return GenotypeSampleComparisonModel(
            targetSample: "Target",
            targetRows: [
                row(id: targetID, allele: "Target only", reads: 9),
            ],
            candidates: [
                .init(
                    sample: "Source",
                    assignedSlotCount: 4,
                    completenessSummary: "4 of 14 assigned",
                    compactSummary: "A H1 Source A1",
                    accessibilityLabel:
                        "Source, 4 of 14 assigned, A H1 Source A1"
                ),
            ],
            rowsForSource: { _ in [] },
            targetSlots: Dictionary(
                uniqueKeysWithValues: targetDraft.slotSnapshots.map {
                    ($0.address, $0)
                }
            ),
            targetDraftRevision: UUID(),
            isReadOnly: isReadOnly,
            assignmentsForSource: {
                $0 == "Source"
                    ? index.sampleAssignments(for: "Source")
                    : nil
            },
            stageSelectedAssignments: stage
        )
    }

    private func assignment(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot,
        label: String,
        notes: String = ""
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: locus.rawValue,
            slot: slot,
            label: label,
            colorTokenIndex: 0,
            diagnosticAlleles: [],
            notes: notes
        )
    }

    private func row(
        id: GenotypeCandidateMatrixRowID,
        allele: String,
        reads: Int?,
        indicators: GenotypeSampleEvidenceRow.Indicators = []
    ) -> GenotypeSampleEvidenceRow {
        .init(
            id: id,
            allele: allele,
            readSupport: reads,
            indicators: indicators,
            accessibilityLabel: allele
        )
    }

    private func makeCall(
        sample: String,
        genotype: String,
        reads: Int
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
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

    private func makeSemanticMatrixResult(
        calls: [ONTGenotypeCall],
        rawKnown: String,
        displayedKnown: String,
        provisional: String
    ) -> ONTGenotypeResultBundleData {
        let samples = ["Target", "Source"].map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: sampleCalls.reduce(0) {
                    $0 + $1.passedAlignments
                },
                passedUniqueReads: sampleCalls.reduce(0) {
                    $0 + $1.passedUniqueReads
                },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        let alleleFieldKey = "feature.allele"
        let bundleURL = URL(
            fileURLWithPath: "/tmp/comparison-semantics.lungfishgenotype"
        )
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                kind:
                    GenotypeResultWorkflowKind
                        .miSeqAmpliconMHCGenotype.rawValue,
                workflowKind: .miSeqAmpliconMHCGenotype,
                workflowMode: .genotypeOnly,
                outputName: "comparison-semantics",
                analysisName: "Comparison Semantics",
                primaryWorkbookPath: "current.xlsx",
                longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("current.xlsx"),
                longSummaryCSVURL:
                    bundleURL.appendingPathComponent("calls.csv"),
                sampleSummaryCSVURL:
                    bundleURL.appendingPathComponent("samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
                provenanceURL:
                    bundleURL.appendingPathComponent("provenance.json")
            ),
            stats: ONTGenotypeRunStats(
                totalInputReads: calls.reduce(0) {
                    $0 + $1.passedUniqueReads
                },
                retainedUniqueReads: calls.reduce(0) {
                    $0 + $1.passedUniqueReads
                }
            ),
            calls: calls,
            samples: samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: .empty,
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: [
                    GenBankRecordDatabase.FieldDefinition(
                        key: alleleFieldKey,
                        displayTitle: "Allele",
                        valueType: "text",
                        sourceCategory: "feature",
                        preferredOrder: 0
                    ),
                ],
                recordsBySequenceName: [
                    rawKnown: [alleleFieldKey: displayedKnown],
                ],
                alleleFieldKey: alleleFieldKey
            ),
            provisionalExon2SequencesByGenotype: [
                provisional: ONTGenotypeProvisionalExon2Sequence(
                    genotype: provisional,
                    locus: calls.first {
                        $0.genotype == provisional
                    }?.locusGroup ?? "MHC-A",
                    sequence: "AACCGGTT",
                    sequenceSHA256: String(repeating: "a", count: 64),
                    sampleSupport: [
                        .init(
                            sample: "Target",
                            passedAlignments: 11,
                            passedUniqueReads: 11
                        ),
                        .init(
                            sample: "Source",
                            passedAlignments: 9,
                            passedUniqueReads: 9
                        ),
                    ]
                ),
            ],
            provisionalExon2ArtifactURLs: .empty
        )
    }

    private typealias Mounted = (
        window: NSWindow,
        host: NSView
    )

    private func mount(
        model: GenotypeSampleComparisonModel,
        width: CGFloat,
        typography: ContentTypographyModel = .shared
    ) -> Mounted {
        let host = NSHostingView(
            rootView: GenotypeSampleComparisonPanel(
                model: model,
                typographyModel: typography,
                onBackToEvidence: {}
            )
        )
        return mount(host: host, width: width)
    }

    private func mount(host: NSView, width: CGFloat) -> Mounted {
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1_200)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        flush(host)
        return (window, host)
    }

    private func flush(_ host: NSView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func accessibilityLabels(in root: NSView) -> [String] {
        ([root] + descendants(of: root)).compactMap {
            guard $0.isAccessibilityElement() else { return nil }
            return $0.accessibilityLabel()
        }
    }

    private func accessibilityView(
        labelled label: String,
        in root: NSView
    ) -> NSView? {
        ([root] + descendants(of: root)).first {
            $0.isAccessibilityElement()
                && $0.accessibilityLabel() == label
        }
    }

    private func controlIdentities(in root: NSView) -> Set<ObjectIdentifier> {
        Set(
            descendants(of: root)
                .filter { $0 is NSButton || $0 is NSTextField }
                .map(ObjectIdentifier.init)
        )
    }

    private func identifiedControlIdentities(
        in root: NSView
    ) -> [String: ObjectIdentifier] {
        let identifiers = [
            "sample-comparison-back-to-evidence",
            "sample-comparison-source-search",
            "sample-comparison-source-selector",
            "sample-comparison-stage-selected",
        ]
        return Dictionary(uniqueKeysWithValues: identifiers.compactMap {
            identifier in
            descendants(of: root).first {
                $0.accessibilityIdentifier() == identifier
            }.map { (identifier, ObjectIdentifier($0)) }
        })
    }

    private func assertComparisonControlsAreAbsentFromAXTree(
        host: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in [
            "sample-comparison-back-to-evidence",
            "sample-comparison-source-search",
            "sample-comparison-stage-selected",
        ] {
            let control = descendants(of: host).first {
                $0.accessibilityIdentifier() == identifier
            }
            XCTAssertFalse(
                control?.isAccessibilityElement() ?? true,
                "Inactive control \(identifier) remained an AX element.",
                file: file,
                line: line
            )
        }
    }

    private func assertComparisonControlsArePresentInAXTree(
        host: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in [
            "sample-comparison-back-to-evidence",
            "sample-comparison-source-search",
            "sample-comparison-stage-selected",
        ] {
            let control = descendants(of: host).first {
                $0.accessibilityIdentifier() == identifier
            }
            XCTAssertTrue(
                control?.isAccessibilityElement() ?? false,
                "Active control \(identifier) was not an AX element.",
                file: file,
                line: line
            )
        }
    }

    private func concreteButton(
        identifier: String,
        in root: NSView
    ) -> NSButton? {
        descendants(of: root).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func assignmentCheckbox(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot,
        in root: NSView
    ) -> NSButton? {
        concreteButton(
            identifier:
                "sample-comparison-choice-\(locus.rawValue)-"
                + slot.rawValue,
            in: root
        )
    }

    private func ancestryDescription(
        of view: NSView,
        in root: NSView
    ) -> String {
        var descriptions: [String] = []
        var current: NSView? = view
        while let item = current {
            descriptions.append(
                "\(type(of: item)):"
                    + "\(item.convert(item.bounds, to: root))"
            )
            if item === root { break }
            current = item.superview
        }
        return descriptions.joined(separator: " <- ")
    }
}

private extension NSButton {
    func keyDown(
        withCharacters characters: String,
        keyCode: UInt16,
        in window: NSWindow
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            XCTFail("Could not construct keyboard event")
            return
        }
        keyDown(with: event)
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private final class MutableComparisonTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }

}

private final class FixedIntrinsicView: NSView {
    private let size: NSSize

    init(size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        size
    }
}

@MainActor
private struct ComparisonPreferredFontProvider:
    ContentPreferredFontProviding
{
    let pointSize: CGFloat

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        if role == .monospaced {
            return .monospacedSystemFont(
                ofSize: pointSize,
                weight: .regular
            )
        }
        return .systemFont(ofSize: pointSize)
    }

    func canonicalUnscaledPointSize(
        for _: ContentTypography.Role
    ) -> CGFloat {
        pointSize
    }
}
