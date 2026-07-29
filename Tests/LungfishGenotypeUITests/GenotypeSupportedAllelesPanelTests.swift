import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSupportedAllelesPanelTests: XCTestCase {
    func testSupportedAllelesPanelSnapshotBoundsPreviewAndSelectsLayout() {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))

        XCTAssertEqual(snapshot.rows.count, 1_001)
        XCTAssertEqual(snapshot.previewRows.count, 12)
        XCTAssertEqual(snapshot.omittedRowCount, 989)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 519), .compact)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 520), .columns)
        XCTAssertEqual(
            snapshot.rows[0].accessibilityLabel,
            "Allele 0, locus MHC-A, 100 unique reads, 200 alignments, 50.0% support"
        )
    }

    func testSupportedAllelesPanelMountedInlineAccessibilityIsBounded() {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))
        let mounted = mount(GenotypeSupportedAllelesPanel(snapshot: snapshot))
        defer { mounted.window.close() }

        let presentation = GenotypeSupportedAllelesPanel.testingPresentationState(
            snapshot: snapshot,
            showsAll: false
        )
        let mountedAccessibilityElementCount = ([mounted.host] + descendants(of: mounted.host))
            .filter { $0.isAccessibilityElement() }
            .count

        XCTAssertGreaterThan(mountedAccessibilityElementCount, 0)
        XCTAssertLessThanOrEqual(mountedAccessibilityElementCount, 14)
        XCTAssertEqual(presentation.inlineAccessibilityLabels.count, 14)
        XCTAssertEqual(presentation.inlineAccessibilityLabels.first, "Supported Alleles")
        XCTAssertEqual(
            Set(presentation.inlineAccessibilityLabels.dropFirst().prefix(12)),
            Set(snapshot.previewRows.map(\.accessibilityLabel))
        )
        XCTAssertEqual(presentation.inlineAccessibilityLabels.last, "Show All 1,001 Alleles…")
        XCTAssertFalse(
            presentation.inlineAccessibilityLabels.contains(snapshot.rows[12].accessibilityLabel)
        )
    }

    func testSupportedAllelesPanelShowAllContractKeepsInlineRowsBounded() {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))

        let inline = GenotypeSupportedAllelesPanel.testingPresentationState(
            snapshot: snapshot,
            showsAll: false
        )
        let popover = GenotypeSupportedAllelesPanel.testingPresentationState(
            snapshot: snapshot,
            showsAll: true
        )

        XCTAssertEqual(inline.inlineRows.count, 12)
        XCTAssertEqual(inline.showAllButtonTitle, "Show All 1,001 Alleles…")
        XCTAssertTrue(inline.popoverRows.isEmpty)
        XCTAssertEqual(popover.inlineRows.count, 12)
        XCTAssertEqual(popover.popoverRows, snapshot.rows)
        XCTAssertEqual(popover.fullListContainer, .virtualizedList)
    }

    func testSupportedAllelesPanelLargeSnapshotDoesNotExpandInlineDocumentHeight() {
        let thirteenRows = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 13))
        let thousandRows = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))
        let thirteen = mount(GenotypeSupportedAllelesPanel(snapshot: thirteenRows))
        let thousand = mount(GenotypeSupportedAllelesPanel(snapshot: thousandRows))
        defer {
            thirteen.window.close()
            thousand.window.close()
        }

        XCTAssertEqual(
            thirteen.host.fittingSize.height,
            thousand.host.fittingSize.height,
            accuracy: 1
        )
    }

    func testSupportedAllelesPanelObservesInjectedContentTypography() {
        let notifications = NotificationCenter()
        let preference = MutableSupportedAllelesTextSizePreference(.custom(100))
        let provider = MutableSupportedAllelesPreferredFonts(pointSize: 13)
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 2))
        let panel = GenotypeSupportedAllelesPanel(
            snapshot: snapshot,
            typographyModel: typography
        )
        let baseline = panel.testingContentTypographyPointSizes

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(
            panel.testingContentTypographyPointSizes.body,
            baseline.body * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            panel.testingContentTypographyPointSizes.caption,
            baseline.caption * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(panel.snapshot, snapshot)
    }

    private func makeRows(count: Int) -> [GenotypeSupportedAllelePresentation] {
        (0..<count).map { index in
            GenotypeSupportedAllelePresentation(
                id: "allele-\(index)",
                allele: "Allele \(index)",
                locus: index.isMultiple(of: 2) ? "MHC-A" : "MHC-B",
                uniqueReads: "\(100 + index)",
                alignments: "\(200 + index)",
                support: "50.0%"
            )
        }
    }

    private typealias MountedPanel = (
        window: NSWindow,
        host: NSHostingView<GenotypeSupportedAllelesPanel>
    )

    private func mount(_ panel: GenotypeSupportedAllelesPanel) -> MountedPanel {
        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 1_200)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class MutableSupportedAllelesTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class MutableSupportedAllelesPreferredFonts: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        13
    }
}
