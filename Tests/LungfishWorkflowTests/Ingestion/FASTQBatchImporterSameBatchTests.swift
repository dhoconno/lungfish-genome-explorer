// FASTQBatchImporterSameBatchTests.swift - No sample of an import replaces a bundle the same import wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Two samples of one import can name one bundle. When the check leaves a
/// run's third file out, the pair and the third file are two samples of the
/// run's name, and two files of one stem from two folders name one bundle
/// too. Without `--force` the later sample found the earlier sample's bundle
/// and was skipped. With `--force` it replaced that bundle and moved it to
/// the Trash, so a run's reads whose mate is missing took the place of its
/// pairs (f10-report.md, concern 1). `--force` now replaces only a bundle
/// that was there before the import.
final class FASTQBatchImporterSameBatchTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-same-batch")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testForceNeverLetsASampleReplaceABundleAnEarlierSampleOfTheImportWrote() async throws {
        let first = try write("plate-a/S1.fastq", reads: ["a1", "a2"])
        let second = try write("plate-b/S1.fastq", reads: ["b1"])
        let samples = FASTQBatchImporter.detectPairs(from: [first, second])
        XCTAssertEqual(samples.map(\.sampleName), ["S1", "S1"])
        let events = EventLog()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: samples,
            config: config(force: true),
            log: { events.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        XCTAssertEqual(result.skipped, 1, "the second S1 is skipped, not imported over the first")
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(try headers(ofBundle: "S1"), ["a1", "a2"], "the first sample's reads stay in the bundle")
        let skips = events.skips
        XCTAssertEqual(skips.map(\.sample), ["S1"])
        XCTAssertEqual(
            skips.first?.reason,
            "Bundle already exists. An earlier sample of this import wrote it, and --force never replaces a bundle "
                + "the same import wrote."
        )
    }

    func testWithoutForceTheLaterSampleIsSkippedAsBefore() async throws {
        let first = try write("plate-a/S3.fastq", reads: ["a1"])
        let second = try write("plate-b/S3.fastq", reads: ["b1"])
        let events = EventLog()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: [first, second]),
            config: config(),
            log: { events.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(events.skips.map(\.reason), ["Bundle already exists"])
        XCTAssertEqual(try headers(ofBundle: "S3"), ["a1"])
    }

    func testForceNeverLetsANameThatDiffersOnlyInCaseReplaceTheBundleOnAVolumeThatIgnoresCase() async throws {
        let values = try project.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try XCTSkipIf(values.volumeSupportsCaseSensitiveNames == true, "the project's volume tells the two names apart")
        let first = try write("plate-a/S4.fastq", reads: ["a1"])
        let second = try write("plate-b/s4.fastq", reads: ["b1"])
        let events = EventLog()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: [first, second]),
            config: config(force: true),
            log: { events.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(events.skips.map(\.sample), ["s4"])
        XCTAssertEqual(try headers(ofBundle: "S4"), ["a1"])
    }

    // MARK: - A bundle an earlier sample failed to write (review B-S2)

    func testNoSampleWritesABundleAnEarlierSampleOfTheImportFailedToWriteWhateverForceSays() async throws {
        for force in [false, true] {
            // Two samples of one name, a pair whose R2 stopped inside its
            // first read and a file of another folder.
            let folder = force ? "forced" : "plain"
            let r1 = try write("\(folder)/plate-a/S5_R1.fastq", reads: ["a1/1"])
            let r2 = root.appendingPathComponent("\(folder)/plate-a/S5_R2.fastq")
            try Data("@a1/2\nACGT".utf8).write(to: r2)
            let other = try write("\(folder)/plate-b/S5.fastq", reads: ["b1"])
            let samples = FASTQBatchImporter.detectPairs(from: [r1, r2, other])
            XCTAssertEqual(samples.map(\.inputFiles), [[r1, r2], [other]], folder)
            let events = EventLog()

            let result = await FASTQBatchImporter.runBatchImport(
                pairs: samples,
                config: config(force: force),
                log: { events.append($0) }
            )

            XCTAssertEqual(result.failed, 1, "the pair fails. Errors: \(result.errors)")
            XCTAssertEqual(result.completed, 0, "the later sample does not take the name the pair failed to write")
            XCTAssertEqual(result.skipped, 1, folder)
            XCTAssertEqual(events.skips.map(\.sample), ["S5"], folder)
            XCTAssertEqual(
                events.skips.first?.reason,
                "An earlier sample of this import failed to write this bundle, so no later sample of the import "
                    + "writes it.",
                folder
            )
            let bundle = project.appendingPathComponent("Imports/S5.lungfishfastq", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), folder)
        }
    }

    // MARK: - Helpers

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ImportLogEvent] = []

        func append(_ event: ImportLogEvent) {
            lock.withLock { events.append(event) }
        }

        var skips: [(sample: String, reason: String)] {
            lock.withLock {
                events.compactMap { event in
                    guard case .sampleSkip(let sample, let reason) = event else { return nil }
                    return (sample, reason)
                }
            }
        }
    }

    private func config(force: Bool = false) -> FASTQBatchImporter.ImportConfig {
        FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: .given(.illumina),
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1,
            forceReimport: force
        )
    }

    private func write(_ relativePath: String, reads: [String]) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = reads.map { "@\($0)\nACGTACGT\n+\nIIIIIIII\n" }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }

    private func headers(ofBundle name: String) throws -> [String] {
        let bundle = project.appendingPathComponent("Imports/\(name).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), "no bundle \(name)")
        return try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 1_000).headers
    }
}
