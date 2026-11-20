// RNASeqCellMapImportStreamCapture.swift - Runs rnaseq cell-map import in process on the STARsolo cut
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `rnaseq cell-map import` (Phase 5.5 lane CM-IMPORT) whose `--format json` standard output is checked in
/// under `Tests/Fixtures/cli-events/commands/rnaseq-cell-map-import`. The command needs no tool and no window server. The
/// STARsolo cut takes 10x's t-SNE with `--barcode-suffix drop` and `--other-counts`, so the transcript holds that warning.
enum RNASeqCellMapImportStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "rnaseq cell-map import", name: "complete") { scratch in
                let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: scratch.root)
                let command = try RNASeqCellMapImportSubcommand.parse([
                    result.path, "--coordinates", CellMapImportFixture.projection.path, "--clusters", CellMapImportFixture.clusters.path,
                    "--barcode-suffix", "drop", "--other-counts",
                    "--output", scratch.root.appendingPathComponent("Analyses/tsne.lungfishrnaseq", isDirectory: true).path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
