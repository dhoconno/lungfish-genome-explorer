// DetectBarcodesReadNameIndexTests.swift - Detect Barcodes says where its counts came from and carries them to the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DETECTHDR (L9, UX's four conditions of `S2-R2-UX.md:30-33` with condition 3 changed, SWIFT's condition
// 1 of `S2-R2-SWIFT.md:23`, and C5 of ruling ARCH-DEMUX-PLAN-CONTROL). Detect counts an Illumina or Element kit from the
// index in the read names. Its result says so, a file that holds one sample says so, Proceed writes each barcode into
// the plan with its source and route, and the plan's run then writes `--engine header-index`, so the run splits by the
// read names as Detect counted them and its route no longer rests on the probe. The way out for these platforms no
// longer sends a person back to Detect with another kit (DETECT-WAYOUT-CIRCLE).

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class DetectBarcodesReadNameIndexTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "detect-read-names")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    private static let d701 = "ATTACTCG"
    private static let d702 = "TCCGGAGA"
    private static let readNameWayOut = "For barcodes inside the reads, run Demultiplex Barcodes from the FASTQ operations dialog with a Custom Definition. Show Details has the full message."

    /// Names that carry each index the given number of times, on bases that hold no barcode of the kit.
    private func writeNames(_ indexes: [(String, Int)], file: String) throws -> URL {
        let sequence = String(repeating: "GATTACA", count: 21)
        let quality = String(repeating: "I", count: sequence.count)
        var text = ""
        var number = 0
        for (index, count) in indexes {
            for _ in 0..<count {
                text += "@r\(number) 1:N:0:\(index)\n\(sequence)\n+\n\(quality)\n"
                number += 1
            }
        }
        let url = project.appendingPathComponent(file)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func scout(_ input: URL) async throws -> BarcodeScoutResult {
        try await DemultiplexingPipeline().scout(
            inputURL: input, kit: BarcodeKitRegistry.truseqSingleA, errorRate: 0.15, progress: { _, _ in }
        )
    }

    private func value(after option: String, in argv: [String]) -> String? {
        argv.firstIndex(of: option).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
    }

    /// The plan Proceed makes from a scout of `input`, with the drawer's single step.
    private func proceedPlan(_ input: URL) async throws -> (DemultiplexPlan, [FASTQSampleBarcodeAssignment]) {
        let result = try await scout(input)
        let rows = ViewerViewController.scoutAssignments(
            acceptedDetections: result.acceptedDetections, scoutResult: result, kit: BarcodeKitRegistry.truseqSingleA
        )
        let step = DemultiplexStep(label: "Detect", barcodeKitID: "truseq-single-a", sampleAssignments: rows)
        return (DemultiplexPlan(steps: [step]), rows)
    }

    // MARK: - UX's four conditions

    /// Condition 1, the source: on BIO's fixture of 900 and 100 names the result says its counts came from the index
    /// in the read names, and how many names carry one.
    func testHeaderCountResultNamesTheReadNames() async throws {
        let result = try await scout(try writeNames([(Self.d701, 900), (Self.d702, 100)], file: "counts.fastq"))
        let words = BarcodeScoutSheet.resultWords(for: result, kitDisplayName: "TruSeq")

        XCTAssertTrue(words.contains("Counted from the index in the read names: 1,000 of 1,000 reads carry one."), words)
        XCTAssertFalse(words.contains("holds one sample"), words)
        XCTAssertFalse(words.contains("may belong to another kit"), "a count with barcodes above chance names no wrong kit: \(words)")
    }

    /// UX should-fix 1 of the DETECTHDR review: names that carry the index of another kit (a wrong kit picked, the
    /// commonest bench slip) give a count with no barcode above chance, and the result says what to try next.
    func testHeaderCountWithNoBarcodeAboveChanceSaysTheIndexMayBelongToAnotherKit() async throws {
        let result = try await scout(try writeNames([("AACCAACC", 1_000)], file: "other-kit.fastq"))
        XCTAssertEqual(result.acceptedCount, 0, "an index of another kit gives no accepted barcode")
        let words = BarcodeScoutSheet.resultWords(for: result, kitDisplayName: "TruSeq")

        XCTAssertTrue(words.contains("may belong to another kit"), words)
        XCTAssertFalse(words.contains("holds one sample"), words)
    }

    /// UX should-fix 3 of the DETECTHDR review (the words are UX's, the number is BIO's): the Accept and Reject boxes do
    /// nothing for a count from the read names, whose dispositions are the chance bound's, so the sheet turns them off
    /// and says why. A count of the read bases keeps them.
    func testThresholdBoxesAreOffForACountFromTheReadNames() async throws {
        let names = try await scout(try writeNames([(Self.d701, 100)], file: "t.fastq"))
        let note = try XCTUnwrap(BarcodeScoutSheet.thresholdNote(for: names), "a count from the read names has no use for the limits")
        XCTAssertTrue(note.contains("chance bound"), note)

        let bases = BarcodeScoutResult(readsScanned: 10, detections: [], unassignedCount: 10, scoutedKitIDs: [], elapsedSeconds: 0)
        XCTAssertNil(BarcodeScoutSheet.thresholdNote(for: bases), "a search of the read bases keeps its limits")
    }

    /// Condition 2, one sample, at BIO's 99% line: 990 of 1,000 names carry D701.
    func testOneIndexFileSaysItHoldsOneSample() async throws {
        let result = try await scout(try writeNames([(Self.d701, 990), ("NNNNNNNN", 10)], file: "one.fastq"))
        let words = BarcodeScoutSheet.resultWords(for: result, kitDisplayName: "TruSeq")

        XCTAssertTrue(
            words.contains("Almost every read carries D701, so this file holds one sample and needs no demultiplexing."), words
        )
        XCTAssertTrue(words.contains("990 of 1,000 reads carry one"), words)
    }

    /// Condition 3, changed: after a count from the read names, Proceed says the run splits by the index in the read
    /// names, and no longer sends the person to the FASTQ operations dialog. A count of the read bases keeps its words.
    func testProceedAfterHeaderCountSaysTheRunSplitsByTheReadNames() {
        let words = ViewerViewController.scoutProceedWords(count: 2, source: .readNameIndex)
        XCTAssertTrue(words.hasPrefix("2 barcodes added to the plan."), words)
        XCTAssertTrue(words.contains("splits the reads by the index in their names"), words)
        XCTAssertFalse(words.contains("FASTQ operations dialog"), words)

        let bases = ViewerViewController.scoutProceedWords(count: 2, source: .readBases)
        XCTAssertFalse(bases.contains("index in their names"), bases)
    }

    /// Condition 4 and DETECT-WAYOUT-CIRCLE: for a TruSeq kit on names with no index, and for an MGI kit, the way out
    /// holds no "choose it and detect", which would send the person back to a Detect that refuses the same way. An ONT
    /// kit keeps that clause.
    func testDetectWayOutForAnIlluminaKitSendsNoOneBack() throws {
        let truseq = BarcodeKitRegistry.truseqSingleA
        let noIndex = ViewerFailureReports.detectBarcodes(
            DemultiplexError.readNamesCarryNoIndex(kitName: truseq.displayName, namesRead: 1_000), kit: truseq
        )
        XCTAssertEqual(noIndex.whatHappened, "Detect Barcodes found no index in the read names of this file.")
        XCTAssertEqual(noIndex.nextStep, Self.readNameWayOut)

        let mgi = BarcodeKitDefinition(
            id: "mgi-test", displayName: "MGI Test", vendor: "mgi", barcodes: [BarcodeEntry(id: "M1", i7Sequence: "ACGTACGT")]
        )
        let mgiReport = ViewerFailureReports.detectBarcodes(DemultiplexError.emptyAdapterSequences(kitName: mgi.displayName), kit: mgi)
        XCTAssertEqual(mgiReport.whatHappened, "Detect Barcodes cannot search Ultima or MGI kits.")
        XCTAssertEqual(mgiReport.nextStep, Self.readNameWayOut)

        for report in [noIndex, mgiReport] {
            XCTAssertFalse(report.nextStep.contains("choose it and detect"), report.nextStep)
        }
        let ont = try XCTUnwrap(BarcodeKitRegistry.kit(byID: "ont-nbd114"))
        let ontReport = ViewerFailureReports.detectBarcodes(DemultiplexError.emptyAdapterSequences(kitName: ont.displayName), kit: ont)
        XCTAssertTrue(ontReport.nextStep.contains("choose it and detect"), ontReport.nextStep)
    }

    // MARK: - Proceed carries the source and route (SWIFT condition 1), and the plan's run takes it (C5)

    /// SWIFT's test (`S2-R2-SWIFT.md:23`): Proceed never writes a barcode counted from the read names as a plain barcode.
    /// Each row records its source and the route of its run.
    func testHeaderCountedBarcodesCarryTheirSourceIntoThePlan() async throws {
        let input = try writeNames([(Self.d701, 1_000), (Self.d702, 100), ("NNNNNNNN", 10)], file: "mixed.fastq")
        let (_, rows) = try await proceedPlan(input)

        XCTAssertEqual(rows.map(\.sampleID), ["D701", "D702"])
        for row in rows {
            XCTAssertEqual(row.metadata[FASTQSampleBarcodeAssignment.barcodeSourceKey], BarcodeCountSource.readNameIndex.rawValue)
            XCTAssertEqual(row.recordedDemultiplexRoute, .headerIndex, "\(row.metadata)")
        }
    }

    /// C5 of ruling ARCH-DEMUX-PLAN-CONTROL (item 10) with QA's L9 line: the plan Proceed made sets the dialog's engine
    /// to Read Names, so its argv writes `--engine header-index`, and the run splits the reads as Detect counted them.
    func testPlanOfReadNameCountsWritesTheHeaderEngineAndSplitsByTheNames() async throws {
        let input = try writeNames([(Self.d701, 1_000), (Self.d702, 100), ("NNNNNNNN", 10)], file: "mixed.fastq")
        let (plan, _) = try await proceedPlan(input)
        let launch = try FASTQDemultiplexPlanLaunch.make(
            plan: plan, kits: BarcodeKitRegistry.builtinKits(), datasetURL: input, projectURL: project
        )
        let state = FASTQOperationsDialogPresenter.makeState(
            selectedInputURLs: launch.inputURLs,
            initialCategory: FASTQOperationToolID.demultiplexBarcodes.categoryID,
            initialToolID: .demultiplexBarcodes,
            projectURL: project,
            configure: launch.configure
        )
        XCTAssertEqual(state.demultiplexEngine, .headerIndex, "the plan's route sets the engine")
        state.prepareForRun()
        let request = try XCTUnwrap(state.pendingLaunchRequest, "the dialog made no request from the plan")
        let output = project.appendingPathComponent("Analyses/detect", isDirectory: true)
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: request, outputTargetPath: output.path)
        XCTAssertEqual(value(after: "--engine", in: invocation.arguments), "header-index", "\(invocation.arguments)")

        var command = try FastqDemultiplexSubcommand.parse(Array(invocation.arguments.dropFirst()))
        try await command.run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "no manifest in \(output.path)")
        let counts = Dictionary(manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) }, uniquingKeysWith: +)
        XCTAssertEqual(counts, ["D701": 1_000, "D702": 100])
        XCTAssertEqual(manifest.unassigned.readCount, 10)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertEqual(value(after: "--engine", in: envelope.argv), "header-index", "\(envelope.argv)")
    }

    /// A plan typed by hand records no route, so its run still leaves the route to the route owner (the plan lane's
    /// tests pin that argv), and a plan that mixes a typed row with rows from the read names takes the read names.
    func testOnlyAPlanWithARowFromTheReadNamesSetsTheEngine() throws {
        let input = try writeNames([(Self.d701, 10)], file: "typed.fastq")
        let typed = FASTQSampleBarcodeAssignment(sampleID: "D701", forwardBarcodeID: "D701", forwardSequence: Self.d701)
        let counted = FASTQSampleBarcodeAssignment(
            sampleID: "D702", forwardBarcodeID: "D702", forwardSequence: Self.d702,
            metadata: FASTQSampleBarcodeAssignment.readNameIndexMetadata
        )
        for (rows, engine) in [([typed], DemultiplexEngine.cutadapt), ([typed, counted], .headerIndex)] {
            let plan = DemultiplexPlan(steps: [DemultiplexStep(label: "P", barcodeKitID: "truseq-single-a", sampleAssignments: rows)])
            let launch = try FASTQDemultiplexPlanLaunch.make(
                plan: plan, kits: BarcodeKitRegistry.builtinKits(), datasetURL: input, projectURL: project
            )
            let state = FASTQOperationsDialogPresenter.makeState(
                selectedInputURLs: launch.inputURLs,
                initialCategory: FASTQOperationToolID.demultiplexBarcodes.categoryID,
                initialToolID: .demultiplexBarcodes,
                projectURL: project,
                configure: launch.configure
            )
            XCTAssertEqual(state.demultiplexEngine, engine, "\(rows.map(\.sampleID))")
        }
    }
}
