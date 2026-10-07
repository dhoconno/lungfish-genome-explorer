// FastqPrimerRemovalDialogDefaultsTests.swift - The primer-trimming dialog runs lungfish-cli's own bbduk defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The dialog's k defaulted to 15 while `fastq primer-remove --kmer` defaulted
// to 23, so a command typed without `--kmer` did not repeat a dialog run, and
// it was refused for every bundled scheme. The command's default is now the
// dialog's (L5, ruling on concern 3).

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO

@MainActor
final class FastqPrimerRemovalDialogDefaultsTests: XCTestCase {
    func testTheDialogsDefaultPrimerTrimNamesTheCommandsDefaults() throws {
        let input = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let primer = "ACTTCATGGCAGACGGGCGATT"
        let state = FASTQOperationDialogState(initialCategory: .trimmingFiltering, selectedInputURLs: [input])
        state.selectTool(.primerTrimming)
        state.primerTrimmingLiteralSequence = primer
        state.prepareForRun()
        let request = try XCTUnwrap(state.pendingLaunchRequest)
        let invocation = try FASTQOperationExecutionService().buildInvocation(for: request)
        let arguments = invocation.arguments
        XCTAssertEqual(arguments.first, "primer-remove")

        // The dialog names k, mink and hdist whatever their values.
        func value(of option: String) -> String? {
            arguments.firstIndex(of: option).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        XCTAssertEqual(value(of: "--kmer"), "15")
        XCTAssertEqual(value(of: "--mink"), "11")
        XCTAssertEqual(value(of: "--hdist"), "1")

        let dialog = try FastqPrimerRemovalSubcommand.parse(Array(arguments.dropFirst()))
        let commandLine = try FastqPrimerRemovalSubcommand.parse([input.path, "--literal", primer, "-o", "<derived>"])
        XCTAssertEqual(dialog.kmerSize, commandLine.kmerSize, "the dialog's k is the command's default")
        XCTAssertEqual(dialog.minKmer, commandLine.minKmer)
        XCTAssertEqual(dialog.hammingDistance, commandLine.hammingDistance)
    }
}
