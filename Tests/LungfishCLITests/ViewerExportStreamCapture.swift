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
            // The app's Kraken2 Export of a database, samples A and B with the `Group` metadata column.
            ImportStreamCapture.Case(leaf: "kraken2 export table", name: "complete") { scratch in
                let result = scratch.root.appendingPathComponent("kraken2-batch", isDirectory: true)
                let metadata = result.appendingPathComponent("metadata", isDirectory: true)
                try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
                var rows: [Kraken2ClassificationRow] = []
                for (sample, name, reads) in [("sample-A", "Virus A", 40), ("sample-B", "Virus B", 20)] {
                    rows.append(Kraken2ClassificationRow(
                        sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                        readsDirect: 0, readsClade: reads, percentage: 100, parentTaxId: nil, depth: 0
                    ))
                    rows.append(Kraken2ClassificationRow(
                        sample: sample, taxonName: name, taxId: reads, rank: "S", rankDisplayName: "Species",
                        readsDirect: reads, readsClade: reads, percentage: 100, parentTaxId: 1, depth: 1
                    ))
                }
                try Kraken2Database.create(
                    at: result.appendingPathComponent(Kraken2TaxonomyTableExport.databaseFileName),
                    rows: rows,
                    metadata: ["total_reads_sample-A": "40", "total_reads_sample-B": "20"]
                )
                try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
                    .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
                let command = try Kraken2Command.ExportTableSubcommand.parse([
                    result.path, "--sample", "sample-A", "--sample", "sample-B", "--metadata-column", "Group",
                    "--output-format", "tsv", "--output", scratch.root.appendingPathComponent("taxonomy.tsv").path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
            // The app's BLAST drawer Export of a saved search, one read with a hit and one with none.
            ImportStreamCapture.Case(leaf: "blast export table", name: "complete") { scratch in
                let result = BlastVerificationResult(
                    taxonName: "Escherichia coli",
                    taxId: 562,
                    readResults: [
                        BlastReadResult(
                            id: "read_1", verdict: .verified, topHitOrganism: "Escherichia coli",
                            topHitAccession: "NC_000001.1", percentIdentity: 99.0, eValue: 0.0, matchesQueriedTaxon: true
                        ),
                        BlastReadResult(id: "read_2", verdict: .unverified),
                    ],
                    submittedAt: Date(timeIntervalSince1970: 1_790_000_000),
                    completedAt: Date(timeIntervalSince1970: 1_790_000_060),
                    rid: "RID-1",
                    blastProgram: "megablast",
                    database: "core_nt"
                )
                let archive = try BlastVerificationArchive.save(result, request: nil, in: scratch.root, toolName: "lungfish-cli", toolKind: "cli")
                let command = try BlastCommand.ExportTableSubcommand.parse([
                    archive.path, "--output-format", "tsv",
                    "--output", scratch.root.appendingPathComponent("blast.tsv").path,
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
            // The app's manual haplotype definitions Export, one assignment from the selection file (lane 12.35).
            ImportStreamCapture.Case(leaf: "genotype export-manual-definitions", name: "complete") { scratch in
                let bundle = scratch.root.appendingPathComponent("manual.lungfishgenotype", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                let output = scratch.root.appendingPathComponent("manual-haplotype-definitions.json")
                let selection = try GenotypeManualDefinitionsExport.selection(assignments: [
                    ManualHaplotypeAssignment(sample: "animal-1", locus: "MHC-A", slot: .h1, label: "Mamu-A1*001",
                                              colorTokenIndex: 1, diagnosticAlleles: ["A1_001"], notes: ""),
                ]).write(besideOutput: output)
                let command = try GenotypeExportManualDefinitionsSubcommand.parse([
                    bundle.path, "--selection", selection.path, "--output", output.path, "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
            // The app's TaxTriage Export Organism Matrix, both samples (lane 12.32).
            ImportStreamCapture.Case(leaf: "taxtriage export organism-matrix", name: "complete") { scratch in
                let result = try taxTriageResult(in: scratch.root)
                let command = try TaxTriageCommand.ExportOrganismMatrixSubcommand.parse([
                    result.path, "--sample", "sample-1", "--sample", "sample-2",
                    "--output", scratch.root.appendingPathComponent("organism_matrix.csv").path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
            // The app's TaxTriage Export Batch Report, both samples (lane 12.32).
            ImportStreamCapture.Case(leaf: "taxtriage export batch-report", name: "complete") { scratch in
                let result = try taxTriageResult(in: scratch.root)
                let command = try TaxTriageCommand.ExportBatchReportSubcommand.parse([
                    result.path, "--sample", "sample-1", "--sample", "sample-2",
                    "--output", scratch.root.appendingPathComponent("batch_report.txt").path,
                    "--format", "json",
                ])
                return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            },
            // The app's TaxTriage Export Results, both samples sorted by reads (lane 12.32).
            ImportStreamCapture.Case(leaf: "taxtriage export results", name: "complete") { scratch in
                let result = try taxTriageResult(in: scratch.root)
                let command = try TaxTriageCommand.ExportResultsSubcommand.parse([
                    result.path, "--sample", "sample-1", "--sample", "sample-2",
                    "--sort", "tt_reads:descending", "--output-format", "tsv",
                    "--output", scratch.root.appendingPathComponent("results.tsv").path,
                    "--format", "json",
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

    /// A TaxTriage result folder with a database of two samples, the second a negative control, and the run's sidecar.
    private static func taxTriageResult(in root: URL) throws -> URL {
        let result = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        _ = try TaxTriageDatabase.create(
            at: result.appendingPathComponent(TaxTriageExportLoader.databaseFileName),
            rows: [
                taxTriageRow("sample-1", "Alpha virus", 1001, 0.91, 42, "High"),
                taxTriageRow("sample-1", "Beta virus", 1002, 0.76, 24, "High"),
                taxTriageRow("sample-2", "Gamma virus", 2001, 0.50, 12, "Medium"),
                taxTriageRow("sample-2", "Alpha virus", 1001, 0.20, 3, "Low"),
            ],
            metadata: ["tool": "taxtriage"]
        )
        let config = TaxTriageConfig(
            samples: ["sample-1", "sample-2"].map {
                TaxTriageSample(
                    sampleId: $0,
                    fastq1: result.appendingPathComponent("\($0).fastq.gz"),
                    isNegativeControl: $0 == "sample-2"
                )
            },
            outputDirectory: result
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TaxTriageResult(config: config, runtime: 61, exitCode: 0, outputDirectory: result))
            .write(to: result.appendingPathComponent(TaxTriageExportLoader.sidecarFileName))
        return result
    }

    private static func taxTriageRow(
        _ sample: String, _ organism: String, _ taxId: Int, _ tass: Double, _ reads: Int, _ confidence: String
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: organism, taxId: taxId, status: nil, tassScore: tass,
            readsAligned: reads, uniqueReads: reads / 2, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: 50, meanCoverage: nil, meanDepth: nil, confidence: confidence,
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil, bamPath: nil,
            bamIndexPath: nil, primaryAccession: "NC_\(taxId)", accessionLength: 1000
        )
    }
}
