// MSADistanceMatrixTextTests.swift - copy TSV shapes and VoiceOver strings (rulings U5, U8, ux memo section 5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishAlignmentUI

struct StubDistanceMatrix: MSADistanceMatrixDisplaying {
    var displayNames: [String]
    var displayRecordIndices: [Int]
    var displayValues: [[Double]]
    var comparable: Int = 100

    func displayComparableSites(row: Int, column: Int) -> Int { comparable }

    var squareTSV: String {
        let header = "row\t" + displayNames.joined(separator: "\t")
        let rows = displayNames.indices.map { row in
            ([displayNames[row]] + displayValues[row].map(MSADistanceValueFormat.full)).joined(separator: "\t")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    static func make(_ count: Int) -> StubDistanceMatrix {
        let names = (0..<count).map { "s\($0)" }
        let values = (0..<count).map { row in
            (0..<count).map { column in row == column ? 1.0 : 1.0 - Double(row + column) / 1000 }
        }
        return StubDistanceMatrix(displayNames: names, displayRecordIndices: Array(0..<count), displayValues: values)
    }
}

final class MSADistanceMatrixTextTests: XCTestCase {
    func testSingleCellCopiesTwoByTwoBlockWithNames() throws {
        let matrix = StubDistanceMatrix.make(4)
        var selection = MSADistanceMatrixSelection(size: 4)
        selection.click(MSADistanceCell(row: 1, column: 2))
        let tsv = try XCTUnwrap(MSADistanceMatrixClipboard.tsv(for: selection, in: matrix))
        XCTAssertEqual(tsv, "row\ts2\ns1\t0.997000\n")
    }

    func testRectangleCopyLeavesUnselectedCellsBlank() throws {
        let matrix = StubDistanceMatrix.make(4)
        var selection = MSADistanceMatrixSelection(size: 4)
        selection.click(MSADistanceCell(row: 0, column: 1))
        selection.commandClick(MSADistanceCell(row: 2, column: 3))
        let tsv = try XCTUnwrap(MSADistanceMatrixClipboard.tsv(for: selection, in: matrix))
        XCTAssertEqual(tsv, """
        row\ts1\ts2\ts3
        s0\t0.999000\t\t
        s1\t\t\t
        s2\t\t\t0.995000

        """)
    }

    func testHeaderBandCopiesSubmatrix() throws {
        var matrix = StubDistanceMatrix.make(3)
        matrix.displayValues[0][2] = .nan
        matrix.displayValues[2][0] = .nan
        var selection = MSADistanceMatrixSelection(size: 3)
        selection.reflectSequences(IndexSet([0, 2]))
        let tsv = try XCTUnwrap(MSADistanceMatrixClipboard.tsv(for: selection, in: matrix))
        XCTAssertEqual(tsv, "row\ts0\ts2\ns0\t1.000000\tnan\ns2\tnan\t1.000000\n")
    }

    func testSelectAllCopyEqualsSquareTSV() throws {
        let matrix = StubDistanceMatrix.make(5)
        var selection = MSADistanceMatrixSelection(size: 5)
        selection.selectAll()
        XCTAssertEqual(MSADistanceMatrixClipboard.tsv(for: selection, in: matrix), matrix.squareTSV)
    }

    func testEmptySelectionCopiesNothing() {
        XCTAssertNil(MSADistanceMatrixClipboard.tsv(for: MSADistanceMatrixSelection(size: 3), in: StubDistanceMatrix.make(3)))
    }

    func testCellLabelsMatchTheMemoExactly() {
        XCTAssertEqual(
            MSADistanceMatrixText.cellLabel(rowName: "A", columnName: "B", value: 0.9985123, comparableSites: 29734, isDiagonal: false),
            "A, B, 0.998512, 29,734 sites compared"
        )
        XCTAssertEqual(
            MSADistanceMatrixText.cellLabel(rowName: "A", columnName: "B", value: .nan, comparableSites: 0, isDiagonal: false),
            "A, B, no comparable sites"
        )
        XCTAssertEqual(
            MSADistanceMatrixText.cellLabel(rowName: "A", columnName: "B", value: .infinity, comparableSites: 120, isDiagonal: false),
            "A, B, saturated, distance not estimable, 120 sites compared"
        )
        XCTAssertEqual(
            MSADistanceMatrixText.cellLabel(rowName: "A", columnName: "A", value: 1, comparableSites: 500, isDiagonal: true),
            "A, A, 1.000000, 500 sites compared, same sequence"
        )
        XCTAssertEqual(MSADistanceMatrixText.cellHelp, "Press Return to show both sequences in the alignment.")
    }

    func testLegendAndFooterStrings() {
        XCTAssertEqual(
            MSADistanceMatrixText.legendLabel(modelName: "identity", lower: 0.9971, upper: 1),
            "Colour scale, identity, 0.9971 to 1.0000. n/a means no comparable sites. Infinity means saturated."
        )
        XCTAssertEqual(
            MSADistanceMatrixText.footer(
                rowName: "A", columnName: "B", modelName: "identity", value: 0.998512,
                comparableSites: 29734, differences: 44, gapSkipped: 12, ambiguitySkipped: 3
            ),
            "A vs B, identity 0.998512, 29,734 compared, 44 differ, 12 gap-skipped, 3 ambiguity-skipped"
        )
        XCTAssertEqual(
            MSADistanceMatrixText.tooManyRows(250, limit: 200),
            "This alignment has 250 sequences. The matrix shows up to 200. Export computes the full matrix."
        )
    }
}
