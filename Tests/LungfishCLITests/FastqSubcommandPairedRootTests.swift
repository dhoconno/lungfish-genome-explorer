// FastqSubcommandPairedRootTests.swift - A fastq subcommand given a root of R1 and R2 files refuses with words (Phase 3.3 lane PAIREDROOT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// `lungfish-cli extract reads --by-id --source R1 --source R2 --bundle` writes a `.lungfishfastq` root that holds an `_R1`
/// and an `_R2` file with no `source-files.json`. A `fastq` subcommand reads one file, so given that root it read R1 alone
/// and left R2 out with no word (BIO-PAIRED-ROOT-DERIVATIVES, S1). It now stops with words before it runs. A file named
/// inside the root is still read in place, a person's explicit choice.
final class FastqSubcommandPairedRootTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-paired-root")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testFastqSubcommandOfPairedRootRefusesAndItsR1FileReadsInPlace() async throws {
        let bundle = root.appendingPathComponent("pair-extract.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let r1 = bundle.appendingPathComponent("s_R1.fastq")
        let r2 = bundle.appendingPathComponent("s_R2.fastq")
        try "@a\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@a\nGGCC\n+\n++++\n".write(to: r2, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("trimmed.fastq")

        do {
            let input = try await FASTQSubcommandInput.resolve(bundle.path, operationName: "trim", contextURL: output)
            input.cleanup()
            XCTFail("a root of R1 and R2 files resolved to \(input.executionURL.lastPathComponent)")
        } catch {
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("s_R1.fastq"), "the words name R1: \(words)")
            XCTAssertTrue(words.contains("s_R2.fastq"), "the words name R2: \(words)")
            XCTAssertTrue(words.contains("nothing was run"), "the words say nothing was run: \(words)")
        }

        let inPlace = try await FASTQSubcommandInput.resolve(r1.path, operationName: "trim", contextURL: output)
        XCTAssertEqual(inPlace.executionURL.standardizedFileURL, r1.standardizedFileURL, "R1 named by file is read where it is")
        XCTAssertFalse(inPlace.wasMaterialized)
    }
}
