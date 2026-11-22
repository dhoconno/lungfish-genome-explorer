// AffectedResults.swift - The results an earlier build made wrong, found from the build a record names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The kind of result a row of ``AffectedResults/rows`` speaks about.
public enum AffectedResultKind: String, CaseIterable, Sendable {
    case taxTriage
    case esViritu
    case kraken2
    case naoMgs
    case nvd
    case assembly
    case viralRecon
    case variantCalls
    case fastqTrim
    /// A FASTQ bundle made by an import that ran a recipe's fastp step.
    case fastqRecipeImport
    /// A sample bundle of a demultiplexing run, or the run's folder. A kind of result the record names, never a type of
    /// the sidebar.
    case fastqDemultiplex
    /// The reads that `lungfish extract reads --by-classifier` took from a TaxTriage result, a FASTQ file or bundle. A
    /// kind of result the record names, never a type of the sidebar.
    case taxTriageReadExtraction
    /// A demultiplexing run that searched the read bases with Cutadapt and a kit whose barcodes are so short that half of
    /// all reads or more match one by chance, the kit the chance floor cannot judge (DEMUX-FLOOR-SATURATED-KIT). It is a
    /// narrower ``fastqDemultiplex``, so every row of that kind names it too.
    case fastqDemultiplexSaturatedKit
    /// A demultiplexing run of Exact Bare Barcode whose input's read names carry two or more of the kit's barcodes, so it
    /// searched the read sequences for barcodes that sat in the names (DEMUX-EXACT-BARE-NO-FLOOR, the names case). It is a
    /// narrower ``fastqDemultiplex``, so every row of that kind names it too.
    case fastqDemultiplexExactBareNames
    /// A demultiplexing run that searched the two barcodes of a custom dual-index definition at Both Ends with no sample
    /// sheet with Cutadapt anywhere in each read, so reads with no barcode could land in a sample by chance
    /// (DEMUX-DUAL-UNANCHORED, BIO-DUAL-ANCHOR items 7 and 12). It is a narrower ``fastqDemultiplex``, so every row of that
    /// kind names it too.
    case fastqDemultiplexDualSearchedAnywhere
    /// A demultiplexing run that searched the two barcodes of a custom dual-index definition with no sample sheet at 5' End
    /// or 3' End with Cutadapt, so one barcode of each pair was free and the other strand was searched as the swapped pair,
    /// and reads from the reverse strand were left unassigned (DEMUX-DUAL-BARE-REVERSE, BIO-BARE-REVERSE items 5 and 6). It
    /// is a narrower ``fastqDemultiplex``, so every row of that kind names it too.
    case fastqDemultiplexDualOneEnd
    /// A demultiplexing run of a custom dual-index definition at Both Ends with no sample sheet that read each secondary
    /// sequence as written, in a definition with two rows whose first barcodes match and whose secondary sequences are
    /// reverse complements, each within the error rate, so a file that lists the i5 primer's barcodes put each row's reads
    /// in the other (DEMUX-DUAL-FORM, BIO-DUAL-FORM item 5). It is a narrower ``fastqDemultiplexDualSearchedAnywhere``, so
    /// every row of that kind names it too.
    case fastqDemultiplexDualFormSwap
    /// A demultiplexing run of a single-index kit, TruSeq Single Index Set A or B or a Custom Definition with one sequence
    /// a row, on a platform that reads one strand, that searched its barcodes at offsets up to a 5' or 3' Distance above 0
    /// with Cutadapt, whose rank put some reads in another sample (DEMUX-SINGLE-OFFSET-SHIFT, BIO-SINGLE-OFFSET item 3). It
    /// is a narrower ``fastqDemultiplex``, so every row of that kind names it too.
    case fastqDemultiplexSingleOffset
    /// A demultiplexing run of the built-in TruSeq HT Dual Index or Nextera XT Index Kit v2 kit, or of a definition made on
    /// one of them or on IDT for Illumina UD Indexes, that searched its index pairs at Both Ends at offsets up to a 5' or 3'
    /// Distance above 0 with Cutadapt, whose rank put some reads in another sample (DEMUX-LINKED-OFFSET-SHIFT,
    /// BIO-LINKED-OFFSET item 3). It is a narrower ``fastqDemultiplex``, so every row of that kind names it too.
    case fastqDemultiplexBuiltInDualOffset
    /// A demultiplexing run of the built-in TruSeq HT Dual Index or Nextera XT Index Kit v2 kit, or of a definition made on
    /// one of them or on IDT for Illumina UD Indexes, at Both Ends whose Cutadapt wrote `{name}.fastq.gz` with each row on
    /// two lines, so each row's output past about 202 KB of gzip lost every read (DEMUX-SHARED-NAME-GZIP,
    /// BIO-SHARED-NAME-GZIP item 3). It is a narrower ``fastqDemultiplex``, so every row of that kind names it too.
    case fastqDemultiplexSharedNameGzip
    /// A mapping whose record names two loose read files, outside any `.lungfishfastq` bundle, bound as R1 and R2, which
    /// the mapper paired by position (LOOSE-PAIR-SHORT-MATE, LOOSE-PAIR-OUT-OF-STEP). A mapping of one file, of files
    /// mapped as single reads or of a bundle is no kind.
    case mappingLoosePair
    /// A FASTQ bundle imported from two loose files recorded as R1 and R2, on this Mac or by a plan whose node returned
    /// the bundle (LOOSE-PAIR-OUT-OF-STEP). An import whose recipe let fastp guess the adapter pair is a
    /// ``fastqRecipeImport`` first, even of two loose files, so a row that speaks of the recipe import names both kinds.
    case fastqLoosePairImport
    /// A CZ ID taxon report imported as a result (CZID-REAL-EXPORT-FORMAT).
    case czIdImport
}

/// One fix of an S1 that an earlier build wrote into a result.
///
/// A result is affected when its record names a build from `firstBuild` to `lastBuild`. A build number is the count
/// of commits behind the commit the build was packaged from (`git rev-list --count HEAD`, the rule of `release.py`),
/// so the numbers order every build of the main line. `lastBuild` is the number of the newest published build that
/// lacks the whole fix, which is the build of the release before the first release that holds `fixCommit`, and
/// `fixCommit` is the last commit of the fix's lane. `firstBuild` is the number of the commit that brought the
/// defect in, or nil when the defect is older than any build number a row can name.
public struct AffectedResultRow: Identifiable, Equatable, Sendable {
    /// The backlog id, or the id of the row in the technical record of the release that fixed it.
    public let backlogID: String
    public let kinds: [AffectedResultKind]
    public let firstBuild: Int?
    public let lastBuild: Int
    /// What went wrong, in one sentence a bench scientist reads as it stands.
    public let sentence: String
    /// What a person does to get a right result.
    public let whatToDo: String
    public let fixCommit: String

