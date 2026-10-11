// ToolProcessObservationTests.swift - The provenance observer hook of ToolProcess and its environment allowlist
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Phase 2.7 lane S1 (B1, decision P10). A recorded environment change keeps
/// every changed name, a value only for an allowlisted name, sanitized, and
/// never a PATH value or the value of a name that points at the account's
/// home or scratch folder.
final class ToolProcessEnvironmentChangeAllowlistTests: XCTestCase {
    private static let context = PortablePath.Context(
        projectURL: nil,
        toolRootURL: URL(fileURLWithPath: "/Users/someone/lungfish-tools", isDirectory: true),
        storageRootURL: URL(fileURLWithPath: "/Users/someone/lungfish-storage", isDirectory: true),
        temporaryRootURLs: []
    )

    func testOnlyAllowlistedNamesKeepTheirValues() {
        let change = ToolProcessEnvironmentChange(
            base: .inherited,
            set: [
                "MAMBA_NO_BANNER": "1",
                "PATH": "/Users/someone/lungfish-tools/envs/kraken2/bin:/Users/someone/bin:/usr/bin",
                "HOME": "/Users/someone",
                "TMPDIR": "/Users/someone/scratch",
                "MAFFT_TMPDIR": "/Users/someone/scratch/mafft",
                "XDG_CACHE_HOME": "/Users/someone/.cache",
                "DATABASE_URL": "postgres://user:secret@host/db",
                "HTTPS_PROXY": "http://user:secret@proxy:8080",
            ],
            unset: ["PYTHONHOME", "CONDA_PREFIX", "PYTHONHOME"],
            sanitizing: Self.context
        )
        XCTAssertEqual(change.base, .inherited)
        XCTAssertEqual(change.set.map(\.name), [
            "DATABASE_URL", "HOME", "HTTPS_PROXY", "MAFFT_TMPDIR", "MAMBA_NO_BANNER", "PATH", "TMPDIR", "XDG_CACHE_HOME",
        ])
        XCTAssertEqual(change.set.filter { $0.value != nil }, [.init(name: "MAMBA_NO_BANNER", value: "1")])
        XCTAssertEqual(change.unset, ["CONDA_PREFIX", "PYTHONHOME"])
    }

    func testKeptValuesAndPathPrefixEntriesAreSanitized() {
        let change = ToolProcessEnvironmentChange(
            base: .inherited,
            set: [
                "JAVA_HOME": "/Users/someone/lungfish-tools/envs/bbtools/lib/jvm",
                "LUNGFISH_STORAGE_ROOT": "/Users/someone/lungfish-storage/databases",
                "MAFFT_BINARIES": "/Users/someone/private/mafft/libexec",
            ],
            pathPrefix: ["/Users/someone/lungfish-tools/envs/bbtools/bin", "/Users/someone/bin", "/usr/bin"],
            sanitizing: Self.context
        )
        XCTAssertEqual(change.set, [
            .init(name: "JAVA_HOME", value: "<tool-root>/envs/bbtools/lib/jvm"),
            .init(name: "LUNGFISH_STORAGE_ROOT", value: "<storage-root>/databases"),
            .init(name: "MAFFT_BINARIES", value: "<external>/libexec"),
        ])
        XCTAssertEqual(change.pathPrefix, ["<tool-root>/envs/bbtools/bin", "<external>/bin", "/usr/bin"])
    }

    /// PortablePath reads a colon-separated list as one path, which rewrites
    /// the root of the first path only. A first path under /usr would even
    /// keep every later path raw. The type sanitizes a list one path at a
    /// time, in a kept value and in a path prefix entry, and a single path
    /// with a colon in a folder name is still one path.
    func testPathListsAreSanitizedOneEntryAtATime() {
        let change = ToolProcessEnvironmentChange(
            base: .inherited,
            set: [
                "PYTHONPATH": "/Users/someone/lungfish-tools/envs/x/lib:/Users/someone/private/py",
                "DYLD_LIBRARY_PATH": "/usr/lib:/Users/someone/private/lib",
                "JAVA_HOME": "/Users/someone/odd:name/jvm",
            ],
            pathPrefix: ["/Users/someone/lungfish-tools/envs/x/bin:/Users/someone/private/bin"],
            sanitizing: Self.context
        )
        XCTAssertEqual(change.set, [
            .init(name: "DYLD_LIBRARY_PATH", value: "/usr/lib:<external>/lib"),
            .init(name: "JAVA_HOME", value: "<external>/jvm"),
            .init(name: "PYTHONPATH", value: "<tool-root>/envs/x/lib:<external>/py"),
        ])
        XCTAssertEqual(change.pathPrefix, ["<tool-root>/envs/x/bin:<external>/bin"])
        XCTAssertFalse(change.set.compactMap(\.value).contains { $0.contains("/Users/someone") })
        XCTAssertFalse(change.pathPrefix.contains { $0.contains("/Users/someone") })
    }

