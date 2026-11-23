// AffectedResults+LoosePairs.swift - The affected rows of the S1 fixes of sub-phase 5.6 and the kinds they name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension AffectedResults.RecordName {
    /// `lungfish map`, the canonical record of a mapping (`MappingProvenance.swift:403`).
    public static let map = "lungfish map"
    /// The record of a CZ ID taxon report import, from the command line or the import window
    /// (`CzIdDataConverter.swift:476`).
    public static let czIdImport = "CZ-ID Import"
    /// The root record of the adopt of an RNA-seq plan counts (`ExecutorRunAdoption+RNASeqRecord.swift:31`). It names no read file.
    public static let rnaSeqAdopt = "RNA-seq adopt"
    /// `lungfish fastq ingest`, a completed or cancelled run (`FastqIngestSubcommand+Run.swift:380`).
    public static let fastqIngest = "lungfish fastq ingest"
    /// `lungfish fastq ribodetector` (`FastqRiboDetectorSubcommand.swift:327`).
    public static let fastqRiboDetector = "RiboDetector FASTQ filter"
    /// `lungfish fastq deacon-ribo` (`FastqDeaconRiboSubcommand.swift:379`).
    public static let fastqDeaconRibo = "Deacon rRNA FASTQ filter"
}

extension AffectedResults {
    /// The rows of the S1 fixes of sub-phase 5.6 (`docs/reports/2026.11.16-technical.md`, S1 and S2 results). No
    /// published build holds any of them, so each ends at Preview 2026.11.15 (14072), and Stable 2026.11.14, a patch build
    /// stamped 13927, lacks each too. No record names a commit that brought a fault in after 2026.8.1, so none has a
    /// first build.
    static let loosePairAndImportRows: [AffectedResultRow] = [
        // TT-PAIR fixed the TaxTriage dialog (cf12d6ba7 to 91f863bd7) and TT-GROUP the grouper behind the Classification
        // and EsViritu dialogs and both --batch commands (4d19103d6 to 61acb5bfc), two of the three kinds, so the row
        // names TT-GROUP's last fix commit, its BIO B1 fold.
        AffectedResultRow(
            backlogID: "TAXTRIAGE-BUNDLE-NAMES-PAIRED", kinds: [.taxTriage, .kraken2, .esViritu], firstBuild: nil,
            lastBuild: 14072,
            sentence: "If this run used FASTQ bundles named like Swab_1 and Swab_2, the old version could treat them as "
                + "the two reads of one sample and skip a third input named Swab.",
            whatToDo: "Run those samples again with this version, which runs each bundle as its own sample.",
            fixCommit: "61acb5bfc"
        ),
        // FIX-A pairs loose mates only within one folder in `classify --batch` and `esviritu detect --batch`.
        AffectedResultRow(
            backlogID: "GROUPER-CROSS-FOLDER-PAIR", kinds: [.kraken2, .esViritu], firstBuild: nil, lastBuild: 14072,
            sentence: "If this command-line batch used read files with the same name from two folders, the old version "
                + "could pair R1 from one folder with R2 from the other.",
            whatToDo: "Run the batch again with this version, which pairs files only within one folder.",
            fixCommit: "d998a3371"
        ),
        // FIX-B (1bebe79ce to 6c437e707) refuses a short mate on TaxTriage, Kraken 2 and EsViritu, and FIX-ROUTES
        // (c9ed8e3ef) on map, assembly and Viral Recon's sample sheet. Each fixes three of the kinds, and
        // FIX-ROUTES reaches one route more and lands last, so the row names it. FIX-ROUTES-2 (ab7520464) refuses a cut
        // pair before the recipe of an import, whose fastp pairs two files by position and leaves equal counts that no
        // later check sees, so the row holds the recipe import. The import with no recipe refused unequal counts after
        // its tools (BIO-ROUTES-3 D1), so the row leaves that kind out.
        // FIX-ROUTES-6 (51f0f3f8f) refuses both on `fastq ingest --pair`, `fastq ribodetector` and `fastq deacon-ribo` (BIO-ROUTES-5).
        AffectedResultRow(
            backlogID: "LOOSE-PAIR-SHORT-MATE",
            kinds: [
                .taxTriage, .kraken2, .esViritu, .mappingLoosePair, .assembly, .viralRecon, .fastqRecipeImport,
                .rnaSeqPlanRun, .fastqRiboFilterLoosePair,
            ],
            firstBuild: nil, lastBuild: 14072,
            sentence: "If this result used separate R1 and R2 files, the old version did not check for equal read "
                + "counts, so it could skip reads or pair them with the wrong mates.",
            whatToDo: "If the read counts differ, rerun the analysis with this version, which stops and reports the "
                + "mismatch.",
            fixCommit: "c9ed8e3ef"
        ),
        // FIX-B2 (543d4ea73 to 1c936647b) on TaxTriage, Kraken 2 and EsViritu, FIX-ROUTES (c9ed8e3ef) on map, assembly and
        // Viral Recon, FIX-ROUTES-2 (ab7520464) on the import with a recipe, and FIX-ROUTES-4 (cccc812a2) on the
        // import with no recipe and on executor plans (BIO-ROUTES-3 D1 and D2). FIX-B2 and FIX-ROUTES fix three kinds
        // each, so the row names FIX-ROUTES, as LOOSE-PAIR-SHORT-MATE does.
        // FIX-ROUTES-6 (51f0f3f8f) refuses both on `fastq ingest --pair`, `fastq ribodetector` and `fastq deacon-ribo` (BIO-ROUTES-5).
        AffectedResultRow(
            backlogID: "LOOSE-PAIR-OUT-OF-STEP",
            kinds: [
                .taxTriage, .kraken2, .esViritu, .mappingLoosePair, .assembly, .viralRecon, .fastqRecipeImport,
                .fastqLoosePairImport, .fastqIngestLoosePair,
                .rnaSeqPlanRun, .fastqRiboFilterLoosePair,
            ],
            firstBuild: nil, lastBuild: 14072,
            sentence: "If this result used separate R1 and R2 files with equal read counts but different read orders, "
                + "the old version paired reads by position, so reads from different fragments could be treated as "
                + "mates.",
            whatToDo: "If the files may have been sorted or subsampled separately, import them again or rerun the "
                + "analysis with this version, which checks that each pair's read names match.",
            fixCommit: "c9ed8e3ef"
        ),
        // FIX-CZID (22dd9eb14) with its folds e2f7f342c and f58ecdaae, in `cz-id import`, `import cz-id` and the window.
        AffectedResultRow(
            backlogID: "CZID-REAL-EXPORT-FORMAT", kinds: [.czIdImport], firstBuild: nil, lastBuild: 14072,
            sentence: "If this result came from a CZ ID report table saved as a tab file, the old version gave every "
                + "taxon 0 reads and rank U.",
            whatToDo: "Import the CZ ID report again with this version, which reads CSV or tab report tables, then "
                + "remove this result.",
            fixCommit: "f58ecdaae"
        ),
    ]

