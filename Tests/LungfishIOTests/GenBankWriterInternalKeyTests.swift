// GenBankWriterInternalKeyTests.swift - The GenBank writer keeps Lungfish's internal keys out of its qualifiers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (CDS-FRAME-TABLE), 13.65-ARCH Fix 3. A feature read from a bundle carries Lungfish's own
// bookkeeping (`GFF3ExportIdentifiers.internalKeys`) as qualifiers, and `lungfish-cli convert <bundle> --to genbank`
// and the viewer's GenBank export hand them to `GenBankWriter`. No GFF3 file leaves the app with these keys, and no
// GenBank file does either.

import Foundation
import XCTest
import LungfishCore
@testable import LungfishIO

final class GenBankWriterInternalKeyTests: XCTestCase {
    func testGenBankWriterDropsTheGFF3InternalKeys() throws {
        let record = GenBankRecord(
            sequence: try Sequence(name: "KEYS", alphabet: .dna, bases: "ACGTACGTACGT"),
            annotations: [
                SequenceAnnotation(
                    type: .cds,
                    name: "g",
                    start: 0,
                    end: 12,
                    strand: .forward,
                    qualifiers: [
                        "gene": AnnotationQualifier("g"),
                        GFF3ExportIdentifiers.phaseKey: AnnotationQualifier("2"),
                        GFF3ExportIdentifiers.cdsPhaseKey: AnnotationQualifier("1"),
                        GFF3ExportIdentifiers.trackIDKey: AnnotationQualifier("t1"),
                    ]
                ),
            ],
            locus: LocusInfo(name: "KEYS", length: 12, moleculeType: .dna, topology: .linear)
        )
        let writer = GenBankWriter(url: FileManager.default.temporaryDirectory.appendingPathComponent("unused-keys.gb"))

        let text = writer.format(record)

        XCTAssertTrue(text.contains("/gene=\"g\""), "an ordinary qualifier is still written:\n\(text)")
        for key in ["lungfish_gff_phase", "lungfish_cds_phase", "annotation_db_track_id"] {
            XCTAssertFalse(text.contains(key), "\(key) reached the GenBank text:\n\(text)")
        }
        for key in GFF3ExportIdentifiers.internalKeys {
            XCTAssertFalse(text.contains(key), "the internal key \(key) reached the GenBank text:\n\(text)")
        }
    }
}
