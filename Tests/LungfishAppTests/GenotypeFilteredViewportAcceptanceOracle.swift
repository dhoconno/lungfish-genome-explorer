import AppKit
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

/// Ordered read-only witness from the already-rendered native Filtered viewport.
/// It deliberately does not read or construct an Excel snapshot.
@MainActor
enum GenotypeFilteredViewportAcceptanceOracle {
    struct Witness: Codable {
        let minimumReads: Int
        let samples: [Sample]
        let rows: [Row]
    }

    struct Sample: Codable {
        let id: String
        let name: String
    }

    struct Row: Codable {
        let locus: String
        let genotype: String
        let stableClusterID: String?
        let displayName: String
        let cells: [Cell]
    }

    struct Cell: Codable {
        let sampleID: String
        let displayValue: Int?
        let displayText: String
        let review: String?
        let comment: String?
        let style: Style
    }

    struct Style: Codable {
        let fillHex: String?
        let isBold: Bool
        let isItalic: Bool
    }

    static func capture(
        matrix: GenotypeComparisonMatrixView,
        sidecar: GenotypeAnnotationSidecar,
        minimumReads: Int
    ) throws -> Witness {
        let rows = matrix.testingVisibleRows
        let samples = matrix.testingVisibleSampleNames
        let duplicateNames = Dictionary(grouping: rows, by: \.genotype)
            .filter { $0.value.count > 1 }
            .keys.sorted()
        XCTAssertTrue(
            duplicateNames.isEmpty,
            "Acceptance fixtures require unambiguous native semantic lookup; duplicates: \(duplicateNames)"
        )
        let comments = sidecar.resolvedMatrixComments

        return Witness(
            minimumReads: minimumReads,
            samples: samples.map { Sample(id: $0, name: $0) },
            rows: try rows.map { row in
                let displayName = try XCTUnwrap(matrix.testingPinnedCellValue(
                    rowID: row.id,
                    column: .alleleName
                ))
                return Row(
                    locus: row.locus,
                    genotype: row.genotype,
                    stableClusterID: row.stableClusterID,
                    displayName: displayName,
                    cells: try samples.map { sample in
                        let semantic = try XCTUnwrap(matrix.testingSemanticCellState(
                            genotype: row.genotype,
                            sample: sample
                        ))
                        let rendered = try XCTUnwrap(matrix.testingRenderedStyle(
                            genotype: row.genotype,
                            sample: sample
                        ))
                        let nativeText = matrix.testingCellValue(
                            genotype: row.genotype,
                            sample: sample
                        ) ?? ""
                        XCTAssertEqual(nativeText, semantic.text.value)
                        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
                            locus: row.locus,
                            genotype: row.genotype,
                            sample: sample,
                            stableClusterID: row.stableClusterID
                        )
                        let comment = comments[target]?.body
                        XCTAssertEqual(semantic.hasNativeCellCommentMarker, comment != nil)
                        return Cell(
                            sampleID: sample,
                            displayValue: semantic.evidenceReads,
                            displayText: nativeText,
                            review: semantic.review.map {
                                $0 == .falsePositive ? "false-positive" : "false-negative"
                            },
                            comment: comment,
                            style: Style(
                                fillHex: exportedHex(matrix.testingBackgroundColor(
                                    rowID: row.id,
                                    column: .sample(sample)
                                )),
                                isBold: rendered.isBold,
                                isItalic: rendered.isItalic
                            )
                        )
                    }
                )
            }
        )
    }

    static func write(_ witness: Witness, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(witness).write(to: url)
    }

    private static func exportedHex(_ color: NSColor?) -> String? {
        guard let converted = color?.usingColorSpace(.sRGB) else { return nil }
        // The native viewport can use translucent system colors. A worksheet
        // cell has a white, opaque canvas, so the independent witness records
        // the literal sRGB value a user sees after ordinary alpha compositing.
        let alpha = min(1, max(0, converted.alphaComponent))
        let components = [converted.redComponent, converted.greenComponent, converted.blueComponent]
            .map { Int((($0 * alpha + 1 - alpha) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }
}
