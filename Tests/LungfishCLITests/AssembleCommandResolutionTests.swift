// AssembleCommandResolutionTests.swift - lungfish-cli assemble resolves a bundle the way lungfish-cli map does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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
        let cases: [(shape: String, bundle: URL, single: [[String]], forward: [String], reverse: [String])] = [
            ("root single", shapes.single, [["s1", "s2", "s3"]], [], []),
            ("root multi-file", shapes.multiFile, [["m1", "m2", "m3", "m4", "m5"]], [], []),
            ("virtual orientMap", shapes.oriented, [["s1", "s3"]], [], []),
            ("derived fullPaired", shapes.paired, [], ["p1/1", "p2/1"], ["p1/2", "p2/2"]),
            ("derived fullMixed", shapes.mixed, [["x1", "x2", "x3", "u1/1", "u1/2"]], [], []),
            ("derived fullFASTA", shapes.fasta, [["f1", "f2"]], [], []),
            ("derived full", shapes.full, [["g1", "g2"]], [], []),
        ]
        for testCase in cases {
            let run = try await assemble(testCase.bundle, label: testCase.shape)
            XCTAssertEqual(run.spades.singleFiles, testCase.single, testCase.shape)
            XCTAssertEqual(run.spades.forward, testCase.forward, testCase.shape)
            XCTAssertEqual(run.spades.reverse, testCase.reverse, testCase.shape)
        }
    }

    func testEveryAssemblerReceivesTheConcatenatedReadsOfAMultiFileBundle() async throws {
        let resolved = try await resolve(shapes.multiFile)
        let concatenated = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(resolved.executionInputURLs.count, 1)
        XCTAssertEqual(try BundleShapeFixtures.readNames(in: concatenated), ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertFalse(resolved.resolvedAsMatePair)
        let layout = try XCTUnwrap(AssembleCommand.resolveInputLayout(
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

    func testAnUnreadableInputIsRefusedBeforeAnythingIsWritten() async throws {
        let emptyBundle = shapes.single.deletingLastPathComponent().appendingPathComponent("empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let inputsDirectory = root.appendingPathComponent("out/.lungfish-assembly-inputs", isDirectory: true)

        await XCTAssertThrowsErrorAsync(
            try await AssembleCommand.resolveExecutionInputs(
                for: [shapes.oriented, emptyBundle],
                tempDirectory: inputsDirectory,
                materializer: FASTQCLIMaterializer(runner: .shared)
            )
        ) { error in
            guard case AssembleInputResolutionError.unreadableBundlePayload = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputsDirectory.path), "nothing was materialized")
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
        try await AssembleCommand.resolveExecutionInputs(
            for: [bundle],
            tempDirectory: root.appendingPathComponent("resolve-\(UUID().uuidString)/.lungfish-assembly-inputs", isDirectory: true),
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
    /// its own resolution, pairing and layout, and `ManagedAssemblyPipeline`
    /// with a stand-in SPAdes.
    private func assemble(_ bundle: URL, label: String) async throws -> AssembleRun {
        let runRoot = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let spades = try StandInSPAdes(root: runRoot)
        let outputDirectory = runRoot.appendingPathComponent("assembly", isDirectory: true)
        let resolved = try await AssembleCommand.resolveExecutionInputs(
            for: [bundle],
            tempDirectory: outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        let pairedEnd = resolved.resolvedAsMatePair
        let layout = AssembleCommand.resolveInputLayout(
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
        let single = names
            .filter { $0.hasPrefix("single-") }
            .sorted { (Int($0.dropFirst("single-".count)) ?? 0) < (Int($1.dropFirst("single-".count)) ?? 0) }
        return Seen(
            singleFiles: try single.map(reads),
            forward: names.contains("forward") ? try reads("forward") : [],
            reverse: names.contains("reverse") ? try reads("reverse") : []
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
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o)
              shift
              outdir="$1"
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
