// FASTQDerivativeToolCommandTests.swift - In-process derivatives record the dataset viewport row's lungfish-cli command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ dataset viewport runs its derivatives in process through
// FASTQDerivativeService and records `FASTQDerivativeRequest.cliCommand` in
// its Operations row, with `<derived>` for the output. The derivative's
// manifest (`operation.toolCommand`, which the Inspector shows with Copy) used
// to record native tool commands on scratch paths the run deletes,
// `lungfish fastq reverse-complement` with the legacy executable name,
// `lungfish fasta translate`, which is no command, or no command at all
// (R3, R8). These tests pin the command the manifest now records, the row's
// command with the derivative's final output in place of `<derived>`.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class FASTQDerivativeToolCommandTests: XCTestCase {
    private let sourceBundle = URL(
        fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/Imports/Sample 1.lungfishfastq",
        isDirectory: true
    )
    private let outputBundle = URL(
        fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/Imports/Sample 1.lungfishfastq/derivatives/rc-1a2b3c4d.lungfishfastq",
        isDirectory: true
    )

    /// The command the dataset viewport's Operations row records for `request`.
    private func rowCommand(_ request: FASTQDerivativeRequest) throws -> String? {
        let reporter = RecordingOperationReporter()
        _ = MainSplitViewController.beginFASTQDerivativeOperation(
            request: request,
            inputURL: sourceBundle,
            routeContext: nil,
            reporter: reporter
        )
        return try XCTUnwrap(reporter.items.first).cliCommand
    }

    func testManifestCommandIsTheRowCommandWithTheFinalOutputInPlaceOfDerived() throws {
        let finalOutput = outputBundle.appendingPathComponent("reads.fastq")
        let requests = GenomicsDisplayDerivativeCases.bothSitesRecord().map(\.request)
            + MainSplitGenomicsDisplayOperationTests.requestsNoCLIOptionExpresses.map(\.1)
        for request in requests {
            let recorded = FASTQDerivativeService.derivativeToolCommand(
                for: request,
                sourceBundleURL: sourceBundle,
                finalOutputURL: finalOutput
            )
            guard let row = try rowCommand(request) else {
                // CLI parity gap, the list MainSplitGenomicsDisplayOperationTests
                // pins. No lungfish-cli option expresses the request, so the
                // manifest records no command either.
                XCTAssertNil(recorded, request.operationLabel)
                continue
            }
            let expected = try RecordedCLICommand.arguments(of: row).map {
                $0.replacingOccurrences(of: "<derived>", with: finalOutput.path)
            }
            XCTAssertEqual(try RecordedCLICommand.arguments(of: recorded), expected, request.operationLabel)
            XCTAssertNoThrow(try RecordedCLICommand.parse(recorded), request.operationLabel)
        }
    }

    func testReverseComplementAndTranslateRecordTheFastqSubcommands() throws {
        // The manifest used to record `lungfish fastq reverse-complement` and
        // `lungfish fasta translate` on the run's scratch files.
        let reads = outputBundle.appendingPathComponent("reads.fastq")
        let reverse = try RecordedCLICommand.parse(
            FASTQDerivativeService.derivativeToolCommand(
                for: .reverseComplement, sourceBundleURL: sourceBundle, finalOutputURL: reads
            ),
            as: FastqReverseComplementSubcommand.self
        )
        XCTAssertEqual(reverse.input, sourceBundle.path)
        XCTAssertEqual(reverse.output.output, reads.path)

        let protein = outputBundle.appendingPathComponent("reads.fasta")
        let translate = try RecordedCLICommand.parse(
            FASTQDerivativeService.derivativeToolCommand(
                for: .translate(frameOffset: 2), sourceBundleURL: sourceBundle, finalOutputURL: protein
            ),
            as: FastqTranslateSubcommand.self
        )
        XCTAssertEqual(translate.input, sourceBundle.path)
        XCTAssertEqual(translate.frame, 3)
        XCTAssertEqual(translate.output.output, protein.path)
    }

    func testSubsampleCommandsCarryTheSeedTheRunDrew() throws {
        let seed: UInt64 = 4_611_686_018_427_387_903
        for request in [FASTQDerivativeRequest.subsampleProportion(0.25), .subsampleCount(500)] {
            let command = try RecordedCLICommand.parse(
                FASTQDerivativeService.derivativeToolCommand(
                    for: request, sourceBundleURL: sourceBundle, finalOutputURL: outputBundle, randomSeed: seed
                ),
                as: FastqSubsampleSubcommand.self
            )
            XCTAssertEqual(command.seed, Int64(seed), "without the seed the command draws other reads")
            XCTAssertEqual(command.input, sourceBundle.path)
            XCTAssertEqual(command.output.output, outputBundle.path)
        }
        let lengthFilter = try XCTUnwrap(FASTQDerivativeService.derivativeToolCommand(
            for: .lengthFilter(min: 10, max: nil), sourceBundleURL: sourceBundle, finalOutputURL: outputBundle, randomSeed: 7
        ))
        XCTAssertFalse(lengthFilter.contains("--seed"), "only a subsample draws reads at random")
    }

    func testFinalOutputIsThePayloadFileOrTheBundle() {
        XCTAssertEqual(
            FASTQDerivativeService.derivativeFinalOutputURL(in: outputBundle, payload: .full(fastqFilename: "reads.fastq")),
            outputBundle.appendingPathComponent("reads.fastq")
        )
        XCTAssertEqual(
            FASTQDerivativeService.derivativeFinalOutputURL(in: outputBundle, payload: .fullFASTA(fastaFilename: "reads.fasta")),
            outputBundle.appendingPathComponent("reads.fasta")
        )
        let bundlePayloads: [FASTQDerivativePayload] = [
            .subset(readIDListFilename: "read-ids.txt"),
            .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
            .fullPaired(r1Filename: "R1.fastq", r2Filename: "R2.fastq"),
            .fullMixed(ReadClassification(files: [])),
            .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
        ]
        for payload in bundlePayloads {
            XCTAssertEqual(
                FASTQDerivativeService.derivativeFinalOutputURL(in: outputBundle, payload: payload),
                outputBundle,
                "\(payload) holds no single file the command writes"
            )
        }
    }

    func testOrientRecordsTheOrientCommandUnlessTheRunSavesUnorientedReads() throws {
        let reference = URL(fileURLWithPath: "/tmp/lane 1k3/Project.lungfish/ref.fasta")
        let scratch = URL(fileURLWithPath: "/tmp/lane 1k3/scratch/materialized.fastq")
        let config = OrientConfig(
            inputURL: scratch, referenceURL: reference, wordLength: 11, dbMask: "none", qMask: "none",
            saveUnoriented: false, extraArguments: ["--id", "0.97"]
        )
        let command = try RecordedCLICommand.parse(
            FASTQDerivativeService.derivativeToolCommand(
                forOrient: config, sourceBundleURL: sourceBundle, finalOutputURL: outputBundle
            ),
            as: FastqOrientSubcommand.self
        )
        XCTAssertEqual(command.input, sourceBundle.path, "the source bundle, not the scratch copy vsearch read")
        XCTAssertEqual(command.reference, reference.path)
        XCTAssertEqual(command.wordLength, 11)
        XCTAssertEqual(command.dbMask, "none")
        XCTAssertEqual(command.extraArgs, "--id 0.97")
        XCTAssertEqual(command.output.output, outputBundle.path)

        // CLI parity gap. No `fastq orient` option saves the unoriented reads,
        // so a run that saves them records no command. The manifest used to
        // record the app's own `lungfish-app-workflow:fastq-orient-derivative`
        // argv, which the provenance envelope still records.
        let saving = OrientConfig(
            inputURL: scratch, referenceURL: reference, wordLength: 11, dbMask: "none", qMask: "none",
            saveUnoriented: true, extraArguments: ["--id", "0.97"]
        )
        XCTAssertNil(FASTQDerivativeService.derivativeToolCommand(
            forOrient: saving, sourceBundleURL: sourceBundle, finalOutputURL: outputBundle
        ))
    }
}
