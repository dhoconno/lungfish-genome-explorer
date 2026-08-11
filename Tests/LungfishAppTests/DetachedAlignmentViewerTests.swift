import XCTest
@testable import LungfishApp
@testable import LungfishKit
@testable import LungfishIO

@MainActor
final class DetachedAlignmentViewerTests: XCTestCase {
    func testDetachedSourceUsesRealViewerProviderAndNoReferenceBundle() throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: URL(fileURLWithPath: "/tmp/final-classifier.bam"),
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: "/tmp/final-classifier.bam", indexPath: "/tmp/final-classifier.bam.bai"),
            referenceSequence: nil
        )

        viewer.displayDetachedAlignment(source)

        XCTAssertNil(viewer.currentReferenceBundle)
        XCTAssertEqual(viewer.viewerView.testDetachedAlignmentSource?.provider.alignmentPath, source.provider.alignmentPath)
        XCTAssertEqual(viewer.viewerView.excludeFlagsSetting, 0xD04)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/final-classifier.lungfishref"))
    }

    func testSettingsUpdatePreservesControllerLocusZoomAndSelection() throws {
        let viewer = ViewerViewController(); _ = viewer.view
        let source = makeSource("one")
        viewer.displayDetachedAlignment(source)
        viewer.referenceFrame?.start = 12
        viewer.referenceFrame?.end = 34
        let initialController = viewer

        viewer.updateDetachedAlignmentSettings(minMapQ: 30, excludeFlags: 0xD04)

        XCTAssertTrue(initialController === viewer)
        XCTAssertEqual(viewer.referenceFrame?.start, 12)
        XCTAssertEqual(viewer.referenceFrame?.end, 34)
    }

    private func makeSource(_ suffix: String) -> SequenceViewerView.DetachedAlignmentSource {
        let bam = URL(fileURLWithPath: "/tmp/final-\(suffix).bam")
        return .init(
            identityURL: bam,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: bam.path, indexPath: "\(bam.path).bai"),
            referenceSequence: nil
        )
    }
}
