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
        let selected = AlignedRead(name: "selected", flag: 0, chromosome: "chr1", position: 15, mapq: 60, cigar: [.init(op: .match, length: 4)], sequence: "ACTG", qualities: [30, 30, 30, 30])
        viewer.viewerView.testSetCachedPackedReads([(0, selected)])
        viewer.viewerView.testSetSelectedReadIDs([selected.id])
        let initialController = viewer

        viewer.updateDetachedAlignmentSettings(minMapQ: 30, excludeFlags: 0xD04)

        XCTAssertTrue(initialController === viewer)
        XCTAssertEqual(viewer.referenceFrame?.start, 12)
        XCTAssertEqual(viewer.referenceFrame?.end, 34)
        XCTAssertEqual(viewer.viewerView.testSelectedReadIDs, [selected.id])
    }

    func testThreeRapidDisplaysCancelSupersededValidationAndOnlyShowLatestSource() async throws {
        let files = try DetachedEvidenceFiles()
        let gate = DetachedHeaderGate()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { url in
                await gate.wait(for: url)
                if Task.isCancelled {
                    await gate.recordCancellation(url)
                    throw CancellationError()
                }
                return "@SQ\tSN:chr1\tLN:4\n"
            },
            indexQuery: { _, _, _ in },
            fileManager: .default
        )
        let controller = ClassifierAlignmentEvidenceViewportController(validator: validator)
        _ = controller.viewController.view
        let requests = try [files.request("one"), files.request("two"), files.request("three")]

        controller.display(requests[0]); await Task.yield()
        controller.display(requests[1]); await Task.yield()
        controller.display(requests[2]); await Task.yield()
        await gate.release(requests[0].bamURL)
        await gate.release(requests[1].bamURL)
        await gate.release(requests[2].bamURL)
        for _ in 0..<100 { if controller.viewer.viewerView.testDetachedAlignmentSource?.identityURL == requests[2].bamURL { break }; await Task.yield() }

        let cancelled = await gate.cancelledURLs()
        XCTAssertEqual(cancelled, Set(requests.prefix(2).map(\.bamURL)))
        XCTAssertEqual(controller.viewer.viewerView.testDetachedAlignmentSource?.identityURL, requests[2].bamURL)
        XCTAssertEqual(controller.availability, .available(reference: .notProvided, reason: nil))
        XCTAssertEqual(controller.status, .available(referenceStrength: "notProvided", reason: nil))
        XCTAssertEqual(controller.visibleStatusText, "Alignment evidence ready (reference: notProvided).")
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

private actor DetachedHeaderGate {
    private var continuations: [URL: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<URL> = []
    private var cancelled: Set<URL> = []
    func wait(for url: URL) async {
        if released.remove(url) != nil { return }
        await withCheckedContinuation { continuations[url] = $0 }
    }
    func recordCancellation(_ url: URL) { cancelled.insert(url) }
    func cancelledURLs() -> Set<URL> { cancelled }
    func release(_ url: URL) {
        if let continuation = continuations.removeValue(forKey: url) { continuation.resume() }
        else { released.insert(url) }
    }
}

private final class DetachedEvidenceFiles {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func request(_ name: String) throws -> ClassifierAlignmentEvidenceRequest {
        let bam = directory.appendingPathComponent("\(name).bam")
        let index = directory.appendingPathComponent("\(name).bam.bai")
        try Data([1]).write(to: bam); try Data([2]).write(to: index)
        return try .init(workflow: .taxTriage, resultIdentity: .init(stableID: name, finalResultURL: directory, provenanceID: name), bamURL: bam, index: .init(url: index, kind: .bai), sample: .init(canonicalID: name), contig: .init(name: "chr1", expectedLength: 4), referenceCandidate: nil, presentation: .init(workflowLabel: "T", resultLabel: name, sampleLabel: name, contigLabel: "chr1"))
    }
}
