// CLIImportRunnerTests - Tests for CLI subprocess management actor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class CLIImportRunnerTests: XCTestCase {

    // MARK: - Event Parsing Tests

    func testParseImportStartEvent() throws {
        let json = """
        {"event":"importStart","sampleCount":3,"recipeName":"vsp2","timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .importStart(sampleCount, recipeName) = event else {
            return XCTFail("Expected importStart, got \(event)")
        }
        XCTAssertEqual(sampleCount, 3)
        XCTAssertEqual(recipeName, "vsp2")
    }

    func testParseSampleStartEvent() throws {
        let json = """
        {"event":"sampleStart","sample":"Sample1","index":0,"total":3,"r1":"/path/r1.fastq.gz","r2":"/path/r2.fastq.gz","timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .sampleStart(sample, index, total, r1, r2) = event else {
            return XCTFail("Expected sampleStart, got \(event)")
        }
        XCTAssertEqual(sample, "Sample1")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(total, 3)
        XCTAssertEqual(r1, "/path/r1.fastq.gz")
        XCTAssertEqual(r2, "/path/r2.fastq.gz")
    }

    func testParseStepStartEvent() throws {
        let json = """
        {"event":"stepStart","sample":"Sample1","step":"Remove PCR duplicates","stepIndex":1,"totalSteps":5,"timestamp":"2026-04-04T10:00:00Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .stepStart(sample, step, stepIndex, totalSteps) = event else {
            return XCTFail("Expected stepStart, got \(event)")
        }
        XCTAssertEqual(sample, "Sample1")
        XCTAssertEqual(step, "Remove PCR duplicates")
        XCTAssertEqual(stepIndex, 1)
        XCTAssertEqual(totalSteps, 5)
    }

    func testParseStepCompleteEvent() throws {
        let json = """
        {"event":"stepComplete","sample":"Sample1","step":"Remove PCR duplicates","durationSeconds":12.5,"timestamp":"2026-04-04T10:00:05Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .stepComplete(sample, step, durationSeconds) = event else {
            return XCTFail("Expected stepComplete, got \(event)")
        }
        XCTAssertEqual(sample, "Sample1")
        XCTAssertEqual(step, "Remove PCR duplicates")
        XCTAssertEqual(durationSeconds, 12.5)
    }

    func testParseSampleCompleteEvent() throws {
        let json = """
        {"event":"sampleComplete","sample":"Sample1","bundle":"/project/Sample1.lungfishfastq","durationSeconds":45.2,"originalBytes":1048576,"finalBytes":524288,"timestamp":"2026-04-04T10:01:00Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .sampleComplete(sample, bundle, durationSeconds, originalBytes, finalBytes) = event else {
            return XCTFail("Expected sampleComplete, got \(event)")
        }
        XCTAssertEqual(sample, "Sample1")
        XCTAssertEqual(bundle, "/project/Sample1.lungfishfastq")
        XCTAssertEqual(durationSeconds, 45.2)
        XCTAssertEqual(originalBytes, 1_048_576)
        XCTAssertEqual(finalBytes, 524_288)
    }

    func testParseSampleFailedEvent() throws {
        let json = """
        {"event":"sampleFailed","sample":"Sample2","error":"Input file not found","timestamp":"2026-04-04T10:01:00Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .sampleFailed(sample, error) = event else {
            return XCTFail("Expected sampleFailed, got \(event)")
        }
        XCTAssertEqual(sample, "Sample2")
        XCTAssertEqual(error, "Input file not found")
    }

    func testParseImportCompleteEvent() throws {
        let json = """
        {"event":"importComplete","completed":2,"skipped":0,"failed":1,"totalDurationSeconds":120.7,"timestamp":"2026-04-04T10:02:00Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .importComplete(completed, skipped, failed, totalDurationSeconds) = event else {
            return XCTFail("Expected importComplete, got \(event)")
        }
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(totalDurationSeconds, 120.7)
    }

    func testParseNonJSONLineReturnsNil() throws {
        let line = "INFO: Starting import pipeline..."
        let event = try CLIImportRunner.parseEvent(from: line)
        XCTAssertNil(event)
    }

    func testParseSampleSkipEvent() throws {
        let json = """
        {"event":"sampleSkip","sample":"Sample3","reason":"Bundle already exists","timestamp":"2026-04-04T10:00:30Z"}
        """
        let event = try XCTUnwrap(CLIImportRunner.parseEvent(from: json))
        guard case let .sampleSkip(sample, reason) = event else {
            return XCTFail("Expected sampleSkip, got \(event)")
        }
        XCTAssertEqual(sample, "Sample3")
        XCTAssertEqual(reason, "Bundle already exists")
    }

    // MARK: - Argument Building Tests

    func testBuildCLIArgumentsPairedEnd() {
        let r1 = URL(fileURLWithPath: "/data/reads_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/reads_R2.fastq.gz")
        let project = URL(fileURLWithPath: "/project")

        let args = CLIImportRunner.buildCLIArguments(
            r1: r1,
            r2: r2,
            projectDirectory: project,
            platform: "illumina",
            recipeName: "vsp2",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced"
        )

        XCTAssertTrue(args.starts(with: ["import", "fastq", r1.path]))
        XCTAssertTrue(args.contains(r2.path))
        XCTAssertTrue(args.contains("--project"))
        XCTAssertTrue(args.contains(project.path))
        XCTAssertTrue(args.contains("--platform"))
        XCTAssertTrue(args.contains("illumina"))
        XCTAssertTrue(args.contains("--recipe"))
        XCTAssertTrue(args.contains("vsp2"))
        XCTAssertTrue(args.contains("--quality-binning"))
        XCTAssertTrue(args.contains("--format"))
        XCTAssertTrue(args.contains("json"))
        XCTAssertTrue(args.contains("--force"))
        XCTAssertTrue(args.contains("--compression"))
        XCTAssertTrue(args.contains("balanced"))
        XCTAssertTrue(args.contains("illumina4"))
        XCTAssertFalse(args.contains("--no-optimize-storage"))
    }

    func testBuildCLIArgumentsSingleEndNoRecipe() {
        let r1 = URL(fileURLWithPath: "/data/reads.fastq.gz")
        let project = URL(fileURLWithPath: "/project")

        let args = CLIImportRunner.buildCLIArguments(
            r1: r1,
            r2: nil,
            projectDirectory: project,
            platform: "nanopore",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast"
        )

        XCTAssertTrue(args.starts(with: ["import", "fastq", r1.path]))
        XCTAssertFalse(args.contains("--recipe"))
        XCTAssertTrue(args.contains("--no-optimize-storage"))
        XCTAssertTrue(args.contains("none"))
        XCTAssertTrue(args.contains("--format"))
        XCTAssertTrue(args.contains("json"))
        XCTAssertTrue(args.contains("--force"))
        XCTAssertTrue(args.contains("--compression"))
        XCTAssertTrue(args.contains("fast"))
    }
}
