// AlignmentActionStreamCapture.swift - Runs the alignment action leaves in process on small fixtures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishTestSupport
@testable import LungfishCLI

/// The runs of the L3 alignment action leaves (Phase 2.10 lane A51) whose `--format json` standard
/// output is checked in under `Tests/Fixtures/cli-events/commands/<leaf>`. They need no tool.
/// `CLIEventTranscriptCoverageTests` runs them through `ImportStreamCapture`, which gives each run a
/// scratch folder of its own and rewrites it to `/work`.
enum AlignmentActionStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            // The Inspector's removal of the derived track `bam filter` made.
            ImportStreamCapture.Case(leaf: "bam remove-track", name: "complete") { scratch in
                try await removeTrack(DerivedAlignmentTrackFixture.derivedTrackID, in: scratch)
            },
            // A source alignment is refused before anything changes, with exit 3.
            ImportStreamCapture.Case(leaf: "bam remove-track", name: "failed") { scratch in
                try await removeTrack(DerivedAlignmentTrackFixture.sourceTrackID, in: scratch)
            },
        ]
    }

    private static func removeTrack(_ trackID: String, in scratch: ImportStreamCapture.Scratch) async throws -> ImportStreamCapture.Output {
        let fixture = try DerivedAlignmentTrackFixture.make(in: scratch.root)
        let command = try BAMCommand.RemoveTrackSubcommand.parse([
            "--bundle", fixture.bundleURL.path, "--track", trackID, "--format", "json",
        ])
        return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
    }
}
