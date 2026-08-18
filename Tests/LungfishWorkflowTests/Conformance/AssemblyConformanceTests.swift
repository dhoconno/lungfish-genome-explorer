// AssemblyConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// End-to-end conformance: runs the real spades.py and megahit binaries against
// the shared SARS-CoV-2 fixture, then verifies the output through the app's
// real assembly output parser/normalizer. By default a missing tool is a skip
// (dev machines drift); with LUNGFISH_REQUIRE_TOOLS=1 a missing tool becomes a
// hard failure.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class AssemblyConformanceTests: XCTestCase {
    private let r1 = ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")
    private let r2 = ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz")

    func testSPAdesProducesContigsWithParsableHeaders() async throws {
        let spades = try await ToolAvailability.require("spades.py", environment: "spades")
        let tmp = try ConformanceFixtures.tempDir("spades")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // The fixture is tiny (200 paired-end SARS-CoV-2 test reads), which
        // is too few for SPAdes' default error-correction coverage-model
        // fitting: even `--only-assembler` still runs the EC threshold
        // finder first and it aborts with "Invalid kmer coverage histogram"
        // on this input regardless of `--cov-cutoff`. `--sc` (single-cell
        // mode, designed for uneven/sparse coverage) avoids that fitting
        // step and completes; combined with a single small k-mer this keeps
        // runtime bounded. Verified locally against the installed binary
        // before adopting this flag combination.
        let res = try ProcessRunner.run(
            spades,
            ["--sc", "-k", "21", "-1", r1.path, "-2", r2.path, "-t", "4", "-m", "8", "-o", tmp.path],
            timeout: 1800
        )
        XCTAssertEqual(res.status, 0, res.stderr.suffix(2000).description)

        let contigs = tmp.appendingPathComponent("contigs.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contigs.path))
        let headers = try String(contentsOf: contigs, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix(">") }
        XCTAssertFalse(headers.isEmpty)
        let regex = try NSRegularExpression(pattern: #"^>NODE_\d+_length_\d+_cov_[\d.]+"#)
        for h in headers {
            XCTAssertNotNil(
                regex.firstMatch(in: String(h), range: NSRange(h.startIndex..., in: h)),
                "unexpected SPAdes header \(h)"
            )
        }

        // SPAdesOutputParser has no `isComplete`; the shipped pipeline
        // (SPAdesAssemblyPipeline) actually treats `contigs.fasta` existing
        // on disk as the completion signal (asserted above) and uses this
        // parser only for `detectError` on failure. Exercise that real,
        // load-bearing contract against the real log: on a successful run,
        // `detectError` must not false-positive on any line.
        //
        // Separately, note for future maintainers: `parseLine`'s stage
        // markers require a two-sided `== ... ==` bracket
        // (`parseStageMarker`'s `hasPrefix("==") && hasSuffix("==")`), but
        // the installed SPAdes 4.2.0 emits single-sided section markers
        // (`===== Assembling finished. `, `======= SPAdes pipeline
        // finished WITH WARNINGS!`) that never match. `parseLine`'s
        // stage/progress reporting is therefore unused/unreachable against
        // real modern SPAdes output -- only its own synthetic unit tests
        // exercise it. This conformance test does not assert on that
        // unreachable path so it does not need to encode a "verified bug"
        // fixture; a fix to `SPAdesOutputParser`'s stage-marker matching is
        // out of scope here.
        let log = try String(contentsOf: tmp.appendingPathComponent("spades.log"), encoding: .utf8)
        let parser = SPAdesOutputParser()
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertNil(parser.detectError(String(line)), "false-positive error detection on: \(line)")
        }

        // The FASTA normalizer must also locate the same contigs file via the
        // real request/normalize entry point.
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [r1, r2],
            projectName: "conformance-spades",
            outputDirectory: tmp,
            pairedEnd: true,
            threads: 4
        )
        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: tmp,
            commandLine: "spades.py --sc -k 21",
            wallTimeSeconds: 0
        )
        XCTAssertEqual(result.contigsPath, contigs)
        XCTAssertGreaterThan(result.statistics.contigCount, 0)
    }

    func testMegahitProducesFinalContigs() async throws {
        let megahit = try await ToolAvailability.require("megahit", environment: "megahit")
        let tmp = try ConformanceFixtures.tempDir("megahit")
        let out = tmp.appendingPathComponent("out")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // MEGAHIT 1.2.9's arm64 core crashes reliably above two threads on
        // Apple Silicon (see AssemblyRunRequest.effectiveThreadCount, which
        // caps the app's own MEGAHIT invocations the same way); confirmed
        // locally that `-t 4` segfaults (exit -11) on this machine while
        // `-t 2` completes.
        let res = try ProcessRunner.run(
            megahit,
            ["-1", r1.path, "-2", r2.path, "-t", "2", "-o", out.path],
            timeout: 1800
        )
        XCTAssertEqual(res.status, 0, res.stderr.suffix(2000).description)

        let contigs = out.appendingPathComponent("final.contigs.fa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contigs.path))

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [r1, r2],
            projectName: "conformance-megahit",
            outputDirectory: out,
            pairedEnd: true,
            threads: 4
        )
        let result = try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: out,
            commandLine: "megahit",
            wallTimeSeconds: 0
        )
        XCTAssertEqual(result.contigsPath, contigs)
        XCTAssertGreaterThan(result.statistics.contigCount, 0)
    }
}
