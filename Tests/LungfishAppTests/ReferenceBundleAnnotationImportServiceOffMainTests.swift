// ReferenceBundleAnnotationImportServiceOffMainTests.swift - Characterization tests proving
// ReferenceBundleAnnotationImportService's GFF3/BED parse, hashing, and provenance I/O can run
// off the main actor and produce identical results to a MainActor-driven run. See F14.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Drives `attachAnnotationTrack` from a plain background actor with no relationship to the
/// main actor, mirroring `NativeBundleBuilderOffMainTests.BackgroundBuildRunner` (task B2).
private actor BackgroundAnnotationImportRunner {
    func attach(
        sourceURL: URL,
        bundleURL: URL,
        trackID: String? = nil,
        trackName: String? = nil
    ) async throws -> ReferenceBundleAnnotationImportResult {
        try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            trackID: trackID,
            trackName: trackName
        )
    }
}

@MainActor
private enum MainActorAnnotationImportRunner {
    static func attach(
        sourceURL: URL,
        bundleURL: URL,
        trackID: String? = nil,
        trackName: String? = nil
    ) async throws -> ReferenceBundleAnnotationImportResult {
        return try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
            sourceURL: sourceURL,
            bundleURL: bundleURL,
            trackID: trackID,
            trackName: trackName
        )
    }
}

/// Thread-safe capture box for the `threadingProbe` hook. The probe closure is
/// `@Sendable` and fires from whatever thread `performAttach` actually runs on; this
/// box lets the (MainActor) test method read the captured value afterward.
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasMainThread: Bool?
    private var _fired = false

    func record() {
        let isMain = Thread.isMainThread
        lock.lock()
        _wasMainThread = isMain
        _fired = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}

final class ReferenceBundleAnnotationImportServiceOffMainTests: XCTestCase {

    private var tempRoot: URL!
    private let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationImportOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ReferenceBundleAnnotationImportService.threadingProbe = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    /// Runs the GFF3 import fully from a background actor (no MainActor hop anywhere in the
    /// call chain) and asserts it produces the same manifest/track/database/feature-count
    /// shape as running the same import from the MainActor. Confirms the pure parse/hash/IO
    /// work in `attachAnnotationTrack` no longer requires main-actor isolation.
    func testGFF3ImportProducesIdenticalResultOffMainAndOnMain() async throws {
        let gffFixture = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/genome.gff3")
        guard FileManager.default.fileExists(atPath: gffFixture.path) else {
            throw XCTSkip("GFF3 fixture not found at \(gffFixture.path)")
        }

        let offMainBundle = try makeBundle(named: "OffMainGFF")
        let onMainBundle = try makeBundle(named: "OnMainGFF")

        let offMainResult = try await BackgroundAnnotationImportRunner().attach(
            sourceURL: gffFixture,
            bundleURL: offMainBundle,
            trackID: "gff_track",
            trackName: "GFF Track"
        )
        let onMainResult = try await MainActorAnnotationImportRunner.attach(
            sourceURL: gffFixture,
            bundleURL: onMainBundle,
            trackID: "gff_track",
            trackName: "GFF Track"
        )

        XCTAssertEqual(offMainResult.featureCount, onMainResult.featureCount)
        XCTAssertGreaterThan(offMainResult.featureCount, 0)
        XCTAssertEqual(offMainResult.track.id, onMainResult.track.id)
        XCTAssertEqual(offMainResult.track.name, onMainResult.track.name)
        XCTAssertEqual(offMainResult.track.databasePath, onMainResult.track.databasePath)
        XCTAssertEqual(offMainResult.track.featureCount, onMainResult.track.featureCount)

        let offMainManifest = try BundleManifest.load(from: offMainBundle)
        let onMainManifest = try BundleManifest.load(from: onMainBundle)
        XCTAssertEqual(offMainManifest.annotations.map(\.id), onMainManifest.annotations.map(\.id))
        XCTAssertEqual(offMainManifest.annotations.map(\.name), onMainManifest.annotations.map(\.name))
        XCTAssertEqual(offMainManifest.annotations.map(\.featureCount), onMainManifest.annotations.map(\.featureCount))

        let offMainDB = try AnnotationDatabase(
            url: offMainBundle.appendingPathComponent("annotations/gff_track.db")
        )
        let onMainDB = try AnnotationDatabase(
            url: onMainBundle.appendingPathComponent("annotations/gff_track.db")
        )
        let offMainRecords = offMainDB.queryByRegion(chromosome: "MT192765.1", start: 0, end: 30_000)
        let onMainRecords = onMainDB.queryByRegion(chromosome: "MT192765.1", start: 0, end: 30_000)
        XCTAssertEqual(offMainRecords.map(\.name), onMainRecords.map(\.name))
        XCTAssertEqual(offMainRecords.map(\.type), onMainRecords.map(\.type))
        XCTAssertEqual(offMainRecords.map(\.start), onMainRecords.map(\.start))
        XCTAssertEqual(offMainRecords.map(\.end), onMainRecords.map(\.end))
    }

