// FASTQDerivativeToolCommandTests.swift - A derivative request records the lungfish-cli command that runs it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FASTQOperationOutputImporter records `FASTQDerivativeRequest.cliCommand` in a
// derived bundle's manifest (`operation.toolCommand`, which the Inspector shows
// with Copy). The manifest used to record native tool commands on scratch paths
// the run deletes, `lungfish fastq reverse-complement` with the legacy
// executable name, `lungfish fasta translate`, which is no command, or no
// command at all (R3, R8). These tests pin the commands for the requests that
// recorded those, and the parity gap of an orient run that saves unoriented
// reads.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKitTestSupport
import LungfishWorkflow

final class FASTQDerivativeToolCommandTests: XCTestCase {
    private let sourceBundle = URL(
        fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/Imports/Sample 1.lungfishfastq",
        isDirectory: true
    )
    private let outputBundle = URL(
        fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/Imports/Sample 1.lungfishfastq/derivatives/rc-1a2b3c4d.lungfishfastq",
        isDirectory: true
    )

    func testReverseComplementAndTranslateRecordTheFastqSubcommands() throws {
        // The manifest used to record `lungfish fastq reverse-complement` and
        // `lungfish fasta translate` on the run's scratch files.
        let reads = outputBundle.appendingPathComponent("reads.fastq")
        let reverse = try RecordedCLICommand.parse(
            FASTQDerivativeRequest.reverseComplement.cliCommand(inputPath: sourceBundle.path, outputPath: reads.path),
            as: FastqReverseComplementSubcommand.self
        )
        XCTAssertEqual(reverse.input, sourceBundle.path)
        XCTAssertEqual(reverse.output.output, reads.path)

        let protein = outputBundle.appendingPathComponent("reads.fasta")
        let translate = try RecordedCLICommand.parse(
            FASTQDerivativeRequest.translate(frameOffset: 2).cliCommand(inputPath: sourceBundle.path, outputPath: protein.path),
            as: FastqTranslateSubcommand.self
        )
        XCTAssertEqual(translate.input, sourceBundle.path)
        XCTAssertEqual(translate.frame, 3)
        XCTAssertEqual(translate.output.output, protein.path)
    }

    func testOrientRecordsTheOrientCommandUnlessTheRunSavesUnorientedReads() throws {
        let reference = URL(fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/ref.fasta")
        let command = try RecordedCLICommand.parse(
            FASTQDerivativeRequest.orient(
                referenceURL: reference, wordLength: 11, dbMask: "none", saveUnoriented: false,
                extraArguments: ["--id", "0.97"]
            ).cliCommand(inputPath: sourceBundle.path, outputPath: outputBundle.path),
            as: FastqOrientSubcommand.self
        )
        XCTAssertEqual(command.input, sourceBundle.path)
        XCTAssertEqual(command.reference, reference.path)
        XCTAssertEqual(command.wordLength, 11)
        XCTAssertEqual(command.dbMask, "none")
        XCTAssertEqual(command.extraArgs, "--id 0.97")
        XCTAssertEqual(command.output.output, outputBundle.path)

        // CLI parity gap. No `fastq orient` option saves the unoriented reads,
        // so a run that saves them records no command.
        XCTAssertNil(
            FASTQDerivativeRequest.orient(
                referenceURL: reference, wordLength: 11, dbMask: "none", saveUnoriented: true,
                extraArguments: ["--id", "0.97"]
            ).cliCommand(inputPath: sourceBundle.path, outputPath: outputBundle.path)
        )
    }
}
