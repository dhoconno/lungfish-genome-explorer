// MatePairFileNamingPlatformTests.swift - Long reads are never paired by file name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class MatePairFileNamingPlatformTests: XCTestCase {
    private let files = [URL(fileURLWithPath: "/data/x_1.fastq"), URL(fileURLWithPath: "/data/x_2.fastq")]

    func testShortReadFilesNamedAsMatesPair() {
        XCTAssertNotNil(MatePairFileNaming.matePair(in: files))
        XCTAssertNotNil(MatePairFileNaming.matePair(in: files, sequencingPlatform: .illumina))
        XCTAssertNotNil(MatePairFileNaming.matePair(in: files, sequencingPlatform: nil))
        XCTAssertNotNil(MatePairFileNaming.matePair(in: files, sequencingPlatform: .unknown))
    }

    func testLongReadFilesNamedAsMatesStaySingle() {
        XCTAssertNil(MatePairFileNaming.matePair(in: files, sequencingPlatform: .oxfordNanopore))
        XCTAssertNil(MatePairFileNaming.matePair(in: files, sequencingPlatform: .pacbio))
    }
}
