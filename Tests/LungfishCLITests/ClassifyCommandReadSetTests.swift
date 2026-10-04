// ClassifyCommandReadSetTests.swift - lungfish-cli conda classify runs pairs as pairs and single reads beside them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// `conda classify <bundle>` under `--read-format auto` plans the bundle's
/// read set (owner decisions 1 and 2, docs/contracts/READ-PAIRING.md). Single
/// reads and an interleaved file keep today's kraken2 command, a paired
/// derivative runs `--paired R1 R2`, and a merge, repair or mixed root runs
/// its pair with each file of single reads and a staged empty mate beside it.
/// A stand-in kraken2 records its argv.
final class ClassifyCommandReadSetTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classify-read-set")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testSingleReadsAndInterleavedFilesKeepTodaysKraken2Command() async throws {
        for bundle in [fixtures.singleRoot, fixtures.subsetOfSingle, fixtures.interleavedRoot, fixtures.chunkedRoot] {
            let run = try await plan([bundle.path])
            XCTAssertNil(run.planned, "\(bundle.lastPathComponent) is not replanned")
            XCTAssertEqual(run.config.kraken2Arguments(), run.unplanned.kraken2Arguments(), bundle.lastPathComponent)
            XCTAssertEqual(run.config.singleReadFiles, [], bundle.lastPathComponent)
            XCTAssertFalse(run.config.plansReadSet, bundle.lastPathComponent)
        }
    }

    func testTheGoldenShapedVirtualSubsetWritesOnlyItsMaterialization() async throws {
        let run = try await plan([fixtures.subsetOfSingle.path])
        let inputs = try FileManager.default.contentsOfDirectory(atPath: run.inputsDirectory.path)
        XCTAssertEqual(inputs.count, 1, "only the materialized file: \(inputs)")
        XCTAssertEqual(try run.config.inputFiles.map(ReadSetFixtures.readNames(in:)), [["s1", "s3"]])
    }

    func testPairedDerivativeRunsPaired() async throws {
        let (run, kraken2) = try await classify([fixtures.pairedDerivative.path])
        let r1 = fixtures.pairedDerivative.appendingPathComponent("sample_R1.fastq").standardizedFileURL.path
        let r2 = fixtures.pairedDerivative.appendingPathComponent("sample_R2.fastq").standardizedFileURL.path
        XCTAssertEqual(Array(try kraken2.argv().suffix(3)), ["--report-minimizer-data", r1, r2])
        XCTAssertTrue(try kraken2.argv().contains("--paired"))
        XCTAssertEqual(run.planned?.originalInputURLs, [fixtures.pairedDerivative.standardizedFileURL, fixtures.pairedDerivative.standardizedFileURL])
    }

    func testMergeDerivativeRunsItsPairAndMergedReadsTogether() async throws {
        let (run, kraken2) = try await classify([fixtures.mergeDerivative.path])
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq").standardizedFileURL
        XCTAssertEqual(Array(try kraken2.argv().suffix(4)), [
            fixtures.mergeDerivative.appendingPathComponent("unmerged_R1.fastq").standardizedFileURL.path,
            fixtures.mergeDerivative.appendingPathComponent("unmerged_R2.fastq").standardizedFileURL.path,
            merged.path,
            run.config.emptyMateURL(for: merged).path,
        ])
        XCTAssertEqual(try kraken2.inputsSeen().map(ReadSetFixtures.readNames(in:)), [["u1/1"], ["u1/2"], ["x1", "x2", "x3"], ["x1", "x2", "x3"]])
    }

    func testRepairDerivativeRunsItsPairAndOrphansTogether() async throws {
        let (run, kraken2) = try await classify([fixtures.repairDerivative.path])
        let singletons = fixtures.repairDerivative.appendingPathComponent("singletons.fastq").standardizedFileURL
        XCTAssertEqual(Array(try kraken2.argv().suffix(2)), [singletons.path, run.config.emptyMateURL(for: singletons).path])
        XCTAssertEqual(run.config.fragmentComposition?.orphanReads, 1)
    }

    func testMixedRootIsSplitByNameThenStaged() async throws {
        let (run, kraken2) = try await classify([fixtures.mixedRoot.path])
        XCTAssertEqual(try kraken2.inputsSeen().map(ReadSetFixtures.readNames(in:)), [
            ["p1/1", "p2/1"], ["p1/2", "p2/2"], ["m1", "m2", "m3"], ["m1", "m2", "m3"],
        ])
        XCTAssertTrue(run.config.inputFiles.allSatisfy { $0.path.hasPrefix(run.inputsDirectory.standardizedFileURL.path) })
    }

    func testVirtualSubsetOfAMergeDerivativeIsPlannedFromItsMaterialization() async throws {
        let (_, kraken2) = try await classify([fixtures.subsetOfMerge.path])
        XCTAssertEqual(try kraken2.inputsSeen().map(ReadSetFixtures.readNames(in:)), [["u1/1"], ["u1/2"], ["x1"], ["x1"]])
    }

    func testLooseFilesTakeUnpairedReadsBesideThePair() async throws {
        // Loose files outside any bundle, as a user names them.
        let loose = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        var copies: [URL] = []
        for name in ["unmerged_R1.fastq", "unmerged_R2.fastq", "merged.fastq"] {
            let copy = loose.appendingPathComponent(name).standardizedFileURL
            try FileManager.default.copyItem(at: fixtures.mergeDerivative.appendingPathComponent(name), to: copy)
            copies.append(copy)
        }
        let (r1, r2, merged) = (copies[0], copies[1], copies[2])
        let (run, kraken2) = try await classify([r1.path, r2.path, "--paired", "--unpaired", merged.path])
        XCTAssertEqual(Array(try kraken2.argv().suffix(4)), [r1.path, r2.path, merged.path, run.config.emptyMateURL(for: merged).path])
        XCTAssertFalse(run.config.plansReadSet, "loose files are recorded with --paired and --unpaired")
        // The recorded command names the pair and the single reads, and it
        // parses and plans to the same kraken2 command.
        let recorded = Array(ClassificationCLIInvocationBuilder.build(for: run.config).arguments.dropFirst(2))
        XCTAssertEqual(Array(recorded.suffix(2)), [r1.path, r2.path])
        let unpairedAt = try XCTUnwrap(recorded.firstIndex(of: "--unpaired"))
        XCTAssertEqual(recorded[unpairedAt + 1], merged.path)
        XCTAssertTrue(recorded.contains("--paired"))
        let replay = try await plan(recorded, database: run.config.databasePath, outputDirectory: run.config.outputDirectory)
        XCTAssertEqual(replay.config.kraken2Arguments(), run.config.kraken2Arguments())
    }

    func testALooseMixedFileIsSplitByNameThenStaged() async throws {
        let mixed = try looseCopy(of: fixtures.mixedRoot.appendingPathComponent("reads.fastq"), into: "loose-mixed")
        let (run, kraken2) = try await classify([mixed.path])
        XCTAssertEqual(try kraken2.inputsSeen().map(ReadSetFixtures.readNames(in:)), [
            ["p1/1", "p2/1"], ["p1/2", "p2/2"], ["m1", "m2", "m3"], ["m1", "m2", "m3"],
        ])
        XCTAssertTrue(try kraken2.argv().contains("--paired"))
        // Recorded with auto, so the pasted command plans the file again.
        let recorded = Array(ClassificationCLIInvocationBuilder.build(for: run.config).arguments.dropFirst(2))
        XCTAssertTrue(recorded.contains("auto"))
        XCTAssertFalse(recorded.contains("--paired"))
        XCTAssertFalse(recorded.contains("--unpaired"))
        XCTAssertEqual(recorded.last, mixed.path)
        // Each run writes its split under a new name, so the replay is
        // compared by flags and by the reads of each file kraken2 reads.
        let replay = try await plan(recorded, database: run.config.databasePath, outputDirectory: run.config.outputDirectory)
        XCTAssertEqual(flags(replay.config.kraken2Arguments()), flags(run.config.kraken2Arguments()))
        XCTAssertEqual(
            try (replay.config.inputFiles + replay.config.singleReadFiles).map(ReadSetFixtures.readNames(in:)),
            try (run.config.inputFiles + run.config.singleReadFiles).map(ReadSetFixtures.readNames(in:))
        )
    }

    func testLooseSingleEndAndInterleavedFilesKeepTodaysCommand() async throws {
        let single = try looseCopy(of: fixtures.singleRoot.appendingPathComponent("single.fastq"), into: "loose-single")
        let interleaved = try looseCopy(of: fixtures.interleavedRoot.appendingPathComponent("reads.fastq"), into: "loose-interleaved")
        for file in [single, interleaved] {
            let run = try await plan([file.path])
            XCTAssertNil(run.planned, file.lastPathComponent)
            XCTAssertEqual(run.config.kraken2Arguments(), run.unplanned.kraken2Arguments(), file.path)
            XCTAssertEqual(run.config.inputFiles, run.unplanned.inputFiles, file.path)
            XCTAssertFalse(run.config.plansReadSet, file.path)
        }
    }

    func testUnpairedNeedsAPairOfFiles() throws {
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")
        let command = try ClassifyCommand.parse([merged.path, "--unpaired", merged.path, "--db", "FixtureDB"])
        XCTAssertThrowsError(try command.resolveReadFormat(inputURLs: [merged]))
        let bundle = try ClassifyCommand.parse([fixtures.mergeDerivative.path, "--paired", "--unpaired", merged.path, "--db", "FixtureDB"])
        XCTAssertThrowsError(try bundle.resolveReadFormat(inputURLs: [fixtures.mergeDerivative]))
    }

    func testExplicitUnpairedKeepsTodaysCommand() async throws {
        let run = try await plan([fixtures.pairedDerivative.path, "--read-format", "unpaired"])
        XCTAssertNil(run.planned)
        XCTAssertFalse(run.config.isPairedEnd)
    }

    // MARK: - Helpers

    private struct PlannedRun {
        let config: ClassificationConfig
        let unplanned: ClassificationConfig
        let planned: ClassifyCommand.PlannedReadSetInputs?
        let inputsDirectory: URL
    }

    /// The kraken2 arguments that are not file paths.
    private func flags(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.hasPrefix("/") }
    }

    /// A copy of `file` outside any bundle, with no sidecar.
    private func looseCopy(of file: URL, into folder: String) throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(file.lastPathComponent).standardizedFileURL
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Resolves and plans the inputs the way `ClassifyCommand.run` does.
    private func plan(
        _ arguments: [String],
        database: URL? = nil,
        outputDirectory: URL? = nil
    ) async throws -> PlannedRun {
        var arguments = arguments
        if !arguments.contains("--db") { arguments += ["--db", "FixtureDB"] }
        let command = try ClassifyCommand.parse(arguments)
        let inputs = command.fastqFiles.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let outputDirectory = outputDirectory ?? root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let inputsDirectory = outputDirectory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: inputs, tempDirectory: inputsDirectory, materializer: fixtures.materializer
        )
        var config = try command.makeConfigForTesting(
            inputURLs: inputs,
            databasePath: database ?? root.appendingPathComponent("db", isDirectory: true),
            inputFormat: try ClassifyCommand.inferInputFormat(from: inputs),
            outputDirectory: outputDirectory
        )
        config.inputFiles = resolved.executionInputURLs
        config.originalInputFiles = inputs
        let unplanned = config
        let planned = try await command.planReadSet(
            inputURLs: inputs,
            executionInputURLs: resolved.executionInputURLs,
            config: &config,
            materializationDirectory: inputsDirectory
        )
        return PlannedRun(config: config, unplanned: unplanned, planned: planned, inputsDirectory: inputsDirectory)
    }

    private func classify(_ arguments: [String]) async throws -> (PlannedRun, ReadSetStandInKraken2) {
        let kraken2 = try ReadSetStandInKraken2(root: root.appendingPathComponent("kraken-\(UUID().uuidString)"))
        let run = try await plan(arguments, database: kraken2.databaseURL)
        _ = try await ClassificationPipeline(condaManager: kraken2.condaManager).classify(config: run.config)
        return (run, kraken2)
    }
}