    /// A hermetic base inherits nothing, so it has nothing to remove, whatever
    /// names the adapter passes. An inherited base keeps them, sorted.
    func testAHermeticBaseKeepsNoUnsetNames() {
        let hermetic = ToolProcessEnvironmentChange(
            base: .hermetic,
            set: ["PATH": "/usr/bin:/bin"],
            unset: ["PYTHONHOME", "CONDA_PREFIX"],
            pathPrefix: ["/usr/bin", "/bin"],
            sanitizing: Self.context
        )
        XCTAssertEqual(hermetic.unset, [])
        let inherited = ToolProcessEnvironmentChange(
            base: .inherited,
            unset: ["PYTHONHOME", "CONDA_PREFIX"],
            sanitizing: Self.context
        )
        XCTAssertEqual(inherited.unset, ["CONDA_PREFIX", "PYTHONHOME"])
    }

    /// The four names of decision P10 and PATH never keep a value, and every
    /// name the adapters set for their tools does.
    func testTheAllowlistAndTheNameOnlyListAreDisjoint() {
        let nameOnly = ToolProcessEnvironmentChange.nameOnlyNames
        XCTAssertEqual(nameOnly, ["PATH", "HOME", "TMPDIR", "MAFFT_TMPDIR", "XDG_CACHE_HOME"])
        XCTAssertTrue(ToolProcessEnvironmentChange.valueRecordedNames.isDisjoint(with: nameOnly))
        for name in nameOnly {
            XCTAssertFalse(ToolProcessEnvironmentChange.recordsValue(of: name), name)
        }
        for name in ["MAMBA_ROOT_PREFIX", "JAVA_HOME", "BBMAP_JAVA", "NXF_HOME", "CONDA_PREFIX", "LUNGFISH_CONDA_ROOT"] {
            XCTAssertTrue(ToolProcessEnvironmentChange.recordsValue(of: name), name)
        }
        XCTAssertEqual(ToolProcessEnvironmentChange.valueRecordedNames.count, 21)
    }
}

/// Collects observations the way a provenance buffer does, with one append
/// under a lock and nothing else.
final class ToolProcessObservationLog: Sendable {
    private let observations = Mutex<[ToolProcessRunObservation]>([])

    var observer: ToolProcessObserver {
        ToolProcessObserver { [self] observation in
            observations.withLock { $0.append(observation) }
        }
    }

    var all: [ToolProcessRunObservation] {
        observations.withLock { $0 }
    }
}

