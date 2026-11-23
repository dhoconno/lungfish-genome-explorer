// FASTQDemultiplexPlanLaunchSettingsTests.swift - The Demux tab's settings and typed sequences reach Demultiplex Barcodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane DEMUX, row DEMUXPLAN-LIMITS-S3-GROUP (known limits K2 and K5 of the plan landing, Phase 3.2 land-46).
// K2: Demultiplex… set the plan's location, error rate, distances and trim in the dialog, and left Min Overlap, Allow
// Indels and Search reverse complement at the dialog's defaults. K5: the plan's definition wrote the kit's sequence of a
// row's barcode, not the 5' or 3' sequence the person typed in the row.

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class FASTQDemultiplexPlanLaunchSettingsTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var dataset: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-plan-settings")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        dataset = project.appendingPathComponent("reads.fastq")
        try "@r1\nGATTACAGATTACA\n+\nIIIIIIIIIIIIII\n".write(to: dataset, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func kit(_ id: String) throws -> BarcodeKitDefinition {
        try XCTUnwrap(BarcodeKitRegistry.kit(byID: id), "no built-in kit \(id)")
    }

    /// A sequence of `length` bases that is no barcode of `kit`, so a row that holds it was typed by the person.
    private func typedSequence(notIn kit: BarcodeKitDefinition, length: Int, skipping: Set<String> = []) throws -> String {
        let used = skipping.union(kit.barcodes.flatMap { [$0.i7Sequence.uppercased(), $0.i5Sequence?.uppercased()].compactMap { $0 } })
        let candidates = ["GGTTCCAA", "CCAAGGTT", "GTGTCACA", "ACACTGTG"].map { String(repeating: $0, count: 3).prefix(length) }
        return try XCTUnwrap(candidates.map(String.init).first { !used.contains($0) }, "every candidate is a barcode of \(kit.id)")
    }

    private func step(
        _ kit: BarcodeKitDefinition, rows: [FASTQSampleBarcodeAssignment],
        minimumOverlap: Int = 20, searchReverseComplement: Bool = true, allowIndels: Bool = true
    ) -> DemultiplexStep {
        DemultiplexStep(
            label: "Plan", barcodeKitID: kit.id, minimumOverlap: minimumOverlap,
            searchReverseComplement: searchReverseComplement, allowIndels: allowIndels, sampleAssignments: rows
        )
    }

    private func launch(_ step: DemultiplexStep) throws -> FASTQDemultiplexPlanLaunch {
        try FASTQDemultiplexPlanLaunch.make(
            plan: DemultiplexPlan(steps: [step]), kits: BarcodeKitRegistry.builtinKits(), datasetURL: dataset,
            projectURL: project
        )
    }

    /// The dialog as Demultiplex… opens it, through the presenter's own order of `selectTool` and `configure`.
    private func dialogState(_ launch: FASTQDemultiplexPlanLaunch) -> FASTQOperationDialogState {
        FASTQOperationsDialogPresenter.makeState(
            selectedInputURLs: launch.inputURLs,
            initialCategory: FASTQOperationToolID.demultiplexBarcodes.categoryID,
            initialToolID: .demultiplexBarcodes,
            projectURL: project,
            configure: launch.configure
        )
    }

    /// The definition's rows, without its `# kit:` line and its header.
    private func definitionRows(_ launch: FASTQDemultiplexPlanLaunch) throws -> [String] {
        let lines = try String(contentsOf: launch.definitionURL, encoding: .utf8).split(separator: "\n").map(String.init)
        return Array(lines.filter { !$0.hasPrefix("#") }.dropFirst())
    }

    // MARK: - K2

    /// The plan step's Min Overlap 5, Allow Indels off and Search reverse complement on are the dialog's after
    /// Demultiplex… opens it. At the base the dialog had no such settings, so a run took the command's defaults.
    func testPlanStepOverlapIndelsAndReverseComplementReachTheDialog() throws {
        let kit = try kit("truseq-single-a")
        let barcode = kit.barcodes[0]
        let row = FASTQSampleBarcodeAssignment(
            sampleID: barcode.id, sampleName: "S1", forwardBarcodeID: barcode.id, forwardSequence: barcode.i7Sequence,
            reverseBarcodeID: barcode.id, reverseSequence: barcode.i7Sequence
        )
        let state = dialogState(try launch(step(
            kit, rows: [row], minimumOverlap: 5, searchReverseComplement: true, allowIndels: false
        )))
        XCTAssertEqual(state.demultiplexMinimumOverlap, 5, "the plan's Min Overlap did not reach the dialog")
        XCTAssertEqual(state.demultiplexAllowIndels, false, "the plan's Allow Indels did not reach the dialog")
        XCTAssertEqual(state.demultiplexSearchReverseComplement, true, "the plan's reverse complement did not reach the dialog")
    }

    // MARK: - K5

    /// A 5' sequence typed in a kit row is the definition's sequence. At the base the definition held the kit's.
    func testTypedFivePrimeSequenceOfAKitRowIsTheDefinitions() throws {
        let kit = try kit("truseq-single-a")
        let barcode = kit.barcodes[0]
        let typed = try typedSequence(notIn: kit, length: barcode.i7Sequence.count)
        let row = FASTQSampleBarcodeAssignment(
            sampleID: barcode.id, sampleName: "S1", forwardBarcodeID: barcode.id, forwardSequence: typed,
            reverseBarcodeID: barcode.id, reverseSequence: barcode.i7Sequence
        )
        let rows = try definitionRows(try launch(step(kit, rows: [row])))
        XCTAssertEqual(rows, ["S1,\(typed),S1"], "the definition does not hold the typed 5' sequence \(typed)")
    }

    /// A 3' sequence typed in a dual kit's row is the definition's second index, and its 5' stays the kit's.
    func testTypedThreePrimeSequenceOfADualKitRowIsTheDefinitionsSecondIndex() throws {
        let kit = try kit("truseq-ht-dual")
        let barcode = kit.barcodes[0]
        let i5 = try XCTUnwrap(barcode.i5Sequence, "\(kit.id) has no second index")
        let typed = try typedSequence(notIn: kit, length: i5.count)
        let row = FASTQSampleBarcodeAssignment(
            sampleID: barcode.id, sampleName: "S1", forwardBarcodeID: barcode.id, forwardSequence: barcode.i7Sequence,
            reverseBarcodeID: barcode.id, reverseSequence: typed
        )
        let rows = try definitionRows(try launch(step(kit, rows: [row])))
        XCTAssertEqual(rows, ["S1,\(barcode.i7Sequence),\(typed),S1"], "the definition does not hold the typed 3' sequence")
    }

    /// A row whose barcode ID was changed keeps the sequence of its earlier barcode in the table, since the drawer does
    /// not refill the cell, and a person may also type another barcode's sequence on purpose. The definition cannot
    /// tell the two apart, so a cell that holds another barcode's sequence of the kit refuses in words and writes no
    /// file (ruling BIO-DEMUX item 10, K5). At `7627eb48d` the definition took the kit's sequence of the row's barcode,
    /// so the table showed one sequence and the run searched another.
    func testAnotherBarcodesSequenceInAFivePrimeCellRefusesInWords() throws {
        let kit = try kit("truseq-single-a")
        let (chosen, earlier) = (kit.barcodes[1], kit.barcodes[0])
        let row = FASTQSampleBarcodeAssignment(
            sampleID: chosen.id, sampleName: "S1", forwardBarcodeID: chosen.id, forwardSequence: earlier.i7Sequence,
            reverseBarcodeID: chosen.id, reverseSequence: earlier.i7Sequence
        )
        XCTAssertThrowsError(try launch(step(kit, rows: [row]))) { error in
            XCTAssertEqual(
                (error as? DemultiplexPlanRefusal)?.words,
                "The sample name S1 has the barcode \(chosen.id), and its 5' Sequence cell holds \(earlier.i7Sequence), "
                    + "the sequence of \(earlier.id). Choose \(earlier.id) as its barcode, or clear the cell to use "
                    + "\(chosen.id)'s sequence."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Barcode Definitions").path))
    }

    /// The 3' cell of a dual kit's row that holds another barcode's second index refuses the same way.
    func testAnotherBarcodesSecondIndexInAThreePrimeCellRefusesInWords() throws {
        let kit = try kit("truseq-ht-dual")
        let chosen = kit.barcodes[0]
        let i5 = try XCTUnwrap(chosen.i5Sequence, "\(kit.id) has no second index")
        let earlier = try XCTUnwrap(
            kit.barcodes.first { $0.i5Sequence != nil && $0.i5Sequence?.uppercased() != i5.uppercased() },
            "\(kit.id) has one second index"
        )
        let other = try XCTUnwrap(earlier.i5Sequence)
        let row = FASTQSampleBarcodeAssignment(
            sampleID: chosen.id, sampleName: nil, forwardBarcodeID: chosen.id, forwardSequence: chosen.i7Sequence,
            reverseBarcodeID: chosen.id, reverseSequence: other
        )
        XCTAssertThrowsError(try launch(step(kit, rows: [row]))) { error in
            XCTAssertEqual(
                (error as? DemultiplexPlanRefusal)?.words,
                "The unnamed sample of barcode \(chosen.id) has the barcode \(chosen.id), and its 3' Sequence cell holds "
                    + "\(other), the sequence of \(earlier.id). Choose \(earlier.id) as its barcode, or clear the cell to "
                    + "use \(chosen.id)'s sequence."
            )
        }
    }

    /// An empty cell, or a cell that holds the kit's own sequence of the row's barcode, is not typed and runs the kit's.
    func testEmptyOrOwnSequenceCellsRunTheKitsSequence() throws {
        let kit = try kit("truseq-single-a")
        let barcode = kit.barcodes[1]
        let row = FASTQSampleBarcodeAssignment(
            sampleID: barcode.id, sampleName: "S1", forwardBarcodeID: barcode.id, forwardSequence: "",
            reverseBarcodeID: barcode.id, reverseSequence: barcode.i7Sequence.lowercased()
        )
        let rows = try definitionRows(try launch(step(kit, rows: [row])))
        XCTAssertEqual(rows, ["S1,\(barcode.i7Sequence),S1"])
    }

    /// A one-index kit's definition holds one sequence a row, so two different typed sequences refuse in words and
    /// write no file.
    func testTwoDifferentTypedSequencesOfAOneIndexKitRowRefuse() throws {
        let kit = try kit("truseq-single-a")
        let barcode = kit.barcodes[0]
        let five = try typedSequence(notIn: kit, length: barcode.i7Sequence.count)
        let three = try typedSequence(notIn: kit, length: barcode.i7Sequence.count, skipping: [five])
        let row = FASTQSampleBarcodeAssignment(
            sampleID: barcode.id, sampleName: "S1", forwardBarcodeID: barcode.id, forwardSequence: five,
            reverseBarcodeID: barcode.id, reverseSequence: three
        )
        XCTAssertThrowsError(try launch(step(kit, rows: [row]))) { error in
            let words = (error as? DemultiplexPlanRefusal)?.words ?? "\(error)"
            XCTAssertTrue(words.contains(five) && words.contains(three), words)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Barcode Definitions").path))
    }
}