/// A conda root whose stand-in micromamba runs a stand-in kraken2 that
/// records its argv, keeps each input and reports one fragment per pair or
/// single read, as kraken2 does.
struct ReadSetStandInKraken2 {
    let condaManager: CondaManager
    let databaseURL: URL
    let seenDirectory: URL

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
        try Self.script(seen: seenDirectory).write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    func argv() throws -> [String] {
        try String(contentsOf: seenDirectory.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func inputsSeen() throws -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: seenDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("input-") }
            .sorted { (Int($0.dropFirst(6)) ?? 0) < (Int($1.dropFirst(6)) ?? 0) }
            .map { seenDirectory.appendingPathComponent($0) }
    }

    private static func script(seen: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
        [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
        shift
        if [ "$1" = "-n" ]; then shift; shift; fi
        tool="$1"; shift
        [ "$tool" = "kraken2" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
        if [ "$1" = "--version" ]; then echo "Kraken version 2.1.3"; exit 0; fi
        seen='\(seen.path)'
        mkdir -p "$seen"
        : > "$seen/argv"
        for arg in "$@"; do printf '%s\\n' "$arg" >> "$seen/argv"; done
        report=""; output=""; paired=0; index=0; files=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --db|--threads|--confidence|--minimum-hit-groups) shift ;;
            --report) shift; report="$1" ;;
            --output) shift; output="$1" ;;
            --paired) paired=1 ;;
            --*) ;;
            *) index=$((index + 1)); cp "$1" "$seen/input-$index"; files="$files $1" ;;
          esac
          shift
        done
        total=0; position=0
        for f in $files; do
          position=$((position + 1))
          if [ "$paired" = 1 ] && [ $((position % 2)) = 0 ]; then continue; fi
          total=$((total + $(awk 'END { print int(NR / 4) }' "$f")))
        done
        mkdir -p "$(dirname "$report")" "$(dirname "$output")"
        printf '100.00\\t1\\t0\\tR\\t1\\troot\\n100.00\\t1\\t1\\tS\\t562\\t  Escherichia coli\\n' > "$report"
        : > "$output"
        i=0
        while [ "$i" -lt "$total" ]; do printf 'C\\tread%s\\t562\\t4\\t0:4\\n' "$i" >> "$output"; i=$((i + 1)); done
        echo "$total sequences (0.00 Mbp) processed in 0.001s (1.0 Kseq/m, 0.01 Mbp/m)." >&2
        exit 0
        """
    }
}
