// AffectedResultsS1SweepTests.swift - The affected rows of the TaxTriage, NAO-MGS and BLAST fixes of the S1 sweep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// Lanes AFFECTED-S1 m1 and m2 of the S1 sweep (`docs/contracts/SCOPE-AND-DELIVERY.md`, Affected results). Preview
/// 2026.11.16 (14223) lacks each fix, so each row holds every build up to 14223 and none after. The tests read the table by
/// backlog id and the kinds by raw value, so they compile at each lane's base, where its rows and kinds do not exist.
final class AffectedResultsS1SweepTests: XCTestCase {
    /// The narrower TaxTriage kind of a result whose record ran the legacy cleanup of `lungfish build-db taxtriage`.
    private static let legacyCleanup = "taxTriageLegacyCleanup"

    /// Each row, its kinds by raw value and the landed hash of the last code commit of its source lane.
    private static let expected: [(id: String, kinds: [String], fix: String)] = [
        // TT-m1, with TT-m1b and the folds of its BIO review. 7e76f495e is the last of its commits that changes code.
        ("TT-LEGACY-CLEANUP-REMOVES-TOP", [legacyCleanup], "7e76f495e"),
        // TT-m2, with the read-count mark of its BIO review B1 (20b45dbad) and its S-2 words (393d2bf2f).
        ("TT-STRAIN-GROUP", ["taxTriage"], "393d2bf2f"),
        // COUNTS. 8183187a1 keys each NAO-MGS mate on its pair, and ca94c5f41 is the lane's last commit.
        ("NAOMGS-DEDUP-READ-COUNT", ["naoMgs"], "ca94c5f41"),
        // BLAST, BLAST-FIX m1 and m2 and the folds of BLAST-BIO-UX, BIO-BLAST ruling D with `.kraken2` (item 8).
        ("BLAST-NAME-PHRASE-LEAK", ["naoMgs", "esViritu", "taxTriage", "nvd", "kraken2"], "973125c78"),
        // Lane AFFECTED-S1 m2. DEMUX, with the folds of its BIO review: 3a78e2507 (DEMUX-BIO B1) is its last code commit.
        ("DEMUXPLAN-LIMITS-S3-GROUP", [planRun], "3a78e2507"),
        // QUALITY: f61cae192 and 38b4b5ebe fix the row, and c9e13ce99 (item 3) is the lane's last commit.
        ("DERIVED-STATS-PRESTORAGE", ["fastqTrim"], "c9e13ce99"),
        // MERGE-UNCOUNTED: be15a4fdc stops the count, and e7a35023c (MERGE-BIO SF1) is its last code commit.
        ("MERGE-COUNTED-INVENTED-Q", [countedMerge], "e7a35023c"),
        // RECORDS: d9939b95f and 2e44adecd fix the rows, and cc18a4e12 (RECORDS-BIO SF2) is its last code commit.
        ("TWELVES-IMPORT-REPLACES-RUN-RECORD", [twelveSReplaced], "cc18a4e12"),
        ("RECORDS-AFFECTED-OTHER-RESULT-TYPES", [runRecordReplaced], "cc18a4e12"),
        ("PAIRING-RECORD-LOST", [extractionDropped], "cc18a4e12"),
        // CKPT-DEPTH: 0019e8379 fixes the row, and 4a76bce42 (CKPT-DEPTH-BIO SF2) is its last code commit.
        ("TTL-ONT-CHECKPOINT-REUSE", [checkpointReuse], "4a76bce42"),
    ]

    /// The kinds of lane m2 by raw value, none of which exists at its base.
    private static let planRun = "fastqDemultiplexPlanRun"
    private static let countedMerge = "fastqCountedMerge"
    private static let twelveSReplaced = "twelveSRunRecordReplaced"
    private static let runRecordReplaced = "resultRunRecordReplaced"
    private static let extractionDropped = "fastqIngestDroppedExtractionRecord"
    private static let checkpointReuse = "genotypeCheckpointReuse"
    private static let m2Kinds = [planRun, countedMerge, twelveSReplaced, runRecordReplaced, extractionDropped, checkpointReuse]

