import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

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

    func testParseCompleteEvent() throws {
        let json = """
        {"event":"msaAlignmentComplete","bundle":"/project/Project.lungfish/Aligned.lungfishmsa","rowCount":3,"alignedLength":19,"warningCount":1}
        """

        let event = try XCTUnwrap(CLIMSAAlignmentRunner.parseEvent(from: json))

        guard case let .complete(bundle, rowCount, alignedLength, warningCount) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(bundle, "/project/Project.lungfish/Aligned.lungfishmsa")
        XCTAssertEqual(rowCount, 3)
        XCTAssertEqual(alignedLength, 19)
        XCTAssertEqual(warningCount, 1)
    }

    func testRunStreamsProgressEventsIntoOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let bundle = tempDir.appendingPathComponent("aligned.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"msaAlignmentStart","tool":"mafft","sourceCount":1}'
        printf '%s\\n' '{"event":"msaAlignmentProgress","progress":0.5,"message":"Running MAFFT..."}'
        printf '%s\\n' '{"event":"msaAlignmentWarning","message":"Duplicate row names were rewritten."}'
        printf '%s\\n' '{"event":"msaAlignmentComplete","bundle":"\(bundle.path)","rowCount":2,"alignedLength":6,"warningCount":1}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "MAFFT Alignment",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentGeneration
            )
        }

        let result = try await CLIMSAAlignmentRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        try await Task.sleep(nanoseconds: 50_000_000)
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.alignedLength, 6)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Running MAFFT...")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "Duplicate row names were rewritten." } == true)
        await MainActor.run {
            OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    func testCancelTerminatesRunningMAFFTProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let readyURL = tempDir.appendingPathComponent("ready")
        let rootPIDURL = tempDir.appendingPathComponent("root.pid")
        let childPIDURL = tempDir.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        echo $$ > '\(rootPIDURL.path)'
        /bin/sh -c 'trap "" TERM HUP; sleep 3 & wait' &
        child=$!
        echo "$child" > '\(childPIDURL.path)'
        printf '%s\\n' '{"event":"msaAlignmentStart","tool":"mafft","sourceCount":1}'
        touch '\(readyURL.path)'
        wait "$child"
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.start(
                title: "MAFFT Alignment",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentGeneration
            )
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

        XCTAssertLessThan(cancelElapsed, 1.0, "MAFFT cancellation should not wait for the child process to finish naturally")
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

    private func waitForFile(_ url: URL, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
    }

    private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 2) async throws {
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
}
