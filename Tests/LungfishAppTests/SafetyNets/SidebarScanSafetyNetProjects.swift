// SidebarScanSafetyNetProjects.swift - Fixture projects for the sidebar-scan safety net
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Five projects, each written under a scratch root. Four come from committed
// inputs, namely the alignment fixture project, the analyses seeds, the
// reference bundles with the SARS-CoV-2 files, and the practice data the
// demo-project builder copies into its demo projects. The fifth is synthetic and lays out
// every analysis naming pattern the scanner still recognises, including the
// legacy names, so a registry that replaces the name tables must keep them.
//
// Every date the scanner shows is pinned. Names that carry a timestamp round
// trip in any time zone. Dates read from analysis metadata or from a folder's
// creation date are written from the same local timestamp string, so they
// format back to it in the time zone the test runs in.

import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

struct SidebarScanFixtureProject: Sendable {
    /// The snapshot file stem under Tests/Fixtures/sidebar-scan.
    let name: String
    /// One line written at the top of the snapshot.
    let summary: String
    /// Writes the project under a scratch root and returns the project folder.
    let build: @Sendable (URL) async throws -> URL
}

enum SidebarScanSafetyNetProjects {
    static let all: [SidebarScanFixtureProject] = [
        alignmentProject,
        analysesSeedProject,
        referenceDataProject,
        demoPracticeDataProject,
        analysisNamingProject,
    ]

    /// A local `yyyy-MM-dd'T'HH-mm-ss` time, the form analysis folder names use.
    static func pinnedDate(_ timestamp: String) throws -> Date {
        guard let date = AnalysesFolder.parseTimestamp(timestamp) else {
            throw PinnedDateError(timestamp: timestamp)
        }
        return date
    }

    struct PinnedDateError: Error, CustomStringConvertible {
        let timestamp: String
        var description: String { "Not an analysis timestamp: \(timestamp)" }
    }

    /// Pins a folder's creation date, which the scanner shows for imported
    /// result names and for folders recognised only by their contents.
    static func pinCreationDate(of url: URL, to timestamp: String) throws {
        try FileManager.default.setAttributes(
            [.creationDate: try pinnedDate(timestamp)],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Committed projects

    /// The committed SARS-CoV-2 MAFFT alignment project.
    ///
    /// The project predates the move of alignments into `Analyses/`. Its
    /// MAFFT bundle carries `analysis-metadata.json`, and the scanner hides a
    /// regular-folder directory with that sidecar, so the snapshot shows the
    /// Multiple Sequence Alignments folder with no rows.
    static let alignmentProject = SidebarScanFixtureProject(
        name: "alignment-project",
        summary: "The committed project Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish."
    ) { root in
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("alignment/sarscov2-mafft-e2e.lungfish"), into: root)
    }

    /// The committed analysis seeds under a project's Analyses folder.
    static let analysesSeedProject = SidebarScanFixtureProject(
        name: "analyses-seeds",
        summary: "The committed seeds in Tests/Fixtures/analyses placed in a project Analyses folder."
    ) { root in
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Analyses Seeds.lungfish", isDirectory: true))
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("analyses"), to: project.appendingPathComponent("Analyses", isDirectory: true))
        return project
    }

