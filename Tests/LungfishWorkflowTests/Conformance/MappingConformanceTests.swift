// MappingConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// End-to-end conformance: runs the real minimap2/samtools/bcftools/htslib
// binaries against the shared SARS-CoV-2 fixture, then verifies the output
// through the app's real samtools output parsers. By default a missing tool
// is a skip (dev machines drift); with LUNGFISH_REQUIRE_TOOLS=1 a missing
// tool becomes a hard failure.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class MappingConformanceTests: XCTestCase {
    func testMinimap2SamtoolsRoundTripAndStatsParse() async throws {
        let minimap2 = try await ToolAvailability.require("minimap2", environment: "minimap2")
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let tmp = try ConformanceFixtures.tempDir("map")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ref = ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta")
        let r1 = ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")
        let r2 = ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz")
        let sam = tmp.appendingPathComponent("out.sam")
        let bam = tmp.appendingPathComponent("out.sorted.bam")

        let m = try ProcessRunner.run(minimap2, ["-ax", "sr", "-o", sam.path, ref.path, r1.path, r2.path], timeout: 300)
        XCTAssertEqual(m.status, 0, m.stderr)

        let sortResult = try ProcessRunner.run(samtools, ["sort", "-o", bam.path, sam.path], timeout: 300)
        XCTAssertEqual(sortResult.status, 0, sortResult.stderr)
        let indexResult = try ProcessRunner.run(samtools, ["index", bam.path], timeout: 300)
        XCTAssertEqual(indexResult.status, 0, indexResult.stderr)

        // Project rule: never keep the intermediate SAM once a sorted, indexed
        // BAM exists.
        try FileManager.default.removeItem(at: sam)

        let flagstat = try ProcessRunner.run(samtools, ["flagstat", bam.path], timeout: 60)
        XCTAssertEqual(flagstat.status, 0, flagstat.stderr)
        let stats = try AlignmentMetadataDatabase.parseFlagstat(flagstat.stdout)
        XCTAssertGreaterThan(stats.mappedReads, 0)
        XCTAssertGreaterThan(stats.totalReads, 0)
        let mappedFraction = Double(stats.mappedReads) / Double(stats.totalReads)
        XCTAssertGreaterThan(mappedFraction, 0.5, "most fixture reads should map to the SARS-CoV-2 reference")

        let idx = try ProcessRunner.run(samtools, ["idxstats", bam.path], timeout: 60)
        XCTAssertEqual(idx.status, 0, idx.stderr)
        let idxRows = try AlignmentMetadataDatabase.parseIdxstats(idx.stdout)
        XCTAssertEqual(idxRows.first?.chromosome, "MT192765.1")
        XCTAssertGreaterThan(idxRows.first?.mappedReads ?? 0, 0)
    }

    func testBcftoolsCallAndHtslibIndexing() async throws {
        let bcftools = try await ToolAvailability.require("bcftools", environment: "bcftools")
        let bgzip = try await ToolAvailability.require("bgzip", environment: "htslib")
        let tabix = try await ToolAvailability.require("tabix", environment: "htslib")
        let tmp = try ConformanceFixtures.tempDir("vcf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ref = ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta")
        let bam = ConformanceFixtures.sarscov2.appendingPathComponent("test.paired_end.sorted.bam")
        let vcf = tmp.appendingPathComponent("calls.vcf")

        // Pipe mpileup -> call via shell to keep it simple and deterministic;
        // ProcessRunner has no built-in pipe support between two processes.
        let sh = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "'\(bcftools.path)' mpileup -f '\(ref.path)' -Ou '\(bam.path)' | '\(bcftools.path)' call -mv -Ov -o '\(vcf.path)'"],
            timeout: 300
        )
        XCTAssertEqual(sh.status, 0, sh.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vcf.path), "bcftools call should produce a VCF")

        let bgzipResult = try ProcessRunner.run(bgzip, ["-f", vcf.path], timeout: 60)
        XCTAssertEqual(bgzipResult.status, 0, bgzipResult.stderr)
        let tabixResult = try ProcessRunner.run(tabix, ["-p", "vcf", vcf.path + ".gz"], timeout: 60)
        XCTAssertEqual(tabixResult.status, 0, tabixResult.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vcf.path + ".gz.tbi"))

        let view = try ProcessRunner.run(bcftools, ["view", "-H", vcf.path + ".gz"], timeout: 60)
        XCTAssertEqual(view.status, 0, view.stderr)
        XCTAssertFalse(view.stdout.isEmpty, "expected at least one variant call on the fixture")
    }
}