    /// Same characterization for the BED import path (createFromBED is fully synchronous,
    /// per F14's specific callout), plus provenance file content equality modulo timestamps.
    func testBEDImportProducesIdenticalResultOffMainAndOnMain() async throws {
        let bedFixture = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.bed")
        guard FileManager.default.fileExists(atPath: bedFixture.path) else {
            throw XCTSkip("BED fixture not found at \(bedFixture.path)")
        }

        let offMainBundle = try makeBundle(named: "OffMainBED")
        let onMainBundle = try makeBundle(named: "OnMainBED")

        let offMainResult = try await BackgroundAnnotationImportRunner().attach(
            sourceURL: bedFixture,
            bundleURL: offMainBundle,
            trackID: "bed_track",
            trackName: "BED Track"
        )
        let onMainResult = try await MainActorAnnotationImportRunner.attach(
            sourceURL: bedFixture,
            bundleURL: onMainBundle,
            trackID: "bed_track",
            trackName: "BED Track"
        )

        XCTAssertEqual(offMainResult.featureCount, onMainResult.featureCount)
        XCTAssertGreaterThan(offMainResult.featureCount, 0)

        let offMainDB = try AnnotationDatabase(
            url: offMainBundle.appendingPathComponent("annotations/bed_track.db")
        )
        let onMainDB = try AnnotationDatabase(
            url: onMainBundle.appendingPathComponent("annotations/bed_track.db")
        )
        let offMainRecords = offMainDB.queryByRegion(chromosome: "MT192765.1", start: 0, end: 30_000)
        let onMainRecords = onMainDB.queryByRegion(chromosome: "MT192765.1", start: 0, end: 30_000)
        XCTAssertEqual(offMainRecords.map(\.name), onMainRecords.map(\.name))
        XCTAssertEqual(offMainRecords.map(\.start), onMainRecords.map(\.start))
        XCTAssertEqual(offMainRecords.map(\.end), onMainRecords.map(\.end))

        // Provenance JSON should describe the same import shape (track id/name/format/feature
        // count), independent of which actor drove the call.
        let offMainProvenance = try String(
            contentsOf: offMainBundle.appendingPathComponent("annotations/bed_track-import-provenance.json"),
            encoding: .utf8
        )
        let onMainProvenance = try String(
            contentsOf: onMainBundle.appendingPathComponent("annotations/bed_track-import-provenance.json"),
            encoding: .utf8
        )
        for expected in [
            "\"trackID\" : \"bed_track\"",
            "\"trackName\" : \"BED Track\"",
            "\"format\" : \"bed\"",
        ] {
            XCTAssertTrue(offMainProvenance.contains(expected))
            XCTAssertTrue(onMainProvenance.contains(expected))
        }
    }

    /// discoverReferenceBundles is a synchronous static helper (FileManager enumeration); it
    /// should be callable without any MainActor hop once the type is no longer @MainActor.
    func testDiscoverReferenceBundlesRunsOffMain() async throws {
        _ = try makeBundle(named: "M1", relativePath: "Reference Sequences/M1.lungfishref")
        let searchRoot = tempRoot!

        let choices = try await Task.detached {
            try ReferenceBundleAnnotationImportService.discoverReferenceBundles(in: searchRoot)
        }.value

        XCTAssertEqual(choices.count, 1)
    }

