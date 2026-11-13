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
    /// assembly's record, name only the bare `<version>`. A build is believed when its version's builds hold it
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

    /// `2026.10.29` and `12045` from `Lungfish 2026.10.29 (12045)`, `2026.10.29` alone from `2026.10.29`, and nil
    /// for any text that names no release version.
    static func parts(of text: String) -> (version: String, build: String?)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if LungfishAppVersion.isReleaseVersion(text) { return (text, nil) }
        guard text.hasPrefix("Lungfish "), text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let version = text[text.index(text.startIndex, offsetBy: 9)..<open].trimmingCharacters(in: .whitespaces)
        guard LungfishAppVersion.isReleaseVersion(version) else { return nil }
        return (version, String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
    }

    static func versionKey(_ version: String) -> [Int]? {
        guard LungfishAppVersion.isReleaseVersion(version) else { return nil }
        return version.split(separator: ".").compactMap { Int($0) }
    }

    /// The table. The newest published builds are `Lungfish 2026.11.7 (12972)` and, before it, 12962 (2026.11.6),
    /// 12859, 12818, 12803, 12591, 12518 (2026.11.1), 12045 (2026.10.29), 11807 (2026.10.28) and 11609 (2026.10.27).
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
    ]

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
        .init("2026.11.7", 12972),
    ]
}
