// ViewerExportStreamCapture.swift - Runs the viewer export leaves in process on small result folders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

/// The runs of the viewer export leaves (Phase 2.12 lane 12.31) whose `--format json` standard output is checked in
/// under `Tests/Fixtures/cli-events/commands/<leaf>`. They need no tool. `CLIEventTranscriptCoverageTests` runs them
/// through `ImportStreamCapture`, which gives each run a scratch folder of its own and rewrites it to `/work`.
enum ViewerExportStreamCapture {
    static func cases() -> [ImportStreamCapture.Case] {
        [
            // The app's EsViritu Export, both samples with the `Group` metadata column.
            ImportStreamCapture.Case(leaf: "esviritu export detections", name: "complete") { scratch in
                let result = try esVirituResult(in: scratch.root)
                let command = try EsVirituCommand.ExportDetectionsSubcommand.parse([
                    result.path, "--sample", "sample-A", "--sample", "sample-B", "--metadata-column", "Group",
                    "--output-format", "tsv", "--output", scratch.root.appendingPathComponent("detections.tsv").path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }

    /// An EsViritu result folder with a database of two samples and a sample metadata table.
    private static func esVirituResult(in root: URL) throws -> URL {
        let result = root.appendingPathComponent("esviritu-batch", isDirectory: true)
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try EsVirituDatabase.create(
            at: result.appendingPathComponent(EsVirituDetectionExport.databaseFileName),
            rows: [esVirituRow(sample: "sample-A", accession: "NC_A", reads: 40), esVirituRow(sample: "sample-B", accession: "NC_B", reads: 20)],
            metadata: ["tool": "test"]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        return result
    }

    private static func esVirituRow(sample: String, accession: String, reads: Int) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: "Virus \(accession)", description: nil, contigLength: 100, segment: nil,
            accession: accession, assembly: "GCF_\(accession)", assemblyLength: 100, kingdom: "Viruses",
            phylum: nil, tclass: nil, torder: nil, family: "Testviridae", genus: nil, species: nil, subspecies: nil,
            rpkmf: 1, readCount: reads, uniqueReads: reads, coveredBases: 90, meanCoverage: 2,
            avgReadIdentity: 99, pi: 0, filteredReadsInSample: 1_000, bamPath: nil, bamIndexPath: nil
        )
    }
}
