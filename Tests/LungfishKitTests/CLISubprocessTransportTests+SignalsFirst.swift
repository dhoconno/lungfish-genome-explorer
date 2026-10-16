// CLISubprocessTransportTests+SignalsFirst.swift - A run that signals the CLI first keeps the tools until the grace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 U30 walk, finding W2, review fix 4. The Core tests of `ToolProcessSpec.signalsProcessFirst` show the
// signal routing with a real shell tree, and none crosses `CLISubprocessTransport.run(signalsCommandFirst:)`. This
// test does, with tools in groups of their own that outlive the stand-in CLI. It lives in an extension in its own
// file, since `CLISubprocessTransportTests.swift` would pass 800 lines, and uses the helpers of that class.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishKit

extension CLISubprocessTransportTests {
    /// A run that sets `signalsCommandFirst` sends SIGTERM to the CLI alone and SIGKILL to its group and its tree at
    /// the end of the grace. The stand-in CLI exits on SIGTERM and leaves the tools of the test above in the states a
    /// real tool can be in, each in a group of its own. The stopper, which would exit on SIGTERM within about a
    /// second, is the probe. The first termination holds the tools in its tree from the snapshot at the cancel and the
    /// second one, which the CLI's exit starts, finds no child of a dead leader. So the stopper still runs 1.5 s after
    /// the cancel only if no SIGTERM reached it, and the SIGKILL at the grace ends every tool, whatever its group or
    /// its answer to SIGTERM.
    func testSignalsCommandFirstSignalsTheCLIAloneAndTheGraceKillsTheTree() async throws {
        let cliPIDFile = folder.appendingPathComponent("cli.pid")
        let stopperPIDFile = folder.appendingPathComponent("stopper.pid")
        let ignorerPIDFile = folder.appendingPathComponent("ignorer.pid")
        let helperPIDFile = folder.appendingPathComponent("helper.pid")
        let helper = try script(named: "helper.sh", """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(helperPIDFile.path)"
        while true; do /bin/sleep 1; done
        """)
        let ignorer = try script(named: "ignorer.sh", """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(ignorerPIDFile.path)"
        set -m
        /bin/sh "\(helper.path)" &
        set +m
        while true; do /bin/sleep 1; done
        """)
        let stopper = try script(named: "stopper.sh", """
        #!/bin/sh
        trap 'exit 0' TERM
        echo $$ > "\(stopperPIDFile.path)"
        while true; do /bin/sleep 1; done
        """)
        let cli = try fakeCLI("""
        #!/bin/sh
        trap 'exit 0' TERM
        echo $$ > "\(cliPIDFile.path)"
        set -m
        /bin/sh "\(stopper.path)" &
        /bin/sh "\(ignorer.path)" &
        set +m
        while true; do /bin/sleep 1; done
        """)
        let transport = CLISubprocessTransport(cliURLOverride: cli)
        let task = Task {
            try await transport.run(
                arguments: [],
                terminationGracePeriod: .seconds(3),
                signalsCommandFirst: true,
                isCancelled: { false },
                onEvent: { _ in }
            )
        }

        var tools: [Int32] = []
        let up = await waitUntil(timeout: .seconds(30)) {
            tools = [cliPIDFile, stopperPIDFile, ignorerPIDFile, helperPIDFile].compactMap { readPID($0) }
            return tools.count == 4
        }
        defer { tools.forEach { kill($0, SIGKILL) } }
        guard up else {
            transport.cancel()
            return XCTFail("the stand-in CLI never started its tools")
        }
        let (cliPID, stopperPID, ignorerPID, helperPID) = (tools[0], tools[1], tools[2], tools[3])
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: cliPID)
        XCTAssertTrue([stopperPID, ignorerPID, helperPID].allSatisfy(tree.contains), "the walk from the CLI reaches every tool, found \(tree)")
        XCTAssertNotEqual(getpgid(stopperPID), getpgid(cliPID), "a tool runs in a group of its own")
        XCTAssertNotEqual(getpgid(helperPID), getpgid(ignorerPID), "so does the helper of a tool")

        let cancelledAt = ContinuousClock.now
        transport.cancel()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(ProcessTreeTerminator.processExists(pid: stopperPID), "the stopper got no SIGTERM, so it runs on after the CLI exited")
        let outcome = try await wait(for: task)
        guard case .failure(let error) = outcome else { return XCTFail("a cancelled run returns no result") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - cancelledAt, .milliseconds(2500), "the run held the tree until the grace")
        let everyone = tools + tree
        let gone = await waitUntil(timeout: .seconds(30)) { !everyone.contains { ProcessTreeTerminator.processExists(pid: $0) } }
        XCTAssertTrue(gone, "the SIGKILL at the grace ends every tool, whatever its group or its answer to SIGTERM")
    }
}
