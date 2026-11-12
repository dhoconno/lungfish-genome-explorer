// AffectedResultsTests.swift - The table of results an earlier build made wrong and its matcher
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class AffectedResultsTests: XCTestCase {
    /// The builds of the published releases from Stable 2026.10.27 on, each the commit count of its packaged commit.
    private let publishedBuilds: Set<Int> = [11609, 11807, 12045, 12518, 12591, 12803, 12818, 12859, 12962, 12972]

    private func version(_ build: Int) -> String { "Lungfish 2026.10.29 (\(build))" }

    private func ids(_ build: Int, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(forAppVersion: version(build), kind: kind).map(\.backlogID)
    }

    func testTheBuildIsTheNumberInBracketsAndNothingElse() {
        XCTAssertEqual(AffectedResults.build(fromAppVersion: "Lungfish 2026.10.29 (12045)"), 12045)
        for text in ["Lungfish 2026.11.7 (dev)", "Lungfish 2026.11.7", "Lungfish fixture", "Lungfish 1.0 ()",
                     "Lungfish 1.0 (12a)", "Lungfish 1.0 (-5)", "", "(12045"] {
            XCTAssertNil(AffectedResults.build(fromAppVersion: text), text)
        }
        XCTAssertNil(AffectedResults.build(fromAppVersion: nil))
    }

    func testARecordOfAnAffectedBuildMatchesTheRowsOfItsKind() {
        // Stable 2026.10.29 counted TaxTriage Reads on the first reference only and could fit a sibling's BAM.
        let taxTriage = ids(12045, .taxTriage)
        XCTAssertTrue(taxTriage.contains("TTREADS"))
        XCTAssertTrue(taxTriage.contains("BUILDDB-BAM-FIT"))
        XCTAssertFalse(taxTriage.contains("NAOMGS-UNALIGNED-MATE-HIT"), "that row speaks about another kind")
        XCTAssertTrue(ids(12045, .naoMgs).contains("NAOMGS-UNALIGNED-MATE-HIT"))
        XCTAssertFalse(ids(12045, .assembly).contains("ASSEMBLY-RECORDED-PATH"), "that row ends at 11807")
        XCTAssertTrue(ids(11807, .assembly).contains("ASSEMBLY-RECORDED-PATH"))
    }

    func testTheBuildBeforeTheFirstAndAfterTheLastDoNotMatch() {
        func holdsBAMFit(_ build: Int) -> Bool { ids(build, .taxTriage).contains("BUILDDB-BAM-FIT") }
        XCTAssertFalse(holdsBAMFit(2978), "one build before the commit that brought the defect in")
        XCTAssertTrue(holdsBAMFit(2979))
        XCTAssertTrue(holdsBAMFit(12859), "Preview 2026.11.5, the last build without the fix")
        XCTAssertFalse(holdsBAMFit(12860))
        XCTAssertEqual(ids(12962, .taxTriage), [], "Preview 2026.11.6 holds every TaxTriage fix")
        XCTAssertEqual(ids(12972, .taxTriage), [], "Stable 2026.11.7 holds every TaxTriage fix")
        XCTAssertFalse(ids(11610, .nvd).contains("NVD-UNIQUE-READS-DOUBLE-COUNT"), "that row ends at Stable 2026.10.27")
        XCTAssertTrue(ids(11609, .nvd).contains("NVD-UNIQUE-READS-DOUBLE-COUNT"))
    }

    func testEveryRowHoldsItsOwnBoundsAndNothingBeyond() {
        for row in AffectedResults.rows {
            XCTAssertTrue(row.holds(build: row.lastBuild), row.backlogID)
            XCTAssertFalse(row.holds(build: row.lastBuild + 1), row.backlogID)
            if let first = row.firstBuild {
                XCTAssertTrue(row.holds(build: first), row.backlogID)
                XCTAssertFalse(row.holds(build: first - 1), row.backlogID)
            }
            for kind in row.kinds {
                XCTAssertTrue(ids(row.lastBuild, kind).contains(row.backlogID), "\(row.backlogID) \(kind)")
                XCTAssertFalse(ids(row.lastBuild + 1, kind).contains(row.backlogID), "\(row.backlogID) \(kind)")
            }
        }
    }

    func testADevBuildOrNoBuildMatchesNothing() {
        for kind in AffectedResultKind.allCases {
            XCTAssertEqual(AffectedResults.rows(forAppVersion: "Lungfish 2026.11.7 (dev)", kind: kind), [], "\(kind)")
            XCTAssertEqual(AffectedResults.rows(forAppVersion: "Lungfish 2026.11.7", kind: kind), [], "\(kind)")
            XCTAssertEqual(AffectedResults.rows(forAppVersion: "", kind: kind), [], "\(kind)")
            XCTAssertEqual(AffectedResults.rows(forAppVersion: nil, kind: kind), [], "\(kind)")
        }
    }

    func testARecordIsReadThroughItsRuntimeIdentity() {
        var affected = ProvenanceEnvelope.fixture()
        affected.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.10.29 (12045)")
        XCTAssertTrue(AffectedResults.rows(for: affected, kind: .taxTriage).contains { $0.backlogID == "TTREADS" })

        var current = ProvenanceEnvelope.fixture()
        current.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.7 (12972)")
        XCTAssertEqual(AffectedResults.rows(for: current, kind: .taxTriage), [])

        var dev = ProvenanceEnvelope.fixture()
        dev.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.7 (dev)")
        XCTAssertEqual(AffectedResults.rows(for: dev, kind: .taxTriage), [])
    }

    func testTheTableIsWellFormed() {
        let rows = AffectedResults.rows
        XCTAssertEqual(Set(rows.map(\.backlogID)).count, rows.count, "one row for each backlog id")
        for row in rows {
            XCTAssertFalse(row.kinds.isEmpty, row.backlogID)
            XCTAssertTrue(publishedBuilds.contains(row.lastBuild),
                          "\(row.backlogID) ends at the newest published build that lacks the fix")
            XCTAssertLessThan(row.lastBuild, 12972, "\(row.backlogID) is fixed in the newest Stable")
            if let first = row.firstBuild { XCTAssertLessThanOrEqual(first, row.lastBuild, row.backlogID) }
            XCTAssertNotNil(row.fixCommit.range(of: "^[0-9a-f]{9}$", options: .regularExpression), row.backlogID)
            for words in [row.sentence, row.whatToDo] {
                XCTAssertTrue(words.hasSuffix("."), row.backlogID)
                XCTAssertFalse(words.contains("\u{2014}") || words.contains(";") || words.contains(":"),
                               "\(row.backlogID) follows the prose rules")
                XCTAssertEqual(words.components(separatedBy: ". ").count, 1, "\(row.backlogID) is one sentence")
            }
            XCTAssertEqual(row.words, row.sentence + " " + row.whatToDo)
        }
    }

    // MARK: - Records as the app wrote them, with the bare version at the root

    private func backlogIDs(_ record: ProvenanceEnvelope, _ kind: AffectedResultKind) -> [String] {
        AffectedResults.rows(for: record, kind: kind).map(\.backlogID)
    }

    /// A classifier golden record (`Tests/Fixtures/golden/classifiers/<name>`) as the app of `version` wrote it. The
    /// root names the bare version, as `AnalysisRunExecutor` writes it, and `stepApp` takes the place of each step's
    /// `Lungfish <APP_VERSION> (dev)`. The other placeholders take values the reader accepts.
    private func goldenRecord(_ name: String, version: String, stepApp: String) throws -> ProvenanceEnvelope {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden/classifiers/\(name)/lungfish-provenance.json")
        var text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "Lungfish <APP_VERSION> (dev)", with: stepApp)
            .replacingOccurrences(of: "<APP_VERSION>", with: version)
            .replacingOccurrences(of: "\"<TIMESTAMP>\"", with: "\"2026-11-03T12:00:00Z\"")
            .replacingOccurrences(of: "\"<DURATION>\"", with: "1")
        text = text.replacingOccurrences(of: #""<SIZE-R[0-9]+>""#, with: "1", options: .regularExpression)
            .replacingOccurrences(of: #""<UUID-([0-9]+)>""#, with: "\"00000000-0000-0000-0000-00000000000$1\"",
                                  options: .regularExpression)
        return try ProvenanceEnvelopeReader.decode(Data(text.utf8))
    }

    /// A record built the way its writer builds it: `AnalysisRunExecutor+RootRecord.swift` for a TaxTriage run and
    /// `AssembleCommand.swift` for an assembly, both with the bare version at the root.
    private func writtenRecord(
        workflow: String, tool: String, toolVersion: String, version: String, steps: [ProvenanceStep]
    ) throws -> ProvenanceEnvelope {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-results-\(UUID().uuidString).txt")
        try Data("result\n".utf8).write(to: output)
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        var builder = ProvenanceRunBuilder(
            workflowName: workflow, workflowVersion: version, toolName: tool, toolVersion: toolVersion
        )
        .argv(["lungfish-cli", workflow])
        .runtime(ProvenanceRuntimeIdentity(appVersion: version))
        for step in steps { builder = builder.step(step) }
        builder = try builder.output(output, role: .output)
        let now = Date()
        return try builder.complete(exitStatus: 0, status: .completed, startedAt: now, endedAt: now)
    }

    func testAKraken2RecordOfStable20261029MatchesTheRowsOfItsBuild() throws {
        // Since 2026-09-29 the bundled CLI names the app's build in each step it runs.
        let record = try goldenRecord("kraken2", version: "2026.10.29", stepApp: "Lungfish 2026.10.29 (12045)")
        XCTAssertEqual(record.runtimeIdentity.appVersion, "2026.10.29", "the root names only the version")
        let expected = AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .kraken2).map(\.backlogID)
        XCTAssertTrue(expected.contains("READ-LAYOUT-PARTIAL-SCAN"))
        XCTAssertEqual(backlogIDs(record, .kraken2), expected)
    }

    func testAnEsVirituRecordWhoseStepsNameNoBuildMatchesByItsVersion() throws {
        // Before 2026-09-29 the bundled CLI wrote `(dev)` in every step, so the version alone names the build.
        let record = try goldenRecord("esviritu", version: "2026.9.40", stepApp: "Lungfish 2026.9.40 (dev)")
        let expected = AffectedResults.rows(forAppVersion: "Lungfish 2026.9.40 (5263)", kind: .esViritu).map(\.backlogID)
        XCTAssertTrue(expected.contains("BLAST-MATES"))
        XCTAssertEqual(backlogIDs(record, .esViritu), expected)
        let fixed = try goldenRecord("esviritu", version: "2026.11.7", stepApp: "Lungfish 2026.11.7 (dev)")
        XCTAssertEqual(backlogIDs(fixed, .esViritu), [], "Stable 2026.11.7 holds every fix")
    }

    func testARecordOfAnUnpackagedBuildMatchesNothing() throws {
        // `swift test` and a SwiftPM lungfish-cli record the development baseline, and an Xcode build stamps 1.
        let baseline = LungfishAppVersion.developmentBaseline
        for stepApp in ["Lungfish \(baseline) (dev)", "Lungfish \(baseline) (1)"] {
            for (name, kind) in [("kraken2", AffectedResultKind.kraken2), ("esviritu", .esViritu)] {
                let record = try goldenRecord(name, version: baseline, stepApp: stepApp)
                XCTAssertEqual(backlogIDs(record, kind), [], "\(name) \(stepApp)")
            }
        }
        var xcodeImport = ProvenanceEnvelope.fixture()
        xcodeImport.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish \(baseline) (1)")
        XCTAssertEqual(backlogIDs(xcodeImport, .naoMgs), [], "an import an Xcode build made")
    }

    func testATaxTriageRootRecordMatchesByItsStepOrByItsVersion() throws {
        // The read-layout steps of `TaxTriagePipeline+ReadLayout.swift` name the app's build.
        let split = ProvenanceStep(
            toolName: "Lungfish TaxTriage Interleaved Split", toolVersion: "Lungfish 2026.10.29 (12045)",
            argv: ["LungfishWorkflow", "deinterleave-fastq"],
            runtimeIdentity: ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.10.29 (12045)"), exitStatus: 0
        )
        let pipeline = ProvenanceStep(toolName: "nextflow", toolVersion: "25.04.6", argv: ["nextflow", "run"], exitStatus: 0)
        let withSteps = try writtenRecord(
            workflow: "lungfish.taxtriage.run", tool: "lungfish-cli", toolVersion: "2026.10.29", version: "2026.10.29",
            steps: [split, pipeline]
        )
        XCTAssertEqual(withSteps.runtimeIdentity.appVersion, "2026.10.29")
        XCTAssertEqual(backlogIDs(withSteps, .taxTriage),
                       AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage).map(\.backlogID))
        XCTAssertTrue(backlogIDs(withSteps, .taxTriage).contains("TTREADS"))

        // A run of Preview 2026.11.5 with no read-layout step names only its version.
        let preview = try writtenRecord(
            workflow: "lungfish.taxtriage.run", tool: "lungfish-cli", toolVersion: "2026.11.5", version: "2026.11.5",
            steps: [pipeline]
        )
        XCTAssertEqual(backlogIDs(preview, .taxTriage), ["BUILDDB-BAM-FIT"], "TTREADS was fixed in 2026.11.1")
        let fixed = try writtenRecord(
            workflow: "lungfish.taxtriage.run", tool: "lungfish-cli", toolVersion: "2026.11.6", version: "2026.11.6",
            steps: [pipeline]
        )
        XCTAssertEqual(backlogIDs(fixed, .taxTriage), [], "Preview 2026.11.6 holds every TaxTriage fix")
    }

    func testAnAssemblyRecordMatchesByItsVersion() throws {
        // `AssembleCommand` names the bare version at the root and in its steps, and no build anywhere.
        func assembly(_ version: String) throws -> ProvenanceEnvelope {
            let spades = ProvenanceStep(toolName: "spades", toolVersion: "4.0.0", argv: ["spades.py"], exitStatus: 0)
            return try writtenRecord(
                workflow: "lungfish.assemble", tool: "spades", toolVersion: "4.0.0", version: version, steps: [spades]
            )
        }
        let stable1028 = try backlogIDs(assembly("2026.10.28"), .assembly)
        XCTAssertTrue(stable1028.contains("ASSEMBLY-RECORDED-PATH"))
        XCTAssertTrue(stable1028.contains("READ-LAYOUT-PARTIAL-SCAN"))
        XCTAssertEqual(try backlogIDs(assembly("2026.10.29"), .assembly), ["READ-LAYOUT-PARTIAL-SCAN"])
        XCTAssertEqual(try backlogIDs(assembly("2026.11.1"), .assembly), [])
    }

    func testTheBundleRowNamesTheFixItsSentenceSpeaksAbout() throws {
        let row = try XCTUnwrap(AffectedResults.rows.first { $0.sentence.contains("multi-file FASTQ bundle") })
        XCTAssertEqual(row.backlogID, "BUNDLE-COUNTED-TWICE", "notes 2026.11.3:37, not the one-file operations of :80")
        XCTAssertEqual(row.fixCommit, "f8dcd190e")
        XCTAssertEqual(row.lastBuild, 12591)
        XCTAssertFalse(row.whatToDo.contains("one file of the bundle"), "the one-file remedy belongs to another fix")
        XCTAssertTrue(row.whatToDo.contains("same bundle"))
    }

    func testWhatToDoNamesTheMenuItemAndReadsWithoutAContradiction() throws {
        for row in AffectedResults.rows {
            XCTAssertFalse(row.whatToDo.hasPrefix("Send "), "\(row.backlogID) names the menu item")
            if row.whatToDo.contains("BLAST"), !row.whatToDo.contains("BLAST Contig") {
                XCTAssertTrue(row.whatToDo.contains("Verify with BLAST\u{2026}"), "\(row.backlogID) names the menu item")
            }
        }
        let layout = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "READ-LAYOUT-PARTIAL-SCAN" })
        XCTAssertFalse(layout.whatToDo.contains("without --unpaired"), "one step, not with and without the option")
        let controls = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "TAXTRIAGE-FAILED-CONTROL-READS-CLEAN" })
        XCTAssertTrue(controls.sentence.hasSuffix("could say No for contamination."))
    }
}
