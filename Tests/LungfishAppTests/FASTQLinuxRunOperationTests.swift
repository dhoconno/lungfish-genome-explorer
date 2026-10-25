// FASTQLinuxRunOperationTests.swift - The Operations rows of the adopt of a Linux run and of the plan sheet (C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import XCTest
import os
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// ARCH 2: each row's command is the argv the run executes, and the adopt's is the envelope's argv. UX 4: each row ends
/// when its command ends.
@MainActor
final class FASTQLinuxRunOperationTests: XCTestCase {
    func testAdoptRowRecordsTheCommandTheCLIRuns() throws {
        let folder = URL(fileURLWithPath: "/data/returned/S1", isDirectory: true)
        let project = URL(fileURLWithPath: "/data/Project.lungfish", isDirectory: true)
        var launched: (id: UUID, arguments: [String])?
        let result = FASTQIngestionService.beginLinuxRunAdoptOperation(
            resultFolder: folder, projectDirectory: project, routeContext: nil
        ) { launched = ($0, $1) }
        guard case .started(let id) = result else { return XCTFail("the adopt row did not start") }
        defer { _ = OperationCenter.shared.fail(id: id, detail: "test", errorMessage: "test") }
        let run = try XCTUnwrap(launched)
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(
            run.arguments,
            ExecutorRunAdoption.cliArguments(resultFolder: folder, projectDirectory: project, eventsOn: true),
            "the run is the adopt's own argv, which the envelope records after the executable"
        )
        XCTAssertEqual(
            run.arguments,
            ["import", "fastq", "/data/returned/S1", "--adopt", "--project", "/data/Project.lungfish", "--format", "json"]
        )
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(item.cliCommand, CLIImportRunner.commandLine(arguments: run.arguments))
        XCTAssertEqual(item.operationType, .ingestion)
        XCTAssertEqual(item.title, "Linux Run Result: S1")
        // beginLinuxRunAdoptOperation's row parses as the CLI's own command, the one the adopt runs.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertTrue(command.adoptOptions.adopt)
        XCTAssertEqual(command.input, [folder.path])
        XCTAssertEqual(command.project, project.path)
        XCTAssertNil(command.adoptRefusal)
    }

