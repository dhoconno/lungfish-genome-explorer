import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

final class CLIMSAAlignmentRunnerTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testBuildArgumentsUseJSONProgressFormat() {
        let input = URL(fileURLWithPath: "/project/input.fasta")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")
        let output = project.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)

        let args = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: [input],
            projectURL: project,
            outputURL: output,
            name: "Aligned",
            strategy: "auto",
            outputOrder: "input",
            threads: 8,
            extraArguments: []
        )

        XCTAssertEqual(args, [
            "align", "mafft", input.path,
            "--project", project.path,
            "--output", output.path,
            "--name", "Aligned",
            "--strategy", "auto",
            "--output-order", "input",
            "--threads", "8",
            "--format", "json",
        ])
    }

    func testBuildArgumentsPassesAdvancedMAFFTOptions() {
        let input = URL(fileURLWithPath: "/project/input.fasta")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")

        let args = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: [input],
            projectURL: project,
            outputURL: nil,
            name: nil,
            strategy: "auto",
            outputOrder: "input",
            threads: nil,
            extraArguments: ["--op", "1.53", "--leavegappyregion"]
        )

        XCTAssertEqual(args.suffix(4), [
            "--extra-args",
            "--op 1.53 --leavegappyregion",
            "--format",
            "json",
        ])
    }

    func testBuildArgumentsPassesResolvedMAFFTOptionsAndFASTQAssemblyFlag() {
        let input = URL(fileURLWithPath: "/project/contigs.fastq")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")

        let args = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: [input],
            projectURL: project,
            outputURL: nil,
            name: "Contigs",
            strategy: "linsi",
            outputOrder: "aligned",
            threads: nil,
            sequenceType: "nucleotide",
            adjustDirection: "accurate",
            symbols: "any",
            allowNondeterministicThreads: true,
            allowFASTQAssemblyInputs: true,
            extraArguments: []
        )

        XCTAssertTrue(args.contains("--sequence-type"))
        XCTAssertTrue(args.contains("nucleotide"))
        XCTAssertTrue(args.contains("--adjust-direction"))
        XCTAssertTrue(args.contains("accurate"))
        XCTAssertTrue(args.contains("--symbols"))
        XCTAssertTrue(args.contains("any"))
        XCTAssertTrue(args.contains("--allow-nondeterministic-threads"))
        XCTAssertTrue(args.contains("--allow-fastq-assembly-inputs"))
        XCTAssertEqual(args.suffix(2), ["--format", "json"])
    }

    func testRunStreamsProgressEventsIntoOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let bundle = tempDir.appendingPathComponent("aligned.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"start","message":"Starting MAFFT alignment for 1 input file(s).","progress":0}'
        printf '%s\\n' '{"event":"progress","progress":0.5,"message":"Running MAFFT..."}'
        printf '%s\\n' '{"event":"log","level":"warning","message":"Duplicate row names were rewritten."}'
        printf '%s\\n' '{"event":"complete","output":"\(bundle.path)","outputs":["\(bundle.path)"],"message":"rows=2 alignedLength=6"}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MAFFT Alignment",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentGeneration,
                cliCommand: nil
            ).rowID
        }

        let result = try await CLIMSAAlignmentRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        // The event glue hops to the main queue; wait for the row to catch up
        // instead of sleeping a fixed 50 ms.
        await waitUntil {
            await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }?.logEntries.contains { $0.message == "Duplicate row names were rewritten." } == true
            }
        }
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.alignedLength, 6)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Running MAFFT...")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "Duplicate row names were rewritten." } == true)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    /// Phase 2.6 lane C6. The captured run of `align mafft` played through a stand-in CLI, and the
    /// same run as a version 1 CLI wrote it, with no version and no artifacts. Both give the
    /// bundle, the row count and the aligned length, and leave the row Completed with the bundle.
    func testRunReadsTheBundleAndCountsFromTheCapturedRunAndFromAVersion1CLI() async throws {
        let url = repoRoot.appendingPathComponent("Tests/Fixtures/cli-events/commands/align-mafft/complete.ndjson")
        let captured = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let decoder = CLIEventLineDecoder()
        guard case let .complete(outputs, message)? = try decoder.decode(line: try XCTUnwrap(captured.last)),
              let bundlePath = outputs.first,
              let counts = message else {
            return XCTFail("The captured run does not end in a completion with a bundle")
        }
        let version1 = try captured.map { line -> String in
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            object["schemaVersion"] = nil
            object["artifacts"] = nil
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        XCTAssertEqual(outputs, [bundlePath], "The completion names the bundle as its one output")

        for (name, lines) in [("captured", captured), ("version 1", version1)] {
            let tempDir = try makeTemporaryDirectory()
            let text = tempDir.appendingPathComponent("lines.ndjson")
            try (lines.joined(separator: "\n") + "\n").write(to: text, atomically: true, encoding: .utf8)
            let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
            try "#!/bin/sh\n/bin/cat '\(text.path)'\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
            let opID = await MainActor.run {
                OperationCenter.shared.begin(
                    title: "MAFFT Alignment",
                    detail: "Launching...",
                    operationType: .multipleSequenceAlignmentGeneration,
                    cliCommand: nil
                ).rowID
            }

            let result = try await CLIMSAAlignmentRunner(cliURLOverride: fakeCLI).run(arguments: [], operationID: opID)

            XCTAssertEqual(result.bundleURL.path, bundlePath, name)
            XCTAssertEqual(result.rowCount, 5, name)
            XCTAssertEqual(result.alignedLength, 29834, name)
            XCTAssertEqual(counts, "rows=5 alignedLength=29834", name)
            await MainActor.run {
                _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
                OperationCenter.shared.clearItem(id: opID)
            }
        }
    }

    /// Phase 2.10 lane U32. The captured run reports MAFFT's own lines as progress messages, with
    /// blank lines among them and a bar that stays at one half until the last message. The bridge
    /// logs each message once, a blank line never blanks the row's detail, and the log holds no
    /// entry twice in a row.
    func testTheCapturedRunLogsMAFFTsLinesOnceAndNeverShowsABlankDetail() async throws {
        let url = repoRoot.appendingPathComponent("Tests/Fixtures/cli-events/commands/align-mafft/complete.ndjson")
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\n/bin/cat '\(url.path)'\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MAFFT Alignment",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentGeneration,
                cliCommand: nil
            ).rowID
        }

        _ = try await CLIMSAAlignmentRunner(cliURLOverride: fakeCLI).run(arguments: [], operationID: opID)
        await waitUntil(timeout: .seconds(30)) {
            await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }?.detail == "MAFFT alignment complete."
            }
        }
        let item = await MainActor.run { OperationCenter.shared.items.first { $0.id == opID } }
        let logged = (item?.logEntries ?? []).filter { !$0.isElisionMarker }.map { "\($0.level.rawValue): \($0.message)" }

        XCTAssertEqual(logged.first, "info: Starting MAFFT alignment for 1 input file(s).")
        XCTAssertTrue(logged.contains("info: Gap Penalty = -1.53, +0.00, +0.00"), "a line of MAFFT's own reaches the log")
        XCTAssertEqual(logged.last, "info: MAFFT alignment complete.")
        XCTAssertEqual(logged.count, 47, "the captured run's non-empty messages, each once in a row")
        XCTAssertFalse(logged.contains("info: "), "a blank line is not logged")
        XCTAssertEqual(zip(logged, logged.dropFirst()).filter { $0 == $1 }.count, 0, "no entry repeats the one before it")
        XCTAssertEqual(item?.detail, "MAFFT alignment complete.", "the blank lines never blanked the detail")
        XCTAssertEqual(item?.progress, 1.0)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
            OperationCenter.shared.clearItem(id: opID)
        }
    }

    /// A version 2 completion types the bundle, and the runner reads it by role, even when it is
    /// not the first output. A completion with no artifact falls back on the first output.
    func testRunReadsTheTypedBundleByRoleAndFallsBackOnTheFirstOutput() async throws {
        let cases: [(name: String, line: String, bundle: String)] = [
            (
                "typed",
                #"{"schemaVersion":2,"event":"complete","outputs":["/work/log.txt","/work/Aligned.lungfishmsa"],"message":"rows=3 alignedLength=40","artifacts":[{"kind":"multiple-sequence-alignment","path":"/work/Aligned.lungfishmsa","role":"alignment"}]}"#,
                "/work/Aligned.lungfishmsa"
            ),
            (
                "untyped",
                #"{"event":"complete","outputs":["/work/First.lungfishmsa","/work/log.txt"],"message":"rows=3 alignedLength=40"}"#,
                "/work/First.lungfishmsa"
            ),
        ]
        for testCase in cases {
            let tempDir = try makeTemporaryDirectory()
            let text = tempDir.appendingPathComponent("lines.ndjson")
            try (testCase.line + "\n").write(to: text, atomically: true, encoding: .utf8)
            let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
            try "#!/bin/sh\n/bin/cat '\(text.path)'\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)
            let opID = await MainActor.run {
                OperationCenter.shared.begin(
                    title: "MAFFT Alignment",
                    detail: "Launching...",
                    operationType: .multipleSequenceAlignmentGeneration,
                    cliCommand: nil
                ).rowID
            }

            let result = try await CLIMSAAlignmentRunner(cliURLOverride: fakeCLI).run(arguments: [], operationID: opID)

            XCTAssertEqual(result.bundleURL.path, testCase.bundle, testCase.name)
            XCTAssertEqual(result.rowCount, 3, testCase.name)
            XCTAssertEqual(result.alignedLength, 40, testCase.name)
            await MainActor.run {
                _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
                OperationCenter.shared.clearItem(id: opID)
            }
        }
    }

    func testCancelTerminatesRunningMAFFTProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let readyURL = tempDir.appendingPathComponent("ready")
        let rootPIDURL = tempDir.appendingPathComponent("root.pid")
        let childPIDURL = tempDir.appendingPathComponent("child.pid")
        // The child outlives every wait below, so only a real kill can end it
        // in time, and the waits leave room for the parallel unit tier.
        let childNaturalCompletionSeconds = 60.0
        let script = """
        #!/bin/sh
        echo $$ > '\(rootPIDURL.path)'
        /bin/sh -c 'trap "" TERM HUP; sleep \(Int(childNaturalCompletionSeconds)) & wait' &
        child=$!
        echo "$child" > '\(childPIDURL.path)'
        printf '%s\\n' '{"event":"start","message":"Starting MAFFT alignment.","progress":0}'
        touch '\(readyURL.path)'
        wait "$child"
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MAFFT Alignment",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentGeneration,
                cliCommand: nil
            ).rowID
        }
        // Cancelling the runner leaves the row Running, since the caller ends it. Finish it here, so a process that
        // runs every class of the bundle (the full tier) does not carry a Running row into the classes after this one.
        addTeardownBlock {
            await MainActor.run {
                _ = OperationCenter.shared.complete(id: opID, detail: "Test finished")
                OperationCenter.shared.clearItem(id: opID)
            }
        }
        let runner = CLIMSAAlignmentRunner(cliURLOverride: fakeCLI)
        let runTask = Task {
            try await runner.run(arguments: [], operationID: opID)
        }

        try await waitForFile(readyURL)
        let rootPID = try readPID(rootPIDURL)
        let childPID = try readPID(childPIDURL)
        defer {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
        }

        let start = Date()
        runner.cancel()
        _ = await runTask.result
        try await waitForProcessExit(pid: childPID)
        let cancelElapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            cancelElapsed,
            childNaturalCompletionSeconds - 0.5,
            "MAFFT cancellation should not wait for the child process to finish naturally"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-msa-alignment-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanupURLs.append(url)
        return url
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
    }

    private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessTreeTerminator.processExists(pid: pid) {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Process \(pid) was still running after cancellation")
    }

    private func readPID(_ url: URL) throws -> Int32 {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(text), "Expected pid in \(url.path)")
    }

    func testBuildArgumentsEmitsOneSequenceFlagPerIncludedName() throws {
        let args = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: [URL(fileURLWithPath: "/tmp/in.fasta")],
            projectURL: URL(fileURLWithPath: "/tmp/Project.lungfish"),
            outputURL: nil,
            name: "Subset",
            strategy: "auto",
            outputOrder: "input",
            threads: nil,
            extraArguments: [],
            includedSequenceNames: ["seqA", "seqB"]
        )
        XCTAssertEqual(args.filter { $0 == "--sequence" }.count, 2)
        let index = try XCTUnwrap(args.firstIndex(of: "seqA"))
        XCTAssertEqual(args[index - 1], "--sequence")
    }

    func testBuildArgumentsOmitsSequenceFlagsWhenNoSelection() {
        let args = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: [URL(fileURLWithPath: "/tmp/in.fasta")],
            projectURL: URL(fileURLWithPath: "/tmp/Project.lungfish"),
            outputURL: nil, name: nil, strategy: "auto", outputOrder: "input",
            threads: nil, extraArguments: []
        )
        XCTAssertFalse(args.contains("--sequence"))
    }

}
