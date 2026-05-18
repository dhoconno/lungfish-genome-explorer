// SequenceExportOptionsTests.swift - reusable sequence export option coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class SequenceExportOptionsTests: XCTestCase {
    func testFormatOptionsExposeFileExtensionsDisplayNamesAndCLITokens() {
        XCTAssertEqual(SequenceExportFormat.fasta.fileExtension, "fa")
        XCTAssertEqual(SequenceExportFormat.fasta.displayName, "FASTA")
        XCTAssertEqual(SequenceExportFormat.fasta.cliFormat, "fasta")

        XCTAssertEqual(SequenceExportFormat.genbank.fileExtension, "gb")
        XCTAssertEqual(SequenceExportFormat.genbank.displayName, "GenBank")
        XCTAssertEqual(SequenceExportFormat.genbank.cliFormat, "genbank")
    }

    func testCompressionOptionsExposeOptionalWrapperExtensions() {
        XCTAssertNil(SequenceExportCompression.none.fileExtension)
        XCTAssertEqual(SequenceExportCompression.gzip.fileExtension, "gz")
        XCTAssertEqual(SequenceExportCompression.zstd.fileExtension, "zst")
    }
}
