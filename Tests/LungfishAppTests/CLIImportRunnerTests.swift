// CLIImportRunnerTests - Tests for CLI subprocess management actor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Darwin
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

private final class CLIImportRunnerStringCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { values }
    }
}

private final class CLIImportRunnerCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.withLock {
            completed = true
        }
    }

    func isCompleted() -> Bool {
        lock.withLock { completed }
    }

    func waitUntilCompleted(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCompleted() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return isCompleted()
    }
}

final class CLIImportRunnerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await OperationCenter.useTemporaryFailureReportsForTesting()
    }


    // MARK: - Events

    func testRunForwardsNoticeEventToOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        try """
        #!/bin/sh
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        echo '{"event":"log","level":"warning","message":"Sample1 — Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads.","schemaVersion":2}'
        echo '{"event":"complete","outputs":["/project/Imports/Sample1.lungfishfastq"],"schemaVersion":2}'
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: Trim Galore notice test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        await CLIImportRunner().run(
            arguments: [],
            operationID: operationID,
            projectDirectory: tempDir,
            onBundleCreated: { _ in },
            onError: { _ in }
        )

        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == operationID }
        }
        XCTAssertTrue(item?.logEntries.contains {
            $0.level == .warning
                && $0.message == "Sample1 — Trim Galore --clumpify also performs adapter/quality filtering and may remove short reads."
        } == true)
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
        // --force must never be passed unless the caller explicitly
        // opts in (i.e. the user chose Replace in the duplicate dialog).
        XCTAssertFalse(args.contains("--force"))
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
        // --force must never be passed unless the caller explicitly
        // opts in (i.e. the user chose Replace in the duplicate dialog).
        XCTAssertFalse(args.contains("--force"))
        XCTAssertTrue(args.contains("--compression"))
        XCTAssertTrue(args.contains("fast"))
    }

    /// Regression: --force is appended only when the caller passes
    /// `force: true` (i.e. after the user explicitly chose Replace).
    func testBuildCLIArgumentsPassesForceOnlyWhenExplicitlyRequested() {
        let base: (URL, URL?, URL, String, String?, String, Bool, String) = (
            URL(fileURLWithPath: "/data/reads.fastq.gz"), nil,
            URL(fileURLWithPath: "/project"), "illumina", nil,
            "illumina4", true, "balanced"
        )

        let withoutForce = CLIImportRunner.buildCLIArguments(
            r1: base.0, r2: base.1, projectDirectory: base.2,
            platform: base.3, recipeName: base.4, qualityBinning: base.5,
            optimizeStorage: base.6, compressionLevel: base.7
        )
        XCTAssertFalse(withoutForce.contains("--force"))

        let withForce = CLIImportRunner.buildCLIArguments(
            r1: base.0, r2: base.1, projectDirectory: base.2,
            platform: base.3, recipeName: base.4, qualityBinning: base.5,
            optimizeStorage: base.6, compressionLevel: base.7,
            force: true
        )
        XCTAssertTrue(withForce.contains("--force"))
    }

    /// Regression: an explicit bundle name reaches the CLI as `--name`,
    /// so Keep Both and sample-sheet names are not silently dropped.
    func testBuildCLIArgumentsForwardsBundleNameAsNameOption() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "illumina4",
            optimizeStorage: true,
            compressionLevel: "balanced",
            bundleName: "Sample1 2"
        )

        let nameIndex = args.firstIndex(of: "--name")
        XCTAssertNotNil(nameIndex)
        if let nameIndex {
            XCTAssertEqual(args[nameIndex + 1], "Sample1 2")
        }
    }

    func testBuildCLIArgumentsIncludesExplicitClumpingTool() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "illumina4",
            optimizeStorage: true,
            clumpingTool: .trimGalore,
            compressionLevel: "balanced"
        )

        XCTAssertTrue(args.contains("--clumping-tool"))
        XCTAssertTrue(args.contains("trim-galore"))
    }

    func testBuildCLIArgumentsCombinesVSP2TargetEnrichmentWithTrimGalore() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: "vsp2-target-enrichment",
            qualityBinning: "illumina4",
            optimizeStorage: true,
            clumpingTool: .trimGalore,
            compressionLevel: "balanced"
        )

        let recipeIndex = args.firstIndex(of: "--recipe")!
        let toolIndex = args.firstIndex(of: "--clumping-tool")!
        XCTAssertEqual(args[recipeIndex + 1], "vsp2-target-enrichment")
        XCTAssertEqual(args[toolIndex + 1], "trim-galore")
    }

    func testBuildCLIArgumentsTreatsNoClumpingToolAsNoOptimizeStorage() {
        let args = CLIImportRunner.buildCLIArguments(
            r1: URL(fileURLWithPath: "/data/reads.fastq.gz"),
            r2: nil,
            projectDirectory: URL(fileURLWithPath: "/project"),
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "illumina4",
            optimizeStorage: true,
            clumpingTool: .none,
            compressionLevel: "balanced"
        )

        XCTAssertTrue(args.contains("--no-optimize-storage"))
        XCTAssertFalse(args.contains("--clumping-tool"))
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

        // --force is no longer appended unconditionally — it is only
        // passed after the user explicitly chooses Replace in the duplicate
        // dialog. This preview reflects the default (no --force) command.
        // The sheet's Pairing choice is pinned as --pairing (2026-09-24). The
        // Platform popup was left on its detection, so --platform auto.
        XCTAssertEqual(
            command,
            "lungfish-cli import fastq /Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R1.fastq.gz /Volumes/iWES_WNPRC/ww_test/WI_Madison_MMSD_20260414_S7_R2.fastq.gz --project /Volumes/iWES_WNPRC/ww_test/ww.lungfish --platform auto --pairing paired --format json --quality-binning illumina4 --compression balanced --recipe wastewater-metagenomics"
        )
    }

    func testCancelTerminatesCLIProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; while true; do sleep 1; done' &
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
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
            OperationCenter.shared.begin(
                title: "FASTQ Import: cancellation test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
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

        let childExited = await Self.waitUntilProcessExits(pid: childPID, timeout: 30)
        XCTAssertTrue(childExited, "Cancelling the CLI import must terminate child tool processes, not only lungfish-cli")

        if !childExited {
            kill(childPID, SIGKILL)
        }
        _ = await runTask.value
    }

    func testRunUsesStructuredSampleFailureAsFinalOperationDetail() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let structuredError = "Recipe 'Illumina Amplicon Merge' cannot be applied to sample 'Solo': requires paired-end reads (R1 and R2), but only R1 was detected."
        let script = """
        #!/bin/sh
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        echo '{"event":"progress","message":"Importing Solo (1/1)","progress":0,"schemaVersion":2}'
        echo '{"event":"log","level":"error","message":"Solo failed: \(structuredError)","schemaVersion":2}'
        echo '{"error":"Solo: \(structuredError)","event":"failed","schemaVersion":2}'
        exit 64
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", fakeCLI.path, 1)
        defer {
            if let priorCLIPath {
                setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "FASTQ Import: structured failure test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        let errors = CLIImportRunnerStringCollector()
        let runner = CLIImportRunner()

        await runner.run(
            arguments: [],
            operationID: operationID,
            projectDirectory: tempDir,
            onBundleCreated: { _ in },
            onError: { errors.append($0) }
        )

        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == operationID }
        }
        let failedItem = try XCTUnwrap(item)
        XCTAssertEqual(failedItem.state, .failed)
        XCTAssertTrue(
            failedItem.detail.contains("requires paired-end reads"),
            "Final operation detail should preserve the structured sample failure, got: \(failedItem.detail)"
        )
        XCTAssertTrue(
            failedItem.errorMessage?.contains("requires paired-end reads") == true,
            "Final operation error summary should preserve the structured sample failure, got: \(String(describing: failedItem.errorMessage))"
        )
        XCTAssertTrue(errors.snapshot().contains { $0.contains("requires paired-end reads") })
    }

    func testRunReturnsAfterParentCLIExitsWhenDescendantKeepsStdoutPipeOpen() async throws {
        let tempDir = try makeTemporaryDirectory()
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        /bin/sh -c 'echo $$ > "$LUNGFISH_TEST_CHILD_PID_FILE"; sleep 60' &
        echo '{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}'
        echo '{"event":"progress","message":"Sample1: Compute statistics","progress":0.8,"schemaVersion":2}'
        echo '{"event":"log","level":"info","message":"Sample1 — bundle created","schemaVersion":2}'
        echo '{"artifacts":[{"kind":"fastq","path":"/project/Imports/Sample1.lungfishfastq","role":"bundle"}],"event":"complete","outputs":["/project/Imports/Sample1.lungfishfastq"],"schemaVersion":2}'
        exit 0
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
            OperationCenter.shared.begin(
                title: "FASTQ Import: stdout pipe lifecycle test",
                detail: "Starting",
                operationType: .ingestion,
                cliCommand: nil
            ).rowID
        }
        addTeardownBlock {
            await Self.finishAndClearOperation(operationID)
        }

        let bundles = CLIImportRunnerStringCollector()
        let runner = CLIImportRunner()
        let completion = CLIImportRunnerCompletionFlag()

        let runTask = Task {
            await runner.run(
                arguments: [],
                operationID: operationID,
                projectDirectory: tempDir,
                onBundleCreated: { bundles.append($0.lastPathComponent) },
                onError: { _ in }
            )
            completion.markCompleted()
        }

        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
        }

        // The descendant holds stdout for 60 s. A runner that waited for EOF
        // would miss this 30 s window, which leaves room for the parallel unit
        // tier, and the wait returns as soon as the run does.
        let returnedBeforeTimeout = await completion.waitUntilCompleted(timeout: 30)
        if !returnedBeforeTimeout {
            await runner.cancel()
            if Self.isProcessRunning(pid: childPID) {
                kill(childPID, SIGKILL)
            }
        }
        _ = await runTask.value

        XCTAssertTrue(
            returnedBeforeTimeout,
            "CLIImportRunner should return when the parent lungfish-cli exits, even if a descendant still holds stdout open"
        )
        // The output a child process kept open is incomplete, so the run fails, as ToolProcess fails
        // any run whose output it could not finish reading, and no bundle is handed over. The S1
        // runner failed the row the same way but had handed the bundle over as the sample finished.
        XCTAssertEqual(bundles.snapshot(), [])
        let item = await MainActor.run { OperationCenter.shared.items.first { $0.id == operationID } }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertTrue(item?.errorMessage?.contains("a child process kept it open") == true, String(describing: item?.errorMessage))
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

    func testResolveCLIPathUsesSwiftPMBinPathForWorkspacePackage() throws {
        let tempDir = try makeTemporaryDirectory()
        let sourceRoot = tempDir.appendingPathComponent("repo", isDirectory: true)
        let binDir = tempDir.appendingPathComponent("swiftpm-bin", isDirectory: true)
        let workingDirectory = sourceRoot.appendingPathComponent("Sources/LungfishApp/Services", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sourceRoot.appendingPathComponent("Package.swift").path,
            contents: Data("// swift-tools-version: 6.2\n".utf8)
        )

        let debugCLI = binDir.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: debugCLI.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: debugCLI.path)

        let resolved = CLIImportRunner.resolveCLIPath(
            mainExecutableURL: nil,
            currentWorkingDirectoryURL: workingDirectory,
            pathLookup: { nil },
            swiftPMBinPathLookup: { packageRoot in
                XCTAssertEqual(packageRoot, sourceRoot)
                return binDir
            }
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

    /// Finishes, then removes, a row a test began on the shared OperationCenter.
    ///
    /// `CLIImportRunner` fails the row itself when the CLI fails. After a clean exit it
    /// leaves the row running for its caller to complete with the new bundle, as
    /// `FASTQIngestionService.runIngestAndBundle` does. These tests are that caller, so
    /// the row is completed before it is cleared, because `clearItem` skips a running
    /// row. Two tests used to leave a running row behind, and a later suite in the same
    /// process that expected no active row failed.
    @MainActor
    private static func finishAndClearOperation(_ operationID: UUID) {
        OperationCenter.shared.complete(id: operationID, detail: "Test finished")
        OperationCenter.shared.clearItem(id: operationID)
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

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 30.0) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? readRepositorySource(url)
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
        ProcessTreeTerminator.processExists(pid: pid)
    }
}
