// AssembleCommandResolutionTests.swift - lungfish-cli assemble resolves a bundle the way lungfish-cli map does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A bundle argument to `lungfish-cli assemble` hands the assembler every
/// read the bundle holds, as `lungfish-cli map` hands the mapper: the
/// unpaired files of one bundle concatenated into one single-read file, the
/// R1 and R2 of a mate pair kept apart and assembled as pairs. The app's
/// single-bundle assembly runs this command, so it assembles the same reads.
final class AssembleCommandResolutionTests: XCTestCase {

    private var root: URL!
    private var shapes: BundleShapeFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assemble-command-resolution")
        shapes = try BundleShapeFixtures(
            in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testSPAdesIsHandedEveryReadOfEachBundleShape() async throws {
        // A fullMixed bundle holds a pair and merged reads. Before owner decision 1
        // of 2026-10-03 (docs/contracts/READ-PAIRING.md) its three files were joined
        // and assembled as five single reads. Now the pair is a pair and the merged
        // reads are SPAdes `--merged` reads.
        let cases: [(shape: String, bundle: URL, single: [[String]], forward: [String], reverse: [String], merged: [[String]])] = [
            ("root single", shapes.single, [["s1", "s2", "s3"]], [], [], []),
            ("root multi-file", shapes.multiFile, [["m1", "m2", "m3", "m4", "m5"]], [], [], []),
            ("virtual orientMap", shapes.oriented, [["s1", "s3"]], [], [], []),
            ("derived fullPaired", shapes.paired, [], ["p1/1", "p2/1"], ["p1/2", "p2/2"], []),
            ("derived fullMixed", shapes.mixed, [], ["u1/1"], ["u1/2"], [["x1", "x2", "x3"]]),
            ("derived fullFASTA", shapes.fasta, [["f1", "f2"]], [], [], []),
            ("derived full", shapes.full, [["g1", "g2"]], [], [], []),
        ]
        for testCase in cases {
            let run = try await assemble(testCase.bundle, label: testCase.shape)
            XCTAssertEqual(run.spades.singleFiles, testCase.single, testCase.shape)
            XCTAssertEqual(run.spades.forward, testCase.forward, testCase.shape)
            XCTAssertEqual(run.spades.reverse, testCase.reverse, testCase.shape)
            XCTAssertEqual(run.spades.mergedFiles, testCase.merged, testCase.shape)
        }
    }

    func testEveryAssemblerReceivesTheConcatenatedReadsOfAMultiFileBundle() async throws {
        let resolved = try await resolve(shapes.multiFile)
        let concatenated = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(resolved.executionInputURLs.count, 1)
        XCTAssertEqual(try BundleShapeFixtures.readNames(in: concatenated), ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertFalse(resolved.resolvedAsMatePair)
        let layout = try XCTUnwrap(AssemblyRunRequest.resolveInputLayout(
            tool: .skesa,
            readType: .illuminaShortReads,
            pairedEnd: false,
            explicit: nil,
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs,
            pooled: resolved.pooledLayoutResolution
        ))
        XCTAssertEqual(layout.layout, .singleEnd)
        XCTAssertEqual(layout.source, .pooledFiles)

        for tool in AssemblyTool.allCases {
            let request = request(tool, resolved: resolved, layout: layout.layout)
            let arguments = try ManagedAssemblyPipeline.buildCommand(for: request).arguments
            XCTAssertTrue(arguments.contains(concatenated.path), "\(tool.rawValue) reads the concatenated file: \(arguments)")
            XCTAssertFalse(
                arguments.contains { $0.contains("run_0") || $0.contains("run_1") },
                "\(tool.rawValue) is not handed a chunk on its own"
            )
            XCTAssertFalse(arguments.contains("--use_paired_ends"), "\(tool.rawValue) assembles single reads")
        }
    }

    func testAFullPairedBundleIsAssembledAsPairsByTheShortReadAssemblers() async throws {
        let resolved = try await resolve(shapes.paired)
        let r1 = shapes.pairedFiles[0].standardizedFileURL
        let r2 = shapes.pairedFiles[1].standardizedFileURL
        XCTAssertEqual(resolved.executionInputURLs, [r1, r2])
        XCTAssertTrue(resolved.resolvedAsMatePair)

        let spades = try ManagedAssemblyPipeline.buildCommand(for: request(.spades, resolved: resolved, pairedEnd: true)).arguments
        XCTAssertEqual(Array(spades.drop { $0 != "-1" }.prefix(4)), ["-1", r1.path, "-2", r2.path])
        let megahit = try ManagedAssemblyPipeline.buildCommand(for: request(.megahit, resolved: resolved, pairedEnd: true)).arguments
        XCTAssertEqual(Array(megahit.drop { $0 != "-1" }.prefix(4)), ["-1", r1.path, "-2", r2.path])
        let skesa = try ManagedAssemblyPipeline.buildCommand(for: request(.skesa, resolved: resolved, pairedEnd: true)).arguments
        XCTAssertEqual(Array(skesa.drop { $0 != "--reads" }.prefix(2)), ["--reads", "\(r1.path),\(r2.path)"])
    }

    func testAConcatenationIsRecordedAsACatStepAndEachFileNamesItsBundle() async throws {
        let run = try await assemble(shapes.multiFile, label: "multi-file")
        let bundle = shapes.multiFile.standardizedFileURL
        let concatenated = try XCTUnwrap(run.resolved.executionInputURLs.first)
        let sidecarURL = try AssembleCommand.writeProvenance(
            request: run.request,
            result: run.result,
            originalInputURLs: run.resolved.originalInputURLs,
            executionInputURLs: run.resolved.executionInputURLs,
            argv: ["lungfish-cli", "assemble", bundle.path, "--assembler", "spades"],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 104),
            materializationStartedAt: run.resolved.materializationStartedAt,
            materializationEndedAt: run.resolved.materializationEndedAt,
            layoutResolution: run.layout,
            writer: ProvenanceWriter(signingProvider: nil)
        )
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: sidecarURL))

