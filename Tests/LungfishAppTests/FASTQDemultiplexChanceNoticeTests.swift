// FASTQDemultiplexChanceNoticeTests.swift - The words of a demultiplex run's Operations row about chance matches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane EXACTBARE-WORDS. A finished demultiplex in the app shows no line of the command line's summary,
// since `fastq demultiplex` has no event channel (ruling UX-EXACT-BARE-WORDS), so the row needs its own words.
// DEMUX-EXACT-BARE-NO-FLOOR: Exact Bare Barcode checks no chance matches and says so when it made a sample file.

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQDemultiplexChanceNoticeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chance-notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A manifest in the run's folder, one barcode for each read count.
    private func writeManifest(readCounts: [Int]) throws {
        let barcodes = readCounts.enumerated().map { index, count in
            BarcodeResult(
                barcodeID: "S\(index + 1)", sampleName: "Sample\(index + 1)", readCount: count, baseCount: Int64(count * 150),
                bundleRelativePath: "S\(index + 1).lungfishfastq"
            )
        }
        try DemultiplexManifest(
            barcodeKit: BarcodeKit(name: "custom", vendor: "custom", barcodeCount: readCounts.count),
            parameters: DemultiplexParameters(tool: "exact-bare", maxMismatches: 0),
            barcodes: barcodes,
            unassigned: UnassignedReadsSummary(readCount: 200, baseCount: 30_000),
            outputDirectoryRelativePath: "demux/",
            inputReadCount: 200 + readCounts.reduce(0, +)
        ).save(to: folder)
    }

    private func result(engine: DemultiplexEngine) -> FASTQOperationExecutionResult {
        FASTQOperationExecutionResult(
            resolvedRequest: .derivative(
                request: .demultiplex(
                    kitID: "custom", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: engine,
                    trimBarcodes: false, sampleAssignments: nil, kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .groupedResult
            ),
            executedInvocations: [],
            importedURLs: [folder],
            groupedContainerURL: folder
        )
    }

    func testExactBareRunThatMadeASampleFileGetsTheWords() throws {
        try writeManifest(readCounts: [5])

        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .exactBareBarcode)),
            DemultiplexEngine.exactBareChanceWords
        )
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.rowDetail("Done in 12.3s"),
            "Not checked for chance matches. Done in 12.3s"
        )
    }

    func testNoWordsWithNoSampleFileOrAnotherEngine() throws {
        try writeManifest(readCounts: [0, 0])
        XCTAssertNil(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .exactBareBarcode)),
            "a run that made no sample file has no sample file to warn about"
        )

        try writeManifest(readCounts: [5])
        XCTAssertNil(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .cutadapt)),
            "a Cutadapt run has its chance floor and its own line"
        )
        XCTAssertNil(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .headerIndex)),
            "the split by read names is not this row"
        )
    }

    func testExactBareRunWhoseManifestCannotBeReadStillGetsTheWords() {
        XCTAssertEqual(
            FASTQDemultiplexChanceNotice.notice(for: result(engine: .exactBareBarcode)),
            DemultiplexEngine.exactBareChanceWords,
            "with no manifest to read the run may have made sample files, so the words stay on the safe side"
        )
    }
}