    private static let sweepIDs = Set(expected.map(\.id))

    /// The rows of this lane that each kind holds at a build without the fixes, in table order. Every other kind holds none.
    private static let held: [String: [String]] = [
        legacyCleanup: ["TT-LEGACY-CLEANUP-REMOVES-TOP"],
        "taxTriage": ["TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK"],
        "naoMgs": ["NAOMGS-DEDUP-READ-COUNT", "BLAST-NAME-PHRASE-LEAK"],
        "esViritu": ["BLAST-NAME-PHRASE-LEAK"],
        "nvd": ["BLAST-NAME-PHRASE-LEAK"],
        "kraken2": ["BLAST-NAME-PHRASE-LEAK"],
        planRun: ["DEMUXPLAN-LIMITS-S3-GROUP"],
        "fastqTrim": ["DERIVED-STATS-PRESTORAGE"],
        countedMerge: ["MERGE-COUNTED-INVENTED-Q"],
        twelveSReplaced: ["TWELVES-IMPORT-REPLACES-RUN-RECORD"],
        runRecordReplaced: ["RECORDS-AFFECTED-OTHER-RESULT-TYPES"],
        extractionDropped: ["PAIRING-RECORD-LOST"],
        checkpointReuse: ["TTL-ONT-CHECKPOINT-REUSE"],
    ]

    /// Every kind by raw value, the narrower kinds of m1 and m2 included where they do not exist yet.
    private static var kinds: [String] {
        let all = AffectedResultKind.allCases.map(\.rawValue)
        return all + ([legacyCleanup] + m2Kinds).filter { !all.contains($0) }
    }

    /// This lane's rows that the build `appVersion` names hold for the kind of raw value `kind`, or nil for no such kind.
    private func ids(_ appVersion: String?, _ kind: String) -> [String]? {
        AffectedResultKind(rawValue: kind).map {
            AffectedResults.rows(forAppVersion: appVersion, kind: $0).map(\.backlogID).filter(Self.sweepIDs.contains)
        }
    }

    /// This lane's rows that the result `record` records shows as a result of `kind`, as the Inspector and the strip ask.
    private func shown(_ record: ProvenanceEnvelope, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(for: record, kind: kind).map(\.backlogID).filter(Self.sweepIDs.contains)
    }

