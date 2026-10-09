import Darwin
import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishApp
import LungfishTestSupport

/// `LungfishCLIRunner.run` blocks its caller, so each test runs it from a
/// detached task, as every real caller does. A script stands in for
/// `lungfish-cli`.
final class LungfishCLIRunnerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "cli-runner")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    private func fakeCLI(_ script: String) throws -> URL {
        let url = folder.appendingPathComponent("lungfish-cli")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs the CLI off the calling thread and waits for the outcome.
    private func run(
        _ cli: URL,
        cancellation: LungfishCLIRunner.CancellationHandle? = nil
    ) -> OutcomeBox {
        let box = OutcomeBox()
        Task.detached {
            do {
                box.set(.success(try await LungfishCLIRunner.run(arguments: [], executableURL: cli, cancellation: cancellation)))
            } catch {
                box.set(.failure(error))
            }
        }
        return box
    }

    func testRunThrowsLaunchFailedForUnlaunchableExecutable() async throws {
        let box = run(folder)
        let finished = await waitUntil(timeout: .seconds(10)) { box.value != nil }
        XCTAssertTrue(finished)
        guard case .failure(let error)? = box.value, case LungfishCLIRunner.RunError.launchFailed = error else {
            return XCTFail("Expected launchFailed, got \(String(describing: box.value))")
        }
    }

    /// More than the 64 KB a pipe holds on both streams, stderr first. A
    /// runner that reads one stream at a time, or after the exit, stalls.
    func testOutputOver64KBOnBothStreamsDoesNotDeadlock() async throws {
        let cli = try fakeCLI("""
        #!/bin/sh
        /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2
        /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' 'o'
        """)
        let box = run(cli)
        let finished = await waitUntil(timeout: .seconds(30)) { box.value != nil }
        XCTAssertTrue(finished, "the run is blocked on a full pipe")
        guard case .success(let output)? = box.value else { return XCTFail("\(String(describing: box.value))") }
        XCTAssertEqual(output.stdout.count, 300_000)
        XCTAssertEqual(output.stderr.count, 300_000)
        XCTAssertEqual(output.status, 0)
    }

    func testANonZeroExitCarriesTheStatusAndAllOfStderr() async throws {
        let cli = try fakeCLI("""
        #!/bin/sh
        /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2
        exit 9
        """)
        let box = run(cli)
        let finished = await waitUntil(timeout: .seconds(30)) { box.value != nil }
        XCTAssertTrue(finished)
        guard case .failure(let error)? = box.value,
              case LungfishCLIRunner.RunError.nonZeroExit(let status, let stderr) = error else {
            return XCTFail("\(String(describing: box.value))")
        }
        XCTAssertEqual(status, 9)
        XCTAssertEqual(stderr.count, 200_000)
    }

    /// A cancel stops the CLI's own child, which ignores SIGTERM.
    func testCancelKillsAGrandchildOfTheCLI() async throws {
        let grandchildPIDFile = folder.appendingPathComponent("grandchild.pid")
        let cli = try fakeCLI("""
        #!/bin/sh
        /bin/sh -c 'echo $$ > "\(grandchildPIDFile.path)"; trap "" TERM; while true; do /bin/sleep 1; done' &
        wait
        """)
        let cancellation = LungfishCLIRunner.CancellationHandle()
        let box = run(cli, cancellation: cancellation)
        var grandchild: Int32?
        let started = await waitUntil(timeout: .seconds(30)) {
            grandchild = (try? String(contentsOf: grandchildPIDFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return grandchild != nil
        }
        XCTAssertTrue(started)
        let pid = try XCTUnwrap(grandchild)
        defer { kill(pid, SIGKILL) }

        cancellation.cancel()

        let finished = await waitUntil(timeout: .seconds(30)) { box.value != nil }
        XCTAssertTrue(finished)
        guard case .failure(let error)? = box.value, case LungfishCLIRunner.RunError.cancelled = error else {
            return XCTFail("\(String(describing: box.value))")
        }
        let gone = await waitUntil(timeout: .seconds(30)) { !ProcessTreeTerminator.processExists(pid: pid) }
        XCTAssertTrue(gone, "the grandchild is stopped")
    }

    func testACancelBeforeTheRunNeverLaunchesTheCLI() async throws {
        let marker = folder.appendingPathComponent("launched")
        let cli = try fakeCLI("""
        #!/bin/sh
        touch '\(marker.path)'
        """)
        let cancellation = LungfishCLIRunner.CancellationHandle()
        cancellation.cancel()
        let box = run(cli, cancellation: cancellation)
        let finished = await waitUntil(timeout: .seconds(10)) { box.value != nil }
        XCTAssertTrue(finished)
        guard case .failure(let error)? = box.value, case LungfishCLIRunner.RunError.cancelled = error else {
            return XCTFail("\(String(describing: box.value))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<LungfishCLIRunner.Output, Error>?
    var value: Result<LungfishCLIRunner.Output, Error>? { lock.withLock { stored } }
    func set(_ value: Result<LungfishCLIRunner.Output, Error>) { lock.withLock { stored = value } }
}
