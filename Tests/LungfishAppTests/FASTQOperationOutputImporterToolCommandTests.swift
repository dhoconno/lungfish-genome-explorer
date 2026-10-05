// FASTQOperationOutputImporterToolCommandTests.swift - Derivative provenance names the lungfish-cli invocation that ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ operations dialog runs each derivative as `lungfish-cli fastq
// <subcommand>`, and FASTQOperationOutputImporter records a command in the
// derived bundle's manifest (`operation.toolCommand`, which the Inspector shows
// with a Copy button). It used to record a second encoding with the CLI's own
// output file as the input, and for five kinds a native tool that never ran,
// such as `seqkit seq --reverse --complement` for a reverse complement (R3, R8).
// These tests import operation outputs and check that the manifest records the
// invocation FASTQOperationCLIInvocationBuilder builds for the same request,
// the one the dialog row records and the execution service runs. The output
// of a launch that is not a derivative records the app's import form.

import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQOperationOutputImporterToolCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input
        // resolvers hand the CLI, so the paths the tests compare agree.
        let made = try TestTempDirectory.make(prefix: "fastq-importer-tool-command")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    /// `words` with the value after `-o` replaced by `value`.
    private func replacingOutput(in words: [String], with value: String) throws -> [String] {
        let index = try XCTUnwrap(words.firstIndex(of: "-o"), "no -o in \(words)")
        var replaced = words
        replaced[index + 1] = value
        return replaced
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A physical source bundle in a project's Imports folder with four reads.
    private func makeSourceBundle(named name: String = "Sample 1") throws -> (bundleURL: URL, fastqURL: URL) {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let bundle = try FASTQOperationTestHelper.makeBundle(named: name, in: imports)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 4, readLength: 20)
        return bundle
    }

    private func makeWriter() -> AppFASTQOutputBundleWriter {
        AppFASTQOutputBundleWriter(
            ingestor: CopyingFASTQOutputIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
    }

    /// The Operations panel command for a dialog launch, as
    /// `MainSplitViewController.beginFASTQLaunchRequestOperation` records it.
    private func dialogRowCommand(for request: FASTQOperationLaunchRequest) throws -> String {
        FASTQOperationCLIInvocationBuilder.commandLine(
            for: try FASTQOperationExecutionService().buildInvocation(for: request)
        )
    }

    func testImportedDerivativeRecordsTheReverseComplementInvocationThatRanNotSeqkit() async throws {
        let source = try makeSourceBundle()
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = FASTQOperationExecutionService(
            commandRunner: InProcessLungfishCLIRunner(),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destination, fastqBundleWriter: makeWriter())
        )

        let result = try await service.execute(
            request: .derivative(request: .reverseComplement, inputURLs: [source.bundleURL], outputMode: .perInput),
            workingDirectory: root.appendingPathComponent("work", isDirectory: true)
        )

        let bundleURL = try XCTUnwrap(result.importedURLs.first)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        let toolCommand = try XCTUnwrap(manifest.operation.toolCommand)
        let finalPayload = bundleURL.appendingPathComponent(manifest.rootFASTQFilename)

        // The words that ran, with the file the CLI read replaced by the
        // bundle the request names and its scratch output by the final payload.
        let ran = try XCTUnwrap(result.executedInvocations.first)
        XCTAssertEqual(ran.subcommand, "fastq")
        XCTAssertEqual(ran.arguments.count, 4)
        XCTAssertEqual(ran.arguments.first, "reverse-complement")
        XCTAssertEqual(ran.arguments[1], source.fastqURL.path)
        XCTAssertEqual(ran.arguments[2], "-o")
        XCTAssertEqual(
            try AdvancedCommandLineOptions.parse(toolCommand),
            [CLICommandIdentity.executableName, "fastq", "reverse-complement", source.bundleURL.path, "-o", finalPayload.path]
        )
        let command = try RecordedCLICommand.parse(toolCommand, as: FastqReverseComplementSubcommand.self)
        XCTAssertEqual(command.input, source.bundleURL.path)
        XCTAssertEqual(command.output.output, finalPayload.path)
        XCTAssertFalse(toolCommand.contains("seqkit"), toolCommand)
        XCTAssertFalse(toolCommand.contains(ran.arguments[3]), "the CLI's scratch output is not the input")
        XCTAssertEqual(manifest.lineage.last?.toolCommand, toolCommand)
        XCTAssertEqual(manifest.operation.toolUsed, CLICommandIdentity.executableName)
    }

    func testImportedDerivativesRecordTheDialogRowCommandWithTheFinalOutput() async throws {
        let source = try makeSourceBundle()
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let primers = FASTQPrimerTrimConfiguration(
            source: .reference, mode: .linked, referenceFasta: root.appendingPathComponent("primers.fasta").path,
            errorRate: 0.08, minimumOverlap: 9, tool: .cutadapt
        )
        // The first five kinds used to record cutadapt, seqkit, vsearch and
        // deacon commands, and the primer trim left out its cutadapt-linked engine.
        let requests: [FASTQDerivativeRequest] = [
            .sequencePresenceFilter(
                sequence: "ACGT", fastaPath: nil, searchEnd: .fivePrime, minOverlap: 4,
                errorRate: 0.1, keepMatched: true, searchReverseComplement: false
            ),
            .reverseComplement,
            .orient(
                referenceURL: root.appendingPathComponent("ref.fasta"),
                wordLength: 12, dbMask: "dust", saveUnoriented: false, extraArguments: []
            ),
            .humanReadScrub(databaseID: DeaconPanhumanDatabaseInstaller.databaseID, removeReads: true),
            .primerRemoval(configuration: primers),
            .subsampleCount(2),
            .lengthFilter(min: 10, max: 40),
        ]

        for (index, request) in requests.enumerated() {
            let launch = FASTQOperationLaunchRequest.derivative(
                request: request, inputURLs: [source.bundleURL], outputMode: .perInput
            )
            let staging = root.appendingPathComponent("work-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = staging.appendingPathComponent("\(request.operationKindString).fastq")
            try FASTQOperationTestHelper.writeSyntheticFASTQ(to: staged, readCount: 2, readLength: 20)
            try SyntheticToolProvenance.write(
                argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
                inputURL: source.fastqURL,
                outputURL: staged,
                in: staging
            )

            let bundleURL = try await makeWriter().importFASTQOutput(
                sourceURL: staged,
                bundleURL: destination.appendingPathComponent(
                    "Sample 1-\(request.operationKindString).\(FASTQBundle.directoryExtension)"
                ),
                originalRequest: launch,
                sourceInputURL: source.bundleURL
            )

            let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL), request.operationLabel)
            let finalPayload = bundleURL.appendingPathComponent(manifest.rootFASTQFilename)
            let recorded = try RecordedCLICommand.arguments(of: manifest.operation.toolCommand)
            let row = try RecordedCLICommand.arguments(of: try dialogRowCommand(for: launch))
            XCTAssertEqual(
                recorded,
                try replacingOutput(in: row, with: finalPayload.path),
                "\(request.operationLabel): the dialog row and the provenance differ only in the output"
            )
            XCTAssertNoThrow(try RecordedCLICommand.parse(manifest.operation.toolCommand), request.operationLabel)
            XCTAssertFalse(recorded.contains(staged.path), "\(request.operationLabel): the CLI's output is not the input")
        }
    }

    func testImportForALaunchThatIsNotADerivativeRecordsTheAppImportForm() async throws {
        // Only a derivative's FASTQ output reaches this import today. The
        // manifest for any other launch used to record `lungfish <FASTQ> -o
        // <payload>`, the legacy executable name with arguments no command
        // takes and the scratch FASTQ the run deletes. No lungfish-cli command
        // writes that FASTQ, so the record names the app's import instead.
        let source = try makeSourceBundle()
        let staging = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("LF1001.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: staged, readCount: 2, readLength: 20)
        try SyntheticToolProvenance.write(
            argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
            inputURL: source.fastqURL,
            outputURL: staged,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let launch = FASTQOperationLaunchRequest.ontFluidigmSampleSplit(
            inputFASTQURL: source.bundleURL,
            barcodeDefinitionsURL: root.appendingPathComponent("samples.csv"),
            threads: 2
        )

        let bundleURL = try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: destination.appendingPathComponent("LF1001.\(FASTQBundle.directoryExtension)"),
            originalRequest: launch,
            sourceInputURL: source.bundleURL
        )

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        let payload = bundleURL.appendingPathComponent(manifest.rootFASTQFilename)
        let toolCommand = try XCTUnwrap(manifest.operation.toolCommand)
        XCTAssertEqual(manifest.operation.toolUsed, "Lungfish.app")
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(toolCommand), [
            "Lungfish.app", "import-fastq-operation-output",
            "--operation", launch.operationDisplayTitle,
            "--input", source.bundleURL.path,
            "--output", payload.path,
        ])
        XCTAssertThrowsError(try RecordedCLICommand.parse(toolCommand), "no lungfish-cli command writes this FASTQ")
        XCTAssertEqual(manifest.lineage.last?.toolCommand, toolCommand)
    }

    func testRibosomalRNAOutputRecordsTheFolderOfThePublishedBundlesAsTheOutputDirectory() async throws {
        let source = try makeSourceBundle(named: "source")
        let staging = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedFASTQ = staging.appendingPathComponent("source.norrna.fastq")
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: stagedFASTQ, readCount: 2, readLength: 20)
        try SyntheticToolProvenance.write(
            argv: ["deacon", "filter", source.fastqURL.path, "-o", stagedFASTQ.path],
            inputURL: source.fastqURL,
            outputURL: stagedFASTQ,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let bundleURL = try await makeWriter().importFASTQOutput(
            sourceURL: stagedFASTQ,
            bundleURL: destination.appendingPathComponent("source-deacon-ribo-norrna.\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: .ribosomalRNAFilter(retention: .both, ensure: .none),
                inputURLs: [source.bundleURL],
                outputMode: .perInput
            ),
            sourceInputURL: source.bundleURL
        )

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        XCTAssertEqual(manifest.operation.riboDetectorRetention, .nonRRNA)
        let command = try RecordedCLICommand.parse(manifest.operation.toolCommand, as: FastqDeaconRiboSubcommand.self)
        XCTAssertEqual(command.inputs, [source.bundleURL.path])
        XCTAssertEqual(command.retain, FASTQRiboDetectorRetention.both.rawValue, "the run kept both classes")
        XCTAssertEqual(command.databaseID, DeaconRibokmersDatabaseInstaller.databaseID)
        XCTAssertEqual(
            URL(fileURLWithPath: command.outputDirectory).standardizedFileURL,
            destination.standardizedFileURL,
            "`fastq deacon-ribo -o` takes a folder, the one that holds the published bundles"
        )
    }

    // MARK: - Output read roles (D10, Phase 1.5 lane A7)

    /// A trim of a file that mixes merged reads with pairs writes the pairs
    /// first and the merged reads last. The import recorded such an output
    /// single-end with no read roles, so with more pair records than the
    /// 100,000-record scan the imported bundle read as strictly interleaved,
    /// and the next tool paired its merged reads by position. Before the fix
    /// the bundle resolved as interleaved pairs. It now records the merged
    /// reads beside the output and resolves as mixed.
    func testAnOutputOfAMixedSourceRecordsItsReadRolesSoALargeOneNeverReadsAsStrictPairs() async throws {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let source = try FASTQOperationTestHelper.makeBundle(named: "vsp2", in: imports)
        try FASTQOperationTestHelper.writeFASTQ(
            records: [
                (id: "m1", sequence: "ACGTACGTACGTACGTACGTACGT"),
                (id: "p1/1", sequence: "ACGTACGTAC"),
                (id: "p1/2", sequence: "ACGTACGTAC"),
            ],
            to: source.fastqURL
        )
        var sourceMetadata = PersistedFASTQMetadata()
        sourceMetadata.ingestion = IngestionMetadata(pairingMode: .interleaved)
        sourceMetadata.readClassification = ReadClassification(files: [
            .init(filename: source.fastqURL.lastPathComponent, role: .merged, readCount: 1),
            .init(filename: source.fastqURL.lastPathComponent, role: .pairedR1, readCount: 1),
            .init(filename: source.fastqURL.lastPathComponent, role: .pairedR2, readCount: 1),
        ])
        FASTQMetadataStore.save(sourceMetadata, for: source.fastqURL)

        let staging = root.appendingPathComponent("work-roles", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("vsp2.trimmed.fastq")
        let pairCount = 50_001
        var records: [(id: String, sequence: String)] = []
        records.reserveCapacity(pairCount * 2 + 2)
        for index in 0..<pairCount {
            records.append((id: "p\(index)/1", sequence: "ACGTACGTAC"))
            records.append((id: "p\(index)/2", sequence: "ACGTACGTAC"))
        }
        records.append((id: "m1", sequence: "ACGTACGTACGTACGTACGTACGT"))
        records.append((id: "m2", sequence: "ACGTACGTACGTACGTACGTACGT"))
        try FASTQOperationTestHelper.writeFASTQ(records: records, to: staged)
        try SyntheticToolProvenance.write(
            argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
            inputURL: source.fastqURL,
            outputURL: staged,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let bundleURL = try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: destination.appendingPathComponent("vsp2-trimmed.\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: .qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight),
                inputURLs: [source.bundleURL],
                outputMode: .perInput
            ),
            sourceInputURL: source.bundleURL
        )

        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundleURL])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs, resolution.reason)
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        let classification = try XCTUnwrap(FASTQMetadataStore.load(for: payload)?.readClassification)
        XCTAssertEqual(classification.pairedReadCount, pairCount * 2)
        XCTAssertEqual(classification.unpairedReadCount + classification.mergedReadCount, 2)
    }

    /// A trim of an interleaved source (no merge evidence) that appends its
    /// orphans after 100,002 pair records. The first 100,000 records scan as
    /// strict pairs, so the roles were decided by that scan and none were
    /// written (Lead A review R1). They are decided from the whole file: 3
    /// single reads, recorded as unpaired.
    func testAnInterleavedSourcesOutputWithAnOrphanTailPastTheScanRecordsItsRoles() async throws {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let source = try FASTQOperationTestHelper.makeBundle(named: "pairs-l2", in: imports)
        try FASTQOperationTestHelper.writeFASTQ(
            records: [(id: "p1/1", sequence: "ACGTACGTAC"), (id: "p1/2", sequence: "ACGTACGTAC")],
            to: source.fastqURL
        )
        var sourceMetadata = PersistedFASTQMetadata()
        sourceMetadata.ingestion = IngestionMetadata(pairingMode: .interleaved)
        FASTQMetadataStore.save(sourceMetadata, for: source.fastqURL)

        let staging = root.appendingPathComponent("work-orphans", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("pairs-l2.trimmed.fastq")
        let pairCount = 50_001
        var records: [(id: String, sequence: String)] = []
        records.reserveCapacity(pairCount * 2 + 3)
        for index in 0..<pairCount {
            records.append((id: "p\(index)/1", sequence: "ACGTACGTAC"))
            records.append((id: "p\(index)/2", sequence: "ACGTACGTAC"))
        }
        records += [(id: "o1/1", sequence: "ACGTACGTAC"), (id: "o2/2", sequence: "ACGTACGTAC"), (id: "o3/1", sequence: "ACGTACGTAC")]
        try FASTQOperationTestHelper.writeFASTQ(records: records, to: staged)
        try SyntheticToolProvenance.write(
            argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
            inputURL: source.fastqURL,
            outputURL: staged,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let bundleURL = try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: destination.appendingPathComponent("pairs-l2-trimmed.\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: .qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight),
                inputURLs: [source.bundleURL],
                outputMode: .perInput
            ),
            sourceInputURL: source.bundleURL
        )

        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        let classification = try XCTUnwrap(FASTQMetadataStore.load(for: payload)?.readClassification)
        XCTAssertEqual(classification.pairedReadCount, pairCount * 2)
        XCTAssertEqual(classification.unpairedReadCount, 3)
        XCTAssertEqual(classification.mergedReadCount, 0)
        XCTAssertEqual(Set(classification.files.map(\.filename)), [payload.lastPathComponent])
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundleURL])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs, resolution.reason)
    }

    /// A strictly interleaved output of a paired source records no roles,
    /// as before.
    func testAStrictlyInterleavedOutputRecordsNoReadRoles() async throws {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let source = try FASTQOperationTestHelper.makeBundle(named: "pairs", in: imports)
        try FASTQOperationTestHelper.writeFASTQ(
            records: [(id: "p1/1", sequence: "ACGTACGTAC"), (id: "p1/2", sequence: "ACGTACGTAC")],
            to: source.fastqURL
        )
        var sourceMetadata = PersistedFASTQMetadata()
        sourceMetadata.ingestion = IngestionMetadata(pairingMode: .interleaved)
        FASTQMetadataStore.save(sourceMetadata, for: source.fastqURL)
        let staging = root.appendingPathComponent("work-pairs", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("pairs.trimmed.fastq")
        try FASTQOperationTestHelper.writeFASTQ(
            records: [(id: "p1/1", sequence: "ACGTACGT"), (id: "p1/2", sequence: "ACGTACGT")],
            to: staged
        )
        try SyntheticToolProvenance.write(
            argv: ["fixture-tool", source.fastqURL.path, "-o", staged.path],
            inputURL: source.fastqURL,
            outputURL: staged,
            in: staging
        )
        let destination = root.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let bundleURL = try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: destination.appendingPathComponent("pairs-trimmed.\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: .qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight),
                inputURLs: [source.bundleURL],
                outputMode: .perInput
            ),
            sourceInputURL: source.bundleURL
        )

        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        XCTAssertNil(FASTQMetadataStore.load(for: payload)?.readClassification)
        XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: bundleURL)?.pairingMode, .interleaved)
    }

    // MARK: - A pairs-only output of a merge bundle (Phase 1.5 lane F6)

    /// Imports `records` as the output of Filter by Read Length on the merge
    /// derivative of `fixtures` and returns the imported bundle.
    private func importLengthFilterOutput(
        of records: [(id: String, sequence: String)],
        named name: String,
        fixtures: ReadSetFixtures
    ) async throws -> URL {
        let staging = root.appendingPathComponent("work-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(name).fastq")
        try FASTQOperationTestHelper.writeFASTQ(records: records, to: staged)
        let mergedInput = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")
        try SyntheticToolProvenance.write(
            argv: ["fixture-tool", mergedInput.path, "-o", staged.path],
            inputURL: mergedInput,
            outputURL: staged,
            in: staging
        )
        let destination = fixtures.projectURL.appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try await makeWriter().importFASTQOutput(
            sourceURL: staged,
            bundleURL: destination.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)"),
            originalRequest: .derivative(
                request: .lengthFilter(min: 5, max: 40),
                inputURLs: [fixtures.mergeDerivative],
                outputMode: .perInput
            ),
            sourceInputURL: fixtures.mergeDerivative
        )
    }

    /// Phase 1.5 lane F6, re-review SHOULD-FIX 2. A dialog operation on a merge
    /// bundle can keep only its unmerged pairs, such as Filter by Read Length
    /// with bounds that drop every merged read. The output is a physical `full`
    /// bundle that inherits the merge in its lineage, so the layout scan reads
    /// it as mixed. The import recorded roles only for a file that holds pairs
    /// and single reads, so the output had no counts, the resolver planned it as
    /// mixed, and EsViritu and TaxTriage ran every mate single-end under the
    /// statement that the sample held single reads. The import now records the
    /// pairs, `pairedR1` and `pairedR2` naming the file and no single role, and
    /// the resolver plans the output from those counts. An output that holds
    /// only merged reads records nothing, as before.
    func testAPairsOnlyOutputOfAMergeBundleRecordsItsPairsSoItPlansAsPairs() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let bundleURL = try await importLengthFilterOutput(
            of: [(id: "u1/1", sequence: "ACGTACGTAC"), (id: "u1/2", sequence: "ACGTACGTAC")],
            named: "merge-pairs",
            fixtures: fixtures
        )

        // The premise. The output inherits the merge, so the scan reads mates beside it as mixed.
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleURL))
        XCTAssertTrue(manifest.lineage.contains { $0.kind == .pairedEndMerge }, "the output inherits the merge")
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: bundleURL).layout, .mixedInterleaved)

        // The import records the pairs and no single role, every role naming the file.
        let payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        let classification = try XCTUnwrap(FASTQMetadataStore.load(for: payload)?.readClassification)
        XCTAssertEqual(classification.files.map(\.role), [.pairedR1, .pairedR2])
        XCTAssertEqual(classification.files.map(\.readCount), [1, 1])
        XCTAssertEqual(Set(classification.files.map(\.filename)), [payload.lastPathComponent])
        XCTAssertEqual(classification.mergedReadCount + classification.unpairedReadCount, 0)

        // Both tools plan the output as one interleaved pair, with no reason.
        for consumerID in [EsVirituConfig.readPairingConsumerID, TaxTriageReadSetPlanner.consumerID] {
            let readSet = try await SamplesheetReadSetPlanner.plan(
                input: bundleURL,
                consumerID: consumerID,
                materializationDirectory: root.appendingPathComponent("plan-\(consumerID)", isDirectory: true),
                materializer: fixtures.materializer
            )
            guard case .interleaved(let file) = readSet.reads else { return XCTFail("\(consumerID): \(readSet.reads)") }
            XCTAssertEqual(file.lastPathComponent, payload.lastPathComponent, consumerID)
            XCTAssertNil(readSet.plan.singleReadReason, consumerID)
            XCTAssertFalse(readSet.plan.sampleHoldsPairsAndSingleReads, consumerID)
            XCTAssertEqual(readSet.plan.composition.pairedFragments, 1, consumerID)
        }

        // An output that holds only merged reads records nothing, as before.
        let mergedOnly = try await importLengthFilterOutput(
            of: [(id: "x1", sequence: "ACGTACGTACGTACGTACGT"), (id: "x2", sequence: "ACGTACGTACGTACGTACGT")],
            named: "merge-singles",
            fixtures: fixtures
        )
        let mergedOnlyPayload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: mergedOnly))
        XCTAssertNil(FASTQMetadataStore.load(for: mergedOnlyPayload)?.readClassification)
    }
}

