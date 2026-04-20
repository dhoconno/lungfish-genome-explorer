// NativeToolRunnerTests.swift - Tests for native bioinformatics tool discovery and execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class NativeToolRunnerTests: XCTestCase {

    // MARK: - Tool Discovery Tests

    func testToolsDirectoryDiscoveryIsOnlyRequiredWhenBundledToolsRemain() async {
        let runner = NativeToolRunner()
        let toolsDir = await runner.getToolsDirectory()
        let bundledTools = NativeTool.allCases.filter(\.isBundled)

        if bundledTools.isEmpty {
            if let toolsDir {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: toolsDir.path),
                    "Discovered tools directory should exist on disk: \(toolsDir.path)"
                )
            }
            return
        }

        XCTAssertNotNil(toolsDir, "Tools directory should be discoverable while bundled tools remain")
        if let toolsDir {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: toolsDir.path),
                "Tools directory should exist on disk: \(toolsDir.path)"
            )
        }
    }

    func testAllBundledToolsRemainAvailable() async {
        let runner = NativeToolRunner()
        let results = await runner.checkAllTools()

        for tool in NativeTool.allCases where tool.isBundled {
            XCTAssertTrue(
                results[tool] == true,
                "Bundled tool '\(tool.rawValue)' should be available; found: \(results[tool] ?? false)"
            )
        }
    }

    func testValidateBundledToolsInstallationSucceedsWhenNoBundledToolsRemain() async {
        let runner = NativeToolRunner()
        let (valid, missing) = await runner.validateBundledToolsInstallation()

        XCTAssertTrue(valid, "Bundled tool validation should succeed when every tool resolves from managed environments")
        XCTAssertTrue(missing.isEmpty)
        XCTAssertFalse(missing.contains(.clumpify))
        XCTAssertFalse(missing.contains(.fastp))
    }

    func testDeaconResolvesFromManagedLungfishEnvironment() {
        switch NativeTool.deacon.location {
        case .managed(let environment, let executableName):
            XCTAssertEqual(environment, "deacon")
            XCTAssertEqual(executableName, "deacon")
        default:
            XCTFail("Deacon should resolve from a managed tool environment")
        }
    }

    func testVariantCallingToolsResolveFromManagedEnvironments() {
        let expectations: [(NativeTool, String, String)] = [
            (.lofreq, "lofreq", "lofreq"),
            (.ivar, "ivar", "ivar"),
            (.medaka, "medaka", "medaka"),
        ]

        for (tool, environment, executable) in expectations {
            switch tool.location {
            case .managed(let actualEnvironment, let actualExecutable):
                XCTAssertEqual(actualEnvironment, environment)
                XCTAssertEqual(actualExecutable, executable)
            default:
                XCTFail("\(tool.rawValue) should resolve from a managed tool environment")
            }
        }
    }

    func testFindToolReturnsExecutableURLForBundledTools() async throws {
        let runner = NativeToolRunner()

        for tool in NativeTool.allCases where tool.isBundled {
            let url = try await runner.findTool(tool)
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: url.path),
                "\(tool.rawValue) should point to an executable file: \(url.path)"
            )
        }
    }

    func testFindToolCachesPath() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }

        let url1 = try await runner.findTool(.bgzip)
        let url2 = try await runner.findTool(.bgzip)
        XCTAssertEqual(url1, url2, "Repeated findTool calls should return the same URL")
    }

    func testClearCacheForcesFreshDiscovery() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }

        let url1 = try await runner.findTool(.samtools)
        await runner.clearCache()
        let url2 = try await runner.findTool(.samtools)

        // Paths should still be equal (same tools directory), but cache was cleared
        XCTAssertEqual(url1, url2)
    }

    // MARK: - Tool Execution Tests

    func testBgzipVersion() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await runner.run(.samtools, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "samtools --version should succeed")
        XCTAssertTrue(
            result.stdout.contains("samtools"),
            "samtools --version should mention samtools"
        )
    }

    func testBcftoolsVersion() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await runner.run(.bcftools, arguments: ["--version"])
        XCTAssertTrue(result.isSuccess, "bcftools --version should succeed")
        XCTAssertTrue(
            result.stdout.contains("bcftools"),
            "bcftools --version should mention bcftools"
        )
    }

    func testTabixVersion() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await runner.run(.tabix, arguments: ["--version"])
        // tabix --version exits 0 and prints to stderr
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("tabix") || output.contains("htslib"),
            "tabix --version should mention tabix or htslib"
        )
    }

    func testBedToBigBedUsage() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let result: NativeToolResult
        do {
            result = try await runner.run(.fastp, arguments: ["--version"])
        } catch let error as NativeToolError {
            if case .toolNotFound = error {
                throw XCTSkip("Managed fastp is not available")
            }
            throw error
        }
        // fastp --version prints to stderr
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("fastp"),
            "fastp --version should mention fastp"
        )
    }

    func testVsearchVersion() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await runner.run(.vsearch, arguments: ["--version"])
        let output = result.stdout + result.stderr
        XCTAssertTrue(
            output.contains("vsearch"),
            "vsearch --version should mention vsearch"
        )
    }

    func testCutadaptVersion() async throws {
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }

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
        let (runner, root) = try makeManagedNativeToolRunner()
        defer { try? FileManager.default.removeItem(at: root) }

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

    func testRunCancelsSubprocessAndThrowsCancellationError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeToolRunner Cancel Run \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let completedURL = root.appendingPathComponent("run-completed.txt")
        let (runner, managedRoot) = try makeCancellableManagedNativeToolRunner(root: root)
        defer { try? FileManager.default.removeItem(at: managedRoot) }

        let task = Task {
            try await runner.run(
                .seqkit,
                arguments: ["sleep-run", completedURL.path],
                timeout: 5
            )
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled run should throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await assertFileDoesNotAppear(at: completedURL, timeoutNanoseconds: 2_500_000_000)
    }

    func testRunPipelineCancelsAllSubprocessesAndThrowsCancellationError() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeToolRunner Cancel Pipeline \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceCompletedURL = root.appendingPathComponent("pipeline-source-completed.txt")
        let sinkCompletedURL = root.appendingPathComponent("pipeline-sink-completed.txt")
        let (runner, managedRoot) = try makeCancellableManagedNativeToolRunner(root: root)
        defer { try? FileManager.default.removeItem(at: managedRoot) }

        let task = Task {
            try await runner.runPipeline(
                [
                    NativePipelineStage(.seqkit, arguments: ["sleep-pipeline-source", sourceCompletedURL.path]),
                    NativePipelineStage(.seqkit, arguments: ["sleep-pipeline-sink", sinkCompletedURL.path]),
                ],
                timeout: 5
            )
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled pipeline should throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await assertFileDoesNotAppear(at: sourceCompletedURL, timeoutNanoseconds: 2_500_000_000)
        try await assertFileDoesNotAppear(at: sinkCompletedURL, timeoutNanoseconds: 2_500_000_000)
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
        XCTAssertEqual(NativeTool.tadpole.executableName, "tadpole.sh")
        XCTAssertEqual(NativeTool.reformat.executableName, "reformat.sh")
        XCTAssertFalse(NativeTool.samtools.isBundled)
        XCTAssertFalse(NativeTool.fastp.isBundled)
        XCTAssertFalse(NativeTool.clumpify.isBundled)
    }

    func testManagedCoreToolLocationsUseCondaEnvironments() {
        XCTAssertEqual(
            NativeTool.samtools.location,
            .managed(environment: "samtools", executableName: "samtools")
        )
        XCTAssertEqual(
            NativeTool.bcftools.location,
            .managed(environment: "bcftools", executableName: "bcftools")
        )
        XCTAssertEqual(
            NativeTool.bgzip.location,
            .managed(environment: "htslib", executableName: "bgzip")
        )
        XCTAssertEqual(
            NativeTool.tabix.location,
            .managed(environment: "htslib", executableName: "tabix")
        )
        XCTAssertEqual(
            NativeTool.seqkit.location,
            .managed(environment: "seqkit", executableName: "seqkit")
        )
        XCTAssertEqual(
            NativeTool.vsearch.location,
            .managed(environment: "vsearch", executableName: "vsearch")
        )
        XCTAssertEqual(
            NativeTool.cutadapt.location,
            .managed(environment: "cutadapt", executableName: "cutadapt")
        )
        XCTAssertEqual(
            NativeTool.pigz.location,
            .managed(environment: "pigz", executableName: "pigz")
        )
        XCTAssertEqual(
            NativeTool.fasterqDump.location,
            .managed(environment: "sra-tools", executableName: "fasterq-dump")
        )
        XCTAssertEqual(
            NativeTool.prefetch.location,
            .managed(environment: "sra-tools", executableName: "prefetch")
        )
        XCTAssertEqual(
            NativeTool.bedToBigBed.location,
            .managed(environment: "ucsc-bedtobigbed", executableName: "bedToBigBed")
        )
        XCTAssertEqual(
            NativeTool.bedGraphToBigWig.location,
            .managed(environment: "ucsc-bedgraphtobigwig", executableName: "bedGraphToBigWig")
        )
    }

    func testNativeToolSourcePackages() {
        XCTAssertEqual(NativeTool.samtools.sourcePackage, "samtools")
        XCTAssertEqual(NativeTool.bgzip.sourcePackage, "htslib")
        XCTAssertEqual(NativeTool.tabix.sourcePackage, "htslib")
        XCTAssertEqual(NativeTool.bedToBigBed.sourcePackage, "ucsc-tools")
        XCTAssertEqual(NativeTool.bbduk.sourcePackage, "bbmap")
        XCTAssertEqual(NativeTool.bbmerge.sourcePackage, "bbmap")
        XCTAssertEqual(NativeTool.repair.sourcePackage, "bbmap")
        XCTAssertEqual(NativeTool.tadpole.sourcePackage, "bbmap")
        XCTAssertEqual(NativeTool.reformat.sourcePackage, "bbmap")
    }

    func testNativeToolHtslibFlag() {
        XCTAssertTrue(NativeTool.bgzip.isHtslib)
        XCTAssertTrue(NativeTool.tabix.isHtslib)
        XCTAssertFalse(NativeTool.samtools.isHtslib)
        XCTAssertFalse(NativeTool.bedToBigBed.isHtslib)
    }

    func testAllCasesCount() {
        // The legacy human-scrubber executables were retired when Deacon replaced that path,
        // and the viral variant callers now add three managed tools.
        XCTAssertEqual(NativeTool.allCases.count, 23, "Should have 23 NativeTool cases including the viral variant callers")
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

    func testBBToolsArgumentsWithProjectPathsContainingSpacesBecomeSpaceFree() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeToolRunner Space Test \(UUID().uuidString)", isDirectory: true)
        let bbtoolsDir = root
            .appendingPathComponent(".lungfish/conda/envs/bbtools/bin", isDirectory: true)
        let projectDir = root.appendingPathComponent("My Genome Project.lungfish", isDirectory: true)
        let inputURL = projectDir.appendingPathComponent("reads 1.fastq.gz")
        let outputURL = projectDir.appendingPathComponent("result output.fastq.gz")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: bbtoolsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data().write(to: inputURL)

        let scriptURL = bbtoolsDir.appendingPathComponent("clumpify.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        for token in $@; do
            printf '%s\\n' "$token"
        done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: root)
        let result = try await runner.run(
            .clumpify,
            arguments: [
                "in=\(inputURL.path)",
                "out=\(outputURL.path)",
            ]
        )

        XCTAssertEqual(result.exitCode, 0, "Fake clumpify should succeed; stderr: \(result.stderr)")
        let tokens = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        XCTAssertEqual(tokens.count, 2, "BBTools wrapper should receive exactly two intact arguments: \(tokens)")
        XCTAssertTrue(tokens.allSatisfy { $0.contains("=") }, "Arguments should not be split into bare path fragments: \(tokens)")
        XCTAssertTrue(tokens.allSatisfy { !$0.contains(" ") }, "Rewritten BBTools arguments should be space-free: \(tokens)")
        XCTAssertFalse(tokens.joined(separator: "\n").contains(projectDir.path), "Safe BBTools paths should not live under the spaced project directory: \(tokens)")
    }

    // MARK: - Managed Fixture

    private func makeManagedNativeToolRunner() throws -> (runner: NativeToolRunner, root: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeToolRunner Managed Test \(UUID().uuidString)", isDirectory: true)

        let scripts: [(environment: String, executable: String, script: String)] = [
            ("samtools", "samtools", """
            #!/bin/sh
            echo "samtools 1.23"
            """),
            ("bcftools", "bcftools", """
            #!/bin/sh
            echo "bcftools 1.23"
            """),
            ("htslib", "bgzip", """
            #!/bin/sh
            echo "bgzip 1.23" >&2
            """),
            ("htslib", "tabix", """
            #!/bin/sh
            echo "tabix 1.23" >&2
            """),
            ("ucsc-bedtobigbed", "bedToBigBed", """
            #!/bin/sh
            echo "usage: bedToBigBed" >&2
            exit 1
            """),
            ("ucsc-bedgraphtobigwig", "bedGraphToBigWig", """
            #!/bin/sh
            echo "bedGraphToBigWig 1.0" >&2
            exit 1
            """),
            ("pigz", "pigz", """
            #!/bin/sh
            echo "pigz 2.0"
            """),
            ("seqkit", "seqkit", """
            #!/bin/sh
            case "$1" in
              version|--version)
                echo "seqkit v2.0"
                ;;
              seq)
                if [ $# -ge 3 ] && [ -n "$3" ]; then
                  cat "$3"
                else
                  cat
                fi
                ;;
              stats)
                awk 'BEGIN { count = 0 } /^@/ { count++ } END { print count }'
                ;;
              *)
                echo "seqkit v2.0"
                ;;
            esac
            """),
            ("fastp", "fastp", """
            #!/bin/sh
            echo "fastp 1.3.2" >&2
            """),
            ("vsearch", "vsearch", """
            #!/bin/sh
            echo "vsearch v2.29.4"
            """),
            ("cutadapt", "cutadapt", """
            #!/bin/sh
            echo "cutadapt 4.8"
            """),
            ("sra-tools", "fasterq-dump", """
            #!/bin/sh
            echo "fasterq-dump 3.1.1"
            """),
            ("sra-tools", "prefetch", """
            #!/bin/sh
            echo "prefetch 3.1.1"
            """),
        ]

        try fm.createDirectory(
            at: root.appendingPathComponent(".lungfish/conda/envs", isDirectory: true),
            withIntermediateDirectories: true
        )

        for spec in scripts {
            let executableDir = root
                .appendingPathComponent(".lungfish/conda/envs/\(spec.environment)/bin", isDirectory: true)
            try fm.createDirectory(at: executableDir, withIntermediateDirectories: true)

            let executableURL = executableDir.appendingPathComponent(spec.executable)
            try spec.script.write(to: executableURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }

        return (NativeToolRunner(toolsDirectory: nil, homeDirectory: root), root)
    }

    private func makeCancellableManagedNativeToolRunner(root: URL) throws -> (runner: NativeToolRunner, root: URL) {
        let fm = FileManager.default
        let executableDir = root
            .appendingPathComponent(".lungfish/conda/envs/seqkit/bin", isDirectory: true)
        try fm.createDirectory(at: executableDir, withIntermediateDirectories: true)

        let executableURL = executableDir.appendingPathComponent("seqkit")
        let script = """
        #!/bin/sh
        set -eu
        command="$1"
        marker="$2"
        case "$command" in
          sleep-run|sleep-pipeline-source|sleep-pipeline-sink)
            sleep 2
            printf "completed\\n" > "$marker"
            ;;
          *)
            echo "unsupported command: $command" >&2
            exit 1
            ;;
        esac
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        return (NativeToolRunner(toolsDirectory: nil, homeDirectory: root), root)
    }

    private func waitForFile(at url: URL, timeoutNanoseconds: UInt64 = 1_000_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Expected file to appear: \(url.path)")
    }

    private func assertFileDoesNotAppear(
        at url: URL,
        timeoutNanoseconds: UInt64
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                XCTFail("File should not appear after cancellation: \(url.path)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
