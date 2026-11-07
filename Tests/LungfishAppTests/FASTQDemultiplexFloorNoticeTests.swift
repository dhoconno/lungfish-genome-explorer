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
}
