// ClassifyCommandResolutionTests.swift - lungfish-cli conda classify resolves a bundle the way the app does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A bundle argument to `lungfish-cli conda classify` hands kraken2 every file
/// the bundle holds, as the app's classification launch does, so the command
/// the Operations panel records classifies the same reads. A bundle of single
/// reads runs each file unpaired. A paired or merge derivative runs its pair
/// with `--paired` and its merged reads beside the pair, each with a staged
/// empty mate (decision 1, lane A2). A stand-in kraken2 keeps a copy of every
/// input it is handed.
final class ClassifyCommandResolutionTests: XCTestCase {

    private var root: URL!
    private var shapes: BundleShapeFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classify-command-resolution")
        shapes = try BundleShapeFixtures(
            in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testKraken2IsHandedEveryFileOfEachBundleShape() async throws {
        let cases: [(shape: String, bundle: URL, files: [[String]], paired: Bool)] = [
            ("root single", shapes.single, [["s1", "s2", "s3"]], false),
            ("root multi-file", shapes.multiFile, [["m1", "m2"], ["m3", "m4", "m5"]], false),
            ("virtual orientMap", shapes.oriented, [["s1", "s3"]], false),
            ("derived fullPaired", shapes.paired, [["p1/1", "p2/1"], ["p1/2", "p2/2"]], true),
            // The pair, then the merged reads and their staged empty mate.
            ("derived fullMixed", shapes.mixed, [["u1/1"], ["u1/2"], ["x1", "x2", "x3"], ["x1", "x2", "x3"]], true),
            ("derived fullFASTA", shapes.fasta, [["f1", "f2"]], false),
            ("derived full", shapes.full, [["g1", "g2"]], false),
        ]
        for testCase in cases {
            let run = try await classify(testCase.bundle, label: testCase.shape)
            XCTAssertEqual(run.filesSeen, testCase.files, testCase.shape)
            XCTAssertEqual(run.pairedFlag, testCase.paired, "\(testCase.shape) runs as the app runs it")
        }
    }

    func testABundleThatHoldsSeveralFilesIsRecordedAsTheOriginOfEach() async throws {
        let run = try await classify(shapes.multiFile, label: "multi-file")
        let bundle = shapes.multiFile.standardizedFileURL
        let chunks = shapes.multiFileChunks.map(\.standardizedFileURL)
        XCTAssertEqual(run.resolved.executionInputURLs, chunks)
        XCTAssertEqual(run.resolved.originalInputURLs, [bundle, bundle])

        let sidecarURL = try ClassifyCommand.writeProvenance(
            result: run.result,
            originalInputURLs: run.resolved.originalInputURLs,
            executionInputURLs: run.resolved.executionInputURLs,
            argv: ["lungfish-cli", "conda", "classify", bundle.path, "--db", "FixtureDB"],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 104),
            writer: ProvenanceWriter(signingProvider: nil)
        )
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.options.explicit["originalInputs"], .array([.file(bundle)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["originalInputs"], .array([.file(bundle), .file(bundle)]))
        XCTAssertEqual(envelope.options.resolvedDefaults["executionInputs"], .array(chunks.map { .file($0) }))
        let krakenInputs = Set(envelope.steps.filter { $0.toolName == "kraken2" }.flatMap(\.inputs).map(\.path))
        XCTAssertTrue(Set(chunks.map(\.path)).isSubset(of: krakenInputs), "kraken2 inputs: \(krakenInputs)")

        // A run that fails after resolution records each file with its bundle.
        let command = try ClassifyCommand.parse([bundle.path, "--db", "FixtureDB"])
        let failedRunDirectory = root.appendingPathComponent("failed-run", isDirectory: true)
        try FileManager.default.createDirectory(at: failedRunDirectory, withIntermediateDirectories: true)
        var context = ClassifyFailureProvenanceContext(
            outputDirectory: failedRunDirectory,
            originalInputURLs: [bundle]
        )
        context.executionInputURLs = run.resolved.executionInputURLs
        context.executionOriginalInputURLs = run.resolved.originalInputURLs
        context.inputFormat = .fastq
        context.stage = .pipeline
        let failureURL = try ClassifyCommand.writeFailureProvenance(
            command: command,
            context: context,
            argv: ["lungfish-cli", "conda", "classify", bundle.path, "--db", "FixtureDB"],
            exitStatus: 1,
            profileState: "failed",
            stderr: "synthetic failure",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            writer: ProvenanceWriter(signingProvider: nil)
        )
        let failure = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: failureURL))
        for chunk in chunks {
            XCTAssertTrue(
                failure.files.contains { $0.path == chunk.path && $0.originPath == bundle.path },
                "\(chunk.lastPathComponent) is recorded with the bundle it came from"
            )
        }
        XCTAssertEqual(failure.options.resolvedDefaults["originalInputs"], .array([.file(bundle), .file(bundle)]))
    }

    func testAVirtualBundlePrintsOnlyTheMaterializersOwnProgressLines() async throws {
        let direct = MessageLog()
        let directDirectory = root.appendingPathComponent("direct", isDirectory: true)
        try FileManager.default.createDirectory(at: directDirectory, withIntermediateDirectories: true)
        _ = try await FASTQCLIMaterializer(runner: .shared).materialize(
            bundleURL: shapes.oriented,
            tempDirectory: directDirectory,
            progress: { direct.append($0) }
        )
        let throughCommand = MessageLog()
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: [shapes.oriented],
            tempDirectory: root.appendingPathComponent("out/.lungfish-classify-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared),
            progress: { throughCommand.append($0) }
        )

        XCTAssertEqual(resolved.executionInputURLs.count, 1)
        XCTAssertFalse(direct.messages.isEmpty)
        XCTAssertEqual(throughCommand.messages, direct.messages, "a run prints the lines it printed before")
    }

    func testDurableReplayArgumentsFollowEachExecutionFile() async throws {
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: [shapes.multiFile, shapes.single],
            tempDirectory: root.appendingPathComponent("out/.lungfish-classify-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        XCTAssertEqual(
            resolved.argumentsPerExecutionFile(["multi.lungfishfastq", "single.lungfishfastq"]),
            ["multi.lungfishfastq", "multi.lungfishfastq", "single.lungfishfastq"]
        )
        XCTAssertEqual(
            resolved.argumentsPerExecutionFile(["Imports"]),
            [],
            "a folder argument that expanded into several inputs is not paired with any one of them"
        )
    }

    func testADemuxGroupAndAnUnreadableInputAreRefusedBeforeAnythingIsWritten() async throws {
        let group = shapes.single.deletingLastPathComponent().appendingPathComponent("group.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let operation = FASTQDerivativeOperation(kind: .demultiplex)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "group",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "none.fastq",
                payload: .demuxGroup(barcodeCount: 2),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: group
        )
        let notes = root.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        let emptyBundle = shapes.single.deletingLastPathComponent().appendingPathComponent("empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let inputsDirectory = root.appendingPathComponent("out/.lungfish-classify-inputs", isDirectory: true)

        await XCTAssertThrowsErrorAsync(
            try await ClassifyCommand.resolveExecutionInputs(
                for: [shapes.oriented, group],
                tempDirectory: inputsDirectory,
                materializer: FASTQCLIMaterializer(runner: .shared)
            )
        ) { error in
            guard case CLISequenceInputMaterializationError.unsupportedSequenceInput = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        for unreadable in [notes, emptyBundle] {
            await XCTAssertThrowsErrorAsync(
                try await ClassifyCommand.resolveExecutionInputs(
                    for: [shapes.oriented, unreadable],
                    tempDirectory: inputsDirectory,
                    materializer: FASTQCLIMaterializer(runner: .shared)
                )
            ) { error in
                guard case CLISequenceInputMaterializationError.unreadableSequenceInput = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputsDirectory.path), "nothing was materialized")
    }

    // MARK: - Helpers

    private struct ClassifyRun {
        let resolved: ResolvedSequenceInputs
        let result: ClassificationResult
        /// The record names of each file kraken2 was handed, in argument order.
        let filesSeen: [[String]]
        let pairedFlag: Bool
    }

    /// Classifies `bundle` the way `ClassifyCommand.run` does: its own
    /// resolution, the read format resolved on the input as given, and
    /// `ClassificationPipeline` with a stand-in kraken2.
    private func classify(_ bundle: URL, label: String) async throws -> ClassifyRun {
        let runRoot = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let kraken2 = try StandInKraken2(root: runRoot)
        let outputDirectory = runRoot.appendingPathComponent("classification", isDirectory: true)
        let command = try ClassifyCommand.parse([bundle.path, "--db", "FixtureDB"])
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: [bundle],
            tempDirectory: outputDirectory.appendingPathComponent(".lungfish-classify-inputs", isDirectory: true),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        var config = try command.makeConfigForTesting(
            inputURLs: [bundle],
            databasePath: kraken2.databaseURL,
            inputFormat: try ClassifyCommand.inferInputFormat(from: [bundle]),
            outputDirectory: outputDirectory
        )
        config.inputFiles = resolved.executionInputURLs
        config.originalInputFiles = [bundle.standardizedFileURL]
        _ = try await command.planReadSet(
            inputURLs: [bundle.standardizedFileURL],
            executionInputURLs: resolved.executionInputURLs,
            config: &config,
            materializationDirectory: outputDirectory.appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
        )
        let result = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: config)
        return ClassifyRun(
            resolved: resolved,
            result: result,
            filesSeen: try kraken2.inputsSeen().map(BundleShapeFixtures.readNames(in:)),
            pairedFlag: kraken2.wasPaired
        )
    }
}

