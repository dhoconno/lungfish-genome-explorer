// MappingVirtualInputProvenanceTests.swift - Virtual FASTQ inputs keep durable provenance on the live mapping path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

/// A mapping run whose input is a virtual FASTQ bundle reads a materialized
/// copy of that bundle's reads. Its provenance must still name the durable
/// inputs (the bundle, its derived manifest, the root FASTQ the reads come
/// from and the payload that selects them), and every file it names must
/// outlive the run. A record that points only at a scratch file the window
/// deletes when the run ends reproduces nothing.
///
/// The window path is driven through its production composition. The request
/// comes from `MappingWizardSheet.buildRunPlan`, and
/// `AppDelegate.resolveManagedMappingInputs` turns it into the request the
/// pipeline runs, exactly as `runSingleManagedMappingAwaitingCompletion` does.
/// `ManagedMappingPipeline` then runs with a stand-in mapper (micromamba)
/// and a stand-in samtools. The CLI-shaped control builds the request the way
/// `lungfish-cli map` does, through `MapCommand`'s own resolution, so the
/// same pipeline and the same assertions show the fixture is sound and that
/// a bundle maps the same reads through the window and through the command
/// the Operations panel records.
@MainActor
final class MappingVirtualInputProvenanceTests: XCTestCase {

    func testWindowMappingOfVirtualBundleRecordsDurableBundleInputs() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        let analysisDirectory = try fixture.makeAnalysisDirectory()
        let request = try fixture.windowRequest(outputDirectory: analysisDirectory)

        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: request, progress: { _ in })
        _ = try await fixture.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )

        try fixture.assertMapperReadMaterializedVirtualReads()
        try fixture.assertDurableVirtualInputProvenance(in: analysisDirectory)
    }

    func testWindowMappingRecordsTheSameInputsAsTheCLIForTheSameVirtualBundle() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        try await assertWindowAndCLIAgree(on: fixture.virtualBundleURL, fixture: fixture)
    }

    func testCLIShapedRequestRecordsDurableBundleInputs() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        let analysisDirectory = try fixture.makeAnalysisDirectory()
        let cliShaped = try await fixture.cliShapedRequest(outputDirectory: analysisDirectory)
        _ = try await fixture.pipeline.run(
            request: cliShaped.request,
            inputLayoutReason: cliShaped.layoutReason
        )

        try fixture.assertMapperReadMaterializedVirtualReads()
        try fixture.assertDurableVirtualInputProvenance(in: analysisDirectory)
    }

    /// A root bundle split over two chunk files (an ONT import) reaches the
    /// mapper as one concatenated file holding every read, the mates of the
    /// pooled files are not invented, and provenance records both chunks,
    /// the concatenation as a step and a durable replay command.
    func testWindowMappingOfMultiFileBundleHandsTheMapperOneFileWithEveryReadAndRecordsTheConcatenation() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        let analysisDirectory = try fixture.makeAnalysisDirectory()
        let request = try fixture.windowRequest(bundleURL: fixture.multiFileBundleURL, outputDirectory: analysisDirectory)

        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: request, progress: { _ in })
        _ = try await fixture.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )

        XCTAssertEqual(resolved.request.inputFASTQURLs.count, 1, "the mapper receives one file")
        XCTAssertFalse(resolved.request.pairedEnd)
        XCTAssertEqual(resolved.request.inputLayout, .singleEnd)
        XCTAssertEqual(try fixture.readsSeenByMapper(), fixture.allReads, "every read of both chunks reached the mapper, in order")

        let provenance = try XCTUnwrap(MappingProvenance.load(from: analysisDirectory))
        let recordedInputs = Set(provenance.inputFiles.filter { $0.role == .input }.map { Self.canonicalPath($0.path) })
        for chunk in fixture.multiFileChunkURLs {
            XCTAssertTrue(recordedInputs.contains(Self.canonicalPath(chunk.path)), "provenance omits \(chunk.lastPathComponent)")
        }
        let concatenationStep = try XCTUnwrap(
            provenance.steps.first { $0.toolName == SequenceInputConcatenation.toolName },
            "no concatenation step; steps: \(provenance.steps.map(\.toolName))"
        )
        XCTAssertEqual(
            concatenationStep.inputs.map { Self.canonicalPath($0.path) },
            fixture.multiFileChunkURLs.map { Self.canonicalPath($0.path) }
        )
        XCTAssertEqual(
            concatenationStep.outputs.map { Self.canonicalPath($0.path) },
            resolved.request.inputFASTQURLs.map { Self.canonicalPath($0.path) }
        )
        XCTAssertNotNil(provenance.mapperInvocation.durableReplayArgv, "the window recorded no durable replay command")
        for record in provenance.inputFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "provenance names \(record.path), which does not exist")
        }
        let scratchPrefix = Self.canonicalPath(fixture.projectURL.appendingPathComponent(".tmp").path) + "/"
        XCTAssertEqual(recordedInputs.filter { $0.hasPrefix(scratchPrefix) }, [], "provenance names a file in the project's scratch folder")
    }

    /// The command the Operations panel records for a multi-file bundle maps
    /// the same reads the window mapped, as one concatenated file, and
    /// records the same inputs and steps.
    func testWindowMappingRecordsTheSameInputsAsTheCLIForTheSameMultiFileBundle() async throws {
        let fixture = try StandInMappingFixture.make()
        defer { fixture.cleanUp() }

        try await assertWindowAndCLIAgree(on: fixture.multiFileBundleURL, fixture: fixture)
        XCTAssertEqual(try fixture.readsSeenByMapper(), fixture.allReads)
    }

    // MARK: - Which inputs pair (READ-PAIRING.md, decision 1)

    /// Two bundles pooled in the window's combined mode are never paired by
    /// their names. Each was imported and reordered on its own, so their
    /// records need not correspond by position. Before the read-set
    /// contract the window paired `sample_R1` and `sample_R2` bundles while
    /// the command it recorded mapped them unpaired (Phase 1 finding N5).
    /// Now both map them pooled as single reads.
    func testTwoPooledBundlesNamedAsMatesMapAsPooledSingleReads() async throws {
        let root = try TestTempDirectory.make(prefix: "mapping-pooled-bundles")
        defer { TestTempDirectory.cleanup(root) }
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        var bundles: [URL] = []
        for (name, read) in [("sample_R1", "q1/1"), ("sample_R2", "q1/2")] {
            let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try ReadSetFixtures.fastq([read]).write(to: bundle.appendingPathComponent("\(name).fastq"), atomically: true, encoding: .utf8)
            bundles.append(bundle)
        }
        let request = try XCTUnwrap(Self.plan(inputs: bundles, mode: .combined, root: root).requests.first)
        XCTAssertFalse(request.pairedEnd)
        XCTAssertFalse(MappingCLIInvocationBuilder.arguments(for: request).contains("--paired"))

        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: request, progress: { _ in })

        XCTAssertFalse(resolved.request.pairedEnd, "two pooled bundles were paired by name")
        XCTAssertEqual(resolved.request.inputLayout, .singleEnd)
        XCTAssertEqual(resolved.layoutResolution.source, .pooledFiles)
    }

    /// Two loose files the window maps together, named as R1 and R2 of one
    /// sample, are mapped as pairs, and the recorded command says `--paired`
    /// so it maps them the same way. Two loose files not named as mates and
    /// the same two files run one at a time stay single reads.
    func testTwoLooseFilesNamedAsMatesAreMappedAndRecordedAsPairs() async throws {
        let root = try TestTempDirectory.make(prefix: "mapping-loose-mates")
        defer { TestTempDirectory.cleanup(root) }
        let r1 = root.appendingPathComponent("sample_R1.fastq")
        let r2 = root.appendingPathComponent("sample_R2.fastq")
        let other = root.appendingPathComponent("other.fastq")
        try ReadSetFixtures.fastq(["q1/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["q1/2"]).write(to: r2, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["z1"]).write(to: other, atomically: true, encoding: .utf8)

        let paired = try XCTUnwrap(Self.plan(inputs: [r1, r2], mode: .combined, root: root).requests.first)
        XCTAssertTrue(paired.pairedEnd, "the window's request does not pair two loose mate files")
        XCTAssertTrue(MappingCLIInvocationBuilder.arguments(for: paired).contains("--paired"))
        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: paired, progress: { _ in })
        XCTAssertTrue(resolved.request.pairedEnd)
        XCTAssertEqual(resolved.request.inputLayout, .pairedFiles)

        let unrelated = try XCTUnwrap(Self.plan(inputs: [r1, other], mode: .combined, root: root).requests.first)
        XCTAssertFalse(unrelated.pairedEnd)
        XCTAssertFalse(MappingCLIInvocationBuilder.arguments(for: unrelated).contains("--paired"))

        let oneAtATime = Self.plan(inputs: [r1, r2], mode: .perBundle, root: root).requests
        XCTAssertEqual(oneAtATime.count, 2)
        XCTAssertEqual(oneAtATime.map(\.pairedEnd), [false, false])
    }

    /// For every bundle layout and every mapper, the window's resolution and
    /// the resolution of the command the window records hand the mapper the
    /// same reads, paired the same way, with the same arguments and the same
    /// read-set steps (READ-PAIRING.md, CLI-EQUIVALENCE.md).
    func testWindowAndItsRecordedCommandResolveEveryLayoutAlike() async throws {
        let root = try TestTempDirectory.make(prefix: "mapping-layout-parity")
        defer { TestTempDirectory.cleanup(root) }
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
        let layouts = [
            fixtures.singleRoot, fixtures.interleavedRoot, fixtures.mixedRoot, fixtures.chunkedRoot,
            fixtures.nanoporeChunkedRoot, fixtures.namedPairChunkedRoot, fixtures.fullMergeOutput,
            fixtures.pairedDerivative, fixtures.mergeDerivative, fixtures.repairDerivative,
            fixtures.subsetOfSingle, fixtures.subsetOfInterleaved, fixtures.subsetOfMerge, fixtures.subsetOfRepair,
        ]
        for bundle in layouts {
            for tool in MappingTool.allCases {
                let label = "\(tool.rawValue) on \(bundle.lastPathComponent)"
                let modeID = tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id
                let windowDirectory = root.appendingPathComponent("window-\(UUID().uuidString)", isDirectory: true)
                let windowRequest = try XCTUnwrap(
                    Self.plan(inputs: [bundle], mode: .perBundle, root: root, tool: tool, modeID: modeID).requests.first
                ).withOutputDirectory(windowDirectory)
                let window = try await AppDelegate().resolveManagedMappingInputs(
                    for: windowRequest,
                    materializer: fixtures.materializer,
                    progress: { _ in }
                )

                // The recorded command, parsed, resolved through the call
                // `MapCommand.run` makes.
                let command = try MapCommand.parse(MappingCLIInvocationBuilder.arguments(for: windowRequest))
                let cliDirectory = root.appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)
                let cli = try await MappingInputResolver.resolve(
                    request: MappingRunRequest(
                        tool: try XCTUnwrap(MappingTool(rawValue: command.mapper)),
                        modeID: modeID,
                        inputFASTQURLs: command.fastqFiles.map { URL(fileURLWithPath: $0) },
                        referenceFASTAURL: URL(fileURLWithPath: command.reference),
                        outputDirectory: cliDirectory,
                        sampleName: try XCTUnwrap(command.sampleName),
                        readGroup: windowRequest.readGroup,
                        pairedEnd: command.pairedEnd,
                        threads: windowRequest.threads
                    ),
                    explicitLayout: command.readLayout.explicitLayout,
                    materializer: fixtures.materializer
                )

                XCTAssertEqual(
                    try Self.comparable(window, outputDirectory: windowDirectory),
                    try Self.comparable(cli, outputDirectory: cliDirectory),
                    label
                )
            }
        }
    }

    /// What a resolution hands the mapper, with each file shown by the reads
    /// it holds and the run's own directory masked.
    private static func comparable(_ resolved: MappingResolvedInputs, outputDirectory: URL) throws -> [String] {
        let request = resolved.request
        func show(_ argument: String) throws -> String {
            let paths = argument.split(separator: ",").map(String.init)
            if !paths.isEmpty, paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) && $0.hasSuffix(".fastq") }) {
                return "[" + (try paths.flatMap { try ReadSetFixtures.readNames(in: URL(fileURLWithPath: $0)) }).joined(separator: ",") + "]"
            }
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("in") {
                return String(argument[...equals]) + (try show(String(argument[argument.index(after: equals)...])))
            }
            return argument.replacingOccurrences(of: outputDirectory.standardizedFileURL.path, with: "<out>")
        }
        let locator = ReferenceLocator(
            referenceURL: URL(fileURLWithPath: "/reference.fa"),
            indexPrefixURL: URL(fileURLWithPath: "/index")
        )
        var commands = try MappingCommandBuilder.buildBBMapReadSetRuns(for: request, referenceLocator: locator).map(\.command)
        if commands.isEmpty {
            commands = [try MappingCommandBuilder.buildCommand(for: request, referenceLocator: locator)]
        }
        let argv = try commands.map { try ([$0.executable] + $0.arguments).map(show).joined(separator: " ") }
        return [
            "files \(try request.inputFASTQURLs.map { try show($0.path) })",
            "pairedEnd \(request.pairedEnd)",
            "layout \(String(describing: request.inputLayout)) \(request.readLayoutPlan.handling)",
            "readSets \(request.readSetLayout != nil)",
            "steps \(resolved.readSetPlan?.steps.map { "\($0.kind) \($0.pairCount) \($0.singleReadCount)" } ?? [])",
        ] + argv
    }

    private static func plan(
        inputs: [URL],
        mode: MultiBundleRunMode,
        root: URL,
        tool: MappingTool = .bowtie2,
        modeID: String = MappingMode.defaultShortRead.id
    ) -> MappingRunPlan {
        MappingWizardSheet.buildRunPlan(
            bundleURLs: inputs,
            mode: mode,
            tool: tool,
            modeID: modeID,
            referenceFASTAURL: root.appendingPathComponent("reference.fa"),
            sourceReferenceBundleURL: nil,
            projectURL: nil,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            runToken: "probe",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
    }

    /// Runs the window composition and the CLI-shaped composition on
    /// `bundleURL` and checks that the mapper saw the same reads and that
    /// the two provenance records name the same inputs, the same steps, a
    /// durable replay command and the same materialized bytes.
    private func assertWindowAndCLIAgree(
        on bundleURL: URL,
        fixture: StandInMappingFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let windowDirectory = try fixture.makeAnalysisDirectory()
        let windowRequest = try fixture.windowRequest(bundleURL: bundleURL, outputDirectory: windowDirectory)
        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: windowRequest, progress: { _ in })
        _ = try await fixture.pipeline.run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )
        let windowReads = try fixture.readsSeenByMapper()

        let cliDirectory = try fixture.makeAnalysisDirectory()
        let cliShaped = try await fixture.cliShapedRequest(bundleURL: bundleURL, outputDirectory: cliDirectory)
        _ = try await fixture.pipeline.run(
            request: cliShaped.request,
            inputLayoutReason: cliShaped.layoutReason
        )
        let cliReads = try fixture.readsSeenByMapper()

        XCTAssertEqual(windowReads, cliReads, "the window and the CLI mapped different reads", file: file, line: line)
        XCTAssertEqual(resolved.request.pairedEnd, cliShaped.request.pairedEnd, "the window and the CLI paired differently", file: file, line: line)
        XCTAssertEqual(resolved.request.inputLayout, cliShaped.request.inputLayout, file: file, line: line)

        let window = try XCTUnwrap(MappingProvenance.load(from: windowDirectory), file: file, line: line)
        let cli = try XCTUnwrap(MappingProvenance.load(from: cliDirectory), file: file, line: line)
        XCTAssertEqual(
            Self.comparableInputs(of: window, analysisDirectory: windowDirectory),
            Self.comparableInputs(of: cli, analysisDirectory: cliDirectory),
            "the window and the CLI recorded different input sets",
            file: file,
            line: line
        )
        XCTAssertEqual(
            window.steps.map(\.toolName),
            cli.steps.map(\.toolName),
            "the window and the CLI recorded different steps",
            file: file,
            line: line
        )
        XCTAssertNotNil(window.mapperInvocation.durableReplayArgv, "the window recorded no durable replay command", file: file, line: line)
        XCTAssertNotNil(cli.mapperInvocation.durableReplayArgv, file: file, line: line)
        XCTAssertEqual(
            Self.materializedInputChecksum(of: window),
            Self.materializedInputChecksum(of: cli),
            "the window and the CLI recorded different materialized reads",
            file: file,
            line: line
        )
        XCTAssertNotNil(Self.materializedInputChecksum(of: cli), file: file, line: line)
    }

    /// The recorded inputs with the run's own directory and the random part
    /// of a materialized file name masked, so two runs compare.
    private static func comparableInputs(
        of provenance: MappingProvenance,
        analysisDirectory: URL
    ) -> [String] {
        let analysisPrefix = analysisDirectory.standardizedFileURL.path + "/"
        return provenance.inputFiles
            .map { record -> String in
                var path = URL(fileURLWithPath: record.path).standardizedFileURL.path
                if path.hasPrefix(analysisPrefix) {
                    path = "<analysis>/" + path.dropFirst(analysisPrefix.count)
                }
                path = path.replacingOccurrences(
                    of: #"(materialized|concatenated)-[0-9A-Fa-f-]+\."#,
                    with: "$1.",
                    options: .regularExpression
                )
                return "\(record.role.rawValue) \(path)"
            }
            .sorted()
    }

    /// The checksum of the file written for the run, materialized or concatenated.
    private static func materializedInputChecksum(of provenance: MappingProvenance) -> String? {
        provenance.inputFiles.first { $0.path.contains("/.lungfish-map-inputs/") }?.sha256
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// A project with a root FASTQ bundle of three Illumina reads, a virtual
/// oriented bundle over it (read 1 forward, read 3 reverse-complemented,
/// read 2 left out) and a root bundle whose three reads are split over two
/// chunk files, plus a stand-in mapper and samtools. Orient materialization
/// is pure Swift, so no real tool runs.
private struct StandInMappingFixture {
    let rootURL: URL
    let projectURL: URL
    let rootFASTQURL: URL
    let virtualBundleURL: URL
    let multiFileBundleURL: URL
    let multiFileChunkURLs: [URL]
    let referenceURL: URL
    let readsSeenByMapperURL: URL
    let pipeline: ManagedMappingPipeline

    struct CLIShapedRequest {
        let request: MappingRunRequest
        let layoutReason: String
    }

    static let readIDs = [
        "A00488:385:HKGCLDRXX:1:1101:1000:1000",
        "A00488:385:HKGCLDRXX:1:1101:1001:1000",
        "A00488:385:HKGCLDRXX:1:1101:1002:1000",
    ]
    static let sequences = [
        String(repeating: "ACGTTGCA", count: 18) + "ACGTAC",
        String(repeating: "GGGCCCAA", count: 18) + "GGGCCC",
        String(repeating: "TTTAAACC", count: 18) + "TTTAAC",
    ]

    /// Every read of the root bundle, as `readsSeenByMapper` reports it.
    var allReads: [String] {
        Self.readIDs.indices.map { "\(Self.readIDs[$0]) \(Self.sequences[$0])" }
    }

    static func record(_ index: Int, sequence: String? = nil) -> String {
        let bases = sequence ?? sequences[index]
        return "@\(readIDs[index]) 1:N:0:1\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n"
    }

    static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return "N"
            }
        })
    }

    static func make() throws -> StandInMappingFixture {
        let fileManager = FileManager.default
        let root = try TestTempDirectory.make(prefix: "mapping-virtual-provenance")
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)

        let rootBundle = imports.appendingPathComponent("run.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFASTQ = rootBundle.appendingPathComponent("run.fastq")
        try (record(0) + record(1) + record(2)).write(to: rootFASTQ, atomically: true, encoding: .utf8)

        let virtualBundle = imports.appendingPathComponent("run-oriented.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: virtualBundle, withIntermediateDirectories: true)
        try "\(readIDs[0])\t+\n\(readIDs[2])\t-\n".write(
            to: virtualBundle.appendingPathComponent("orient-map.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try record(0).write(
            to: virtualBundle.appendingPathComponent("preview.fastq"),
            atomically: true,
            encoding: .utf8
        )
        let operation = FASTQDerivativeOperation(kind: .orient)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "run-oriented",
                parentBundleRelativePath: "@/Imports/run.lungfishfastq",
                rootBundleRelativePath: "@/Imports/run.lungfishfastq",
                rootFASTQFilename: "run.fastq",
                payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 300),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: virtualBundle
        )

        // A root bundle whose reads are split over two chunk files listed in
        // source-files.json, the shape of an ONT import.
        let multiFileBundle = imports.appendingPathComponent("chunked.lungfishfastq", isDirectory: true)
        let chunkDirectory = multiFileBundle.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        let chunk0 = chunkDirectory.appendingPathComponent("chunked_0.fastq")
        let chunk1 = chunkDirectory.appendingPathComponent("chunked_1.fastq")
        try (record(0) + record(1)).write(to: chunk0, atomically: true, encoding: .utf8)
        try record(2).write(to: chunk1, atomically: true, encoding: .utf8)
        try record(0).write(to: multiFileBundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/chunked_0.fastq", originalPath: "/orig/chunked_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/chunked_1.fastq", originalPath: "/orig/chunked_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: multiFileBundle)

        let reference = project.appendingPathComponent("reference.fa")
        try ">chr1\n\(String(repeating: "ACGTTGCA", count: 20))\n".write(
            to: reference,
            atomically: true,
            encoding: .utf8
        )

        // Stand-in mapper: the managed minimap2 environment exists, and a
        // stand-in micromamba answers the version probe, copies the reads it
        // was given aside, and writes a header-only SAM.
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let mapperBin = condaRoot.appendingPathComponent("envs/minimap2/bin", isDirectory: true)
        try fileManager.createDirectory(at: mapperBin, withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: mapperBin.appendingPathComponent("minimap2"))
        let readsSeen = root.appendingPathComponent("reads-seen-by-mapper.fastq")
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try writeExecutable(micromambaScript(readsSeenPath: readsSeen.path), to: micromamba)
        let condaManager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )

        let samtoolsHome = try ManagedSamtoolsHome.makeStub(
            rootURL: root,
            namePrefix: "samtools-home",
            script: samtoolsScript
        )
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: samtoolsHome.homeURL)

        return StandInMappingFixture(
            rootURL: root,
            projectURL: project,
            rootFASTQURL: rootFASTQ,
            virtualBundleURL: virtualBundle,
            multiFileBundleURL: multiFileBundle,
            multiFileChunkURLs: [chunk0, chunk1],
            referenceURL: reference,
            readsSeenByMapperURL: readsSeen,
            pipeline: ManagedMappingPipeline(condaManager: condaManager, nativeToolRunner: runner)
        )
    }

    func cleanUp() {
        TestTempDirectory.cleanup(rootURL)
    }

    func makeAnalysisDirectory() throws -> URL {
        try AnalysesFolder.createAnalysisDirectory(tool: MappingTool.minimap2.rawValue, in: projectURL)
    }

    /// The request the Map Reads dialog hands to `runManagedMapping` for one
    /// bundle (the virtual bundle unless another is named), bound to its
    /// analysis directory as `runSingleManagedMappingAwaitingCompletion`
    /// binds it.
    func windowRequest(bundleURL: URL? = nil, outputDirectory: URL) throws -> MappingRunRequest {
        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleURL ?? virtualBundleURL],
            mode: .perBundle,
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceURL,
            sourceReferenceBundleURL: nil,
            projectURL: projectURL,
            outputDirectory: projectURL.appendingPathComponent("mapping-probe", isDirectory: true),
            runToken: "probe",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
        let request = try XCTUnwrap(plan.requests.first)
        return request.withOutputDirectory(outputDirectory)
    }

    /// The request `lungfish-cli map <bundle>` builds: the inputs as named,
    /// resolved through `MappingInputResolver` into the run's
    /// `.lungfish-map-inputs`, with pairing, layout and lineage as the
    /// command derives them.
    func cliShapedRequest(bundleURL: URL? = nil, outputDirectory: URL) async throws -> CLIShapedRequest {
        let inputURL = bundleURL ?? virtualBundleURL
        let resolved = try await MappingInputResolver.resolve(
            request: MappingRunRequest(
                tool: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: [inputURL],
                referenceFASTAURL: referenceURL,
                projectURL: projectURL,
                outputDirectory: outputDirectory,
                sampleName: inputURL.deletingPathExtension().lastPathComponent,
                threads: 2
            ),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        return CLIShapedRequest(request: resolved.request, layoutReason: resolved.layoutResolution.reason)
    }

    /// The read names and bases the stand-in mapper was handed, in order.
    func readsSeenByMapper() throws -> [String] {
        let lines = try String(contentsOf: readsSeenByMapperURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var reads: [String] = []
        var index = 0
        while index + 1 < lines.count, lines[index].hasPrefix("@") {
            let name = String(lines[index].dropFirst().split(separator: " ").first ?? "")
            reads.append("\(name) \(lines[index + 1])")
            index += 4
        }
        return reads
    }

    /// The mapper read the oriented reads, not the bundle's one-read
    /// preview and not the three-read root FASTQ.
    func assertMapperReadMaterializedVirtualReads(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try readsSeenByMapper(),
            [
                "\(Self.readIDs[0]) \(Self.sequences[0])",
                "\(Self.readIDs[2]) \(Self.reverseComplement(Self.sequences[2]))",
            ],
            file: file,
            line: line
        )
    }

    /// The run's provenance names the virtual bundle, its derived manifest,
    /// the root FASTQ and the orient map, every file it names still exists
    /// once the run is over, and none of them lives in the project's scratch
    /// folder.
    func assertDurableVirtualInputProvenance(
        in analysisDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let provenance = try XCTUnwrap(
            MappingProvenance.load(from: analysisDirectory),
            "mapping-provenance.json was not written",
            file: file,
            line: line
        )
        let recordedInputs = provenance.inputFiles
            .filter { $0.role == .input }
            .map { Self.canonicalPath($0.path) }
        let durableInputs = [
            virtualBundleURL,
            FASTQBundle.derivedManifestURL(in: virtualBundleURL),
            rootFASTQURL,
            virtualBundleURL.appendingPathComponent("orient-map.tsv"),
        ].map { Self.canonicalPath($0.path) }
        for durableInput in durableInputs {
            XCTAssertTrue(
                recordedInputs.contains(durableInput),
                "provenance inputs omit durable input \(durableInput); recorded inputs: \(recordedInputs)",
                file: file,
                line: line
            )
        }
        for record in provenance.inputFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: record.path),
                "provenance names \(record.path), which no longer exists after the run",
                file: file,
                line: line
            )
        }
        let scratchPrefix = Self.canonicalPath(projectURL.appendingPathComponent(".tmp").path) + "/"
        XCTAssertEqual(
            recordedInputs.filter { $0.hasPrefix(scratchPrefix) },
            [],
            "provenance names a file in the project's scratch folder",
            file: file,
            line: line
        )
        XCTAssertFalse(
            provenance.steps.filter { $0.toolName == CLISequenceInputMaterialization.materializationToolName }.isEmpty,
            "provenance records no materialization step; steps: \(provenance.steps.map(\.toolName))",
            file: file,
            line: line
        )

        let envelope = try XCTUnwrap(
            ProvenanceRecorder.findProvenanceEnvelope(for: analysisDirectory)?.envelope,
            "the canonical provenance envelope was not written",
            file: file,
            line: line
        )
        let envelopeFiles = envelope.files.map { Self.canonicalPath($0.path) }
        XCTAssertTrue(
            envelopeFiles.contains(Self.canonicalPath(virtualBundleURL.path)),
            "the provenance envelope omits the virtual bundle; envelope files: \(envelopeFiles)",
            file: file,
            line: line
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func micromambaScript(readsSeenPath: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ]; then
          echo "stand-in micromamba: unexpected arguments: $*" >&2
          exit 64
        fi
        shift
        if [ "$1" = "-n" ]; then
          shift 2
        fi
        tool="$1"
        shift
        if [ "$tool" != "minimap2" ]; then
          echo "stand-in micromamba: unexpected tool $tool" >&2
          exit 64
        fi
        if [ "$1" = "--version" ]; then
          echo "2.28-r1209"
          exit 0
        fi
        out=""
        last=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            out="$2"
            shift 2
            continue
          fi
          last="$1"
          shift
        done
        cat "$last" > '\(readsSeenPath)'
        printf '@HD\\tVN:1.6\\tSO:unsorted\\n@SQ\\tSN:chr1\\tLN:160\\n' > "$out"
        exit 0
        """
    }

    private static let samtoolsScript = """
        #!/bin/sh
        sub="$1"
        if [ "$sub" = "--version" ]; then
          echo "samtools 1.21"
          exit 0
        fi
        shift
        case "$sub" in
          view|sort)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            if [ -n "$out" ]; then
              : > "$out"
            fi
            ;;
          index)
            bam=""
            for arg in "$@"; do
              bam="$arg"
            done
            : > "$bam.bai"
            ;;
          flagstat)
            echo "2 + 0 in total (QC-passed reads + QC-failed reads)"
            echo "2 + 0 primary"
            echo "2 + 0 mapped (100.00% : N/A)"
            echo "2 + 0 primary mapped (100.00% : N/A)"
            ;;
          coverage)
            printf '#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n'
            printf 'chr1\\t1\\t160\\t2\\t160\\t100.0\\t2.0\\t30.0\\t60.0\\n'
            ;;
        esac
        exit 0
        """
}
