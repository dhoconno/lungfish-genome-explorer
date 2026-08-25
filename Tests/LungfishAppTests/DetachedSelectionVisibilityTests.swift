import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO
@testable import LungfishKit

/// A user interval (column) selection must be visible in the detached BAM
/// viewer. Reported against 2026.8.10: dragging an interval in classifier
/// alignment evidence selected the range (centering and extraction saw it)
/// but drew nothing — the detached draw path never painted the
/// column-selection overlay that bundle viewports always paint.
@MainActor
final class DetachedSelectionVisibilityTests: XCTestCase {

    func testUserColumnSelectionIsVisibleInDetachedViewer() async throws {
        let (viewer, _, region) = try await makeViewerWithOneFetchedRead()
        let frame = try XCTUnwrap(viewer.referenceFrame)
        preparePackedLayoutSynchronously(viewer.viewerView, region: region, frame: frame)

        let view = try XCTUnwrap(viewer.viewerView)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        let baseline = renderToBitmap(view)

        // Exactly the state SequenceViewerView.mouseDown/mouseDragged set for
        // a drag interval selection (the "no object hit" path).
        view.columnDragStartBase = 20
        view.isUserColumnSelection = true
        view.selectionRange = 20..<60
        view.isSelecting = false

        let selected = renderToBitmap(view)

        let differingColumns = differingPixelColumns(baseline, selected)
        XCTAssertFalse(
            differingColumns.isEmpty,
            "an interval selection must change rendered pixels in the detached BAM viewer"
        )

        // The overlay must be where the selection is: every changed column
        // sits inside the selected interval's pixel span (with a 2px stroke
        // tolerance).
        let startX = Int(frame.genomicToPixel(20).rounded(.down)) - 2
        let endX = Int(frame.genomicToPixel(60).rounded(.up)) + 2
        let outliers = differingColumns.filter { $0 < startX || $0 > endX }
        XCTAssertTrue(
            outliers.isEmpty,
            "selection overlay must be confined to the selected interval; changed columns outside \(startX)...\(endX): \(outliers.prefix(5))"
        )
    }

    private func renderToBitmap(_ view: SequenceViewerView) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// X coordinates (view space) of columns containing at least one pixel
    /// that differs between the two renders.
    private func differingPixelColumns(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [Int] {
        guard let da = a.bitmapData, let db = b.bitmapData else { return [] }
        let bytesPerPixel = a.bitsPerPixel / 8
        var columns: Set<Int> = []
        for y in 0..<a.pixelsHigh {
            let rowA = da + y * a.bytesPerRow
            let rowB = db + y * b.bytesPerRow
            for x in 0..<a.pixelsWide where memcmp(rowA + x * bytesPerPixel, rowB + x * bytesPerPixel, bytesPerPixel) != 0 {
                columns.insert(x)
            }
        }
        return columns.sorted()
    }

    // Mirrors DetachedAlignmentViewerTests.makeViewerWithOneFetchedRead.
    private func makeViewerWithOneFetchedRead() async throws -> (ViewerViewController, SequenceViewerView.DetachedAlignmentSource, GenomicRegion) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detached-selvis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "-c" ]; then printf '1\\n'; exit 0; fi
        done
        printf 'selected\\t0\\tchr1\\t11\\t60\\t4M\\t*\\t0\\t0\\tACTG\\t????\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let bam = directory.appendingPathComponent("evidence.bam")
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: bam,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: bam.path, indexPath: "\(bam.path).bai", samtoolsPath: script.path),
            referenceSequence: nil
        )
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayDetachedAlignment(source)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)
        viewer.viewerView.fetchDetachedReads(source: source, region: region)
        for _ in 0..<250 where viewer.viewerView.testCachedAlignedReads.count != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (viewer, source, region)
    }

    @MainActor
    private func preparePackedLayoutSynchronously(
        _ view: SequenceViewerView,
        region: GenomicRegion,
        frame: ReferenceFrame
    ) {
        let result = view.prepareDetachedReadLayout(region: region, frame: frame)
        view.testDrainPendingPack(
            reads: view.testCachedAlignedReads.filter { $0.chromosome == region.chromosome },
            frame: ReadPackFrame(frame),
            maxRows: result.maxRows,
            prioritizedRegion: region.start..<region.end
        )
    }
}
