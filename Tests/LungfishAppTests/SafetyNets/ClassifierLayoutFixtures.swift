// ClassifierLayoutFixtures.swift - Every classifier result layout LGE writes, as folders for the pins
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A2. The analysis run executor will write Kraken2 and EsViritu results
// through `--project` and `--output-dir`. Readers decide what the sidebar lists and which
// viewer opens from the shape of the folder alone (AnalysesFolder, SidebarProjectScanner,
// ClassifierDatabaseRouter, MainSplitViewController). These builders write each shape LGE
// has written, and each shape the executor will write. The sidebar snapshot, the routing
// table and ClassifierLayoutReaderPinTests all build their folders here.
//
// Which files are literal and which come from today's writers
//   - Literal text written by this file. The Kraken2 and EsViritu sidecars and tables, the batch
//     summaries, the provenance stand-ins, the hidden inputs and analysis-metadata.json. A change
//     to a writer of these files cannot move a pin. The metadata text has the bytes that
//     AnalysesFolder.writeAnalysisMetadata wrote at 18e422c4f (pretty printed, sorted keys, ISO 8601
//     in UTC), so a reader that stops decoding what 2.6 wrote fails a pin. Only the instant is
//     computed, from the pinned local timestamp, because the scan shows it in the local zone.
//   - Files from today's writers. The batch manifests, from MetagenomicsBatchResultStore
//     saveClassification and saveEsViritu. The indexes (kraken2.sqlite and esviritu.sqlite), from
//     RoutingSafetyNetFixtures.kraken2Result and esVirituResult, which run the database writers.
//     The run folders of interruptedRun, whose metadata and run record come from
//     AnalysesFolder.createAnalysisDirectory and whose outcome comes from
//     AnalysisRunRecord.recordOutcome. A change to one of these writers moves the files it writes.
//
// Evidence for the shapes
//   - Command line output, from Tests/Fixtures/golden/classifiers/*/files.txt and
//     EsVirituCommand.swift and ClassifyCommand.swift. A claimed `--output` folder gets a
//     run record while the command runs and no analysis-metadata.json at any time.
//   - Window output, from AppDelegate+Classification.swift. A single Kraken2 run is one
//     folder with metadata and no index. Every EsViritu run, single or batch, is a batch
//     root with a sample folder, a summary, a manifest and an index.
//   - Import output, from MetagenomicsImportService.importEsViritu. A tool-prefixed folder
//     with metadata and the copied files at its root.
//   - Executor output, from the Phase 2.7 plan (decisions E1, E1b, E2, E3 and E5). Metadata, the
//     index built in process, a hidden inputs folder at the root, and a failed or cancelled
//     run kept hidden by its run record. A `--output-dir` the executor claims gets the metadata
//     only when it sits directly under a project's Analyses folder (E1b). Anywhere else it keeps
//     the command line set of files.
//
// Sidecars hold only the keys a reader uses, plus the file set a writer leaves.

import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

enum ClassifierLayoutFixtures {
    /// The sample every layout holds, and the first sample of a batch.
    static let sample = "HG002"
    /// The second sample of a two-sample batch.
    static let secondSample = "MMU-17"

    /// The command a run record names, written as the executor will name it (decisions E1, E8
    /// and E11). Kraken2 records `kraken2 classify`, and EsViritu runs as a batch of one or more.
    static func recordedCommand(for tool: String) -> String {
        tool == "kraken2"
            ? "lungfish-cli kraken2 classify HG002.fastq --db Viral --project Layouts.lungfish --format json"
            : "lungfish-cli esviritu detect HG002.fastq --project Layouts.lungfish --batch --format json"
    }

