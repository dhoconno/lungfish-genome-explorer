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
        XCTAssertEqual(NativeTool.clumpify.executableName, "clumpify.sh")
        XCTAssertEqual(NativeTool.java.executableName, "java")
        XCTAssertEqual(NativeTool.clumpify.relativeExecutablePath, "bbtools/clumpify.sh")
        XCTAssertEqual(NativeTool.java.relativeExecutablePath, "jre/bin/java")
    }

    func testNativeToolSourcePackages() {
        XCTAssertEqual(NativeTool.samtools.sourcePackage, "samtools")
        XCTAssertEqual(NativeTool.bgzip.sourcePackage, "htslib")
        XCTAssertEqual(NativeTool.tabix.sourcePackage, "htslib")
        XCTAssertEqual(NativeTool.bedToBigBed.sourcePackage, "ucsc-tools")
    }

    func testNativeToolHtslibFlag() {
        XCTAssertTrue(NativeTool.bgzip.isHtslib)
        XCTAssertTrue(NativeTool.tabix.isHtslib)
        XCTAssertFalse(NativeTool.samtools.isHtslib)
        XCTAssertFalse(NativeTool.bedToBigBed.isHtslib)
    }

    func testAllCasesCount() {
        XCTAssertEqual(NativeTool.allCases.count, 12, "Should have 12 bundled tools")
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
}