/// Phase 2.7 lane S1 (B1, decisions P1 and P3). A run built while an
/// observer is bound delivers one observation with one entry per declared
/// stage, before anything waiting on the run wakes, and its result or error
/// stays what ToolProcessEntryPointPinTests and the other suites pin.
final class ToolProcessObservationTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures
    private typealias Pins = ToolProcessEntryPointPinTests

    // MARK: - Single runs

    func testRunDeliversOneObservationBeforeItReturns() async throws {
        let directory = try makeToolProcessTempDirectory()
        let change = ToolProcessEnvironmentChange(
            base: .hermetic,
            set: ["PATH": Fixtures.systemPath],
            pathPrefix: Fixtures.systemPath.split(separator: ":").map(String.init),
            sanitizing: PortablePath.Context(projectURL: nil)
        )
        var spec = Fixtures.shell("echo out; echo warn >&2")
        spec.workingDirectory = directory
        spec.environmentChange = change
        spec.identityHint = "sh"
        let log = ToolProcessObservationLog()
        let before = Date()
        let result = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await ToolProcess.run(spec)
        }
        let after = Date()
        // Read at once, without a wait, because delivery comes before run returns.
        let observations = log.all
        XCTAssertEqual(observations.count, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertNil(observation.stop)
        XCTAssertEqual(observation.stages.count, 1)
        let stage = try XCTUnwrap(observation.stages.first)
        XCTAssertEqual(stage.index, 0)
        XCTAssertEqual(stage.stageCount, 1)
        XCTAssertEqual(stage.label, "sh")
        XCTAssertEqual(stage.argv, spec.argv)
        XCTAssertEqual(stage.workingDirectory, directory)
        XCTAssertEqual(stage.ending, .terminated(.exited(code: 0)))
        XCTAssertEqual(stage.wallTime, result.wallTime)
        XCTAssertNil(stage.stop)
        XCTAssertEqual(stage.outputComplete, true)
        XCTAssertFalse(stage.failedOnItsOwn)
        XCTAssertEqual(stage.stderr, .init(captured: Data("warn\n".utf8), earlierBytesDropped: false))
        XCTAssertEqual(stage.environmentChange, change)
        XCTAssertEqual(stage.identityHint, "sh")
        let startedAt = try XCTUnwrap(stage.startedAt)
        XCTAssertLessThanOrEqual(before, observation.startedAt)
        XCTAssertLessThanOrEqual(observation.startedAt, startedAt)
        XCTAssertLessThanOrEqual(startedAt, after)
    }

    func testANonzeroExitAndASignalAreFailuresOfTheirOwn() async throws {
        let log = ToolProcessObservationLog()
        let (failed, signaled) = try await ToolProcessObservation.$observer.withValue(log.observer) {
            (try await ToolProcess.run(Fixtures.shell("exit 3")), try await ToolProcess.run(Fixtures.shell("kill -KILL $$")))
        }
        XCTAssertEqual(failed.termination, .exited(code: 3))
        XCTAssertEqual(signaled.termination, .signaled(signal: SIGKILL))
        let observations = log.all
        XCTAssertEqual(observations.map { $0.stages.map(\.ending) }, [
            [.terminated(.exited(code: 3))],
            [.terminated(.signaled(signal: SIGKILL))],
        ])
        XCTAssertEqual(observations.flatMap { $0.stages.map(\.failedOnItsOwn) }, [true, true])
        XCTAssertLessThan(observations[0].sequenceNumber, observations[1].sequenceNumber)
    }

    func testATimedOutRunStillThrowsAndItsObservationSaysWhy() async throws {
        let log = ToolProcessObservationLog()
        do {
            _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.run(Fixtures.shell("echo begun; sleep 30", timeout: .milliseconds(500)))
            }
            XCTFail("Expected a timeout")
        } catch ToolProcessError.timedOut(let timeout, let results) {
            XCTAssertEqual(timeout, .wallClock(.milliseconds(500)))
            XCTAssertEqual(results.first?.stdoutText, "begun\n")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let observation = try XCTUnwrap(log.all.first)
        XCTAssertEqual(observation.stop, .timedOut(.wallClock(.milliseconds(500))))
        let stage = try XCTUnwrap(observation.stages.first)
        XCTAssertEqual(stage.stop, .timedOut(.wallClock(.milliseconds(500))))
        XCTAssertTrue(stage.ending.launched)
        XCTAssertFalse(stage.failedOnItsOwn, "a stage ToolProcess stopped did not fail on its own")
    }

    func testACancelledRunStillThrowsCancelledAndItsObservationSaysSo() async throws {
        let directory = try makeToolProcessTempDirectory()
        let pidFile = directory.appendingPathComponent("pid")
        let log = ToolProcessObservationLog()
        let spec = Fixtures.shell("echo $$ > \(Fixtures.shellQuote(pidFile.path)); while true; do sleep 1; done")
        let task = Task {
            try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.run(spec)
            }
        }
        let pid = await Fixtures.waitForPID(pidFile)
        defer { Fixtures.killIfAlive(pid) }
        task.cancel()
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertEqual(results.map(\.stop), [.cancelled])
        default:
            XCTFail("Expected cancelled")
        }
        let observation = try XCTUnwrap(log.all.first)
        XCTAssertEqual(observation.stop, .cancelled)
        XCTAssertEqual(observation.stages.map(\.stop), [.cancelled])
        XCTAssertEqual(observation.stages.map(\.ending.launched), [true])
    }

    func testALaunchFailureIsObservedWithTheReasonItsErrorGives() async throws {
        let log = ToolProcessObservationLog()
        var thrownReason: String?
        do {
            _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.run(Pins.missingTool(label: "ghost"))
            }
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(_, let reason, let results) {
            XCTAssertTrue(results.isEmpty)
            thrownReason = reason
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let stage = try XCTUnwrap(log.all.first?.stages.first)
        XCTAssertEqual(stage.ending, .launchFailed(reason: try XCTUnwrap(thrownReason)))
        XCTAssertTrue(stage.failedOnItsOwn)
        XCTAssertNil(stage.startedAt)
        XCTAssertNil(stage.wallTime)
        XCTAssertNil(stage.outputComplete)
        XCTAssertNil(stage.stderr)
    }

    // MARK: - Pipelines

    /// The second of three stages cannot launch. The entries say the first
    /// was stopped on its account, the second could not launch and the third
    /// never launched.
    func testAPipelineWhoseMiddleStageCannotLaunchHasAnEntryForEveryDeclaredStage() async throws {
        let log = ToolProcessObservationLog()
        do {
            _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.runPipeline(
                    [
                        Fixtures.shell("while true; do sleep 1; done", label: "first"),
                        Pins.missingTool(label: "ghost"),
                        Pins.tool("/bin/cat", label: "last"),
                    ],
                    timeout: .seconds(30)
                )
            }
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed(let label, _, let results) {
            XCTAssertEqual(label, "ghost")
            XCTAssertEqual(results.map(\.stop), [.pipelineStageFailed(stage: 1)])
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let observation = try XCTUnwrap(log.all.first)
        XCTAssertNil(observation.stop)
        XCTAssertEqual(observation.stages.map(\.label), ["first", "ghost", "last"])
        XCTAssertEqual(observation.stages.map(\.index), [0, 1, 2])
        XCTAssertEqual(observation.stages.map(\.stageCount), [3, 3, 3])
        XCTAssertTrue(observation.stages[0].ending.launched)
        XCTAssertEqual(observation.stages[0].stop, .pipelineStageFailed(stage: 1))
        guard case .launchFailed = observation.stages[1].ending else {
            return XCTFail("Expected a launch failure, got \(observation.stages[1].ending)")
        }
        XCTAssertEqual(observation.stages[2].ending, .notLaunched)
        XCTAssertEqual(observation.stages.map(\.failedOnItsOwn), [false, true, false])
    }

    func testThePipelineVerdictNamesOnlyTheStageThatFailedOnItsOwn() async throws {
        let log = ToolProcessObservationLog()
        let result = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await ToolProcess.runPipeline(
                [
                    Fixtures.shell("while true; do sleep 1; done", label: "endless"),
                    Fixtures.shell("sleep 0.2; exit 3", label: "failing"),
                ],
                timeout: .seconds(60)
            )
        }
        XCTAssertEqual(result.failedStageIndices, [1])
        let stages = try XCTUnwrap(log.all.first).stages
        XCTAssertEqual(stages.map(\.failedOnItsOwn), [false, true])
        XCTAssertEqual(stages[0].stop, .pipelineStageFailed(stage: 1))
        XCTAssertEqual(stages[1].ending, .terminated(.exited(code: 3)))
    }

    func testAnUpstreamStageEndedBySIGPIPEIsNoFailureWhenTheNextStageIsClean() async throws {
        let log = ToolProcessObservationLog()
        let result = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await ToolProcess.runPipeline(
                [Pins.tool("/usr/bin/yes", label: "yes"), Pins.tool("/usr/bin/head", label: "head")],
                timeout: .seconds(30)
            )
        }
        XCTAssertTrue(result.isSuccess)
        let stages = try XCTUnwrap(log.all.first).stages
        XCTAssertEqual(stages.map(\.ending), [.terminated(.signaled(signal: SIGPIPE)), .terminated(.exited(code: 0))])
        XCTAssertEqual(stages.map(\.failedOnItsOwn), [false, false])
        XCTAssertEqual(stages.map(\.outputComplete), [true, true])
    }

    // MARK: - runBlocking and handles

    func testRunBlockingAndAHandleDeliverBeforeTheirWaitsReturn() async throws {
        let log = ToolProcessObservationLog()
        let blocking = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try ToolProcess.runBlocking(Fixtures.shell("exit 2"))
        }
        XCTAssertEqual(blocking.termination, .exited(code: 2))
        XCTAssertEqual(log.all.count, 1)
        let waited = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try ToolProcess.start(Fixtures.shell("exit 4"))
        }.waitBlocking()
        XCTAssertEqual(waited.termination, .exited(code: 4))
        XCTAssertEqual(log.all.count, 2)
        let handle = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try ToolProcess.start(Fixtures.shell("exit 5"))
        }
        let awaited = try await handle.result()
        XCTAssertEqual(awaited.termination, .exited(code: 5))
        XCTAssertEqual(log.all.map { $0.stages.map(\.ending) }, [
            [.terminated(.exited(code: 2))],
            [.terminated(.exited(code: 4))],
            [.terminated(.exited(code: 5))],
        ])
    }

    func testADroppedHandleStillDeliversItsObservation() async throws {
        let log = ToolProcessObservationLog()
        try await ToolProcessObservation.$observer.withValue(log.observer) {
            _ = try ToolProcess.start(Fixtures.shell("sleep 0.2; exit 6"))
        }
        let delivered = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            log.all.count == 1
        }
        XCTAssertTrue(delivered, "a run whose handle is dropped must still deliver")
        XCTAssertEqual(log.all.first?.stages.map(\.ending), [.terminated(.exited(code: 6))])
    }

    /// The reader of a streamed stdout is judged after the run ends, so the
    /// run leaves the stage's output completeness not recorded (P3).
    func testAStreamedStdoutLeavesOutputCompletenessNotRecorded() async throws {
        let log = ToolProcessObservationLog()
        let run = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try ToolProcess.start(ToolProcessSpec(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["streamed"],
                environment: [:],
                stdout: .stream,
                label: "echo"
            ))
        }
        let bytes = ToolProcessStreamTests.readToEnd(run.stdout)
        let result = try await run.result()
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "streamed\n")
        XCTAssertTrue(result.outputComplete)
        let stage = try XCTUnwrap(log.all.first?.stages.first)
        XCTAssertEqual(stage.ending, .terminated(.exited(code: 0)))
        XCTAssertNil(stage.outputComplete)
    }

    /// Delivery holds no lock of the run. The run's lock is not recursive, so
    /// an observer reading the handle's pid would hang or trap under it. The
    /// child waits for a marker that the test creates once the handle is
    /// stored, so the observer cannot run before that, however long the test
    /// thread is descheduled.
    func testAnObserverMayReadTheRunHandleBecauseDeliveryHoldsNoLock() async throws {
        let directory = try makeToolProcessTempDirectory()
        let marker = directory.appendingPathComponent("handle-stored")
        let handle = ToolProcessTestBox<ToolProcessRun?>(nil)
        // The observer holds the box, the box the run, the run its engine and
        // the engine the observer, so the box is emptied however the test ends.
        defer { handle.withLock { $0 = nil } }
        let seenPID = ToolProcessTestBox<Int32?>(nil)
        let observer = ToolProcessObserver { _ in
            let pid = handle.withLock { $0 }?.pid
            seenPID.withLock { $0 = pid }
        }
        let waiting = "while [ ! -e \(Fixtures.shellQuote(marker.path)) ]; do sleep 0.02; done"
        let run = try await ToolProcessObservation.$observer.withValue(observer) {
            try ToolProcess.start(Fixtures.shell(waiting, timeout: .seconds(30)))
        }
        handle.withLock { $0 = run }
        try Data().write(to: marker)
        let result = try await run.result()
        XCTAssertEqual(seenPID.withLock { $0 }, result.pid)
    }

    // MARK: - Scope, stderr and clocks

    /// A run reads the observer where it is built. One built outside the
    /// scope, or in a detached task that drops the binding, delivers nothing,
    /// and one built inside delivers even when awaited outside.
    func testOnlyARunBuiltInsideTheScopeDelivers() async throws {
        let log = ToolProcessObservationLog()
        let observer = log.observer
        _ = try await ToolProcess.run(Fixtures.shell("true"))
        let handle = try await ToolProcessObservation.$observer.withValue(observer) {
            try ToolProcess.start(Fixtures.shell("true", label: "inside"))
        }
        _ = try await handle.result()
        try await ToolProcessObservation.$observer.withValue(observer) {
            _ = try await Task.detached { try await ToolProcess.run(Fixtures.shell("true")) }.value
            do {
                var invalid = Fixtures.shell("true")
                invalid.stderr = .stream
                _ = try await ToolProcess.run(invalid)
                XCTFail("Expected an invalid spec")
            } catch ToolProcessError.invalidSpec {
            }
        }
        XCTAssertEqual(log.all.map { $0.stages.map(\.label) }, [["inside"]])
    }

    func testStderrIsBoundedToItsHeadAndTailBeforeDelivery() async throws {
        let written = Data((1...20_000).map { "\($0)\n" }.joined().utf8)
        let log = ToolProcessObservationLog()
        var limited = Fixtures.shell("seq 1 20000 >&2")
        limited.stderr = .capture(limit: 50_000)
        let (whole, cut) = try await ToolProcessObservation.$observer.withValue(log.observer) {
            (try await ToolProcess.run(Fixtures.shell("seq 1 20000 >&2")), try await ToolProcess.run(limited))
        }
        XCTAssertEqual(whole.stderr, written)
        XCTAssertTrue(cut.stderrTruncated)
        let excerpts = log.all.compactMap { $0.stages.first?.stderr }
        XCTAssertEqual(excerpts.count, 2)
        let head = ToolProcessRunObservation.StderrExcerpt.headByteLimit
        let tail = ToolProcessRunObservation.StderrExcerpt.tailByteLimit
        XCTAssertEqual(head, 8_192)
        XCTAssertEqual(tail, 32_768)
        XCTAssertEqual(excerpts[0].head, written.prefix(head))
        XCTAssertEqual(excerpts[0].tail, written.suffix(tail))
        XCTAssertEqual(excerpts[0].omittedByteCount, written.count - head - tail)
        XCTAssertFalse(excerpts[0].earlierBytesDropped)
        let kept = written.suffix(50_000)
        XCTAssertEqual(excerpts[1].head, kept.prefix(head))
        XCTAssertEqual(excerpts[1].tail, kept.suffix(tail))
        XCTAssertEqual(excerpts[1].omittedByteCount, 50_000 - head - tail)
        XCTAssertTrue(excerpts[1].earlierBytesDropped)
    }

    /// The recipe that the `StderrExcerpt` doc comment gives a recorder.
    private static func recorded(_ excerpt: ToolProcessRunObservation.StderrExcerpt) -> String? {
        let head = String(decoding: excerpt.head, as: UTF8.self)
        guard excerpt.omittedByteCount > 0 else { return ProvenanceStderr.truncated(head) }
        let tail = String(decoding: excerpt.tail, as: UTF8.self)
        return String(head.prefix(ProvenanceStderr.headLength))
            + ProvenanceStderr.truncationMarker
            + String(tail.suffix(ProvenanceStderr.tailLength))
    }

    /// The recipe gives the stderr that `ProvenanceStderr.truncated` gives for
    /// the whole capture, at each boundary of the limits and for characters of
    /// one, three and four bytes. Applying `truncated` to the joined head and
    /// tail does not, because four-byte characters just over the limits join
    /// to exactly `maxLength` characters, which it keeps whole without the
    /// marker.
    func testTheExcerptRecipeKeepsWhatTheWholeCaptureWouldKeep() {
        let captures: [(name: String, text: String)] = [
            ("ascii inside both limits", String(repeating: "a", count: 5_000)),
            ("ascii over maxLength and inside both limits", String(repeating: "a", count: 30_000)),
            ("ascii over both limits", String(repeating: "a", count: 100_000)),
            ("three-byte characters over both limits", String(repeating: "\u{20AC}", count: 20_000)),
            ("four-byte characters at both limits", String(repeating: "\u{1F600}", count: 10_240)),
            ("four-byte characters just over both limits", String(repeating: "\u{1F600}", count: 10_241)),
            ("four-byte characters far over both limits", String(repeating: "\u{1F600}", count: 12_000)),
            ("mixed widths over both limits", String(repeating: "a\u{20AC}\u{1F600}", count: 9_000)),
        ]
        for (name, text) in captures {
            let excerpt = ToolProcessRunObservation.StderrExcerpt(captured: Data(text.utf8), earlierBytesDropped: false)
            XCTAssertEqual(Self.recorded(excerpt), ProvenanceStderr.truncated(text), name)
        }
        let justOver = String(repeating: "\u{1F600}", count: 10_241)
        let excerpt = ToolProcessRunObservation.StderrExcerpt(captured: Data(justOver.utf8), earlierBytesDropped: false)
        XCTAssertEqual(excerpt.omittedByteCount, 4)
        let joined = String(decoding: excerpt.head + excerpt.tail, as: UTF8.self)
        XCTAssertEqual(joined.count, ProvenanceStderr.maxLength)
        XCTAssertNotEqual(ProvenanceStderr.truncated(joined), ProvenanceStderr.truncated(justOver))
    }

    /// The wall clock is read through the provenance time source when the
    /// run is built, so a test pins it for the building task, and every
    /// stage's start is that time plus monotonic time.
    func testWallClockTimesComeFromTheProvenanceTimeSourceWhenTheRunIsBuilt() async throws {
        let pinned = Date(timeIntervalSince1970: 1_800_000_000)
        let source = ProvenanceTimeSource(wallClockNow: { pinned }, monotonicNow: { ContinuousClock.now })
        let log = ToolProcessObservationLog()
        _ = try await ProvenanceTimeSource.$override.withValue(source) {
            try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.runPipeline(
                    [Fixtures.shell("sleep 0.1; echo a", label: "slow"), Pins.tool("/bin/cat", label: "cat")],
                    timeout: .seconds(30)
                )
            }
        }
        let observation = try XCTUnwrap(log.all.first)
        XCTAssertEqual(observation.startedAt, pinned)
        XCTAssertGreaterThanOrEqual(observation.wallTime, .milliseconds(100))
        for stage in observation.stages {
            let startedAt = try XCTUnwrap(stage.startedAt)
            XCTAssertGreaterThanOrEqual(startedAt, pinned)
            XCTAssertLessThan(startedAt, pinned.addingTimeInterval(30))
        }
    }

    /// Runs in flight at once deliver in the order they end. The sequence
    /// number keeps the order in which they were built.
    func testSequenceNumbersFollowTheOrderRunsWereBuilt() async throws {
        let log = ToolProcessObservationLog()
        let (slow, quick) = try await ToolProcessObservation.$observer.withValue(log.observer) {
            (try ToolProcess.start(Fixtures.shell("sleep 0.5", label: "slow")), try ToolProcess.start(Fixtures.shell("true", label: "quick")))
        }
        _ = try await quick.result()
        _ = try await slow.result()
        let ordered = log.all.sorted { $0.sequenceNumber < $1.sequenceNumber }
        XCTAssertEqual(ordered.map { $0.stages.map(\.label) }, [["slow"], ["quick"]])
    }
}

