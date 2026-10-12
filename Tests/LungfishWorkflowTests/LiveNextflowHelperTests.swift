// LiveNextflowHelperTests.swift - The shared helper of the live Nextflow classes, with no Docker and no Nextflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q9b, owner direction O5. These cases check what the helper decides and does without a
// daemon. The decision is a pure function of a dictionary, so no case calls setenv. The Docker side runs
// against a daemon in memory that holds containers of other runs, to show a teardown removes none of
// them. LiveNextflowTeardownLiveConformanceTests checks the same against the real daemon.

import CryptoKit
import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class LiveNextflowHelperTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "live-nextflow-helper")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - The switch

    func testWithoutASwitchTheLiveClassSkips() {
        let skip = LiveNextflowSwitch.Decision.skip(reason: LiveNextflowSwitch.offReason)
        XCTAssertEqual(LiveNextflowSwitch.decide(environment: [:]), skip)
        // A storage root alone does not turn the class on, and only the value 1 counts as the require flag.
        XCTAssertEqual(LiveNextflowSwitch.decide(environment: ["LUNGFISH_STORAGE_ROOT": "/Users/x/.lungfish-stable"]), skip)
        XCTAssertEqual(LiveNextflowSwitch.decide(environment: ["LUNGFISH_REQUIRE_TOOLS": "0", "LUNGFISH_STORAGE_ROOT": "/r"]), skip)
        XCTAssertEqual(LiveNextflowSwitch.decide(environment: ["LUNGFISH_REQUIRE_TOOLS": "true", "LUNGFISH_STORAGE_ROOT": "/r"]), skip)
        // A blank live root is not set.
        XCTAssertEqual(LiveNextflowSwitch.decide(environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": "  \n"]), skip)
    }

    func testALiveRootRunsTheClassAgainstThatRoot() {
        let decision = LiveNextflowSwitch.decide(environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": " /Users/dho/.lungfish-stable/ "])
        let run = Self.run(of: decision)
        XCTAssertEqual(run?.path, "/Users/dho/.lungfish-stable")
        XCTAssertEqual(run?.source, .liveRootVariable)
        XCTAssertEqual(run?.source.variable, "LUNGFISH_LIVE_NEXTFLOW_ROOT")
    }

    func testRequireToolsRunsTheClassAgainstTheStorageRoot() {
        let decision = LiveNextflowSwitch.decide(environment: [
            "LUNGFISH_REQUIRE_TOOLS": "1",
            "LUNGFISH_STORAGE_ROOT": "/Users/dho/.lungfish-stable",
        ])
        let run = Self.run(of: decision)
        XCTAssertEqual(run?.path, "/Users/dho/.lungfish-stable")
        XCTAssertEqual(run?.source, .requireToolsStorageRoot)
        XCTAssertEqual(run?.source.variable, "LUNGFISH_STORAGE_ROOT")
    }

    func testALiveRootWinsOverTheStorageRootWhateverTheRequireFlagSays() {
        for require in ["1", "0"] {
            let decision = LiveNextflowSwitch.decide(environment: [
                "LUNGFISH_REQUIRE_TOOLS": require,
                "LUNGFISH_STORAGE_ROOT": "/Users/dho/.lungfish-debug",
                "LUNGFISH_LIVE_NEXTFLOW_ROOT": "/Users/dho/.lungfish-stable",
            ])
            XCTAssertEqual(Self.run(of: decision)?.path, "/Users/dho/.lungfish-stable", "require flag \(require)")
            XCTAssertEqual(Self.run(of: decision)?.source, .liveRootVariable)
        }
    }

    func testASwitchThatCannotBeHonouredIsMisconfiguredAndNeverASkip() {
        let cases: [[String: String]] = [
            ["LUNGFISH_REQUIRE_TOOLS": "1"],
            ["LUNGFISH_REQUIRE_TOOLS": "1", "LUNGFISH_STORAGE_ROOT": ""],
            ["LUNGFISH_REQUIRE_TOOLS": "1", "LUNGFISH_STORAGE_ROOT": "relative/root"],
            ["LUNGFISH_LIVE_NEXTFLOW_ROOT": "relative/root"],
            ["LUNGFISH_LIVE_NEXTFLOW_ROOT": "~/.lungfish-stable"],
        ]
        for environment in cases {
            guard case .misconfigured(let reason) = LiveNextflowSwitch.decide(environment: environment) else {
                XCTFail("\(environment) must be misconfigured")
                continue
            }
            XCTAssertNotNil(reason.range(of: "LUNGFISH_"), "the reason names the variable: \(reason)")
        }
    }

    /// The decision takes its answer from the dictionary and nothing else, so an empty dictionary skips
    /// even when this very test run has the live switch set.
    func testTheDecisionDoesNotReadTheProcessEnvironment() {
        XCTAssertEqual(LiveNextflowSwitch.decide(environment: [:]), .skip(reason: LiveNextflowSwitch.offReason))
        XCTAssertEqual(
            LiveNextflowSwitch.decide(environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": "/a/b"]),
            LiveNextflowSwitch.decide(environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": "/a/b"])
        )
    }

    func testTheRunBoundsAreThePinnedOnes() {
        XCTAssertEqual(LiveNextflowRun.runTimeout, 600, "10 minutes, about twice the slowest warm run of Q15")
        XCTAssertEqual(LiveNextflowDocker.probeTimeout, 30)
        XCTAssertEqual(LiveNextflowDocker.probeArguments, ["info"], "the probe asks the daemon that runs and starts nothing")
    }

    // MARK: - The Docker probe

    func testTheProbeAsksDockerInfoOnceWithinThirtySeconds() {
        let calls = CallLog()
        let docker = LiveNextflowDocker(executable: URL(fileURLWithPath: "/usr/local/bin/docker")) { arguments, timeout in
            calls.append(arguments, timeout: timeout)
            return LiveNextflowDocker.Output(status: 0, stdout: "Server Version: 28.3.2\n")
        }
        XCTAssertEqual(docker.probe(), .answers)
        XCTAssertNil(docker.probe().problem)
        XCTAssertEqual(calls.arguments, [["info"], ["info"]])
        XCTAssertEqual(calls.timeouts, [30, 30])
    }

    func testTheProbeSaysWhyDockerDoesNotAnswer() {
        let down = LiveNextflowDocker(executable: URL(fileURLWithPath: "/usr/local/bin/docker")) { _, _ in
            LiveNextflowDocker.Output(
                status: 1,
                stdout: "Client:\n",
                stderr: "\nCannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n"
            )
        }
        let outcome = down.probe()
        XCTAssertEqual(
            outcome,
            .fails(status: 1, detail: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
        )
        XCTAssertNotNil(outcome.problem?.range(of: "never starts Docker Desktop"))

        let silent = LiveNextflowDocker(executable: URL(fileURLWithPath: "/usr/local/bin/docker")) { _, timeout in
            throw LiveNextflowDocker.TimedOut(seconds: timeout)
        }
        XCTAssertEqual(silent.probe(), .noAnswer(seconds: 30))
        XCTAssertNotNil(silent.probe().problem?.range(of: "no answer within 30 s"))

        struct LaunchFailure: Error {}
        let missing = LiveNextflowDocker(executable: URL(fileURLWithPath: "/usr/local/bin/docker")) { _, _ in throw LaunchFailure() }
        guard case .cannotRun = missing.probe() else { return XCTFail("a launch failure is cannotRun") }
    }

    /// The real runner, with scripts that stand in for `docker`: a daemon that is down, one that answers,
    /// and one that never answers, which the probe cuts off at its bound.
    func testTheProbeOfARealProcessReadsItsExitAndEnforcesTheBound() throws {
        let up = try stubDocker("echo ok")
        XCTAssertEqual(timed("answering") { LiveNextflowDocker.system(executable: up).probe() }, .answers)

        let down = try stubDocker("echo 'Cannot connect to the Docker daemon' >&2\nexit 1")
        XCTAssertEqual(
            timed("failing") { LiveNextflowDocker.system(executable: down).probe() },
            .fails(status: 1, detail: "Cannot connect to the Docker daemon")
        )

        let silent = try stubDocker("exec sleep 20")
        let started = Date()
        XCTAssertEqual(
            timed("silent") { LiveNextflowDocker.system(executable: silent).probe(timeout: 1) },
            .noAnswer(seconds: 1)
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the bound ends the wait")
    }

    func testTheRunningContainersOfTheRunAreListedWithoutTheStoppedOnes() throws {
        let daemon = FakeDockerDaemon()
        let run = try beginRun(daemon)
        defer { run.teardown() }
        daemon.setContainers([container("own", run.workDirectory.path + "/aa/bbbbbb")])

        XCTAssertEqual(try run.ownedContainers(includingStopped: false).map(\.id), ["own"])
        XCTAssertEqual(daemon.commands.filter { $0.first == "ps" }, [["ps", "-q", "--no-trunc"]])
        XCTAssertEqual(try run.ownedContainers().map(\.id), ["own"])
        XCTAssertEqual(daemon.commands.filter { $0.first == "ps" }.last, ["ps", "-a", "-q", "--no-trunc"])
    }

    // MARK: - Which containers belong to a run

    func testCanonicalHostPathReadsEverySpellingOfOneFolder() {
        let canonical = LiveNextflowDocker.canonicalHostPath
        XCTAssertEqual(canonical("/private/var/folders/xy/T/x"), "/var/folders/xy/T/x")
        XCTAssertEqual(canonical("/var/folders/xy/T/x/"), "/var/folders/xy/T/x")
        XCTAssertEqual(canonical("/host_mnt/private/var/folders/xy/T/x"), "/var/folders/xy/T/x")
        XCTAssertEqual(canonical("/host_mnt/Users/dho/x"), "/Users/dho/x")
        XCTAssertEqual(canonical("/private/tmp/x"), "/tmp/x")
        XCTAssertEqual(canonical("/private/other/x"), "/private/other/x", "only var, tmp and etc are links into /private")
        XCTAssertEqual(canonical("/a/./b//c/../d"), "/a/b/d")
    }

    func testAContainerBelongsToARunOnlyThroughAMountInsideItsWorkFolder() {
        let temporary = "/var/folders/xy/T"
        let work = "\(temporary)/live-1a2b3c4d-AAAA/work"
        let containers = [
            container("task", temporary, "\(work)/06/2dcb09834cd2b4c58ce632d16d3eba"),
            container("private-spelling", "/private\(work)/aa/bbbbbb"),
            container("work-itself", work),
            container("other-run", temporary, "\(temporary)/live-ffffffff-BBBB/work/06/2dcb09"),
            container("sibling-prefix", "\(work)-other/aa"),
            container("temporary-only", temporary),
            container("parent-of-the-run", "\(temporary)/live-1a2b3c4d-AAAA"),
            container("no-mounts"),
        ]
        let found = LiveNextflowDocker.filter(containers, holding: URL(fileURLWithPath: "/private\(work)"))
        XCTAssertEqual(found.map(\.id), ["task", "private-spelling", "work-itself"])
    }

    func testABroadWorkFolderSelectsNothing() {
        let everything = [container("a", "/"), container("b", "/tmp/x"), container("c", "/var/folders/xy/T")]
        for broad in ["/", "/tmp", "/var/folders"] {
            XCTAssertEqual(LiveNextflowDocker.filter(everything, holding: URL(fileURLWithPath: broad)), [], broad)
        }
    }

    func testInspectOutputIsReadIntoContainersAndMounts() throws {
        let output = """
        aaa111|[{"Type":"bind","Source":"/var/folders/xy/T","Destination":"/var/folders/xy/T","Mode":"","RW":true}]
        bbb222|[]
        ccc333|null
        ddd444|[{"Type":"volume","Name":"v","Destination":"/data"},{"Type":"bind","Source":"/x y/z","Destination":"/z"}]
        """
        let containers = try LiveNextflowDocker.parseInspect(output)
        XCTAssertEqual(containers.map(\.id), ["aaa111", "bbb222", "ccc333", "ddd444"])
        XCTAssertEqual(containers.map(\.mountSources), [["/var/folders/xy/T"], [], [], ["/x y/z"]])
        XCTAssertThrowsError(try LiveNextflowDocker.parseInspect("no separator here"))
        XCTAssertThrowsError(try LiveNextflowDocker.parseInspect("aaa|{not json"))
    }

    // MARK: - Beginning a run and tearing it down

    func testBeginGivesTheRunAKeyAFolderAndItsRootForChildProcesses() throws {
        let root = try fakeManagedRoot()
        let daemon = FakeDockerDaemon()
        let first = try LiveNextflowRun.begin(
            environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": root.path],
            docker: daemon.client
        )
        defer { first.teardown() }
        let second = try LiveNextflowRun.begin(
            environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": root.path],
            docker: daemon.client
        )
        defer { second.teardown() }

        XCTAssertEqual(first.key.count, 13)
        XCTAssertTrue(first.key.hasPrefix("live-"))
        XCTAssertTrue(first.directory.lastPathComponent.hasPrefix(first.key + "-"), "the key is in the folder name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertEqual(first.workDirectory.deletingLastPathComponent().path, first.directory.path)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(first.source, .liveRootVariable)
        XCTAssertEqual(Self.canonical(first.root.path), Self.canonical(root.path))
        XCTAssertEqual(daemon.commands.filter { $0 == ["info"] }.count, 2, "one probe for each run")

        let child = first.childEnvironment(base: ["PATH": "/usr/bin", "LUNGFISH_STORAGE_ROOT": "/elsewhere"])
        XCTAssertEqual(child["LUNGFISH_STORAGE_ROOT"].map(Self.canonical), Self.canonical(root.path))
        XCTAssertEqual(child["LUNGFISH_CONDA_ROOT"].map(Self.canonical), Self.canonical(root.path) + "/conda")
        XCTAssertEqual(child["PATH"], "/usr/bin")
        XCTAssertNil(first.processRootProblem(processRoot: root))
        XCTAssertNotNil(first.processRootProblem(processRoot: URL(fileURLWithPath: "/elsewhere")))
    }

    func testBeginStopsBeforeAnyDockerCommandWhenTheSwitchIsOffOrBroken() throws {
        let daemon = FakeDockerDaemon()
        XCTAssertThrowsError(try LiveNextflowRun.begin(environment: [:], docker: daemon.client)) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        XCTAssertThrowsError(try LiveNextflowRun.begin(
            environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": "relative"],
            docker: daemon.client
        )) { error in
            guard case .misconfigured? = error as? LiveNextflowError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(daemon.commands, [], "no command reached the daemon")
    }

    func testTheRootAndTheManagedNextflowAreCheckedWhereTheChildProcessLooksForThem() throws {
        let root = try fakeManagedRoot()
        XCTAssertNil(LiveNextflowRun.rootProblem(root, source: .liveRootVariable))
        XCTAssertNil(LiveNextflowRun.nextflowProblem(in: root))
        XCTAssertEqual(
            Self.canonical(LiveNextflowRun.nextflowExecutable(in: root).path),
            Self.canonical(root.path) + "/conda/envs/nextflow/bin/nextflow"
        )

        let empty = scratch.appendingPathComponent("empty-root", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(LiveNextflowRun.rootProblem(empty, source: .liveRootVariable))
        XCTAssertNotNil(LiveNextflowRun.nextflowProblem(in: empty)?.range(of: "not installed"))

        let spaced = scratch.appendingPathComponent("a root with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        XCTAssertNotNil(LiveNextflowRun.rootProblem(spaced, source: .liveRootVariable)?.range(of: "space"))
        let missing = scratch.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNotNil(LiveNextflowRun.rootProblem(missing, source: .requireToolsStorageRoot)?.range(of: "LUNGFISH_STORAGE_ROOT"))
    }

    func testTeardownRemovesOnlyTheContainersOfItsOwnWorkFolderAndThenTheFolder() throws {
        let daemon = FakeDockerDaemon()
        let run = try beginRun(daemon)
        let temporary = run.directory.deletingLastPathComponent().path
        daemon.setContainers([
            container("own-1", temporary, run.workDirectory.path + "/aa/bbbbbb"),
            container("own-2", Self.otherSpelling(of: run.workDirectory.path + "/cc/dddddd")),
            container("other-run", temporary, temporary + "/live-00000000-ZZZZ/work/aa/bbbbbb"),
            container("sibling-prefix", run.workDirectory.path + "-other/aa"),
            container("temporary-only", temporary),
            container("no-mounts"),
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.directory.path))
        XCTAssertEqual(try run.ownedContainers().map(\.id), ["own-1", "own-2"])

        let report = run.teardown()

        XCTAssertEqual(report.removedContainerIDs, ["own-1", "own-2"])
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(daemon.containerIDs, ["other-run", "sibling-prefix", "temporary-only", "no-mounts"])
        let removals = daemon.commands.filter { $0.first == "rm" }
        XCTAssertEqual(removals, [["rm", "-f", "-v", "own-1", "own-2"]], "one removal that names only the run's containers")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directory.path))

        let again = run.teardown()
        XCTAssertEqual(again.removedContainerIDs, [])
        XCTAssertEqual(again.problems, [])
        XCTAssertEqual(daemon.commands.filter { $0.first == "rm" }.count, 1, "a second teardown removes nothing")
    }

    func testTeardownReportsAContainerThatSurvivesAndStillRemovesTheFolder() throws {
        let daemon = FakeDockerDaemon()
        daemon.ignoresRemoval = true
        let run = try beginRun(daemon)
        daemon.setContainers([container("stubborn", run.workDirectory.path + "/aa/bbbbbb")])

        let report = run.teardown()

        XCTAssertEqual(report.removedContainerIDs, ["stubborn"])
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertNotNil(report.problems.first?.range(of: "remain"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directory.path))
    }

    func testTeardownReportsADaemonThatWentAwayAndStillRemovesTheFolder() throws {
        let daemon = FakeDockerDaemon()
        let run = try beginRun(daemon)
        daemon.failsEveryCommand = true

        let report = run.teardown()

        XCTAssertEqual(report.removedContainerIDs, [])
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.directory.path))
    }

    // MARK: - The archive input

    func testTheArchiveInputIsCopiedIntoTheRunFolderAndTheArchiveIsNotTouched() async throws {
        let daemon = FakeDockerDaemon()
        let run = try beginRun(daemon)
        defer { run.teardown() }
        let project = DemoProjectArchiveFixtures.mhcGenotyping
        let folder = DemoProjectArchiveFixtures.directory
        let archive = folder.appendingPathComponent(DemoProjectArchiveFixtures.mhcArchiveName)
        let digestBefore = SHA256.hash(data: try Data(contentsOf: archive)).description
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date

        let installed = try await run.installDemoProject(project, from: folder)

        XCTAssertTrue(installed.path.hasPrefix(run.inputDirectory.path + "/"), installed.path)
        XCTAssertEqual(installed.lastPathComponent, project.projectFolderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent(".lgedemo.json").path))
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: archive)).description, digestBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date, modifiedBefore)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: run.inputDirectory.path)
        XCTAssertEqual(leftovers, [project.projectFolderName], "the staging copy is gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".lge-demo") }, [])
    }

    func testAnArchiveFolderWithoutTheArchiveIsUnavailableBeforeAnyCopy() throws {
        let project = DemoProjectArchiveFixtures.mhcGenotyping
        let name = DemoProjectArchiveFixtures.mhcArchiveName
        let empty = scratch.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        for folder in [nil, empty, scratch.appendingPathComponent("not-there", isDirectory: true)] {
            XCTAssertThrowsError(try LiveNextflowRun.locateArchive(for: project, in: folder)) { error in
                guard case .unavailable? = error as? LiveNextflowError else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(
            try LiveNextflowRun.locateArchive(for: project, in: DemoProjectArchiveFixtures.directory).lastPathComponent,
            name
        )
    }

    func testThePathogenDetectionDemoIsInTheBundledCatalogue() throws {
        let project = try LiveNextflowRun.demoProject(id: "pathogen-detection")
        XCTAssertEqual(project.projectFolderName, "Pathogen Detection.lungfish")
        XCTAssertThrowsError(try LiveNextflowRun.demoProject(id: "no-such-demo")) { error in
            guard case .misconfigured? = error as? LiveNextflowError else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Helpers

    private static func run(of decision: LiveNextflowSwitch.Decision) -> (path: String, source: LiveNextflowSwitch.Source)? {
        if case .run(let root, let source) = decision { return (root.path, source) }
        return nil
    }

    private static func canonical(_ path: String) -> String {
        LiveNextflowDocker.canonicalHostPath(path)
    }

    /// The same folder in the other macOS spelling: `/var/...` becomes `/private/var/...` and back.
    private static func otherSpelling(of path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
    }

    private func container(_ id: String, _ sources: String...) -> LiveNextflowDocker.Container {
        LiveNextflowDocker.Container(id: id, mountSources: sources)
    }

    /// A managed root that holds a Nextflow stand-in where the CLI looks for it.
    private func fakeManagedRoot() throws -> URL {
        let root = scratch.appendingPathComponent("managed-root-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("conda/envs/nextflow/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let nextflow = bin.appendingPathComponent("nextflow")
        try "#!/bin/sh\necho nextflow\n".write(to: nextflow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nextflow.path)
        return root
    }

    private func beginRun(_ daemon: FakeDockerDaemon) throws -> LiveNextflowRun {
        try LiveNextflowRun.begin(
            environment: ["LUNGFISH_LIVE_NEXTFLOW_ROOT": try fakeManagedRoot().path],
            docker: daemon.client
        )
    }

    /// Runs `body` and prints how long it took, so a slow probe shows in the log.
    private func timed(_ label: String, _ body: () -> LiveNextflowDocker.ProbeOutcome) -> LiveNextflowDocker.ProbeOutcome {
        let started = Date()
        let outcome = body()
        print("[live-nextflow] \(label) probe took \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        return outcome
    }

    private func stubDocker(_ body: String) throws -> URL {
        let script = scratch.appendingPathComponent("docker-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

/// The commands a runner was given, in order.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedArguments: [[String]] = []
    private var recordedTimeouts: [TimeInterval] = []

    func append(_ arguments: [String], timeout: TimeInterval) {
        lock.withLock {
            recordedArguments.append(arguments)
            recordedTimeouts.append(timeout)
        }
    }

    var arguments: [[String]] { lock.withLock { recordedArguments } }
    var timeouts: [TimeInterval] { lock.withLock { recordedTimeouts } }
}

/// A Docker daemon in memory. It answers `info`, `ps`, `inspect` and `rm` for the containers it holds and
/// records every command, so a test sees exactly what a teardown asked of it.
private final class FakeDockerDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [(id: String, mounts: [String])] = []
    private var log: [[String]] = []
    private var ignoresRemovalFlag = false
    private var failsEveryCommandFlag = false

    var ignoresRemoval: Bool {
        get { lock.withLock { ignoresRemovalFlag } }
        set { lock.withLock { ignoresRemovalFlag = newValue } }
    }

    var failsEveryCommand: Bool {
        get { lock.withLock { failsEveryCommandFlag } }
        set { lock.withLock { failsEveryCommandFlag = newValue } }
    }

    var commands: [[String]] { lock.withLock { log } }
    var containerIDs: [String] { lock.withLock { held.map(\.id) } }

    func setContainers(_ containers: [LiveNextflowDocker.Container]) {
        lock.withLock { held = containers.map { (id: $0.id, mounts: $0.mountSources) } }
    }

    var client: LiveNextflowDocker {
        LiveNextflowDocker(executable: URL(fileURLWithPath: "/usr/bin/true")) { [self] arguments, _ in
            try handle(arguments)
        }
    }

    private func handle(_ arguments: [String]) throws -> LiveNextflowDocker.Output {
        try lock.withLock {
            log.append(arguments)
            if failsEveryCommandFlag, arguments != ["info"] {
                throw LiveNextflowDocker.CommandFailed("the daemon went away")
            }
            switch arguments.first {
            case "info":
                return LiveNextflowDocker.Output(status: 0)
            case "ps":
                return LiveNextflowDocker.Output(status: 0, stdout: held.map { $0.id + "\n" }.joined())
            case "inspect":
                let wanted = Set(arguments.dropFirst(5))
                let lines = try held.filter { wanted.contains($0.id) }.map { entry -> String in
                    let mounts = entry.mounts.map { ["Type": "bind", "Source": $0, "Destination": $0] }
                    let json = try JSONSerialization.data(withJSONObject: mounts, options: [.sortedKeys])
                    return entry.id + "|" + String(decoding: json, as: UTF8.self) + "\n"
                }
                return LiveNextflowDocker.Output(status: 0, stdout: lines.joined())
            case "rm":
                if !ignoresRemovalFlag {
                    let doomed = Set(arguments.dropFirst(3))
                    held.removeAll { doomed.contains($0.id) }
                }
                return LiveNextflowDocker.Output(status: 0)
            default:
                return LiveNextflowDocker.Output(status: 1, stderr: "unknown command")
            }
        }
    }
}
