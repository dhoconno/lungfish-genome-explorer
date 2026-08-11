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

    func testEvidenceChangedBetweenValidationAndInstallationIsRejected() async throws {
        let files = try DetachedEvidenceFiles()
        let request = try files.request("installation-race")
        let gate = DetachedHeaderGate()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { url in
                await gate.wait(for: url)
                return "@SQ\tSN:chr1\tLN:4\n"
            },
            indexQuery: { _, _, _ in },
            fileManager: .default
        )
        let controller = ClassifierAlignmentEvidenceViewportController(validator: validator)

        controller.display(request)
        await gate.waitUntilEntered(request.bamURL)
        try Data([9]).write(to: request.bamURL)
        await gate.release(request.bamURL)
        for _ in 0..<100 where controller.status == .loading {
            await Task.yield()
        }

        let reason = "Classifier alignment evidence changed on disk: installation-race.bam."
        XCTAssertNil(controller.viewer.viewerView.testDetachedAlignmentSource)
        XCTAssertEqual(controller.status, .stale(reason))
        XCTAssertEqual(controller.visibleStatusText, reason)
    }

    func testSameSizeRestoredMTimeReplacementIsDetectedByEvidenceMonitor() async throws {
        let files = try DetachedEvidenceFiles()
        let request = try files.request("changed")
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in },
            fileManager: .default
        )
        let controller = ClassifierAlignmentEvidenceViewportController(validator: validator)
        controller.display(request)
        for _ in 0..<100 where controller.viewer.viewerView.testDetachedAlignmentSource == nil {
            await Task.yield()
        }
        guard let source = controller.viewer.viewerView.testDetachedAlignmentSource else {
            return XCTFail("Validated detached source was not installed")
        }
        controller.viewer.viewerView.testSetCachedAlignedReads([
            AlignedRead(name: "cached", flag: 0, chromosome: "chr1", position: 0, mapq: 60, cigar: [.init(op: .match, length: 1)], sequence: "A", qualities: [30])
        ])

        let originalAttributes = try FileManager.default.attributesOfItem(atPath: request.bamURL.path)
        let originalMTime = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        try Data([9]).write(to: request.bamURL) // same byte count as the validated payload
        try FileManager.default.setAttributes([.modificationDate: originalMTime], ofItemAtPath: request.bamURL.path)

        for _ in 0..<250 where controller.status != .stale("Classifier alignment evidence changed on disk: changed.bam.") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reason = "Classifier alignment evidence changed on disk: changed.bam."
        XCTAssertEqual(controller.viewer.viewerView.detachedEvidenceStaleReason, reason)
        XCTAssertEqual(controller.status, .stale(reason))
        XCTAssertEqual(controller.visibleStatusText, reason)
        XCTAssertTrue(controller.viewer.viewerView.testCachedAlignedReads.isEmpty)
        XCTAssertGreaterThan(controller.viewer.viewerView.testDetachedEvidenceMonitorEventCount, 0)
    }

    func testClearCancelsRetainedDetachedReadAndDepthTasks() async {
        let view = SequenceViewerView(frame: .zero)
        let readProbe = CancellationProbe()
        let depthProbe = CancellationProbe()
        view.testInstallDetachedAlignmentFetchTasks(
            read: makeCancellationTask(readProbe),
            depth: makeCancellationTask(depthProbe)
        )

        view.clearReferenceBundle()
        await waitForCancellation(readProbe, depthProbe)

        XCTAssertTrue(readProbe.cancelled)
        XCTAssertTrue(depthProbe.cancelled)
    }

    func testSourceReplacementCancelsRetainedDetachedReadAndDepthTasks() async {
        let view = SequenceViewerView(frame: .zero)
        view.setDetachedAlignmentSource(makeSource("old"))
        let readProbe = CancellationProbe()
        let depthProbe = CancellationProbe()
        view.testInstallDetachedAlignmentFetchTasks(
            read: makeCancellationTask(readProbe),
            depth: makeCancellationTask(depthProbe)
        )

        view.setDetachedAlignmentSource(makeSource("replacement"))
        await waitForCancellation(readProbe, depthProbe)

        XCTAssertTrue(readProbe.cancelled)
        XCTAssertTrue(depthProbe.cancelled)
    }

    private func makeCancellationTask(_ probe: CancellationProbe) -> Task<Void, Never> {
        Task.detached {
            await withTaskCancellationHandler(operation: {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }, onCancel: {
                probe.recordCancellation()
            })
        }
    }

    private func waitForCancellation(_ read: CancellationProbe, _ depth: CancellationProbe) async {
        for _ in 0..<200 where !(read.cancelled && depth.cancelled) {
            await Task.yield()
        }
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

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func recordCancellation() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private actor DetachedHeaderGate {
    private var continuations: [URL: CheckedContinuation<Void, Never>] = [:]
    private var enteredContinuations: [URL: CheckedContinuation<Void, Never>] = [:]
    private var entered: Set<URL> = []
    private var released: Set<URL> = []
    private var cancelled: Set<URL> = []
    func wait(for url: URL) async {
        entered.insert(url)
        enteredContinuations.removeValue(forKey: url)?.resume()
        if released.remove(url) != nil { return }
        await withCheckedContinuation { continuations[url] = $0 }
    }
    func waitUntilEntered(_ url: URL) async {
        if entered.contains(url) { return }
        await withCheckedContinuation { enteredContinuations[url] = $0 }
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
