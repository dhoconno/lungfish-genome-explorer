// SystemContainerRuntimeProbeTests.swift - The Docker probe's verdicts for a stub `docker`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S11 (SWIFT inventory row 264, E14). `SystemContainerRuntimeProbe` finds `docker`
// and runs `docker version` under a timeout. No case here runs the real Docker. A shell script
// named `docker` answers, fails or hangs in its place, so the verdicts need no daemon.
//
// The first seven cases were written at the base of the lane, where the probe launched Foundation
// `Process` objects, and they passed there. They still pass now that the probe runs on
// `ToolProcess`, which includes the case where a timeout stops the helper that `docker` forked.
// The last case is the behaviour the move added. A cancelled task ends the probe at once and stops
// `docker`, where the base waited out the timeout, so it failed there.
//
// Phase 2.10 tier 1. The two cases that hang a stub under a 1 s timeout run it once first and repeat
// a probe that struck before the stub's first line, because the first run of a new script can wait
// seconds for the system's check of it. With 20 copies of the group case started at once, 14 failed
// on that wait while the probe stopped `docker` on time.

import Darwin
import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class SystemContainerRuntimeProbeTests: XCTestCase {
    private var folder: URL!
    private var leftoverPIDs: [Int32] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try TestTempDirectory.make(prefix: "docker-probe")
    }

    override func tearDown() {
        for pid in leftoverPIDs { kill(pid, SIGKILL) }
        leftoverPIDs = []
        TestTempDirectory.cleanup(folder)
        super.tearDown()
    }

    // MARK: - Verdicts

    func testADaemonThatAnswersIsReachableWithBothVersions() async throws {
        let docker = try writeStub("echo '28.3.2|28.4.0'")

        let verdict = await SystemContainerRuntimeProbe().dockerDaemon(dockerPath: docker.path, timeout: 10)

        XCTAssertEqual(
            verdict,
            DockerDaemonProbe(reachable: true, clientVersion: "28.3.2", serverVersion: "28.4.0", detail: nil)
        )
        let argv = try String(contentsOf: folder.appendingPathComponent("argv.txt"), encoding: .utf8)
        XCTAssertEqual(
            argv,
            "version\n--format\n{{.Client.Version}}|{{if .Server}}{{.Server.Version}}{{end}}\n",
            "the probe asks for the two versions in one call"
        )
    }

    func testADaemonThatFailsIsUnreachableAndNamesTheFirstStderrLine() async throws {
        let docker = try writeStub(
            """
            echo '28.3.2|'
            echo 'Cannot connect to the Docker daemon. Is the docker daemon running?' >&2
            echo 'a second line the verdict never shows' >&2
            exit 1
            """
        )

        let verdict = await SystemContainerRuntimeProbe().dockerDaemon(dockerPath: docker.path, timeout: 10)

        XCTAssertEqual(
            verdict,
            DockerDaemonProbe(
                reachable: false,
                clientVersion: "28.3.2",
                serverVersion: nil,
                detail: "Cannot connect to the Docker daemon. Is the docker daemon running?"
            )
        )
    }

    func testAClientWithNoServerIsUnreachableAndSaysItsExitStatus() async throws {
        let docker = try writeStub("echo '28.3.2|'\nexit 3")

        let verdict = await SystemContainerRuntimeProbe().dockerDaemon(dockerPath: docker.path, timeout: 10)

        XCTAssertEqual(
            verdict,
            DockerDaemonProbe(
                reachable: false,
                clientVersion: "28.3.2",
                serverVersion: nil,
                detail: "docker version exited with status 3"
            )
        )
    }

    func testADaemonThatHangsPastTheTimeoutIsUnreachableAndSaysSo() async throws {
        let printed = folder.appendingPathComponent("printed.txt")
        // `exec` makes the stub one process, as the real `docker` is, so a stop of its leader ends it.
        let docker = try writeHangingStub("echo '28.3.2|'\n: > '\(printed.path)'\nexec sleep 30")

        let run = await probeUntilReached(docker) { FileManager.default.fileExists(atPath: printed.path) }

        XCTAssertTrue(run.stubReached, "the stub never printed, even with a timeout of \(run.seconds) s")
        XCTAssertEqual(
            run.verdict,
            DockerDaemonProbe(
                reachable: false,
                clientVersion: "28.3.2",
                serverVersion: nil,
                detail: run.timeoutDetail
            ),
            "the client version printed before the hang is kept"
        )
        XCTAssertLessThan(run.waited, .seconds(run.seconds + 10), "the probe returns at its timeout")
    }

    func testALaunchFailureIsUnreachableWithADetail() async {
        let missing = folder.appendingPathComponent("no-such-docker")

        let verdict = await SystemContainerRuntimeProbe().dockerDaemon(dockerPath: missing.path, timeout: 5)

        XCTAssertFalse(verdict.reachable)
        XCTAssertNil(verdict.clientVersion)
        XCTAssertNil(verdict.serverVersion)
        XCTAssertFalse(verdict.detail?.isEmpty ?? true, "an unreachable daemon always says why")
    }

    // MARK: - The lookup

    func testTheLookupReturnsTheFirstDockerOnPATH() throws {
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let docker = bin.appendingPathComponent("docker")
        try "#!/bin/sh\nexit 0\n".write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let savedPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(bin.path):/usr/bin:/bin", 1)
        defer {
            if let savedPath { setenv("PATH", savedPath, 1) } else { unsetenv("PATH") }
        }

        XCTAssertEqual(SystemContainerRuntimeProbe().dockerCLIPath(), docker.path)
    }

    // MARK: - Stopping docker

    func testATimeoutStopsTheWholeProcessGroupOfDocker() async throws {
        let pidFile = folder.appendingPathComponent("child.pid")
        // A helper that docker forked and that no longer holds the probe's pipes.
        let docker = try writeHangingStub(
            """
            sleep 60 </dev/null >/dev/null 2>&1 &
            echo $! > '\(pidFile.path)'
            wait
            """
        )

        let run = await probeUntilReached(docker) { Self.pid(in: pidFile) != nil }

        XCTAssertEqual(run.verdict.detail, run.timeoutDetail)
        let pid = try XCTUnwrap(
            Self.pid(in: pidFile),
            "the stub never recorded its helper, even with a timeout of \(run.seconds) s"
        )
        leftoverPIDs.append(pid)
        let gone = await waitUntil(timeout: .seconds(30)) { !Self.isRunning(pid) }
        XCTAssertTrue(gone, "the helper of docker outlived the probe's timeout")
    }

    func testACancelEndsTheProbeAtOnceAndStopsDocker() async throws {
        let pidFile = folder.appendingPathComponent("docker.pid")
        let docker = try writeStub("echo $$ > '\(pidFile.path)'\nexec sleep 30")
        let probe = SystemContainerRuntimeProbe()

        let run = Task { await probe.dockerDaemon(dockerPath: docker.path, timeout: 10) }
        let launched = await waitUntil(timeout: .seconds(30)) { Self.pid(in: pidFile) != nil }
        XCTAssertTrue(launched, "the stub never started")
        let pid = try XCTUnwrap(Self.pid(in: pidFile))
        leftoverPIDs.append(pid)

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        run.cancel()
        let verdict = await run.value
        let waited = clock.now - cancelledAt

        XCTAssertLessThan(waited, .seconds(5), "the probe waited out its 10 s timeout after the cancel")
        XCTAssertFalse(verdict.reachable)
        XCTAssertEqual(verdict.detail, "docker version was cancelled")
        XCTAssertFalse(Self.isRunning(pid), "docker outlived the cancelled probe")
    }

    // MARK: - Helpers

    /// A `docker` stand-in. It records its argv in `argv.txt`, then runs `body`.
    private func writeStub(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("docker")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(folder.path)/argv.txt'\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// While this file exists, a hanging stub exits at once. That is how `probeUntilReached` runs it once
    /// before the timed probes.
    private var warmUpMarker: URL { folder.appendingPathComponent("warm-up") }

    /// A `docker` stand-in that hangs in `body`. Probe it with `probeUntilReached`.
    private func writeHangingStub(_ body: String) throws -> URL {
        try writeStub("[ -e '\(warmUpMarker.path)' ] && exit 0\n\(body)")
    }

    /// What the last probe of a hanging stub gave.
    private struct HangingProbe {
        var verdict: DockerDaemonProbe
        /// The timeout of that probe, in seconds.
        var seconds: Int
        /// How long that probe took.
        var waited: Duration
        /// Whether the stub ran the lines the case needs before that probe's timeout struck.
        var stubReached: Bool

        /// The detail of a probe that gave up after `seconds`.
        var timeoutDetail: String { "docker version did not answer within \(seconds) s" }
    }

    /// Probes the hanging stub `docker` and returns the first probe after which `reached` holds, which means the
    /// stub ran the lines the case needs before that probe's timeout struck. When none does, it returns the last.
    ///
    /// The probe's timeout starts when `docker` is launched, and the first run of a new script can wait seconds
    /// for its first line. The system checks each new script before its first run. That check measured 0.1 to
    /// 0.25 s a script and runs one script at a time for every process on the machine, so a parallel unit tier
    /// queues dozens of them. A timeout that strikes before the stub's first line says nothing about the probe.
    /// So the stub first runs once with the warm-up marker in place, which takes that check outside any timeout,
    /// and a probe that still struck first is repeated with a timeout four times longer, up to 16 s.
    private func probeUntilReached(_ docker: URL, reached: () -> Bool) async -> HangingProbe {
        FileManager.default.createFile(atPath: warmUpMarker.path, contents: nil)
        _ = await SystemContainerRuntimeProbe().dockerDaemon(dockerPath: docker.path, timeout: 30)
        try? FileManager.default.removeItem(at: warmUpMarker)

        let clock = ContinuousClock()
        var seconds = 1
        while true {
            let startedAt = clock.now
            let verdict = await SystemContainerRuntimeProbe().dockerDaemon(
                dockerPath: docker.path,
                timeout: TimeInterval(seconds)
            )
            let probe = HangingProbe(
                verdict: verdict,
                seconds: seconds,
                waited: clock.now - startedAt,
                stubReached: reached()
            )
            if probe.stubReached || seconds >= 16 { return probe }
            seconds *= 4
        }
    }

    /// The pid a stub wrote to `file`, or nil until it has written a whole number.
    nonisolated private static func pid(in file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether `pid` names a process that has not exited. A zombie only waits to be reaped, so it
    /// has exited.
    nonisolated private static func isRunning(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) != SZOMB
    }
}