    /// Folder names, so the snapshot, the routing rows and the pin tests agree.
    enum Name {
        // Writers of today.
        static let cliKraken2 = "kraken2-golden"
        static let windowKraken2Single = "kraken2-2026-02-09T09-00-00"
        static let windowKraken2Batch = "kraken2-batch-2026-02-09T10-00-00"
        static let windowKraken2BatchWithoutIndex = "kraken2-batch-2026-02-09T11-00-00"
        static let cliEsViritu = "esviritu-golden"
        static let cliEsVirituFreeName = "HG002 viral detection"
        static let importedEsViritu = "esviritu-HG002_import"
        static let windowEsVirituBatchOfOne = "esviritu-batch-2026-02-09T12-00-00"
        static let windowEsVirituBatchOfOneWithoutIndex = "esviritu-batch-2026-02-09T12-10-00"
        static let probeOnlyKraken2 = "Sample run 12"
        // The executor.
        static let executorKraken2Single = "kraken2-2026-02-11T09-00-00"
        static let executorKraken2Batch = "kraken2-batch-2026-02-11T10-00-00"
        static let executorEsVirituBatch = "esviritu-batch-2026-02-11T11-00-00"
        static let claimedKraken2 = "Sample A kraken2"
        static let claimedEsViritu = "HG002 esviritu claimed"
        static let renamedExecutorKraken2 = "HG002 kraken2 renamed"
        static let failedKraken2 = "kraken2-2026-02-11T12-00-00"
        static let cancelledEsVirituBatch = "esviritu-batch-2026-02-11T13-00-00"
        static let runningKraken2 = "kraken2-2026-02-11T14-00-00"
        // Outside Analyses. The command line output is also what the executor leaves in a claimed
        // folder there (E1b), and the copy is a result of Analyses that kept its metadata.
        static let outsideCLIOutput = "Kraken2 CLI output"
        static let outsideAnalysesCopy = "Kraken2 result copied out of Analyses"
    }

    /// The timestamp a folder name ends with, which is the one the scanner parses from the name.
    static func timestamp(of name: String) -> String {
        String(name.suffix(19))
    }

    // MARK: - Writers of today

    /// `lungfish-cli conda classify --output-dir D` and `kraken2 classify`. The files sit at
    /// the root of D, with the inputs the run materialized and no metadata, batch file or index.
    @discardableResult
    static func cliKraken2(named name: String, in parent: URL) throws -> URL {
        let folder = try SafetyNetFiles.makeDirectory(parent.appendingPathComponent(name, isDirectory: true))
        try writeKraken2Files(into: folder, keepsInputs: true)
        return folder
    }