    /// TestData reference bundles, the committed primer schemes and the
    /// committed SARS-CoV-2 files in every format the fixture set holds.
    static let referenceDataProject = SidebarScanFixtureProject(
        name: "reference-data",
        summary: "The TestData reference bundles, the committed primer schemes and the SARS-CoV-2 fixture files."
    ) { root in
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Reference Data.lungfish", isDirectory: true))
        let references = project.appendingPathComponent("Reference Sequences", isDirectory: true)
        try SafetyNetFiles.copy(SafetyNetPaths.testData("TestGenome.lungfishref"), into: references)
        try SafetyNetFiles.copy(SafetyNetPaths.testData("HepatitisB.lungfishref"), into: references)
        let schemes = project.appendingPathComponent(PrimerSchemesFolder.folderName, isDirectory: true)
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("primerschemes/QIASeqDIRECT-SARS2.lungfishprimers"), into: schemes)
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("primerschemes/mt192765-integration.lungfishprimers"), into: schemes)
        let inputs = project.appendingPathComponent("Inputs", isDirectory: true)
        for name in [
            "genome.fasta", "genome.fasta.fai", "genome.gff3", "genome.gtf", "test.bed",
            "test.paired_end.sorted.bam", "test.paired_end.sorted.bam.bai",
            "test.paired_end.sorted.markers.bam", "test.paired_end.sorted.markers.bam.bai",
            "test.vcf", "test.vcf.gz", "test.vcf.gz.tbi", "test_1.fastq.gz", "test_2.fastq.gz",
        ] {
            try SafetyNetFiles.copy(RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent(name), into: inputs)
        }
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("phylogenetics/known-sarcopterygian/expected.nwk"), into: inputs, as: "sarcopterygian.nwk")
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("czid/minimal_taxon_report.tsv"), into: inputs)
        return project
    }

    /// The practice data the demo-project builder copies into the Genes and
    /// Sequences, Pathogen Detection and 12S Metabarcoding projects, beside the
    /// haplotype definition and reference allele database layout of the MHC
    /// Genotyping project. Imported reads are left out, because only
    /// `lungfish-cli` can make them.
    static let demoPracticeDataProject = SidebarScanFixtureProject(
        name: "demo-practice-data",
        summary: "The practice data of the Genes and Sequences, Pathogen Detection, 12S and MHC demo projects."
    ) { root in
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Demo Practice Data.lungfish", isDirectory: true))
        try SafetyNetFiles.write(#"{"name":"Demo Practice Data"}"#, to: project.appendingPathComponent("metadata.json"))
        let practice = project.appendingPathComponent("Practice Data", isDirectory: true)
        let manualInputs = [
            "hbb-gene/NG_000007.3.gb",
            "primate-mito/primate-mito.fasta",
            "human-mito/NC_012920.1.fasta",
            "nvd-demo/results/05_labkey_bundling/demo_blast_concatenated.csv",
            "nvd-demo/results/02_human_viruses/03_human_virus_results/SampleA.human_virus.fasta",
            "nvd-demo/results/02_human_viruses/03_human_virus_results/SampleB.human_virus.fasta",
            "nvd-demo/results/02_human_viruses/03_human_virus_results/SampleC.human_virus.fasta",
            "primate-12s/primate-12s-dedup.fasta",
            "primate-12s/primate-12s-midori.tsv",
            "primate-12s/SIMULATED-12S-mixture.fastq.gz",
            "primate-12s/SIMULATED-12S-mixture.truth.tsv",
            "primate-12s/SIMULATED-12S-mixture.amplicons.fasta",
        ]
        for path in manualInputs {
            try SafetyNetFiles.copy(SafetyNetPaths.manualFixture(path), to: practice.appendingPathComponent(path))
        }
        for path in ["naomgs/virus_hits_final.tsv.gz", "czid/minimal_taxon_report.tsv"] {
            try SafetyNetFiles.copy(SafetyNetPaths.fixture(path), to: practice.appendingPathComponent(path))
        }
        try SafetyNetFiles.copy(
            SafetyNetPaths.manualFixture("mhc-simulated/mhc-simulated-mcm-teaching.lungfishhaplotypedef.json"),
            into: project.appendingPathComponent("Haplotype Definitions", isDirectory: true)
        )
        _ = try RoutingSafetyNetFixtures.mhcReferenceBundle(
            in: project.appendingPathComponent("Reference allele databases", isDirectory: true)
        )
        return project
    }

    // MARK: - Analysis naming patterns

    /// Every analysis folder name the scanner recognises, and the folders it
    /// must hide, in one synthetic project.
    static let analysisNamingProject = SidebarScanFixtureProject(
        name: "analysis-naming",
        summary: "Every analysis naming pattern, content probe and hidden folder the scanner handles."
    ) { root in
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Analysis Naming.lungfish", isDirectory: true))
        let analyses = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        try writeKnownToolFolders(in: analyses)
        try await writeImportedAndProbedFolders(in: analyses)
        try writeGroupingAndHiddenFolders(in: analyses, project: project)
        try await writeRegularFolderEdges(in: project)
        return project
    }

    /// `{tool}-{timestamp}` and `{tool}-batch-{timestamp}` for every known tool.
    ///
    /// Batch folders hold one sample, the least a batch needs to be listed.
    /// Classifier batches hold the result sidecar their sample count reads.
    static func writeKnownToolFolders(in analyses: URL) throws {
        // A literal list, not AnalysesFolder.knownTools, so a registry change alters the
        // code under test and not its input. These are the 21 ids in today's sorted order.
        let tools = [
            "bbmap", "bowtie2", "bwa-mem2", "cz-id", "esviritu", "flye", "hifiasm", "kraken2",
            "mafft", "megahit", "minimap2", "naomgs", "nvd", "ont-genotyping", "pbaa",
            "primer-order", "savont", "skesa", "spades", "taxtriage", "viralrecon",
        ]
        for tool in tools {
            try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent("\(tool)-2026-01-15T10-00-00", isDirectory: true))
            let batch = try SafetyNetFiles.makeDirectory(
                analyses.appendingPathComponent("\(tool)-batch-2026-01-15T11-00-00", isDirectory: true)
            )
            let sample = try SafetyNetFiles.makeDirectory(batch.appendingPathComponent("HG002", isDirectory: true))
            switch tool {
            case "kraken2":
                try SafetyNetFiles.write("{}", to: sample.appendingPathComponent("classification-result.json"))
            case "esviritu":
                try SafetyNetFiles.write("{}", to: sample.appendingPathComponent("esviritu-result.json"))
            default:
                break
            }
        }
    }

    /// Imported result names, folders recognised only by their contents, a
    /// renamed folder that keeps its metadata, and the legacy Kraken2 name.
    static func writeImportedAndProbedFolders(in analyses: URL) async throws {
        for tool in ["naomgs", "nvd", "cz-id"] {
            let folder = try SafetyNetFiles.makeDirectory(
                analyses.appendingPathComponent("\(tool)-MMU-17 import", isDirectory: true)
            )
            try pinCreationDate(of: folder, to: "2026-01-15T12-00-00")
        }

        let probes: [(name: String, write: (URL) async throws -> Void)] = [
            ("Probe CZ ID", { folder in
                _ = try CzIdDataConverter.convertTaxonReport(
                    at: SafetyNetPaths.fixture("czid/minimal_taxon_report.tsv"),
                    outputDirectory: folder
                )
            }),
            ("Probe Kraken2", { folder in
                try SafetyNetFiles.write(#"{"config":{"databaseName":"Standard-8"}}"#, to: folder.appendingPathComponent("classification-result.json"))
            }),
            ("Probe Viral Recon", { folder in
                try SafetyNetFiles.write("{}", to: folder.appendingPathComponent("viralrecon-result.json"))
            }),
            ("Probe MEGAHIT", { folder in
                try SafetyNetFiles.write(#"{"tool":"megahit"}"#, to: folder.appendingPathComponent("assembly-result.json"))
            }),
            ("Probe SPAdes schema 1", { folder in
                try SafetyNetFiles.write(#"{"schemaVersion":1}"#, to: folder.appendingPathComponent("assembly-result.json"))
            }),
            ("Probe SPAdes keys", { folder in
                try SafetyNetFiles.write(#"{"spadesVersion":"4.0.0"}"#, to: folder.appendingPathComponent("assembly-result.json"))
            }),
            ("Probe Bowtie2", { folder in
                try SafetyNetFiles.write(#"{"mapper":"bowtie2"}"#, to: folder.appendingPathComponent("mapping-result.json"))
            }),
            ("Probe MAFFT", { folder in
                try SafetyNetFiles.write(#"{"bundleKind":"multiple-sequence-alignment"}"#, to: folder.appendingPathComponent("manifest.json"))
                try SafetyNetFiles.write(">a\nACGT\n", to: folder.appendingPathComponent("alignment/primary.aligned.fasta"))
            }),
            ("Probe NVD", { folder in
                try SafetyNetFiles.write(#"{"experiment":"100"}"#, to: folder.appendingPathComponent("manifest.json"))
                try SafetyNetFiles.write("", to: folder.appendingPathComponent("hits.sqlite"))
            }),
            ("Probe NAO-MGS", { folder in
                try SafetyNetFiles.write(#"{"taxonCount":3}"#, to: folder.appendingPathComponent("manifest.json"))
                try SafetyNetFiles.write("", to: folder.appendingPathComponent("hits.sqlite"))
            }),
            ("Probe ambiguous manifest", { folder in
                try SafetyNetFiles.write("{}", to: folder.appendingPathComponent("manifest.json"))
                try SafetyNetFiles.write("", to: folder.appendingPathComponent("hits.sqlite"))
            }),
            ("Probe EsViritu", { folder in
                try SafetyNetFiles.write("", to: folder.appendingPathComponent("HG002.detected_virus.info.tsv"))
            }),
            ("Probe TaxTriage", { folder in
                try SafetyNetFiles.write("", to: folder.appendingPathComponent("hits.sqlite"))
            }),
        ]
        for probe in probes {
            let folder = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent(probe.name, isDirectory: true))
            try await probe.write(folder)
            try pinCreationDate(of: folder, to: "2026-01-15T13-00-00")
        }

        let renamed = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent("Renamed Kraken2 run", isDirectory: true))
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "kraken2", isBatch: false, created: try pinnedDate("2026-01-15T14-00-00")),
            to: renamed
        )
        let renamedBatch = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent("Renamed SPAdes batch", isDirectory: true))
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "spades", isBatch: true, created: try pinnedDate("2026-01-15T14-10-00")),
            to: renamedBatch
        )
        try SafetyNetFiles.makeDirectory(renamedBatch.appendingPathComponent("HG002", isDirectory: true))

        // Kraken2 results were once written as classification-<timestamp>.
        // The name is no longer a known tool, so the sidecar identifies it.
        let legacyKraken = try SafetyNetFiles.makeDirectory(
            analyses.appendingPathComponent("classification-2026-01-15T09-00-00", isDirectory: true)
        )
        try SafetyNetFiles.write(#"{"config":{"databaseName":"Viral"}}"#, to: legacyKraken.appendingPathComponent("classification-result.json"))
        try pinCreationDate(of: legacyKraken, to: "2026-01-15T09-00-00")
    }

    /// Grouping folders, loose items, incomplete runs and pipeline internals.
    static func writeGroupingAndHiddenFolders(in analyses: URL, project: URL) throws {
        let group = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent("Run group", isDirectory: true))
        try SafetyNetFiles.makeDirectory(group.appendingPathComponent("spades-2026-01-15T15-00-00", isDirectory: true))
        try SafetyNetFiles.write("kept in the group\n", to: group.appendingPathComponent("Notes/readme.txt"))
        try SafetyNetFiles.makeDirectory(group.appendingPathComponent("Empty", isDirectory: true))
        try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent("Empty group", isDirectory: true))
        try SafetyNetFiles.write("checked\n", to: analyses.appendingPathComponent("Loose notes/checklist.txt"))
        try SafetyNetFiles.write("sample\treads\n", to: analyses.appendingPathComponent("summary.tsv"))
        try SafetyNetFiles.write("[]", to: analyses.appendingPathComponent("analyses-manifest.json"))
        try RoutingSafetyNetFixtures.sarsCoV2ReferenceBundle(named: "MT192765.1", in: analyses, publishTracks: false)

        // A run still writing its result, and one that never finished.
        let processing = try SafetyNetFiles.makeDirectory(
            analyses.appendingPathComponent("spades-2026-01-15T16-00-00", isDirectory: true)
        )
        OperationMarker.markInProgress(processing)
        try AnalysesFolder.createAnalysisDirectory(
            tool: "minimap2",
            in: project,
            date: try pinnedDate("2026-01-15T16-10-00")
        )

        // Viral Recon leaves the raw nf-core tree and a run bundle beside its result.
        try SafetyNetFiles.write("", to: analyses.appendingPathComponent("viralrecon-results-a1b2c3/multiqc/multiqc_report.html"))
        try SafetyNetFiles.write("{}", to: analyses.appendingPathComponent("run-a1b2c3.lungfishrun/run.json"))
    }

    /// Folders outside Analyses. These are hidden result folders, standalone
    /// NAO-MGS and NVD bundles, opaque packages, staging folders and FASTQ
    /// bundles, one demultiplexed and one whose derivatives still hold
    /// results in the layout used before the Analyses folder.
    static func writeRegularFolderEdges(in project: URL) async throws {
        try SafetyNetFiles.write(#"{"name":"Analysis Naming"}"#, to: project.appendingPathComponent("metadata.json"))
        try SafetyNetFiles.write("{}", to: project.appendingPathComponent("provenance/run.json"))
        try SafetyNetFiles.makeDirectory(project.appendingPathComponent(PrimerSchemesFolder.folderName, isDirectory: true))

        let imports = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Imports", isDirectory: true))
        try SafetyNetFiles.write("{}", to: imports.appendingPathComponent("taxtriage-legacy/taxtriage-result.json"))
        try SafetyNetFiles.write("{}", to: imports.appendingPathComponent("classification-legacy/classification-result.json"))
        try SafetyNetFiles.write("{}", to: imports.appendingPathComponent("esviritu-legacy/esviritu-result.json"))
        try SafetyNetFiles.write("{}", to: imports.appendingPathComponent("cz-id-legacy/cz-id-manifest.json"))
        let renamedWithMetadata = try SafetyNetFiles.makeDirectory(imports.appendingPathComponent("Renamed result", isDirectory: true))
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "kraken2", isBatch: false), to: renamedWithMetadata)
        _ = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-wastewater", in: imports)
        _ = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-demo", in: imports)
        try SafetyNetFiles.makeDirectory(imports.appendingPathComponent("cli-output-1a2b", isDirectory: true))
        try SafetyNetFiles.makeDirectory(imports.appendingPathComponent("materialized-inputs-3c4d", isDirectory: true))
        try SafetyNetFiles.write("", to: imports.appendingPathComponent("viralrecon-results-e5f6/log.txt"))
        try SafetyNetFiles.write("{}", to: imports.appendingPathComponent("run-e5f6.lungfishrun/run.json"))
        try SafetyNetFiles.write("kept\n", to: imports.appendingPathComponent("viralrecon notes/plan.txt"))
        _ = try RoutingSafetyNetFixtures.czIdResult(named: "cornea.lungfishtax", in: imports)
        try SafetyNetFiles.write("taxon\treads\n", to: imports.appendingPathComponent("legacy.lungfishtax/report.tsv"))
        try SafetyNetFiles.write("{}", to: imports.appendingPathComponent("workflow.lungfishflow/flow.json"))
        try SafetyNetFiles.write(">human\nACGT\n", to: imports.appendingPathComponent("primate.lungfish12sref/reference.fa"))

        // A pooled run demultiplexed twice, with one batch operation over its
        // barcodes. The operation's output is listed under the batch row, which
        // has no folder of its own.
        let pooled = imports.appendingPathComponent("pooled.lungfishfastq", isDirectory: true)
        let fastqRecord = "@read1\nACGTACGT\n+\nIIIIIIII\n"
        try SafetyNetFiles.write(fastqRecord, to: pooled.appendingPathComponent("pooled.fastq"))
        let demux = pooled.appendingPathComponent("demux", isDirectory: true)
        for path in [
            "demux/barcode01.lungfishfastq/reads.fastq",
            "demux/barcode02.lungfishfastq/reads.fastq",
            "demux/trimmed/barcode01-trimmed.lungfishfastq/reads.fastq",
            "demux-2/barcode01.lungfishfastq/reads.fastq",
        ] {
            try SafetyNetFiles.write(fastqRecord, to: pooled.appendingPathComponent(path))
        }
        try FASTQBatchManifest(operations: [
            BatchOperationRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                label: "Quality trim",
                operationKind: "qualityTrim",
                performedAt: try pinnedDate("2026-01-15T17-00-00"),
                outputBundlePaths: ["trimmed/barcode01-trimmed.lungfishfastq"],
                inputBundlePaths: ["barcode01.lungfishfastq"]
            ),
        ]).save(to: demux)

        let reads = imports.appendingPathComponent("HG002.lungfishfastq", isDirectory: true)
        try SafetyNetFiles.copy(SafetyNetPaths.fixture("assembly-ui/illumina/reads_R1.fastq"), to: reads.appendingPathComponent("HG002.fastq"))
        for prefix in ["classification", "esviritu", "taxtriage", "naomgs", "nvd"] {
            try SafetyNetFiles.write(
                "{}",
                to: reads.appendingPathComponent("derivatives/\(prefix)-2026-01-15T08-00-00/manifest.json")
            )
        }
    }
}