    public var id: String { backlogID }

    /// The sentence and what to do, as the Inspector and the viewer's strip show them.
    public var words: String { sentence + " " + whatToDo }

    /// Whether a build from `firstBuild` to `lastBuild`, both included, holds the defect.
    public func holds(build: Int) -> Bool {
        build >= (firstBuild ?? 0) && build <= lastBuild
    }
}

/// The table of results that a fixed S1 left wrong in older projects, and the matcher that reads it.
///
/// Each fix of an S1 that an earlier build wrote into a result adds one row (`docs/contracts/SCOPE-AND-DELIVERY.md`,
/// Affected results). A result whose record names a build that a row holds shows that row's words in its viewer and
/// in the Inspector until it is made again by a build that no row holds. A record from a build with no number,
/// such as `Lungfish 2026.11.7 (dev)`, matches nothing, because no row can say whether that build holds a fix.
public enum AffectedResults {
    /// The build number in `Lungfish <version> (<build>)`, or nil for `dev`, a missing text or any other build text.
    public static func build(fromAppVersion appVersion: String?) -> Int? {
        guard let text = appVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !inside.isEmpty, inside.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(inside)
    }

    /// The rows for `kind` whose builds hold the build `appVersion` names, in table order.
    public static func rows(forAppVersion appVersion: String?, kind: AffectedResultKind) -> [AffectedResultRow] {
        guard let build = build(fromAppVersion: appVersion) else { return [] }
        return rows(forBuilds: build...build, kind: kind)
    }

    /// The rows for `kind` that hold every build in `builds`, in table order.
    public static func rows(forBuilds builds: ClosedRange<Int>, kind: AffectedResultKind) -> [AffectedResultRow] {
        rows.filter {
            $0.kinds.contains(kind) && $0.holds(build: builds.lowerBound) && $0.holds(build: builds.upperBound)
        }
    }

    /// The rows for `kind` that hold every build that may have made the result `envelope` records (``builds(of:)``).
    public static func rows(for envelope: ProvenanceEnvelope, kind: AffectedResultKind) -> [AffectedResultRow] {
        guard let builds = builds(of: envelope) else { return [] }
        return rows(forBuilds: builds, kind: kind)
    }

