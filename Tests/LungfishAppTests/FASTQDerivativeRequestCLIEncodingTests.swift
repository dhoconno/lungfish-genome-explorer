// FASTQDerivativeRequestCLIEncodingTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

/// SIMP-01: `FASTQDerivativeRequest` used to encode a request into three
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

    func testSearchTextDisplayCommandUsesRealLungfishSubcommandNotSeqkit() {
        let request = FASTQDerivativeRequest.searchText(query: "virus", field: .description, regex: false)
        let command = request.cliCommand(inputPath: "/tmp/in.fastq", outputPath: "/tmp/out.fastq")

        XCTAssertTrue(command.contains("fastq search-text"))
        XCTAssertTrue(command.contains("--query virus"))
        XCTAssertTrue(command.contains("--field description"))
        XCTAssertFalse(command.contains("seqkit"))
    }

    func testSearchMotifDisplayCommandUsesRealLungfishSubcommandNotSeqkit() {
        let request = FASTQDerivativeRequest.searchMotif(pattern: "ACGT", regex: true)
        let command = request.cliCommand(inputPath: "/tmp/in.fastq", outputPath: "/tmp/out.fastq")

        XCTAssertTrue(command.contains("fastq search-motif"))
        XCTAssertTrue(command.contains("--pattern ACGT"))
        XCTAssertTrue(command.contains("--regex"))
        XCTAssertFalse(command.contains("seqkit"))
    }

    // MARK: - provenanceCLIArguments (recorded argv)

    func testLengthFilterProvenanceUsesMinMaxNotMinLengthMaxLength() {
        let request = FASTQDerivativeRequest.lengthFilter(min: 50, max: 500)
        let args = request.provenanceCLIArguments

        XCTAssertTrue(args.containsSequence(["--min", "50"]))
        XCTAssertTrue(args.containsSequence(["--max", "500"]))
        XCTAssertFalse(args.contains("--min-length"))
        XCTAssertFalse(args.contains("--max-length"))
    }

    func testSearchTextProvenanceUsesBareRegexFlagNotBooleanString() {
        let requestWithRegex = FASTQDerivativeRequest.searchText(query: "q", field: .id, regex: true)
        XCTAssertTrue(requestWithRegex.provenanceCLIArguments.contains("--regex"))
        XCTAssertFalse(requestWithRegex.provenanceCLIArguments.contains("true"))

        let requestWithoutRegex = FASTQDerivativeRequest.searchText(query: "q", field: .id, regex: false)
        XCTAssertFalse(requestWithoutRegex.provenanceCLIArguments.contains("--regex"))
        XCTAssertFalse(requestWithoutRegex.provenanceCLIArguments.contains("false"))
    }

    func testDeduplicateProvenanceUsesSubsAndBareOpticalFlagMatchingExecutedArgv() {
        let request = FASTQDerivativeRequest.deduplicate(
            preset: .exactPCR,
            substitutions: 2,
            optical: true,
            opticalDistance: 12000
        )
        let args = request.provenanceCLIArguments

        XCTAssertTrue(args.containsSequence(["--subs", "2"]))
        XCTAssertTrue(args.contains("--optical"))
        XCTAssertTrue(args.containsSequence(["--dupedist", "12000"]))
        XCTAssertFalse(args.contains("--substitutions"))
        XCTAssertFalse(args.contains("--optical-distance"))
    }

    func testDeduplicateProvenanceOmitsOpticalFlagsWhenNotOptical() {
        let request = FASTQDerivativeRequest.deduplicate(
            preset: .exactPCR,
            substitutions: 1,
            optical: false,
            opticalDistance: 40
        )
        let args = request.provenanceCLIArguments

        XCTAssertFalse(args.contains("--optical"))
        XCTAssertFalse(args.contains("--dupedist"))
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
