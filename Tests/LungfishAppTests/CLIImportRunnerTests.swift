// CLIImportRunnerTests - Tests for CLI subprocess management actor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishIO
import LungfishWorkflow
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

    func testCommandLineShellQuotesArguments() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/Volumes/iWES WNPRC/ww test/Sample R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/Volumes/iWES WNPRC/ww test/Sample R2.fastq.gz"),
            projectDirectory: URL(fileURLWithPath: "/Volumes/iWES WNPRC/ww test/ww.lungfish"),
            platform: "illumina",
            recipeName: "wastewater-metagenomics",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced"
        )

        let command = CLIImportRunner.commandLine(arguments: args)

        XCTAssertTrue(command.hasPrefix("lungfish-cli import fastq "))
        XCTAssertTrue(command.contains("'/Volumes/iWES WNPRC/ww test/Sample R1.fastq.gz'"))
        XCTAssertTrue(command.contains("--recipe wastewater-metagenomics"))
        XCTAssertTrue(command.contains("--platform illumina"))
        XCTAssertTrue(command.contains("--quality-binning illumina4"))
        XCTAssertTrue(command.contains("--compression balanced"))
    }

    func testFASTQIngestionOperationCommandPreviewMatchesCLIArguments() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R2.fastq.gz")
        )
        let project = URL(fileURLWithPath: "/Volumes/iWES_WNPRC/ww_test/ww.lungfish")
        let config = FASTQImportConfiguration(
            inputFiles: [pair.r1, pair.r2!],
            detectedPlatform: .illumina,
            confirmedPlatform: .illumina,
            pairingMode: .pairedEnd,
            qualityBinning: .illumina4,
            skipClumpify: false,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: "wastewater-metagenomics",
            compressionLevel: .balanced
        )

        let command = FASTQIngestionService.cliImportCommandPreview(
            pair: pair,
            projectDirectory: project,
            importConfig: config
        )

        XCTAssertEqual(
            command,
            "lungfish-cli import fastq /Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R1.fastq.gz /Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R2.fastq.gz --project /Volumes/iWES_WNPRC/ww_test/ww.lungfish --platform illumina --format json --quality-binning illumina4 --compression balanced --force --recipe wastewater-metagenomics"
        )
    }

    func testCancelTerminatesCLIProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; while true; do sleep 1; done' &
        echo '{"event":"importStart","sampleCount":1,"recipeName":"test"}'
        while true; do sleep 1; done
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let priorPIDFile = ProcessInfo.processInfo.environment["LUNGFISH_TEST_CHILD_PID_FILE"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        setenv("LUNGFISH_TEST_CHILD_PID_FILE", childPIDFile.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
            if let priorPIDFile {
                setenv("LUNGFISH_TEST_CHILD_PID_FILE", priorPIDFile, 1)
            } else {
                unsetenv("LUNGFISH_TEST_CHILD_PID_FILE")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.start(
                title: "FASTQ Import: cancellation test",
                detail: "Starting",
                operationType: .ingestion
            )
        }
        addTeardownBlock {
            await MainActor.run {
                OperationCenter.shared.clearItem(id: operationID)
            }
        }

        let runner = CLIImportRunner()
        let runTask = Task {
            await runner.run(
                arguments: [],
                operationID: operationID,
                projectDirectory: tempDir,
                onBundleCreated: { _ in },
                onError: { _ in }
            )
        }

        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
        }
        XCTAssertTrue(Self.isProcessRunning(pid: childPID))

        await runner.cancel()

        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 2.0)
        XCTAssertTrue(childExited, "Cancelling the CLI import must terminate child tool processes, not only lungfish-cli")

        if !childExited {
            kill(childPID, SIGKILL)
        }
        _ = await runTask.value
    }

    func testResolveCLIPathPrefersBundledSiblingExecutable() throws {
        let tempDir = try makeTemporaryDirectory()
        let executableDir = tempDir.appendingPathComponent("Lungfish.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDir, withIntermediateDirectories: true)

        let mainExecutable = executableDir.appendingPathComponent("Lungfish")
        FileManager.default.createFile(atPath: mainExecutable.path, contents: Data())

        let bundledCLI = executableDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: bundledCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: mainExecutable,
            currentWorkingDirectoryURL: nil,
            pathLookup: { nil }
        )

        XCTAssertEqual(resolved, bundledCLI)
    }

    func testResolveCLIPathFallsBackToWorkspaceDebugBinary() throws {
        let tempDir = try makeTemporaryDirectory()
        let sourceRoot = tempDir.appendingPathComponent("repo", isDirectory: true)
        let debugDir = sourceRoot.appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
        let workingDirectory = sourceRoot.appendingPathComponent("Sources/LungfishApp/Services", isDirectory: true)
        try FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sourceRoot.appendingPathComponent("Package.swift").path,
            contents: Data("// swift-tools-version: 6.2\n".utf8)
        )

        let debugCLI = debugDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: debugCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: debugCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: nil,
            currentWorkingDirectoryURL: workingDirectory,
            pathLookup: { nil }
        )

        XCTAssertEqual(resolved, debugCLI)
    }

    func testResolveCLIPathPrefersExplicitEnvironmentOverride() throws {
        let tempDir = try makeTemporaryDirectory()
        let explicitCLI = tempDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: explicitCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: explicitCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: nil,
            currentWorkingDirectoryURL: nil,
            environment: ["LUNGFISH_CLI_PATH": explicitCLI.path],
            pathLookup: { nil }
        )

        XCTAssertEqual(resolved, explicitCLI)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 2.0) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(contents) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(
            domain: "CLIImportRunnerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fake CLI child PID"]
        )
    }

    private static func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessRunning(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isProcessRunning(pid: pid)
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}
