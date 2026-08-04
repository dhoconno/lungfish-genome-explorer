import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeSampleDetailSheetTests: XCTestCase {
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
            onSaveOverride: { _, _ in },
            onClearOverride: { _ in },
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