    /// One Kraken2 run in the window. The folder `createAnalysisDirectory` made, in the state a completed
    /// run leaves it, with metadata and the pipeline's files. The index is built at the first view, so
    /// the folder has none.
    @discardableResult
    static func windowKraken2Single(named name: String, timestamp: String, in analyses: URL) throws -> URL {
        let folder = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent(name, isDirectory: true))
        try writeMetadata(tool: "kraken2", isBatch: false, timestamp: timestamp, to: folder)
        try writeKraken2Files(into: folder, keepsInputs: true)
        return folder
    }

    /// A Kraken2 batch from the window. A batch root with metadata, a folder per sample, the
    /// summary, the manifest and, when the build finished, the index.
    @discardableResult
    static func windowKraken2Batch(
        named name: String,
        timestamp: String,
        in analyses: URL,
        samples: [String],
        index: Bool
    ) throws -> URL {
        let batch = try kraken2BatchRoot(named: name, in: analyses, samples: samples, index: index)
        try writeMetadata(tool: "kraken2", isBatch: true, timestamp: timestamp, to: batch)
        for sample in samples {
            try writeKraken2Files(into: batch.appendingPathComponent(sample, isDirectory: true), keepsInputs: false)
        }
        try writeKraken2BatchFiles(into: batch, samples: samples, timestamp: timestamp)
        return batch
    }

    /// `lungfish-cli esviritu detect --output D`. The files sit at the root of D with no metadata,
    /// summary, manifest or index.
    @discardableResult
    static func cliEsViritu(named name: String, in parent: URL) throws -> URL {
        let folder = try SafetyNetFiles.makeDirectory(parent.appendingPathComponent(name, isDirectory: true))
        try writeEsVirituFiles(sample: sample, into: folder, virusCount: 1)
        try SafetyNetFiles.write("", to: folder.appendingPathComponent("\(sample)_final_consensus.fasta"))
        try SafetyNetFiles.write("{}", to: folder.appendingPathComponent(".lungfish-provenance.json"))
        try SafetyNetFiles.write("@r1\nACGT\n+\nIIII\n", to: folder.appendingPathComponent(".lungfish-esviritu-inputs/materialized-0001.fastq"))
        return folder
    }

    /// `lungfish-cli import esviritu`. A tool-prefixed folder with metadata, the sidecar and the files
    /// the import copied into its root. The import takes the first `*virus*.tsv` in name order as the
    /// detection table, and a full command line output folder holds an assembly summary that sorts
    /// before it, so the input here is the detection table alone.
    @discardableResult
    static func importedEsViritu(named name: String, timestamp: String, in analyses: URL) throws -> URL {
        let folder = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent(name, isDirectory: true))
        try writeMetadata(tool: "esviritu", isBatch: false, timestamp: timestamp, to: folder)
        try writeEsVirituSidecar(sample: sample, into: folder, virusCount: 3)
        try writeEsVirituDetectionTable(sample: sample, into: folder, virusCount: 3)
        try SafetyNetFiles.write("{}", to: folder.appendingPathComponent(".lungfish-provenance.json"))
        return folder
    }

    /// Any EsViritu run in the window, one sample or more. A batch root with metadata, a folder per
    /// sample, the summary, the manifest and, when the build finished, the index.
    @discardableResult
    static func windowEsVirituBatch(
        named name: String,
        timestamp: String,
        in analyses: URL,
        samples: [String],
        index: Bool
    ) throws -> URL {
        let batch = try esVirituBatchRoot(named: name, in: analyses, samples: samples, index: index)
        try writeMetadata(tool: "esviritu", isBatch: true, timestamp: timestamp, to: batch)
        for sample in samples {
            let folder = batch.appendingPathComponent(sample, isDirectory: true)
            try writeEsVirituFiles(sample: sample, into: folder, virusCount: 1)
            try SafetyNetFiles.write("{}", to: folder.appendingPathComponent(".lungfish-provenance.json"))
        }
        try writeEsVirituBatchFiles(into: batch, samples: samples, timestamp: timestamp)
        return batch
    }

    /// A folder only its sidecar identifies. Kraken2 wrote it, then the user renamed it, or
    /// something copied the files without metadata.
    @discardableResult
    static func probeOnlyKraken2(named name: String, in analyses: URL) throws -> URL {
        let folder = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent(name, isDirectory: true))
        try writeKraken2Files(into: folder, keepsInputs: false)
        try SidebarScanSafetyNetProjects.pinCreationDate(of: folder, to: "2026-02-09T13-00-00")
        return folder
    }

    // MARK: - Executor layouts (decisions E1, E2, E3)

    /// One Kraken2 sample under `--project`. Metadata, the pipeline's files, a hidden inputs
    /// folder and the index built in process. The run record is gone because the run completed.
    @discardableResult
    static func executorKraken2Single(named name: String, timestamp: String, in analyses: URL) throws -> URL {
        let folder = try RoutingSafetyNetFixtures.kraken2Result(named: name, in: analyses, samples: [sample])
        try writeMetadata(tool: "kraken2", isBatch: false, timestamp: timestamp, to: folder)
        try writeKraken2Files(into: folder, keepsInputs: true)
        return folder
    }

    /// Several Kraken2 samples under `--project`. The batch root of the window plus one hidden
    /// inputs folder at the root.
    @discardableResult
    static func executorKraken2Batch(
        named name: String,
        timestamp: String,
        in analyses: URL,
        samples: [String]
    ) throws -> URL {
        let batch = try windowKraken2Batch(named: name, timestamp: timestamp, in: analyses, samples: samples, index: true)
        try SafetyNetFiles.write("@r1\nACGT\n+\nIIII\n", to: batch.appendingPathComponent(".lungfish-classify-inputs/materialized-0001.fastq"))
        return batch
    }

    /// EsViritu under `--project` is always a batch root, so one sample is a batch of one. The
    /// window's batch root plus one hidden inputs folder at the root.
    @discardableResult
    static func executorEsVirituBatch(
        named name: String,
        timestamp: String,
        in analyses: URL,
        samples: [String]
    ) throws -> URL {
        let batch = try windowEsVirituBatch(named: name, timestamp: timestamp, in: analyses, samples: samples, index: true)
        try SafetyNetFiles.write("@r1\nACGT\n+\nIIII\n", to: batch.appendingPathComponent(".lungfish-esviritu-inputs/materialized-0001.fastq"))
        return batch
    }

    /// `--output-dir D` under the executor, when D is a folder the user named directly under a
    /// project's Analyses folder (decision E1b). The executor claims D, writes the same metadata
    /// and keeps the command line set of files, so only the metadata identifies it. Anywhere else
    /// a claimed D gets no metadata and is `cliKraken2`.
    @discardableResult
    static func claimedKraken2(named name: String, timestamp: String, in analyses: URL) throws -> URL {
        let folder = try cliKraken2(named: name, in: analyses)
        try writeMetadata(tool: "kraken2", isBatch: false, timestamp: timestamp, to: folder)
        return folder
    }

    /// `esviritu detect --output D` under the executor, when D is a folder the user named directly
    /// under a project's Analyses folder (decision E1b). The executor claims D through the same
    /// path as a Kraken2 `--output-dir`, so D gets the metadata (`esviritu`, not a batch) beside the
    /// command line set of files, and no index. The same files route as nothing today, as
    /// `cliEsVirituFreeName` does, and route to the lazy `build-db esviritu` once they carry metadata.
    @discardableResult
    static func claimedEsViritu(named name: String, timestamp: String, in analyses: URL) throws -> URL {
        let folder = try cliEsViritu(named: name, in: analyses)
        try writeMetadata(tool: "esviritu", isBatch: false, timestamp: timestamp, to: folder)
        return folder
    }

    /// A run the executor started under `--project`, in the state it leaves. The folder comes
    /// from `createAnalysisDirectory`, which writes metadata and the run record naming the command.
    /// A nil outcome is a run still going, `.failed` and `.cancelled` are runs that ended. The
    /// executor keeps an ended run hidden with partial files, a hidden inputs folder and a
    /// stand-in for its provenance record. Scan and discovery never read that record.
    @discardableResult
    static func interruptedRun(
        tool: String,
        isBatch: Bool,
        timestamp: String,
        outcome: AnalysisRunRecord.Outcome?,
        in project: URL
    ) throws -> URL {
        let folder = try AnalysesFolder.createAnalysisDirectory(
            tool: tool,
            in: project,
            isBatch: isBatch,
            date: try SidebarScanSafetyNetProjects.pinnedDate(timestamp),
            command: recordedCommand(for: tool)
        )
        let inputs = tool == "kraken2" ? ".lungfish-classify-inputs" : ".lungfish-esviritu-inputs"
        try SafetyNetFiles.write("@r1\nACGT\n+\nIIII\n", to: folder.appendingPathComponent("\(inputs)/materialized-0001.fastq"))
        if isBatch {
            try SafetyNetFiles.write("partial\n", to: folder.appendingPathComponent("\(sample)/partial.txt"))
        } else {
            try SafetyNetFiles.write("partial\n", to: folder.appendingPathComponent("classification.kreport"))
        }
        if let outcome {
            try SafetyNetFiles.write(#"{"status":"\#(outcome.rawValue)"}"#, to: folder.appendingPathComponent(".lungfish-provenance.json"))
            AnalysisRunRecord.recordOutcome(outcome, in: folder)
        }
        return folder
    }

    // MARK: - The project the snapshot and the pin tests share

    /// Every layout in one project. The run folders are made last, because they come from the
    /// real folder creation and the scan must leave them out.
    static func writeProject(in root: URL) throws -> URL {
        let project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("Classifier Layouts.lungfish", isDirectory: true))
        try SafetyNetFiles.write(#"{"name":"Classifier Layouts"}"#, to: project.appendingPathComponent("metadata.json"))
        let analyses = try SafetyNetFiles.makeDirectory(project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true))

        try cliKraken2(named: Name.cliKraken2, in: analyses)
        try windowKraken2Single(named: Name.windowKraken2Single, timestamp: "2026-02-09T09-00-00", in: analyses)
        try windowKraken2Batch(
            named: Name.windowKraken2Batch, timestamp: "2026-02-09T10-00-00", in: analyses,
            samples: [sample, secondSample], index: true
        )
        try windowKraken2Batch(
            named: Name.windowKraken2BatchWithoutIndex, timestamp: "2026-02-09T11-00-00", in: analyses,
            samples: [sample, secondSample], index: false
        )
        try cliEsViritu(named: Name.cliEsViritu, in: analyses)
        try cliEsViritu(named: Name.cliEsVirituFreeName, in: analyses)
        try importedEsViritu(named: Name.importedEsViritu, timestamp: "2026-02-09T12-30-00", in: analyses)
        try windowEsVirituBatch(
            named: Name.windowEsVirituBatchOfOne, timestamp: "2026-02-09T12-00-00", in: analyses,
            samples: [sample], index: true
        )
        try windowEsVirituBatch(
            named: Name.windowEsVirituBatchOfOneWithoutIndex, timestamp: "2026-02-09T12-10-00", in: analyses,
            samples: [sample], index: false
        )
        try probeOnlyKraken2(named: Name.probeOnlyKraken2, in: analyses)

        try executorKraken2Single(named: Name.executorKraken2Single, timestamp: "2026-02-11T09-00-00", in: analyses)
        try executorKraken2Batch(
            named: Name.executorKraken2Batch, timestamp: "2026-02-11T10-00-00", in: analyses,
            samples: [sample, secondSample]
        )
        try executorEsVirituBatch(
            named: Name.executorEsVirituBatch, timestamp: "2026-02-11T11-00-00", in: analyses,
            samples: [sample]
        )
        try claimedKraken2(named: Name.claimedKraken2, timestamp: "2026-02-11T11-30-00", in: analyses)
        try claimedEsViritu(named: Name.claimedEsViritu, timestamp: "2026-02-11T11-35-00", in: analyses)

        let imports = try SafetyNetFiles.makeDirectory(project.appendingPathComponent("Imports", isDirectory: true))
        try cliKraken2(named: Name.outsideCLIOutput, in: imports)
        try windowKraken2Single(named: Name.outsideAnalysesCopy, timestamp: "2026-02-11T11-40-00", in: imports)

        try interruptedRun(tool: "kraken2", isBatch: false, timestamp: "2026-02-11T12-00-00", outcome: .failed, in: project)
        try interruptedRun(tool: "esviritu", isBatch: true, timestamp: "2026-02-11T13-00-00", outcome: .cancelled, in: project)
        try interruptedRun(tool: "kraken2", isBatch: false, timestamp: "2026-02-11T14-00-00", outcome: nil, in: project)
        return project
    }

    // MARK: - Files

    /// `analysis-metadata.json` as literal text with the bytes that `AnalysesFolder.writeAnalysisMetadata`
    /// wrote at 18e422c4f. The file is pretty printed with sorted keys and no final newline, and
    /// `created` is ISO 8601 in UTC. It does not go through the writer, so a change to the metadata
    /// codec cannot rewrite a fixture. `created` is the instant of the pinned local timestamp,
    /// because the scan shows it in the local zone and the snapshot must read the same in every zone.
    private static func writeMetadata(tool: String, isBatch: Bool, timestamp: String, to folder: URL) throws {
        let created = ISO8601DateFormatter().string(from: try SidebarScanSafetyNetProjects.pinnedDate(timestamp))
        try SafetyNetFiles.write(
            """
            {
              "created" : "\(created)",
              "isBatch" : \(isBatch),
              "tool" : "\(tool)"
            }
            """,
            to: folder.appendingPathComponent("analysis-metadata.json")
        )
    }

    /// What `ClassificationPipeline` leaves in a result folder, without the read-level files
    /// nothing in the scan or the router opens.
    private static func writeKraken2Files(into folder: URL, keepsInputs: Bool) throws {
        try SafetyNetFiles.write(
            #"{"config":{"databaseName":"Viral","databaseVersion":"20260626","goal":"classify","confidence":0.2},"reportPath":"classification.kreport","outputPath":"classification.kraken.gz","toolVersion":"2.17.1","profileOutcome":{"state":"notRequested"}}"#,
            to: folder.appendingPathComponent("classification-result.json")
        )
        try SafetyNetFiles.write("100.00\t10\t0\tR\t1\troot\n", to: folder.appendingPathComponent("classification.kreport"))
        try SafetyNetFiles.write("{}", to: folder.appendingPathComponent(".lungfish-provenance.json"))
        if keepsInputs {
            try SafetyNetFiles.write("@r1\nACGT\n+\nIIII\n", to: folder.appendingPathComponent(".lungfish-classify-inputs/materialized-0001.fastq"))
        }
    }

    /// `esviritu-result.json`, with the keys the scan reads and the paths the other readers follow.
    static func writeEsVirituSidecar(sample: String, into folder: URL, virusCount: Int) throws {
        try SafetyNetFiles.write(
            #"{"config":{"sampleName":"\#(sample)","threads":2,"qualityFilter":true,"readFormat":"unpaired"},"detectionPath":"\#(sample).detected_virus.info.tsv","assemblyPath":"\#(sample).detected_virus.assembly_summary.tsv","taxProfilePath":"\#(sample).tax_profile.tsv","coveragePath":"\#(sample).virus_coverage_windows.tsv","virusCount":\#(virusCount),"toolVersion":"1.3.3"}"#,
            to: folder.appendingPathComponent("esviritu-result.json")
        )
    }

    /// `<sample>.detected_virus.info.tsv`, the table the probe and the import look for.
    static func writeEsVirituDetectionTable(sample: String, into folder: URL, virusCount: Int) throws {
        try SafetyNetFiles.write(
            esVirituDetectionTable(sample: sample, virusCount: virusCount),
            to: folder.appendingPathComponent("\(sample).detected_virus.info.tsv")
        )
    }

    /// The tables and sidecar EsViritu leaves for one sample, named by the sample as the golden
    /// inventory shows. The detection table carries one row per virus, so the sidecar's count and
    /// the table agree.
    static func writeEsVirituFiles(sample: String, into folder: URL, virusCount: Int) throws {
        try writeEsVirituSidecar(sample: sample, into: folder, virusCount: virusCount)
        try writeEsVirituDetectionTable(sample: sample, into: folder, virusCount: virusCount)
        // The other three tables hold only the header the golden capture shows. No reader of the
        // scan or the router opens them.
        let headers = [
            "detected_virus.assembly_summary.tsv": "sample_ID\tfiltered_reads_in_sample\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tadj_taxonomy\tread_count\tcovered_bases\tavg_read_identity\tconsensus_ref_identity\tAccession\tSegment\tRPKMF\n",
            "tax_profile.tsv": "sample_ID\tfiltered_reads_in_sample\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tread_count\tRPKMF\tavg_read_identity\tconsensus_ref_identity\tassembly_list\n",
            "virus_coverage_windows.tsv": "Accession\twindow_index\twindow_start\twindow_end\taverage_coverage\n",
        ]
        for (table, header) in headers {
            try SafetyNetFiles.write(header, to: folder.appendingPathComponent("\(sample).\(table)"))
        }
        try SafetyNetFiles.write("reads for EsViritu denominator: 55\nreads pre-quality filter: 55\n", to: folder.appendingPathComponent("\(sample)_esviritu.readstats.yaml"))
        try SafetyNetFiles.write("", to: folder.appendingPathComponent("\(sample)_temp/\(sample).third.filt.sorted.bam"))
    }

    /// `<sample>.detected_virus.info.tsv` with the 25 columns of the golden capture
    /// (Tests/Fixtures/golden/classifiers/esviritu) and one synthetic row per virus.
    static func esVirituDetectionTable(sample: String, virusCount: Int) -> String {
        let header = [
            "sample_ID", "Name", "description", "Length", "Segment", "Accession", "Assembly", "Asm_length",
            "kingdom", "phylum", "tclass", "order", "family", "genus", "species", "subspecies", "adj_taxonomy",
            "RPKMF", "read_count", "covered_bases", "mean_coverage", "avg_read_identity",
            "consensus_ref_identity", "Pi", "filtered_reads_in_sample",
        ]
        let rows = (0..<virusCount).map { index -> String in
            let accession = "MW33878\(index + 1).1"
            return [
                sample, "Synthetic virus \(index + 1)", "Synthetic test virus", "29889", "NA", accession, "acc:\(accession)", "29889",
                "k__Viruses", "p__Pisuviricota", "c__Pisoniviricetes", "o__Nidovirales", "f__Coronaviridae",
                "g__Betacoronavirus", "s__Betacoronavirus pandemicum", "t__Synthetic", "true",
                "32848.8", "54", "6407", "0.27", "0.995", "1.0", "0.0", "55",
            ].joined(separator: "\t")
        }
        return ([header.joined(separator: "\t")] + rows).joined(separator: "\n") + "\n"
    }

    private static func kraken2BatchRoot(named name: String, in analyses: URL, samples: [String], index: Bool) throws -> URL {
        if index {
            return try RoutingSafetyNetFixtures.kraken2Result(named: name, in: analyses, samples: samples, sampleSubdirectories: true)
        }
        let batch = try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent(name, isDirectory: true))
        for sample in samples {
            try SafetyNetFiles.makeDirectory(batch.appendingPathComponent(sample, isDirectory: true))
        }
        return batch
    }

    private static func esVirituBatchRoot(named name: String, in analyses: URL, samples: [String], index: Bool) throws -> URL {
        if index {
            return try RoutingSafetyNetFixtures.esVirituResult(named: name, in: analyses, samples: samples)
        }
        return try SafetyNetFiles.makeDirectory(analyses.appendingPathComponent(name, isDirectory: true))
    }

    /// The summary and manifest the window's Kraken2 batch writes (`classification-batch-summary.tsv`
    /// and schema 2 of `classification-batch-result.json`).
    private static func writeKraken2BatchFiles(into batch: URL, samples: [String], timestamp: String) throws {
        let summary = "classification-batch-summary.tsv"
        try SafetyNetFiles.write(
            (["sample_id\tstatus"] + samples.map { "\($0)\tok" }).joined(separator: "\n") + "\n",
            to: batch.appendingPathComponent(summary)
        )
        try MetagenomicsBatchResultStore.saveClassification(
            ClassificationBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 2,
                    createdAt: try SidebarScanSafetyNetProjects.pinnedDate(timestamp),
                    sampleCount: samples.count
                ),
                goal: "classify",
                databaseName: "Viral",
                databaseVersion: "20260626",
                summaryTSV: summary,
                samples: samples.map { sampleRecord($0, status: "ok") },
                completedCount: samples.count,
                degradedCount: 0,
                failedCount: 0
            ),
            to: batch
        )
        try SafetyNetFiles.write("{}", to: batch.appendingPathComponent(".lungfish-provenance.json"))
    }

    /// The summary and manifest the window's EsViritu batch writes (`esviritu-batch-summary.tsv`
    /// and schema 1 of `esviritu-batch-result.json`).
    private static func writeEsVirituBatchFiles(into batch: URL, samples: [String], timestamp: String) throws {
        let summary = "esviritu-batch-summary.tsv"
        try SafetyNetFiles.write(
            (["sample_id\tstatus\tvirus_count"] + samples.map { "\($0)\tok\t1" }).joined(separator: "\n") + "\n",
            to: batch.appendingPathComponent(summary)
        )
        try MetagenomicsBatchResultStore.saveEsViritu(
            EsVirituBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(
                    schemaVersion: 1,
                    createdAt: try SidebarScanSafetyNetProjects.pinnedDate(timestamp),
                    sampleCount: samples.count
                ),
                summaryTSV: summary,
                samples: samples.map { sampleRecord($0, status: nil) }
            ),
            to: batch
        )
        try SafetyNetFiles.write("{}", to: batch.appendingPathComponent(".lungfish-provenance.json"))
    }

    private static func sampleRecord(_ sample: String, status: String?) -> MetagenomicsBatchSampleRecord {
        MetagenomicsBatchSampleRecord(
            sampleId: sample,
            resultDirectory: sample,
            inputFiles: ["/Reads/\(sample).fastq"],
            isPairedEnd: false,
            status: status,
            message: nil
        )
    }
}
