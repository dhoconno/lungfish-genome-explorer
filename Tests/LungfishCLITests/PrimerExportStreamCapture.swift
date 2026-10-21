// PrimerExportStreamCapture.swift - Runs the two primer export leaves in process on small saved analyses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// The runs of `primers analysis export-order` and `export-selection` (Phase 2.13 lane 13.43 M3) whose `--format json`
/// standard output is checked in under `Tests/Fixtures/cli-events/commands/<leaf>`. They need no tool.
/// `CLIEventTranscriptCoverageTests` runs them through `ImportStreamCapture`, which gives each run a scratch folder of its
/// own and rewrites it to `/work`.
enum PrimerExportStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            // The Inspector's order export of one Primer3 candidate pair, named and requested by a person.
            ImportStreamCapture.Case(leaf: "primers analysis export-order", name: "complete") { scratch in
                let bundle = try PrimerAnalysisExportFixtures.primer3(in: scratch.root, pairCount: 2)
                let command = try PrimerAnalysisExportOrderCommand.parse([
                    bundle.path, "--scope", "candidate-pairs", "--name", "Pair order", "--requested-by", "Bench",
                    "--output", scratch.root.appendingPathComponent("order").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
            // The saved analysis view's Save Primer FASTA Bundle of numbered pool 1.
            ImportStreamCapture.Case(leaf: "primers analysis export-selection", name: "complete") { scratch in
                let bundle = try PrimerAnalysisExportFixtures.primalScheme(in: scratch.root)
                let target = try XCTUnwrap(try PrimerAnalysisViewerSnapshot.load(from: bundle).designReview.first)
                let command = try PrimerAnalysisExportSelectionCommand.parse([
                    bundle.path, "--kind", "primer-fasta", "--source-result-id", target.sourceResultID, "--pool", "1",
                    "--output", scratch.root.appendingPathComponent("pool.lungfishref").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
