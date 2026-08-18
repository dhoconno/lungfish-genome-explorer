// DeaconFastpSeqkitConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// End-to-end conformance: runs the real deacon, fastp, seqkit, cutadapt, and
// bbtools (reformat.sh) binaries against the shared SARS-CoV-2 fixture, then
// verifies the output through the app's real parsers where one exists. By
// default a missing tool is a skip (dev machines drift); with
// LUNGFISH_REQUIRE_TOOLS=1 a missing tool becomes a hard failure.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class DeaconFastpSeqkitConformanceTests: XCTestCase {
    private var r1: URL { ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz") }

    func testDeaconIndexBuildAndFilterDepletesFixtureReads() async throws {
        let deacon = try await ToolAvailability.require("deacon", environment: "deacon")
        let tmp = try ConformanceFixtures.tempDir("deacon")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let idx = tmp.appendingPathComponent("ref.idx")
        let build = try ProcessRunner.run(
            deacon,
            ["index", "build", ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta").path, "-o", idx.path]
        )
        XCTAssertEqual(build.status, 0, build.stderr)

        let out = tmp.appendingPathComponent("filt.fq.gz")
        let summary = tmp.appendingPathComponent("summary.json")
        let filter = try ProcessRunner.run(
            deacon,
            ["filter", "-d", idx.path, r1.path, "-o", out.path, "--summary", summary.path]
        )
        XCTAssertEqual(filter.status, 0, filter.stderr)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: summary)) as? [String: Any]
        let keys = (json?.keys).map { Array($0).sorted() } ?? []
        XCTAssertNotNil(json, "deacon summary.json did not parse as an object; keys seen elsewhere: \(keys)")

        // deacon's real summary keys (verified against the installed binary):
        // "seqs_in"/"seqs_out" (not "reads_in"/"reads_out").
        let seqsIn = (json?["seqs_in"] as? Int) ?? (json?["reads_in"] as? Int) ?? 0
        let seqsOut = (json?["seqs_out"] as? Int) ?? (json?["reads_out"] as? Int) ?? seqsIn
        XCTAssertGreaterThan(seqsIn, 0, "summary keys: \((json?.keys.sorted()) ?? [])")
        // Fixture reads are SARS-CoV-2; depleting against a SARS-CoV-2 index
        // must remove nearly all of them.
        XCTAssertLessThan(Double(seqsOut) / Double(seqsIn), 0.05)
    }

    func testFastpTrimsAndSeqkitStatsParse() async throws {
        let fastp = try await ToolAvailability.require("fastp", environment: "fastp")
        let seqkit = try await ToolAvailability.require("seqkit", environment: "seqkit")
        let tmp = try ConformanceFixtures.tempDir("fastp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out = tmp.appendingPathComponent("trim.fq.gz")
        let res = try ProcessRunner.run(
            fastp,
            ["-i", r1.path, "-o", out.path, "-j", tmp.appendingPathComponent("f.json").path, "-h", tmp.appendingPathComponent("f.html").path, "-w", "2"]
        )
        XCTAssertEqual(res.status, 0, res.stderr)

        let stats = try ProcessRunner.run(seqkit, ["stats", "-a", "-T", out.path])
        XCTAssertEqual(stats.status, 0, stats.stderr)
        let table = try SeqkitStatsParser.parse(stats.stdout)
        XCTAssertGreaterThan(table.numSeqs, 0)
        XCTAssertGreaterThan(table.avgLen, 30)
    }

    func testCutadaptAndBBToolsRun() async throws {
        let cutadapt = try await ToolAvailability.require("cutadapt", environment: "cutadapt")
        let reformat = try await ToolAvailability.require("reformat.sh", environment: "bbtools")
        let tmp = try ConformanceFixtures.tempDir("bb")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let c = try ProcessRunner.run(cutadapt, ["-a", "AGATCGGAAGAGC", "-o", tmp.appendingPathComponent("c.fq.gz").path, r1.path])
        XCTAssertEqual(c.status, 0, c.stderr)

        let env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        )
        let r = try ProcessRunner.run(
            reformat,
            ["in=\(r1.path)", "out=\(tmp.appendingPathComponent("r.fq").path)", "overwrite=t"],
            environment: env
        )
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stderr.contains("Input:") && r.stderr.contains("reads"), "reformat.sh summary format changed: \(r.stderr.suffix(300))")
    }
}
