// ONTImportWordsTests.swift - The ONT import sheet and row count what the import makes
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp

/// ONT-WORDS (rewalk WO-11). The sheet said `Found 7 barcode directories` while the import made 6 bundles, since
/// an import with no processing recipe leaves the `unclassified` folder out, and the row said `1 barcode bundles` for one.
@MainActor
final class ONTImportWordsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = try TestTempDirectory.make(prefix: "ont-import-words")
    }

    override func tearDown() {
        if let tempDirectory {
            TestTempDirectory.cleanup(tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testONTSheetCountsBarcodesAndSaysTheUnclassifiedFolderIsLeftOut() throws {
        let layout = try ONTDirectoryImporter().detectLayout(at: try makeRun(barcodes: 6, withUnclassified: true))
        XCTAssertEqual(layout.barcodeDirectories.count, 7, "the fixture holds seven folders, one of them unclassified")

        let words = ONTImportOperationCoordinator.importSheetSummary(
            runName: "fastq_pass", layout: layout, formattedSize: "28 bytes"
        )
        XCTAssertTrue(words.contains("Found 6 barcode directories."), words)
        XCTAssertTrue(words.contains("Without a processing recipe, the import leaves the unclassified folder out."), words)
        XCTAssertTrue(words.contains("ONT run folder: fastq_pass"), words)
        XCTAssertTrue(words.contains("Total size: 28 bytes"), words)
        XCTAssertFalse(words.lowercased().contains("include"), "the app offers no way to include the folder, so the words promise none: \(words)")
    }

    func testONTSheetUsesTheSingularForOneFolderAndSaysNothingWithoutAnUnclassifiedFolder() throws {
        let layout = try ONTDirectoryImporter().detectLayout(at: try makeRun(barcodes: 1, withUnclassified: false))
        let words = ONTImportOperationCoordinator.importSheetSummary(
            runName: "fastq_pass", layout: layout, formattedSize: "4 bytes"
        )
        XCTAssertTrue(words.contains("Found 1 barcode directory."), words)
        XCTAssertFalse(words.lowercased().contains("unclassified"), "there is no unclassified folder to speak of: \(words)")
    }

    func testRowSaysOneBarcodeBundleInTheSingular() {
        XCTAssertEqual(ONTImportOperationCoordinator.completionDetail(bundleCount: 1), "1 barcode bundle")
        XCTAssertEqual(ONTImportOperationCoordinator.completionDetail(bundleCount: 6), "6 barcode bundles")
    }

    private func makeRun(barcodes: Int, withUnclassified: Bool) throws -> URL {
        let run = tempDirectory.appendingPathComponent("fastq_pass", isDirectory: true)
        let text = """
        @read1 runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01 basecall_model_version_id=dorado-test
        ACGT
        +
        !!!!

        """
        var names = (1...barcodes).map { String(format: "barcode%02d", $0) }
        if withUnclassified { names.append("unclassified") }
        for name in names {
            let folder = run.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        }
        return run
    }
}
