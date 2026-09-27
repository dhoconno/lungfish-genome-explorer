// MultipleSequenceAlignmentDistanceMatrixTests.swift - Shared identity / p-distance service
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class MultipleSequenceAlignmentDistanceMatrixTests: XCTestCase {
    /// The fixture and expected TSV are the same ones `MSACommandTests` asserts for
    /// `lungfish-cli msa distance`, so the Inspector table and the CLI file must agree.
    private let records = [
        MSAAlignedRecord(name: "seq1", sequence: "ACGT"),
        MSAAlignedRecord(name: "seq2", sequence: "A-GT"),
        MSAAlignedRecord(name: "seq3", sequence: "ACAT"),
    ]

    func testIdentityMatrixMatchesCLILayout() throws {
        let matrix = try MSADistanceMatrix(records: records, model: .identity)

        XCTAssertEqual(matrix.names, ["seq1", "seq2", "seq3"])
        XCTAssertEqual(
            matrix.tsv,
            "row\tseq1\tseq2\tseq3\nseq1\t1.000000\t1.000000\t0.750000\nseq2\t1.000000\t1.000000\t0.666667\nseq3\t0.750000\t0.666667\t1.000000\n"
        )
        XCTAssertEqual(matrix.values[0][2], 0.75, accuracy: 1e-12)
        XCTAssertEqual(matrix.values[2][0], 0.75, accuracy: 1e-12, "matrix is symmetric")
        XCTAssertEqual(matrix.comparableSites[1][2], 3, "gap in seq2 is skipped pairwise")
        XCTAssertEqual(matrix.matchingSites[1][2], 2)
    }

    func testPDistanceIsOneMinusIdentity() throws {
        let matrix = try MSADistanceMatrix(records: records, model: .pDistance)
        XCTAssertEqual(matrix.values[0][2], 0.25, accuracy: 1e-12)
        XCTAssertEqual(matrix.values[1][2], 1 - 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(matrix.values[0][0], 0, accuracy: 1e-12)
    }

    func testUniquePairsListEachUnorderedPairOnce() throws {
        let matrix = try MSADistanceMatrix(records: records, model: .identity)
        let pairs = matrix.uniquePairs
        XCTAssertEqual(pairs.map(\.id), ["0:1", "0:2", "1:2"])
        XCTAssertEqual(pairs.map { "\($0.rowName)/\($0.columnName)" }, ["seq1/seq2", "seq1/seq3", "seq2/seq3"])
        XCTAssertEqual(pairs.map(\.formattedValue), ["1.000000", "0.750000", "0.666667"])
        XCTAssertEqual(pairs.map(\.comparableSites), [3, 4, 3])
    }

    func testNoComparableSitesGivesNaNSortedLast() throws {
        let matrix = try MSADistanceMatrix(
            records: [MSAAlignedRecord(name: "a", sequence: "AC--"), MSAAlignedRecord(name: "b", sequence: "--GT")],
            model: .identity
        )
        let pair = try XCTUnwrap(matrix.uniquePairs.first)
        XCTAssertTrue(pair.value.isNaN)
        XCTAssertEqual(pair.formattedValue, "nan")
        XCTAssertEqual(pair.sortableValue, -Double.infinity)
        XCTAssertTrue(matrix.tsv.contains("\tnan"))
    }

    func testComparisonIsCaseInsensitiveAndTreatsDotAsGap() throws {
        let matrix = try MSADistanceMatrix(
            records: [MSAAlignedRecord(name: "a", sequence: "acgt"), MSAAlignedRecord(name: "b", sequence: "AC.T")],
            model: .identity
        )
        XCTAssertEqual(matrix.values[0][1], 1, accuracy: 1e-12)
        XCTAssertEqual(matrix.comparableSites[0][1], 3)
    }

    func testUnequalAlignedLengthsThrow() {
        XCTAssertThrowsError(try MSADistanceMatrix(
            records: [MSAAlignedRecord(name: "a", sequence: "ACGT"), MSAAlignedRecord(name: "b", sequence: "ACG")],
            model: .identity
        )) { error in
            XCTAssertEqual(error as? MSADistanceMatrixError, .unequalAlignedLengths)
        }
    }

    func testSingleRowHasNoPairs() throws {
        let matrix = try MSADistanceMatrix(records: [records[0]], model: .identity)
        XCTAssertTrue(matrix.uniquePairs.isEmpty)
        XCTAssertEqual(matrix.tsv, "row\tseq1\nseq1\t1.000000\n")
    }

    func testParseAlignedFASTAAndLoadFromBundle() throws {
        let parsed = MSAAlignedRecord.parseAlignedFASTA(">x desc\nAC GT\nac\n\n>y\n--GT\n")
        XCTAssertEqual(parsed, [
            MSAAlignedRecord(name: "x desc", sequence: "ACGTac"),
            MSAAlignedRecord(name: "y", sequence: "--GT"),
        ])
        XCTAssertTrue(MSAAlignedRecord.parseAlignedFASTA("").isEmpty)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msa-distance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("alignment.fasta")
        try ">seq1\nACGT\n>seq2\nA-GT\n>seq3\nACAT\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let bundleURL = tempDir.appendingPathComponent("alignment.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL)

        let loaded = try MSAAlignedRecord.loadPrimaryAlignment(of: bundleURL)
        XCTAssertEqual(loaded.map(\.name), ["seq1", "seq2", "seq3"])
        XCTAssertEqual(try MSADistanceMatrix(records: loaded, model: .identity).tsv, try MSADistanceMatrix(records: records, model: .identity).tsv)
    }

    func testModelRawValuesAreTheCLISpellings() {
        XCTAssertEqual(MSADistanceModel.allCases.map(\.rawValue), ["identity", "p-distance"])
        XCTAssertEqual(MSADistanceModel(rawValue: "p-distance"), .pDistance)
    }
}
