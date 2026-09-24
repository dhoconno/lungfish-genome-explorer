// FASTQBatchImporterPairingTests.swift - The --pairing choice applied to detected samples
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

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
            projectDirectory: URL(fileURLWithPath: "/project.lungfish"),
            pairing: .interleaved
        )
        XCTAssertEqual(config.pairing, .interleaved)
        XCTAssertEqual(
            FASTQBatchImporter.ImportConfig(projectDirectory: URL(fileURLWithPath: "/project.lungfish")).pairing,
            .auto,
            "Callers that predate the option keep name-based detection"
        )
    }

    func testPairingValuesMatchTheCLIVocabulary() {
        XCTAssertEqual(
            FASTQBatchImporter.ImportPairing.allCases.map(\.rawValue),
            ["auto", "single", "paired", "interleaved"]
        )
    }
}
