// DockerRuntimeToolProcessTests.swift - DockerRuntime's docker CLI runs, against a fake docker
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LungfishWorkflow

/// DockerRuntime finds `docker` with `/usr/bin/which` on the inherited PATH,
/// which is its only seam. Each test puts a fake `docker` first on PATH just
/// long enough for the runtime to resolve and cache its path, then restores
/// PATH, so no other test sees the fake.
final class DockerRuntimeToolProcessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockerRuntimeToolProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let docker = root.appendingPathComponent("bin/docker")
        try Self.fakeDocker(pidFile: root.appendingPathComponent("docker.pid").path)
            .write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
    }

    override func tearDownWithError() throws {
        if let pid = try? Self.pid(in: root.appendingPathComponent("docker.pid")) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: runDockerCommand

    func testCommandOutputOver64KBOnBothStreamsIsReadInFull() async throws {
        let runtime = try await resolvedRuntime()
        let container = try await withDeadline {
            try await runtime.createContainer(name: "big", image: ContainerImage(reference: "fake:1", runtimeType: .docker), config: .minimal())
        }
        XCTAssertEqual(container.id, Self.lines("stdout", count: Self.bigLineCount).trimmingCharacters(in: .whitespacesAndNewlines))

        let created = Container(
            id: "big-rm", name: "big-rm", runtimeType: .docker, state: .created,
            image: ContainerImage(reference: "fake:1", runtimeType: .docker), configuration: .minimal(), nativeContainer: AnySendable("big-rm")
        )
        do {
            try await withDeadline { try await runtime.removeContainer(created) }
            XCTFail("Expected docker rm to fail")
        } catch ContainerRuntimeError.containerRemoveFailed(_, let reason) {
            XCTAssertEqual(reason, Self.lines("stderr", count: Self.bigLineCount).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func testCancellingACommandKillsTheDockerProcessTree() async throws {
        let runtime = try await resolvedRuntime()
        let childPIDFile = root.appendingPathComponent("child.pid")
        let task = Task { try await runtime.pullImage(reference: childPIDFile.path) }
        let child = try await waitForPID(in: childPIDFile)
        let startedAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected the cancelled pull to fail")
        } catch {}
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(5))
        try await assertGone(child)
    }

    // MARK: exec

    func testExecStreamsOutputOver64KBOnBothStreamsInFull() async throws {
        let runtime = try await resolvedRuntime()
        let process = try await runtime.exec(
            in: Self.runningContainer, command: "big", arguments: [], environment: [:], workingDirectory: "/work"
        )
        try await process.start()
        async let stdout: Data = Self.collect(process.stdout)
        async let stderr: Data = Self.collect(process.stderr)
        let status = try await withDeadline { try await process.wait() }
        let (out, err) = await (stdout, stderr)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), Self.lines("stdout", count: Self.bigLineCount))
        XCTAssertEqual(String(decoding: err, as: UTF8.self), Self.lines("stderr", count: Self.bigLineCount))
    }

    func testExecRunCollectsOutputAndFinishes() async throws {
        let runtime = try await resolvedRuntime()
        let process = try await runtime.exec(
            in: Self.runningContainer, command: "big", arguments: [], environment: [:], workingDirectory: "/work"
        )
        let output = try await withDeadline { try await process.run() }
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.stdoutString, Self.lines("stdout", count: Self.bigLineCount))
        XCTAssertEqual(output.stderrString, Self.lines("stderr", count: Self.bigLineCount))
    }

    func testCancellingAnExecWaitKillsTheDockerProcessTree() async throws {
        let runtime = try await resolvedRuntime()
        let childPIDFile = root.appendingPathComponent("exec-child.pid")
        let process = try await runtime.exec(
            in: Self.runningContainer, command: "tree", arguments: [childPIDFile.path], environment: [:], workingDirectory: "/work"
        )
        try await process.start()
        let child = try await waitForPID(in: childPIDFile)
        let waiter = Task { try await process.wait() }
        try await Task.sleep(for: .milliseconds(100))
        let startedAt = ContinuousClock.now
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected the cancelled wait to throw")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(5))
        try await assertGone(child)
    }

    func testTerminatingAnExecKillsTheDockerProcessTree() async throws {
        let runtime = try await resolvedRuntime()
        let childPIDFile = root.appendingPathComponent("exec-term-child.pid")
        let process = try await runtime.exec(
            in: Self.runningContainer, command: "tree", arguments: [childPIDFile.path], environment: [:], workingDirectory: "/work"
        )
        try await process.start()
        let child = try await waitForPID(in: childPIDFile)
        try await process.terminate()
        let status = try await withDeadline { try await process.wait() }
        XCTAssertNotEqual(status, 0)
        try await assertGone(child)
    }

    func testExecWithoutResolvedDockerFailsToStart() async throws {
        let runtime = DockerRuntime()
        let process = try await runtime.exec(
            in: Self.runningContainer, command: "big", arguments: [], environment: [:], workingDirectory: "/work"
        )
        do {
            try await process.start()
            XCTFail("Expected start to fail without a resolved docker")
        } catch ContainerRuntimeError.execFailed(_, _, let reason) {
            XCTAssertEqual(reason, "Docker executable not found")
        }
    }

    // MARK: Helpers

    private static let bigLineCount = 4_000

    private static let runningContainer = Container(
        id: "fake-container", name: "fake", runtimeType: .docker, state: .running,
        image: ContainerImage(reference: "fake:1", runtimeType: .docker), configuration: .minimal(), nativeContainer: AnySendable("fake-container")
    )

    /// The lines the fake docker prints on one stream, each ending in a newline.
    private static func lines(_ stream: String, count: Int) -> String {
        (0..<count).map { String(format: "%@-line-%06d-padding-padding-padding\n", stream, $0) }.joined()
    }

    private static func fakeDocker(pidFile: String) -> String {
        let awkLines = { (stream: String, target: String) in
            #"/usr/bin/awk 'BEGIN { for (i = 0; i < \#(bigLineCount); i++) printf "\#(stream)-line-%06d-padding-padding-padding\n", i \#(target) }'"#
        }
        return """
        #!/bin/sh
        echo $$ > '\(pidFile)'
        case "$1" in
          info) exit 0 ;;
          --version) echo "Docker version 99.1.2, build fake"; exit 0 ;;
          create) \(awkLines("stdout", "")); \(awkLines("stderr", "> \"/dev/stderr\"")); exit 0 ;;
          rm) \(awkLines("stdout", "")); \(awkLines("stderr", "> \"/dev/stderr\"")); exit 3 ;;
          pull) /bin/sleep 300 & echo $! > "$2"; wait; exit 0 ;;
          exec)
            command="$5"
            if [ "$command" = "big" ]; then
              \(awkLines("stdout", "")); \(awkLines("stderr", "> \"/dev/stderr\"")); exit 0
            fi
            if [ "$command" = "tree" ]; then
              /bin/sleep 300 & echo $! > "$6"; wait; exit 0
            fi
            echo "unknown exec command $command" >&2; exit 2 ;;
        esac
        echo "unsupported docker $*" >&2
        exit 2
        """
    }

    /// A runtime whose docker path is the fake, resolved while the fake is
    /// first on PATH.
    private func resolvedRuntime() async throws -> DockerRuntime {
        let runtime = DockerRuntime()
        let original = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", root.appendingPathComponent("bin").path + ":" + original, 1)
        let available = await runtime.isAvailable()
        setenv("PATH", original, 1)
        XCTAssertTrue(available)
        let path = await runtime.getDockerPath()
        XCTAssertEqual(path, root.appendingPathComponent("bin/docker").path)
        return runtime
    }

    private static func collect(_ stream: AsyncStream<Data>) async -> Data {
        var data = Data()
        for await chunk in stream { data.append(chunk) }
        return data
    }

    private static func pid(in url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text) else { throw CocoaError(.fileReadCorruptFile) }
        return pid
    }

    private func waitForPID(in url: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let pid = try? Self.pid(in: url) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func assertGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        kill(pid, SIGKILL)
        XCTFail("Process \(pid) outlived the cancelled docker run", file: file, line: line)
    }

    /// Runs `body`, and if it has not finished after 20 seconds kills the
    /// fake docker so a run blocked on a full pipe returns, then fails.
    private func withDeadline<T: Sendable>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let pidFile = root.appendingPathComponent("docker.pid")
        let timedOut = Mutex(false)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            timedOut.withLock { $0 = true }
            if let pid = try? Self.pid(in: pidFile) { kill(pid, SIGKILL) }
        }
        defer { watchdog.cancel() }
        let value = try await body()
        if timedOut.withLock({ $0 }) {
            XCTFail("The docker run blocked until the fake docker was killed", file: file, line: line)
        }
        return value
    }
}
