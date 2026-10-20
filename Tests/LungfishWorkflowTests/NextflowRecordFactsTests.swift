// NextflowRecordFactsTests.swift - The facts one Nextflow step records, with TaxTriage as the first workflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B11, milestone M1. `NextflowRecordFacts` holds the engine and pipeline facts of one Nextflow step in
// one shape for every workflow (decision R1), and `TaxTriageRecordFacts` takes its step's facts from it. The extraction
// moves no record fact, which `TaxTriageRecordFreezeTests` and `TaxTriageSampleRecordFreezeTests` show unchanged. These
// tests pin the shape, its TaxTriage client and the gap milestone M2 closes, the version line TaxTriage prints under
// Nextflow 26 in a real run (R1).

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class NextflowRecordFactsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "nextflow-record-facts")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Helpers

    /// The commit of TaxTriage `v3.3.8`, the commit the lock pins.
    private static let commit = "e10bfebda32a62711f38a4e23ab03b61725a9675"

    /// The facts of a TaxTriage step at that commit launched from LGE's snapshot, as R1 ran.
    private static let taxTriageStep = NextflowRecordFacts(
        toolName: "taxtriage",
        toolVersion: commit,
        githubReleaseVersion: "v3.3.8",
        pipelineSource: .snapshot
    )

    /// The banner of Nextflow 25.04.6 as the stand-in engine prints it, and the launch line that follows it.
    private static let nextflow25Lines = [
        "N E X T F L O W  ~  version 25.04.6",
        "",
        "Launching `jhuapl-bio/taxtriage` [silly_euler] DSL2 - revision: \(commit) [main]",
    ]

    /// Lines 86 to 93 of the log of R1, the real pooled TaxTriage run on Nextflow 26.04.6 of Phase 2.9 lane Q15,
    /// without line 92, the `[WORKDIR]` line that names that Mac's scratch folder.
    private static let nextflow26Lines = [
        "No taxdump provided, downloading the latest taxdump from NCBI",
        "Nextflow version: 26.04.6",
        "Commit ID: local",
        "Repository URL: local",
        "Date: Mon Oct 12 09:19:02 CDT 2026",
        "[PIPELINE] nf-core/taxtriage 1.0dev | profile=docker",
        "[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP",
    ]

    /// A file at `path` under the test's folder that holds `lines`.
    private func writeLog(_ lines: [String], at path: String = "nextflow.log") throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    // MARK: - The shape

    /// R1 and T6. A Nextflow step is the pipeline id at the commit that ran, with the release tag that names the commit,
    /// launched from the repository or from LGE's snapshot.
    func testAStepIsThePipelineAtTheCommitWithTheTagBeside() {
        let step = Self.taxTriageStep

        XCTAssertEqual(step.toolName, "taxtriage")
        XCTAssertEqual(step.toolVersion, Self.commit)
        XCTAssertEqual(step.githubReleaseVersion, "v3.3.8")
        XCTAssertEqual(step.pipelineSource, .snapshot)
        XCTAssertNotEqual(
            step,
            NextflowRecordFacts(toolName: "taxtriage", toolVersion: Self.commit, githubReleaseVersion: nil, pipelineSource: .snapshot),
            "a commit that no tag names is another fact"
        )
        XCTAssertNotEqual(
            step,
            NextflowRecordFacts(toolName: "taxtriage", toolVersion: Self.commit, githubReleaseVersion: "v3.3.8", pipelineSource: .remote),
            "the code the repository gave is another fact"
        )
        XCTAssertEqual(NextflowPipelineSource.remote.rawValue, "remote")
        XCTAssertEqual(NextflowPipelineSource.snapshot.rawValue, "snapshot")
    }

    /// The step's resolved options are where its code came from and the version of the Nextflow that ran, from the
    /// banner in the run's own log (declared move of M2, `pipelineSource` added).
    func testTheResolvedOptionsHoldTheSourceAndTheVersionFromTheLog() throws {
        let log = try writeLog(Self.nextflow25Lines)

        XCTAssertEqual(
            Self.taxTriageStep.resolvedOptions(logFile: log),
            ["pipelineSource": .string("snapshot"), "nextflowVersion": .string("25.04.6")]
        )
    }

    /// No log, a log that is gone, a log that is not UTF-8 and a log with no banner each leave the version out, and
    /// the source stays (declared move of M2, the options were empty).
    func testTheResolvedOptionsHoldOnlyTheSourceWithNoVersionToRead() throws {
        let notUTF8 = root.appendingPathComponent("not-utf8.log", isDirectory: false)
        try Data([0x4E, 0x20, 0xFF, 0xFE, 0xC3]).write(to: notUTF8)
        let step = Self.taxTriageStep
        let sourceOnly: [String: ParameterValue] = ["pipelineSource": .string("snapshot")]

        XCTAssertEqual(step.resolvedOptions(logFile: nil), sourceOnly)
        XCTAssertEqual(step.resolvedOptions(logFile: root.appendingPathComponent("gone.log", isDirectory: false)), sourceOnly)
        XCTAssertEqual(step.resolvedOptions(logFile: notUTF8), sourceOnly)
        XCTAssertEqual(step.resolvedOptions(logFile: try writeLog(["Launching jhuapl-bio/taxtriage"])), sourceOnly)
    }

    /// The parser reads the version of the first banner, a suffix such as `-edge` with it, and nothing else.
    func testTheParserReadsTheVersionOfTheFirstBanner() {
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inLog: " N E X T F L O W  ~  version 24.10.4\n"), "24.10.4")
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inLog: "N E X T F L O W ~ version 25.04.6-edge"), "25.04.6-edge")
        XCTAssertEqual(
            NextflowRecordFacts.nextflowVersion(
                inLog: "N E X T F L O W  ~  version 25.04.6\nN E X T F L O W  ~  version 24.10.4"
            ),
            "25.04.6"
        )
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inLog: "Launching jhuapl-bio/taxtriage"))
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inLog: "N E X T F L O W  ~  version unknown"))
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inLog: ""))
    }

    /// R1, the gap M2 closed (flipped by M2). Nextflow 26.04.6 prints no `N E X T F L O W` banner, and the version a
    /// real run's log holds is the line `Nextflow version: 26.04.6` that TaxTriage's workflow prints from
    /// `workflow.nextflow.version`, the engine that ran. Its step recorded empty resolved options in R1's record, and
    /// reads `26.04.6` here now.
    func testTheVersionLineTaxTriagePrintsIsRead() throws {
        let log = try writeLog(Self.nextflow26Lines)

        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inLog: Self.nextflow26Lines.joined(separator: "\n")), "26.04.6")
        XCTAssertEqual(Self.taxTriageStep.resolvedOptions(logFile: log)["nextflowVersion"], .string("26.04.6"))
    }

    /// The BIO review of M1, note 1. Nextflow 26.04.6's own lines name the pipeline's manifest version and no engine
    /// version, so a wider parser never records `1.0dev` as the Nextflow that ran.
    func testTheEngineLinesOfNextflow26HoldNoVersion() {
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(
            inLog: "[PIPELINE] nf-core/taxtriage 1.0dev | profile=docker\n[WORKDIR] /tmp/work\n[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP"
        ))
    }

    /// A version counts only at the start of a line, so a path or an argument in the preamble LGE writes at the top of
    /// the log never stands in for the engine's line, and the first line that names a version wins.
    func testOnlyALineThatStartsWithTheVersionCounts() {
        let preamble = [
            "# TaxTriage launch metadata",
            "requested_output_directory: /Users/me/Nextflow version: 9 runs/out",
            "nextflow_command: nextflow run jhuapl-bio/taxtriage --title 'N E X T F L O W  ~  version 8'",
        ]

        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inLog: preamble.joined(separator: "\n")))
        XCTAssertEqual(
            NextflowRecordFacts.nextflowVersion(inLog: (preamble + Self.nextflow25Lines + Self.nextflow26Lines).joined(separator: "\n")),
            "25.04.6"
        )
        XCTAssertEqual(
            NextflowRecordFacts.nextflowVersion(inLog: (preamble + Self.nextflow26Lines + Self.nextflow25Lines).joined(separator: "\n")),
            "26.04.6"
        )
        XCTAssertEqual(NextflowRecordFacts.nextflowVersion(inLog: "\tNextflow version: 26.04.6\n"), "26.04.6")
        XCTAssertNil(NextflowRecordFacts.nextflowVersion(inLog: "Nextflow version: local"))
    }

    // MARK: - TaxTriage, the first client

    /// RT4 and R1. A TaxTriage step is the tool `taxtriage` at the revision, with the lock's tag for the pinned commit,
    /// the tag itself for a revision that is a `v` tag and no tag for another commit.
    func testATaxTriageStepIsTaxtriageAtTheRevisionWithTheTagThatNamesIt() throws {
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        let otherCommit = "78f4b4b" + String(repeating: "0", count: 33)

        XCTAssertEqual(
            TaxTriageRecordFacts.nextflowFacts(revision: pin.revision, pin: pin, pipelineSource: .snapshot),
            NextflowRecordFacts(
                toolName: "taxtriage",
                toolVersion: pin.revision,
                githubReleaseVersion: pin.releaseVersion,
                pipelineSource: .snapshot
            )
        )
        XCTAssertEqual(
            TaxTriageRecordFacts.nextflowFacts(revision: "v3.3.9", pin: try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin(), pipelineSource: .remote),
            NextflowRecordFacts(toolName: "taxtriage", toolVersion: "v3.3.9", githubReleaseVersion: "v3.3.9", pipelineSource: .remote)
        )
        XCTAssertEqual(
            TaxTriageRecordFacts.nextflowFacts(revision: otherCommit, pin: try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin(), pipelineSource: .remote),
            NextflowRecordFacts(toolName: "taxtriage", toolVersion: otherCommit, githubReleaseVersion: nil, pipelineSource: .remote)
        )
    }

    /// A TaxTriage step reads the version from the first output named `nextflow.log`, the log LGE keeps of the engine,
    /// and never from Nextflow's own `.nextflow.log` or another output. A first log with no banner leaves the version
    /// out, and no later log stands in.
    func testATaxTriageStepReadsTheFirstOutputNamedNextflowLog() throws {
        let own = try writeLog(["N E X T F L O W  ~  version 24.10.4"], at: ".nextflow.log")
        let report = try writeLog(["N E X T F L O W  ~  version 23.04.0"], at: "report.txt")
        let kept = try writeLog(Self.nextflow25Lines)
        let bannerless = try writeLog(["Launching jhuapl-bio/taxtriage"], at: "earlier/nextflow.log")
        let step = TaxTriageRecordFacts.nextflowFacts(revision: Self.commit, pin: try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin(), pipelineSource: .remote)

        XCTAssertEqual(TaxTriageRecordFacts.nextflowLog(among: [own, report, kept]), kept)
        XCTAssertNil(TaxTriageRecordFacts.nextflowLog(among: [own, report]))
        XCTAssertEqual(
            step.resolvedOptions(logFile: TaxTriageRecordFacts.nextflowLog(among: [own, report, kept])),
            ["pipelineSource": .string("remote"), "nextflowVersion": .string("25.04.6")]
        )
        XCTAssertEqual(TaxTriageRecordFacts.nextflowLog(among: [bannerless, kept]), bannerless)
        XCTAssertEqual(
            step.resolvedOptions(logFile: TaxTriageRecordFacts.nextflowLog(among: [bannerless, kept])),
            ["pipelineSource": .string("remote")]
        )
    }

    // MARK: - The lock's pin

    /// R1 on A16's pin. A step that ran the pin is the lock's pipeline id at the pinned revision with the pin's tag, so
    /// for the pinned commit the pin route and the TaxTriage pipeline route record the same facts, and a pin with no
    /// tag records none.
    func testAStepThatRanThePinIsThePipelineIdAtThePinnedRevision() throws {
        let pin = try NextflowWorkflowDescriptor.taxTriage.resolveBundledPin()
        let untagged = NextflowPipelinePin(pipelineID: "taxtriage", repository: pin.repository, revision: pin.revision, releaseVersion: "")

        XCTAssertEqual(
            NextflowRecordFacts(pin: pin, pipelineSource: .snapshot),
            NextflowRecordFacts(
                toolName: "taxtriage",
                toolVersion: pin.revision,
                githubReleaseVersion: pin.releaseVersion,
                pipelineSource: .snapshot
            )
        )
        XCTAssertEqual(
            NextflowRecordFacts(pin: pin, pipelineSource: .remote),
            TaxTriageRecordFacts.nextflowFacts(revision: pin.revision, pin: try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin(), pipelineSource: .remote)
        )
        XCTAssertNil(NextflowRecordFacts(pin: untagged, pipelineSource: .remote).githubReleaseVersion)
    }

    // MARK: - Database identity, R3 and R4

    /// Every value recorded under `databaseIdentityStatus` in the record at `url`.
    private func recordedStatusWords(in url: URL) throws -> Set<String> {
        func collect(_ value: Any) -> [String] {
            if let dictionary = value as? [String: Any] {
                let own = ((dictionary["databaseIdentityStatus"] as? [String: Any])?["value"] as? String).map { [$0] } ?? []
                return own + dictionary.values.flatMap(collect)
            }
            return (value as? [Any])?.flatMap(collect) ?? []
        }
        return Set(collect(try JSONSerialization.jsonObject(with: Data(contentsOf: url))))
    }

    /// R3. One vocabulary of three statuses. Each writer keeps its word, TaxTriage's through the type, and a reader
    /// takes Kraken 2's `unresolved-bounded-metadata` as `unpinned` and its `provided-aggregate-digest` as `pinned`,
    /// as the classifier goldens record EsViritu's `unpinned` and Kraken 2's `provided-aggregate-digest`.
    func testEveryRecordedStatusWordReadsAsOneStatus() throws {
        let goldens = ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/golden/classifiers", isDirectory: true)
        let esViritu = try recordedStatusWords(in: goldens.appendingPathComponent("esviritu/lungfish-provenance.json"))
        let kraken2 = try recordedStatusWords(in: goldens.appendingPathComponent("kraken2/lungfish-provenance.json"))

        XCTAssertEqual(DatabaseIdentityStatus.allCases.map(\.rawValue), ["pinned", "unpinned", "liveSnapshot"])
        for status in DatabaseIdentityStatus.allCases {
            XCTAssertEqual(DatabaseIdentityStatus.status(ofRecordedWord: status.rawValue), status)
        }
        XCTAssertEqual(TaxTriageRecordFacts.databaseIdentityStatus, "unpinned", "TaxTriage keeps its word")
        XCTAssertEqual(DatabaseIdentityStatus.status(ofRecordedWord: EsVirituAnalysisRunTool.databaseIdentityStatus), .unpinned)
        XCTAssertEqual(esViritu, ["unpinned"])
        XCTAssertEqual(kraken2, ["provided-aggregate-digest"])
        XCTAssertEqual(DatabaseIdentityStatus.status(ofRecordedWord: "unresolved-bounded-metadata"), .unpinned)
        XCTAssertEqual(kraken2.compactMap(DatabaseIdentityStatus.status(ofRecordedWord:)), [.pinned])
        XCTAssertEqual(esViritu.compactMap(DatabaseIdentityStatus.status(ofRecordedWord:)), [.unpinned])
        XCTAssertNil(DatabaseIdentityStatus.status(ofRecordedWord: "Unpinned"))
        XCTAssertNil(DatabaseIdentityStatus.status(ofRecordedWord: ""))
    }

    /// R4. A database the run fetched is `liveSnapshot` with the date of the fetch and the kept listings, such as
    /// TaxTriage's `combine/<sample>.combined.gcfmap.tsv`, and no path, because the run keeps no copy of it.
    func testALiveSnapshotEntryNamesItsFetchDateAndTheKeptListings() throws {
        let combine = ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/taxtriage-mini/combine", isDirectory: true)
        let listings = ["SRR35517702", "SRR35517703"].map { combine.appendingPathComponent("\($0).combined.gcfmap.tsv") }
        let fetchedAt = try Date("2026-10-12T14:22:37Z", strategy: .iso8601)
        let entry = NextflowDatabaseEntry(
            role: "fetchedReferences",
            status: .liveSnapshot,
            fetchedAt: fetchedAt,
            listingFiles: listings
        )

        XCTAssertTrue(listings.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(entry.resolvedDefaults, [
            "fetchedReferences": .dictionary([
                "status": .string("liveSnapshot"),
                "fetchedAt": .string("2026-10-12T14:22:37Z"),
                "listingFiles": .array(listings.map { .file($0) }),
            ]),
        ])
    }

    /// R3. An entry names only what it knows, so a database the run did not fetch has no date and no listing, and two
    /// entries are two resolved defaults, one per role.
    func testAnEntryNamesOnlyWhatItKnows() {
        let database = URL(fileURLWithPath: "/db/viral-kraken2", isDirectory: true)
        let kraken2 = NextflowDatabaseEntry(role: "kraken2Database", status: .unpinned, path: database)
        let references = NextflowDatabaseEntry(role: "fetchedReferences", status: .liveSnapshot)

        XCTAssertEqual(
            kraken2.resolvedDefaults,
            ["kraken2Database": .dictionary(["status": .string("unpinned"), "path": .file(database)])]
        )
        XCTAssertEqual(references.resolvedDefaults, ["fetchedReferences": .dictionary(["status": .string("liveSnapshot")])])
        XCTAssertEqual(
            Set(kraken2.resolvedDefaults.merging(references.resolvedDefaults) { current, _ in current }.keys),
            ["kraken2Database", "fetchedReferences"]
        )
    }
}