/// Runs each invocation with the real `lungfish-cli` subcommand in this
/// process, as the shipped binary would parse it.
private struct InProcessLungfishCLIRunner: FASTQOperationCommandRunning {
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

/// Stands in for the re-ingestion (clumpify and compression) and copies the
/// operation's output into the staging bundle unchanged.
private struct CopyingFASTQOutputIngestor: FASTQOutputIngesting {
    func ingest(
        config: FASTQIngestionConfig,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FASTQIngestionResult {
        let input = config.inputFiles[0]
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let output = config.outputDirectory.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: output)
        return FASTQIngestionResult(
            outputFile: output,
            wasClumpified: false,
            qualityBinning: config.qualityBinning,
            originalFilenames: [input.lastPathComponent],
            originalSizeBytes: 0,
            finalSizeBytes: 0,
            pairingMode: config.pairingMode
        )
    }
}

/// A one-step provenance envelope beside a staged output, as a CLI run writes it.
private enum SyntheticToolProvenance {
    static func write(argv: [String], inputURL: URL, outputURL: URL, in directory: URL) throws {
        let startedAt = Date(timeIntervalSince1970: 1_800)
        let endedAt = Date(timeIntervalSince1970: 1_801)
        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: outputURL, format: .fastq, role: .output)
        let envelope = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq fixture",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "fixture-tool",
            toolVersion: "1.0.0"
        )
        .argv(argv)
        .options(explicit: [:], defaults: [:], resolved: [:])
        .input(inputURL, format: .fastq, role: .input)
        .output(outputURL, format: .fastq, role: .output)
        .step(ProvenanceStep(
            toolName: "fixture-tool",
            toolVersion: "1.0.0",
            argv: argv,
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 1,
            startedAt: startedAt,
            completedAt: endedAt
        ))
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: endedAt)
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
    }
}
