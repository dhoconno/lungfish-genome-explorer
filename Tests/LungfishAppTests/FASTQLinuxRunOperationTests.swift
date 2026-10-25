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

    // MARK: A returned batch folder (C5 D2 a, UX-c5 point 7)

    private static let project = URL(fileURLWithPath: "/data/Project.lungfish", isDirectory: true)
    private static let batchBundles = ["A", "B", "C"].map { "/data/Project.lungfish/Imports/\($0).lungfishfastq" }

    /// Three bundles end the row with the sample count and all three bundles, never with the last bundle's name alone.
    func testLinuxRunRowEndNamesSampleCountForBatch() {
        let bundles = Self.batchBundles.map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(
            FASTQIngestionService.linuxRunRowEnd(.init(bundles: bundles), planFolder: Self.project),
            .completed(detail: "Imported 3 samples", bundleURLs: bundles)
        )
    }

    /// One bundle keeps the words of the adopt of one plan folder, "Imported <bundle>".
    func testLinuxRunRowEndKeepsOneBundleWords() {
        let bundle = URL(fileURLWithPath: "/data/Project.lungfish/Imports/S1.lungfishfastq")
        XCTAssertEqual(
            FASTQIngestionService.linuxRunRowEnd(.init(bundles: [bundle]), planFolder: Self.project),
            .completed(detail: "Imported S1.lungfishfastq", bundleURLs: [bundle])
        )
    }

    /// UX 3: each sample's step reaches the row's detail while the batch adopt runs, in the sheet batch's form, and the
    /// row then ends Completed with the sample count and every bundle, which the sidebar hears of.
    func testBatchAdoptRowShowsEachSampleThenTheCount() async throws {
        let steps = ["Checking 3 of 3: C\u{2026}", "Adopting 1 of 3: A\u{2026}", "Adopting 2 of 3: B\u{2026}"]
        let outputs = Self.batchBundles.map { #""\#($0)""# }.joined(separator: ",")
        let artifacts = Self.batchBundles.map { #"{"kind":"fastq","path":"\#($0)","role":"bundle"}"# }.joined(separator: ",")
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("linux-run-gate-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: gate) }
        try installStubCLI(
            printing: [Self.startLine] + steps.enumerated().map { index, step in
                #"{"event":"progress","message":"\#(step)","progress":0.\#(index + 2),"schemaVersion":2}"#
            },
            thenWaitingFor: gate,
            printing: [
                #"{"artifacts":[\#(artifacts)],"event":"complete","message":"Adopted 3 samples","outputs":[\#(outputs)],"progress":1,"schemaVersion":2}"#,
            ]
        )
        let handed = OSAllocatedUnfairLock(initialState: [URL]())
        let id = try XCTUnwrap(startAdoptRow(handed: handed), "the adopt row did not start")
        let shown = await rowWhen(id) { $0.detail == steps[2] }
        XCTAssertEqual(shown?.detail, steps[2], "the last step reached the row's detail while the adopt ran")
        XCTAssertEqual(shown?.state, .running)
        try Data().write(to: gate)
        let ended = await rowAfterItEnds(id)
        let row = try XCTUnwrap(ended)
        XCTAssertEqual(row.state, .completed, "the row reads \"\(row.detail)\"")
        XCTAssertEqual(row.detail, "Imported 3 samples")
        XCTAssertEqual(row.bundleURLs.map(\.path), Self.batchBundles)
        XCTAssertEqual(handed.withLock { $0 }.map(\.path), Self.batchBundles, "the sidebar hears of every bundle")
    }

    /// A write failure after bundle 2 of 3 fails the row with the CLI's message as its detail and the three lines as its
    /// error detail. It never reads Completed or Completed with Warnings, and the runner hands over no bundle.
    func testBatchAdoptRowFailsOnWriteFailure() async throws {
        let message = "The adopt failed after 2 of 3 samples. There is not enough space on the disk."
        let detail = "Imported: A.lungfishfastq, B.lungfishfastq.\nNot imported: C.\n"
            + "To adopt the rest, delete the imported bundles and adopt the batch again."
        let row = try await failedBatchRow(message: message, detail: detail, status: 64)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.detail, message)
        XCTAssertEqual(row.errorMessage, message)
        XCTAssertEqual(row.errorDetail, detail)
        XCTAssertEqual(row.bundleURLs, [])
    }

    /// A refusal fails the row with "Nothing was imported." and lists each refused sample in the error detail.
    func testBatchAdoptRowFailsOnRefusalAndListsEachSample() async throws {
        let message = "2 of 3 samples were refused. Nothing was imported."
        let detail = "B: its job returned nothing. The folder holds no run-record.json.\n"
            + "C: its job returned no reads. The payload out/C.fastq.gz is missing from the folder.\n"
            + "Fix or rerun each refused sample on the Linux machine, then adopt the whole batch again."
        let row = try await failedBatchRow(message: message, detail: detail, status: 3)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.detail, message)
        XCTAssertEqual(row.errorDetail, detail)
        XCTAssertEqual(row.bundleURLs, [])
    }

    /// The row of a batch adopt whose stand-in CLI prints two adopted steps and then `failed` with `message` and
    /// `detail`, exiting with `status`.
    private func failedBatchRow(message: String, detail: String, status: Int32) async throws -> OperationCenter.Item {
        await OperationCenter.useTemporaryFailureReportsForTesting()
        let escaped = detail.replacingOccurrences(of: "\n", with: "\\n")
        try installStubCLI(printing: [
            Self.startLine,
            #"{"event":"progress","message":"Adopted A as A.lungfishfastq","progress":0.4,"schemaVersion":2}"#,
            #"{"detail":"\#(escaped)","error":"\#(message)","event":"failed","schemaVersion":2}"#,
        ], status: status)
        let handed = OSAllocatedUnfairLock(initialState: [URL]())
        let id = try XCTUnwrap(startAdoptRow(handed: handed), "the adopt row did not start")
        let ended = await rowAfterItEnds(id)
        XCTAssertEqual(handed.withLock { $0 }, [], "no bundle is handed over for a failed batch")
        return try XCTUnwrap(ended)
    }

    /// A stand-in `lungfish-cli` that prints `first`, waits until `gate` exists, prints `then` and exits 0.
    private func installStubCLI(printing first: [String], thenWaitingFor gate: URL, printing then: [String]) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-run-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let firstFile = folder.appendingPathComponent("first.ndjson")
        let thenFile = folder.appendingPathComponent("then.ndjson")
        try (first.joined(separator: "\n") + "\n").write(to: firstFile, atomically: true, encoding: .utf8)
        try (then.joined(separator: "\n") + "\n").write(to: thenFile, atomically: true, encoding: .utf8)
        let script = "#!/bin/sh\ncat '\(firstFile.path)'\nwhile [ ! -e '\(gate.path)' ]; do sleep 0.05; done\n"
            + "cat '\(thenFile.path)'\nexit 0\n"
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

    /// The row once `condition` holds, or its last state when `timeout` passes.
    private func rowWhen(
        _ id: UUID, timeout: Duration = .seconds(15), _ condition: (OperationCenter.Item) -> Bool
    ) async -> OperationCenter.Item? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let item = OperationCenter.shared.items.first(where: { $0.id == id }), condition(item) { return item }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return OperationCenter.shared.items.first { $0.id == id }
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