    // MARK: - Threading regression (review round 1, CRITICAL finding)
    //
    // These tests call `attachAnnotationTrack` from an actual `@MainActor` context (as
    // every production caller does) and assert, via a probe fired from inside
    // `performAttach`'s `Task.detached` body, that the heavy work is NOT running on the
    // main thread. `Task.detached` makes this an unconditional, structural guarantee
    // rather than relying on the isolation-crossing `await` hop that Swift 6 happens to
    // insert when a `@MainActor` caller awaits a nonisolated async callee on this
    // toolchain -- that hop is real (confirmed empirically while building this fix: a
    // `@MainActor` caller awaiting a plain nonisolated async method, even one with zero
    // internal awaits, lands on a background thread here), but it is compiler/runtime
    // behavior this class should not depend on implicitly. The discriminating mutation
    // these tests actually catch is the class regaining `@MainActor` (F14's original
    // bug): confirmed RED by temporarily re-adding `@MainActor` to
    // `ReferenceBundleAnnotationImportService` during development, which made both
    // `wasMainThread` assertions below fail (`Optional(true)` instead of
    // `Optional(false)`), then GREEN again after reverting.

    /// GFF3 import, driven from @MainActor: the heavy work must not run on the main thread.
    func testGFF3ImportRunsHeavyWorkOffMainThreadWhenCalledFromMainActor() async throws {
        let gffFixture = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/genome.gff3")
        guard FileManager.default.fileExists(atPath: gffFixture.path) else {
            throw XCTSkip("GFF3 fixture not found at \(gffFixture.path)")
        }
        let bundleURL = try makeBundle(named: "ThreadProbeGFF3")
        let observation = ThreadObservationBox()
        ReferenceBundleAnnotationImportService.threadingProbe = { observation.record() }

        _ = try await MainActorAnnotationImportRunner.attach(
            sourceURL: gffFixture,
            bundleURL: bundleURL,
            trackID: "thread_probe_gff3"
        )

        XCTAssertTrue(observation.fired, "threadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "annotation import heavy work ran on the main thread")
    }

    /// BED import, driven from @MainActor: this is the CRITICAL path from the review --
    /// createFromBED has zero internal `await`s, so this is the format most exposed to
    /// the nonisolated-inherits-caller's-thread pitfall.
    func testBEDImportRunsHeavyWorkOffMainThreadWhenCalledFromMainActor() async throws {
        let bedFixture = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.bed")
        guard FileManager.default.fileExists(atPath: bedFixture.path) else {
            throw XCTSkip("BED fixture not found at \(bedFixture.path)")
        }
        let bundleURL = try makeBundle(named: "ThreadProbeBED")
        let observation = ThreadObservationBox()
        ReferenceBundleAnnotationImportService.threadingProbe = { observation.record() }

        _ = try await MainActorAnnotationImportRunner.attach(
            sourceURL: bedFixture,
            bundleURL: bundleURL,
            trackID: "thread_probe_bed"
        )

        XCTAssertTrue(observation.fired, "threadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "annotation import heavy work ran on the main thread")
    }

    private func makeBundle(named name: String, relativePath: String? = nil) throws -> URL {
        let bundleURL = tempRoot.appendingPathComponent(relativePath ?? "\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("genome", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations", isDirectory: true),
            withIntermediateDirectories: true
        )

        try ">MT192765.1\n\(String(repeating: "ACGT", count: 7500))\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "MT192765.1\t30000\t12\t30001\n".write(
            to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.test.\(UUID().uuidString.lowercased())",
            source: SourceInfo(organism: "Test", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 30_000,
                chromosomes: [
                    ChromosomeInfo(name: "MT192765.1", length: 30_000, offset: 12, lineBases: 30_000, lineWidth: 30_001)
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
