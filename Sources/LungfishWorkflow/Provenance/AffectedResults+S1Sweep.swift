// AffectedResults+S1Sweep.swift - The affected rows of the S1 sweep before Preview 2026.11.17
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension AffectedResults.RecordName {
    /// `lungfish build-db taxtriage` (`BuildDbProvenanceTool.workflowName`, `BuildDbCommand+Provenance.swift:32`). It is
    /// the root record of a TaxTriage result folder that holds no record of another workflow, an older run or an import,
    /// and the record of the database beside it.
    public static let buildDbTaxTriage = "lungfish build-db taxtriage"
    /// `lungfish fastq merge` (`FastqCommand+Provenance.swift:241`), counted or not (BIO-MERGE Q3).
    public static let fastqMerge = "lungfish fastq merge"
    /// The record a sample metadata import writes when the result holds none
    /// (`SampleMetadataBundleImportService.swift:65-66`). Up to Preview 2026.11.16 it wrote it over the run's record.
    public static let sampleMetadataImport = "Sample metadata import"
    /// The root of the folder `lungfish extract taxa-collection` writes (`ExtractTaxaCollectionCommand.swift:202,232`).
    public static let extractTaxaCollection = "lungfish extract taxa-collection"
    /// The record of a full-length ONT MHC genotyping run (`FullLengthONTMHCGenotypingPipeline+Provenance.swift:227`).
    public static let fullLengthONTMHCGenotype = "lungfish fastq full-length-ont-mhc-genotype"
}

extension AffectedResults {
    /// The flag with which `lungfish build-db taxtriage` skips its own cleanup (`BuildDbCommand+TaxTriageCore.swift:60`).
    static let buildDbNoCleanupFlag = "--no-cleanup"

