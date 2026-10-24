// ChunkBinningProgressTests.swift - A chunked ONT import says the importer's last word once, after the binning
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane ONT (O29-ONT-ONCE, SWIFT). A chunked import bins its chunks after the importer ends, so the
// importer's last word, "Import complete (N reads, Xs)", waits for `finish()` and the row says it once, as its last
// detail. These tests drive `ChunkBinningProgress` with the words the importer and the binning say. They need no
// BBTools, since the struct only reorders the words it is given.

import os
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ChunkBinningProgressTests: XCTestCase {
    private struct Report: Sendable {
        let fraction: Double
        let message: String

        /// The message with its fraction to two places, so one assertion shows both and no float compare is exact.
        var line: String { "\(message) @\(String(format: "%.2f", fraction))" }
    }

    private func makeProgress(
        storageMode: ONTImportStorageMode,
        into reports: OSAllocatedUnfairLock<[Report]>
    ) -> ChunkBinningProgress {
        ChunkBinningProgress(
            storageMode: storageMode,
            optimization: ONTImportWorkflow.OptimizationConfig(optimizeStorage: false, qualityBinning: .illumina4),
            report: { fraction, message in
                reports.withLock { $0.append(Report(fraction: fraction, message: message)) }
            }
        )
    }

    /// A storage mode that bins holds the importer's last word back, so the row says it once after the binning. At
    /// the base the word is reported at 0.8 and again by `finish()`, so this fails there with five reports.
    func testChunkedImportSaysTheImporterWordOnceAtTheEnd() {
        let reports = OSAllocatedUnfairLock<[Report]>(initialState: [])
        let progress = makeProgress(storageMode: .chunked, into: reports)

        progress.importer(0.5, "Reading")
        progress.importer(1.0, "Completed 2/2 barcodes")
        progress.importer(1.0, "Import complete (3 reads, 0.0s)")
        progress.binning(0.5, "Binning chunk 1 of 2")
        progress.finish()

        let said = reports.withLock { $0 }
        XCTAssertEqual(
            said.map(\.line),
            [
                "Reading @0.40",
                "Completed 2/2 barcodes @0.80",
                "Binning chunk 1 of 2 @0.90",
                "Import complete (3 reads, 0.0s) @1.00",
            ]
        )
        let fractions = said.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "the bar never moves back: \(fractions)")
    }

    /// A binning that fails or is cancelled ends the workflow before `finish()`, so no report ever says complete.
    /// At the base the importer's word is reported as it arrives, so this fails there.
    func testAChunkedImportThatEndsBeforeFinishNeverSaysComplete() {
        let reports = OSAllocatedUnfairLock<[Report]>(initialState: [])
        let progress = makeProgress(storageMode: .chunked, into: reports)

        progress.importer(1.0, "Completed 2/2 barcodes")
        progress.importer(1.0, "Import complete (3 reads, 0.0s)")
        progress.binning(0.5, "Binning chunk 1 of 2")

        let words = reports.withLock { $0 }.map(\.message)
        XCTAssertEqual(words, ["Completed 2/2 barcodes", "Binning chunk 1 of 2"])
    }

    /// A storage mode that does not bin keeps the importer's words as they are, including its last one. It passes at
    /// the base and pins the unchunked path.
    func testUnbinnedImportReportsAsTheImporterSays() {
        let reports = OSAllocatedUnfairLock<[Report]>(initialState: [])
        let progress = makeProgress(storageMode: .flattened, into: reports)

        progress.importer(0.5, "Reading")
        progress.importer(1.0, "Completed 2/2 barcodes")
        progress.importer(1.0, "Import complete (3 reads, 0.0s)")
        progress.finish()

        XCTAssertEqual(
            reports.withLock { $0 }.map(\.line),
            [
                "Reading @0.50",
                "Completed 2/2 barcodes @1.00",
                "Import complete (3 reads, 0.0s) @1.00",
            ]
        )
    }
}
