import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypeViewportTests: XCTestCase {
    func testLocusLayoutUsesScaledBreakpointAndKeepsChildrenInsideBounds() {
        let childSizes = [
            CGSize(width: 72, height: 20),
            CGSize(width: 180, height: 26),
            CGSize(width: 180, height: 26),
        ]

        let wide = ManualHaplotypeLocusLayout.testingGeometry(
            availableWidth: 520,
            typographyScale: 1,
            childSizes: childSizes
        )
        XCTAssertEqual(wide.mode, .sideBySide)
        XCTAssertEqual(Set(wide.frames.map(\.minY)), [0])
        XCTAssertLessThanOrEqual(
            wide.frames.map(\.maxX).max() ?? .infinity,
            520
        )

        for width in [CGFloat(420), 280] {
            let narrow = ManualHaplotypeLocusLayout.testingGeometry(
                availableWidth: width,
                typographyScale: 1,
                childSizes: childSizes
            )
            XCTAssertEqual(narrow.mode, .stacked)
            XCTAssertGreaterThanOrEqual(
                narrow.frames[1].minY,
                narrow.frames[0].maxY
            )
            XCTAssertGreaterThanOrEqual(
                narrow.frames[2].minY,
                narrow.frames[1].maxY
            )
            XCTAssertLessThanOrEqual(
                narrow.frames.map(\.maxX).max() ?? .infinity,
                width
            )
        }

        XCTAssertEqual(
            ManualHaplotypeLocusLayout.testingGeometry(
                availableWidth: 520,
                typographyScale: 2,
                childSizes: childSizes
            ).mode,
            .stacked
        )
    }

    func testMountedEditorReflowsAtOneHundredAndTwoHundredPercent()
        throws
    {
        let standard = makeHost(width: 520, typographyPercent: 100)
        defer { standard.window.orderOut(nil) }
        XCTAssertTrue(
            locusSlotsShareRow(
                combos: try combos(in: standard.host),
                locusIndex: 0
            )
        )

        resize(standard, width: 420)
        XCTAssertFalse(
            locusSlotsShareRow(
                combos: try combos(in: standard.host),
                locusIndex: 0
            )
        )

        resize(standard, width: 280)
        let narrowCombos = try combos(in: standard.host)
        XCTAssertTrue(
            narrowCombos.allSatisfy {
                let frame = $0.convert($0.bounds, to: standard.host)
                return frame.minX >= -0.5
                    && frame.maxX <= standard.host.bounds.maxX + 0.5
            }
        )

        let enlarged = makeHost(width: 520, typographyPercent: 200)
        defer { enlarged.window.orderOut(nil) }
        XCTAssertFalse(
            locusSlotsShareRow(
                combos: try combos(in: enlarged.host),
                locusIndex: 0
            )
        )
    }

    func testTwoHundredPercentSlotHeadersFitTheirVisibleLabels() throws {
        let mounted = makeHost(width: 520, typographyPercent: 200)
        defer { mounted.window.orderOut(nil) }
        let hostedCombos = try combos(in: mounted.host)
        let editorHorizontalInset: CGFloat = 10
        let labelToComboSpacing: CGFloat = 6 + 9 + 6

        for (index, combo) in hostedCombos.enumerated() {
            let label = index.isMultiple(of: 2) ? "H1" : "H2"
            let requiredWidth = ceil(
                (label as NSString).size(
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 26),
                    ]
                ).width
            )
            let comboFrame = combo.convert(combo.bounds, to: mounted.host)
            XCTAssertGreaterThanOrEqual(
                comboFrame.minX + 0.5,
                editorHorizontalInset
                    + labelToComboSpacing
                    + requiredWidth,
                "\(label) must remain fully visible at 200% typography."
            )
        }
    }

    func testWidthChangesPreserveComboIdentityDraftFocusAndRowMajorOrder()
        throws
    {
        let mounted = makeHost(width: 520, typographyPercent: 100)
        defer { mounted.window.orderOut(nil) }
        let initial = try combos(in: mounted.host)
        let expectedIdentifiers =
            GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
                HaplotypeSlot.allCases.map {
                    "manual-haplotype-\(locus.rawValue)-\($0.rawValue)"
                }
            }
        XCTAssertEqual(
            initial.map { $0.accessibilityIdentifier() },
            expectedIdentifiers
        )

        let first = initial[0]
        XCTAssertTrue(mounted.window.makeFirstResponder(first))
        first.selectText(nil)
        flush(mounted)
        mounted.model.updateLabel(
            "Responsive Draft",
            locus: .a,
            slot: .h1
        )
        flush(mounted)
        let initialIdentities = initial.map(ObjectIdentifier.init)

        resize(mounted, width: 420)
        let stacked = try combos(in: mounted.host)
        XCTAssertEqual(stacked.map(ObjectIdentifier.init), initialIdentities)
        XCTAssertEqual(
            mounted.model.draft[.a, .h1]?.label,
            "Responsive Draft"
        )
        XCTAssertTrue(
            mounted.window.firstResponder === first
                || first.currentEditor() === mounted.window.firstResponder
        )

        resize(mounted, width: 520)
        XCTAssertEqual(
            try combos(in: mounted.host).map(ObjectIdentifier.init),
            initialIdentities
        )
    }

    func testEditorHostingViewUsesIntrinsicVerticalSizingWithoutMinimumHeight() {
        let mounted = makeHost(width: 420, typographyPercent: 100)
        defer { mounted.window.orderOut(nil) }

        XCTAssertEqual(
            mounted.host.sizingOptions,
            [.intrinsicContentSize]
        )
        XCTAssertEqual(
            mounted.host.contentHuggingPriority(for: .horizontal),
            .defaultLow
        )
        XCTAssertEqual(
            mounted.host.contentCompressionResistancePriority(
                for: .horizontal
            ),
            .defaultLow
        )
        XCTAssertFalse(
            mounted.host.constraints.contains {
                $0.firstAttribute == .height
                    && $0.relation == .greaterThanOrEqual
                    && $0.constant >= 590
            }
        )
    }

    private typealias MountedEditor = (
        window: NSWindow,
        host: NSHostingView<GenotypeManualHaplotypeEditor>,
        model: GenotypeManualHaplotypeEditorModel
    )

    private func makeHost(
        width: CGFloat,
        typographyPercent: Int
    ) -> MountedEditor {
        let preference =
            ManualHaplotypeViewportTextSizePreference(
                .custom(typographyPercent)
            )
        let typography = ContentTypographyModel(
            notificationCenter: NotificationCenter(),
            preferenceProvider: { preference.value },
            preferredFontProvider:
                ManualHaplotypeViewportPreferredFonts()
        )
        let model = makeModel()
        let host = makeGenotypeManualHaplotypeEditorHostingView(
            model: model,
            typographyModel: typography
        )
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1_600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let mounted = (window, host, model)
        flush(mounted)
        return mounted
    }

    private func makeModel() -> GenotypeManualHaplotypeEditorModel {
        let draft = GenotypeManualHaplotypeDraft(
            sample: "Animal-1",
            index: GenotypeManualHaplotypeAssignmentIndex(assignments: [])
        )
        let snapshot = GenotypeManualHaplotypeEditorModel.Snapshot(
            draft: draft,
            copyCandidates: [],
            isReadOnly: false
        )
        return GenotypeManualHaplotypeEditorModel(
            snapshot: snapshot,
            onSave: { $0 },
            onReload: { snapshot },
            onExport: {}
        )
    }

    private func combos(
        in host: NSHostingView<GenotypeManualHaplotypeEditor>
    ) throws -> [NSComboBox] {
        let values = descendants(of: host).compactMap { $0 as? NSComboBox }
        XCTAssertEqual(values.count, 14)
        return values
    }

    private func locusSlotsShareRow(
        combos: [NSComboBox],
        locusIndex: Int
    ) -> Bool {
        let h1 = combos[locusIndex * 2].convert(
            combos[locusIndex * 2].bounds,
            to: nil
        )
        let h2 = combos[locusIndex * 2 + 1].convert(
            combos[locusIndex * 2 + 1].bounds,
            to: nil
        )
        return abs(h1.midY - h2.midY) < 1
    }

    private func resize(_ mounted: MountedEditor, width: CGFloat) {
        mounted.window.setContentSize(
            NSSize(width: width, height: mounted.host.frame.height)
        )
        flush(mounted)
    }

    private func flush(_ mounted: MountedEditor) {
        mounted.window.layoutIfNeeded()
        mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        mounted.window.layoutIfNeeded()
        mounted.host.layoutSubtreeIfNeeded()
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }
}

@MainActor
private final class ManualHaplotypeViewportTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class ManualHaplotypeViewportPreferredFonts:
    ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: 13, weight: .semibold)
        default:
            return .systemFont(ofSize: 13)
        }
    }

    func canonicalUnscaledPointSize(
        for _: ContentTypography.Role
    ) -> CGFloat {
        13
    }
}
