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
            // The app's NAO-MGS Export, samples A and B with the `Cohort` metadata column.
            ImportStreamCapture.Case(leaf: "nao-mgs export table", name: "complete") { scratch in
                let result = try naoMgsResult(in: scratch.root)
                let command = try NaoMgsCommand.ExportTableSubcommand.parse([
                    result.path, "--sample", "sample-A", "--sample", "sample-B", "--metadata-column", "Cohort",
                    "--output", scratch.root.appendingPathComponent("summary.tsv").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
            // The app's NVD Export, samples 1 and 2 with the `Cohort` metadata column.
            ImportStreamCapture.Case(leaf: "nvd export contigs", name: "complete") { scratch in
                let result = try nvdResult(in: scratch.root)
                let command = try NvdCommand.ExportContigsSubcommand.parse([
                    result.path, "--sample", "sample1", "--sample", "sample2", "--metadata-column", "Cohort",
                    "--output", scratch.root.appendingPathComponent("contigs.tsv").path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
        ]
    }

    /// A NAO-MGS result folder with a database of two samples, its manifest and a sample metadata table.
    private static func naoMgsResult(in root: URL) throws -> URL {
        let result = root.appendingPathComponent("naomgs-result", isDirectory: true)
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(NaoMgsManifest(
            sampleName: "naomgs-capture", sourceFilePath: root.appendingPathComponent("virus_hits.tsv").path,
            hitCount: 3, taxonCount: 2, topTaxon: "Taxon 1", topTaxonId: 1
        )).write(to: result.appendingPathComponent(NaoMgsSummaryExport.manifestFileName))
        try NaoMgsDatabase.create(
            at: result.appendingPathComponent(NaoMgsSummaryExport.databaseFileName),
            hits: [
                naoMgsHit(sample: "sample-A", taxId: 1, read: 0), naoMgsHit(sample: "sample-A", taxId: 1, read: 1),
                naoMgsHit(sample: "sample-B", taxId: 2, read: 0),
            ]
        )
        try Data("Sample\tCohort\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        return result
    }

    private static func naoMgsHit(sample: String, taxId: Int, read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: "\(sample)-\(taxId)-\(read)", taxId: taxId,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100, refStart: read * 100,
            refEnd: read * 100 + 100, readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100), subjectSeqId: "NC_\(taxId)", subjectTitle: "Taxon \(taxId)",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }

    /// An NVD result folder with a database of two samples, its manifest and a sample metadata table.
    private static func nvdResult(in root: URL) throws -> URL {
        let result = root.appendingPathComponent("nvd-result", isDirectory: true)
        let metadata = result.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let samples = ["sample1", "sample2"]
        try NvdDatabase.create(
            at: result.appendingPathComponent(NvdContigsExport.databaseFileName),
            hits: [nvdHit(sample: "sample1", reads: 30), nvdHit(sample: "sample2", reads: 20)],
            samples: samples.map {
                NvdSampleMetadata(
                    sampleId: $0, bamPath: "\($0).bam", fastaPath: "\($0).fasta",
                    totalReads: 1000, contigCount: 1, hitCount: 1
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(NvdManifest(
            experiment: "exp-capture", sampleCount: 2, contigCount: 2, hitCount: 2, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: root.appendingPathComponent("nvd-run").path,
            samples: samples.map {
                NvdSampleSummary(
                    sampleId: $0, contigCount: 1, hitCount: 1, totalReads: 1000,
                    bamRelativePath: "\($0).bam", fastaRelativePath: "\($0).fasta"
                )
            },
            cachedTopContigs: nil
        )).write(to: result.appendingPathComponent(NvdContigsExport.manifestFileName))
        try Data("Sample\tCohort\nsample1\tcase\nsample2\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        return result
    }

    private static func nvdHit(sample: String, reads: Int) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-capture", blastTask: "blastn", sampleId: sample, qseqid: "contig_1", qlen: 8,
            sseqid: "NC_\(sample)", stitle: "Alpha virus", taxRank: "species", length: 8, pident: 100, evalue: 0,
            bitscore: 50, sscinames: "Alpha virus", staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: reads, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: "1234",
            adjustmentMethod: "dominant", adjustedTaxidName: "Alpha virus", adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(reads) * 1_000_000
        )
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
