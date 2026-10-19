// BeginSiteCLIStandIn.swift - Runs a viewer begin site against a stand-in lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.20 (QR-a). A viewer method that begins an operation records its command on the
// operation's row and then launches `lungfish-cli` through the app's runner, which looks for the CLI through
// `LUNGFISH_CLI_PATH` first. The stand-in points that variable at a shell script that writes the arguments
// it got and exits, so the real method runs, the row holds the command the method recorded, and no real CLI
// starts. The script ends without reporting an output, so the runner fails the row. A capture returns once
// the row has left the active states, which also releases the bundle lock for the next capture.

import Foundation
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class BeginSiteCLIStandIn {
    /// What one run of a begin site left behind.
    struct Capture {
        /// The rows the site added to `OperationCenter.shared`, newest first.
        let rows: [OperationCenter.Item]
        /// The arguments the runner passed to the stand-in, nil when the stand-in never ran.
        let launchedArguments: [String]?
    }

    private let root: URL
    private var priorCLIPath: String??
    private var addedRowIDs: [UUID] = []
    private var captures = 0

    init(root: URL) {
        self.root = root
    }

    /// Runs `site` with `LUNGFISH_CLI_PATH` naming a fresh stand-in CLI. When the site began an operation,
    /// the capture waits for the stand-in to run and for the row to end, each for at most `timeout`
    /// seconds and each returning as soon as its condition holds.
    func capture(timeout: TimeInterval = 30, of site: @MainActor () -> Void) async throws -> Capture {
        captures += 1
        let folder = root.appendingPathComponent("stand-in-\(captures)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stand = try StandInAlignmentCLI.make(in: folder, body: "exit 0")
        if priorCLIPath == nil {
            priorCLIPath = .some(ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"])
        }
        setenv("LUNGFISH_CLI_PATH", stand.cli.path, 1)

        let existing = Set(OperationCenter.shared.items.map(\.id))
        site()
        let rows = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        addedRowIDs.append(contentsOf: rows.map(\.id))

        let startedIDs = Set(rows.filter { $0.state.isActive }.map(\.id))
        if !startedIDs.isEmpty {
            let launched = await Self.wait(timeout: timeout) {
                FileManager.default.fileExists(atPath: stand.startedFile.path)
            }
            XCTAssertTrue(launched, "the runner never launched the stand-in CLI")
            let ended = await Self.wait(timeout: timeout) {
                OperationCenter.shared.items.filter { startedIDs.contains($0.id) }.allSatisfy { !$0.state.isActive }
            }
            XCTAssertTrue(ended, "a started row never left the active states")
        }
        return Capture(rows: rows, launchedArguments: stand.arguments())
    }

    /// Puts `LUNGFISH_CLI_PATH` back and clears the rows the captures added.
    func restore() {
        if let priorCLIPath {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        priorCLIPath = nil
        addedRowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        addedRowIDs = []
    }

    private static func wait(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
