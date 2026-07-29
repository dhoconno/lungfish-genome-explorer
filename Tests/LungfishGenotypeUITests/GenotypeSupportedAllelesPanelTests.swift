import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSupportedAllelesPanelTests: XCTestCase {
    func testSupportedAllelesPanelSnapshotBoundsPreviewAndLabels() {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))

        XCTAssertEqual(snapshot.rows.count, 1_001)
        XCTAssertEqual(snapshot.previewRows.count, 12)
        XCTAssertEqual(snapshot.omittedRowCount, 989)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 519), .compact)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 520), .columns)
        XCTAssertEqual(
            snapshot.rows[0].accessibilityLabel,
            "Allele 0, read support 100."
        )
    }

    func testEvidenceTableContainsOnlyAlleleAndReadSupport() throws {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: [
            .init(
                id: "known:MHC-A:NHP01801",
                allele: "Mafa-A1*018:01:01:01",
                readSupport: "712"
            ),
        ])
        let mounted = mount(
            GenotypeSupportedAllelesPanel(snapshot: snapshot),
            width: 620
        )
        defer { close(mounted) }

        XCTAssertEqual(
            GenotypeSupportedAllelesSnapshot.columnTitles,
            ["Allele", "Read support"]
        )
        XCTAssertEqual(
            accessibilityLabels(in: mounted.host).filter {
                $0 == "Mafa-A1*018:01:01:01, read support 712."
            }.count,
            1
        )
    }

    func testSupportedAllelesPanelMountedProductionBehavior() throws {
        let thousandRows = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))
        let mounted = mount(
            GenotypeSupportedAllelesPanel(snapshot: thousandRows),
            width: 620
        )
        defer { close(mounted) }

        try assertBoundedInlineAccessibility(
            snapshot: thousandRows,
            mounted: mounted
        )
        try assertRealShowAllPopover(
            snapshot: thousandRows,
            mounted: mounted
        )
        try assertActualLayoutBoundary(mounted: mounted)
        try assertMountedTypographyObservation(mounted: mounted)
        assertLargeSnapshotKeepsInlineHeightBounded(mounted: mounted)
    }

    private func assertBoundedInlineAccessibility(
        snapshot: GenotypeSupportedAllelesSnapshot,
        mounted: MountedPanel
    ) throws {
        let labels = accessibilityLabels(in: mounted.host)
        let expected = ["Supported Alleles"]
            + snapshot.previewRows.map(\.accessibilityLabel)
            + ["Show All 1,001 Alleles…"]

        for label in expected {
            XCTAssertEqual(labels.filter { $0 == label }.count, 1, "Missing or duplicate \(label)")
        }
        try assertHeading(
            labelled: "Supported Alleles",
            level: 2,
            in: mounted.host
        )
        XCTAssertFalse(labels.contains(snapshot.rows[12].accessibilityLabel))
        XCTAssertFalse(descendants(of: mounted.host).contains { $0 is NSScrollView })
    }

    private func assertRealShowAllPopover(
        snapshot: GenotypeSupportedAllelesSnapshot,
        mounted: MountedPanel
    ) throws {
        let inlineHeight = mounted.host.fittingSize.height
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let button = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Show All 1,001 Alleles…" }
        )

        button.performClick(nil)
        let popoverWindow = try XCTUnwrap(
            waitForWindow(excluding: existingWindows),
            "The real button action should set the SwiftUI binding and present a popover."
        )
        let popoverContent = try XCTUnwrap(popoverWindow.contentView)
        let popoverLabels = accessibilityLabels(in: popoverContent)
        let table = try XCTUnwrap(
            descendants(of: popoverContent).compactMap { $0 as? NSTableView }.first
        )

        XCTAssertNotEqual(popoverWindow, mounted.window)
        XCTAssertTrue(popoverLabels.contains("All 1,001 Supported Alleles"))
        try assertHeading(
            labelled: "All 1,001 Supported Alleles",
            level: 1,
            in: popoverContent
        )
        XCTAssertTrue(popoverLabels.contains(snapshot.rows[0].accessibilityLabel))
        XCTAssertTrue(descendants(of: popoverContent).contains { $0 is NSScrollView })
        XCTAssertEqual(table.numberOfRows, 1_001)
        XCTAssertEqual(mounted.host.fittingSize.height, inlineHeight, accuracy: 1)

        popoverWindow.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
    }

    private func assertActualLayoutBoundary(mounted: MountedPanel) throws {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 2))
        mounted.host.rootView = GenotypeSupportedAllelesPanel(snapshot: snapshot)

        resize(mounted, width: 519)
        let compactRow = try XCTUnwrap(
            accessibilityView(
                labelled: snapshot.rows[0].accessibilityLabel,
                in: mounted.host
            )
        )
        let compactHeight = compactRow.frame.height

        resize(mounted, width: 520)
        let columnRow = try XCTUnwrap(
            accessibilityView(
                labelled: snapshot.rows[0].accessibilityLabel,
                in: mounted.host
            )
        )

        XCTAssertEqual(snapshot.layoutMode(forWidth: 519), .compact)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 520), .columns)
        XCTAssertGreaterThan(compactHeight, columnRow.frame.height)
    }

    private func assertMountedTypographyObservation(mounted: MountedPanel) throws {
        let notifications = NotificationCenter()
        let preference = MutableSupportedAllelesTextSizePreference(.custom(100))
        let provider = MutableSupportedAllelesPreferredFonts(pointSize: 13)
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 2))
        mounted.host.rootView = GenotypeSupportedAllelesPanel(
            snapshot: snapshot,
            typographyModel: typography
        )
        resize(mounted, width: 519)
        let baselineRow = try XCTUnwrap(
            accessibilityView(
                labelled: snapshot.rows[0].accessibilityLabel,
                in: mounted.host
            )
        )
        let baselineHeight = baselineRow.frame.height

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)
        flush(mounted)
        let enlargedRow = try XCTUnwrap(
            accessibilityView(
                labelled: snapshot.rows[0].accessibilityLabel,
                in: mounted.host
            )
        )

        XCTAssertGreaterThan(enlargedRow.frame.height, baselineHeight)
    }

    private func assertLargeSnapshotKeepsInlineHeightBounded(
        mounted: MountedPanel
    ) {
        resize(mounted, width: 620)
        mounted.host.rootView = GenotypeSupportedAllelesPanel(
            snapshot: GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 13))
        )
        flush(mounted)
        let thirteenRowHeight = mounted.host.fittingSize.height

        mounted.host.rootView = GenotypeSupportedAllelesPanel(
            snapshot: GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))
        )
        flush(mounted)

        XCTAssertEqual(
            mounted.host.fittingSize.height,
            thirteenRowHeight,
            accuracy: 1
        )
    }

    private func makeRows(count: Int) -> [GenotypeSupportedAllelePresentation] {
        (0..<count).map { index in
            GenotypeSupportedAllelePresentation(
                id: "allele-\(index)",
                allele: "Allele \(index)",
                readSupport: "\(100 + index)"
            )
        }
    }

    private typealias MountedPanel = (
        window: NSWindow,
        host: NSHostingView<GenotypeSupportedAllelesPanel>
    )

    private func mount(
        _ panel: GenotypeSupportedAllelesPanel,
        width: CGFloat
    ) -> MountedPanel {
        let host = NSHostingView(rootView: panel)
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
        let mounted = (window, host)
        flush(mounted)
        return mounted
    }

    private func resize(_ mounted: MountedPanel, width: CGFloat) {
        mounted.window.setContentSize(
            NSSize(width: width, height: mounted.host.frame.height)
        )
        flush(mounted)
    }

    private func flush(_ mounted: MountedPanel) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        mounted.host.layoutSubtreeIfNeeded()
    }

    private func close(_ mounted: MountedPanel) {
        mounted.window.orderOut(nil)
        mounted.window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func waitForWindow(
        excluding existingWindows: Set<ObjectIdentifier>
    ) -> NSWindow? {
        let deadline = Date(timeIntervalSinceNow: 1)
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            if let window = NSApp.windows.first(where: {
                !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible
            }) {
                window.contentView?.layoutSubtreeIfNeeded()
                return window
            }
        } while Date() < deadline
        return nil
    }

    private func accessibilityLabels(in root: NSView) -> [String] {
        ([root] + descendants(of: root))
            .filter { $0.isAccessibilityElement() }
            .compactMap { $0.accessibilityLabel() }
    }

    private func accessibilityView(
        labelled label: String,
        in root: NSView
    ) -> NSView? {
        ([root] + descendants(of: root)).first {
            $0.isAccessibilityElement() && $0.accessibilityLabel() == label
        }
    }

    private func assertHeading(
        labelled label: String,
        level: Int,
        in root: NSView
    ) throws {
        let view = try XCTUnwrap(accessibilityView(labelled: label, in: root))
        let headingRole = NSAccessibility.Role(rawValue: "AXHeading")
        let headingLevelAttribute = NSAccessibility.Attribute(rawValue: "AXHeadingLevel")
        let headingLevel = view.perform(
            NSSelectorFromString("accessibilityAttributeValue:"),
            with: headingLevelAttribute.rawValue
        )?.takeUnretainedValue() as? NSNumber

        XCTAssertEqual(view.accessibilityRole(), headingRole)
        XCTAssertNil(view.accessibilitySubrole())
        XCTAssertEqual(headingLevel?.intValue, level)
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
