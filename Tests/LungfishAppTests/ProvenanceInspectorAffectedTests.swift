// ProvenanceInspectorAffectedTests.swift - The Inspector shows the sentence of a result an earlier build made wrong
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ProvenanceInspectorAffectedTests: XCTestCase {
    /// An item of the sidebar type `type`, or a track source of the Source picker when `type` is nil.
    private func item(
        _ type: SidebarItemType?, at url: URL = URL(fileURLWithPath: "/tmp/affected-results-test")
    ) -> ProvenanceInspectableItem {
        ProvenanceInspectableItem(url: url, sidebarType: type, contentMode: .metagenomics, displayName: "result")
    }

    /// Applies the affected rows the way a lookup does, for `item` and the record the model holds: the kind comes from
    /// both, and the model reads only that kind.
    private func apply(_ model: ProvenanceInspectorViewModel, _ item: ProvenanceInspectableItem) {
        model.applyAffectedResults(
            kind: ProvenanceInspectorViewModel.affectedResultKind(for: item, envelope: model.resolvedEnvelope)
        )
    }

    /// A record as its writer names it: the root workflow name, the app version at the root and the steps.
    private func record(_ workflow: String, app: String, steps: [ProvenanceStep] = []) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope.fixture()
        envelope.workflowName = workflow
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: app)
        envelope.steps = steps
        return envelope
    }

    private func step(_ tool: String, _ argv: [String], version: String = "1.0") -> ProvenanceStep {
        ProvenanceStep(toolName: tool, toolVersion: version, argv: argv, exitStatus: 0)
    }

    private func words(_ backlogID: String) throws -> String {
        try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == backlogID }, backlogID).words
    }

    /// The Warnings a lookup of `item` that found `envelope` shows, and the rows it told the viewer's strip.
    private func shownAndPosted(
        _ item: ProvenanceInspectableItem, _ envelope: ProvenanceEnvelope
    ) -> (shown: [String], posted: [AffectedResultRow]?) {
        let model = ProvenanceInspectorViewModel()
        model.resolvedEnvelope = envelope
        var posted: [AffectedResultRow]?
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { note in
            posted = note.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        apply(model, item)
        return (shown(model), posted)
    }

    /// DEMUX-GROUPED-DROPS-INPUTS in UX's words (plan D5), then what to do from `docs/plans/BACKLOG.md:28`.
    private let groupedDemultiplexWords = "If you chose Grouped Result for more than one dataset, this demultiplexing "
        + "run read only the first dataset, so the reads of the others are in none of the samples. If you did, run "
        + "Demultiplex Barcodes again on all the datasets with this version, then delete this result."

    /// A Viral Recon result folder of the Analyses folder, whose metadata names the tool `viralrecon`.
    private func viralReconResultFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("affected-viralrecon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "viralrecon", isBatch: false), to: url)
        return url
    }

    private func model(build appVersion: String) -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        var envelope = ProvenanceEnvelope.fixture()
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: appVersion)
        model.resolvedEnvelope = envelope
        return model
    }

    private func shown(_ model: ProvenanceInspectorViewModel) -> [String] {
        model.warnings.filter { $0.title == ProvenanceInspectorViewModel.affectedResultsWarningTitle }.map(\.message)
    }

    func testTheInspectorOfARecordOfAnAffectedBuildShowsTheSentenceAndWhatToDo() throws {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        apply(model,item(.taxTriageResult))
        let reads = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "TTREADS" })
        XCTAssertTrue(shown(model).contains(reads.words), "the sentence then what to do, as the table words them")
        XCTAssertEqual(shown(model).count,
                       AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage).count)
    }

    func testTheInspectorOfARootRecordWithTheBareVersionShowsTheSentence() throws {
        // The root record of a Kraken 2, TaxTriage or EsViritu run names only the version, such as 2026.10.29.
        let model = model(build: "2026.10.29")
        apply(model,item(.taxTriageResult))
        let reads = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "TTREADS" })
        XCTAssertTrue(shown(model).contains(reads.words))
    }

    func testTheCopyTextHoldsTheAffectedResultRows() throws {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        apply(model,item(.taxTriageResult))
        let reads = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "TTREADS" })
        XCTAssertTrue(model.copyableText.contains("Affected result: " + reads.words),
                      "Copy copies every displayed row, the Warnings among them")
        let fixed = model
        fixed.resolvedEnvelope = ProvenanceEnvelope.fixture()
        apply(fixed, item(.taxTriageResult))
        XCTAssertFalse(fixed.copyableText.contains("Affected result"), "rows that went leave the copy text too")
    }

    func testARecordOfAnUnaffectedOrDevBuildShowsNothing() {
        for appVersion in ["Lungfish 2026.11.7 (12972)", "Lungfish 2026.11.7 (dev)", "Lungfish 2026.11.7"] {
            let model = model(build: appVersion)
            apply(model,item(.taxTriageResult))
            XCTAssertEqual(shown(model), [], appVersion)
        }
    }

    func testAResultOfAnotherKindOrWithNoRecordShowsNothing() {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        apply(model,item(.sequence))
        XCTAssertEqual(shown(model), [], "no row speaks about a plain sequence")
        model.resolvedEnvelope = nil
        apply(model,item(.taxTriageResult))
        XCTAssertEqual(shown(model), [], "a result with no record has no build to hold")
    }

    func testTheSentenceIsNotAddedTwiceByTwoLookups() {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        apply(model,item(.taxTriageResult))
        let once = shown(model)
        apply(model,item(.taxTriageResult))
        XCTAssertEqual(shown(model), once)
    }

    func testTheViewersStripIsToldTheMatchedRows() throws {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        var received: [AffectedResultRow]?
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { note in
            received = note.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        apply(model,item(.taxTriageResult))
        XCTAssertEqual(received, AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage))
        model.resolvedEnvelope = ProvenanceEnvelope.fixture()
        apply(model,item(.taxTriageResult))
        XCTAssertEqual(received, [], "a fixture record names a build with no number")
    }

    func testClearingTheRecordTellsTheViewerThatNoRowMatches() throws {
        // A selection clears the model before its lookup, so a strip of the item before never outlives that item.
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        var received: [AffectedResultRow]?
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { note in
            received = note.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        apply(model,item(.taxTriageResult))
        XCTAssertFalse(try XCTUnwrap(received).isEmpty)

        model.clear()

        XCTAssertEqual(received, [], "the strip goes with the record it spoke for")
        XCTAssertEqual(shown(model), [])
    }

    func testARecordOfPartOfTheShownResultLeavesTheViewersStrip() throws {
        // A click on a detection loads the record of its alignment evidence into this model. The viewer still shows the
        // result, so its strip stays: neither the clear nor the end of that lookup tells the viewer.
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        var notices = 0
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        model.clear(speaksForViewer: false)
        model.resolvedEnvelope = ProvenanceEnvelope.fixture()
        apply(model,ProvenanceInspectableItem(
            url: URL(fileURLWithPath: "/tmp/affected-results-test/evidence.bam"), sidebarType: nil,
            contentMode: .metagenomics, displayName: "evidence"
        ))
        XCTAssertEqual(notices, 0, "the evidence's record does not speak for the viewer")

        model.clear()
        XCTAssertEqual(notices, 1, "the next selection's clear does")
        model.resolvedEnvelope = ProvenanceEnvelope.fixture()
        apply(model,item(.taxTriageResult))
        XCTAssertEqual(notices, 2, "the flag does not stay false into the next selection's lookup")
    }

    func testTheKindOfAnItemFollowsItsSidebarType() {
        let kinds: [(SidebarItemType, AffectedResultKind)] = [
            (.taxTriageResult, .taxTriage), (.esvirituResult, .esViritu), (.classificationResult, .kraken2),
            (.naoMgsResult, .naoMgs), (.nvdResult, .nvd),
        ]
        for (type, kind) in kinds {
            XCTAssertEqual(ProvenanceInspectorViewModel.affectedResultKind(for: item(type)), kind)
        }
        XCTAssertEqual(ProvenanceInspectorViewModel.affectedResultKind(forTool: "spades"), .assembly)
        XCTAssertNil(ProvenanceInspectorViewModel.affectedResultKind(forTool: "primer-order"))
    }

    // MARK: - Kinds the record names (AFFECTED-KINDS-NOT-MAPPED)

    func testADemultiplexedSampleOfStable20261107ShowsTheGroupedSentenceAndTellsTheStrip() {
        // A sample bundle of a demultiplexing run reads the run folder's record, `lungfish fastq demultiplex`.
        let demultiplex = record("lungfish fastq demultiplex", app: "Lungfish 2026.11.7 (12972)")
        let sample = shownAndPosted(item(.fastqBundle), demultiplex)
        XCTAssertEqual(sample.shown, [groupedDemultiplexWords], "the sentence then what to do, under Warnings")
        XCTAssertEqual(sample.posted?.map(\.words), [groupedDemultiplexWords], "the viewer's strip is told the row")
        XCTAssertEqual(shownAndPosted(item(.folder), demultiplex).shown, [groupedDemultiplexWords], "the run's folder")
    }

    func testATrimRecordShowsBothTrimRowsForEitherTrimCommand() throws {
        let both = [try words("FASTQ-TRIM-READ-ORDER"), try words("FASTQ-SE-ADAPTER-GUESS")]
        for root in ["lungfish fastq trim", "lungfish fastq adapter-trim"] {
            let trim = record(root, app: "Lungfish 2026.11.7 (12972)", steps: [step("fastp", ["fastp", "-i", "in.fq"])])
            let bundle = shownAndPosted(item(.fastqBundle), trim)
            XCTAssertEqual(bundle.shown, both, root)
            XCTAssertEqual(bundle.posted?.map(\.words), both, root)
        }
    }

    func testATrimStepInsideAnotherWorkflowOrAQualityTrimShowsNothing() {
        // Both trim commands name their steps with their root name as a prefix (`stepNamePrefix`), and quality-trim
        // turns fastp's adapter trimming off (`FastpTrimOptions.swift:86`).
        let steps = [step("lungfish fastq trim", ["fastp", "-i", "in.fq"]), step("fastp", ["fastp", "-i", "in.fq"])]
        for root in ["lungfish.taxtriage.run", "lungfish fastq quality-trim", "lungfish fastq trim (fastp)"] {
            let other = record(root, app: "Lungfish 2026.11.7 (12972)", steps: steps)
            XCTAssertEqual(shownAndPosted(item(.fastqBundle), other).shown, [], root)
        }
    }

    func testARecordOfABuildAfterTheLastAffectedOneShowsNothing() {
        for root in ["lungfish fastq demultiplex", "lungfish fastq trim"] {
            let fixed = record(root, app: "Lungfish 2026.11.9 (13300)")
            XCTAssertEqual(shownAndPosted(item(.fastqBundle), fixed).shown, [], root)
        }
    }

    func testARecipeImportThatLetFastpGuessTheAdapterShowsTheRecipeRowAndNeverTheTrimRows() throws {
        // The recipe's fastp trim passed --detect_adapter_for_pe until dbadae4f5 named the TruSeq pair. The record keeps
        // the step's argv (`FASTQBatchImporter.swift:1607`), as the adopted import of 2026.10.25 build 11392 shows.
        let guessing = step("fastp", ["/opt/lge/env/bin/fastp", "-i", "r1.fq", "-I", "r2.fq", "--detect_adapter_for_pe"])
        let recipe = record("lungfish import fastq", app: "Lungfish 2026.10.25 (11392)",
                            steps: [step("clumpify.sh", ["clumpify.sh"]), guessing])
        let bundle = shownAndPosted(item(.fastqBundle), recipe)
        XCTAssertEqual(bundle.shown, [try words("FASTQ-TRIM-RECIPE-READ-ORDER")])
        XCTAssertEqual(bundle.posted?.map(\.backlogID), ["FASTQ-TRIM-RECIPE-READ-ORDER"])
        XCTAssertFalse(bundle.shown.contains(try words("FASTQ-TRIM-READ-ORDER")), "a recipe import is never a trim result")
    }

    func testAnImportWhoseFastpStepsGuessNoAdapterShowsNothing() {
        let app = "Lungfish 2026.10.25 (11392)"
        let plain = record("lungfish import fastq", app: app, steps: [step("clumpify.sh", ["clumpify.sh"])])
        XCTAssertEqual(shownAndPosted(item(.fastqBundle), plain).shown, [], "an import with no fastp step")
        // Dedup turns adapter trimming off (`FastpDedupStep.swift:35`), and a paired merge trims by mate overlap.
        let dedupAndMerge = record("lungfish import fastq", app: app, steps: [
            step("fastp", ["fastp", "-i", "r1.fq", "-I", "r2.fq", "-D", "-A", "-G", "-Q", "-L"]),
            step("fastp", ["fastp", "-i", "r1.fq", "-I", "r2.fq", "--merge"]),
        ])
        XCTAssertEqual(shownAndPosted(item(.fastqBundle), dedupAndMerge).shown, [], "fastp steps that guess no adapter")
    }

    func testAViralReconResultShowsTheRowsOfItsBuild() throws {
        let folder = try viralReconResultFolder()
        let readOrder = try words("VIRALRECON-READ-ORDER")
        let stable = shownAndPosted(item(.analysisResult, at: folder), record("Viral Recon", app: "Lungfish 2026.11.7 (12972)"))
        XCTAssertEqual(stable.shown, [try words("VIRALRECON-LINEAGE-PREFIX"), readOrder])
        XCTAssertEqual(stable.posted?.map(\.backlogID), ["VIRALRECON-LINEAGE-PREFIX", "VIRALRECON-READ-ORDER"])
        // 5500 is a build of 2026.9.53, after the all-samples fix (to 5442) and before the prefix defect (from 5524).
        let older = shownAndPosted(item(.analysisResult, at: folder), record("Viral Recon", app: "Lungfish 2026.9.53 (5500)"))
        XCTAssertEqual(older.shown, [readOrder])
    }

    func testAnIVarTrackShowsTheCodonMergeRowAndAnotherCallerNothing() throws {
        // A track is a source of its bundle's picker with no sidebar type. `lungfish variants call` names
        // `lungfish-cli <version>` at its root and the app's build in its staging steps, as the record of the 2026.9.58
        // demo project does (`Analyses/minimap2-2026-09-25T00-00-00/.../variants/vc-3c4d560b-....lungfish-provenance.json`).
        let staging = step("lungfish reference-staging", ["lungfish-internal"], version: "Lungfish 2026.9.58 (5822)")
        let ivar = record("lungfish variants call", app: "lungfish-cli 2026.9.58",
                          steps: [staging, step("ivar", ["ivar", "variants"])])
        let track = shownAndPosted(item(nil), ivar)
        XCTAssertEqual(track.shown, [try words("IVAR-CODON-MERGE")])
        XCTAssertEqual(track.posted?.map(\.backlogID), ["IVAR-CODON-MERGE"])
        let lofreq = record("lungfish variants call", app: "lungfish-cli 2026.9.58",
                            steps: [staging, step("lofreq", ["lofreq", "call-parallel"])])
        XCTAssertEqual(shownAndPosted(item(nil), lofreq).shown, [], "the row speaks of iVar calls only")
    }
}
