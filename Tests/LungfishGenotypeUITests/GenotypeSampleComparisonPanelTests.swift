import AppKit
import LungfishCore
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
                "sample-comparison-use-assignments",
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
        var staged: [String] = []
        let comparison = makeComparison(stage: {
            staged.append($0)
        })
        comparison.selectSource("Source")
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
            identifier: "sample-comparison-use-assignments",
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
        XCTAssertEqual(staged, ["Source"])
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
                identifier: "sample-comparison-use-assignments",
                in: host
            )
        )
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

    func testUseAssignmentsStagesOnlyAfterDirtyConfirmationAndCancelIsNoOp() {
        var dirty = true
        var staged: [String] = []
        let model = makeComparison(
            isDirty: { dirty },
            stage: { staged.append($0) }
        )
        model.selectSource("Source")
        model.requestUseAssignments()

        XCTAssertNotNil(model.confirmationText)
        XCTAssertTrue(staged.isEmpty)
        model.cancelUseAssignments()
        XCTAssertTrue(staged.isEmpty)
        XCTAssertNil(model.pendingSource)

        model.requestUseAssignments()
        model.confirmUseAssignments()
        XCTAssertEqual(staged, ["Source"])
        dirty = false
    }

    private func makeComparison(
        isDirty: @escaping () -> Bool = { false },
        stage: @escaping (String) -> Void = { _ in }
    ) -> GenotypeSampleComparisonModel {
        GenotypeSampleComparisonModel(
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
            isDraftDirty: isDirty,
            stageAssignments: stage
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
            rowsForSource: { _ in [] },
            isDraftDirty: { false },
            stageAssignments: { _ in }
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
            "sample-comparison-use-assignments",
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
            "sample-comparison-use-assignments",
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
            "sample-comparison-use-assignments",
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