/// Collects progress lines from a `@Sendable` callback.
private final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var messages: [String] { lock.withLock { recorded } }

    func append(_ message: String) {
        lock.withLock { recorded.append(message) }
    }
}

/// A conda root whose stand-in micromamba runs a stand-in kraken2: it keeps
/// a copy of every input file it is handed, notes `--paired`, and writes a
/// one-read report and per-read output.
private struct StandInKraken2 {
    let condaManager: CondaManager
    let databaseURL: URL
    private let seenDirectory: URL

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: databaseURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        seenDirectory = root.appendingPathComponent("kraken2-saw", isDirectory: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script(seenDirectory: seenDirectory).write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    /// The copies of the files kraken2 was handed, in argument order.
    func inputsSeen() throws -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: seenDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("input-") }
            .sorted { (Int($0.dropFirst("input-".count)) ?? 0) < (Int($1.dropFirst("input-".count)) ?? 0) }
            .map { seenDirectory.appendingPathComponent($0) }
    }

    var wasPaired: Bool {
        FileManager.default.fileExists(atPath: seenDirectory.appendingPathComponent("paired").path)
    }

    private static func script(seenDirectory: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "micromamba 2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ]; then
          echo "unexpected micromamba invocation: $*" >&2
          exit 64
        fi
        shift
        if [ "$1" = "-n" ]; then
          shift
          shift
        fi
        tool="$1"
        shift
        if [ "$tool" != "kraken2" ]; then
          echo "unexpected tool: $tool" >&2
          exit 64
        fi
        if [ "$1" = "--version" ]; then
          echo "Kraken version 2.1.3"
          exit 0
        fi
        seen='\(seenDirectory.path)'
        mkdir -p "$seen"
        report=""
        output=""
        index=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --db|--threads|--confidence|--minimum-hit-groups)
              shift
              ;;
            --report)
              shift
              report="$1"
              ;;
            --output)
              shift
              output="$1"
              ;;
            --paired)
              : > "$seen/paired"
              ;;
            --*)
              ;;
            *)
              index=$((index + 1))
              cp "$1" "$seen/input-$index"
              ;;
          esac
          shift
        done
        mkdir -p "$(dirname "$report")" "$(dirname "$output")"
        printf '100.00\\t1\\t0\\tR\\t1\\troot\\n100.00\\t1\\t1\\tS\\t562\\t  Escherichia coli\\n' > "$report"
        # One per-read line per fragment: a pair, or a file of single reads
        # staged with its empty mate, counts once.
        total=0
        position=0
        paired=0
        [ -f "$seen/paired" ] && paired=1
        for f in "$seen"/input-*; do
          [ -f "$f" ] || continue
          position=$((position + 1))
          if [ "$paired" = 1 ] && [ $((position % 2)) = 0 ]; then continue; fi
          total=$((total + $(awk 'END { print int(NR / 4) }' "$f")))
        done
        : > "$output"
        i=0
        while [ "$i" -lt "$total" ]; do printf 'C\\tread%s\\t562\\t4\\t0:4\\n' "$i" >> "$output"; i=$((i + 1)); done
        echo "$total sequences (0.00 Mbp) processed in 0.001s" >&2
        exit 0
        """
    }
}
