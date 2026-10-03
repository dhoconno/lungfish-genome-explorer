// ONTSampleMaterializationCommandTests.swift - The ONT sample materializers record the command that rewrites each sample bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The three ONT sample materializers in LungfishWorkflow write one
// .lungfishfastq bundle per sample, and each bundle's manifest records a
// command (`operation.toolCommand`, which the Inspector shows with Copy). They
// recorded `lungfish fastq ont-fluidigm-samples` or `lungfish fastq
// ont-pacbio-barcode-demux`, the legacy executable name with no arguments
// (R3, R8). These tests run each materializer on a small fixture, parse the
// recorded command with the real CLI parser, run it again into the same folder
// and compare the sample bundles. The materializer no lungfish-cli command
// runs records a `Lungfish.app` form, a pinned CLI parity gap. The last test
// runs the ONT Fluidigm Sample Split launch through
// FASTQOperationExecutionService, as the FASTQ operations dialog and the
// import sheet do.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class ONTSampleMaterializationCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ont-sample-commands")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - PacBio barcode pairs

    func testPacBioSampleBundlesRecordTheDemuxCommandThatRewritesThem() async throws {
        let input = root.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Self.writeFASTQ([
            ("read-1", Self.pacBioRead(forward: "CACATATCAGAGTGCG", reverse: "CTATACATAGTGATGT")),
            ("read-2", Self.pacBioRead(forward: "ACACACAGACTGTGAG", reverse: "CACTCACGTGTGATAT")),
            ("read-3", String(repeating: "N", count: 2_100)),
        ], to: input.appendingPathComponent("chunk-1.fastq"))
        let sheet = root.appendingPathComponent("plate 1 barcodes.csv")
        try "sample_id,barcode_1,barcode_2\nMm-001,bc1001,bc1021\nMm-002,bc1002,bc1022\n"
            .write(to: sheet, atomically: true, encoding: .utf8)
        let request = ONTPacBioBarcodeDemuxMaterializationRequest(
            inputURL: input,
            barcodeDefinitionsURL: sheet,
            outputDirectory: root.appendingPathComponent("pacbio demux", isDirectory: true),
            threads: 2,
            chunkJobs: 3,
            maxReadsPerSlice: 50_000,
            maxInputBytesPerCutadapt: 1_000_000
        )

        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(request)

        let bundles = result.outputBundleURLs.map(\.lastPathComponent)
        XCTAssertEqual(bundles, ["Mm-001.lungfishfastq", "Mm-002.lungfishfastq"])
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: result.outputBundleURLs[0]))
        let toolCommand = try XCTUnwrap(manifest.operation.toolCommand)
        XCTAssertEqual(toolCommand, request.recordedCommandLine)
        XCTAssertEqual(manifest.operation.toolUsed, "exact-barcode-demux", "the tool stays the demultiplexing engine")
        let command = try RecordedCLICommand.parse(toolCommand, as: FastqONTPacBioBarcodeDemuxSubcommand.self)
        XCTAssertEqual(command.input, input.path)
        XCTAssertEqual(command.barcodes, sheet.path)
        XCTAssertEqual(command.output, request.outputDirectory.path)
        XCTAssertEqual(command.chunkJobs, 3)
        XCTAssertEqual(command.maxReadsPerSlice, 50_000)
        XCTAssertEqual(command.maxBytesPerCutadapt, 1_000_000)
        XCTAssertFalse(command.force)
        XCTAssertEqual(command.threads, 2)

        // The command, run again into the same folder, writes the same sample
        // bundles and records itself in them and in its own envelope.
        let appOutput = root.appendingPathComponent("pacbio demux from the app", isDirectory: true)
        try FileManager.default.moveItem(at: request.outputDirectory, to: appOutput)
        try await command.run()
        for bundle in bundles {
            try await assertSameReads(
                appOutput.appendingPathComponent(bundle),
                request.outputDirectory.appendingPathComponent(bundle)
            )
            let rerun = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: request.outputDirectory.appendingPathComponent(bundle)))
            XCTAssertEqual(rerun.operation.toolCommand, toolCommand, bundle)
        }
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: request.outputDirectory))
        XCTAssertEqual(envelope.argv, request.recordedCommandArguments, "the argv the command records for its own run")
    }

    // MARK: - Fluidigm CS1 to CS2 inserts

    func testFluidigmSampleBundlesRecordTheSamplesCommandThatRewritesThem() async throws {
        let input = root.appendingPathComponent("barcode11.fastq")
        try Self.writeFASTQ(Self.fluidigmReads(), to: input)
        let sheet = root.appendingPathComponent("NB11 samples.csv")
        try "sample,barcode\nLF2871,AAAACCCCGG\nLF2872,GGGGTTTTAA\n".write(to: sheet, atomically: true, encoding: .utf8)
        // The request canonicalizes reverse complements by default and the
        // command does not, so the command spells the setting out.
        let request = ONTFluidigmAmpliconMaterializationRequest(
            inputURL: input,
            barcodeDefinitionsURL: sheet,
            outputDirectory: root.appendingPathComponent("fluidigm samples", isDirectory: true),
            primerMismatches: 1,
            minimumInsertLength: 8,
            threads: 3
        )
        XCTAssertTrue(request.canonicalizeReverseComplements)

        let result = try await ONTFluidigmAmpliconMaterializer().run(request)

        let bundles = result.outputBundleURLs.map(\.lastPathComponent)
        XCTAssertEqual(bundles, ["LF2871.lungfishfastq", "LF2872.lungfishfastq"])
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: result.outputBundleURLs[0]))
        let toolCommand = try XCTUnwrap(manifest.operation.toolCommand)
        XCTAssertEqual(toolCommand, request.recordedCommandLine)
        XCTAssertEqual(manifest.operation.toolUsed, CLICommandIdentity.executableName, "it used to be the legacy name lungfish")
        let command = try RecordedCLICommand.parse(toolCommand, as: FastqONTFluidigmSamplesSubcommand.self)
        XCTAssertEqual(command.input, input.path)
        XCTAssertEqual(command.barcodes, sheet.path)
        XCTAssertEqual(command.output, request.outputDirectory.path)
        XCTAssertEqual(command.primerMismatches, 1)
        XCTAssertEqual(command.minimumInsertLength, 8)
        XCTAssertTrue(command.canonicalizeReverseComplements, "the run canonicalized reverse complements")
        XCTAssertFalse(command.force)
        XCTAssertEqual(command.threads, 3)

        // The command, run again into the same folder, writes the same sample
        // bundles and records itself in them and in its own envelope. Its
        // provenance step used to refuse the checksum-less folder records, so
        // every run failed after writing the bundles, and its argv left out
        // `--canonicalize-reverse-complements`, so a replay ran without it.
        let appOutput = root.appendingPathComponent("fluidigm samples from the app", isDirectory: true)
        try FileManager.default.moveItem(at: request.outputDirectory, to: appOutput)
        try await command.run()
        for bundle in bundles {
            try await assertSameReads(
                appOutput.appendingPathComponent(bundle),
                request.outputDirectory.appendingPathComponent(bundle)
            )
            let rerun = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: request.outputDirectory.appendingPathComponent(bundle)))
            XCTAssertEqual(rerun.operation.toolCommand, toolCommand, bundle)
        }
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: request.outputDirectory))
        XCTAssertEqual(envelope.argv, request.recordedCommandArguments, "the argv the command records for its own run")
        XCTAssertEqual(envelope.argv.filter { $0.hasSuffix("canonicalize-reverse-complements") }, [
            "--canonicalize-reverse-complements",
        ])
    }

    func testFluidigmRequestWithOtherPrimersRecordsTheAppFormNoCommandRuns() throws {
        // CLI parity gap. No `fastq ont-fluidigm-samples` option sets the
        // primers, so a request with other primers records the app form,
        // which no shell runs, with the primers as descriptive flags.
        let request = ONTFluidigmAmpliconMaterializationRequest(
            inputURL: root.appendingPathComponent("barcode11.fastq"),
            barcodeDefinitionsURL: root.appendingPathComponent("samples.csv"),
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            forwardPrimer: "ACGTACGTACGTACGTACGTAC"
        )

        let words = request.recordedCommandArguments
        XCTAssertEqual(Array(words.prefix(2)), ["Lungfish.app", "ont-fluidigm-samples"])
        let forward = try XCTUnwrap(words.firstIndex(of: "--forward-primer"))
        XCTAssertEqual(words[forward + 1], "ACGTACGTACGTACGTACGTAC")
        let reverse = try XCTUnwrap(words.firstIndex(of: "--reverse-primer"))
        XCTAssertEqual(words[reverse + 1], ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        assertIsNotALungfishCLICommand(request.recordedCommandLine)
    }

    // MARK: - ONT Fluidigm Sample Split launch

    func testFluidigmSampleSplitLaunchPublishesEachSampleBundleWithTheRunsProvenance() async throws {
        // The launch used to fail at the end of every run. The command's
        // provenance step refused its checksum-less folder records after the
        // sample bundles were written, and the service then removed them.
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let source = try FASTQOperationTestHelper.makeBundle(
            named: "barcode11",
            in: project.appendingPathComponent("Imports", isDirectory: true)
        )
        try Self.writeFASTQ(Self.fluidigmReads(), to: source.fastqURL)
        let sheet = project.appendingPathComponent("NB11 samples.csv")
        try "sample,barcode\nLF2871,AAAACCCCGG\nLF2872,GGGGTTTTAA\n".write(to: sheet, atomically: true, encoding: .utf8)
        let launch = FASTQOperationLaunchRequest.ontFluidigmSampleSplit(
            inputFASTQURL: source.bundleURL,
            barcodeDefinitionsURL: sheet,
            threads: 2
        )
        let service = FASTQOperationExecutionService(
            commandRunner: InProcessFluidigmCLIRunner(),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: project)
        )

        let result = try await service.execute(
            request: launch,
            workingDirectory: project.appendingPathComponent("ont-fluidigm-samples", isDirectory: true)
        )

        XCTAssertEqual(result.importedURLs.map(\.lastPathComponent).sorted(), ["LF2871.lungfishfastq", "LF2872.lungfishfastq"])
        let ran = try RecordedCLICommand.parse(
            FASTQOperationCLIInvocationBuilder.commandLine(for: try XCTUnwrap(result.executedInvocations.first)),
            as: FastqONTFluidigmSamplesSubcommand.self
        )
        XCTAssertEqual(Self.physicalPath(ran.input), Self.physicalPath(source.bundleURL.path))
        XCTAssertEqual(ran.threads, 2)
        for bundle in result.importedURLs {
            let name = bundle.lastPathComponent
            let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), name)
            let reads = try await FASTQReader(validateSequence: false).readAll(from: payload)
            XCTAssertFalse(reads.isEmpty, name)
            let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(from: bundle), name)
            XCTAssertEqual(envelope.workflowName, "lungfish fastq ont-fluidigm-samples", name)
            XCTAssertEqual(envelope.outputs.map { Self.physicalPath($0.path) }, [Self.physicalPath(payload.path)], name)
            // The bundle and the run's envelope name one command, with the
            // thread count and the reverse complement setting the run used.
            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle), name)
            XCTAssertEqual(
                try RecordedCLICommand.arguments(of: manifest.operation.toolCommand).map(Self.physicalPath),
                envelope.argv.dropFirst().map(Self.physicalPath),
                name
            )
            let recorded = try RecordedCLICommand.parse(manifest.operation.toolCommand, as: FastqONTFluidigmSamplesSubcommand.self)
            XCTAssertEqual(Self.physicalPath(recorded.input), Self.physicalPath(source.bundleURL.path), name)
            XCTAssertEqual(recorded.threads, 2, name)
            XCTAssertFalse(recorded.canonicalizeReverseComplements, name)
        }
    }

    /// `path` with symbolic links resolved when it is an absolute path, so
    /// `/var` and `/private/var` compare equal, and any other word unchanged.
    private static func physicalPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Fluidigm whole reads

    func testWholeReadSampleBundlesRecordTheAppFormBecauseNoCommandRunsThatMaterializer() async throws {
        let input = root.appendingPathComponent("barcode11.fastq")
        try Self.writeFASTQ(Self.fluidigmReads(), to: input)
        let sheet = root.appendingPathComponent("NB11 samples.csv")
        try "sample,barcode\nLF2871,AAAACCCCGG\nLF2872,GGGGTTTTAA\n".write(to: sheet, atomically: true, encoding: .utf8)
        let request = ONTFluidigmSampleMaterializationRequest(
            inputURL: input,
            barcodeDefinitionsURL: sheet,
            outputDirectory: root.appendingPathComponent("whole reads", isDirectory: true)
        )

        let result = try await ONTFluidigmSampleMaterializer().run(request)

        // CLI parity gap. `fastq ont-fluidigm-samples`, the command the
        // manifest named, cuts each read to its CS1 to CS2 insert, and this
        // materializer keeps whole reads, so no lungfish-cli command writes
        // these bundles.
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: try XCTUnwrap(result.outputBundleURLs.first)))
        let toolCommand = try XCTUnwrap(manifest.operation.toolCommand)
        XCTAssertEqual(toolCommand, request.recordedCommandLine)
        XCTAssertEqual(manifest.operation.toolUsed, "Lungfish.app")
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(toolCommand), [
            "Lungfish.app", "ont-fluidigm-whole-read-samples", input.path,
            "--barcodes", sheet.path,
            "--output", request.outputDirectory.path,
            "--forward-primer", ONTFluidigmAmpliconMaterializer.defaultForwardPrimer,
            "--reverse-primer", ONTFluidigmAmpliconMaterializer.defaultReversePrimer,
        ])
        assertIsNotALungfishCLICommand(toolCommand)
    }

    // MARK: - Helpers

    private func assertIsNotALungfishCLICommand(
        _ command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try RecordedCLICommand.parse(command), file: file, line: line) { error in
            guard case RecordedCLICommand.ParseError.notALungfishCLICommand = error else {
                return XCTFail("\(error)", file: file, line: line)
            }
        }
    }

    /// Asserts two sample bundles hold the same reads in the same order.
    private func assertSameReads(
        _ first: URL,
        _ second: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let firstFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: first), file: file, line: line)
        let secondFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: second), file: file, line: line)
        let reader = FASTQReader(validateSequence: false)
        let firstRecords = try await reader.readAll(from: firstFASTQ)
        let secondRecords = try await reader.readAll(from: secondFASTQ)
        XCTAssertFalse(firstRecords.isEmpty, first.lastPathComponent, file: file, line: line)
        XCTAssertEqual(firstRecords.map(\.identifier), secondRecords.map(\.identifier), file: file, line: line)
        XCTAssertEqual(firstRecords.map(\.sequence), secondRecords.map(\.sequence), file: file, line: line)
    }

    /// Two LF2871 reads and one LF2872 read in the CS1, insert, rc(CS2),
    /// spacer, barcode layout the Fluidigm materializers expect. The 24 base
    /// inserts pass the command's default minimum insert length of 20.
    private static func fluidigmReads() -> [(String, String)] {
        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let cs2RC = reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        return [
            ("read-1", cs1 + "ACGTACGTACGTACGTACGTACGT" + cs2RC + "CC" + "AAAACCCCGG"),
            ("read-2", cs1 + "ACGTACGTACGTACGTACGTACGT" + cs2RC + "CC" + "AAAACCCCGG"),
            ("read-3", cs1 + "TTTTCCCCAAAAGGGGTTTTCCCC" + cs2RC + "AA" + "GGGGTTTTAA"),
        ]
    }

    /// A read with a PacBio barcode at each end of a 2,050 base insert.
    private static func pacBioRead(forward: String, reverse: String) -> String {
        forward + String(repeating: "A", count: 2_050) + reverseComplement(reverse)
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complements: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A", "N": "N"]
        return String(sequence.reversed().map { complements[$0] ?? "N" })
    }

    private static func writeFASTQ(_ records: [(String, String)], to url: URL) throws {
        let text = records.map { identifier, sequence in
            "@\(identifier)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary parses it.
private struct InProcessFluidigmCLIRunner: FASTQOperationCommandRunning {
    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        let words = invocation.subcommand.split(separator: " ").map(String.init) + invocation.arguments
        let parsed = try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(words))
        guard var command = parsed as? AsyncParsableCommand else {
            throw CocoaError(.featureUnsupported)
        }
        try await command.run()
        return FASTQCLIExecutionResult(outputURLs: [])
    }
}
