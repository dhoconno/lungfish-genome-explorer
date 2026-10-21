// BundleExportGraphicStreamCapture.swift - Runs bundle export-graphic in process on a small reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
@testable import LungfishCLI

/// The run of `bundle export-graphic` (Phase 2.13 lane 13.30) whose `--format json` standard output is checked in
/// under `Tests/Fixtures/cli-events/commands/bundle-export-graphic`. The command needs no tool and no window server.
/// `CLIEventTranscriptCoverageTests` runs it through `ImportStreamCapture`, which gives each run a scratch folder of
/// its own and rewrites it to `/work`. The bundle is `BundleExportGraphicCommandTests`', 3,000 bases of `chr1` with
/// two annotation tracks, a variant track and a signal track.
enum BundleExportGraphicStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            // The app's File > Export > Image of a 200-base region, the sequence and the genes drawn as a PNG at 1x.
            ImportStreamCapture.Case(leaf: "bundle export-graphic", name: "complete") { scratch in
                let bundle = try BundleExportGraphicCommandTests.makeBundle(in: scratch.root)
                let command = try BundleExportGraphicSubcommand.parse([
                    bundle.path, "--region", "chr1:1101-1300", "--track", "sequence", "--track", "genes",
                    "--output-format", "png", "--scale", "1",
                    "-o", scratch.root.appendingPathComponent("fixture.png").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }
}
