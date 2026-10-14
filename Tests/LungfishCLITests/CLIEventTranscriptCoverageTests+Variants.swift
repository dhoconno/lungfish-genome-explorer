// CLIEventTranscriptCoverageTests+Variants.swift - The in-process captures of the variant edit leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
@testable import LungfishCLI

/// `variants delete` and `variants import-sample-metadata` run no tool, so their transcripts are
/// captured in process on a bundle of one variant database of three variants and two samples
/// (2.10 A43). They live here because the main file is past 800 lines.
extension CLIEventTranscriptCoverageTests {
    static func variantsCaptures() -> [Capture] {
        [
            Capture(leaf: "variants delete", name: "complete") { scratch in
                let fixture = try VariantEditFixture.make(in: scratch.root, withTrackManifest: true)
                let command = try VariantsCommand.DeleteSubcommand.parse([fixture.bundleURL.path, "--all", "--format", "json"])
                return try await Self.eventLines { try await command.execute(emit: $0) }
            },
            Capture(leaf: "variants import-sample-metadata", name: "complete") { scratch in
                let fixture = try VariantEditFixture.make(in: scratch.root, withTrackManifest: true)
                let metadata = try fixture.writeMetadata()
                let command = try VariantsCommand.ImportSampleMetadataSubcommand.parse([
                    fixture.bundleURL.path, metadata.path, "--format", "json",
                ])
                return try await Self.eventLines { try await command.execute(emit: $0) }
            },
        ]
    }
}
