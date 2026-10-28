// PrimerDesignCLIGUIParityReplayTests+Cancel.swift - A primer design cancels through the app's transport, every core busy
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.17 M2, PLAN section 8 X14, the SIGTERM part of the recipe of a CLI route
// (`docs/contracts/ADDING-AN-OPERATION.md`). The dialog's Primer3 command runs on a stand-in `primer3_core` that writes
// its pid and sleeps, named with `--primer3-path`, so the case needs no managed tool. Primer3 publishes its bundle in one
// move from a scratch folder beside it, and a cancel removes the scratch, so the design leaves no record, and the case
// asserts that no bundle and no scratch are left in place of a record that reads cancelled.
//
// The failure case answers fix 1 of the lane 12.17 review. A design that fails exits 64 after its failed event
// (`docs/contracts/ADDING-AN-OPERATION.md:184`), where the leaves first rethrew the pipeline's error and exited 1. A
// stand-in `primer3_core` that exits 1 makes the design fail.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

extension PrimerDesignCLIGUIParityReplayTests {
    /// The command through the transport exits 125 inside the grace with its failed event, and leaves no process, no
    /// bundle and no scratch. Then the row's Cancel through `CLIPrimerDesignRunner` ends the row Cancelled with no
    /// failure, and the stand-in is gone.
    func testACancelledPrimer3DesignEndsCancelledThroughTheTransportWithEveryCoreBusy() async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin")

        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeFixture(root)
        let pidFile = scratch.appendingPathComponent("primer3.pid")
        let primer3 = try Self.writeSleepingPrimer3(in: scratch, pidFile: pidFile)
        let state = await Self.dialog(in: root)
        let destination = try state.validatedDestinationURL(createParent: false)
        let argv = try XCTUnwrap(PrimerDesignOperation.cliArgv(state: state, destination: destination))
            + ["--primer3-path", primer3.path]

        let run = await RouteParityHarness.runCLI(
            cli, arguments: CLIPrimerDesignRunner.arguments(argv: argv), timeout: .seconds(60), environment: [:],
            cancelWhen: { FileManager.default.fileExists(atPath: pidFile.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "primer3 never ran, so nothing was cancelled: \(run.detail)\n\(run.stderr)")
        CLISIGTERMHarness.assertCancelledExit(
            status: observed.status, elapsed: observed.elapsed, within: CLIPrimerDesignRunner.terminationGracePeriod,
            detail: " \(run.detail)\n\(run.stderr)"
        )
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        let lastEvent = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(lastEvent.contains(#""event":"failed""#) && lastEvent.contains("Primer design cancelled"), run.stdout)
        try assertNothingLeft(at: destination)

        try FileManager.default.removeItem(at: pidFile)
        let handle = PrimerDesignOperation.startThroughCLI(
            title: "\(state.engine.rawValue) · \(state.analysisName)", destination: destination, routeContext: nil,
            argv: argv, runner: CLIPrimerDesignRunner(cliURLOverride: cli),
            onResultSaved: { _ in XCTFail("a cancelled design saves nothing") }
        )
        let started = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        XCTAssertTrue(started, "the row's command never started primer3")
        OperationCenter.shared.cancel(id: handle.id)
        await handle.task.value
        let row = OperationCenter.shared.items.first { $0.id == handle.id }
        XCTAssertEqual(row?.state, .cancelled, "the row reads Cancelled: \(row?.detail ?? "no row")")
        XCTAssertNil(row?.errorMessage, "a cancelled row holds no failure, so no alert shows")
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        await CLISIGTERMHarness.assertNoProcessLeft([try XCTUnwrap(Int32(pidText))])
        try assertNothingLeft(at: destination)
    }

    /// A design whose Primer3 run fails ends with its failed event and exit 64, the exit of a failure
    /// (`docs/contracts/ADDING-AN-OPERATION.md:184`, ruling 1 of the lane 12.17 review). The first form of the leaves
    /// rethrew the pipeline's error, which ArgumentParser ends with status 1. The stand-in `primer3_core` answers
    /// `--about`, then writes a line to standard error and exits 1, so the design fails once Primer3 runs. The refusal
    /// keeps its exit 3 (`PrimerDesignExistingOutputTests`) and the cancel its 125 (the case above).
    func testAFailedPrimer3DesignExitsSixtyFourAfterItsFailedEvent() async throws {
        let root = scratch.appendingPathComponent("failure", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeFixture(root)
        let primer3 = try Self.writeFailingPrimer3(in: scratch)
        let state = await Self.dialog(in: root)
        let destination = try state.validatedDestinationURL(createParent: false)
        let argv = try XCTUnwrap(PrimerDesignOperation.cliArgv(state: state, destination: destination))
            + ["--primer3-path", primer3.path]

        let run = await RouteParityHarness.runCLI(
            cli, arguments: CLIPrimerDesignRunner.arguments(argv: argv), timeout: .seconds(60), environment: [:]
        )
        XCTAssertEqual(run.status, 64, "a failed design exits 64: \(run.detail)\n\(run.stderr)")
        let lastLine = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
        let last = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any],
            "the last standard output line is an event: \(run.stdout)"
        )
        XCTAssertEqual(last["event"] as? String, "failed", "the last event is the failed event: \(run.stdout)")
        XCTAssertFalse((last["error"] as? String ?? "").isEmpty, "the failed event says why: \(lastLine)")
        try assertNothingLeft(at: destination)
    }

    /// No bundle at `destination` and no Primer3 scratch folder beside it.
    private func assertNothingLeft(at destination: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a cancelled or failed design publishes no bundle",
                       file: file, line: line)
        let parent = destination.deletingLastPathComponent()
        let scratchFolders = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
            .filter { $0.hasPrefix(".lungfish-primer3-") }
        XCTAssertEqual(scratchFolders, [], "the cancel or the failure removes the design's scratch", file: file, line: line)
    }

    /// A stand-in `primer3_core` that answers `--about` and otherwise writes its pid to `pidFile` and sleeps a minute.
    /// The pid goes to `pidFile.tmp` and moves into place, so `pidFile` never exists empty. Both cancel watches fire on
    /// its existence, and the row's case parses it after the cancel, where a SIGTERM between the shell's create and its
    /// write once left an empty file for `Int32(...)` to read as nil (item 10, the race of item 9b).
    static func writeSleepingPrimer3(in folder: URL, pidFile: URL) throws -> URL {
        let url = folder.appendingPathComponent("sleeping-primer3/primer3_core")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "--about" ]; then echo "libprimer3 release 2.6.1"; exit 0; fi
        echo $$ > '\(pidFile.path).tmp'
        /bin/mv '\(pidFile.path).tmp' '\(pidFile.path)'
        exec sleep 60
        """
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A stand-in `primer3_core` that answers `--about` and otherwise writes a line to standard error and exits 1.
    static func writeFailingPrimer3(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("failing-primer3/primer3_core")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "--about" ]; then echo "libprimer3 release 2.6.1"; exit 0; fi
        echo "stand-in primer3_core failed on purpose" >&2
        exit 1
        """
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
