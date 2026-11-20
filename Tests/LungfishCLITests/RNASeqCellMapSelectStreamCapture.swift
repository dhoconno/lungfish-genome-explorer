// RNASeqCellMapSelectStreamCapture.swift - Runs rnaseq cell-map select in process on the STARsolo cut
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `rnaseq cell-map select` (Phase 5.5 lane CM-SELECT-CLI) whose `--format json` standard output is checked in
/// under `Tests/Fixtures/cli-events/commands/rnaseq-cell-map-select`. The command needs no tool and no window server. It
/// imports 10x's t-SNE onto the STARsolo cut, then selects graph cluster 1.
enum RNASeqCellMapSelectStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "rnaseq cell-map select", name: "complete") { scratch in
                let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: scratch.root)
                let map = scratch.root.appendingPathComponent("Analyses/tsne.lungfishrnaseq", isDirectory: true)
                try await RNASeqCellMapImportSubcommand.parse([
                    result.path, "--coordinates", CellMapImportFixture.projection.path, "--clusters", CellMapImportFixture.clusters.path,
                    "--barcode-suffix", "drop", "--other-counts", "--output", map.path, "--quiet",
                ]).run()
                let command = try RNASeqCellMapSelectSubcommand.parse([
                    map.path, "--embedding", "TSNE", "--label-set", "graphclust", "--label", "1",
                    "--output", scratch.root.appendingPathComponent("Analyses/selection.tsv").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