    func testPlanRowRecordsTheCommandTheSheetRuns() throws {
        let arguments = FASTQPlanSheetModel.cliArguments(
            inputs: [URL(fileURLWithPath: "/data/reads")], planFolder: URL(fileURLWithPath: "/data/plan-1"),
            executorManifest: URL(fileURLWithPath: "/app/LinuxExecutor/x86_64/manifest.json"),
            image: URL(fileURLWithPath: "/app/image.json"), imageToolManifest: URL(fileURLWithPath: "/app/image-manifest.json"),
            stagingFolder: "/staging/groups/g/1/lge", threads: 8, clumpifyHeapGB: 16, optimizeStorage: true, tool: .bbtools
        )
        let request = FASTQPlanSheetRequest(arguments: arguments, planFolder: URL(fileURLWithPath: "/data/plan-1"))
        var launched: [String]?
        let result = FASTQIngestionService.beginLinuxPlanOperation(request: request, routeContext: nil) { launched = $1 }
        guard case .started(let id) = result else { return XCTFail("the plan row did not start") }
        defer { _ = OperationCenter.shared.fail(id: id, detail: "test", errorMessage: "test") }
        XCTAssertEqual(launched, arguments)
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(item.cliCommand, CLIImportRunner.commandLine(arguments: arguments))
        XCTAssertEqual(item.title, "Plan for a Linux Machine: plan-1")
        // beginLinuxPlanOperation's row parses as the CLI's own `import fastq --write-plan`.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FastqSubcommand.self)
        XCTAssertEqual(command.planOptions.writePlan, "/data/plan-1")
        XCTAssertEqual(command.planOptions.stagingFolder, "/staging/groups/g/1/lge")
        XCTAssertEqual(command.importOptions.clumpingTool, "bbtools")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.clumpifyHeapGB, 16)
    }

    // MARK: The end of a run (UX 4)

    /// The runner ends the row only for a failure. On success it hands over the bundles and returns, so the caller
    /// ends the row, as the in-app import does. A stand-in `lungfish-cli` prints the version 2 lines of a plan and of an
    /// adopt, and each row is begun and launched as the app begins and launches it.
    func testLinuxRunRowEndsWhenTheCommandEnds() async throws {
        // The plan's complete line names the plan folder and the staged files, and no bundle.
        let plan = URL(fileURLWithPath: "/data/plan-1", isDirectory: true)
        try installStubCLI(printing: [
            Self.startLine,
            #"{"artifacts":[{"kind":"staging-r1","path":"/staging/lge/S1_R1.fastq.gz","role":"S1"}],"event":"complete","message":"Wrote the submit folder for 1 sample(s)","outputs":["/data/plan-1","/data/plan-1/S1"],"progress":1,"schemaVersion":2}"#,
        ])
        let planID = try XCTUnwrap(startPlanRow(planFolder: plan), "the plan row did not start")
        let planEnd = await rowAfterItEnds(planID)
        let planRow = try XCTUnwrap(planEnd)
        XCTAssertEqual(planRow.state, .completed, "the plan row ends with its command, and it reads \"\(planRow.detail)\"")
        XCTAssertEqual(planRow.detail, "Plan written to plan-1")
        XCTAssertEqual(planRow.bundleURLs, [])
        XCTAssertNil(planRow.errorMessage)

        // The adopt's complete line names one bundle.
        let bundle = "/data/Project.lungfish/Imports/S1.lungfishfastq"
        try installStubCLI(printing: [
            Self.startLine,
            #"{"artifacts":[{"kind":"fastq","path":"\#(bundle)","provenancePath":"\#(bundle)/.lungfish-provenance.json","role":"bundle"}],"event":"complete","message":"Adopted 1 sample","output":"\#(bundle)","outputs":["\#(bundle)"],"progress":1,"schemaVersion":2}"#,
        ])
        let handed = OSAllocatedUnfairLock(initialState: [URL]())
        let adoptID = try XCTUnwrap(startAdoptRow(handed: handed), "the adopt row did not start")
        let adoptEnd = await rowAfterItEnds(adoptID)
        let adoptRow = try XCTUnwrap(adoptEnd)
        XCTAssertEqual(adoptRow.state, .completed, "the adopt row ends with its command, and it reads \"\(adoptRow.detail)\"")
        XCTAssertEqual(adoptRow.detail, "Imported S1.lungfishfastq")
        XCTAssertEqual(adoptRow.bundleURLs.map(\.path), [bundle])
        XCTAssertNil(adoptRow.errorMessage)
        XCTAssertEqual(handed.withLock { $0 }.map(\.path), [bundle], "the sidebar still hears of the bundle")
    }

    /// A command that fails leaves its row failed with the command's own message, and no bundle is handed over.
    func testLinuxRunRowStaysFailedWithTheCLIsMessage() async throws {
        await OperationCenter.useTemporaryFailureReportsForTesting()
        let message = "The returned folder has no run-record.json."
        try installStubCLI(
            printing: [Self.startLine, #"{"error":"\#(message)","event":"failed","schemaVersion":2}"#], status: 64
        )
        let handed = OSAllocatedUnfairLock(initialState: [URL]())
        let id = try XCTUnwrap(startAdoptRow(handed: handed), "the adopt row did not start")
        let ended = await rowAfterItEnds(id)
        let row = try XCTUnwrap(ended)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, message)
        XCTAssertEqual(row.bundleURLs, [])
        XCTAssertEqual(handed.withLock { $0 }, [])
    }

    /// Cancel on the row stops the command, and the row reads Cancelled at once. It does not wait for the cancel grace
    /// period of OperationCenter (10 seconds), which ends a row whose worker never ended it with a warning that says the
    /// worker did not respond. The first pass cancels as the command launches and the second while it runs.
    func testLinuxRunRowIsCancelledAtOnceWhenTheCommandStops() async throws {
        for waitsForTheCommand in [false, true] {
            let ready = FileManager.default.temporaryDirectory
                .appendingPathComponent("linux-run-ready-\(UUID().uuidString)")
            addTeardownBlock { try? FileManager.default.removeItem(at: ready) }
            try installStubCLI(printing: [Self.startLine], readyFile: ready)
            let handed = OSAllocatedUnfairLock(initialState: [URL]())
            let id = try XCTUnwrap(startAdoptRow(handed: handed), "the adopt row did not start")
            if waitsForTheCommand {
                let deadline = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < deadline, !FileManager.default.fileExists(atPath: ready.path) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the stand-in command started")
            }
            OperationCenter.shared.cancel(id: id)
            let ended = await rowAfterItEnds(id, timeout: .seconds(6))
            let row = try XCTUnwrap(ended)
            let pass = waitsForTheCommand ? "while the command runs" : "as the command launches"
            XCTAssertEqual(row.state, .cancelled, "the row reads \"\(row.detail)\" 6 seconds after Cancel \(pass)")
            XCTAssertNil(row.errorMessage, pass)
            XCTAssertFalse(
                row.logEntries.contains { $0.message.contains("did not respond") },
                "the worker answered the cancel, so the row logs no forced end \(pass)"
            )
            XCTAssertEqual(handed.withLock { $0 }, [], pass)
        }
    }

    private static let startLine = #"{"event":"start","message":"Starting FASTQ import","progress":0,"schemaVersion":2}"#

    /// A stand-in `lungfish-cli` that prints `lines` and exits with `status`. With `readyFile` it prints them, writes
    /// that file and waits for SIGTERM, which ends it with status 125 as a cancelled run ends. `LUNGFISH_CLI_PATH` names
    /// the stand-in until the test ends.
    private func installStubCLI(printing lines: [String], status: Int32 = 0, readyFile: URL? = nil) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-run-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let printed = folder.appendingPathComponent("stdout.ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: printed, atomically: true, encoding: .utf8)
        var script = "#!/bin/sh\n"
        if let readyFile {
            script += "trap 'exit 125' TERM\ncat '\(printed.path)'\nexec 2>/dev/null\ntouch '\(readyFile.path)'\n"
            script += "while true; do sleep 0.1; done\n"
        } else {
            script += "cat '\(printed.path)'\nexit \(status)\n"
        }
        let cli = folder.appendingPathComponent("lungfish-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let prior = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        addTeardownBlock {
            if let prior { setenv("LUNGFISH_CLI_PATH", prior, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Begins the plan row and launches its command as `AppDelegate.writeFASTQPlanFromURLs` does.
    private func startPlanRow(planFolder: URL) -> UUID? {
        let request = FASTQPlanSheetRequest(
            arguments: ["import", "fastq", "/data/reads", "--write-plan", planFolder.path], planFolder: planFolder
        )
        let result = FASTQIngestionService.beginLinuxPlanOperation(request: request, routeContext: nil) { id, arguments in
            FASTQIngestionService.runLinuxRunCommand(
                arguments: arguments, operationID: id, projectDirectory: planFolder, onBundleCreated: { _ in }
            )
        }
        guard case .started(let id) = result else { return nil }
        return id
    }

    /// Begins the adopt row and launches its command as `AppDelegate.adoptLinuxRunFromURL` does. `handed` collects the
    /// bundles the app's sidebar reload hears of.
    private func startAdoptRow(handed: OSAllocatedUnfairLock<[URL]>) -> UUID? {
        let project = URL(fileURLWithPath: "/data/Project.lungfish", isDirectory: true)
        let result = FASTQIngestionService.beginLinuxRunAdoptOperation(
            resultFolder: URL(fileURLWithPath: "/data/returned/S1", isDirectory: true),
            projectDirectory: project, routeContext: nil
        ) { id, arguments in
            FASTQIngestionService.runLinuxRunCommand(
                arguments: arguments, operationID: id, projectDirectory: project,
                onBundleCreated: { url in handed.withLock { $0.append(url) } }
            )
        }
        guard case .started(let id) = result else { return nil }
        return id
    }

    /// The row once it is neither running nor cancelling, or its last state when `timeout` passes.
    private func rowAfterItEnds(_ id: UUID, timeout: Duration = .seconds(15)) async -> OperationCenter.Item? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let item = OperationCenter.shared.items.first(where: { $0.id == id }), !item.state.isActive {
                return item
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return OperationCenter.shared.items.first { $0.id == id }
    }
}
