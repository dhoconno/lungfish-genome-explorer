// AnnotationGFF3RelationalIDMask.swift - The B5 parity mask for GFF3 `ID=` values, with its negative controls
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39, manager decision R5 (`SCR/rulings/MGR-12.39-R5.md`). `GFF3Writer` prints
// `ID=<annotation.id.uuidString>`, and every load of an annotation database gives its records new UUIDs, so two
// exports of one sidebar bundle differ in every `ID=` value. The B5 parity class
// (`AnnotationExportCLIGUIParityReplayTests`) compares a sidebar bundle's GFF3 under this mask and under no other.
// No shared policy uses it (R5 item 2). The 2.13 row GFF3-STABLE-ID removes the need for it.

import Foundation
import XCTest
import LungfishCore
import LungfishIO

/// The relational `ID=` mask of R5 item 1. Each distinct `ID=` value becomes a token in order of first appearance
/// (`<ID-1>`, `<ID-2>`, ...), and every attribute value that equals a masked ID takes the same token, so two lines
/// that share an ID on one side share a token on the other. Nothing else in the text changes.
enum AnnotationGFF3RelationalIDMask {
    static func masked(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var tokens: [String: String] = [:]
        for line in lines {
            guard let attributes = attributeColumn(of: line) else { continue }
            for pair in attributes.components(separatedBy: ";") where pair.hasPrefix("ID=") {
                let id = String(pair.dropFirst("ID=".count))
                if tokens[id] == nil {
                    tokens[id] = "<ID-\(tokens.count + 1)>"
                }
            }
        }
        return lines.map { line in
            guard attributeColumn(of: line) != nil else { return line }
            var columns = line.components(separatedBy: "\t")
            columns[8] = columns[8].components(separatedBy: ";").map { pair in
                guard let equals = pair.firstIndex(of: "=") else { return pair }
                // A list value is comma separated, and the writer encodes a comma inside a value as %2C.
                let values = pair[pair.index(after: equals)...].components(separatedBy: ",")
                return String(pair[..<equals]) + "=" + values.map { tokens[$0] ?? $0 }.joined(separator: ",")
            }.joined(separator: ";")
            return columns.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// The ninth column of a feature line, or nil for a comment, a directive or a blank line.
    private static func attributeColumn(of line: String) -> String? {
        guard !line.hasPrefix("#") else { return nil }
        let columns = line.components(separatedBy: "\t")
        return columns.count == 9 ? columns[8] : nil
    }
}

/// R5 item 3. Each negative control is a difference the mask must still show, and the positive control is the one
/// it must hide, a reload of the same annotations under new UUIDs.
final class AnnotationGFF3RelationalIDMaskTests: XCTestCase {
    private static func annotations(geneEnd: Int = 60, transcriptName: String = "tx-b") -> [SequenceAnnotation] {
        [
            SequenceAnnotation(type: .gene, name: "gene-a", chromosome: "chr1", start: 10, end: geneEnd, strand: .forward),
            SequenceAnnotation(
                type: .mRNA, name: transcriptName, chromosome: "chr1",
                intervals: [AnnotationInterval(start: 100, end: 120), AnnotationInterval(start: 170, end: 200)],
                strand: .forward, qualifiers: ["gene": AnnotationQualifier("gene-a")]
            ),
        ]
    }

    private func gff3(_ annotations: [SequenceAnnotation]) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationGFF3RelationalIDMask-\(UUID().uuidString).gff3")
        defer { try? FileManager.default.removeItem(at: url) }
        try await GFF3Writer.write(annotations, to: url, source: "Lungfish")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testAReloadUnderNewUUIDsIsEqualUnderTheMask() async throws {
        // Each call builds the annotations under new UUIDs, as a second load of one database gives them.
        let first = try await gff3(Self.annotations())
        let second = try await gff3(Self.annotations())
        XCTAssertNotEqual(first, second, "the raw texts differ in their IDs")
        XCTAssertEqual(AnnotationGFF3RelationalIDMask.masked(first), AnnotationGFF3RelationalIDMask.masked(second))
        let masked = AnnotationGFF3RelationalIDMask.masked(first)
        XCTAssertEqual(masked.components(separatedBy: "ID=<ID-2>").count - 1, 2, "the two lines of tx-b share one token\n\(masked)")
    }

    /// Control (a). One feature's two lines given two different IDs on one side.
    func testSplittingOneFeaturesIDIsADifference() async throws {
        let annotations = Self.annotations()
        let reference = try await gff3(annotations)
        let shared = "ID=" + annotations[1].id.uuidString
        let second = try XCTUnwrap(reference.range(of: shared, range: try XCTUnwrap(reference.range(of: shared)).upperBound..<reference.endIndex))
        let split = reference.replacingCharacters(in: second, with: "ID=" + UUID().uuidString)
        XCTAssertNotEqual(AnnotationGFF3RelationalIDMask.masked(reference), AnnotationGFF3RelationalIDMask.masked(split))
    }

    /// Control (b). One coordinate changed.
    func testAChangedCoordinateIsADifference() async throws {
        let reference = try await gff3(Self.annotations())
        let moved = try await gff3(Self.annotations(geneEnd: 61))
        XCTAssertNotEqual(AnnotationGFF3RelationalIDMask.masked(reference), AnnotationGFF3RelationalIDMask.masked(moved))
    }

    /// Control (c). One `Name=` value changed.
    func testAChangedNameIsADifference() async throws {
        let reference = try await gff3(Self.annotations())
        let renamed = try await gff3(Self.annotations(transcriptName: "tx-c"))
        XCTAssertNotEqual(AnnotationGFF3RelationalIDMask.masked(reference), AnnotationGFF3RelationalIDMask.masked(renamed))
    }
}
