// AffectedResults.swift - The results an earlier build made wrong, found from the build a record names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The kind of result a row of ``AffectedResults/rows`` speaks about.
public enum AffectedResultKind: String, CaseIterable, Sendable {
    case taxTriage
    case esViritu
    case kraken2
    case naoMgs
    case nvd
    case assembly
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
        return rows.filter { $0.kinds.contains(kind) && $0.holds(build: build) }
    }

    /// The rows for `kind` that the build named by `envelope`'s runtime identity holds.
    public static func rows(for envelope: ProvenanceEnvelope, kind: AffectedResultKind) -> [AffectedResultRow] {
        rows(forAppVersion: envelope.runtimeIdentity.appVersion ?? envelope.legacyRun?.appVersion, kind: kind)
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
                + "once spaces and symbols were removed, so the organism matrix and the batch report could say No.",
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
            whatToDo: "Extract the reads or send the BLAST row again, which now use every reference of the organism.",
            fixCommit: "fd48a7c29"
        ),
        AffectedResultRow(
            backlogID: "READ-LAYOUT-PARTIAL-SCAN", kinds: [.kraken2, .taxTriage, .esViritu, .assembly],
            firstBuild: nil, lastBuild: 12045,
            sentence: "The version that made this result could pair unrelated reads, with no warning, when the "
                + "FASTQ file behind it held read pairs together with merged or single reads and had 50,000 "
                + "or more pairs.",
            whatToDo: "Run fastq deinterleave on the file without --unpaired, split a mixed file with --unpaired, "
                + "and run the analysis again.",
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
            backlogID: "PAIREDROOT", kinds: [.kraken2, .esViritu], firstBuild: nil, lastBuild: 12591,
            sentence: "The version that made this result counted each file of a multi-file FASTQ bundle as the "
                + "whole bundle when it classified the bundle or ran EsViritu on it, so read counts and depth "
                + "came out multiplied.",
            whatToDo: "Run the classification or EsViritu again on one file of the bundle.",
            fixCommit: "42677c04a"
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
            whatToDo: "Send the row again to refresh its badge.",
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

    ]
}
