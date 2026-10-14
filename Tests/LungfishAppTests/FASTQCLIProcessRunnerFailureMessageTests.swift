import XCTest
@testable import LungfishApp
import LungfishWorkflow

/// A failed FASTQ operation's Operations Panel row shows the runner's error.
/// lungfish-cli writes its JSON event stream to stderr, so quoting stderr
/// whole put every event line into the row (Preview 2026.9.64, SPAdes with a
/// bad extra argument). The error should carry the CLI's own failure message.
///
/// A leaf prints its events on the stream its row of the contract table names, and the runner
/// reads that stream (2.10 A41). `assemble` prints them on standard output since 2.10 A46 and the
/// ONT sample leaves on standard error, so each case runs once for each of the two.
final class FASTQCLIProcessRunnerFailureMessageTests: XCTestCase {
    private var tempDir: URL!

    /// One leaf for each stream a row can name for its events.
    private static let leaves = ["assemble", "fastq ont-fluidigm-samples"]

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQCLIFailureMessage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A stand-in `lungfish-cli` that prints `events` on `channel` and `plain` on standard error.
    private func makeFakeCLI(
        events: [String],
        plain: [String],
        channel: CLIEventContract.Channel,
        status: Int32
    ) throws -> URL {
        let script = tempDir.appendingPathComponent("lungfish-cli")
        func printLine(_ line: String, onStandardError: Bool) -> String {
            "printf '%s\\n' '\(line)'" + (onStandardError ? " >&2" : "")
        }
        let body = (events.map { printLine($0, onStandardError: channel == .standardError) }
            + plain.map { printLine($0, onStandardError: true) }).joined(separator: "\n")
        try "#!/bin/sh\n\(body)\nexit \(status)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func failureMessage(of subcommand: String, events: [String], plain: [String] = []) async throws -> String {
        let invocation = FASTQCLIInvocation(subcommand: subcommand, arguments: [])
        let channel = try XCTUnwrap(invocation.eventChannel, "\(subcommand) names a stream for its events")
        let cli = try makeFakeCLI(events: events, plain: plain, channel: channel, status: 64)
        let runner = LungfishCLIProcessRunner(cliURLProvider: { cli })
        do {
            _ = try await runner.run(
                invocation: invocation,
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
        for leaf in Self.leaves {
            let message = try await failureMessage(of: leaf, events: [
                #"{"event":"start","message":"Launching SPAdes","progress":0}"#,
                #"{"event":"log","level":"info","message":"Usage: spades.py [options] -o <output_dir>"}"#,
                #"{"error":"SPAdes failed (exit 2): spades.py: error: bad option","event":"failed"}"#,
            ])
            XCTAssertEqual(
                message,
                "lungfish-cli exited with status 64: SPAdes failed (exit 2): spades.py: error: bad option",
                leaf
            )
            XCTAssertFalse(message.contains("{\"event\""), "the row must not show raw CLI events (\(leaf))")
        }
    }

    func testFailureWithoutAFailedEventKeepsPlainStderrButDropsEvents() async throws {
        for leaf in Self.leaves {
            let message = try await failureMessage(
                of: leaf,
                events: [#"{"event":"start","message":"Launching","progress":0}"#],
                plain: ["Error: Unknown option --bogus"]
            )
            XCTAssertEqual(message, "lungfish-cli exited with status 64: Error: Unknown option --bogus", leaf)
        }
    }

    /// The two cases above cover both streams only while the rows of the two leaves name different ones.
    func testTheTwoLeavesNameDifferentStreamsForTheirEvents() {
        let channels = Set(Self.leaves.compactMap { FASTQCLIInvocation(subcommand: $0, arguments: []).eventChannel })
        XCTAssertEqual(channels, [.standardOutput, .standardError])
    }
}
