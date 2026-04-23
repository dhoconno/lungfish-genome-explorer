// AlignmentDuplicateServiceTests.swift - Tests for duplicate workflow helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AlignmentDuplicateServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignmentDuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testUniqueDeduplicatedBundleURLUsesDefaultSuffixWhenAvailable() {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(for: source)
        XCTAssertEqual(candidate.lastPathComponent, "example-deduplicated.lungfishref")
    }

    func testUniqueDeduplicatedBundleURLAdvancesSuffixWhenExistingPathPresent() throws {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let existing = tempDir.appendingPathComponent("example-deduplicated.lungfishref")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(for: source)
        XCTAssertEqual(candidate.lastPathComponent, "example-deduplicated-2.lungfishref")
    }

    func testUniqueDeduplicatedBundleURLPrefersExplicitOutputWhenUnused() {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let preferred = tempDir.appendingPathComponent("custom-output.lungfishref")
        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(
            for: source,
            preferred: preferred
        )
        XCTAssertEqual(candidate, preferred)
    }

    func testAlignmentDuplicateErrorDescriptionsAreNonEmpty() {
        let errors: [AlignmentDuplicateError] = [
            .noAlignmentTracks,
            .sourcePathNotFound("/tmp/missing.bam"),
            .samtoolsFailed("mock failure")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }

    func testMarkdupPipelineRunsCanonicalCommandOrder() async throws {
        let inputURL = tempDir.appendingPathComponent("input.bam")
        try Data("bam".utf8).write(to: inputURL)

        let outputURL = tempDir.appendingPathComponent("out/output.bam")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        try Data(">chr1\nACGT\n".utf8).write(to: referenceURL)

        let runner = RecordingSamtoolsRunner()
        let pipeline = LungfishApp.AlignmentMarkdupPipeline(samtoolsRunner: runner)

        let result = try await pipeline.run(
            inputURL: inputURL,
            outputURL: outputURL,
            removeDuplicates: false,
            referenceFastaPath: referenceURL.path,
            progressHandler: nil
        )

        let commands = await runner.recordedArguments
        XCTAssertEqual(commands.count, 5)
        XCTAssertEqual(commands[0], [
            "sort", "-n", "-o", result.intermediateFiles.nameSortedBAM.path,
            "--reference", referenceURL.path,
            inputURL.path
        ])
        XCTAssertEqual(commands[1], [
            "fixmate", "-m",
            "--reference", referenceURL.path,
            result.intermediateFiles.nameSortedBAM.path,
            result.intermediateFiles.fixmateBAM.path
        ])
        XCTAssertEqual(commands[2], [
            "sort", "-o", result.intermediateFiles.coordinateSortedBAM.path,
            "--reference", referenceURL.path,
            result.intermediateFiles.fixmateBAM.path
        ])
        XCTAssertEqual(commands[3], [
            "markdup",
            result.intermediateFiles.coordinateSortedBAM.path,
            outputURL.path
        ])
        XCTAssertEqual(commands[4], ["index", outputURL.path])
        XCTAssertFalse(commands[3].contains("-r"))
    }

    func testMarkdupPipelineAddsRemoveFlagWhenDeduplicating() async throws {
        let inputURL = tempDir.appendingPathComponent("input.bam")
        try Data("bam".utf8).write(to: inputURL)

        let outputURL = tempDir.appendingPathComponent("out/output.bam")
        let runner = RecordingSamtoolsRunner()
        let pipeline = LungfishApp.AlignmentMarkdupPipeline(samtoolsRunner: runner)

        let result = try await pipeline.run(
            inputURL: inputURL,
            outputURL: outputURL,
            removeDuplicates: true,
            referenceFastaPath: nil,
            progressHandler: nil
        )

        let commands = await runner.recordedArguments
        XCTAssertEqual(commands[3], [
            "markdup",
            "-r",
            result.intermediateFiles.coordinateSortedBAM.path,
            outputURL.path
        ])
    }

    func testMarkdupPipelineMapsWorkflowSamtoolsFailuresToAlignmentDuplicateError() async throws {
        let inputURL = tempDir.appendingPathComponent("input.bam")
        try Data("bam".utf8).write(to: inputURL)

        let outputURL = tempDir.appendingPathComponent("out/output.bam")
        let pipeline = LungfishApp.AlignmentMarkdupPipeline(samtoolsRunner: FailingSamtoolsRunner())

        do {
            _ = try await pipeline.run(
                inputURL: inputURL,
                outputURL: outputURL,
                removeDuplicates: false,
                referenceFastaPath: nil,
                progressHandler: nil
            )
            XCTFail("Expected samtools failure")
        } catch let error as AlignmentDuplicateError {
            guard case .samtoolsFailed(let message) = error else {
                return XCTFail("Unexpected duplicate error: \(error)")
            }
            XCTAssertEqual(message, "samtools exploded")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor RecordingSamtoolsRunner: LungfishApp.AlignmentSamtoolsRunning {
    private(set) var recordedArguments: [[String]] = []

    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        recordedArguments.append(arguments)

        if let outputIndex = arguments.firstIndex(of: "-o"), outputIndex + 1 < arguments.count {
            FileManager.default.createFile(atPath: arguments[outputIndex + 1], contents: Data())
        } else if arguments.first == "markdup", let outputPath = arguments.last {
            FileManager.default.createFile(atPath: outputPath, contents: Data())
        } else if arguments.first == "index", arguments.count >= 2 {
            FileManager.default.createFile(atPath: arguments[1] + ".bai", contents: Data())
        }

        return NativeToolResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor FailingSamtoolsRunner: LungfishApp.AlignmentSamtoolsRunning {
    func runSamtools(arguments: [String], timeout: TimeInterval) async throws -> NativeToolResult {
        NativeToolResult(exitCode: 1, stdout: "", stderr: "samtools exploded")
    }
}
