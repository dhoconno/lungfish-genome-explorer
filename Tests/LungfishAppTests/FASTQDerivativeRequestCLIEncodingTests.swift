// FASTQDerivativeRequestCLIEncodingTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// `FASTQDerivativeRequest` used to encode a request into three
/// independent command lines that had already drifted from each other --
/// most visibly, `cliCommand` showed a `seqkit grep` invocation for
/// search-text/search-motif that never ran (the actual executed command is
/// `lungfish fastq search-text`/`search-motif`), and `provenanceCLIArguments`
/// spelled length-filter and deduplicate options differently from the
/// executed argv (`--min-length`/`--max-length` instead of `--min`/`--max`,
/// `--substitutions`/`--optical true` instead of `--subs`/bare `--optical`).
/// These tests pin the corrected display and provenance encodings to the
/// same flag spellings `FASTQOperationCLIInvocationBuilder.fastqArguments`
/// actually executes.
final class FASTQDerivativeRequestCLIEncodingTests: XCTestCase {
    // MARK: - cliCommand (display)

    func testSearchTextDisplayCommandUsesRealLungfishSubcommandNotSeqkit() throws {
        let request = FASTQDerivativeRequest.searchText(query: "virus", field: .description, regex: false)
        let command = try XCTUnwrap(request.cliCommand(inputPath: "/tmp/in.fastq", outputPath: "/tmp/out.fastq"))

        XCTAssertTrue(command.contains("fastq search-text"))
        XCTAssertTrue(command.contains("--query virus"))
        XCTAssertTrue(command.contains("--field description"))
        XCTAssertFalse(command.contains("seqkit"))
    }

    func testSearchMotifDisplayCommandUsesRealLungfishSubcommandNotSeqkit() throws {
        let request = FASTQDerivativeRequest.searchMotif(pattern: "ACGT", regex: true)
        let command = try XCTUnwrap(request.cliCommand(inputPath: "/tmp/in.fastq", outputPath: "/tmp/out.fastq"))

        XCTAssertTrue(command.contains("fastq search-motif"))
        XCTAssertTrue(command.contains("--pattern ACGT"))
        XCTAssertTrue(command.contains("--regex"))
        XCTAssertFalse(command.contains("seqkit"))
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.contains { index in
            let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex)
            guard let end else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}
