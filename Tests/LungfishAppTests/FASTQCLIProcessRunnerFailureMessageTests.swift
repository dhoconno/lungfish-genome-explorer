import XCTest
@testable import LungfishApp

/// A failed FASTQ operation's Operations Panel row shows the runner's error.
/// lungfish-cli writes its JSON event stream to stderr, so quoting stderr
/// whole put every event line into the row (Preview 2026.9.64, SPAdes with a
/// bad extra argument). The error should carry the CLI's own failure message.
final class FASTQCLIProcessRunnerFailureMessageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQCLIFailureMessage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFakeCLI(stderrLines: [String], status: Int32) throws -> URL {
        let script = tempDir.appendingPathComponent("lungfish-cli")
        let body = stderrLines.map { "printf '%s\\n' '\($0)' >&2" }.joined(separator: "\n")
        try "#!/bin/sh\n\(body)\nexit \(status)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func failureMessage(stderrLines: [String]) async throws -> String {
        let cli = try makeFakeCLI(stderrLines: stderrLines, status: 64)
        let runner = LungfishCLIProcessRunner(cliURLProvider: { cli })
        do {
            _ = try await runner.run(
                invocation: FASTQCLIInvocation(subcommand: "assemble", arguments: []),
                outputDirectory: tempDir,
                progress: { _, _ in }
            )
            XCTFail("a non-zero exit must throw")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func testFailureUsesTheCLIFailedEventInsteadOfTheEventStream() async throws {
        let message = try await failureMessage(stderrLines: [
            #"{"event":"start","message":"Launching SPAdes","progress":0}"#,
            #"{"event":"log","level":"info","message":"Usage: spades.py [options] -o <output_dir>"}"#,
            #"{"error":"SPAdes failed (exit 2): spades.py: error: bad option","event":"failed"}"#,
        ])
        XCTAssertEqual(message, "lungfish-cli exited with status 64: SPAdes failed (exit 2): spades.py: error: bad option")
        XCTAssertFalse(message.contains("{\"event\""), "the row must not show raw CLI events")
    }

    func testFailureWithoutAFailedEventKeepsPlainStderrButDropsEvents() async throws {
        let message = try await failureMessage(stderrLines: [
            #"{"event":"start","message":"Launching","progress":0}"#,
            "Error: Unknown option --bogus",
        ])
        XCTAssertEqual(message, "lungfish-cli exited with status 64: Error: Unknown option --bogus")
    }
}
