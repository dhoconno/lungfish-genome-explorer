// CountedFASTQMaterializerTests+PlaceholderPin.swift - The reader knows what the writer wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

extension CountedFASTQMaterializerTests {
    /// The reader of the quality origin recognizes counted reads by the form `CountedFASTQMaterializer` writes (lane
    /// FLUIDIGM-UNLINKED, ruling BIO-FLUIDIGM-UNLINKED). The test writes the reads with the real writer, so a change to
    /// the name or the score form fails here and not in a bundle that was made long ago.
    func testCountedReadsAreRecognizedAsPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountedPlaceholderPin-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("counted.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let writer = CountedFASTQMaterializer()
        let counts = ["ACGTACGTAC": 7, "TTTTGGGGCC": 3, "GATTACAGAT": 1]

        _ = try writer.write(counts: counts, outputURL: bundle.appendingPathComponent("reads.fastq"))
        XCTAssertTrue(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: bundle),
            "plain text reads written by the materializer"
        )

        try FileManager.default.removeItem(at: bundle.appendingPathComponent("reads.fastq"))
        _ = try writer.write(counts: counts, outputURL: bundle.appendingPathComponent("reads.fastq.gz"))
        XCTAssertTrue(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: bundle),
            "gzip reads written by the materializer"
        )
    }
}
