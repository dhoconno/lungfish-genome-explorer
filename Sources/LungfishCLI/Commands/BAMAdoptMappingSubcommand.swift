// BAMAdoptMappingSubcommand.swift - Attach a fresh `lungfish map` mapping result
// to a reference bundle as a new alignment track.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension BAMCommand {
    struct AdoptMappingSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "adopt-mapping",
            abstract: "Attach a `lungfish map` result to a reference bundle as a new alignment track"
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory (.lungfishref)")
        var bundlePath: String

        @Option(name: .customLong("mapping-result"), help: "Path to the mapping analysis directory produced by `lungfish map`")
        var mappingResultPath: String

        @Option(name: .customLong("name"), help: "Display name for the new alignment track")
        var trackName: String

        @Option(name: .customLong("track-id"), help: "Override the auto-generated alignment track identifier")
        var trackIDOverride: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let mappingURL = URL(fileURLWithPath: mappingResultPath)
            let bamURL = mappingURL.appendingPathComponent("sorted.bam")
            let baiURL = mappingURL.appendingPathComponent("sorted.bam.bai")
            guard FileManager.default.fileExists(atPath: bamURL.path) else {
                throw ValidationError("Mapping result is missing sorted.bam at \(bamURL.path)")
            }
            guard FileManager.default.fileExists(atPath: baiURL.path) else {
                throw ValidationError("Mapping result is missing sorted.bam.bai at \(baiURL.path)")
            }
            let outputTrackID = trackIDOverride ?? "aln_\(UUID().uuidString.prefix(8))"
            let request = PreparedAlignmentAttachmentRequest(
                bundleURL: bundleURL,
                stagedBAMURL: bamURL,
                stagedIndexURL: baiURL,
                outputTrackID: String(outputTrackID),
                outputTrackName: trackName,
                relativeDirectory: "alignments/mapped",
                format: .bam
            )
            _ = try await PreparedAlignmentAttachmentService().attach(request: request)
            if !globalOptions.quiet {
                print("Attached alignment track '\(trackName)' (\(outputTrackID)) to bundle.")
            }
        }
    }
}