/// Phase 2.7 lane S1 (B1). A task cancelled before the launch launches
/// nothing and still throws `cancelled(results: [])`, and the run goes
/// through the normal stop path, so it delivers an observation whose entries
/// read never launched.
final class ToolProcessEarlyCancelObservationTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures
    private typealias Pins = ToolProcessEntryPointPinTests

    func testARunCancelledBeforeLaunchDeliversAnObservationOfNothingLaunched() async throws {
        let log = ToolProcessObservationLog()
        let launched = ToolProcessTestBox(false)
        let task = Task { () async throws -> ToolProcessResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.run(
                    Fixtures.shell("true", label: "never"),
                    onLaunch: { _ in launched.withLock { $0 = true } }
                )
            }
        }
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertTrue(results.isEmpty)
        default:
            XCTFail("Expected cancelled with no results")
        }
        XCTAssertFalse(launched.withLock { $0 })
        let observations = log.all
        XCTAssertEqual(observations.count, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.stop, .cancelled)
        XCTAssertEqual(observation.stages.map(\.label), ["never"])
        XCTAssertEqual(observation.stages.map(\.ending), [.notLaunched])
        XCTAssertEqual(observation.stages.map(\.failedOnItsOwn), [false])
        XCTAssertEqual(observation.stages.map(\.stop), [nil])
    }

    func testAPipelineCancelledBeforeLaunchDeliversAnEntryForEveryStage() async throws {
        let log = ToolProcessObservationLog()
        let launched = ToolProcessTestBox<[Int]>([])
        let task = Task { () async throws -> ToolPipelineResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.runPipeline(
                    [Fixtures.shell("true", label: "first"), Pins.tool("/bin/cat", label: "second")],
                    timeout: .seconds(30),
                    onLaunch: { stage, _ in launched.withLock { $0.append(stage) } }
                )
            }
        }
        switch await task.result {
        case .failure(ToolProcessError.cancelled(let results)):
            XCTAssertTrue(results.isEmpty)
        default:
            XCTFail("Expected cancelled with no results")
        }
        XCTAssertEqual(launched.withLock { $0 }, [])
        let observations = log.all
        XCTAssertEqual(observations.count, 1)
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.stop, .cancelled)
        XCTAssertEqual(observation.stages.map(\.label), ["first", "second"])
        XCTAssertEqual(observation.stages.map(\.ending), [.notLaunched, .notLaunched])
    }

    /// runBlocking with a cancellation that came first already went through
    /// the run, and it delivers the same observation.
    func testABlockingRunWhoseCancellationCameFirstDeliversToo() async throws {
        let log = ToolProcessObservationLog()
        let cancellation = ToolProcessCancellation()
        cancellation.cancel()
        do {
            _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
                try ToolProcess.runBlocking(Fixtures.shell("true", label: "never"), cancellation: cancellation)
            }
            XCTFail("Expected a cancellation")
        } catch ToolProcessError.cancelled(let results) {
            XCTAssertTrue(results.isEmpty)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let observation = try XCTUnwrap(log.all.first)
        XCTAssertEqual(observation.stop, .cancelled)
        XCTAssertEqual(observation.stages.map(\.ending), [.notLaunched])
    }
}

