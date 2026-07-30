import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSupportedAllelesPanelTests: XCTestCase {
    func testSupportedAllelesSnapshotPreservesAllRowsAndLabels() {
        let snapshot = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))

        XCTAssertEqual(snapshot.rows.count, 1_001)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 519), .compact)
        XCTAssertEqual(snapshot.layoutMode(forWidth: 520), .columns)
        XCTAssertEqual(
            snapshot.rows[0].accessibilityLabel,
            "Allele 0, read support 100."
        )
    }

    func testInlineTableReportsEveryRowWithoutShowAllControl() throws {
        let snapshot = GenotypeSupportedAllelesSnapshot(
            rows: makeRows(count: 1_001)
        )
        let mounted = mount(
            GenotypeSupportedAllelesPanel(snapshot: snapshot),
            width: 620
        )
        defer { close(mounted) }
        let table = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap { $0 as? NSTableView }
                .first
        )
        let buttons = descendants(of: mounted.host)
            .compactMap { $0 as? NSButton }

        XCTAssertEqual(table.numberOfRows, 1_001)
        XCTAssertFalse(
            buttons.contains { $0.title.hasPrefix("Show All") }
        )
        XCTAssertEqual(
            GenotypeSupportedAllelesSnapshot.columnTitles,
            ["Allele", "Read support"]
        )
        let headerLabels = descendants(of: mounted.host)
            .filter {
                $0.accessibilityIdentifier()
                    .hasPrefix("supported-alleles-header-")
            }
            .compactMap { $0.accessibilityLabel() }
        XCTAssertEqual(headerLabels, ["Allele", "Read support"])

        mounted.host.layoutSubtreeIfNeeded()
        let mountedCells = (0..<table.numberOfRows).compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false)
        }
        XCTAssertGreaterThan(mountedCells.count, 0)
        XCTAssertLessThan(
            mountedCells.count,
            1_001,
            "The inline table must virtualize offscreen allele rows."
        )
    }

    func testInlineTableReflowsWithoutReplacingTableOrCoordinator() throws {
        let thousandRows = GenotypeSupportedAllelesSnapshot(rows: makeRows(count: 1_001))
        let mounted = mount(
            GenotypeSupportedAllelesPanel(snapshot: thousandRows),
            width: 620
        )
        defer { close(mounted) }
        let table = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap { $0 as? NSTableView }
                .first
        )
        let firstCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let wideFields = descendants(of: firstCell)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
        XCTAssertEqual(wideFields.count, 2)
        XCTAssertEqual(
            wideFields.first { $0.stringValue == "100" }?.alignment,
            .right
        )

        resize(mounted, width: 519)
        let compactTable = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap { $0 as? NSTableView }
                .first
        )
        XCTAssertTrue(compactTable === table)
        let compactCell = try XCTUnwrap(
            compactTable.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            )
        )
        let compactFields = descendants(of: compactCell)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
        let allele = try XCTUnwrap(
            compactFields.first { $0.stringValue == "Allele 0" }
        )
        let support = try XCTUnwrap(
            compactFields.first {
                $0.stringValue == "Read support: 100"
            }
        )
        XCTAssertLessThan(support.frame.maxY, allele.frame.minY)
    }

    func testInlineTableReflowsAtTwoHundredPercentWithoutReplacingMountedTable()
        throws
    {
        let notifications = NotificationCenter()
        let preference = MutableSupportedAllelesTextSizePreference(
            .custom(100)
        )
        let provider = MutableSupportedAllelesPreferredFonts(pointSize: 13)
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let snapshot = GenotypeSupportedAllelesSnapshot(
            rows: makeRows(count: 20)
        )
        let mounted = mount(
            GenotypeSupportedAllelesPanel(
                snapshot: snapshot,
                typographyModel: typography
            ),
            width: 650
        )
        defer { close(mounted) }
        let listHost = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap {
                    $0 as? GenotypeSupportedAllelesListHostView
                }
                .first
        )
        let table = listHost.tableView
        let coordinator = try XCTUnwrap(table.delegate as AnyObject?)
        let wideCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertNotNil(
            descendants(of: wideCell)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "100" }
        )

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)
        flush(mounted)

        let updatedListHost = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap {
                    $0 as? GenotypeSupportedAllelesListHostView
                }
                .first
        )
        XCTAssertTrue(updatedListHost === listHost)
        XCTAssertTrue(updatedListHost.tableView === table)
        XCTAssertTrue(
            (updatedListHost.tableView.delegate as AnyObject?)
                === coordinator
        )
        let visibleHeaders = descendants(of: updatedListHost)
            .compactMap { $0 as? NSTextField }
            .filter {
                $0.accessibilityIdentifier()
                    .hasPrefix("supported-alleles-header-")
                    && !$0.isHidden
            }
        XCTAssertEqual(
            visibleHeaders.map(\.stringValue),
            ["Allele"]
        )
        for header in visibleHeaders {
            XCTAssertGreaterThanOrEqual(
                header.frame.width + 0.5,
                header.intrinsicContentSize.width,
                "\(header.stringValue) header is horizontally clipped"
            )
            XCTAssertGreaterThanOrEqual(
                header.frame.height + 0.5,
                header.intrinsicContentSize.height,
                "\(header.stringValue) header is vertically clipped"
            )
        }
        let compactCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let fields = descendants(of: compactCell)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }
        let allele = try XCTUnwrap(
            fields.first { $0.stringValue == "Allele 0" }
        )
        let support = try XCTUnwrap(
            fields.first { $0.stringValue == "Read support: 100" }
        )
        XCTAssertEqual(
            compactCell.accessibilityLabel(),
            "Allele 0, read support 100."
        )
        XCTAssertLessThan(support.frame.maxY, allele.frame.minY)
    }

    func testInlineTableUsesScaledLineMetricsWithoutClipping()
        throws
    {
        let notifications = NotificationCenter()
        let preference = MutableSupportedAllelesTextSizePreference(.custom(200))
        let provider = MutableSupportedAllelesPreferredFonts(pointSize: 13)
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        var rows = makeRows(count: 1_001)
        rows[0] = GenotypeSupportedAllelePresentation(
            id: "qualified",
            allele: "Mafa-A1*007:08:01:01_1nt_nov",
            readSupport: "[42]",
            qualifiers: [
                "Provisional exon 2",
                "False positive",
                "Cell comment",
            ],
            readSupportIsSecondary: true,
            readSupportIsItalic: true,
            semanticAccessibilityDetails:
                "Designation: Provisional exon 2. Review: false positive."
        )
        let body = typography.resolvedNSFont(for: .body)
        let caption = typography.resolvedNSFont(for: .caption)
        let host = NSHostingView(rootView:
            GenotypeSupportedAllelesVirtualizedList(
                rows: rows,
                bodyFont: body,
                captionFont: caption
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 519, height: 360)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(
            descendants(of: host).compactMap { $0 as? NSTableView }.first
        )
        XCTAssertEqual(table.numberOfRows, 1_001)
        let cell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        cell.layoutSubtreeIfNeeded()

        let requiredHeight = ceil(
            body.boundingRectForFont.height
                + caption.boundingRectForFont.height
                + 1
                + 8
        )
        XCTAssertGreaterThanOrEqual(
            table.rect(ofRow: 0).height,
            requiredHeight
        )
        for field in descendants(of: cell)
            .compactMap({ $0 as? NSTextField })
            .filter({ !$0.isHidden }) {
            let frame = field.convert(field.bounds, to: cell)
            XCTAssertGreaterThanOrEqual(frame.minY, cell.bounds.minY - 0.5)
            XCTAssertLessThanOrEqual(frame.maxY, cell.bounds.maxY + 0.5)
        }
    }

    func testListHeightPolicyUsesFiniteWorkbenchHeight() {
        XCTAssertEqual(
            GenotypeSupportedAllelesListHeightPolicy.height(
                availableHeight: nil,
                compact: false
            ),
            360
        )
        XCTAssertEqual(
            GenotypeSupportedAllelesListHeightPolicy.height(
                availableHeight: 120,
                compact: true
            ),
            160
        )
        XCTAssertEqual(
            GenotypeSupportedAllelesListHeightPolicy.height(
                availableHeight: 240,
                compact: true
            ),
            240
        )
        XCTAssertEqual(
            GenotypeSupportedAllelesListHeightPolicy.height(
                availableHeight: 120,
                compact: false
            ),
            280
        )
        XCTAssertEqual(
            GenotypeSupportedAllelesListHeightPolicy.height(
                availableHeight: 900,
                compact: false
            ),
            480
        )
    }

    func testIdenticalUpdateDoesNotReloadInlineTable() throws {
        let snapshot = GenotypeSupportedAllelesSnapshot(
            rows: makeRows(count: 1_001)
        )
        let mounted = mount(
            GenotypeSupportedAllelesPanel(snapshot: snapshot),
            width: 620
        )
        defer { close(mounted) }
        let table = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap { $0 as? NSTableView }
                .first
        )
        let listHost = try XCTUnwrap(
            descendants(of: mounted.host)
                .compactMap {
                    $0 as? GenotypeSupportedAllelesListHostView
                }
                .first
        )
        let baselineReloadCount = listHost.reloadCount

        mounted.host.rootView = GenotypeSupportedAllelesPanel(
            snapshot: snapshot
        )
        flush(mounted)

        XCTAssertEqual(listHost.reloadCount, baselineReloadCount)
        XCTAssertEqual(table.numberOfRows, 1_001)
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
