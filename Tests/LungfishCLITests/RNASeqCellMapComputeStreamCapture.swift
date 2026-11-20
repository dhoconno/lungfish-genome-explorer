// RNASeqCellMapComputeStreamCapture.swift - Runs rnaseq cell-map compute in process on the STARsolo cut
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `rnaseq cell-map compute` (Phase 5.5 lane CM-COMPUTE) whose `--format json` standard output is checked in
/// under `Tests/Fixtures/cli-events/commands/rnaseq-cell-map-compute`. The leaf runs on the STARsolo cut through the
/// stand-in route of `RNASeqCellMapComputeTests`, which writes the pin's record, so no tool and no window server is needed.
/// The real route's run is `RNASeqCellMapComputeConformanceTests`.
enum RNASeqCellMapComputeStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "rnaseq cell-map compute", name: "complete") { scratch in
                let result = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: scratch.root)
                let command = try RNASeqCellMapComputeSubcommand.parse([
                    result.path, "--output", scratch.root.appendingPathComponent("Analyses/umap.lungfishrnaseq", isDirectory: true).path,
                    "--format", "json",
                ])
                let launch = ComputeStandIn.launch(record: try ComputeStandIn.pinRecord, seen: ComputeLaunchSeen())
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run(launch: launch) }
            },
        ]
    }
}
