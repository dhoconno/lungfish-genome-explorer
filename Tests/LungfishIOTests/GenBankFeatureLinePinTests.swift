// GenBankFeatureLinePinTests.swift - The feature lines GenBankWriter prints for features GenBankReader read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.41 M1 (row M858 GENBANK-FEATURE-LINE, the BIO ruling on lane 12.13 section 3, QA 1). A
// GenBank file with a CDS of two parts marked partial at both ends, a reverse gene and an order() feature is
// read, written and read again. At the lane's base the writer printed each key in lower case and rebuilt each
// location from its ranges, so `CDS` became `cds`, the partial markers `<` and `>` were lost and `order()`
// became `join()`. Since M3 the writer prints the key and the location the reader read while they still
// describe the annotation, so the three lines read as the source had them (predictions P1 to P5), and the
// ranges and strands read back the same.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenBankFeatureLinePinTests: XCTestCase {
    /// A record of 160 bases with the three feature shapes the pin covers.
    static let source = """
    LOCUS       pinA                     160 bp    DNA     linear   SYN 01-JAN-2026
    DEFINITION  Synthetic record with a partial CDS, a reverse gene and an order feature.
    FEATURES             Location/Qualifiers
         CDS             join(<1..>30,50..80)
                         /codon_start=1
                         /product="partial protein"
         gene            complement(90..120)
                         /gene="geneR"
         misc_feature    order(130..140,150..160)
                         /note="ordered parts"
    ORIGIN
            1 acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac acgtacgtac ggttaaccgg
           61 ttaaccggtt acgtacgtac acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac
          121 acgtacgtac ggttaaccgg ttaaccggtt acgtacgtac
    //

    """

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("genbank-feature-line-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The feature lines a read and written file holds, and the ranges and strands it reads back.
    func testTheWriterKeepsTheFeatureLinesOfAReadFile() throws {
        let sourceURL = folder.appendingPathComponent("source.gb")
        try Self.source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let read = try GenBankReader(url: sourceURL).readAllSync()
        let record = try XCTUnwrap(read.first)
        XCTAssertEqual(record.annotations.map(\.type), [.cds, .gene, .misc_feature])

        let writtenURL = folder.appendingPathComponent("written.gb")
        try GenBankWriter(url: writtenURL).write(read)
        let text = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertEqual(Self.featureLines(text), [
            "     CDS             join(<1..>30,50..80)",
            "     gene            complement(90..120)",
            "     misc_feature    order(130..140,150..160)",
        ], text)
        XCTAssertTrue(text.contains("<1"), "the 5' partial marker is kept")
        XCTAssertTrue(text.contains(">30"), "the 3' partial marker is kept")
        XCTAssertTrue(text.contains("order("), "order() is kept")

        let reread = try XCTUnwrap(GenBankReader(url: writtenURL).readAllSync().first)
        XCTAssertEqual(reread.annotations.map(Self.shape), record.annotations.map(Self.shape))
    }

    /// The lines of `text` that open a feature, which start with five spaces and then the key.
    static func featureLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            line.hasPrefix("     ") && !line.hasPrefix("      ")
        }
    }

    /// The type, the ranges with their strands and the feature strand of `annotation`, without the phase.
    static func shape(_ annotation: SequenceAnnotation) -> String {
        let ranges = annotation.intervals.map { interval in
            "\(interval.start)-\(interval.end)" + (interval.strand.map { " \($0)" } ?? "")
        }
        return "\(annotation.type) [\(ranges.joined(separator: ", "))] \(annotation.strand)"
    }
}
