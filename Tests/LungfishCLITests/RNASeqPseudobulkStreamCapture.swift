// RNASeqPseudobulkStreamCapture.swift - Runs rnaseq pseudobulk in process on the STARsolo cut
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `rnaseq pseudobulk` (Phase 5.2 lane RS-PSEUDOBULK) whose `--format json` standard output is checked in under
/// `Tests/Fixtures/cli-events/commands/rnaseq-pseudobulk`. The command needs no tool and no window server, and the
/// fixture's label table leaves out its 9-cell group, so the transcript holds that warning.
enum RNASeqPseudobulkStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "rnaseq pseudobulk", name: "complete") { scratch in
                let result = try RNASeqPseudobulkCommandTests.makeSingleCellResult(in: scratch.root)
                let command = try RNASeqPseudobulkSubcommand.parse([
                    result.path, "--labels", RNASeqPseudobulkCommandTests.labels.path,
                    "--output", scratch.root.appendingPathComponent("Analyses/pb.lungfishrnaseq", isDirectory: true).path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
