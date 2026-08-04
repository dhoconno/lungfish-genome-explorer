import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSampleDetailSheetTests: XCTestCase {
    func testRenderedSaveRetainsDraftAndFocusUntilChangedSuccess() throws {
        for outcome in [
            GenotypeHaplotypeMutationOutcome.unchanged,
            .failure,
            .changed,
        ] {
            var savedDrafts: [GenotypeOverrideSection.OverrideDraft] = []
            let mounted = mountSheet(
                saveOutcome: outcome,
                clearOutcome: .failure,
                onSave: { savedDrafts.append($0) }
            )
            defer { mounted.window.close() }
            try button(
                "genotype-sample-detail-edit-MHC-A-h1",
                in: mounted.host
            ).performClick(nil)
            flush(mounted.host)
            let save = try button(
                "genotypeOverrideSaveButton",
                in: mounted.host
            )
            XCTAssertTrue(mounted.window.makeFirstResponder(save))

            save.performClick(nil)
            flush(mounted.host)

            XCTAssertEqual(savedDrafts, [.init(
                target: "M3A",
                reason: .misCall,
                rationale: "Rendered sheet draft"
            )])
            if outcome == .changed {
                XCTAssertNil(
                    buttonIfPresent(
                        "genotypeOverrideSaveButton",
                        in: mounted.host
                    )
                )
            } else {
                let retainedSave = try button(
                    "genotypeOverrideSaveButton",
                    in: mounted.host
                )
                XCTAssertTrue(retainedSave === save)
                XCTAssertTrue(mounted.window.firstResponder === save)
                retainedSave.performClick(nil)
                flush(mounted.host)
                XCTAssertEqual(savedDrafts.count, 2)
                XCTAssertEqual(savedDrafts[0], savedDrafts[1])
            }
        }
    }

    func testRenderedRestoreFailureRetainsOpenDraftAndFocus() throws {
        var clearCount = 0
        let mounted = mountSheet(
            saveOutcome: .failure,
            clearOutcome: .failure,
            onClear: { clearCount += 1 }
        )
        defer { mounted.window.close() }
        try button(
            "genotype-sample-detail-edit-MHC-A-h1",
            in: mounted.host
        ).performClick(nil)
        flush(mounted.host)
        let restore = try button(
            "genotype-sample-detail-restore-MHC-A-h1",
            in: mounted.host
        )
        XCTAssertTrue(mounted.window.makeFirstResponder(restore))

        restore.performClick(nil)
        flush(mounted.host)

        XCTAssertEqual(clearCount, 1)
        XCTAssertNotNil(
            try? button("genotypeOverrideSaveButton", in: mounted.host)
        )
        XCTAssertTrue(
            try button(
                "genotype-sample-detail-restore-MHC-A-h1",
                in: mounted.host
            ) === restore
        )
        XCTAssertTrue(mounted.window.firstResponder === restore)
    }

    func testContentTypographyModelUpdatesSheetMetricsWithoutChangingRows() {
        let notifications = NotificationCenter()
        let preference = MutableSampleDetailTextSizePreference(.custom(100))
        let provider = MutableSampleDetailPreferredFonts(pointSize: 13)
        let model = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let rows = [
            GenotypeSampleDetailSheet.CallRow(
                locus: "MHC-A",
                slot: .h1,
                callName: "M1A",
                status: .called,
                source: .pipeline,
                observedGenotypeCount: 2
            ),
        ]
        let view = GenotypeSampleDetailSheet(
            sampleId: "DW472",
            rows: rows,
            overrides: [],
            allowedTargetsForLocus: { _ in [] },
            onSaveOverride: { _, _ in .unchanged },
            onClearOverride: { _ in .unchanged },
            onDismiss: {},
            typographyModel: model
        )
        let baseline = view.testingContentTypographyPointSizes

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(view.testingContentTypographyPointSizes.body, baseline.body * 2, accuracy: 0.01)
        XCTAssertEqual(view.testingContentTypographyPointSizes.caption, baseline.caption * 2, accuracy: 0.01)
        XCTAssertEqual(view.rows, rows)
    }

    func testSheetUsesAdaptiveRowsAndSharedContentTypography() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeSampleDetailSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("typographyModel.font(for:"))
    }

    private typealias MountedSheet = (
        window: NSWindow,
        host: NSHostingView<GenotypeSampleDetailSheet>
    )

    private func mountSheet(
        saveOutcome: GenotypeHaplotypeMutationOutcome,
        clearOutcome: GenotypeHaplotypeMutationOutcome,
        onSave: @escaping (
            GenotypeOverrideSection.OverrideDraft
        ) -> Void = { _ in },
        onClear: @escaping () -> Void = {}
    ) -> MountedSheet {
        let row = GenotypeSampleDetailSheet.CallRow(
            locus: "MHC-A",
            slot: .h1,
            callName: "M3A",
            status: .called,
            source: .analystOverride,
            observedGenotypeCount: 2
        )
        let override = GenotypeAnnotationSidecar.CallOverride(
            sample: "DW472",
            locus: row.locus,
            slot: row.slot,
            originalCall: "M1A",
            overrideCall: "M3A",
            reasonTag: .misCall,
            rationale: "Rendered sheet draft",
            author: "Reviewer",
            timestamp: "2026-08-04T00:00:00Z"
        )
        let host = NSHostingView(rootView: GenotypeSampleDetailSheet(
            sampleId: "DW472",
            rows: [row],
            overrides: [override],
            allowedTargetsForLocus: { _ in ["M1A", "M3A"] },
            onSaveOverride: { _, draft in
                onSave(draft)
                return saveOutcome
            },
            onClearOverride: { _ in
                onClear()
                return clearOutcome
            },
            onDismiss: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
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

    private func button(
        _ identifier: String,
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSButton {
        let buttons = descendants(of: root).compactMap { $0 as? NSButton }
        let summaries = buttons.map {
            [$0.title, $0.accessibilityIdentifier(),
             $0.accessibilityLabel() ?? ""].joined(separator: "|")
        }
        return try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == identifier },
            "Missing \(identifier); buttons=\(summaries)",
            file: file,
            line: line
        )
    }

    private func buttonIfPresent(
        _ identifier: String,
        in root: NSView
    ) -> NSButton? {
        descendants(of: root).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class MutableSampleDetailTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class MutableSampleDetailPreferredFonts: ContentPreferredFontProviding {
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