    /// The rows of the S1 sweep before Preview 2026.11.17 that lanes TT-m1, TT-m2, COUNTS and BLAST (AFFECTED-S1 m1) and
    /// DEMUX, QUALITY, MERGE-UNCOUNTED, RECORDS and CKPT-DEPTH (m2) fixed. Preview 2026.11.16 (14223) lacks each fix, so
    /// each row ends there. No source lane names the commit that brought a defect in, so none has a first build. Each
    /// `fixCommit` is the last commit on main that changes code in the row's lane.
    static let s1SweepRows: [AffectedResultRow] = [
        // TT-m1 (4a0597253) keeps `top/`, and the app's recount passes --no-cleanup. Every earlier rebuild of a folder with
        // no record of `taxtriage run` ran the command's own cleanup and deleted `top/`, and so did each recount the app
        // ran on display from 3.2 TTREADS through Preview 2026.11.16. The cleanup of an executor result always kept
        // `top/`, so the row names only the narrower kind (TT-m1, Affected facts).
        AffectedResultRow(
            backlogID: "TT-LEGACY-CLEANUP-REMOVES-TOP", kinds: [.taxTriageLegacyCleanup], firstBuild: nil,
            lastBuild: 14223,
            sentence: "When an earlier version of Lungfish opened or rebuilt this result, it deleted the folder named top "
                + "inside it, so a sample whose rows came only from that folder cannot be counted again.",
            whatToDo: "Import the original TaxTriage run folder again, if you still have it.",
            fixCommit: "7e76f495e"
        ),
        // TT-m2 (2ddb5c113) counts a row on every strain it sums. Its BIO review B1 (20b45dbad) moves the read-count mark
        // to `odr_reads_aligned+organism_references+strain_groups`, so a database with any other `read_count` was built
        // before the fix, and the app counts such a database again once when it shows the result in a project it can
        // write. It does so only while the result's report files exist (`TaxTriageDatabase.isStale`), so a result whose
        // reports are gone keeps the one-strain counts. The recount rewrites the root record only of a folder whose root
        // is the build-db record, so the row stays on an executor result after its recount, and the words say both.
        AffectedResultRow(
            backlogID: "TT-STRAIN-GROUP", kinds: [.taxTriage], firstBuild: nil, lastBuild: 14223,
            sentence: "For a TaxTriage row that sums several strains, the version that made this result used one "
                + "strain's references only for Unique Reads, Extract Reads and BLAST Verify, and this note can stay "
                + "after the result is counted again, because the result's record still names that version.",
            whatToDo: "Open the result once in a project you can edit or run lungfish-cli build-db taxtriage "
                + "<result folder> --force, either of which counts it again only while its report files are still "
                + "in the result folder, and if those files are gone, run TaxTriage again.",
            fixCommit: "393d2bf2f"
        ),
        // COUNTS (8183187a1) keys each mate on its whole pair. The import writes Unique Reads into the result's NAO-MGS
        // database, so an earlier import keeps the low count until its results file is imported again. The import's
        // record names the build that wrote it, as for NAOMGS-UNALIGNED-MATE-HIT (``AffectedResults/builds(of:)``).
        AffectedResultRow(
            backlogID: "NAOMGS-DEDUP-READ-COUNT", kinds: [.naoMgs], firstBuild: nil, lastBuild: 14223,
            sentence: "The version that imported this result counted a NAO-MGS read as a PCR duplicate when it shared its "
                + "place, strand and length with a read of a different pair, so Unique Reads can read low and PCR "
                + "duplicates can read high.",
            whatToDo: "Import the original results file again, which makes a second result beside this one, then "
                + "remove this result.",
            fixCommit: "ca94c5f41"
        ),
        // BIO-BLAST ruling D. A verdict is saved in blast-result.json and never judged again on open, and a row takes no
        // test of each result, so the row holds kinds and builds, with Kraken 2 since BLAST-FIX m1 (b4de7f438). By
        // UX-BLAST-NOTAX item 11 it adds no kind. A result saved before `judgedAt` and a Kraken 2 result judged on its
        // report's tree alone stay in it, and a result judged at `rowTaxId` or `names` reads Not judged on reopen.
        AffectedResultRow(
            backlogID: "BLAST-NAME-PHRASE-LEAK", kinds: [.naoMgs, .esViritu, .taxTriage, .nvd, .kraken2],
            firstBuild: nil, lastBuild: 14223,
            sentence: "A Verify with BLAST… badge that an earlier version saved on this result could count a read as "
                + "supporting when its best match was a record of another species whose name holds the row's name, "
                + "such as Woolly monkey hepatitis B virus on a Hepatitis B virus row.",
            whatToDo: "With NCBI Taxonomy installed, run Verify with BLAST… again on any row that read Supported or Mixed.",
            fixCommit: "973125c78"
        ),
        // Lane AFFECTED-S1 m2, from here on. DEMUX (8f60dd82c to 3a78e2507) carries the Demux tab's Min Overlap and Allow
        // indels to the run and refuses a cell that holds another barcode's sequence. Before it, a run the tab started
        // searched each kit barcode's own sequence with the default overlap and indels, and the record cannot tell which
        // rows showed a typed sequence (DEMUX, Affected facts K5), so the row holds every run a plan started.
        AffectedResultRow(
            backlogID: "DEMUXPLAN-LIMITS-S3-GROUP", kinds: [.fastqDemultiplexPlanRun], firstBuild: nil, lastBuild: 14223,
            sentence: "This run used the kit's barcode sequences and the default Min Overlap, Allow Indels and "
                + "reverse-complement search, whatever the Demux tab showed.",
            whatToDo: "If you changed any of them, demultiplex again from the tab.",
            fixCommit: "3a78e2507"
        ),
        // QUALITY (f61cae192, 38b4b5ebe) stores the statistics of the file a FASTQ operation stored. Neither the manifest
        // nor the record says which were stored, and of the operations only a trim names a kind, so the row holds every
        // trim and says "if the reads held scores of 0 or 1" (BIO-QUALITY Q4, QUALITY-BIO check 6 and SF3).
        AffectedResultRow(
            backlogID: "DERIVED-STATS-PRESTORAGE", kinds: [.fastqTrim], firstBuild: nil, lastBuild: 14223,
            sentence: "Mean Q and the quality charts describe the reads before Lungfish stored them, which raised every "
                + "score of 0 or 1 to 2, so if the reads held scores of 0 or 1, they can read a little lower than the "
                + "stored reads, while Q20 and Q30 are not changed.",
            whatToDo: "Run the operation again to measure the stored reads.",
            fixCommit: "c9e13ce99"
        ),
        // MERGE-UNCOUNTED (be15a4fdc) stops the app's merge from passing --count-duplicates. Every app merge before it
        // recorded the counted step (BIO-MERGE Q3, whose words these are).
        AffectedResultRow(
            backlogID: "MERGE-COUNTED-INVENTED-Q", kinds: [.fastqCountedMerge], firstBuild: nil, lastBuild: 14223,
            sentence: "The version that made these merged reads kept one copy of each read sequence and wrote a quality "
                + "score of 40 on every base in place of the scores bbmerge and the sequencer gave, so the quality shown "
                + "for them, and any trimming or filtering by quality, used scores no instrument measured, reads that did "
                + "not merge lost their mate pairing, and each copy stands for several reads that later steps count once.",
            whatToDo: "Merge the original read pairs again with this version, and redo any trimming, filtering, assembly, "
                + "mapping or variant calling that used these merged reads.",
            fixCommit: "e7a35023c"
        ),
        // RECORDS (d9939b95f) adds a metadata import to the record that stands in the bundle. Before it the import wrote
        // its own record over the run's. A 12S run always writes a root record, so on a 12S result the import's record
        // always means the run's is gone (RECORDS-BIO R4). The kind comes from the sidebar type and the record's root.
        AffectedResultRow(
            backlogID: "TWELVES-IMPORT-REPLACES-RUN-RECORD", kinds: [.twelveSRunRecordReplaced], firstBuild: nil,
            lastBuild: 14223,
            sentence: "A sample metadata import replaced this bundle's record of its 12S run, so its command, times and "
                + "tool versions are gone.",
            whatToDo: "Run the 12S matching again for a full record.",
            fixCommit: "cc18a4e12"
        ),
        // The same fix for the other results the import takes whose run or import writes a root record in the result
        // folder: EsViritu (RECORDS-BIO R4), the runs the executor records and NAO-MGS imports
        // (``kindsWhoseRunRecordAnImportReplaced``).
        AffectedResultRow(
            backlogID: "RECORDS-AFFECTED-OTHER-RESULT-TYPES", kinds: [.resultRunRecordReplaced], firstBuild: nil,
            lastBuild: 14223,
            sentence: "A sample metadata import replaced the run's record of this result.",
            whatToDo: "Run the analysis again for a full record.",
            fixCommit: "cc18a4e12"
        ),
        // RECORDS (2e44adecd) adds the steps of an input's own record to an in-place ingest. Before it, an ingest that
        // removed the original also removed the extraction record beside it, and the folder's record cannot show whether
        // the file had one, so the words say "may have dropped" (RECORDS-BIO R4).
        AffectedResultRow(
            backlogID: "PAIRING-RECORD-LOST", kinds: [.fastqIngestDroppedExtractionRecord], firstBuild: nil,
            lastBuild: 14223,
            sentence: "Ingesting this file in place may have dropped the record of the extraction it came from, with the "
                + "source file, its digest and the per-taxon counts.",
            whatToDo: "Extract the reads again if you need that record.",
            fixCommit: "cc18a4e12"
        ),
        // CKPT-DEPTH (0019e8379) reuses a sample checkpoint only when each output is the file it recorded. Before it a
        // reuse checked only that each output existed (CKPT-DEPTH-BIO SF1, whose words these are).
        AffectedResultRow(
            backlogID: "TTL-ONT-CHECKPOINT-REUSE", kinds: [.genotypeCheckpointReuse], firstBuild: nil, lastBuild: 14223,
            sentence: "A sample reused from saved results could hold files that a later run with other settings, stopped "
                + "part way, had overwritten, so its calls may not match this run's settings.",
            whatToDo: "Run the genotyping again without reusing earlier results.",
            fixCommit: "4a76bce42"
        ),
    ]

