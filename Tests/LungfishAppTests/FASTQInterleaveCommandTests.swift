// FASTQInterleaveCommandTests.swift - An interleave records the R1 and R2 files of the paired bundle it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FASTQOperationCLIInvocationBuilder wrote `fastq interleave --in1 <input>
// --in2 '<R2>'`, with a literal placeholder for the second file (R3, R8). No
// GUI path builds an interleave request today. The FASTQ operations dialog has
// no interleave tool, the dataset viewport's operation list has none and no
// recipe step interleaves, so no run executed that command. The derivative
// row, the dialog row and both manifest writers record the builder's command,
// and the in-process interleave reads the R1 and R2 files of a `fullPaired`
// bundle. These tests show the command now names those two files, and that an
// input without them records no command.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQInterleaveCommandTests: XCTestCase {
    private let interleave = FASTQDerivativeRequest.interleaveReformat(direction: .interleave)

    /// Bundles of each shape in a fresh project, removed when the test ends.
    private func makeShapes() throws -> (root: URL, shapes: AssemblyBundleShapes) {
        let root = try TestTempDirectory.make(prefix: "fastq-interleave-command")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let shapes = try AssemblyBundleShapes(in: root.appendingPathComponent("Project.lungfish", isDirectory: true))
        return (root, shapes)
    }

    /// The command the dataset viewport's derivative row records for `input`.
    private func derivativeRowCommand(input: URL) throws -> String? {
        let reporter = RecordingOperationReporter()
        _ = MainSplitViewController.beginFASTQDerivativeOperation(
            request: interleave,
            inputURL: input,
            routeContext: nil,
            reporter: reporter
        )
        return try XCTUnwrap(reporter.items.first).cliCommand
    }

    /// The command the FASTQ operations dialog row records for `input`.
    private func dialogRowCommand(input: URL) throws -> String? {
        let reporter = RecordingOperationReporter()
        MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: Interleave Reformat",
            request: .derivative(request: interleave, inputURLs: [input], outputMode: .perInput),
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            reporter: reporter
        ) { _ in }
        return try XCTUnwrap(reporter.items.first).cliCommand
    }

    func testInterleaveNamesTheR1AndR2FilesOfThePairedBundle() throws {
        let (root, shapes) = try makeShapes()
        // The files the in-process interleave hands reformat.sh as in1 and in2.
        let runFiles = try XCTUnwrap(FASTQBundle.pairedFASTQURLs(forDerivedBundle: shapes.paired))
        XCTAssertEqual([runFiles.r1.path, runFiles.r2.path], shapes.pairedFiles.map(\.path))

        let row = try derivativeRowCommand(input: shapes.paired)
        let command = try RecordedCLICommand.parse(row, as: FastqInterleaveSubcommand.self)
        XCTAssertEqual(command.in1, runFiles.r1.path)
        XCTAssertEqual(command.in2, runFiles.r2.path, "the command used to pass the literal <R2>")
        XCTAssertEqual(command.output.output, "<derived>")
        XCTAssertTrue(FileManager.default.fileExists(atPath: command.in2))
        XCTAssertEqual(try dialogRowCommand(input: shapes.paired), row, "both rows record the builder's command")

        // The manifest records the row's command with the payload in place of <derived>.
        let payload = root.appendingPathComponent("interleaved.lungfishfastq/reads.fastq")
        let manifestCommand = FASTQDerivativeService.derivativeToolCommand(
            for: interleave,
            sourceBundleURL: shapes.paired,
            finalOutputURL: payload
        )
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: manifestCommand),
            try RecordedCLICommand.arguments(of: row).map { $0 == "<derived>" ? payload.path : $0 }
        )
    }

    func testDialogRunNamesThePairedBundlesFilesAfterTheInputIsMaterialized() throws {
        let (root, shapes) = try makeShapes()
        // The execution service hands the builder a materialized scratch file
        // and the bundle the user chose as the pairing metadata. The command
        // it runs reads the bundle's R1 and R2, the files the row records.
        let scratch = root.appendingPathComponent("materialized-inputs/paired.fastq")
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: .derivative(request: interleave, inputURLs: [scratch], outputMode: .perInput),
            outputTargetPath: root.appendingPathComponent("work/paired.fastq").path,
            pairingMetadataURL: shapes.paired
        )
        let command = try RecordedCLICommand.parse(
            FASTQOperationCLIInvocationBuilder.commandLine(for: invocation),
            as: FastqInterleaveSubcommand.self
        )
        XCTAssertEqual([command.in1, command.in2], shapes.pairedFiles.map(\.path))
    }

    func testInterleaveOfAnInputWithoutSeparateR1AndR2FilesRecordsNoCommand() throws {
        let (root, shapes) = try makeShapes()
        // CLI parity gap. The request carries no R2, so an input that is not a
        // paired bundle has no second file to name. Neither row records a
        // command, the manifest records none and a dialog run fails before
        // the CLI starts.
        for input in [shapes.single, shapes.interleaved, shapes.looseFiles[0]] {
            let name = input.lastPathComponent
            XCTAssertNil(try derivativeRowCommand(input: input), name)
            XCTAssertNil(try dialogRowCommand(input: input), name)
            XCTAssertNil(
                FASTQDerivativeService.derivativeToolCommand(
                    for: interleave,
                    sourceBundleURL: input,
                    finalOutputURL: root.appendingPathComponent("out.fastq")
                ),
                name
            )
            XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(
                for: .derivative(request: interleave, inputURLs: [input], outputMode: .perInput)
            )) { error in
                XCTAssertEqual(
                    error as? FASTQOperationCLIInvocationError,
                    .interleaveNeedsPairedBundle(input: input.path),
                    name
                )
            }
        }
    }
}
