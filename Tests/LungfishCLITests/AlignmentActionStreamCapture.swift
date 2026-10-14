// AlignmentActionStreamCapture.swift - Runs the alignment action leaves in process on small fixtures
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

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
        ] + inspectorWorkflowCases()
    }

    // MARK: - The Inspector's derived-track and duplicate workflows (Phase 2.10 lane A54)
    //
    // Each of these four leaves calls a Workflow service that runs samtools. The transcripts run the
    // leaf's own event code around a stand-in for that service, which reports the stages the service
    // reports, so the unit tier needs no tool.

    private static let json = ResolvedTextAndJSONGlobalOptions(outputFormat: .json, quiet: false)

    private static func inspectorWorkflowCases() -> [ImportStreamCapture.Case] {
        [
            ImportStreamCapture.Case(leaf: "bam filter", name: "complete") { scratch in
                try await filter(in: scratch, failing: nil)
            },
            // A track the bundle does not hold is refused before anything changes, with exit 3.
            ImportStreamCapture.Case(leaf: "bam filter", name: "failed") { scratch in
                try await filter(in: scratch, failing: BundleAlignmentFilterServiceError.sourceTrackNotFound("aln-missing"))
            },
            ImportStreamCapture.Case(leaf: "bam annotate", name: "complete") { scratch in
                try await annotate(in: scratch, failing: nil)
            },
            ImportStreamCapture.Case(leaf: "bam annotate", name: "failed") { scratch in
                try await annotate(in: scratch, failing: MappedReadsAnnotationServiceError.outputTrackExists("Mapped Reads"))
            },
            ImportStreamCapture.Case(leaf: "bundle mark-duplicates", name: "complete") { scratch in
                try await markDuplicates(in: scratch, failing: nil)
            },
            ImportStreamCapture.Case(leaf: "bundle mark-duplicates", name: "failed") { scratch in
                try await markDuplicates(in: scratch, failing: AlignmentDuplicateError.allTracksAlreadyMarked)
            },
            ImportStreamCapture.Case(leaf: "bundle deduplicate-alignments", name: "complete") { scratch in
                try await deduplicate(in: scratch, failing: nil)
            },
        ]
    }

    private static func filter(in scratch: ImportStreamCapture.Scratch, failing error: (any Error)?) async throws -> ImportStreamCapture.Output {
        let bundle = scratch.root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        let command = try BAMCommand.FilterSubcommand.parse([
            "--bundle", bundle.path, "--alignment-track", "aln-source",
            "--output-track-name", "Mapped Primary", "--mapped-only", "--primary-only", "--format", "json",
        ])
        let runtime = BAMCommand.FilterSubcommand.Runtime(runFilter: { _, _, name, _, _, progress in
            if let error { throw error }
            let stages = [
                (0.05, "Checking required SAM tags..."), (0.55, "Filtering alignments..."),
                (0.72, "Sorting filtered BAM..."), (0.84, "Indexing filtered BAM..."),
                (0.9, "Attaching filtered BAM..."), (1.0, "Filtered alignment attached."),
            ]
            for (fraction, message) in stages { progress(fraction, message) }
            return BundleAlignmentFilterResult(
                bundleURL: bundle,
                mappingResultURL: nil,
                trackInfo: AlignmentTrackInfo(
                    id: "aln_1a2b3c4d", name: name, format: .bam,
                    sourcePath: "alignments/filtered/aln_1a2b3c4d.bam",
                    indexPath: "alignments/filtered/aln_1a2b3c4d.bam.bai",
                    metadataDBPath: "alignments/filtered/aln_1a2b3c4d.stats.db"
                ),
                commandHistory: []
            )
        })
        return try await ImportStreamCapture.capture(in: scratch) {
            _ = try await command.executeForTesting(runtime: runtime, resolvedGlobalOptions: json, emit: printEventLine)
        }
    }

    private static func annotate(in scratch: ImportStreamCapture.Scratch, failing error: (any Error)?) async throws -> ImportStreamCapture.Output {
        let bundle = scratch.root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        let command = try BAMCommand.AnnotateSubcommand.parse([
            "--bundle", bundle.path, "--alignment-track", "aln-source",
            "--output-track-name", "Mapped Reads", "--primary-only", "--format", "json",
        ])
        let runtime = BAMCommand.AnnotateSubcommand.Runtime(runAnnotate: { request, progress in
            if let error { throw error }
            let stages = [
                (0.02, "Opening bundle..."), (0.1, "Reading mapped alignments..."),
                (0.35, "Converting reads to annotations..."), (0.78, "Writing annotation database..."),
                (0.92, "Updating bundle manifest..."), (1.0, "Mapped reads annotation track created."),
            ]
            for (fraction, message) in stages { progress(fraction, message) }
            return MappedReadsAnnotationResult(
                bundleURL: bundle,
                sourceAlignmentTrackID: request.sourceTrackID,
                sourceAlignmentTrackName: "Sample BAM",
                annotationTrackInfo: AnnotationTrackInfo(
                    id: "ann_1a2b3c4d", name: request.outputTrackName,
                    path: "annotations/ann_1a2b3c4d.db", databasePath: "annotations/ann_1a2b3c4d.db",
                    annotationType: .custom, featureCount: 2
                ),
                databasePath: "annotations/ann_1a2b3c4d.db",
                convertedRecordCount: 2,
                skippedUnmappedCount: 1,
                skippedSecondarySupplementaryCount: 1,
                includedSequence: false,
                includedQualities: false
            )
        })
        return try await ImportStreamCapture.capture(in: scratch) {
            _ = try await command.executeForTesting(runtime: runtime, resolvedGlobalOptions: json, emit: printEventLine)
        }
    }

    private static func markDuplicates(in scratch: ImportStreamCapture.Scratch, failing error: (any Error)?) async throws -> ImportStreamCapture.Output {
        let bundle = scratch.root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        let command = try BundleMarkDuplicatesSubcommand.parse([bundle.path, "--format", "json"])
        return try await ImportStreamCapture.capture(in: scratch) {
            try await command.execute(eventsOn: true, quiet: false, emit: printEventLine) { progress in
                if let error { throw error }
                progress(0.0, "Preparing Sample BAM...")
                progress(0.5, "Sample BAM: marking duplicates...")
                progress(1.0, "Duplicate marking complete.")
                return AlignmentDuplicateService.WorkflowResult(
                    bundleURL: bundle, processedTracks: 1, newTrackIds: ["aln_1a2b3c4d"], retainedTrackIds: ["aln-source"]
                )
            }
        }
    }

    private static func deduplicate(in scratch: ImportStreamCapture.Scratch, failing error: (any Error)?) async throws -> ImportStreamCapture.Output {
        let bundle = scratch.root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        let copy = scratch.root.appendingPathComponent("Sample-deduplicated.lungfishref", isDirectory: true)
        let command = try BundleDeduplicateAlignmentsSubcommand.parse([bundle.path, "--format", "json"])
        return try await ImportStreamCapture.capture(in: scratch) {
            try await command.execute(eventsOn: true, quiet: false, emit: printEventLine) { progress in
                if let error { throw error }
                progress(0.08, "Created deduplicated bundle copy.")
                progress(0.54, "Sample BAM: removing duplicates...")
                progress(1.0, "Deduplicated bundle ready.")
                return AlignmentDuplicateService.WorkflowResult(
                    bundleURL: copy, processedTracks: 1, newTrackIds: ["aln_1a2b3c4d"]
                )
            }
        }
    }

    private static func removeTrack(_ trackID: String, in scratch: ImportStreamCapture.Scratch) async throws -> ImportStreamCapture.Output {
        let fixture = try DerivedAlignmentTrackFixture.make(in: scratch.root)
        let command = try BAMCommand.RemoveTrackSubcommand.parse([
            "--bundle", fixture.bundleURL.path, "--track", trackID, "--format", "json",
        ])
        return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
    }
}
