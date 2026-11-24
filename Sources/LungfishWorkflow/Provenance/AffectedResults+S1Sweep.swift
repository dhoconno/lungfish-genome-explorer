// AffectedResults+S1Sweep.swift - The affected rows of the TaxTriage, NAO-MGS and BLAST fixes of the S1 sweep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension AffectedResults.RecordName {
    /// `lungfish build-db taxtriage` (`BuildDbProvenanceTool.workflowName`, `BuildDbCommand+Provenance.swift:32`). It is
    /// the root record of a TaxTriage result folder that holds no record of another workflow, an older run or an import,
    /// and the record of the database beside it.
    public static let buildDbTaxTriage = "lungfish build-db taxtriage"
}

extension AffectedResults {
    /// The flag with which `lungfish build-db taxtriage` skips its own cleanup (`BuildDbCommand+TaxTriageCore.swift:60`).
    static let buildDbNoCleanupFlag = "--no-cleanup"

    /// The rows of the S1 sweep before Preview 2026.11.17 that lanes TT-m1, TT-m2, COUNTS and BLAST fixed. Preview
    /// 2026.11.16 (14223) lacks each fix, so each row ends there. No source lane names the commit that brought a defect
    /// in, so none has a first build. Each `fixCommit` is the last commit on main that changes code in the row's lane.
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
                + "strain's references only for Unique Reads, Extract Reads and BLAST Verify.",
            whatToDo: "Open the result once in a project you can edit, or run lungfish-cli build-db taxtriage "
                + "<result folder> --force. Either counts it again, but only while its report files are still in the "
                + "result folder. If they are gone, run TaxTriage again. This note can stay after the result is counted "
                + "again, because the result's record still names the version that made it.",
            fixCommit: "393d2bf2f"
        ),
        // COUNTS (8183187a1) keys each mate on its whole pair. The import writes Unique Reads into the result's NAO-MGS
        // database, so an earlier import keeps the low count until its results file is imported again. The import's
        // record names the build that wrote it, as for NAOMGS-UNALIGNED-MATE-HIT (``AffectedResults/builds(of:)``).
        AffectedResultRow(
            backlogID: "NAOMGS-DEDUP-READ-COUNT", kinds: [.naoMgs], firstBuild: nil, lastBuild: 14223,
            sentence: "The version that imported this result could leave out of Unique Reads a mate that two different "
                + "NAO-MGS read pairs shared, so Unique Reads can read low.",
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
