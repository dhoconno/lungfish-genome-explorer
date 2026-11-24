// AffectedResultsS1SweepTests.swift - The affected rows of the TaxTriage, NAO-MGS and BLAST fixes of the S1 sweep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// Lane AFFECTED-S1 m1 of the S1 sweep (`docs/contracts/SCOPE-AND-DELIVERY.md`, Affected results). Preview 2026.11.16
/// (14223) lacks each fix, so each row holds every build up to 14223 and none after. The tests read the table by backlog
/// id and the kinds by raw value, so they compile at the base, where no row and no narrower kind exists.
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
    ]

    private static let sweepIDs = Set(expected.map(\.id))

    /// The rows of this lane that each kind holds at a build without the fixes, in table order. Every other kind holds none.
    private static let held: [String: [String]] = [
        legacyCleanup: ["TT-LEGACY-CLEANUP-REMOVES-TOP"],
        "taxTriage": ["TT-STRAIN-GROUP", "BLAST-NAME-PHRASE-LEAK"],
        "naoMgs": ["NAOMGS-DEDUP-READ-COUNT", "BLAST-NAME-PHRASE-LEAK"],
        "esViritu": ["BLAST-NAME-PHRASE-LEAK"],
        "nvd": ["BLAST-NAME-PHRASE-LEAK"],
        "kraken2": ["BLAST-NAME-PHRASE-LEAK"],
    ]

    /// Every kind by raw value, the narrower TaxTriage kind included where it does not exist yet.
    private static var kinds: [String] {
        let all = AffectedResultKind.allCases.map(\.rawValue)
        return all.contains(legacyCleanup) ? all : all + [legacyCleanup]
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
}