    /// Whether `envelope`, a record of `lungfish build-db taxtriage`, ran the command's own cleanup, which deleted `top/`
    /// until TT-m1. That is a completed run with `--no-cleanup` in neither its argv, a step's argv nor its options. An
    /// executor result's root record names `taxtriage run`, whose cleanup kept `top/`, so it is never such a record.
    static func ranTheLegacyTaxTriageCleanup(_ envelope: ProvenanceEnvelope) -> Bool {
        guard envelope.status == .completed else { return false }
        if case .boolean(true)? = envelope.options.explicit["noCleanup"] { return false }
        return !([envelope.argv] + envelope.steps.map(\.argv)).contains { $0.contains(buildDbNoCleanupFlag) }
    }
}

// MARK: - The rows a record shows, with its narrower kinds

extension AffectedResults {
    /// The rows for `kind` that hold every build that may have made the result `envelope` records (``builds(of:)``), with
    /// the rows of each narrower kind the record names beside `kind` (``narrowerKinds(of:beside:)``), in table order.
    public static func rows(for envelope: ProvenanceEnvelope, kind: AffectedResultKind) -> [AffectedResultRow] {
        guard let builds = builds(of: envelope) else { return [] }
        let kinds = narrowerKinds(of: envelope, beside: kind).union([kind])
        return rows.filter {
            !kinds.isDisjoint(with: $0.kinds) && $0.holds(build: builds.lowerBound) && $0.holds(build: builds.upperBound)
        }
    }

