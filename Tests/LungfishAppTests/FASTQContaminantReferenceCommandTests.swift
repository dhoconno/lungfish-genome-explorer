// FASTQContaminantReferenceCommandTests.swift - A contaminant filter records its reference by the absolute path the run reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The contaminant filter's recorded `--ref` carried the reference string as the
// request gave it (R3, R8). The in-process run
// (FASTQDerivativeService.runBBDukContaminantFilter) reads a relative reference
// inside the input bundle, while `lungfish-cli fastq contaminant-filter` reads
// it from its own working directory, so the recorded command found no
// reference, or another file, when it ran from another folder. These tests run
// the in-process filter with fake bbduk and seqkit tools and show the recorded
// command names the file the run read, at both FASTQ rows and in the manifest.

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

    /// A tool runner whose bbduk and seqkit are the fake scripts below.
    private func makeRunner(in root: URL) throws -> NativeToolRunner {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try Self.install(Self.bbdukScript, tool: "bbduk.sh", environment: "bbtools", home: home)
        try Self.install(Self.seqkitScript, tool: "seqkit", environment: "seqkit", home: home)
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
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

    func testRelativeReferenceIsRecordedAsTheAbsolutePathTheInProcessRunReads() async throws {
        let root = try makeRoot()
        let runner = try makeRunner(in: root)
        // One reference inside the bundle, one in the project beside it. The
        // names hold no whitespace, so NativeToolRunner hands bbduk the paths
        // themselves rather than staged links, and its step argv names the
        // reference the run read.
        let references = [
            ("Sample_1", "refs/lane-1k4-contaminants.fasta"),
            ("Sample_2", "../../References/lane-1k4-contaminants.fasta"),
        ]
        for (name, relative) in references {
            let bundle = try makeBundle(named: name, referenceAt: relative, in: root)
            // The in-process run reads `sourceBundleURL.appendingPathComponent(path)`.
            let runReference = bundle.appendingPathComponent(relative).path

            let output = try await FASTQDerivativeService(runner: runner).createDerivative(
                from: bundle,
                request: contaminantFilter(reference: relative)
            )

            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: output), relative)
            let command = try RecordedCLICommand.parse(
                manifest.operation.toolCommand,
                as: FastqContaminantFilterSubcommand.self
            )
            let recorded = try XCTUnwrap(command.reference, relative)
            XCTAssertEqual(recorded, runReference, "the command used to pass \(relative) as given")
            XCTAssertEqual(manifest.operation.contaminantReferenceFasta, relative, "the operation keeps the request's value")
            let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: output), relative)
            let bbduk = try XCTUnwrap(envelope.steps.first { $0.toolName == "bbduk.sh" }, relative)
            XCTAssertTrue(bbduk.argv.contains("ref=\(recorded)"), "the run read the file the command names: \(bbduk.argv)")
            // The command resolves an absolute path the same way from any
            // folder, where the relative one depended on its working directory.
            XCTAssertEqual(
                try FastqContaminantFilterSubcommand.bbdukReferenceURL(mode: command.mode, reference: command.reference).path,
                recorded
            )
            XCTAssertThrowsError(
                try FastqContaminantFilterSubcommand.bbdukReferenceURL(mode: command.mode, reference: relative),
                "\(relative) does not resolve from this process's working directory"
            )
        }
    }

    func testBothRowsAndTheDialogRunRecordTheReferenceInsideTheInputBundle() throws {
        let root = try makeRoot()
        let bundle = try makeBundle(named: "Sample 3", referenceAt: "refs/lane-1k4-contaminants.fasta", in: root)
        let expected = bundle.appendingPathComponent("refs/lane-1k4-contaminants.fasta").path
        let request = contaminantFilter(reference: "refs/lane-1k4-contaminants.fasta")

        let derivativeReporter = RecordingOperationReporter()
        _ = MainSplitViewController.beginFASTQDerivativeOperation(
            request: request,
            inputURL: bundle,
            routeContext: nil,
            reporter: derivativeReporter
        )
        let derivativeRow = try RecordedCLICommand.parse(
            derivativeReporter.items.first?.cliCommand,
            as: FastqContaminantFilterSubcommand.self
        )
        XCTAssertEqual(derivativeRow.reference, expected)

        let launch = FASTQOperationLaunchRequest.derivative(request: request, inputURLs: [bundle], outputMode: .perInput)
        let dialogReporter = RecordingOperationReporter()
        MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: Contaminant Filter",
            request: launch,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            reporter: dialogReporter
        ) { _ in }
        XCTAssertEqual(dialogReporter.items.first?.cliCommand, derivativeReporter.items.first?.cliCommand)

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
        // bundle has no folder the run would read it from, so neither row
        // records a command and a dialog run fails before the CLI starts.
        let reads = try makeRoot().appendingPathComponent("Reads/loose.fastq")
        try FileManager.default.createDirectory(at: reads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@read-1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let request = contaminantFilter(reference: "refs/lane-1k4-contaminants.fasta")

        let reporter = RecordingOperationReporter()
        _ = MainSplitViewController.beginFASTQDerivativeOperation(
            request: request,
            inputURL: reads,
            routeContext: nil,
            reporter: reporter
        )
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

    // MARK: - Fake tools

    private static func install(_ script: String, tool: String, environment: String, home: URL) throws {
        let bin = home.appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let url = bin.appendingPathComponent(tool)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Keeps every read, as bbduk does when no read matches the reference.
    private static let bbdukScript = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "BBDuk version 39.01"
          exit 0
        fi
        input=""
        output=""
        for arg in "$@"; do
          case "$arg" in
            in=*) input="${arg#in=}" ;;
            out=*) output="${arg#out=}" ;;
          esac
        done
        cp "$input" "$output"
        """

    /// Answers the read-ID, preview and statistics calls a subset derivative makes.
    private static let seqkitScript = """
        #!/bin/sh
        if [ "$1" = "version" ]; then
          echo "seqkit v2.8.2"
          exit 0
        fi
        command="$1"
        shift
        input=""
        output=""
        names=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) output="$2"; shift 2 ;;
            -m|-M|-j|-n|-p|-s) shift 2 ;;
            -2) shift ;;
            --name|--only-id) names=1; shift ;;
            -*) shift ;;
            *) input="$1"; shift ;;
          esac
        done
        if [ "$command" = "seq" ] && [ "$names" = "1" ]; then
          if [ -n "$output" ]; then
            awk 'NR % 4 == 1 { sub(/^@/, ""); split($0, a, " "); print a[1] }' "$input" > "$output"
          else
            awk 'NR % 4 == 1 { sub(/^@/, ""); split($0, a, " "); print a[1] }' "$input"
          fi
          exit 0
        fi
        if [ "$command" = "seq" ] || [ "$command" = "head" ]; then
          if [ -n "$output" ]; then cp "$input" "$output"; else cat "$input"; fi
          exit 0
        fi
        if [ "$command" = "stats" ]; then
          printf 'file\\tformat\\ttype\\tnum_seqs\\tsum_len\\tmin_len\\tavg_len\\tmax_len\\n'
          printf '%s\\tFASTQ\\tDNA\\t2\\t20\\t10\\t10.0\\t10\\n' "$input"
          exit 0
        fi
        exit 1
        """
}
