import XCTest
import Darwin
@testable import LungfishApp
@testable import LungfishWorkflow

final class CLIVariantCallingRunnerTests: XCTestCase {
    func testCancelTerminatesRunningProcessTree() async throws {
        let tempDir = try makeTemporaryDirectory()
        let rootPIDFile = tempDir.appendingPathComponent("root.pid")
        let childPIDFile = tempDir.appendingPathComponent("child.pid")
        let scriptURL = tempDir.appendingPathComponent("variant-cli-stub.sh")
        let rootPIDPath = shellQuote(rootPIDFile.path)
        let childPIDPath = shellQuote(childPIDFile.path)
        let script = """
        #!/bin/sh
        echo $$ > \(rootPIDPath)
        /bin/sh -c 'trap "" TERM HUP INT; echo $$ > "$1"; while true; do sleep 1; done' sh \(childPIDPath) &
        while true; do sleep 1; done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let runner = CLIVariantCallingRunner(cliBinaryPathProvider: { scriptURL })
        let task = Task {
            try await runner.run(
                arguments: [],
                onEvent: { _ in }
            )
        }

        let rootPID = try await waitForPIDFile(rootPIDFile)
        let childPID = try await waitForPIDFile(childPIDFile)
        addTeardownBlock {
            ProcessTreeTerminator.terminate(rootPID: rootPID, gracePeriod: 0)
            ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0)
        }

        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: rootPID))
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: childPID))

        await runner.cancel()

        let rootExited = await waitUntilProcessExits(pid: rootPID, timeout: 2.0)
        let childExited = await waitUntilProcessExits(pid: childPID, timeout: 2.0)
        XCTAssertTrue(rootExited, "Cancelling the variant runner must terminate the CLI root process")
        XCTAssertTrue(childExited, "Cancelling the variant runner must terminate descendant tool processes")

        do {
            _ = try await task.value
            XCTFail("Expected cancelled runner to throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testRunnerParsesRunCompleteEvent() throws {
        let json = """
        {"event":"runComplete","message":"done","variantTrackID":"vc-1","variantTrackName":"Sample 1 • LoFreq","databasePath":"/tmp/variants.db","vcfPath":"/tmp/variants.vcf.gz","tbiPath":"/tmp/variants.vcf.gz.tbi"}
        """

        let event = try XCTUnwrap(CLIVariantCallingRunner.parseEvent(from: json))
        guard case let .runComplete(trackID, trackName, databasePath, vcfPath, tbiPath) = event else {
            return XCTFail("Expected runComplete, got \(event)")
        }

        XCTAssertEqual(trackID, "vc-1")
        XCTAssertEqual(trackName, "Sample 1 • LoFreq")
        XCTAssertEqual(databasePath, "/tmp/variants.db")
        XCTAssertEqual(vcfPath, "/tmp/variants.vcf.gz")
        XCTAssertEqual(tbiPath, "/tmp/variants.vcf.gz.tbi")
    }

    func testRunnerParsesRunFailedEvent() throws {
        let json = """
        {"event":"runFailed","message":"Medaka requires ONT model metadata"}
        """

        let event = try XCTUnwrap(CLIVariantCallingRunner.parseEvent(from: json))
        guard case let .runFailed(message) = event else {
            return XCTFail("Expected runFailed, got \(event)")
        }

        XCTAssertEqual(message, "Medaka requires ONT model metadata")
    }

    func testBuildCLIArgumentsIncludesExtraArgsAsSingleValue() {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Test Bundle.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Sample 1 • LoFreq",
            threads: 4,
            advancedArguments: ["--call-indels", "--tag", "sample 1"]
        )

        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)
        let index = arguments.firstIndex(of: "--extra-args")

        XCTAssertNotNil(index)
        XCTAssertEqual(arguments[index! + 1], "--call-indels --tag 'sample 1'")
        XCTAssertFalse(arguments.contains("--advanced-options"))
    }

    func testBuildCLIArgumentsIncludesIvarSpecificOptions() {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Test Bundle.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .ivar,
            outputTrackName: "Sample 1 • iVar",
            minimumAlleleFrequency: 0.07,
            minimumDepth: 12,
            ivarPrimerTrimConfirmed: true,
            ivarConsensusAF: 0.8,
            ivarMergeAFThreshold: 0.2,
            ivarBadQualityThreshold: 25,
            ivarIgnoreStrandBias: false
        )

        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)

        XCTAssertTrue(arguments.containsSequence(["--ivar-consensus-af", "0.8"]))
        XCTAssertTrue(arguments.containsSequence(["--ivar-merge-af-threshold", "0.2"]))
        XCTAssertTrue(arguments.containsSequence(["--ivar-bad-quality-threshold", "25"]))
        XCTAssertTrue(arguments.contains("--ivar-no-ignore-strand-bias"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIVariantCallingRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 5.0) async throws -> Int32 {
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
            domain: "CLIVariantCallingRunnerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for PID file \(url.path)"]
        )
    }

    private func waitUntilProcessExits(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !ProcessTreeTerminator.processExists(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !ProcessTreeTerminator.processExists(pid: pid)
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.contains { index in
            let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex)
            guard let end else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}
