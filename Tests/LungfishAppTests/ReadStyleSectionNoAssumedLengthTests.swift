// ReadStyleSectionNoAssumedLengthTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishWorkflow

/// EST-COVERAGE-150BP: the Inspector's Est. Coverage multiplied the mapped records by an assumed 150 bp and divided by
/// the length, so 10 reads of 10,000 bp over 1,000 bp showed 1.5x. The row now shows the mean depth that samtools
/// measured over the sequence, and no row where it is not measured.
@MainActor
final class ReadStyleSectionNoAssumedLengthTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-style-no-assumed-length-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct Fixture {
        let bundle: ReferenceBundle
        let bam: URL
    }

    @discardableResult
    private func runSamtools(_ arguments: [String]) async throws -> NativeToolResult {
        let result = try await NativeToolRunner.shared.run(.samtools, arguments: arguments, timeout: 60)
        XCTAssertEqual(result.exitCode, 0, "samtools \(arguments.joined(separator: " ")): \(result.stderr)")
        return result
    }

    /// One sequence of 1,000 bp and 10 mapped reads of 10,000 bp. Each read aligns 1,000 bases over the whole sequence
    /// and soft-clips the other 9,000, so every position has depth 10.
    private func makeFixture(writeBAM: Bool, mappedRecords: Int64) async throws -> Fixture {
        let bundleURL = tempDir.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
        let alignments = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignments, withIntermediateDirectories: true)
        let bam = alignments.appendingPathComponent("fixture.sorted.bam")
        if writeBAM {
            let sequence = String(repeating: "A", count: 10_000)
            let qualities = String(repeating: "I", count: 10_000)
            var sam = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:ref\tLN:1000\n"
            for index in 1...10 {
                sam += "read\(index)\t0\tref\t1\t60\t1000M9000S\t*\t0\t0\t\(sequence)\t\(qualities)\n"
            }
            let samURL = alignments.appendingPathComponent("fixture.sam")
            try sam.write(to: samURL, atomically: true, encoding: .utf8)
            try await runSamtools(["view", "-b", "-o", bam.path, samURL.path])
            try await runSamtools(["index", bam.path, bam.path + ".bai"])
        }
        let database = try AlignmentMetadataDatabase.create(at: alignments.appendingPathComponent("fixture.stats.db"))
        database.addChromosomeStats(chromosome: "ref", length: 1_000, mapped: mappedRecords, unmapped: 0)
        let manifest = BundleManifest(
            name: "Fixture",
            identifier: "bundle.depth-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture", database: "Test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln", name: "Fixture",
                    sourcePath: "alignments/fixture.sorted.bam",
                    indexPath: "alignments/fixture.sorted.bam.bai",
                    metadataDBPath: "alignments/fixture.stats.db"
                ),
            ]
        )
        return Fixture(bundle: ReferenceBundle(url: bundleURL, manifest: manifest), bam: bam)
    }

    /// The mean of `samtools depth -a` over every position of the fixture, run directly (SAD:92).
    private func samtoolsDepthMean(of bam: URL) async throws -> Double {
        let result = try await runSamtools(["depth", "-a", bam.path])
        let depths = result.stdout.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").last.flatMap { Double($0) }
        }
        XCTAssertEqual(depths.count, 1_000, "depth -a lists every position of the sequence")
        return depths.reduce(0, +) / Double(max(1, depths.count))
    }

    private func depthShown(
        by viewModel: ReadStyleSectionViewModel, near expected: Double, within seconds: TimeInterval
    ) async throws -> Double? {
        let deadline = Date().addingTimeInterval(seconds)
        var shown = viewModel.chromosomeStats.first?.estimatedCoverage
        while Date() < deadline {
            if let value = shown, abs(value - expected) < 1e-6 { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
            shown = viewModel.chromosomeStats.first?.estimatedCoverage
        }
        return shown
    }

    func testTheDepthShownIsTheMeasuredMeanNotMappedReadsTimes150() async throws {
        let fixture = try await makeFixture(writeBAM: true, mappedRecords: 10)
        let measured = try await samtoolsDepthMean(of: fixture.bam)
        print("CKPT-DEPTH samtools depth -a mean over fixture.sorted.bam: \(measured)")
        XCTAssertEqual(measured, 10.0, accuracy: 1e-9, "samtools depth -a on the 1,000 bp fixture")

        let viewModel = ReadStyleSectionViewModel()
        viewModel.loadStatistics(from: fixture.bundle)
        XCTAssertEqual(viewModel.chromosomeStats.count, 1)

        let shown = try await depthShown(by: viewModel, near: measured, within: 20)
        XCTAssertEqual(
            try XCTUnwrap(shown), measured, accuracy: 1e-6,
            "the row shows samtools' mean depth, not 10 records x 150 bp / 1,000 bp = 1.5"
        )
    }

    func testNoDepthIsShownForASequenceWhoseAlignmentCannotBeMeasured() async throws {
        let fixture = try await makeFixture(writeBAM: false, mappedRecords: 5)

        let viewModel = ReadStyleSectionViewModel()
        viewModel.loadStatistics(from: fixture.bundle)
        XCTAssertEqual(viewModel.chromosomeStats.count, 1)
        XCTAssertNil(viewModel.chromosomeStats.first?.estimatedCoverage, "no read length is assumed")

        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(viewModel.chromosomeStats.first?.estimatedCoverage, "a measurement that failed leaves no row")
    }
}
