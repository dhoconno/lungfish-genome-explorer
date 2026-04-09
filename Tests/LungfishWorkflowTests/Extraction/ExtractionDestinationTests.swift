// ExtractionDestinationTests.swift — Value-type tests for destination + outcome + options
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ExtractionDestinationTests: XCTestCase {

    // MARK: - ExtractionOptions

    func testOptions_samtoolsExcludeFlags_includeUnmappedMatesFalse_returns0x404() {
        let opts = ExtractionOptions(format: .fastq, includeUnmappedMates: false)
        XCTAssertEqual(opts.samtoolsExcludeFlags, 0x404)
    }

    func testOptions_samtoolsExcludeFlags_includeUnmappedMatesTrue_returns0x400() {
        let opts = ExtractionOptions(format: .fastq, includeUnmappedMates: true)
        XCTAssertEqual(opts.samtoolsExcludeFlags, 0x400)
    }

    func testOptions_format_roundTripsFASTQandFASTA() {
        XCTAssertEqual(ExtractionOptions(format: .fastq, includeUnmappedMates: false).format, .fastq)
        XCTAssertEqual(ExtractionOptions(format: .fasta, includeUnmappedMates: true).format, .fasta)
    }

    // MARK: - CopyFormat

    func testCopyFormat_allCasesAndRawValues() {
        XCTAssertEqual(CopyFormat.fasta.rawValue, "fasta")
        XCTAssertEqual(CopyFormat.fastq.rawValue, "fastq")
        XCTAssertEqual(Set(CopyFormat.allCases), [.fasta, .fastq])
    }

    // MARK: - ExtractionDestination

    func testDestination_fileCase_isDistinctFromBundle() {
        let file: ExtractionDestination = .file(URL(fileURLWithPath: "/tmp/out.fastq"))
        let bundle: ExtractionDestination = .bundle(
            projectRoot: URL(fileURLWithPath: "/tmp/proj"),
            displayName: "x",
            metadata: ExtractionMetadata(sourceDescription: "s", toolName: "t")
        )
        // Can pattern-match — they are distinct cases
        switch file {
        case .file: break
        default: XCTFail("Expected .file case")
        }
        switch bundle {
        case .bundle: break
        default: XCTFail("Expected .bundle case")
        }
    }

    // MARK: - ExtractionOutcome

    func testOutcome_allCasesCarryReadCount() {
        let f: ExtractionOutcome = .file(URL(fileURLWithPath: "/tmp/a.fastq"), readCount: 10)
        let b: ExtractionOutcome = .bundle(URL(fileURLWithPath: "/tmp/a.lungfishfastq"), readCount: 20)
        let c: ExtractionOutcome = .clipboard(byteCount: 1234, readCount: 5)
        let s: ExtractionOutcome = .share(URL(fileURLWithPath: "/tmp/x.fastq"), readCount: 7)

        XCTAssertEqual(f.readCount, 10)
        XCTAssertEqual(b.readCount, 20)
        XCTAssertEqual(c.readCount, 5)
        XCTAssertEqual(s.readCount, 7)
    }
}
