// CLIMemoryGuardTests.swift - At its memory share the CLI stops the work, says why and exits nonzero
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishWorkflow

/// The guard reads the footprint through an injected reader, so these tests set a footprint over the share and
/// allocate nothing.
final class CLIMemoryGuardTests: XCTestCase {
    private let sixteenGB: UInt64 = 16 << 30

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _stderr: [String] = []
        private var _events: [String] = []
        private var _toolStops = 0
        private var _exits: [Int32] = []
        private var order: [String] = []

        var stderr: [String] { lock.withLock { _stderr } }
        var events: [String] { lock.withLock { _events } }
        var toolStops: Int { lock.withLock { _toolStops } }
        var exits: [Int32] { lock.withLock { _exits } }
        var steps: [String] { lock.withLock { order } }

        var sinks: CLIMemoryGuard.Sinks {
            CLIMemoryGuard.Sinks(
                stderr: { line in self.lock.withLock { self._stderr.append(line); self.order.append("stderr") } },
                event: { line in self.lock.withLock { self._events.append(line); self.order.append("event") } },
                stopTools: { self.lock.withLock { self._toolStops += 1; self.order.append("stopTools") } },
                exit: { code in self.lock.withLock { self._exits.append(code); self.order.append("exit") } }
            )
        }
    }

    private func makeGuard(
        footprint: UInt64?, eventsOn: Bool, recorder: Recorder, command: String = "import fastq"
    ) -> CLIMemoryGuard {
        CLIMemoryGuard(
            command: command,
            eventsOn: eventsOn,
            share: ProcessMemoryShare(physicalMemoryBytes: sixteenGB),
            readFootprint: { footprint },
            sinks: recorder.sinks
        )
    }

    private let expectedWords = "lungfish-cli stopped import fastq because it was using 9 GB of memory, half or more of "
        + "the 16 GB on this Mac. It stops there so the Mac does not run out of memory. Run the command on fewer or "
        + "smaller files at a time, or on a Mac with more memory."

    func testAtTheShareTheCLIStopsToolsWritesStderrAndEventAndExitsNonzero() throws {
        let recorder = Recorder()
        let memoryGuard = makeGuard(footprint: 9 << 30, eventsOn: true, recorder: recorder)
        memoryGuard.check()
        XCTAssertEqual(recorder.stderr, ["Error: " + expectedWords])
        XCTAssertEqual(recorder.events.count, 1)
        let line = try XCTUnwrap(recorder.events.first)
        let event = try JSONDecoder().decode(CLIEvent.self, from: Data(line.utf8))
        XCTAssertEqual(event, .failed(message: expectedWords, detail: nil))
        XCTAssertEqual(recorder.toolStops, 1)
        XCTAssertEqual(recorder.exits, [CLIMemoryGuard.exitStatus])
        XCTAssertNotEqual(CLIMemoryGuard.exitStatus, 0)
        XCTAssertEqual(recorder.steps, ["stderr", "event", "stopTools", "exit"])
    }

    func testWithEventsOffOnlyStderrCarriesTheWords() {
        let recorder = Recorder()
        makeGuard(footprint: 8 << 30, eventsOn: false, recorder: recorder).check()
        XCTAssertEqual(recorder.stderr.count, 1)
        XCTAssertTrue(recorder.stderr[0].contains("using 8 GB of memory"), recorder.stderr[0])
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertEqual(recorder.exits, [CLIMemoryGuard.exitStatus])
    }

    func testUnderTheShareNothingHappens() {
        let recorder = Recorder()
        let memoryGuard = makeGuard(footprint: (8 << 30) - 1, eventsOn: true, recorder: recorder)
        memoryGuard.check()
        let unreadable = makeGuard(footprint: nil, eventsOn: true, recorder: recorder)
        unreadable.check()
        XCTAssertTrue(recorder.steps.isEmpty)
    }

    func testTheShareIsHalfThePhysicalMemoryReadEveryTwoSeconds() {
        XCTAssertEqual(ProcessMemoryShare(physicalMemoryBytes: 64 << 30).limitBytes, 32 << 30)
        XCTAssertEqual(ProcessMemoryShare(physicalMemoryBytes: sixteenGB).limitBytes, 8 << 30)
        XCTAssertEqual(ProcessMemoryShare.pollInterval, .seconds(2))
    }

    func testFootprintReaderReadsThisProcess() throws {
        let footprint = try XCTUnwrap(ProcessMemoryShare.currentFootprint())
        XCTAssertGreaterThan(footprint, 1 << 20)
        XCTAssertLessThan(footprint, ProcessInfo.processInfo.physicalMemory)
    }

    func testCommandAndEventsAreReadFromTheArguments() {
        XCTAssertEqual(CLIMemoryGuard.command(in: ["import", "fastq", "--format", "json", "/x/r.fq"]), "import fastq")
        XCTAssertEqual(CLIMemoryGuard.command(in: ["extract", "/x/a.fa"]), "extract")
        XCTAssertEqual(CLIMemoryGuard.command(in: ["--help"]), "the command")
        XCTAssertTrue(CLIMemoryGuard.eventsOn(in: ["esviritu", "--format", "json"]))
        XCTAssertTrue(CLIMemoryGuard.eventsOn(in: ["esviritu", "--format=json"]))
        XCTAssertFalse(CLIMemoryGuard.eventsOn(in: ["esviritu", "--format", "text"]))
    }
}
