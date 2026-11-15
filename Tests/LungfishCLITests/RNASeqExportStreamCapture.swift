// RNASeqExportStreamCapture.swift - Runs rnaseq export in process on a small result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `rnaseq export` (Phase 5.1 lane RS-HANDOFF) whose `--format json` standard output is checked in under
/// `Tests/Fixtures/cli-events/commands/rnaseq-export`. The command needs no tool and no window server.
/// `CLIEventTranscriptCoverageTests` runs it through `ImportStreamCapture`, which gives each run a scratch folder of
/// its own and rewrites it to `/work`. The result is `RNASeqExportCommandTests`' two samples of one salmon route.
enum RNASeqExportStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "rnaseq export", name: "complete") { scratch in
                let result = try RNASeqExportCommandTests.makeResult(
                    "a", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"], in: scratch.root)
                let command = try RNASeqExportSubcommand.parse([
                    result.path, "--output", scratch.root.appendingPathComponent("export", isDirectory: true).path,
                    "--design", "group", "--contrast", "group:TB:HIV", "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
