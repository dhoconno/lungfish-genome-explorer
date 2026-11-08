// FASTQDemultiplexFloorNoticeTests.swift - The floor's chance line reaches the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane EXACTBARE-WORDS, DEMUX-FLOOR-SATURATED-KIT (ruling UX-EXACT-BARE-WORDS section 7). The floor's words
// reached only the command line, since `fastq demultiplex` has no event channel. The window reads the run's record, which
// names the barcodes within chance under `chanceFloor`, and says the same line with the row finishing with a warning.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

final class FASTQDemultiplexFloorNoticeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("floor-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The record of a `fastq demultiplex` run in the run's folder, with the `chanceFloor` block the command writes
    /// (BIO-DEMUX-NULL item 9) or none.
    private func writeRecord(chanceFloor: [String: ParameterValue]?) throws {
        let output = folder.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: output, atomically: true, encoding: .utf8)
        var parameters: [String: ParameterValue] = ["engine": .string("cutadapt")]
        if let chanceFloor { parameters["chanceFloor"] = .dictionary(chanceFloor) }
        let argv = ["lungfish-cli", "fastq", "demultiplex", "reads.fastq", "--output", folder.path]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq demultiplex", workflowVersion: "2026.11",
            toolName: "lungfish fastq demultiplex", toolVersion: "2026.11"
        )
        .argv(argv)
        .options(explicit: parameters, defaults: [:], resolved: parameters)
        .output(output, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish fastq demultiplex", toolVersion: "2026.11", argv: argv,
                outputs: [try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)],
                exitStatus: 0, wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity())
        .complete(
            exitStatus: 0, startedAt: Date(timeIntervalSince1970: 80), endedAt: Date(timeIntervalSince1970: 81)
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: folder)
    }

    private func floor(null: String, within: [String: Int]) -> [String: ParameterValue] {
        [
            "kitTail": .number(1e-6), "chanceTrials": .integer(2_000), "null": .string(null), "margin": .number(1),
            "compositionReads": .integer(0),
            "barcodesWithinChance": .dictionary(within.mapValues { ParameterValue.integer($0) }),
        ]
    }

    private func result(engine: DemultiplexEngine = .cutadapt) -> FASTQOperationExecutionResult {
        FASTQOperationExecutionResult(
            resolvedRequest: .derivative(
                request: .demultiplex(
                    kitID: "truseq-single-a", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: engine,
                    trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .groupedResult
            ),
            executedInvocations: [],
            importedURLs: [folder],
            groupedContainerURL: folder
        )
    }

    /// A kit the floor cannot measure on the run's own reads falls back to random bases and names that in its line, so a
    /// run of QA's 384-plate kit says in the window what it says on the command line.
    func testRecordWithABarcodeWithinChanceGivesTheFloorsLineInTheWindow() throws {
        try writeRecord(chanceFloor: floor(null: "random-bases", within: ["D703": 3]))

        let expected = "Could be chance matches: D703 (3 reads). Reads that carry no barcode match a barcode by chance at "
            + "this error rate, and each of these holds no more reads than chance gives. The chance is worked out as if "
            + "A, C, G and T were equally likely, because the Unassigned reads could not measure it. Their files were "
            + "kept, so check them against the samples you expect."
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorNotice(for: result()), expected)
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.rowNotice(for: result())?.rowDetail("Done in 12.3s"),
            "Some barcodes could be chance matches. Done in 12.3s"
        )
        XCTAssertEqual(FASTQDemultiplexChanceNotice.rowNotice(for: result())?.message, expected)
    }

    func testRecordWithNoBarcodeWithinChanceGivesNoWarning() throws {
        try writeRecord(chanceFloor: floor(null: "start-composition", within: [:]))
        XCTAssertNil(FASTQDemultiplexChanceNotice.floorNotice(for: result()))
        XCTAssertNil(FASTQDemultiplexChanceNotice.rowNotice(for: result()))
    }

    func testRecordWithNoChanceFloorOrNoRecordGivesNoFloorLine() throws {
        XCTAssertNil(FASTQDemultiplexChanceNotice.floorNotice(for: result()), "no record in the folder")
        try writeRecord(chanceFloor: nil)
        XCTAssertNil(FASTQDemultiplexChanceNotice.floorNotice(for: result()), "a record with no chanceFloor block")
    }

    // DEMUX-FLOOR-DECOY-MAX (rulings BIO-DECOY-MAX-STABLE and STB-R2-UX section D, Stable job lane DECOYWORDS). A record
    // holds a `chanceFloor` block only when a barcode beat the floor, so the block alone says the run published a sample
    // and the manifest is not read. The line is information, never the row's one warning.

    /// The line UX set, byte for byte.
    private let notInPoolLine = "A barcode that is not in your pool can still pass as a sample. For each such barcode this "
        + "happens in about one run in 1,000, and more often in amplicon files. Check samples with few reads against "
        + "your sample sheet."

    func testAFloorRunWithNoBarcodeWithinChanceStillCarriesTheNotInPoolLine() throws {
        try writeRecord(chanceFloor: floor(null: "start-composition", within: [:]))
        XCTAssertNil(FASTQDemultiplexChanceNotice.rowNotice(for: result()), "the line is not the row's warning")
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorLimitLine(for: result()), notInPoolLine)
        let words = FASTQDemultiplexChanceNotice.rowWords(for: result())
        XCTAssertNil(words.notice)
        XCTAssertEqual(words.floorLimitLine, notInPoolLine)
    }

    func testARunWithABarcodeWithinChanceKeepsItsWarningAndAlsoCarriesTheNotInPoolLine() throws {
        try writeRecord(chanceFloor: floor(null: "start-composition", within: ["D703": 3]))
        let within = "Could be chance matches: D703 (3 reads). Reads that carry no barcode match a barcode by chance at this "
            + "error rate, and each of these holds no more reads than chance gives. The chance is measured on the first "
            + "bases of the Unassigned reads. Their files were kept, so check them against the samples you expect."
        XCTAssertEqual(FASTQDemultiplexChanceNotice.rowNotice(for: result())?.message, within)
        XCTAssertEqual(FASTQDemultiplexChanceNotice.floorLimitLine(for: result()), notInPoolLine)
        let words = FASTQDemultiplexChanceNotice.rowWords(for: result())
        XCTAssertEqual(words.notice?.message, within)
        XCTAssertEqual(words.floorLimitLine, notInPoolLine)
    }

    func testARunWithNoRecordOrNoFloorBlockHasNoNotInPoolLine() throws {
        XCTAssertNil(FASTQDemultiplexChanceNotice.floorLimitLine(for: result()), "no record in the folder")
        try writeRecord(chanceFloor: nil)
        XCTAssertNil(FASTQDemultiplexChanceNotice.floorLimitLine(for: result()), "a record with no chanceFloor block")
        XCTAssertNil(FASTQDemultiplexChanceNotice.rowWords(for: result()).floorLimitLine)
    }

    /// The row stays Completed, so its detail starts with the check when the line stands without a warning, and with the
    /// warning's own prefix when there is one.
    func testTheRowDetailStartsWithTheCheckOnlyWhenTheLineStandsWithoutAWarning() {
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.floorLimitRowPrefix, "Check samples with few reads against your sample sheet. "
        )
        let warning = FASTQDemultiplexChanceNotice.RowNotice(
            message: "Could be chance matches: D703 (3 reads).", detailPrefix: FASTQDemultiplexChanceNotice.floorRowPrefix
        )
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.rowDetail(nil, notInPoolLine, "Done in 12.3s"),
            "Check samples with few reads against your sample sheet. Done in 12.3s"
        )
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.rowDetail(warning, notInPoolLine, "Done in 12.3s"),
            "Some barcodes could be chance matches. Done in 12.3s"
        )
        XCTAssertEqual(FASTQDemultiplexChanceNotice.rowDetail(nil, nil, "Done in 12.3s"), "Done in 12.3s")
    }

    /// The Log takes the warning at `.warning`, then the line at `.info`. A `.warning` entry turns a finished row into
    /// Completed with Warnings (`OperationCenter.Item.hasWarnings`), so the line alone must leave the row without one.
    @MainActor
    func testTheNotInPoolLineGoesToTheLogAtInfoAfterTheWarning() throws {
        let center = OperationCenter()
        let warning = FASTQDemultiplexChanceNotice.RowNotice(
            message: "Could be chance matches: D703 (3 reads).", detailPrefix: FASTQDemultiplexChanceNotice.floorRowPrefix
        )
        let withWarning = try XCTUnwrap(center.begin(
            title: "Demultiplex Barcodes", detail: "", operationType: .fastqOperation, cliCommand: "lungfish fastq demultiplex"
        ).startedID)
        FASTQDemultiplexChanceNotice.log(warning, notInPoolLine, id: withWarning, in: center)
        let first = try XCTUnwrap(center.items.first { $0.id == withWarning })
        XCTAssertEqual(first.logEntries.map(\.level), [.warning, .info])
        XCTAssertEqual(first.logEntries.map(\.message), [warning.message, notInPoolLine])

        let lineAlone = try XCTUnwrap(center.begin(
            title: "Demultiplex Barcodes", detail: "", operationType: .fastqOperation, cliCommand: "lungfish fastq demultiplex"
        ).startedID)
        FASTQDemultiplexChanceNotice.log(nil, notInPoolLine, id: lineAlone, in: center)
        let second = try XCTUnwrap(center.items.first { $0.id == lineAlone })
        XCTAssertEqual(second.logEntries.map(\.level), [.info])
        XCTAssertEqual(second.logEntries.map(\.message), [notInPoolLine])
        XCTAssertFalse(second.hasWarnings, "the line alone leaves the finished row Completed")
    }
}