    /// The builds that may have made the result `envelope` records, or nil when no packaged build did.
    ///
    /// A record the app writes itself, such as a NAO-MGS or NVD import, names `Lungfish <version> (<build>)` at its
    /// root. The root record `AnalysisRunExecutor` writes for a Kraken 2, TaxTriage or EsViritu run, and an
    /// assembly's record, name only the bare `<version>`, and a `lungfish variants call` record names
    /// `lungfish-cli <version>`, which counts as the bare version. A build is believed when its version's builds hold it
    /// (``builds(ofVersion:)``). A bare version takes the build a step of the same version names, which the bundled
    /// CLI has written since 2026-09-29, and otherwise every build its version names. `dev`, a number its version's
    /// builds do not hold (an Xcode build stamps 1) and the version every unpackaged process records
    /// (``LungfishAppVersion/developmentBaseline``) name no packaged build.
    public static func builds(of envelope: ProvenanceEnvelope) -> ClosedRange<Int>? {
        let stepTexts = envelope.steps.flatMap { [$0.runtimeIdentity?.appVersion, $0.toolVersion] }.compactMap { $0 }
        let rootTexts = [envelope.runtimeIdentity.appVersion, envelope.legacyRun?.appVersion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let root = rootTexts.first(where: { !$0.isEmpty }) else {
            return stepTexts.lazy.compactMap { packagedBuild(in: $0) }.first.map { $0...$0 }
        }
        guard let named = parts(of: root) else { return nil }
        if let bracket = named.build {
            guard bracket.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(bracket) else { return nil }
            if builds(ofVersion: named.version)?.contains(number) == true { return number...number }
        } else if let build = stepTexts.lazy.compactMap({ packagedBuild(in: $0, version: named.version) }).first {
            return build...build
        }
        return named.version == LungfishAppVersion.developmentBaseline ? nil : builds(ofVersion: named.version)
    }

    /// The builds a release version such as `2026.10.29` names. A published version names the builds after the
    /// release before it up to its own, since every candidate packaged under it came after that release and no later
    /// than its own. A version between two published ones names the builds between them. Nil for a version older or
    /// newer than every published one, which no row can hold, and for any other text.
    public static func builds(ofVersion version: String) -> ClosedRange<Int>? {
        guard let key = versionKey(version) else { return nil }
        var previous: PublishedRelease?
        for release in publishedReleases {
            guard let releaseKey = versionKey(release.version) else { continue }
            if releaseKey == key { return ((previous?.build ?? release.build - 1) + 1)...release.build }
            if key.lexicographicallyPrecedes(releaseKey) {
                guard let previous, previous.build + 1 <= release.build - 1 else { return nil }
                return (previous.build + 1)...(release.build - 1)
            }
            previous = release
        }
        return nil
    }

    /// The build a `Lungfish <version> (<build>)` text names when its version's builds hold it, for `version` alone
    /// when one is given.
    static func packagedBuild(in text: String, version: String? = nil) -> Int? {
        guard let named = parts(of: text), let bracket = named.build, version == nil || named.version == version,
              bracket.allSatisfy({ $0.isASCII && $0.isNumber }), let build = Int(bracket),
              builds(ofVersion: named.version)?.contains(build) == true else { return nil }
        return build
    }

    /// `2026.10.29` and `12045` from `Lungfish 2026.10.29 (12045)`, `2026.10.29` alone from `2026.10.29` and from
    /// `lungfish-cli 2026.10.29`, and nil for any text that names no release version.
    static func parts(of text: String) -> (version: String, build: String?)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if LungfishAppVersion.isReleaseVersion(text) { return (text, nil) }
        // `lungfish variants call` puts the CLI's name and version alone at its root (`VariantsCommand.swift:1061`).
        if text.hasPrefix(commandLineVersionPrefix) {
            let version = String(text.dropFirst(commandLineVersionPrefix.count))
            return LungfishAppVersion.isReleaseVersion(version) ? (version, nil) : nil
        }
        guard text.hasPrefix("Lungfish "), text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let version = text[text.index(text.startIndex, offsetBy: 9)..<open].trimmingCharacters(in: .whitespaces)
        guard LungfishAppVersion.isReleaseVersion(version) else { return nil }
        return (version, String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
    }

    static func versionKey(_ version: String) -> [Int]? {
        guard LungfishAppVersion.isReleaseVersion(version) else { return nil }
        return version.split(separator: ".").compactMap { Int($0) }
    }

    /// The table, with the rows of the S1 fixes of sub-phase 5.6 in ``loosePairAndImportRows``. The newest published
    /// builds are `Lungfish 2026.11.15 (14072)`, 13927 (Stable 2026.11.14, a patch build), 13924 (2026.11.13), 13764
    /// (2026.11.12) and `Lungfish 2026.11.11 (13672)` and, before it, 13603 (2026.11.10),
    /// 13300 (2026.11.9), 13190 (2026.11.8), 12972 (2026.11.7), 12962 (2026.11.6), 12859, 12818, 12803, 12591, 12518
    /// (2026.11.1), 12045 (2026.10.29), 11807 (2026.10.28) and 11609 (2026.10.27).
    public static let rows: [AffectedResultRow] = [
        AffectedResultRow(
            backlogID: "BUILDDB-BAM-FIT", kinds: [.taxTriage], firstBuild: 2979, lastBuild: 12859,
            sentence: "The version that made this result could give a TaxTriage sample another sample's BAM file "
                + "when its own BAM file was missing, so its alignment view, Unique Reads and Extract Reads "
                + "could come from the other sample.",
            whatToDo: "Open the result in a project you can edit, which builds its database again, or on the "
                + "command line run lungfish-cli build-db taxtriage <result folder> --force.",
            fixCommit: "a77b7dd43"
        ),
        AffectedResultRow(
            backlogID: "EXTRACT-SCAN-EXTENDED-ID", kinds: [.taxTriageReadExtraction], firstBuild: 1085,
            lastBuild: 13672,
            sentence: "An extraction of a TaxTriage sample whose own BAM was missing may hold another sample's reads.",
            whatToDo: "Extract again with this version, which says so when the sample's own BAM is missing.",
            fixCommit: "e9a83bb94"
        ),
        AffectedResultRow(
            backlogID: "TTREADS", kinds: [.taxTriage], firstBuild: nil, lastBuild: 12045,
            sentence: "The version that made this result could show 0 or too few Reads for a TaxTriage organism "
                + "that has more than one reference sequence, such as the eight segments of Influenza A, "
                + "so a negative control could look clean.",
            whatToDo: "Open the result once in a project you can edit, which counts it again, "
                + "and export again any table made from it.",
            fixCommit: "25a9357f6"
        ),
        AffectedResultRow(
            backlogID: "TAXTRIAGE-FAILED-CONTROL-READS-CLEAN", kinds: [.taxTriage], firstBuild: nil, lastBuild: 12045,
            sentence: "The version that made this result could show a TaxTriage negative control as clean when it "
                + "had failed, was missing, was left out of the selection, or shared a name with another sample "
                + "once spaces and symbols were removed, so the organism matrix and the batch report could say "
                + "No for contamination.",
            whatToDo: "Export the organism matrix, the results table and the batch report again, "
                + "and run again any control that the batch report says failed.",
            fixCommit: "14c18d52c"
        ),
        AffectedResultRow(
            backlogID: "IMPORT-TAXTRIAGE-BATCH-HIDDEN", kinds: [.taxTriage], firstBuild: nil, lastBuild: 12045,
            sentence: "The version that imported this TaxTriage run lost its negative controls, its settings and "
                + "its database name, so the result reads Not recorded above its table and a table made from it "
                + "could say No for contamination.",
            whatToDo: "Import the run's folder again with this version and export again anything made from "
                + "the old import.",
            fixCommit: "b3471bc21"
        ),
        AffectedResultRow(
            backlogID: "W1FIX-F1", kinds: [.taxTriage], firstBuild: nil, lastBuild: 12045,
            sentence: "The version that made this result could analyze two TaxTriage samples on one reads file "
                + "when their reads files shared a name in folders with a space in the path.",
            whatToDo: "If samplesheet.csv in the result lists one reads file for two samples, "
                + "run those samples again.",
            fixCommit: "ede56dffd"
        ),
        AffectedResultRow(
            backlogID: "TTACCESSIONS", kinds: [.taxTriage], firstBuild: 2567, lastBuild: 12045,
            sentence: "The version that made this result used only the first reference sequence of a TaxTriage "
                + "organism for Extract Reads, BLAST Verify and the alignment view, so an organism with several "
                + "references could miss reads.",
            whatToDo: "Extract the reads again or run Verify with BLAST… again on the row, since both now use "
                + "every reference of the organism.",
            fixCommit: "fd48a7c29"
        ),
        AffectedResultRow(
            backlogID: "READ-LAYOUT-PARTIAL-SCAN", kinds: [.kraken2, .taxTriage, .esViritu, .assembly],
            firstBuild: nil, lastBuild: 12045,
            sentence: "The version that made this result could pair unrelated reads, with no warning, when the "
                + "FASTQ file behind it held read pairs together with merged or single reads and had 50,000 "
                + "or more pairs.",
            whatToDo: "Run fastq deinterleave on the file, split it again with --unpaired if it stops and reports "
                + "a mixed file, and run the analysis again.",
            fixCommit: "21f9d9b3b"
        ),
        AffectedResultRow(
            backlogID: "DOTTED-MATE-NAMES", kinds: [.kraken2, .taxTriage, .esViritu], firstBuild: nil, lastBuild: 12045,
            sentence: "The version that made this result ran read pairs named like SRR123.1.1 and SRR123.1.2 as "
                + "single reads, so a Kraken 2 total was about double the number of pairs and a third file of "
                + "unpaired reads was left out.",
            whatToDo: "If this result was made from reads named that way, import the run again "
                + "and run the analysis again.",
            fixCommit: "1259d57d7"
        ),
        AffectedResultRow(
            backlogID: "BUNDLE-COUNTED-TWICE", kinds: [.kraken2, .esViritu], firstBuild: nil, lastBuild: 12591,
            sentence: "The version that made this result counted each file of a multi-file FASTQ bundle as the "
                + "whole bundle when it classified the bundle or ran EsViritu on it, so read counts and depth "
                + "came out multiplied.",
            whatToDo: "Run the classification or EsViritu again on the same bundle with this version, "
                + "which reads the bundle once.",
            fixCommit: "f8dcd190e"
        ),
        AffectedResultRow(
            backlogID: "NAOMGS-UNALIGNED-MATE-HIT", kinds: [.naoMgs], firstBuild: nil, lastBuild: 12045,
            sentence: "The version that imported this result could count a NAO-MGS read pair's second mate at the "
                + "first base of a reference without placing it, so Unique Reads read low and the mate was "
                + "missing from the read panels.",
            whatToDo: "Import the original results file again, which makes a second result beside this one, "
                + "then remove this result.",
            fixCommit: "f3f9bc09e"
        ),
        AffectedResultRow(
            backlogID: "NAO-BAM-STALE", kinds: [.naoMgs], firstBuild: nil, lastBuild: 11609,
            sentence: "The version that imported this result stored the reverse-strand reads of a NAO-MGS result "
                + "reverse-complemented, so extracted reads came out reversed and the read panels showed false "
                + "mismatches, although counts and read IDs were right.",
            whatToDo: "Import the same NAO-MGS results file again in the Import Center, under NAO-MGS Results.",
            fixCommit: "04aea4b3b"
        ),
        AffectedResultRow(
            backlogID: "NVD-UNIQUE-READS-DOUBLE-COUNT", kinds: [.nvd], firstBuild: nil, lastBuild: 11609,
            sentence: "The version that imported this result counted a read more than once in the Unique Reads of "
                + "an NVD result when its BAM held secondary or supplementary alignments, so Extract Reads could "
                + "write fewer reads than the table shows.",
            whatToDo: "Import the NVD result again.",
            fixCommit: "a8274f7f1"
        ),
        AffectedResultRow(
            backlogID: "NAOMGS-BLAST-SCOPE", kinds: [.naoMgs], firstBuild: nil, lastBuild: 11807,
            sentence: "A Verify with BLAST… badge that an earlier version saved on this NAO-MGS result searched "
                + "only the taxon's own records, so it could read Supported when another organism matched better.",
            whatToDo: "Run Verify with BLAST… again on any NAO-MGS call you rely on.",
            fixCommit: "bd429ad8f"
        ),
        AffectedResultRow(
            backlogID: "BLAST-ESVIRITU-SPECIES", kinds: [.naoMgs, .esViritu, .taxTriage, .nvd, .kraken2],
            firstBuild: nil, lastBuild: 11807,
            sentence: "A Verify with BLAST… badge that an earlier version saved on this result counted a best "
                + "match filed under another name in the same species as contradicting the row, so a correct "
                + "call could read Mixed or Unsupported.",
            whatToDo: "Run Verify with BLAST… again on any row that read Mixed or Unsupported.",
            fixCommit: "035372991"
        ),
        AffectedResultRow(
            backlogID: "BLAST-MATES", kinds: [.esViritu, .taxTriage], firstBuild: nil, lastBuild: 11807,
            sentence: "A Verify with BLAST… badge that an earlier version saved on this result ignored the second "
                + "mate of a read pair, so a row could read Inconclusive when the second mate matched at 100% "
                + "or stay at Supported when it matched another organism.",
            whatToDo: "Run Verify with BLAST… again on any row from paired-end reads.",
            fixCommit: "62f06f7d2"
        ),
        AffectedResultRow(
            backlogID: "BLAST-TIED-BEYOND-FIVE", kinds: [.naoMgs, .esViritu, .taxTriage, .nvd, .kraken2],
            firstBuild: nil, lastBuild: 12045,
            sentence: "A Verify with BLAST… badge that an earlier version saved on this result judged each read "
                + "by only 5 of NCBI's records, so a perfect match could read Unsupported because its first five "
                + "hits were lab vectors.",
            whatToDo: "Run Verify with BLAST… again on the row to refresh its badge.",
            fixCommit: "0721d9182"
        ),
        AffectedResultRow(
            backlogID: "BLAST-ESVIRITU-FIRST-WORD", kinds: [.esViritu], firstBuild: 511, lastBuild: 13672,
            sentence: "A BLAST check of an EsViritu row judged by organism names could count a read as supporting "
                + "when its best match was another virus whose name starts with the same word.",
            whatToDo: "Run Verify with BLAST… again.",
            fixCommit: "3c943cb8a"
        ),
        AffectedResultRow(
            backlogID: "ASSEMBLY-RECORDED-PATH", kinds: [.assembly], firstBuild: nil, lastBuild: 11807,
            sentence: "The version that made this result read its contigs from the folder named in "
                + "assembly-result.json, so after the result was moved, renamed or copied, BLAST Contig, "
                + "Copy FASTA and a saved BLAST result could use another folder's contig.",
            whatToDo: "If you ran BLAST Contig or Copy FASTA on this result after it was moved or copied, "
                + "run it again.",
            fixCommit: "622463625"
        ),
        AffectedResultRow(
            backlogID: "VIRALRECON-LINEAGE-PREFIX", kinds: [.viralRecon], firstBuild: 5524, lastBuild: 12972,
            sentence: "The version that made this result could put the Pangolin and Nextclade tables of a Viral "
                + "Recon sample into the lineage files of another sample in the same batch when its name began "
                + "with the other sample's name and a dot, such as S1.1 beside S1, so the Inspector could show "
                + "the lineage and clade of S1.1 under S1.",
            whatToDo: "Run the batch again with this version, or keep from each sample's lineage files only the "
                + "tables whose names start with that sample's own name and then .pangolin or .nextclade.",
            fixCommit: "21f491b8e"
        ),
        AffectedResultRow(
            backlogID: "VIRALRECON-LINEAGE-ALL-SAMPLES", kinds: [.viralRecon], firstBuild: 4400, lastBuild: 5442,
            sentence: "The version that made this result gave every sample of a Viral Recon batch the Pangolin "
                + "and Nextclade tables of every sample in the batch, so the lineage and clade that the "
                + "Inspector listed first for a sample could belong to another sample.",
            whatToDo: "Run the batch again with this version, or keep from each sample's lineage files only the "
                + "tables whose names start with that sample's own name and then .pangolin or .nextclade.",
            fixCommit: "8739d18dd"
        ),
        AffectedResultRow(
            backlogID: "VIRALRECON-READ-ORDER", kinds: [.viralRecon], firstBuild: 1618, lastBuild: 12972,
            sentence: "The version that made this Viral Recon result gave viralrecon the reads in the order the "
                + "import stored them, so fastp could choose the wrong adapter and leave adapter bases on some "
                + "reads, which can change allele frequencies, consensus bases and Nextclade amino-acid changes "
                + "at primer sites.",
            whatToDo: "Run Viral Recon again on the same samples with this version and compare the variant table "
                + "and consensus.",
            fixCommit: "3b0f0c233"
        ),
        AffectedResultRow(
            backlogID: "VIRALRECON-SE-ADAPTER-GUESS", kinds: [.viralRecon], firstBuild: 1618, lastBuild: 13672,
            sentence: "A single-end Viral Recon run let fastp guess the adapter from the first reads, so the "
                + "same reads in another stored order could be trimmed differently.",
            whatToDo: "If this run used single-end reads, run Viral Recon again on the same samples with this version "
                + "and compare the variant table and consensus.",
            fixCommit: "4bf400438"
        ),
        AffectedResultRow(
            backlogID: "IVAR-CODON-MERGE", kinds: [.variantCalls], firstBuild: 1728, lastBuild: 12972,
            sentence: "The version that made these iVar calls joined two changes in one codon into one record "
                + "shown at the lower frequency, and could leave low-frequency changes in a shared codon out, "
                + "so a variant can be missing or shown too low.",
            whatToDo: "Call variants again with this version, or read MERGED_AF in a merged record for each "
                + "position's own frequency.",
            fixCommit: "c86b0c2d2"
        ),
        AffectedResultRow(
            backlogID: "ESV-STAGING-SYMBOL-NAMES", kinds: [.esViritu], firstBuild: 520, lastBuild: 12972,
            sentence: "The version that made this EsViritu result could give EsViritu the second of two input files of "
                + "one name twice and the first not at all when a folder in the input or output path held a space, "
                + "so that sample's detections, read counts and abundances can be wrong.",
            whatToDo: "If this sample had two input files of the same name, such as reads.fastq.gz from two run "
                + "folders, and a space in a folder name, run the sample again with this version.",
            fixCommit: "3d75f96a4"
        ),
        AffectedResultRow(
            backlogID: "FASTQ-TRIM-READ-ORDER", kinds: [.fastqTrim], firstBuild: 344, lastBuild: 12972,
            sentence: "The version that made these trimmed reads gave fastp the read pairs in the order the import "
                + "stored them, so fastp could choose the wrong adapter and leave adapter bases on some reads, which "
                + "can change mapping, primer trimming and allele frequencies made from them.",
            whatToDo: "Trim the original reads again with this version, or name your adapter in the trim dialog, "
                + "and redo any mapping or variant calling that used the trimmed reads.",
            fixCommit: "1cf7f7b28"
        ),
        AffectedResultRow(
            backlogID: "FASTQ-SE-ADAPTER-GUESS", kinds: [.fastqTrim], firstBuild: 344, lastBuild: 12972,
            sentence: "The version that made these trimmed reads let fastp guess the adapter of single-end reads from "
                + "the reads it saw first, and the guess changed with the order the reads were stored in, so some "
                + "reads kept adapter bases or were trimmed differently from the same reads in another order, which "
                + "can change mapping, primer trimming, small RNA counts and allele frequencies made from them.",
            whatToDo: "Trim the original reads again with this version, which names the Illumina TruSeq, Nextera and "
                + "small RNA adapters for single reads, or name your adapter in the trim dialog if your library used "
                + "another, and redo any mapping, counting or variant calling that used the trimmed reads.",
            fixCommit: "c4e2d9908"
        ),
        AffectedResultRow(
            backlogID: "FASTQ-TRIM-RECIPE-READ-ORDER", kinds: [.fastqRecipeImport], firstBuild: 802, lastBuild: 12972,
            sentence: "If the reads you imported with this recipe were exported from a Lungfish bundle, the version "
                + "that made this result let fastp choose the adapter from the order Lungfish had stored them in, "
                + "which can leave adapter bases on some reads.",
            whatToDo: "Import the original sequencer files again with this version.",
            fixCommit: "dbadae4f5"
        ),
        AffectedResultRow(
            backlogID: "DEMUX-GROUPED-DROPS-INPUTS",
            kinds: [
                .fastqDemultiplex, .fastqDemultiplexSaturatedKit, .fastqDemultiplexExactBareNames,
                .fastqDemultiplexDualSearchedAnywhere, .fastqDemultiplexDualOneEnd, .fastqDemultiplexDualFormSwap,
                .fastqDemultiplexSingleOffset, .fastqDemultiplexBuiltInDualOffset, .fastqDemultiplexSharedNameGzip,
            ],
            firstBuild: nil, lastBuild: 12972,
            sentence: "If you chose Grouped Result for more than one dataset, this demultiplexing run read only the first "
                + "dataset, so the reads of the others are in none of the samples.",
            whatToDo: "If you did, run Demultiplex Barcodes again on all the datasets with this version, then delete "
                + "this result.",
            fixCommit: "367ba1fed"
        ),
        // S1 sweep 2026-11-17 lane DEMUX-SATKIT (BIO-DEMUX-THREE section 1). Every build up to the fix, with no floor up to
        // Stable 2026.10.29 and with the floor of random bases from Preview 2026.11.3, published such a kit's chance matches.
        AffectedResultRow(
            backlogID: "DEMUX-FLOOR-SATURATED-KIT", kinds: [.fastqDemultiplexSaturatedKit], firstBuild: nil, lastBuild: 13672,
            sentence: "This run used a kit whose barcodes match about half of all reads or more by chance, so its "
                + "sample files may hold chance matches.",
            whatToDo: "Check each sample against your sample sheet, and note that a new run makes sample files "
                + "from such a kit only if you choose Keep Unchecked Samples.",
            fixCommit: "f0103d9f4"
        ),
        // Lane DEMUX-DUAL-ANCHOR (BIO-DUAL-ANCHOR items 7 and 12, Q4). Every build from the writer's landing in e34628cf4
        // searched a custom dual-index definition at Both Ends with no sample sheet as `i7...i5` with no anchor. The refusal
        // of SATKIT-4, 413bdd7a1, is the first commit that stops such a run, and the anchored lines follow it.
        AffectedResultRow(
            backlogID: "DEMUX-DUAL-UNANCHORED",
            kinds: [.fastqDemultiplexDualSearchedAnywhere, .fastqDemultiplexDualFormSwap], firstBuild: nil,
            lastBuild: 13672,
            sentence: "This run looked for each pair of barcodes in a Custom Definition of dual indexes anywhere in each "
                + "read, so its sample files may hold reads that matched by chance.",
            whatToDo: "Check each sample against your sample sheet, then run Demultiplex Barcodes again with this version, "
                + "which looks for each pair only at the two read ends, and if your barcodes sit some bases in from the "
                + "ends, set 5' Distance and 3' Distance to that many bases (on the command line, --max-distance-5prime "
                + "and --max-distance-3prime).",
            fixCommit: "413bdd7a1"
        ),
        // Lane DEMUX-DUAL-BARE-REVERSE (BIO-BARE-REVERSE items 1, 2, 5 and 6, Q3 and Q4). Every build searched a custom
        // dual-index definition at 5' End or 3' End with no sample sheet with one barcode of each pair free and the swapped
        // pair as its other strand. The refusal 713276a94 is the first commit that stops such a run.
        AffectedResultRow(
            backlogID: "DEMUX-DUAL-BARE-REVERSE", kinds: [.fastqDemultiplexDualOneEnd], firstBuild: nil, lastBuild: 13764,
            sentence: "This run searched a Custom Definition of dual indexes at 5' End or 3' End, so reads from the "
                + "reverse strand were left in Unassigned and its sample files may hold reads that matched by chance, "
                + "enough in an amplicon pool to fill a sample.",
            whatToDo: "Run Demultiplex Barcodes again with this version and choose Both Ends, and if your barcodes sit some "
                + "bases in from the read ends, also set 5' Distance and 3' Distance to that many bases (on the command "
                + "line, --location bothends, --max-distance-5prime and --max-distance-3prime).",
            fixCommit: "713276a94"
        ),
        // Lane DEMUX-DUAL-FORM (BIO-DUAL-FORM item 5). Every build read the secondary sequence of a custom dual-index
        // definition at Both Ends with no sample sheet only as written. 95021de8b is the first commit that reads it the
        // way the reads carry it, or stops in words.
        AffectedResultRow(
            backlogID: "DEMUX-DUAL-FORM", kinds: [.fastqDemultiplexDualFormSwap], firstBuild: nil, lastBuild: 13764,
            sentence: "This run read the secondary sequence of each row of your Custom Definition as written, and two of "
                + "its rows have first barcodes that match and secondary sequences that are reverse complements of each "
                + "other, each within the error rate, so if the definition lists the i5 primer's barcodes, those two "
                + "samples hold each other's reads.",
            whatToDo: "Run Demultiplex Barcodes again with this version, which reads the secondary sequence the way your "
                + "reads carry it or stops and says why.",
            fixCommit: "95021de8b"
        ),
        // Lane DEMUX-SINGLE-OFFSET-SHIFT (BIO-SINGLE-OFFSET item 3). Every published build from 2026.8.1, the first that
        // holds the writer fe644e767, searched a single-index kit with a distance above 0 with lines that Cutadapt ranks by
        // their N's. ce890d4a4 ends the fix: a placed read stays only in the row that fits it at the fewest errors.
        AffectedResultRow(
            backlogID: "DEMUX-SINGLE-OFFSET-SHIFT", kinds: [.fastqDemultiplexSingleOffset], firstBuild: 4192, lastBuild: 13764,
            sentence: "This run searched for single barcodes set in from the read end, and the build that ran it could place "
                + "some reads in another sample or leave out all the reads of a sample without a warning.",
            whatToDo: "Run it again in this version.",
            fixCommit: "ce890d4a4"
        ),
        // Lane DEMUX-LINKED-OFFSET-SHIFT (BIO-LINKED-OFFSET item 3). Every published build from 2026.8.1, the first that
        // holds the writer fe644e767, searched a built-in Illumina dual kit, or a definition made on one, at Both Ends with
        // a distance above 0 with lines that Cutadapt ranks by their N's. ce890d4a4 ends the fix: a placed read stays only
        // in the row that fits it at the fewest errors.
        AffectedResultRow(
            backlogID: "DEMUX-LINKED-OFFSET-SHIFT", kinds: [.fastqDemultiplexBuiltInDualOffset], firstBuild: 4192,
            lastBuild: 13764,
            sentence: "This run searched for dual indexes set in from the read ends, and the build that ran it could place "
                + "some reads in another sample or leave out all the reads of a sample without a warning.",
            whatToDo: "Run it again in this version.",
            fixCommit: "ce890d4a4"
        ),
        // Lane DEMUX-SHARED-NAME-GZIP (BIO-SHARED-NAME-GZIP item 3). Every published build from 2026.8.1, the first a row
        // names, wrote a built-in dual kit's rows on two lines into gzip outputs. 794ae5bff writes them plain and gzips after.
        AffectedResultRow(
            backlogID: "DEMUX-SHARED-NAME-GZIP", kinds: [.fastqDemultiplexSharedNameGzip], firstBuild: 4192, lastBuild: 13764,
            sentence: "This run searched for pairs of barcodes, and the build that ran it could leave out all the reads of a "
                + "sample without a warning and count only the reads it kept.",
            whatToDo: "Run it again in this version.",
            fixCommit: "794ae5bff"
        ),
        // S1 sweep 2026-11-17 lane DEMUX-EXACTBARE-NAMES (BIO-DEMUX-THREE item 11, section 2a). Every build with Exact Bare
        // Barcode, from its landing in 4389cd101, searched the read sequences of reads whose barcodes sat in their names.
        AffectedResultRow(
            backlogID: "DEMUX-EXACT-BARE-NO-FLOOR", kinds: [.fastqDemultiplexExactBareNames], firstBuild: 2135,
            lastBuild: 13672,
            sentence: "This run searched the read sequences for barcodes that sit in the read names, so its sample files "
                + "may hold chance matches.",
            whatToDo: "Run Demultiplex Barcodes again with the engine Read Names, which reads the barcodes from the "
                + "read names.",
            fixCommit: "eba5464b1"
        ),
    ] + loosePairAndImportRows

    /// A published release, its version and the build of the commit it was packaged from.
    public struct PublishedRelease: Equatable, Sendable {
        public let version: String
        public let build: Int

        init(_ version: String, _ build: Int) {
            self.version = version
            self.build = build
        }
    }

    /// Every published release, oldest first, each with the commit count of its tag (`git rev-list --count
    /// v<version>`), the build `release.py` stamps. A version newer than the last names no build, so a row whose
    /// `lastBuild` names a newer release needs that release added here first (`AffectedResultsTests`).
    public static let publishedReleases: [PublishedRelease] = [
        .init("2026.8.1", 4192), .init("2026.8.2", 4193), .init("2026.8.3", 4194), .init("2026.8.4", 4213),
        .init("2026.8.5", 4215), .init("2026.8.6", 4252), .init("2026.8.7", 4256), .init("2026.8.8", 4267),
        .init("2026.8.9", 4283), .init("2026.8.10", 4285), .init("2026.8.11", 4288), .init("2026.8.12", 4294),
        .init("2026.8.13", 4295), .init("2026.8.14", 4297), .init("2026.8.15", 4339), .init("2026.8.16", 4343),
        .init("2026.8.17", 4346), .init("2026.8.18", 4348), .init("2026.8.19", 4350), .init("2026.8.20", 4352),
        .init("2026.9.1", 4354), .init("2026.9.2", 4356), .init("2026.9.3", 4358), .init("2026.9.4", 4362),
        .init("2026.9.6", 4441), .init("2026.9.7", 4450), .init("2026.9.8", 4477), .init("2026.9.9", 4502),
        .init("2026.9.10", 4505), .init("2026.9.11", 4507), .init("2026.9.12", 4509), .init("2026.9.13", 4510),
        .init("2026.9.14", 4709), .init("2026.9.15", 4714), .init("2026.9.16", 4715), .init("2026.9.17", 4718),
        .init("2026.9.18", 4719), .init("2026.9.19", 4737), .init("2026.9.20", 4804), .init("2026.9.21", 4816),
        .init("2026.9.22", 4827), .init("2026.9.23", 4839), .init("2026.9.24", 4840), .init("2026.9.25", 4841),
        .init("2026.9.26", 4842), .init("2026.9.27", 4844), .init("2026.9.28", 4845), .init("2026.9.29", 4846),
        .init("2026.9.30", 4857), .init("2026.9.31", 4860), .init("2026.9.32", 4958), .init("2026.9.33", 4959),
        .init("2026.9.34", 4960), .init("2026.9.35", 4962), .init("2026.9.36", 4963), .init("2026.9.37", 4964),
        .init("2026.9.38", 4965), .init("2026.9.39", 4969), .init("2026.9.40", 5263), .init("2026.9.41", 5293),
        .init("2026.9.42", 5356), .init("2026.9.43", 5366), .init("2026.9.44", 5400), .init("2026.9.45", 5405),
        .init("2026.9.46", 5408), .init("2026.9.47", 5424), .init("2026.9.48", 5436), .init("2026.9.49", 5438),
        .init("2026.9.50", 5439), .init("2026.9.51", 5441), .init("2026.9.52", 5442), .init("2026.9.53", 5745),
        .init("2026.9.54", 5747), .init("2026.9.55", 5749), .init("2026.9.56", 5751), .init("2026.9.57", 5806),
        .init("2026.9.58", 5822), .init("2026.9.59", 5835), .init("2026.9.60", 5837), .init("2026.9.61", 5848),
        .init("2026.9.62", 5852), .init("2026.9.63", 5861), .init("2026.9.64", 5863), .init("2026.9.65", 5867),
        .init("2026.9.66", 5874), .init("2026.9.67", 5884), .init("2026.9.68", 5887), .init("2026.9.69", 5890),
        .init("2026.9.70", 5897), .init("2026.9.71", 5901), .init("2026.9.72", 5905), .init("2026.9.73", 5968),
        .init("2026.9.74", 5978), .init("2026.9.75", 5986), .init("2026.9.76", 5991), .init("2026.9.77", 6021),
        .init("2026.9.78", 6022), .init("2026.10.1", 6358), .init("2026.10.2", 6625), .init("2026.10.3", 6726),
        .init("2026.10.4", 6740), .init("2026.10.5", 6793), .init("2026.10.6", 6834), .init("2026.10.7", 6837),
        .init("2026.10.8", 6846), .init("2026.10.9", 6993), .init("2026.10.10", 7002), .init("2026.10.11", 7018),
        .init("2026.10.12", 7076), .init("2026.10.13", 7254), .init("2026.10.14", 7526), .init("2026.10.15", 8013),
        .init("2026.10.16", 8221), .init("2026.10.17", 8228), .init("2026.10.18", 9035), .init("2026.10.19", 9046),
        .init("2026.10.20", 9488), .init("2026.10.21", 10132), .init("2026.10.22", 10789), .init("2026.10.23", 11097),
        .init("2026.10.24", 11265), .init("2026.10.25", 11584), .init("2026.10.26", 11593), .init("2026.10.27", 11609),
        .init("2026.10.28", 11807), .init("2026.10.29", 12045), .init("2026.11.1", 12518), .init("2026.11.2", 12591),
        .init("2026.11.3", 12803), .init("2026.11.4", 12818), .init("2026.11.5", 12859), .init("2026.11.6", 12962),
        .init("2026.11.7", 12972), .init("2026.11.8", 13190), .init("2026.11.9", 13300), .init("2026.11.10", 13603),
        .init("2026.11.11", 13672), .init("2026.11.12", 13764), .init("2026.11.13", 13924),
        // Stable 2026.11.14 was packaged from a patch branch of v2026.11.7, whose tag counts 12984 commits, and stamped
        // 13927. It is left out, so its version names the builds between the two Previews, which hold 13927.
        .init("2026.11.15", 14072),
    ]
}

// MARK: - The kind a record names

extension AffectedResults {
    /// The root workflow names the writers of the kinds below record, each written here once (plan D4). A test holds
    /// each against a record its writer made.
    public enum RecordName {
        /// `lungfish fastq trim` (`FastqTrimSubcommand.swift:151`). Its steps carry the name as a prefix (`:76`).
        public static let fastqTrim = "lungfish fastq trim"
        /// `lungfish fastq adapter-trim` (`FastqAdapterTrimSubcommand.swift:78`), whose steps carry it as a prefix.
        public static let fastqAdapterTrim = "lungfish fastq adapter-trim"
        /// A FASTQ import, with a recipe's steps as its child steps (`FASTQBatchImporter.swift:1201,1242-1245`).
        public static let fastqImport = "lungfish import fastq"
        /// `lungfish variants call` (`VariantsCommand.swift:1060`, `BundleVariantTrackAttachmentService.swift:248`).
        public static let variantsCall = "lungfish variants call"
        /// The run folder's record of Demultiplex Barcodes, from the CLI or the window (`FastqCommand.swift:542`).
        public static let fastqDemultiplex = "lungfish fastq demultiplex"
        /// `lungfish extract reads` (`ExtractReadsCommand.swift:514`). A `--by-classifier` run records the classifier
        /// in its `tool` option (`ExtractReadsCommand.swift:829`).
        public static let extractReads = "lungfish extract reads"
        /// The bundle record of a classifier read extraction (`ReadExtractionService.swift:978`), written by the Bundle
        /// destination of the app and by `lungfish extract reads --bundle`.
        public static let classifierReadExtraction = "Classifier Read Extraction"
        /// The record of the File destination of the app (`TaxonomyReadExtractionAction.swift:690`).
        public static let appClassifierReadExtraction = "lungfish app classifier read extraction"
    }

