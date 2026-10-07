// FASTQBatchImporterPairingTests.swift - The --pairing choice applied to detected samples
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO

/// The Import FASTQ sheet's Pairing popup and `--pairing` used to have no
/// effect: pairing was decided only by whether an R2 file was detected.
final class FASTQBatchImporterPairingTests: XCTestCase {

    private let pair = SamplePair(
        sampleName: "sample",
        r1: URL(fileURLWithPath: "/data/sample_R1.fastq.gz"),
        r2: URL(fileURLWithPath: "/data/sample_R2.fastq.gz"),
        relativePath: "run1",
        metadata: ["lane": "1"],
        sampleSheetURL: URL(fileURLWithPath: "/data/sheet.csv")
    )
    private let single = SamplePair(sampleName: "alone", r1: URL(fileURLWithPath: "/data/alone.fastq"), r2: nil)

    func testAutoAndPairedKeepDetectedPairs() {
        for pairing in [FASTQBatchImporter.ImportPairing.auto, .paired] {
            let applied = FASTQBatchImporter.applyPairing(pairing, to: [pair, single])
            XCTAssertEqual(applied.map(\.sampleName), ["sample", "alone"], "\(pairing)")
            XCTAssertEqual(applied[0].r2, pair.r2)
            XCTAssertTrue(pairing.keepsDetectedPairs)
        }
    }

    func testSingleSplitsEachPairIntoTwoSamplesNamedByFileStem() {
        let applied = FASTQBatchImporter.applyPairing(.single, to: [pair, single])

        XCTAssertEqual(applied.map(\.sampleName), ["alone", "sample_R1", "sample_R2"])
        XCTAssertTrue(applied.allSatisfy { $0.r2 == nil })
        XCTAssertEqual(applied[1].r1, pair.r1)
        XCTAssertEqual(applied[2].r1, pair.r2)
        // Sample-sheet context follows both halves.
        XCTAssertEqual(applied[1].relativePath, "run1")
        XCTAssertEqual(applied[2].metadata, ["lane": "1"])
        XCTAssertEqual(applied[2].sampleSheetURL, pair.sampleSheetURL)
    }

    func testInterleavedAlsoSplitsPairsAndIsRecordedInConfig() {
        let applied = FASTQBatchImporter.applyPairing(.interleaved, to: [pair])
        XCTAssertEqual(applied.map(\.sampleName), ["sample_R1", "sample_R2"])
        XCTAssertFalse(FASTQBatchImporter.ImportPairing.interleaved.keepsDetectedPairs)

        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: URL(fileURLWithPath: "/project.lungfish"), platform: .illumina,
            pairing: .interleaved
        )
        XCTAssertEqual(config.pairing, .interleaved)
        XCTAssertEqual(
            FASTQBatchImporter.ImportConfig(projectDirectory: URL(fileURLWithPath: "/project.lungfish"), platform: .illumina).pairing,
            .auto,
            "Callers that predate the option keep name-based detection"
        )
    }

    func testAMixedOutputIsLabelledByItsCountAsEveryImporterLabelsOne() {
        // One pairing-label convention (orchestrator ruling of 2026-10-06,
        // from lane L3). A file whose whole-file count holds any single read
        // is labelled single-end, and a count of only pairs interleaved, the
        // rule FASTQMixedLayoutHint.pairingMode applies. The batch importer
        // labelled a merge recipe's output, or a run's pairs with its reads
        // whose mate is missing, interleaved whenever it held a pair.
        let imported = FASTQBatchImporter.RecordedPairing(mode: .interleaved, source: .explicit)
        func recorded(merged: Int, pairs: Int, unpaired: Int) -> FASTQBatchImporter.RecordedPairing {
            FASTQBatchImporter.recordedPairing(
                afterRecipeOutput: .mixed,
                mixedLayout: RecipeMixedLayoutCounts(mergedReads: merged, pairs: pairs, unpairedReads: unpaired),
                importedAs: imported
            )
        }
        for (merged, pairs, unpaired) in [(3, 5, 0), (0, 5, 2), (3, 5, 2), (4, 0, 0), (0, 5, 0), (0, 0, 0)] {
            let expected = FASTQMixedLayoutHint.pairingMode(pairs: pairs, singles: merged + unpaired)
            XCTAssertEqual(
                recorded(merged: merged, pairs: pairs, unpaired: unpaired),
                FASTQBatchImporter.RecordedPairing(mode: expected, source: .detected),
                "merged \(merged), pairs \(pairs), unpaired \(unpaired)"
            )
        }
        XCTAssertEqual(recorded(merged: 3, pairs: 5, unpaired: 0).mode, .singleEnd, "merged reads beside pairs")
        XCTAssertEqual(recorded(merged: 0, pairs: 5, unpaired: 2).mode, .singleEnd, "a run's reads whose mate is missing")
        XCTAssertEqual(recorded(merged: 0, pairs: 5, unpaired: 0).mode, .interleaved, "pairs alone")
        XCTAssertEqual(
            FASTQBatchImporter.recordedPairing(afterRecipeOutput: .mixed, mixedLayout: nil, importedAs: imported).mode,
            .singleEnd
        )
    }

    func testPairingValuesMatchTheCLIVocabulary() {
        XCTAssertEqual(
            FASTQBatchImporter.ImportPairing.allCases.map(\.rawValue),
            ["auto", "single", "paired", "interleaved"]
        )
    }
}
