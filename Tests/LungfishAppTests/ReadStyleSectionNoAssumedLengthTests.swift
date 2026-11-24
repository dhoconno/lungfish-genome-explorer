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
    ///
    /// `samtools depth -a` run directly on this fixture (samtools 1.24, 2026-11-23): 1,000 positions, sum 10,000,
    /// mean 10.0 (SAD:92). `samtools coverage` gives meandepth 10 for the same file. The assumed 150 bp showed
    /// 10 x 150 / 1,000 = 1.5x.
    ///
    /// `supplementary` adds that many supplementary records (flag 2048) over the same 1,000 bases. `samtools coverage`
    /// counts them unless it is told to leave them out, as the mapping table's pass does, so 2 of them give 12.0 for
    /// the default flags and 10.0 for the table's.
    private func makeFixture(writeBAM: Bool, mappedRecords: Int64, supplementary: Int = 0) async throws -> Fixture {
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
            for index in 0..<supplementary {
                sam += "supp\(index)\t2048\tref\t1\t60\t1000M9000S\t*\t0\t0\t\(sequence)\t\(qualities)\n"
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

    /// CKPT-DEPTH-BIO B1: the mapping table's Mean Depth is `samtools coverage` with the primary-mapped filter flags,
    /// which leave out supplementary alignments (`MappingSummaryBuilder.primaryMappedReadExclusionFlags`). The row of
    /// the Inspector carries the same label, so for a BAM with chimeric or split reads it must show the same figure.
    func testTheDepthLeavesOutSupplementaryAlignmentsLikeTheMappingTable() async throws {
        let fixture = try await makeFixture(writeBAM: true, mappedRecords: 10, supplementary: 2)
        let table = try await runSamtools(
            ["coverage", "--ff", "UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP", fixture.bam.path]
        )
        let tableLine = table.stdout.split(separator: "\n").dropFirst().first ?? ""
        let tableFields = tableLine.split(separator: "\t", omittingEmptySubsequences: false)
        let tableDepth = try XCTUnwrap(tableFields.count >= 7 ? Double(tableFields[6]) : nil, "the table's pass has a row")
        XCTAssertEqual(tableDepth, 10.0, accuracy: 1e-9, "the table's pass leaves out the 2 supplementary alignments")

        let viewModel = ReadStyleSectionViewModel()
        viewModel.loadStatistics(from: fixture.bundle)
        XCTAssertEqual(viewModel.chromosomeStats.count, 1)

        let shown = try await depthShown(by: viewModel, near: tableDepth, within: 20)
        XCTAssertEqual(
            try XCTUnwrap(shown), tableDepth, accuracy: 1e-6,
            "the row equals the mapping table's Mean Depth, 12.0 if supplementary alignments are counted"
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