/// Phase 2.7 lane S1 (decision P4). Each reaped stage's peak memory comes
/// from `wait4` into the observation only. The rule that no record writes it
/// until a golden normalizer rule for it is approved lives on
/// `ToolProcessRunObservation.Stage.observedPeakMemoryBytes` and in
/// `docs/contracts/RECORDING-PROVENANCE.md`. The guard for that rule belongs
/// to the lane that first turns an observation into a record.
final class ToolProcessObservedPeakMemoryTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures
    private typealias Pins = ToolProcessEntryPointPinTests

    /// The shell holds a 16 MB string, so its peak resident memory is at
    /// least that, in bytes as Darwin reports it. A stage that never
    /// launched has none.
    func testEachReapedStageCarriesThePeakMemoryWait4Reports() async throws {
        let log = ToolProcessObservationLog()
        let result = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await ToolProcess.run(Fixtures.shell("x=$(head -c 16000000 /dev/zero | tr '\\000' a); echo ${#x}"))
        }
        XCTAssertEqual(result.stdoutText, "16000000\n")
        let peak = try XCTUnwrap(log.all.first?.stages.first?.observedPeakMemoryBytes)
        XCTAssertGreaterThanOrEqual(peak, 16_000_000)
        XCTAssertLessThan(peak, 4_000_000_000, "a value this large would mean the units are wrong")
        do {
            _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
                try await ToolProcess.runPipeline(
                    [Fixtures.shell("true", label: "first"), Pins.missingTool(label: "ghost")],
                    timeout: .seconds(30)
                )
            }
            XCTFail("Expected launchFailed")
        } catch ToolProcessError.launchFailed {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let stages = try XCTUnwrap(log.all.last).stages
        XCTAssertNotNil(stages[0].observedPeakMemoryBytes)
        XCTAssertNil(stages[1].observedPeakMemoryBytes)
    }
}