    /// Whether an import record names two loose files as `r1` and `r2` (`FASTQBatchImporter.provenanceParameters`),
    /// which a plan's returned record keeps too. One file records `r2` as null.
    static func importedTwoLooseFiles(_ envelope: ProvenanceEnvelope) -> Bool {
        let explicit = envelope.options.explicit
        guard case .file(let r1)? = explicit["r1"], case .file(let r2)? = explicit["r2"] else { return false }
        return liesInNoBundle(r1.path) && liesInNoBundle(r2.path)
    }

    /// Whether a `lungfish fastq ingest` record names an R2 as `pair` beside its `input`, both outside any bundle
    /// (`FastqIngestSubcommand.swift:194-195`). One file records `pair` as null.
    static func ingestedTwoLooseFiles(_ envelope: ProvenanceEnvelope) -> Bool {
        let explicit = envelope.options.explicit
        guard case .file(let r1)? = explicit["input"], case .file(let r2)? = explicit["pair"] else { return false }
        return liesInNoBundle(r1.path) && liesInNoBundle(r2.path)
    }

    /// Whether a record that is not a `lungfish fastq ingest` record holds the step of one that read two files with `--pair`.
    /// An in-place ingest merges into the record that stands in the folder, such as a download. The merge keeps the root name
    /// of that record and lets the options of the later ingest win (`InPlaceIngestionProvenance.swift:42`), so a later
    /// one-file ingest in the folder records `pair` as null over the earlier pair. The earlier ingest stays as its step,
    /// `FASTQIngestionPipeline` with `--pair` in its argv (`FastqIngestSubcommand+Run.swift:347-351`), and the step alone
    /// decides (BIO-ROUTES-5 item 4).
    static func mergedIngestOfTwoLooseFiles(_ envelope: ProvenanceEnvelope) -> Bool {
        envelope.steps.contains { step in
            step.toolName == "FASTQIngestionPipeline" && step.argv.contains("--pair")
        }
    }

    /// Whether a RiboDetector or Deacon rRNA record names exactly two input files, both outside any bundle
    /// (`FastqRiboDetectorSubcommand.swift:307`, `FastqDeaconRiboSubcommand.swift:382`). One file, an interleaved file
    /// or a bundle is no kind.
    static func filteredTwoLooseFiles(_ envelope: ProvenanceEnvelope) -> Bool {
        guard case .array(let inputs)? = envelope.options.explicit["inputs"], inputs.count == 2 else { return false }
        return inputs.allSatisfy { value in
            guard case .file(let file) = value else { return false }
            return liesInNoBundle(file.path)
        }
    }

    /// Whether a mapping record bound its reads as a pair (`pairedEnd`) from exactly two input files that lie in no
    /// bundle. The reference has its own role, and a bundle's files lie in the bundle.
    static func mappedTwoLooseFiles(_ envelope: ProvenanceEnvelope) -> Bool {
        guard case .boolean(true)? = envelope.options.explicit["pairedEnd"] else { return false }
        let reads = envelope.files.filter { $0.role == .input }.map(\.path)
        return reads.count == 2 && reads.allSatisfy(liesInNoBundle)
    }

    /// Whether `path` lies in no `.lungfishfastq` bundle, read from the text alone, since a record can name files that
    /// are gone.
    static func liesInNoBundle(_ path: String) -> Bool {
        !path.split(separator: "/").contains { $0.lowercased().hasSuffix(".lungfishfastq") }
    }
}
