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
        let model = makeComparison()
        model.selectSource("Source")
        let mounted = mount(
            model: model,
            width: 420,
            typography: typography
        )
        defer { mounted.window.close() }
        let baseline = controlIdentities(in: mounted.host)

        for width in [779, 841, 1_200] {
            mounted.window.setContentSize(
                NSSize(width: width, height: 1_200)
            )
            flush(mounted.host)
            XCTAssertEqual(controlIdentities(in: mounted.host), baseline)
        }

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)
        flush(mounted.host)
        XCTAssertEqual(controlIdentities(in: mounted.host), baseline)
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
