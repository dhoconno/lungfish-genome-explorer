// FASTQContaminantReferenceCommandTests.swift - A contaminant filter records its reference by the absolute path the run reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The contaminant filter's recorded `--ref` carried the reference string as the
// request gave it (R3, R8). The FASTQ operations dialog reads a relative
// reference inside the input bundle
// (`FASTQOperationCLIInvocationBuilder.contaminantReferencePath`), while
// `lungfish-cli fastq contaminant-filter` reads it from its own working
// directory, so a recorded command that kept the relative path found no
// reference, or another file, when it ran from another folder. These tests show
// the recorded command names the absolute file the run reads, in the dialog row
// and in the command the importer records in the manifest.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQContaminantReferenceCommandTests: XCTestCase {
    /// A fresh folder, removed when the test ends.
    private func makeRoot() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "contaminant-reference-command")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    /// A root bundle with two reads in a project's Imports folder, with a
    /// contaminant FASTA at `relativeReference` from the bundle.
    private func makeBundle(named name: String, referenceAt relativeReference: String, in root: URL) throws -> URL {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@read-1\nACGTACGTAC\n+\nIIIIIIIIII\n@read-2\nTTGACCAGTA\n+\nIIIIIIIIII\n"
            .write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let reference = bundle.appendingPathComponent(relativeReference).standardizedFileURL
        try FileManager.default.createDirectory(
            at: reference.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ">contaminant\nGGGGGGGGGGGG\n".write(to: reference, atomically: true, encoding: .utf8)
        return bundle
    }

    private func contaminantFilter(reference: String) -> FASTQDerivativeRequest {
        .contaminantFilter(mode: .custom, referenceFasta: reference, kmerSize: 27, hammingDistance: 1)
    }

    func testRelativeReferenceIsRecordedAsTheAbsolutePathInsideTheInputBundle() throws {
        let root = try makeRoot()
        // One reference inside the bundle, one in the project beside it.
        let references = [
            ("Sample_1", "refs/lane-1k4-contaminants.fasta"),
            ("Sample_2", "../../References/lane-1k4-contaminants.fasta"),
        ]
        for (name, relative) in references {
            let bundle = try makeBundle(named: name, referenceAt: relative, in: root)
            // The run reads `bundle.appendingPathComponent(path)`.
            let runReference = bundle.appendingPathComponent(relative).path

            // The command the importer records in the manifest of a derivative of this bundle.
            let recorded = try XCTUnwrap(
                contaminantFilter(reference: relative).cliCommand(
                    inputPath: bundle.path,
                    outputPath: root.appendingPathComponent("out/reads.fastq").path
                ),
                relative
            )
            let command = try RecordedCLICommand.parse(recorded, as: FastqContaminantFilterSubcommand.self)
            let reference = try XCTUnwrap(command.reference, relative)
            XCTAssertEqual(reference, runReference, "the command used to pass \(relative) as given")
            // The command resolves an absolute path the same way from any
            // folder, where the relative one depended on its working directory.
            XCTAssertEqual(
                try FastqContaminantFilterSubcommand.bbdukReferenceURL(mode: command.mode, reference: command.reference).path,
                reference
            )
            XCTAssertThrowsError(
                try FastqContaminantFilterSubcommand.bbdukReferenceURL(mode: command.mode, reference: relative),
                "\(relative) does not resolve from this process's working directory"
            )
        }
    }

    func testTheDialogRowAndTheExecutedInvocationRecordTheReferenceInsideTheInputBundle() throws {
        let root = try makeRoot()
        let bundle = try makeBundle(named: "Sample 3", referenceAt: "refs/lane-1k4-contaminants.fasta", in: root)
        let expected = bundle.appendingPathComponent("refs/lane-1k4-contaminants.fasta").path
        let request = contaminantFilter(reference: "refs/lane-1k4-contaminants.fasta")

        let launch = FASTQOperationLaunchRequest.derivative(request: request, inputURLs: [bundle], outputMode: .perInput)
        let dialogReporter = RecordingOperationReporter()
        MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: Contaminant Filter",
            request: launch,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            reporter: dialogReporter
        ) { _ in }
        let dialogRow = try RecordedCLICommand.parse(
            dialogReporter.items.first?.cliCommand,
            as: FastqContaminantFilterSubcommand.self
        )
        XCTAssertEqual(dialogRow.reference, expected)

        // The execution service hands the builder a materialized scratch file
        // and the bundle the user chose as the pairing metadata.
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: .derivative(
                request: request,
                inputURLs: [root.appendingPathComponent("materialized-inputs/Sample 3.fastq")],
                outputMode: .perInput
            ),
            outputTargetPath: root.appendingPathComponent("work/Sample 3.fastq").path,
            pairingMetadataURL: bundle
        )
        let executed = try RecordedCLICommand.parse(
            FASTQOperationCLIInvocationBuilder.commandLine(for: invocation),
            as: FastqContaminantFilterSubcommand.self
        )
        XCTAssertEqual(executed.reference, expected)
    }

    func testRelativeReferenceWithoutAnInputBundleRecordsNoCommand() throws {
        // CLI parity gap. A relative reference beside a FASTQ that is not in a
        // bundle has no folder the run would read it from, so the dialog row
        // records no command and a dialog run fails before the CLI starts.
        let reads = try makeRoot().appendingPathComponent("Reads/loose.fastq")
        try FileManager.default.createDirectory(at: reads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@read-1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let request = contaminantFilter(reference: "refs/lane-1k4-contaminants.fasta")

        let reporter = RecordingOperationReporter()
        MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: Contaminant Filter",
            request: .derivative(request: request, inputURLs: [reads], outputMode: .perInput),
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            reporter: reporter
        ) { _ in }
        XCTAssertNil(try XCTUnwrap(reporter.items.first).cliCommand)
        XCTAssertThrowsError(try FASTQOperationExecutionService().buildInvocation(
            for: .derivative(request: request, inputURLs: [reads], outputMode: .perInput)
        )) { error in
            XCTAssertEqual(
                error as? FASTQOperationCLIInvocationError,
                .contaminantReferenceNeedsBundle(reference: "refs/lane-1k4-contaminants.fasta")
            )
        }
    }
}