    /// The `tool` option of a `lungfish extract reads` record that took its reads from a TaxTriage result, the raw value
    /// of `ClassifierTool.taxtriage` that `--tool` takes.
    static let extractReadsTaxTriageTool = "taxtriage"

    /// The text before the version at the root of a `lungfish variants call` record.
    static let commandLineVersionPrefix = "lungfish-cli "

    /// The flag with which fastp guesses the adapters of read pairs from the reads it sees first. A recipe's fastp
    /// trim passed it until dbadae4f5, fused with other fastp steps or alone (`FastpTrimStep.swift`).
    static let fastpPairedAdapterGuess = "--detect_adapter_for_pe"

    /// The kind of result `envelope` records, read from its root workflow name and its steps, or nil when no row speaks
    /// about it. A trim is only a record whose root is one of the two trim commands, never a step of that name inside
    /// another run, and never a trim that named its adapter or turned adapter trimming off
    /// (`trimLeftNoAdapterToGuess`). A FASTQ import is a recipe import only when a fastp step of its recipe guessed
    /// the adapter pair, since a recipe's fastp runs on read pairs (`FastpTrimStep.swift:19`) and its dedup and
    /// length-filter steps turn adapter trimming off. Variant calls count only when iVar called them, which
    /// IVAR-CODON-MERGE speaks of. A read extraction counts only when it took its reads from a TaxTriage result, which
    /// EXTRACT-SCAN-EXTENDED-ID speaks of. The `tool` option names the classifier in every `lungfish extract reads` record
    /// and in the record of the File destination of the app, and the Bundle destination of the app names it as the tool
    /// of the record instead. The `bamScanNote` is not in every such record, since builds before 03d2d8c3b and every
    /// `lungfish extract reads` record lack it.
    public static func kind(of envelope: ProvenanceEnvelope) -> AffectedResultKind? {
        switch envelope.workflowName.trimmingCharacters(in: .whitespacesAndNewlines) {
        case RecordName.fastqTrim, RecordName.fastqAdapterTrim:
            return trimLeftNoAdapterToGuess(envelope) ? nil : .fastqTrim
        case RecordName.fastqDemultiplex:
            if searchedReadNameBarcodesWithExactBare(envelope) { return .fastqDemultiplexExactBareNames }
            if searchedCustomDualPairsThatCouldSwap(envelope) { return .fastqDemultiplexDualFormSwap }
            if searchedCustomDualPairsAnywhere(envelope) { return .fastqDemultiplexDualSearchedAnywhere }
            if searchedCustomDualPairsAtOneEnd(envelope) { return .fastqDemultiplexDualOneEnd }
            if searchedBuiltInDualPairsAtAnOffset(envelope) { return .fastqDemultiplexBuiltInDualOffset }
            if wroteBuiltInDualRowsToSharedGzipOutputs(envelope) { return .fastqDemultiplexSharedNameGzip }
            if searchedWithAKitTheFloorCannotJudge(envelope) { return .fastqDemultiplexSaturatedKit }
            return searchedSingleBarcodesAtAnOffset(envelope) ? .fastqDemultiplexSingleOffset : .fastqDemultiplex
        case RecordName.fastqImport:
            // One kind per record: a recipe import that let fastp guess the adapter pair is the recipe kind even when its
            // reads were two loose files, so LOOSE-PAIR-OUT-OF-STEP names both kinds.
            let guessed = envelope.steps.contains { runs("fastp", $0) && $0.argv.contains(fastpPairedAdapterGuess) }
            if guessed { return .fastqRecipeImport }
            return importedTwoLooseFiles(envelope) ? .fastqLoosePairImport : nil
        case RecordName.map:
            return mappedTwoLooseFiles(envelope) ? .mappingLoosePair : nil
        case RecordName.czIdImport:
            return .czIdImport
        case RecordName.variantsCall:
            return envelope.steps.contains { runs("ivar", $0) } ? .variantCalls : nil
        case RecordName.extractReads, RecordName.classifierReadExtraction, RecordName.appClassifierReadExtraction:
            return takesReadsFromTaxTriage(envelope) ? .taxTriageReadExtraction : nil
        default:
            return nil
        }
    }

