// SequenceViewerVariantTrackScanOffMainTests.swift - PERF-07 threading regression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 2026-09-23 best-practices audit (concurrency-performance.md, PERF-07). Result/bundle selection
// used to open every variant database and call sampleCount()/allChromosomes() synchronously on
// the main actor inside SequenceViewerView.setReferenceBundle. That work now runs on
// `variantAliasWarmupQueue` (off-main) and commits back to the view only if the bundle is still
// current, mirroring the `warmVariantChromosomeAliasesAsync` pattern already used for the
// expensive alias inference right below it.
//
// This test asserts two things: (1) the scan body actually executes off the main thread (mutation
// -verified: temporarily inlining the old synchronous loop back onto setReferenceBundle's caller
// thread was checked to make this test fail, mirroring the sibling F4 async-bundle-read test's
// documented verification method), and (2) selecting a bundle with a slow-opening variant track
// does not block the main actor — a main-actor probe scheduled immediately after
// `setReferenceBundle` returns must run before the scan completes.
import AppKit
import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishApp

@MainActor
final class SequenceViewerVariantTrackScanOffMainTests: XCTestCase {
    nonisolated(unsafe) private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-variant-scan-off-main-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SequenceViewerView.variantTrackScanThreadingProbe = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testVariantTrackScanRunsOffTheMainThread() throws {
        let bundleURL = try makeReferenceBundleWithVariantTrack()
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        let probe = ThreadObservationBox()
        SequenceViewerView.variantTrackScanThreadingProbe = { [probe] in
            probe.record(isMainThread: Thread.isMainThread)
        }

        viewer.setReferenceBundle(bundle)

        let deadline = Date().addingTimeInterval(5)
        while !probe.fired && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(probe.fired, "Variant track scan probe never fired")
        XCTAssertFalse(probe.wasMainThread, "Variant track scan ran on the main thread")
    }

    func testMainActorIsNotBlockedWhileVariantTrackScanIsInFlight() throws {
        let bundleURL = try makeReferenceBundleWithVariantTrack()
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        // Hold the scan queue busy for a bit so any accidental main-thread work inside
        // setReferenceBundle itself (not the detached scan) would show up as a stall here.
        let scanStarted = ThreadObservationBox()
        let releaseGate = DispatchSemaphore(value: 0)
        SequenceViewerView.variantTrackScanThreadingProbe = { [scanStarted] in
            scanStarted.record(isMainThread: Thread.isMainThread)
            // Simulate a slow variant-database open (large cohort VCF) without needing to
            // fabricate gigabytes of test data — the point under test is that this delay,
            // wherever it happens, cannot be observed as main-actor unresponsiveness.
            _ = releaseGate.wait(timeout: .now() + 2)
        }
        defer { releaseGate.signal() }

        let callStart = Date()
        viewer.setReferenceBundle(bundle)
        let callElapsed = Date().timeIntervalSince(callStart)

        // setReferenceBundle itself must return promptly — it only enqueues the scan, it does
        // not wait for it. A synchronous scan on main would make this call itself take ~2s.
        XCTAssertLessThan(callElapsed, 0.5, "setReferenceBundle blocked the caller for \(callElapsed)s")

        // A main-actor unit of work queued right after setReferenceBundle must run promptly,
        // proving the main actor was never occupied by the scan.
        let mainActorProbeRan = ThreadObservationBox()
        DispatchQueue.main.async {
            mainActorProbeRan.record(isMainThread: Thread.isMainThread)
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !mainActorProbeRan.fired && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(mainActorProbeRan.fired, "A main-actor probe queued after setReferenceBundle did not run promptly — the main actor may be blocked")

        releaseGate.signal()
    }

    // MARK: - Fixture

    private func makeReferenceBundleWithVariantTrack() throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("variant-scan.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let chromosome = "chr1"
        let sequence = "ACGT"
        try (">\(chromosome)\n\(sequence)\n").write(
            to: genomeDir.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        let offset = ">\(chromosome)\n".utf8.count
        try "\(chromosome)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(to: genomeDir.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        // A minimal variant database is enough to exercise the scan path — its content doesn't
        // matter for this threading test, only that `bundle.variantTrackIds` is non-empty so
        // `setReferenceBundle` actually dispatches the scan. `VariantDatabase.init(readWrite:)`
        // opens with SQLITE_OPEN_READWRITE (no SQLITE_OPEN_CREATE), so a fresh database must be
        // created through the real import path instead of instantiated directly.
        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        let vcfURL = variantsDir.appendingPathComponent("track.vcf")
        let vcfContents = """
        ##fileformat=VCFv4.2
        ##contig=<ID=\(chromosome),length=\(sequence.count)>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        \(chromosome)\t1\t.\tA\tG\t.\t.\t.

        """
        try vcfContents.write(to: vcfURL, atomically: true, encoding: .utf8)
        let dbURL = variantsDir.appendingPathComponent("track.sqlite")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        let vcfIndexURL = variantsDir.appendingPathComponent("track.vcf.gz.tbi")
        FileManager.default.createFile(atPath: vcfIndexURL.path, contents: Data())

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Variant Scan Threading Fixture",
            identifier: "org.lungfish.tests.variant-scan-off-main",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosome,
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    )
                ]
            ),
            variants: [
                VariantTrackInfo(
                    id: "track-1",
                    name: "Test Track",
                    path: "variants/track.vcf.gz",
                    indexPath: "variants/track.vcf.gz.tbi",
                    databasePath: "variants/track.sqlite"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}

/// Lock-protected capture box — test-only, mirroring the pattern used by the sibling B3/F14
/// threading regression tests (see SequenceViewerInteractionAsyncBundleReadTests.swift).
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    private var _wasMainThread = false

    func record(isMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _fired = true
        _wasMainThread = isMainThread
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}
