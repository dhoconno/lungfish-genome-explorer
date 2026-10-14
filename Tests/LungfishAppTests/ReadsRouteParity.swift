// ReadsRouteParity.swift - A Map Reads or Reassemble row, as the L6 parity classes record and compare it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M3. MappingRouteParityReplayTests and AssemblyRouteParityReplayTests run one
// launch on each side of RouteParityHarness and record each side's row (UX 1 and 3), the stage
// words, the bar, the lines logged and the end, with MappingRouteRow.Recorder.

import Combine
import Foundation
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
enum ReadsRouteParity {
    /// Runs `start` and records the row titled `title` until it ends, then clears the row.
    static func record(title: String, start: () -> Void) async throws -> (row: MappingRouteRow, item: OperationCenter.Item) {
        let recorder = MappingRouteRow.Recorder(title: title)
        let subscription = OperationCenter.shared.$items.sink { items in recorder.take(items) }
        defer { subscription.cancel() }
        start()
        await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(50)) { recorder.ended != nil }
        let item = try XCTUnwrap(recorder.ended, "the row never ended:\n\(recorder.row.text)")
        OperationCenter.shared.clearItem(id: item.id)
        var row = recorder.row
        row.logged = item.logEntries.map { "\($0.level) \($0.message)" }
        row.end = "\(item.state) \(item.detail)"
        return (row, item)
    }

    /// How a side's row ended, in the harness's words. Side C adds the command its row recorded.
    static func outcome(of item: OperationCenter.Item, recordsCommand: Bool = false) -> RouteParitySideOutcome {
        let end: RouteParityEnd
        switch item.state {
        case .completed: end = item.hasWarnings ? .completedWithWarnings : .completed
        case .cancelled: end = .cancelled
        default: end = .failed
        }
        return RouteParitySideOutcome(end: end, detail: "\(item.state) \(item.detail)", recordedCommand: recordsCommand ? item.cliCommand : nil)
    }

    /// `row` with the side's root read as `<ROOT>`, so the rows of two sides compare.
    static func rooted(_ row: MappingRouteRow, _ root: URL) -> MappingRouteRow {
        func masked(_ text: String) -> String {
            [root.resolvingSymlinksInPath().path, root.path].reduce(text) { $0.replacingOccurrences(of: $1, with: "<ROOT>") }
        }
        var row = row
        row.shown = row.shown.map(masked)
        row.logged = row.logged.map(masked)
        row.end = masked(row.end)
        return row
    }

    /// Writes `script` as an executable file at `url`.
    nonisolated static func write(_ script: String, executableAt url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A stand-in micromamba that answers version probes, and whose run of `tool` records its
    /// process ID in `pidFile` and waits. The path is written into the script, since a managed tool
    /// runs with an environment of its own.
    nonisolated static func sleepingMicromamba(tool: String, pidFile: URL) -> String {
        """
        #!/bin/sh
        for argument in "$@"; do
          case "$argument" in
            --version|-v|-V) echo "2.0.0"; exit 0 ;;
          esac
        done
        case " $* " in
          " run "*" \(tool) "*)
            echo $$ > '\(pidFile.path)'
            exec /bin/sleep 300 ;;
        esac
        exit 0
        """
    }
}