    /// The results whose run or import writes its root record in the folder a sample metadata import writes into
    /// (`ResultBundleSampleMetadataResolver.swift:7-36`): EsViritu (`EsVirituPipeline.swift:652,686`, RECORDS-BIO R4),
    /// TaxTriage, Kraken 2 and EsViritu runs (`AnalysisRunExecutor`, step P4) and NAO-MGS imports
    /// (`MetagenomicsImportService.swift:1206`). A genotyping run writes `full-length-ont-mhc-genotyping-provenance.json`,
    /// which the import never wrote over, so it is not here. NVD takes no metadata import.
    static let kindsWhoseRunRecordAnImportReplaced: Set<AffectedResultKind> = [.taxTriage, .esViritu, .kraken2, .naoMgs]

    /// The narrower kinds `envelope` names beside the kind of its result, whose rows that result shows too, since one record
    /// names one kind (``kind(of:)``): a TaxTriage result the legacy cleanup rebuilt, a result whose run record a metadata
    /// import replaced, a demultiplexing run a plan started and an in-place ingest that dropped an extraction record.
    static func narrowerKinds(of envelope: ProvenanceEnvelope, beside kind: AffectedResultKind) -> Set<AffectedResultKind> {
        let root = envelope.workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        var kinds: Set<AffectedResultKind> = []
        if kind == .taxTriage, root == RecordName.buildDbTaxTriage, ranTheLegacyTaxTriageCleanup(envelope) {
            kinds.insert(.taxTriageLegacyCleanup)
        }
        if kindsWhoseRunRecordAnImportReplaced.contains(kind), isTheRecordOfAMetadataImport(envelope) {
            kinds.insert(.resultRunRecordReplaced)
        }
        if root == RecordName.fastqDemultiplex, aDemuxPlanStartedTheRun(envelope) { kinds.insert(.fastqDemultiplexPlanRun) }
        if root == RecordName.extractTaxaCollection, anInPlaceIngestDroppedTheExtractionRecord(envelope) {
            kinds.insert(.fastqIngestDroppedExtractionRecord)
        }
        return kinds
    }