    /// The root record `lungfish build-db taxtriage` writes in a result folder that holds no record of another workflow,
    /// an older run or an import (`BuildDbCommand+Provenance.swift`, `buildDbReplayArgv` and `buildDbExplicitOptions`).
    private func buildDbRecord(_ flags: [String], appVersion: String = "Lungfish 2026.11.16 (14223)") -> ProvenanceEnvelope {
        let name = "lungfish build-db taxtriage"
        var record = ProvenanceEnvelope.fixture(
            workflowName: name, toolName: name,
            argv: ["lungfish-cli", "build-db", "taxtriage", "/Project/Analyses/taxtriage-2026-11-01"] + flags
        )
        record.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: appVersion)
        if flags.contains("--no-cleanup") { record.options = ProvenanceOptions(explicit: ["noCleanup": .boolean(true)]) }
        return record
    }

    func testEachRowNamesItsKindsBuildsAndFix() {
        for (id, kinds, fix) in Self.expected {
            let row = AffectedResults.rows.first { $0.backlogID == id }
            XCTAssertEqual(row?.kinds.map(\.rawValue), kinds, id)
            XCTAssertEqual(row.map(\.firstBuild), .some(nil), "\(id): no source lane names the commit that brought it in")
            XCTAssertEqual(row?.lastBuild, 14223, "\(id): Preview 2026.11.16 is the newest build without the fix")
            XCTAssertEqual(row?.fixCommit, fix, id)
        }
    }

    func testBuilds14223And14072OfEachKindShowItsRowsAndNoLaterBuildDoes() {
        for kind in Self.kinds {
            let held = Self.held[kind] ?? []
            XCTAssertEqual(ids("Lungfish 2026.11.16 (14223)", kind), held, "\(kind) at Preview 2026.11.16")
            XCTAssertEqual(ids("Lungfish 2026.11.15 (14072)", kind), held, "\(kind) at Preview 2026.11.15")
            XCTAssertEqual(ids("Lungfish 2026.11.14 (13927)", kind), held, "\(kind) at Stable 2026.11.14, a patch build")
            XCTAssertEqual(ids("Lungfish 2026.8.1 (4192)", kind), held, "\(kind) at 2026.8.1, the first published build")
            XCTAssertEqual(ids("Lungfish 2026.11.17 (14224)", kind), [], "\(kind) at the first build with every fix")
        }
    }

    func testARecordThatNamesNoBuildNumberShowsNone() {
        for kind in Self.kinds {
            for appVersion in ["Lungfish 2026.11.16 (dev)", "Lungfish 2026.11.16", "Lungfish fixture", "", nil] {
                XCTAssertEqual(ids(appVersion, kind), [], "\(kind) at \(appVersion ?? "nil")")
            }
        }
        XCTAssertEqual(shown(buildDbRecord(["--force"], appVersion: "Lungfish 2026.11.16 (dev)"), .taxTriage), [])
    }

    /// TT-m1, Affected facts. An older run or an import that a build up to 14223 rebuilt without `--no-cleanup` lost its
    /// `top/` folder, and its root record is that build's `lungfish build-db taxtriage` record. Its TaxTriage result shows
    /// the row beside the rows of every TaxTriage result.
    func testAResultTheLegacyCleanupRebuiltShowsTheTopRowBesideItsTaxTriageRows() {
        for flags in [["--force"], [], ["--force", "--format", "json"]] {
            let legacy = buildDbRecord(flags)
            XCTAssertEqual(AffectedResults.kind(of: legacy)?.rawValue, Self.legacyCleanup, "\(flags)")
            XCTAssertEqual(shown(legacy, .taxTriage),
                           ["TT-LEGACY-CLEANUP-REMOVES-TOP", "TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK"], "\(flags)")
        }
        let older = AffectedResults.rows(for: buildDbRecord(["--force"], appVersion: "Lungfish 2026.10.29 (12045)"),
                                         kind: .taxTriage).map(\.backlogID)
        XCTAssertEqual(older.contains("TTREADS"), true, "an older TaxTriage row stays")
        XCTAssertEqual(older.contains("TT-LEGACY-CLEANUP-REMOVES-TOP"), true)
        XCTAssertEqual(shown(buildDbRecord(["--force"], appVersion: "Lungfish 2026.11.17 (14224)"), .taxTriage), [])
    }

    /// A rebuild with `--no-cleanup` (the app's recount from TT-m1 on), a failed rebuild and the result of an executor run,
    /// whose root record names `lungfish.taxtriage.run` and whose cleanup always kept `top/`, show no top row.
    func testAResultWhoseTopNoBuildRemovedShowsNoTopRow() {
        let kept = buildDbRecord(["--force", "--no-cleanup"])
        XCTAssertEqual(AffectedResults.kind(of: kept), nil)
        XCTAssertEqual(shown(kept, .taxTriage), ["TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK"])

        var failed = buildDbRecord(["--force"])
        failed.status = .failed
        XCTAssertEqual(AffectedResults.kind(of: failed), nil)
        XCTAssertEqual(shown(failed, .taxTriage), ["TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK"])

        var executor = ProvenanceEnvelope.fixture(
            workflowName: TaxTriageAnalysisRunTool.workflowName, toolName: "taxtriage", argv: ["nextflow", "run"]
        )
        executor.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.16 (14223)")
        XCTAssertEqual(AffectedResults.kind(of: executor), nil)
        XCTAssertEqual(shown(executor, .taxTriage), ["TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK"])
    }

    /// The narrower kind adds its row to a TaxTriage result only, so a NAO-MGS result keeps its own rows.
    func testTheTopRowJoinsNoOtherKind() {
        let legacy = buildDbRecord(["--force"])
        XCTAssertEqual(shown(legacy, .naoMgs), ["NAOMGS-DEDUP-READ-COUNT", "BLAST-NAME-PHRASE-LEAK"])
        XCTAssertEqual(shown(legacy, .esViritu), ["BLAST-NAME-PHRASE-LEAK"])
    }

    /// BIO-BLAST ruling D gives the sentence and what to do, and UX-BLAST-NOTAX item 11 keeps them for a result saved
    /// before `judgedAt` and a Kraken 2 result judged on its report's tree alone.
    func testTheBlastRowSaysRulingDsWords() {
        let row = AffectedResults.rows.first { $0.backlogID == "BLAST-NAME-PHRASE-LEAK" }
        XCTAssertEqual(row?.sentence, "A Verify with BLAST… badge that an earlier version saved on this result could count a "
            + "read as supporting when its best match was a record of another species whose name holds the row's name, "
            + "such as Woolly monkey hepatitis B virus on a Hepatitis B virus row.")
        XCTAssertEqual(row?.whatToDo, "With NCBI Taxonomy installed, run Verify with BLAST… again on any row that read "
            + "Supported or Mixed.")
    }

    /// COUNTS, Affected facts. `lungfish markdup` writes its totals only to standard output, and no bundle or record holds
    /// them, so MARKDUP-COUNTS-RECORDS has no row.
    func testNoMarkdupRow() {
        XCTAssertEqual(AffectedResults.rows.filter { $0.backlogID.hasPrefix("MARKDUP") }.map(\.backlogID), [])
    }

    // MARK: - Lane AFFECTED-S1 m2

    /// A record of `root` that a build names at its root, by default Preview 2026.11.16 (14223).
    private func record(
        _ root: String, steps: [ProvenanceStep] = [], options: [String: ParameterValue] = [:],
        appVersion: String = "Lungfish 2026.11.16 (14223)"
    ) -> ProvenanceEnvelope {
        var record = ProvenanceEnvelope.fixture(workflowName: root, toolName: root, argv: ["lungfish-cli"])
        record.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: appVersion)
        record.steps = steps
        record.options = ProvenanceOptions(explicit: options)
        return record
    }

    private func step(_ tool: String, _ argv: [String] = []) -> ProvenanceStep {
        ProvenanceStep(toolName: tool, toolVersion: "1.0", argv: argv, exitStatus: 0)
    }

    /// This lane's rows that `record` shows as a result of the kind of raw value `kind`, or nil for no such kind.
    private func shown(_ record: ProvenanceEnvelope, _ kind: String) -> [String]? {
        AffectedResultKind(rawValue: kind).map { shown(record, $0) }
    }

    /// The rows the kind `kind(of:)` reads from `record` shows, or nil when the record is no kind.
    private func shownByItsKind(_ record: ProvenanceEnvelope) -> [String]? {
        AffectedResults.kind(of: record).map { shown(record, $0) }
    }

    /// DEMUX, Affected facts K5, and BIO-DEMUX item 11. Demultiplex… of the Demux tab writes its definition as
    /// `<dataset> demux plan <12 hex>.csv` in `<project>/Barcode Definitions/` (`FASTQDemultiplexPlanLaunch.swift:165`),
    /// and the run keeps a copy of that name in its folder, which `kit` and `customBarcodeKit` name
    /// (`FastqCommand.swift:385-386`, `:450`). The record shows the row beside the rows of its own demultiplexing kind.
    func testADemultiplexRunAPlanStartedShowsThePlanRowBesideItsOwnKind() {
        let kept = "/Project/reads-demux/reads demux plan 0123456789ab.csv"
        let plan = record("lungfish fastq demultiplex",
                          options: ["kit": .string(kept), "customBarcodeKit": .file(URL(fileURLWithPath: kept))])
        XCTAssertEqual(AffectedResults.kind(of: plan)?.rawValue, "fastqDemultiplex")
        XCTAssertEqual(shown(plan, .fastqDemultiplex), ["DEMUXPLAN-LIMITS-S3-GROUP"])
        XCTAssertEqual(shown(plan, .fastqDemultiplexSaturatedKit), ["DEMUXPLAN-LIMITS-S3-GROUP"], "a narrower kind")
        let definition = "/Project/Barcode Definitions/reads demux plan 0123456789ab.csv"
        XCTAssertEqual(shown(record("lungfish fastq demultiplex", options: ["kit": .string(definition)]), .fastqDemultiplex),
                       ["DEMUXPLAN-LIMITS-S3-GROUP"], "the definition in the project, before the run kept a copy")
        for other in ["/Project/Barcode Definitions/My kit.csv", "/Project/reads demux plan 0123.csv",
                      "/Project/reads demux plan 0123456789ab.tsv", "truseq-ht-dual"] {
            let notAPlan = record("lungfish fastq demultiplex", options: ["kit": .string(other)])
            XCTAssertEqual(shown(notAPlan, .fastqDemultiplex), [], other)
        }
        let later = record("lungfish fastq demultiplex", options: ["kit": .string(kept)],
                           appVersion: "Lungfish 2026.11.17 (14224)")
        XCTAssertEqual(shown(later, .fastqDemultiplex), [])
    }

    /// QUALITY, Affected facts, and BIO-QUALITY Q4. A FASTQ operation's bundle names no kind but a trim's, so the row names
    /// `.fastqTrim` and its words say "if the reads held scores of 0 or 1".
    func testATrimBundleShowsTheStoredStatisticsRow() {
        XCTAssertEqual(shownByItsKind(record("lungfish fastq trim")), ["DERIVED-STATS-PRESTORAGE"])
        XCTAssertEqual(shownByItsKind(record("lungfish fastq adapter-trim")), ["DERIVED-STATS-PRESTORAGE"])
        XCTAssertEqual(shownByItsKind(record("lungfish fastq trim", appVersion: "Lungfish 2026.11.17 (14224)")), [])
    }

    /// BIO-MERGE Q3. Every app merge up to 14223 recorded the step `lungfish fastq merge count-duplicates` under the root
    /// `lungfish fastq merge` (`FastqCommand+Provenance.swift:210`, `:241`). `AffectedResultsS1SweepRecordTests` pins the
    /// kind against the records the CLI's two writers make.
    func testACountedMergeShowsTheMergeRowAndAnUncountedMergeIsNoKind() {
        let counted = record("lungfish fastq merge", steps: [step("bbmerge"), step("lungfish fastq merge count-duplicates")])
        XCTAssertEqual(AffectedResults.kind(of: counted)?.rawValue, Self.countedMerge)
        XCTAssertEqual(shownByItsKind(counted), ["MERGE-COUNTED-INVENTED-Q"])
        let uncounted = record("lungfish fastq merge", steps: [step("bbmerge"), step("lungfish fastq merge concatenate")])
        XCTAssertEqual(AffectedResults.kind(of: uncounted)?.rawValue, nil)
    }

    /// RECORDS, Affected facts 1, and RECORDS-BIO R4. Up to 14223 a sample metadata import wrote its own root record,
    /// `Sample metadata import`, over the record of the run that stood in the result. The 12S kind comes from the sidebar
    /// type (`ProvenanceInspectorAffectedTests`), and a TaxTriage, EsViritu, Kraken 2 or NAO-MGS result whose record is the
    /// import's shows the other-type row beside its own rows. NVD takes no metadata import, and a FASTQ bundle or a folder
    /// that held no record got the import's record as its first, so the record alone is no kind.
    func testAResultWhoseRecordAMetadataImportReplacedShowsTheReplacedRecordRow() {
        let imported = record("Sample metadata import")
        XCTAssertEqual(shown(imported, Self.twelveSReplaced), ["TWELVES-IMPORT-REPLACES-RUN-RECORD"])
        XCTAssertEqual(shown(imported, .taxTriage),
                       ["TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK", "RECORDS-AFFECTED-OTHER-RESULT-TYPES"])
        XCTAssertEqual(shown(imported, .esViritu), ["BLAST-NAME-PHRASE-LEAK", "RECORDS-AFFECTED-OTHER-RESULT-TYPES"])
        XCTAssertEqual(shown(imported, .kraken2), ["BLAST-NAME-PHRASE-LEAK", "RECORDS-AFFECTED-OTHER-RESULT-TYPES"])
        XCTAssertEqual(shown(imported, .naoMgs),
                       ["NAOMGS-DEDUP-READ-COUNT", "BLAST-NAME-PHRASE-LEAK", "RECORDS-AFFECTED-OTHER-RESULT-TYPES"])
        XCTAssertEqual(shown(imported, .nvd), ["BLAST-NAME-PHRASE-LEAK"])
        XCTAssertEqual(AffectedResults.kind(of: imported)?.rawValue, nil)
        XCTAssertEqual(shown(record("lungfish.esviritu.run"), .esViritu), ["BLAST-NAME-PHRASE-LEAK"], "the run's own record")
        XCTAssertEqual(shown(record("Sample metadata import", appVersion: "Lungfish 2026.11.17 (14224)"), .esViritu), [])
    }

    /// RECORDS, Affected facts 2, and RECORDS-BIO R4. The row needs all four facts: the root of the taxa collection
    /// (`ExtractTaxaCollectionCommand.swift:202`), an ingest step (`FastqIngestSubcommand.swift:246`), `deleteOriginals`
    /// true (`:199`) and no extraction step (`TaxonomyExtractionPipeline.swift:448`).
    func testAnInPlaceIngestThatRemovedTheTaxonFilesOriginalShowsThePairingRow() {
        let root = "lungfish extract taxa-collection"
        let ingest = step("FASTQIngestionPipeline", ["lungfish-cli", "fastq", "ingest", "HSV-1_taxid10298.fastq"])
        let removed: [String: ParameterValue] = ["deleteOriginals": .boolean(true)]
        let dropped = record(root, steps: [ingest], options: removed)
        XCTAssertEqual(AffectedResults.kind(of: dropped)?.rawValue, Self.extractionDropped)
        XCTAssertEqual(shownByItsKind(dropped), ["PAIRING-RECORD-LOST"])
        let kept = record(root, steps: [ingest], options: ["deleteOriginals": .boolean(false)])
        let carried = record(root, steps: [step("TaxonomyExtractionPipeline"), ingest], options: removed)
        let download = record("SRA download", steps: [ingest], options: removed)
        let noIngest = record(root, options: removed)
        for (name, other) in [("kept", kept), ("carried", carried), ("download", download), ("no ingest", noIngest)] {
            XCTAssertEqual(AffectedResults.kind(of: other)?.rawValue, nil, name)
        }
        // A pair ingested in place keeps the loose-pair kind of FIX-ROUTES-7 and shows the row beside its rows.
        let pair = step("FASTQIngestionPipeline", ["lungfish-cli", "fastq", "ingest", "R1.fastq", "--pair", "R2.fastq"])
        let pairDropped = record(root, steps: [pair], options: removed)
        XCTAssertEqual(AffectedResults.kind(of: pairDropped)?.rawValue, "fastqIngestLoosePair")
        XCTAssertEqual(shownByItsKind(pairDropped), ["PAIRING-RECORD-LOST"])
    }

    /// CKPT-DEPTH-BIO SF1. The `toolName` of the reuse step (`FullLengthONTMHCGenotypingPipeline+Checkpoints.swift:443`)
    /// marks the record, never its argv, whose first word is `lungfish-cli` and whose subcommand the CLI does not have.
    func testAGenotypeResultThatReusedASampleShowsTheCheckpointRow() {
        let root = "lungfish fastq full-length-ont-mhc-genotype"
        let argv = ["lungfish-cli", "fastq", "full-length-ont-mhc-genotype", "reuse-sample-checkpoint", "DL46",
                    "--checkpoint", "/Project/DL46.checkpoint.json"]
        let reused = record(root, steps: [step("savont"), step("lungfish full-length ONT MHC sample checkpoint reuse", argv)])
        XCTAssertEqual(AffectedResults.kind(of: reused)?.rawValue, Self.checkpointReuse)
        XCTAssertEqual(shownByItsKind(reused), ["TTL-ONT-CHECKPOINT-REUSE"])
        XCTAssertEqual(AffectedResults.kind(of: record(root, steps: [step("savont")]))?.rawValue, nil, "no reuse")
        XCTAssertEqual(AffectedResults.kind(of: record(root, steps: [step("lungfish-cli", argv)]))?.rawValue, nil, "argv")
        XCTAssertEqual(shown(record(root, steps: reused.steps, appVersion: "Lungfish 2026.11.17 (14224)"),
                             Self.checkpointReuse), [])
    }

    /// The words of the brief, with BIO-MERGE Q3 for the merge and RECORDS-BIO R4's "may have dropped" for the pairing.
    func testTheRowsOfM2SayTheirRulingsWords() {
        let words: [String: (sentence: String, whatToDo: String)] = [
            "DEMUXPLAN-LIMITS-S3-GROUP": (
                "This run used the kit's barcode sequences and the default Min Overlap and Allow Indels, whatever the "
                    + "Demux tab showed.",
                "If you changed any of them, demultiplex again from the tab."),
            "DERIVED-STATS-PRESTORAGE": (
                "Mean Q and the quality charts describe the reads before Lungfish stored them, which raised every score of "
                    + "0 or 1 to 2, so if the reads held scores of 0 or 1, they can read a little lower than the stored "
                    + "reads, while Q20 and Q30 are not changed.",
                "Run the operation again to measure the stored reads."),
            "MERGE-COUNTED-INVENTED-Q": (
                "The version that made these merged reads kept one copy of each read sequence and wrote a quality score of "
                    + "40 on every base in place of the scores bbmerge and the sequencer gave, so the quality shown for them, "
                    + "and any trimming or filtering by quality, used scores no instrument measured, reads that did not merge "
                    + "lost their mate pairing, and each copy stands for several reads that later steps count once.",
                "Merge the original read pairs again with this version, and redo any trimming, filtering, assembly, mapping "
                    + "or variant calling that used these merged reads."),
            "TWELVES-IMPORT-REPLACES-RUN-RECORD": (
                "A sample metadata import replaced this bundle's record of its 12S run, so its command, times and tool "
                    + "versions are gone.",
                "Run the 12S matching again for a full record."),
            "RECORDS-AFFECTED-OTHER-RESULT-TYPES": (
                "A sample metadata import replaced the run's record of this result.",
                "Run the analysis again for a full record."),
            "PAIRING-RECORD-LOST": (
                "Ingesting this file in place may have dropped the record of the extraction it came from, with the source "
                    + "file, its digest and the per-taxon counts.",
                "Extract the reads again if you need that record."),
            "TTL-ONT-CHECKPOINT-REUSE": (
                "A sample reused from saved results could hold files that a later run with other settings, stopped part "
                    + "way, had overwritten, so its calls may not match this run's settings.",
                "Run the genotyping again without reusing earlier results."),
        ]
        for (id, expected) in words.sorted(by: { $0.key < $1.key }) {
            let row = AffectedResults.rows.first { $0.backlogID == id }
            XCTAssertEqual(row?.sentence, expected.sentence, id)
            XCTAssertEqual(row?.whatToDo, expected.whatToDo, id)
        }
    }
}
