import CryptoKit
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

    func testSettingsRefetchAndRenderPreserveOnlySecondOfTwoIdenticalAlignments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "-c" ]; then printf '2\\n'; exit 0; fi
        done
        printf 'duplicate\\t0\\tchr1\\t11\\t60\\t4M\\t*\\t0\\t0\\tACTG\\t????\\n'
        printf 'duplicate\\t0\\tchr1\\t11\\t60\\t4M\\t*\\t0\\t0\\tACTG\\t????\\n'
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
        for _ in 0..<250 where viewer.viewerView.testCachedAlignedReads.count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let frame = try XCTUnwrap(viewer.referenceFrame)
        preparePackedLayoutSynchronously(viewer.viewerView, region: region, frame: frame)
        let initiallyPacked = viewer.viewerView.testCachedPackedReads
        guard initiallyPacked.count == 2 else { return XCTFail("Detached fetch did not reach the renderer") }
        let selectedSecondID = initiallyPacked[1].1.id
        viewer.viewerView.testSetSelectedReadIDs([selectedSecondID])

        viewer.updateDetachedAlignmentSettings(minMapQ: 1, excludeFlags: 0xD04)
        viewer.updateDetachedAlignmentSettings(minMapQ: 2, excludeFlags: 0xD04)
        viewer.viewerView.fetchDetachedReads(source: source, region: region)
        for _ in 0..<250 where viewer.viewerView.testCachedAlignedReads.count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preparePackedLayoutSynchronously(viewer.viewerView, region: region, frame: frame)

        let reparsedPacked = viewer.viewerView.testCachedPackedReads
        guard reparsedPacked.count == 2 else { return XCTFail("Detached refetch did not reach the renderer") }
        XCTAssertEqual(viewer.viewerView.testSelectedReadIDs, [reparsedPacked[1].1.id])
    }

    func testSettingsRefetchClearsMissingSelectedReadFromViewerAndBoundInspector() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mode = directory.appendingPathComponent("mode")
        try "reads".write(to: mode, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        if [ "$(cat '\(mode.path)')" = "empty" ]; then
          for argument in "$@"; do if [ "$argument" = "-c" ]; then printf '0\\n'; fi; done
          exit 0
        fi
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
        let inspector = InspectorViewController()
        _ = viewer.view
        _ = inspector.view
        viewer.displayDetachedAlignment(source)
        inspector.updateClassifierAlignmentInspector(
            capabilities: .detachedEvidence(
                workflow: "TaxTriage", result: "result", sample: "S1", contig: "chr1",
                bamPath: bam.path, indexPath: "\(bam.path).bai", referenceValidation: .absent, readGroups: []
            ),
            applySettings: viewer.applyReadDisplaySettings
        )
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 100)
        let frame = try XCTUnwrap(viewer.referenceFrame)

        viewer.viewerView.fetchDetachedReads(source: source, region: region)
        for _ in 0..<250 where viewer.viewerView.testCachedAlignedReads.count != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preparePackedLayoutSynchronously(viewer.viewerView, region: region, frame: frame)
        let selected = try XCTUnwrap(viewer.viewerView.testCachedPackedReads.first?.1)
        viewer.viewerView.testSetSelectedReadIDs([selected.id])
        NotificationCenter.default.post(name: .readSelected, object: viewer.viewerView, userInfo: [NotificationUserInfoKey.alignedRead: selected])
        XCTAssertEqual(inspector.readStyleSectionViewModel.selectedRead?.id, selected.id)

        try "empty".write(to: mode, atomically: true, encoding: .utf8)
        viewer.updateDetachedAlignmentSettings(minMapQ: 1, excludeFlags: 0xD04)
        viewer.updateDetachedAlignmentSettings(minMapQ: 2, excludeFlags: 0xD04)
        viewer.viewerView.fetchDetachedReads(source: source, region: region)
        for _ in 0..<250 where viewer.viewerView.testIsFetchingReads || !viewer.viewerView.testCachedAlignedReads.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(viewer.viewerView.testSelectedReadIDs.isEmpty)
        XCTAssertNil(inspector.readStyleSectionViewModel.selectedRead)
    }

    /// One synthetic read served by a fake samtools; returns after the fetch
    /// has landed so callers can pack and draw deterministically.
    @MainActor
    private func makeViewerWithOneFetchedRead() async throws -> (ViewerViewController, SequenceViewerView.DetachedAlignmentSource, GenomicRegion) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detached-hittest-\(UUID().uuidString)", isDirectory: true)
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

    /// Read clicks in the detached (classifier evidence) viewer must hit-test:
    /// the draw path forgot to store `readContentHeight`, so `readAtPoint`
    /// computed a zero-height clickable area and every click fell through to
    /// 1 bp sequence selection (reported against EsViritu on 2026-08-23).
    func testDetachedReadHitTestFindsAReadAfterDrawing() async throws {
        let (viewer, source, region) = try await makeViewerWithOneFetchedRead()
        let frame = try XCTUnwrap(viewer.referenceFrame)
        preparePackedLayoutSynchronously(viewer.viewerView, region: region, frame: frame)
        _ = source

        // Render into an offscreen context so the draw path publishes its
        // layout geometry (lastRenderedReadY, readContentHeight, tier).
        let view = try XCTUnwrap(viewer.viewerView)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
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

        XCTAssertGreaterThan(view.testReadContentHeight, 0, "the detached draw must publish the read content height")
        let read = try XCTUnwrap(view.testCachedPackedReads.first?.1)
        let midX = CGFloat((frame.genomicToPixel(Double(read.position)) + frame.genomicToPixel(Double(read.alignmentEnd))) / 2)
        let y = view.testLastRenderedReadY + 2
        XCTAssertEqual(view.testReadAtPoint(NSPoint(x: midX, y: y))?.id, read.id,
                       "a click on the drawn read must hit-test to that read")
    }

    /// Async packing means `prepareDetachedReadLayout` only queues a background
    /// pack; drain it so assertions see the resulting layout (same seam
    /// `ReadLayoutCacheTests` uses).
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

    func testSourceReplacementDoesNotRestorePendingSelectionWithMatchingReadIdentity() throws {
        let viewer = ViewerViewController()
        let inspector = InspectorViewController()
        _ = viewer.view
        _ = inspector.view
        let sourceA = makeSource("selection-source-a")
        let sourceB = makeSource("selection-source-b")
        viewer.displayDetachedAlignment(sourceA)
        inspector.updateClassifierAlignmentInspector(
            capabilities: .detachedEvidence(
                workflow: "TaxTriage", result: "result-a", sample: "S1", contig: "chr1",
                bamPath: sourceA.provider.alignmentPath, indexPath: sourceA.provider.indexPath,
                referenceValidation: .absent, readGroups: []
            ),
            applySettings: viewer.applyReadDisplaySettings
        )

        let sourceARead = AlignedRead(
            name: "same-read", flag: 0, chromosome: "chr1", position: 15, mapq: 60,
            cigar: [.init(op: .match, length: 4)], sequence: "ACTG", qualities: [30, 30, 30, 30]
        )
        viewer.viewerView.testSetCachedPackedReads([(0, sourceARead)])
        viewer.viewerView.testSetSelectedReadIDs([sourceARead.id])
        NotificationCenter.default.post(
            name: .readSelected,
            object: viewer.viewerView,
            userInfo: [NotificationUserInfoKey.alignedRead: sourceARead]
        )
        XCTAssertEqual(inspector.readStyleSectionViewModel.selectedRead?.id, sourceARead.id)

        viewer.updateDetachedAlignmentSettings(minMapQ: 20, excludeFlags: 0xD04)
        viewer.displayDetachedAlignment(sourceB)
        let sourceBRead = AlignedRead(
            name: "same-read", flag: 0, chromosome: "chr1", position: 15, mapq: 60,
            cigar: [.init(op: .match, length: 4)], sequence: "ACTG", qualities: [30, 30, 30, 30]
        )
        viewer.viewerView.testSetCachedPackedReads([(0, sourceBRead)])

        XCTAssertTrue(viewer.viewerView.testSelectedReadIDs.isEmpty)
        XCTAssertNil(inspector.readStyleSectionViewModel.selectedRead)
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
        XCTAssertEqual(controller.status, .available(referenceStrength: "not provided", reason: nil))
        XCTAssertEqual(controller.visibleStatusText, "Alignment evidence ready (reference: not provided).")
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

    func testPreviouslyValidatedInstallationDoesNotSynchronouslyRescanEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("evidence.bam")
        let index = directory.appendingPathComponent("evidence.bam.bai")
        try Data(repeating: 0xA5, count: 1 << 20).write(to: bam)
        try Data([0x01]).write(to: index)
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: bam,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: bam.path, indexPath: index.path),
            referenceSequence: nil,
            // A direct install is only reached after validator-owned snapshot
            // validation. A mismatching witness must therefore not be reread
            // synchronously on the main actor during installation.
            bamSnapshot: .init(size: 1, sha256: "stale"),
            indexSnapshot: .init(size: 1, sha256: "stale")
        )
        let viewer = ViewerViewController()
        _ = viewer.view

        XCTAssertTrue(viewer.displayDetachedAlignment(source))
        XCTAssertEqual(viewer.viewerView.testDetachedAlignmentSource?.identityURL, bam)
    }

    func testNewDisplaySynchronouslyClearsInstalledEvidenceWhileValidationWaits() async throws {
        let files = try DetachedEvidenceFiles()
        let first = try files.request("installed")
        let second = try files.request("pending")
        let gate = DetachedHeaderGate()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { url in
                if url == second.bamURL { await gate.wait(for: url) }
                return "@SQ\tSN:chr1\tLN:4\n"
            }, indexQuery: { _, _, _ in }, fileManager: .default
        )
        let controller = ClassifierAlignmentEvidenceViewportController(validator: validator)
        controller.display(first)
        for _ in 0..<100 where controller.viewer.viewerView.testDetachedAlignmentSource == nil { await Task.yield() }
        XCTAssertEqual(controller.viewer.viewerView.testDetachedAlignmentSource?.identityURL, first.bamURL)

        controller.display(second)
        await gate.waitUntilEntered(second.bamURL)

        XCTAssertNil(controller.viewer.viewerView.testDetachedAlignmentSource)
        XCTAssertEqual(controller.status, .loading)
        await gate.release(second.bamURL)
    }

    func testClearCancelsPendingValidationAndPreventsLaterStatusOrInspectorPublication() async throws {
        let files = try DetachedEvidenceFiles()
        let request = try files.request("navigation-pending")
        let gate = DetachedHeaderGate()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { url in
                await gate.wait(for: url)
                if Task.isCancelled {
                    await gate.recordCancellation(url)
                    throw CancellationError()
                }
                return "@SQ\tSN:chr1\tLN:4\n"
            }, indexQuery: { _, _, _ in }, fileManager: .default
        )
        let controller = ClassifierAlignmentEvidenceViewportController(validator: validator)
        var statuses: [ClassifierAlignmentViewerStatus] = []
        var capabilities: [ClassifierAlignmentInspectorCapabilities?] = []
        controller.onStatusChanged = { statuses.append($0) }
        controller.onInspectorCapabilitiesChanged = { capabilities.append($0) }

        controller.display(request)
        await gate.waitUntilEntered(request.bamURL)
        controller.clear()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNil(controller.inspectorCapabilities)
        await gate.release(request.bamURL)
        for _ in 0..<20 { await Task.yield() }

        let cancelled = await gate.cancelledURLs()
        XCTAssertEqual(cancelled, [request.bamURL])
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNil(controller.inspectorCapabilities)
        XCTAssertEqual(statuses.last, .idle)
        XCTAssertNil(capabilities.last!)
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
        guard controller.viewer.viewerView.testDetachedAlignmentSource != nil else {
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

    func testReadGroupFilterSuppressesCoverageAndRemovingItResumesDepth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("samtools")
        try "#!/bin/sh\nprintf 'chr1\\t1\\t5\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: directory.appendingPathComponent("evidence.bam"),
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: "/tmp/evidence.bam", indexPath: "/tmp/evidence.bam.bai", samtoolsPath: script.path),
            referenceSequence: nil
        )
        let view = SequenceViewerView(frame: .zero)
        view.setDetachedAlignmentSource(source)
        view.selectedReadGroupsSetting = ["rg1"]
        view.fetchDetachedDepth(source: source, region: .init(chromosome: "chr1", start: 0, end: 1))
        XCTAssertTrue(view.testCachedDepthPoints.isEmpty)
        XCTAssertEqual(view.testDetachedEvidenceFetchMessage, "Coverage is unavailable while read-group filtering is active.")

        view.selectedReadGroupsSetting = []
        view.fetchDetachedDepth(source: source, region: .init(chromosome: "chr1", start: 0, end: 1))
        for _ in 0..<250 where view.testCachedDepthPoints.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(view.testCachedDepthPoints.first?.depth, 5)
    }

    func testDetachedDepthRecoveryClearsPriorFailureNotice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mode = directory.appendingPathComponent("mode")
        try "fail".write(to: mode, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        if [ "$(cat '\(mode.path)')" = "fail" ]; then
          echo 'simulated depth failure' >&2
          exit 1
        fi
        printf 'chr1\\t1\\t5\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let bam = directory.appendingPathComponent("evidence.bam")
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: bam,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: bam.path, indexPath: "\(bam.path).bai", samtoolsPath: script.path),
            referenceSequence: nil
        )
        let view = SequenceViewerView(frame: .zero)
        XCTAssertTrue(view.setDetachedAlignmentSource(source))
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 1)

        view.fetchDetachedDepth(source: source, region: region)
        for _ in 0..<250 where view.testDetachedEvidenceFetchMessage == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(view.testDetachedEvidenceFetchMessage?.hasPrefix("Coverage evidence could not be fetched:") == true)

        try "success".write(to: mode, atomically: true, encoding: .utf8)
        view.fetchDetachedDepth(source: source, region: region)
        for _ in 0..<250 where view.testCachedDepthPoints.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(view.testCachedDepthPoints.first?.depth, 5)
        XCTAssertNil(view.testDetachedEvidenceFetchMessage)
    }

    func testSupersededDetachedDepthFailureDoesNotPublishIntoReplacementSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("samtools")
        try "#!/bin/sh\nsleep 1\necho 'late failure' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let firstBAM = directory.appendingPathComponent("first.bam")
        let secondBAM = directory.appendingPathComponent("second.bam")
        let first = SequenceViewerView.DetachedAlignmentSource(
            identityURL: firstBAM,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: firstBAM.path, indexPath: "\(firstBAM.path).bai", samtoolsPath: script.path),
            referenceSequence: nil
        )
        let replacement = SequenceViewerView.DetachedAlignmentSource(
            identityURL: secondBAM,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: secondBAM.path, indexPath: "\(secondBAM.path).bai", samtoolsPath: script.path),
            referenceSequence: nil
        )
        let view = SequenceViewerView(frame: .zero)
        XCTAssertTrue(view.setDetachedAlignmentSource(first))
        view.fetchDetachedDepth(source: first, region: .init(chromosome: "chr1", start: 0, end: 1))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(view.setDetachedAlignmentSource(replacement))

        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(view.testDetachedAlignmentSource?.identityURL, secondBAM)
        XCTAssertNil(view.testDetachedEvidenceFetchMessage)
    }

    func testDetachedReadAndDepthFailuresPublishVisibleFetchMessages() async {
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: URL(fileURLWithPath: "/tmp/missing-evidence.bam"),
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: "/tmp/missing-evidence.bam", indexPath: "/tmp/missing-evidence.bam.bai", samtoolsPath: "/tmp/no-samtools"),
            referenceSequence: nil
        )
        let view = SequenceViewerView(frame: .zero)
        view.setDetachedAlignmentSource(source)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 1)
        view.fetchDetachedReads(source: source, region: region)
        for _ in 0..<200 where view.testDetachedEvidenceFetchMessage == nil { await Task.yield() }
        XCTAssertTrue(view.testDetachedEvidenceFetchMessage?.hasPrefix("Read evidence could not be fetched:") == true)

        view.detachedEvidenceFetchMessage = nil
        view.fetchDetachedDepth(source: source, region: region)
        for _ in 0..<200 where view.testDetachedEvidenceFetchMessage == nil { await Task.yield() }
        XCTAssertTrue(view.testDetachedEvidenceFetchMessage?.hasPrefix("Coverage evidence could not be fetched:") == true)
    }

    func testDetachedTransportCapAppliesWhenRowLimitingIsDisabled() {
        XCTAssertEqual(
            SequenceViewerView.detachedEvidenceTransportTarget(limitRows: false, maxRows: Int.max),
            250_000
        )
        XCTAssertEqual(
            SequenceViewerView.detachedEvidenceTransportTarget(limitRows: true, maxRows: 75),
            75
        )
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

    /// Regression: while the initial off-main snapshot checksum runs, the
    /// viewer draws the "evidence is unavailable" badge. When the check
    /// completes it must invalidate the display itself — before this fix the
    /// badge stuck until an unrelated redraw (observed live with the 240MB
    /// EsViritu reference).
    func testMonitorCheckCompletionInvalidatesTheDisplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("evidence.bam")
        let payload = Data("detached-evidence-payload".utf8)
        try payload.write(to: bam)
        let snapshot = ClassifierAlignmentEvidenceFileSnapshot(
            size: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        )
        let source = SequenceViewerView.DetachedAlignmentSource(
            identityURL: bam,
            contig: .init(name: "chr1", length: 100),
            provider: AlignmentDataProvider(alignmentPath: bam.path, indexPath: "\(bam.path).bai", samtoolsPath: "/usr/bin/true"),
            referenceSequence: nil,
            bamSnapshot: snapshot
        )
        let view = SequenceViewerView(frame: .zero)
        XCTAssertTrue(view.setDetachedAlignmentSource(source))
        XCTAssertFalse(view.detachedEvidenceIsCurrent(source), "evidence must be pending until the first checksum completes")
        let baseline = view.testDisplayInvalidationCount

        var becameCurrent = false
        for _ in 0..<250 {
            if view.detachedEvidenceIsCurrent(source) { becameCurrent = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(becameCurrent, "the monitor check never established the evidence signatures")
        XCTAssertGreaterThan(
            view.testDisplayInvalidationCount, baseline,
            "completing the monitor check must invalidate the display so the pending badge clears"
        )
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