    /// Whether a read extraction record took its reads from a TaxTriage result. The command line and the File destination
    /// of the app name the classifier in the `tool` option. The Bundle destination of the app records it as the tool of
    /// the record, by display name (`ClassifierTool.taxtriage.displayName`), and writes no `tool` option. The option wins
    /// when it is present, so a bundle of the command line that names another classifier is no kind.
    private static func takesReadsFromTaxTriage(_ envelope: ProvenanceEnvelope) -> Bool {
        if case .string(let tool)? = envelope.options.explicit["tool"] {
            return tool.trimmingCharacters(in: .whitespacesAndNewlines) == extractReadsTaxTriageTool
        }
        return envelope.toolName.trimmingCharacters(in: .whitespacesAndNewlines) == ClassifierTool.taxtriage.displayName
    }

    /// Whether `step` ran `tool`, by the tool name a recipe or caller records or the executable of its argv.
    private static func runs(_ tool: String, _ step: ProvenanceStep) -> Bool {
        step.toolName.lowercased() == tool
            || step.argv.first.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == tool } == true
    }

    /// Whether the trim record says fastp was given its adapter (`adapterSequence` of `fastq trim`, `adapter` of
    /// `fastq adapter-trim`) or told to trim none (`adapterTrimming` false), with no step passing the paired guess.
    /// Only that positive record clears a trim. A record without such a key, or with the guess flag in a step, keeps
    /// both trim rows, since fastp may then have guessed. The `interleaved` key never narrows: a mixed file runs its
    /// unpaired reads single-end, and builds before 15439a5b6 handed fastp one interleaved file as single reads.
    private static func trimLeftNoAdapterToGuess(_ envelope: ProvenanceEnvelope) -> Bool {
        let explicit = envelope.options.explicit
        var cleared = false
        if case .string(let adapter)? = explicit["adapterSequence"] ?? explicit["adapter"],
           !adapter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cleared = true }
        if case .boolean(false)? = explicit["adapterTrimming"] { cleared = true }
        return cleared && !envelope.steps.contains { $0.argv.contains(fastpPairedAdapterGuess) }
    }
}
