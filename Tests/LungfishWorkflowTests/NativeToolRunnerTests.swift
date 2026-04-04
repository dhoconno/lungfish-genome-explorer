// NativeToolRunnerTests.swift - Tests for native bioinformatics tool discovery and execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class NativeToolRunnerTests: XCTestCase {

    // MARK: - Tool Discovery Tests

    func testToolsDirectoryDiscovery() async {
        let runner = NativeToolRunner()
        let toolsDir = await runner.getToolsDirectory()
        XCTAssertNotNil(toolsDir, "Tools directory should be discoverable from test environment")
        if let toolsDir {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: toolsDir.path),
                "Tools directory should exist on disk: \(toolsDir.path)"
            )
        }
    }

    func testAllToolsAvailable() async {
        let runner = NativeToolRunner()
        let results = await runner.checkAllTools()

        for tool in NativeTool.allCases {
            XCTAssertTrue(
                results[tool] == true,
                "Tool '\(tool.rawValue)' should be available; found: \(results[tool] ?? false)"
            )
        }
    }

    func testValidateToolsInstallation() async {
        let runner = NativeToolRunner()
        let (valid, missing) = await runner.validateToolsInstallation()

        XCTAssertTrue(valid, "All tools should be present")
        XCTAssertTrue(
            missing.isEmpty,
            "No tools should be missing; missing: \(missing.map(\.rawValue))"
        )
    }

    func testFindToolReturnsExecutableURL() async throws {
        let runner = NativeToolRunner()

        for tool in NativeTool.allCases {
            let url = try await runner.findTool(tool)
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: url.path),
                "\(tool.rawValue) should point to an executable file: \(url.path)"
            )
        }
    }

    func testFindToolCachesPath() async throws {
        let runner = NativeToolRunner()

        let url1 = try await runner.findTool(.bgzip)
        let url2 = try await runner.findTool(.bgzip)
        XCTAssertEqual(url1, url2, "Repeated findTool calls should return the same URL")
    }

    func testClearCacheForcesFreshDiscovery() async throws {
        let runner = NativeToolRunner()

        let url1 = try await runner.findTool(.samtools)
        await runner.clearCache()
        let url2 = try await runner.findTool(.samtools)

        // Paths should still be equal (same tools directory), but cache was cleared
        XCTAssertEqual(url1, url2)
    }

    // MARK: - Tool Execution Tests

    func testBgzipVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.bgzip, arguments: ["--version"])
        // bgzip --version prints to stderr and exits 0
        XCTAssertTrue(
            result.isSuccess || result.exitCode == 0,
            "bgzip --version should succeed"
        )
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("bgzip") || output.contains("htslib"),
            "bgzip --version output should mention bgzip or htslib"
        )
    }

    func testSamtoolsVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.samtools, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "samtools --version should succeed")
        XCTAssertTrue(
            result.stdout.contains("samtools"),
            "samtools --version should mention samtools"
        )
    }

    func testBcftoolsVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.bcftools, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "bcftools --version should succeed")
        XCTAssertTrue(
            result.stdout.contains("bcftools"),
            "bcftools --version should mention bcftools"
        )
    }

    func testTabixVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.tabix, arguments: ["--version"])
        // tabix --version exits 0 and prints to stderr
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("tabix") || output.contains("htslib"),
            "tabix --version should mention tabix or htslib"
        )
    }

    func testBedToBigBedUsage() async throws {
        let runner = NativeToolRunner()
        // bedToBigBed with no arguments prints usage and exits with non-zero
        let result = try await runner.run(.bedToBigBed, arguments: [])
        // We just verify it ran without crashing (exit code will be non-zero)
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("bedToBigBed") || output.contains("usage") || output.contains("bed"),
            "bedToBigBed should produce usage output"
        )
    }

    func testFastpVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.fastp, arguments: ["--version"])
        // fastp --version prints to stderr
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("fastp"),
            "fastp --version should mention fastp"
        )
    }

    func testVsearchVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.vsearch, arguments: ["--version"])
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("vsearch"),
            "vsearch --version should mention vsearch"
        )
    }

    func testCutadaptVersion() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.run(.cutadapt, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "cutadapt --version should succeed")
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("4."),
            "cutadapt --version should print a semantic version; output: \(output)"
        )
    }

    // MARK: - Pipeline Tests

    func testSingleStagePipeline() async throws {
        let runner = NativeToolRunner()
        let result = try await runner.runPipeline(
            [NativePipelineStage(.seqkit, arguments: ["version"])]
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.exitCodes.count, 1)
        XCTAssertTrue(result.stdout.contains("seqkit"))
    }

    func testTwoStagePipeline() async throws {
        // seqkit version | seqkit seq --upper-case (seq will read the version text as invalid FASTQ and exit,
        // but the pipe itself should work)
        // Better test: use samtools --version | grep samtools via pipeline
        // Actually, let's test with a simple echo-like pattern using seqkit
        let runner = NativeToolRunner()

        // Create a temp FASTQ file for the pipeline test
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fqContent = """
        @read1
        ACGTACGTACGT
        +
        FFFFFFFFFFFF
        @read2
        NNNNACGTNNNN
        +
        FFFFFFFFFFFF

        """
        let inputURL = tempDir.appendingPathComponent("test.fq")
        try fqContent.write(to: inputURL, atomically: true, encoding: .utf8)

        // seqkit seq --upper-case test.fq | seqkit stats --tabular
        let result = try await runner.runPipeline([
            NativePipelineStage(.seqkit, arguments: ["seq", "--upper-case", inputURL.path]),
            NativePipelineStage(.seqkit, arguments: ["stats", "--tabular"]),
        ])

        XCTAssertTrue(result.isSuccess, "Pipeline should succeed; stderr: \(result.combinedStderr)")
        XCTAssertEqual(result.exitCodes.count, 2)
        XCTAssertTrue(result.stdout.contains("2"), "Stats should show 2 reads")
    }

    func testPipelineWithFileOutput() async throws {
        let runner = NativeToolRunner()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineFileTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fqContent = """
        @read1
        ACGTACGTACGT
        +
        FFFFFFFFFFFF
        @read2
        TTTTTTTTTTTTT
        +
        FFFFFFFFFFFFF

        """
        let inputURL = tempDir.appendingPathComponent("test.fq")
        try fqContent.write(to: inputURL, atomically: true, encoding: .utf8)

        let outputURL = tempDir.appendingPathComponent("output.fq")

        // seqkit seq --upper-case | seqkit seq --reverse > output.fq
        let result = try await runner.runPipelineWithFileOutput(
            [
                NativePipelineStage(.seqkit, arguments: ["seq", "--upper-case", inputURL.path]),
                NativePipelineStage(.seqkit, arguments: ["seq", "--reverse"]),
            ],
            outputFile: outputURL
        )

        XCTAssertTrue(result.isSuccess, "Pipeline should succeed; stderr: \(result.combinedStderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertFalse(output.isEmpty, "Output file should not be empty")
    }

    func testEmptyPipelineThrows() async {
        let runner = NativeToolRunner()
        do {
            _ = try await runner.runPipeline([])
            XCTFail("Empty pipeline should throw")
        } catch let error as NativeToolError {
            if case .invalidArguments = error {
                // expected
            } else {
                XCTFail("Expected invalidArguments error")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPipelineResultProperties() {
        let success = NativePipelineResult(
            exitCodes: [0, 0], stderrByStage: ["", ""], stdout: "output"
        )
        XCTAssertTrue(success.isSuccess)
        XCTAssertNil(success.firstFailureCode)

        let failure = NativePipelineResult(
            exitCodes: [0, 1], stderrByStage: ["", "error"], stdout: ""
        )
        XCTAssertFalse(failure.isSuccess)
        XCTAssertEqual(failure.firstFailureCode, 1)
        XCTAssertEqual(failure.combinedStderr, "error")
    }

    // MARK: - Injected Tools Directory Tests

    func testInitWithExplicitToolsDirectory() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeToolRunnerTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runner = NativeToolRunner(toolsDirectory: tempDir)
        let dir = await runner.getToolsDirectory()
        XCTAssertEqual(dir, tempDir, "Injected tools directory should be used")
    }

    func testInitWithNilToolsDirectory() async {
        let runner = NativeToolRunner(toolsDirectory: nil)
        let dir = await runner.getToolsDirectory()
        XCTAssertNil(dir, "Nil tools directory should remain nil")
    }

    // MARK: - NativeTool Enum Tests

    func testNativeToolExecutableNames() {
        XCTAssertEqual(NativeTool.samtools.executableName, "samtools")
        XCTAssertEqual(NativeTool.bcftools.executableName, "bcftools")
        XCTAssertEqual(NativeTool.bgzip.executableName, "bgzip")
        XCTAssertEqual(NativeTool.tabix.executableName, "tabix")
        XCTAssertEqual(NativeTool.bedToBigBed.executableName, "bedToBigBed")
        XCTAssertEqual(NativeTool.bedGraphToBigWig.executableName, "bedGraphToBigWig")
        XCTAssertEqual(NativeTool.seqkit.executableName, "seqkit")
        XCTAssertEqual(NativeTool.fastp.executableName, "fastp")
        XCTAssertEqual(NativeTool.vsearch.executableName, "vsearch")
        XCTAssertEqual(NativeTool.clumpify.executableName, "clumpify.sh")
        XCTAssertEqual(NativeTool.bbduk.executableName, "bbduk.sh")
        XCTAssertEqual(NativeTool.bbmerge.executableName, "bbmerge.sh")
        XCTAssertEqual(NativeTool.repair.executableName, "repair.sh")
        XCTAssertEqual(NativeTool.java.executableName, "java")
        XCTAssertEqual(NativeTool.clumpify.relativeExecutablePath, "bbtools/clumpify.sh")
        XCTAssertEqual(NativeTool.bbduk.relativeExecutablePath, "bbtools/bbduk.sh")
        XCTAssertEqual(NativeTool.bbmerge.relativeExecutablePath, "bbtools/bbmerge.sh")
        XCTAssertEqual(NativeTool.repair.relativeExecutablePath, "bbtools/repair.sh")
        XCTAssertEqual(NativeTool.tadpole.executableName, "tadpole.sh")
        XCTAssertEqual(NativeTool.tadpole.relativeExecutablePath, "bbtools/tadpole.sh")
        XCTAssertEqual(NativeTool.reformat.executableName, "reformat.sh")
        XCTAssertEqual(NativeTool.reformat.relativeExecutablePath, "bbtools/reformat.sh")
        XCTAssertEqual(NativeTool.java.relativeExecutablePath, "jre/bin/java")
    }

    func testNativeToolSourcePackages() {
        XCTAssertEqual(NativeTool.samtools.sourcePackage, "samtools")
        XCTAssertEqual(NativeTool.bgzip.sourcePackage, "htslib")
        XCTAssertEqual(NativeTool.tabix.sourcePackage, "htslib")
        XCTAssertEqual(NativeTool.bedToBigBed.sourcePackage, "ucsc-tools")
        XCTAssertEqual(NativeTool.bbduk.sourcePackage, "bbtools")
        XCTAssertEqual(NativeTool.bbmerge.sourcePackage, "bbtools")
        XCTAssertEqual(NativeTool.repair.sourcePackage, "bbtools")
        XCTAssertEqual(NativeTool.tadpole.sourcePackage, "bbtools")
        XCTAssertEqual(NativeTool.reformat.sourcePackage, "bbtools")
    }

    func testNativeToolHtslibFlag() {
        XCTAssertTrue(NativeTool.bgzip.isHtslib)
        XCTAssertTrue(NativeTool.tabix.isHtslib)
        XCTAssertFalse(NativeTool.samtools.isHtslib)
        XCTAssertFalse(NativeTool.bedToBigBed.isHtslib)
    }

    func testAllCasesCount() {
        XCTAssertEqual(NativeTool.allCases.count, 22, "Should have 22 bundled tools")
    }

    // MARK: - Error Tests

    func testToolNotFoundError() {
        let error = NativeToolError.toolNotFound("missing_tool")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("missing_tool"))
    }

    func testToolsDirectoryNotFoundError() {
        let error = NativeToolError.toolsDirectoryNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Tools directory"))
    }

    func testExecutionFailedError() {
        let error = NativeToolError.executionFailed("samtools", 1, "some error")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("samtools"))
        XCTAssertTrue(error.errorDescription!.contains("exit code 1"))
    }

    func testTimeoutError() {
        let error = NativeToolError.timeout("bgzip", 300)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("bgzip"))
        XCTAssertTrue(error.errorDescription!.contains("300"))
    }

    // MARK: - Bounded stderr capture (TailBuffer)

    /// Verifies that maxStderrBytes caps the captured stderr to at most that many bytes.
    /// Generates ~128 KB of stderr via bash and passes maxStderrBytes: 65536 (64 KB).
    func testMaxStderrBytesTruncatesLargeStderr() async throws {
        let runner = NativeToolRunner()
        let bash = URL(fileURLWithPath: "/bin/bash")
        // Write a line that is ~100 bytes, repeated 1400 times ≈ 140 KB to stderr.
        let script = """
        for i in $(seq 1 1400); do
            printf '%s\\n' "STDERR_LINE_$(printf '%090d' $i)" >&2
        done
        """
        let maxBytes = 65_536
        let result = try await runner.runProcess(
            executableURL: bash,
            arguments: ["-c", script],
            maxStderrBytes: maxBytes
        )
        XCTAssertEqual(result.exitCode, 0, "bash script should exit 0")
        let capturedBytes = result.stderr.utf8.count
        XCTAssertLessThanOrEqual(
            capturedBytes,
            maxBytes,
            "Captured stderr (\(capturedBytes) bytes) should be ≤ maxStderrBytes (\(maxBytes))"
        )
        // Also verify we captured something non-trivial (the tail, not silence)
        XCTAssertGreaterThan(capturedBytes, 0, "Should have captured some stderr tail")
        XCTAssertTrue(result.stderr.contains("STDERR_LINE_"), "Tail should contain recognizable output")
    }

    /// Verifies that without maxStderrBytes the full stderr is captured (regression guard).
    func testWithoutMaxStderrBytesCapturesFullStderr() async throws {
        let runner = NativeToolRunner()
        let bash = URL(fileURLWithPath: "/bin/bash")
        // Write exactly 10 lines of known content to stderr.
        let script = """
        for i in $(seq 1 10); do
            printf 'LINE_%d\\n' $i >&2
        done
        """
        let result = try await runner.runProcess(
            executableURL: bash,
            arguments: ["-c", script]
        )
        XCTAssertEqual(result.exitCode, 0)
        for i in 1...10 {
            XCTAssertTrue(result.stderr.contains("LINE_\(i)"), "Full capture should include LINE_\(i)")
        }
    }
}