        let cat = try XCTUnwrap(envelope.steps.first { $0.toolName == SequenceInputConcatenation.toolName })
        XCTAssertEqual(cat.inputs.map(\.path), shapes.multiFileChunks.map(\.standardizedFileURL.path))
        XCTAssertTrue(cat.inputs.allSatisfy { $0.originPath == bundle.path })
        XCTAssertEqual(cat.outputs.map(\.path), [concatenated.path])
        let assembler = try XCTUnwrap(envelope.steps.first { $0.toolName == AssemblyTool.spades.rawValue })
        XCTAssertTrue(assembler.inputs.contains { $0.path == concatenated.path && $0.originPath == bundle.path })
        XCTAssertEqual(envelope.options.explicit["originalInputs"], .array([.file(bundle)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["originalInputs"], .array([.file(bundle)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["executionInputs"], .array([.file(concatenated)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["readLayoutSource"], .string("pooled_files"))
    }

    func testAPairedBundleRecordsItsBundleAsTheOriginOfBothMates() async throws {
        let run = try await assemble(shapes.paired, label: "paired")
        let bundle = shapes.paired.standardizedFileURL
        let sidecarURL = try AssembleCommand.writeProvenance(
            request: run.request,
            result: run.result,
            originalInputURLs: run.resolved.originalInputURLs,
            executionInputURLs: run.resolved.executionInputURLs,
            argv: ["lungfish-cli", "assemble", bundle.path, "--assembler", "spades"],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 104),
            writer: ProvenanceWriter(signingProvider: nil)
        )
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: sidecarURL))
        let assembler = try XCTUnwrap(envelope.steps.first { $0.toolName == AssemblyTool.spades.rawValue })
        for mate in shapes.pairedFiles.map(\.standardizedFileURL) {
            XCTAssertTrue(assembler.inputs.contains { $0.path == mate.path && $0.originPath == bundle.path })
        }
        XCTAssertEqual(envelope.options.explicit["originalInputs"], .array([.file(bundle)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["originalInputs"], .array([.file(bundle), .file(bundle)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["pairedEnd"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["readPairing"], .string(AssemblyReadPairing.pairedFiles.rawValue))
        XCTAssertFalse(envelope.steps.contains { $0.toolName == SequenceInputConcatenation.toolName })
    }

    /// The app's per-bundle batch launch hands this command files that live
    /// inside a bundle: one chunk per run for a multi-file bundle, the R1 and
    /// R2 of a fullPaired bundle with --paired, the merged file of a fullMixed
    /// bundle. Each names its whole bundle, once.
    func testFilesOfOneBundleGivenSeparatelyAreAssembledAsThatBundleOnce() async throws {
        let chunk = try await resolve([shapes.multiFileChunks[1]])
        XCTAssertEqual(chunk.originalInputURLs, [shapes.multiFile.standardizedFileURL])
        XCTAssertEqual(chunk.executionInputURLs.count, 1)
        XCTAssertEqual(
            try BundleShapeFixtures.readNames(in: try XCTUnwrap(chunk.executionInputURLs.first)),
            ["m1", "m2", "m3", "m4", "m5"],
            "a chunk's run assembles the whole bundle, not chunk 0"
        )

        let mates = try await resolve(shapes.pairedFiles)
        XCTAssertEqual(mates.originalInputURLs, [shapes.paired.standardizedFileURL, shapes.paired.standardizedFileURL])
        XCTAssertEqual(mates.executionInputURLs, shapes.pairedFiles.map(\.standardizedFileURL))
        XCTAssertTrue(mates.resolvedAsMatePair)
        let pairedRun = try await assemble(shapes.pairedFiles, pairedFlag: true, label: "batch fullPaired")
        XCTAssertEqual(pairedRun.spades.forward, ["p1/1", "p2/1"], "R1 is the forward file, not assembled against itself")
        XCTAssertEqual(pairedRun.spades.reverse, ["p1/2", "p2/2"])
        XCTAssertEqual(pairedRun.spades.singleFiles, [])

        let merged = try await resolve([shapes.mixedFiles[0]])
        XCTAssertEqual(merged.originalInputURLs, [shapes.mixed.standardizedFileURL])
        XCTAssertEqual(
            try BundleShapeFixtures.readNames(in: try XCTUnwrap(merged.executionInputURLs.first)),
            ["x1", "x2", "x3", "u1/1", "u1/2"]
        )

        let twoBundles = try await resolve([shapes.single, shapes.full.appendingPathComponent("full.fastq")])
        XCTAssertEqual(twoBundles.originalInputURLs, [shapes.single.standardizedFileURL, shapes.full.standardizedFileURL])
    }

    /// Flye and hifiasm take one sample. The chunk files of one multi-file
    /// bundle are that bundle, which `assemble` reads as one joined file, so
    /// they take them as they take the bundle. Two loose files, two bundles,
    /// or a chunk with a loose file are two samples and stay refused (R3,
    /// lane 1q-2).
    func testLongReadAssemblersTakeTheFilesOfOneBundleAsOneSample() async throws {
        let loose = try ["loose_a", "loose_b"].map { name -> URL in
            let url = root.appendingPathComponent("\(name).fastq")
            try BundleShapeFixtures.fastq([name]).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        for tool in [AssemblyTool.flye, .hifiasm] {
            XCTAssertNoThrow(
                try AssembleCommand.validatePreMaterializationTopology(
                    tool: tool,
                    inputURLs: shapes.multiFileChunks,
                    pairedEnd: false
                ),
                "\(tool.rawValue): the chunk files of one bundle"
            )
            for samples in [loose, [shapes.single, shapes.multiFile], [shapes.multiFileChunks[0], loose[0]]] {
                XCTAssertThrowsError(
                    try AssembleCommand.validatePreMaterializationTopology(tool: tool, inputURLs: samples, pairedEnd: false),
                    "\(tool.rawValue): \(samples.map(\.lastPathComponent))"
                )
            }
            XCTAssertThrowsError(
                try AssembleCommand.validatePreMaterializationTopology(
                    tool: tool,
                    inputURLs: shapes.pairedFiles,
                    pairedEnd: true
                ),
                "\(tool.rawValue) never pairs"
            )
        }

        let resolved = try await resolve(shapes.multiFileChunks)
        XCTAssertEqual(resolved.originalInputURLs, [shapes.multiFile.standardizedFileURL])
        let joined = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(resolved.executionInputURLs.count, 1)
        XCTAssertEqual(try BundleShapeFixtures.readNames(in: joined), ["m1", "m2", "m3", "m4", "m5"])
        let flye = try ManagedAssemblyPipeline.buildCommand(for: request(.flye, resolved: resolved)).arguments
        XCTAssertTrue(flye.contains(joined.path), "Flye reads the joined chunks: \(flye)")
    }

    func testReadLayoutIsRefusedForABundleThatHoldsAMatePair() async throws {
        let output = root.appendingPathComponent("refused-assembly", isDirectory: true)
        let command = try AssembleCommand.parse([
            shapes.paired.path,
            "--assembler", "spades",
            "--read-type", "illumina-short-reads",
            "--read-layout", "interleaved",
            "--output", output.path,
        ])

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            XCTAssertEqual((error as? ExitCode)?.rawValue, CLIExitCode.inputError.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "refused before anything is written")
    }

    /// The shared resolver refuses an input with no readable payload before
    /// it writes anything, and `assemble` exits with its format error.
    func testAnUnreadableInputIsRefusedBeforeAnythingIsWritten() async throws {
        let emptyBundle = shapes.single.deletingLastPathComponent().appendingPathComponent("empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let command = try AssembleCommand.parse([
            shapes.oriented.path,
            emptyBundle.path,
            "--assembler", "spades",
            "--read-type", "illumina-short-reads",
            "--output", output.path,
        ])

        await XCTAssertThrowsErrorAsync(try await command.run()) { error in
            XCTAssertEqual((error as? ExitCode)?.rawValue, CLIExitCode.formatError.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "nothing was materialized")
    }

    // MARK: - Helpers

    private struct AssembleRun {
        let resolved: ResolvedSequenceInputs
        let layout: FASTQInputLayoutResolution?
        let request: AssemblyRunRequest
        let result: AssemblyResult
        let spades: StandInSPAdes.Seen
    }

    private func resolve(_ bundle: URL) async throws -> ResolvedSequenceInputs {
        try await resolve([bundle])
    }

    private func resolve(_ inputs: [URL]) async throws -> ResolvedSequenceInputs {
        try await ResolvedSequenceInputs.resolveForAssembly(
            inputURLs: inputs,
            materializationDirectory: root.appendingPathComponent("resolve-\(UUID().uuidString)/.lungfish-assembly-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
    }

    private func request(
        _ tool: AssemblyTool,
        resolved: ResolvedSequenceInputs,
        pairedEnd: Bool = false,
        layout: FASTQInputLayout? = nil
    ) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: tool == .flye || tool == .hifiasm ? .ontReads : .illuminaShortReads,
            inputURLs: resolved.executionInputURLs,
            projectName: "fixture",
            outputDirectory: root.appendingPathComponent("out-\(tool.rawValue)-\(UUID().uuidString)", isDirectory: true),
            pairedEnd: pairedEnd,
            threads: 2,
            inputLayout: layout
        )
    }

    /// Assembles `bundle` with SPAdes the way `AssembleCommand.run` does:
    /// the shared resolution, pairing and layout rules it calls, and
    /// `ManagedAssemblyPipeline` with a stand-in SPAdes.
    private func assemble(_ bundle: URL, label: String) async throws -> AssembleRun {
        try await assemble([bundle], pairedFlag: false, label: label)
    }

    private func assemble(_ inputs: [URL], pairedFlag: Bool, label: String) async throws -> AssembleRun {
        let runRoot = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let spades = try StandInSPAdes(root: runRoot)
        let outputDirectory = runRoot.appendingPathComponent("assembly", isDirectory: true)
        let resolved = try await ResolvedSequenceInputs.resolveForAssembly(
            inputURLs: inputs,
            materializationDirectory: outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        let pairedEnd = pairedFlag || resolved.resolvedAsMatePair
        let layout = AssemblyRunRequest.resolveInputLayout(
            tool: .spades,
            readType: .illuminaShortReads,
            pairedEnd: pairedEnd,
            explicit: nil,
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs,
            pooled: resolved.pooledLayoutResolution
        )
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: resolved.executionInputURLs,
            projectName: "fixture",
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: 2,
            inputLayout: layout?.layout
        ).normalizedForExecution()
        let result = try await ManagedAssemblyPipeline(condaManager: spades.condaManager).run(request: request)
        return AssembleRun(resolved: resolved, layout: layout, request: request, result: result, spades: try spades.seen())
    }
}

/// A conda root whose stand-in micromamba runs a stand-in SPAdes: it keeps a
/// copy of every read file it is handed under the flag it came with and
/// writes one contig.
private struct StandInSPAdes {
    struct Seen {
        /// The record names of each `-s` file, in argument order.
        let singleFiles: [[String]]
        let forward: [String]
        let reverse: [String]
        /// The record names of each `--merged` file, in argument order.
        let mergedFiles: [[String]]
    }

    let condaManager: CondaManager
    private let seenDirectory: URL

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        seenDirectory = root.appendingPathComponent("spades-saw", isDirectory: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script(seenDirectory: seenDirectory).write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func seen() throws -> Seen {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: seenDirectory.path)) ?? []
        func reads(_ name: String) throws -> [String] {
            try BundleShapeFixtures.readNames(in: seenDirectory.appendingPathComponent(name))
        }
        func numbered(_ prefix: String) -> [String] {
            names
                .filter { $0.hasPrefix("\(prefix)-") }
                .sorted { (Int($0.dropFirst(prefix.count + 1)) ?? 0) < (Int($1.dropFirst(prefix.count + 1)) ?? 0) }
        }
        return Seen(
            singleFiles: try numbered("single").map(reads),
            forward: names.contains("forward") ? try reads("forward") : [],
            reverse: names.contains("reverse") ? try reads("reverse") : [],
            mergedFiles: try numbered("merged").map(reads)
        )
    }

    private static func script(seenDirectory: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ] || [ "$2" != "-n" ]; then
          echo "unexpected micromamba invocation: $*" >&2
          exit 64
        fi
        tool="$4"
        shift 4
        if [ "$tool" = "spades.py" ] && { [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; }; then
          echo "SPAdes 4.2.0"
          exit 0
        fi
        if [ "$tool" != "spades.py" ]; then
          echo "unexpected tool: $tool" >&2
          exit 65
        fi
        seen='\(seenDirectory.path)'
        mkdir -p "$seen"
        outdir=""
        single=0
        merged=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o)
              shift
              outdir="$1"
              ;;
            --merged)
              shift
              merged=$((merged + 1))
              cp "$1" "$seen/merged-$merged"
              ;;
            -s)
              shift
              single=$((single + 1))
              cp "$1" "$seen/single-$single"
              ;;
            -1)
              shift
              cp "$1" "$seen/forward"
              ;;
            -2)
              shift
              cp "$1" "$seen/reverse"
              ;;
            --12)
              shift
              cp "$1" "$seen/interleaved"
              ;;
          esac
          shift
        done
        if [ -z "$outdir" ]; then
          echo "missing -o argument" >&2
          exit 66
        fi
        mkdir -p "$outdir"
        printf '>contig1\\nACGTACGTACGTACGTACGT\\n' > "$outdir/contigs.fasta"
        echo "SPAdes pipeline finished" > "$outdir/spades.log"
        exit 0
        """
    }
}