    /// The kind of a record whose root ``kind(of:)`` does not switch on itself. An in-place ingest merges into the record
    /// that stands in the folder, which keeps its own root name, so the ingest shows only as its step (BIO-ROUTES-5 item 4),
    /// and a pair ingested in place is the loose-pair kind first, even in a taxa collection, which names the narrower
    /// kind of a dropped extraction record beside it.
    static func kindOfAnotherRoot(_ envelope: ProvenanceEnvelope) -> AffectedResultKind? {
        switch envelope.workflowName.trimmingCharacters(in: .whitespacesAndNewlines) {
        case RecordName.buildDbTaxTriage:
            return ranTheLegacyTaxTriageCleanup(envelope) ? .taxTriageLegacyCleanup : nil
        case RecordName.fastqMerge:
            return envelope.steps.contains { $0.toolName == fastqMergeCountedStep } ? .fastqCountedMerge : nil
        case RecordName.fullLengthONTMHCGenotype:
            return envelope.steps.contains { $0.toolName == genotypeCheckpointReuseStep } ? .genotypeCheckpointReuse : nil
        case RecordName.extractTaxaCollection:
            if mergedIngestOfTwoLooseFiles(envelope) { return .fastqIngestLoosePair }
            return anInPlaceIngestDroppedTheExtractionRecord(envelope) ? .fastqIngestDroppedExtractionRecord : nil
        default:
            return mergedIngestOfTwoLooseFiles(envelope) ? .fastqIngestLoosePair : nil
        }
    }

    /// The step every merge the app ran up to Preview 2026.11.16 recorded (`FastqCommand+Provenance.swift:210`).
    static let fastqMergeCountedStep = "lungfish fastq merge count-duplicates"
    /// The step of a sample a genotyping run reused (`FullLengthONTMHCGenotypingPipeline+Checkpoints.swift:443`). Its argv
    /// starts with `lungfish-cli` and names no subcommand the CLI has, so only the tool name marks it (CKPT-DEPTH-BIO SF1).
    static let genotypeCheckpointReuseStep = "lungfish full-length ONT MHC sample checkpoint reuse"

    /// Whether `envelope`, a record of a result, is the record a sample metadata import wrote. On a result whose run writes
    /// a root record, that record was the run's until RECORDS (RECORDS-BIO R4).
    public static func isTheRecordOfAMetadataImport(_ envelope: ProvenanceEnvelope) -> Bool {
        envelope.workflowName.trimmingCharacters(in: .whitespacesAndNewlines) == RecordName.sampleMetadataImport
    }

    /// Whether a `lungfish fastq demultiplex` record names the definition Demultiplex… of the Demux tab writes,
    /// `<dataset> demux plan <12 hex>.csv` (`FASTQDemultiplexPlanLaunch.swift:165`), in `kit` or in `customBarcodeKit`,
    /// the copy of the same name the run kept (`FastqCommand.swift:385-386`, `:450`, DEMUX Affected facts K5).
    static func aDemuxPlanStartedTheRun(_ envelope: ProvenanceEnvelope) -> Bool {
        let options = envelope.options.explicit
        let paths: [String] = ["kit", "customBarcodeKit"].compactMap {
            switch options[$0] {
            case .string(let path)?: return path
            case .file(let url)?: return url.path
            default: return nil
            }
        }
        return paths.contains { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard name.hasSuffix(".csv"), let marker = name.range(of: " demux plan ", options: .backwards),
                  marker.lowerBound > name.startIndex else { return false }
            let digest = name[marker.upperBound...].dropLast(4)
            return digest.count == 12 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }

    /// Whether an in-place ingest removed the original of a file whose extraction record it did not carry: an ingest step
    /// (`FastqIngestSubcommand.swift:246`), `deleteOriginals` true (`:199`) and no step of the extraction
    /// (`TaxonomyExtractionPipeline.swift:448`). Without `--delete-originals` the file's own record stayed beside it.
    static func anInPlaceIngestDroppedTheExtractionRecord(_ envelope: ProvenanceEnvelope) -> Bool {
        guard case .boolean(true)? = envelope.options.explicit["deleteOriginals"] else { return false }
        return envelope.steps.contains { $0.toolName == "FASTQIngestionPipeline" }
            && !envelope.steps.contains { $0.toolName == "TaxonomyExtractionPipeline" }
    }
}
