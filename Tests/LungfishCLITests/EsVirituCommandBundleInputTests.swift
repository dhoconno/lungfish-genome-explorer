// EsVirituCommandBundleInputTests.swift - lungfish-cli esviritu detect reads a FASTQ bundle the way the app does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// The app's EsViritu launch hands EsViritu every file a `.lungfishfastq`
/// bundle holds, materializing a virtual bundle first, and records the
/// command `lungfish-cli esviritu detect --input <bundle> ...`. The command
/// used to refuse the bundle as a directory, so the recorded command could
/// not be replayed (R3). It now resolves a bundle through
/// `ResolvedSequenceInputs` and records the bundle behind each file in
/// provenance. A stand-in EsViritu keeps a copy of every read file it is
/// handed and the `-p` read format.
final class EsVirituCommandBundleInputTests: XCTestCase {

    private var root: URL!
    private var shapes: BundleShapeFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-command-bundle-input")
        shapes = try BundleShapeFixtures(
            in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testEsVirituIsHandedEveryFileOfEachBundleShape() async throws {
        let cases: [(shape: String, bundle: URL, files: [[String]])] = [
            ("root single", shapes.single, [["s1", "s2", "s3"]]),
            ("root multi-file", shapes.multiFile, [["m1", "m2"], ["m3", "m4", "m5"]]),
            ("virtual orientMap", shapes.oriented, [["s1", "s3"]]),
            ("derived full", shapes.full, [["g1", "g2"]]),
        ]
        for testCase in cases {
            let run = try await detect(testCase.bundle, readFormat: "unpaired", label: testCase.shape)
            XCTAssertEqual(run.filesSeen, testCase.files, testCase.shape)
            XCTAssertEqual(run.formatSeen, "unpaired", testCase.shape)
        }
    }

    func testAPairedBundleRunsItsMatesAsAPair() async throws {
        let run = try await detect(shapes.paired, readFormat: "paired", label: "fullPaired")
        XCTAssertEqual(run.filesSeen, [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
        XCTAssertEqual(run.formatSeen, "paired")
    }

    func testProvenanceNamesTheBundleBehindAMaterializedFile() async throws {
        let run = try await detect(shapes.oriented, readFormat: "unpaired", label: "virtual")
        let bundle = shapes.oriented.standardizedFileURL
        let inputsDirectory = run.outputDirectory.appendingPathComponent(".lungfish-esviritu-inputs", isDirectory: true)
        let materialized = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: inputsDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fastq" }
        ).standardizedFileURL

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.outputDirectory))
        let parameters = try XCTUnwrap(envelope.legacyRun?.parameters)
        XCTAssertEqual(parameters["originalInputs"], .array([.file(bundle)]))
        XCTAssertEqual(
            parameters["inputMaterializationCommands"],
            .array([.string(
                ["lungfish-cli", "fastq", "materialize", bundle.path, "--output", materialized.path]
                    .map(shellEscape).joined(separator: " ")
            )])
        )
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "EsViritu" })
        let inputPaths = Set(step.inputs.map(\.path))
        XCTAssertTrue(inputPaths.contains(materialized.path), "inputs: \(inputPaths)")
        XCTAssertTrue(
            inputPaths.contains(bundle.appendingPathComponent("derived.manifest.json").path),
            "the bundle's manifest is recorded: \(inputPaths)"
        )
        XCTAssertTrue(
            inputPaths.contains(shapes.single.appendingPathComponent("single.fastq").standardizedFileURL.path),
            "the root FASTQ the virtual bundle points at is recorded: \(inputPaths)"
        )
        XCTAssertEqual(envelope.argv.first, "EsViritu", "the run is still named by its tool")
    }

    func testAPhysicalBundleRecordsTheBundleAndEachFileOnce() async throws {
        let run = try await detect(shapes.single, readFormat: "unpaired", label: "physical")
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.outputDirectory))
        let parameters = try XCTUnwrap(envelope.legacyRun?.parameters)
        XCTAssertEqual(parameters["originalInputs"], .array([.file(shapes.single.standardizedFileURL)]))
        XCTAssertEqual(parameters["inputMaterializationCommands"], .array([]), "a physical bundle is read in place")
        let step = try XCTUnwrap(envelope.steps.first { $0.toolName == "EsViritu" })
        let resolvedPaths = step.inputs.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        XCTAssertEqual(resolvedPaths.count, Set(resolvedPaths).count, "each file is recorded once: \(resolvedPaths)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: run.outputDirectory.appendingPathComponent(".lungfish-esviritu-inputs").path)
        )
    }

    func testAFASTQFileRunRecordsNoLineage() async throws {
        let fastq = root.appendingPathComponent("reads.fastq")
        try BundleShapeFixtures.fastq(["f1", "f2"]).write(to: fastq, atomically: true, encoding: .utf8)
        let run = try await detect(fastq, readFormat: "unpaired", label: "file")
        XCTAssertEqual(run.filesSeen, [["f1", "f2"]])
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: run.outputDirectory))
        let parameters = try XCTUnwrap(envelope.legacyRun?.parameters)
        XCTAssertNil(parameters["originalInputs"])
        XCTAssertNil(parameters["inputMaterializationCommands"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: run.outputDirectory.appendingPathComponent(".lungfish-esviritu-inputs").path)
        )
    }

    // MARK: - Helpers

    private struct DetectRun {
        let outputDirectory: URL
        /// The record names of each file EsViritu was handed, in argument order.
        let filesSeen: [[String]]
        let formatSeen: String
    }

    /// Runs `lungfish-cli esviritu detect --input <input>` through the
    /// command's own resolution with a stand-in EsViritu.
    private func detect(_ input: URL, readFormat: String, label: String) async throws -> DetectRun {
        let runRoot = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let esviritu = try StandInEsViritu(root: runRoot)
        let outputDirectory = runRoot.appendingPathComponent("esviritu/sample", isDirectory: true)
        let parsed = try LungfishCLI.parseAsRoot([
            "esviritu", "detect",
            "--input", input.path,
            "--sample", "sample",
            "--read-format", readFormat,
            "--db", esviritu.databaseURL.path,
            "--output", outputDirectory.path,
            "--threads", "2",
            "--quiet",
        ])
        let command = try XCTUnwrap(parsed as? EsVirituCommand.DetectSubcommand, label)
        try await command.execute(
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
        return DetectRun(
            outputDirectory: outputDirectory,
            filesSeen: try esviritu.inputsSeen().map(BundleShapeFixtures.readNames(in:)),
            formatSeen: esviritu.formatSeen
        )
    }
}

/// A conda root whose stand-in micromamba runs a stand-in EsViritu: it keeps a
/// copy of every read file passed after `-r`, notes the `-p` read format, and
/// writes an empty detection table in the `-o` folder.
struct StandInEsViritu {
    let condaManager: CondaManager
    let databaseURL: URL
    private let seenDirectory: URL

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("esviritu-db", isDirectory: true)
        try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        seenDirectory = root.appendingPathComponent("esviritu-saw", isDirectory: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script(seenDirectory: seenDirectory).write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    /// The copies of the read files EsViritu was handed, in argument order.
    func inputsSeen() throws -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: seenDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("input-") }
            .sorted { (Int($0.dropFirst("input-".count)) ?? 0) < (Int($1.dropFirst("input-".count)) ?? 0) }
            .map { seenDirectory.appendingPathComponent($0) }
    }

    var formatSeen: String {
        (try? String(contentsOf: seenDirectory.appendingPathComponent("format"), encoding: .utf8)) ?? ""
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
        if [ "$tool" != "EsViritu" ]; then
          echo "unexpected tool: $tool" >&2
          exit 64
        fi
        if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then
          echo "EsViritu 1.3.3"
          exit 0
        fi
        seen='\(seenDirectory.path)'
        mkdir -p "$seen"
        sample=""
        output=""
        reads=0
        index=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -r)
              reads=1
              ;;
            -s)
              shift
              sample="$1"
              reads=0
              ;;
            -o)
              shift
              output="$1"
              reads=0
              ;;
            -p)
              shift
              printf '%s' "$1" > "$seen/format"
              reads=0
              ;;
            -t|-q|--db|--keep)
              shift
              reads=0
              ;;
            -*)
              reads=0
              ;;
            *)
              if [ "$reads" = 1 ]; then
                index=$((index + 1))
                cp "$1" "$seen/input-$index"
              fi
              ;;
          esac
          shift
        done
        mkdir -p "$output"
        printf 'sample_ID\\tName\\tdescription\\tLength\\tSegment\\tAccession\\tAssembly\\tAsm_length\\tkingdom\\tphylum\\ttclass\\torder\\tfamily\\tgenus\\tspecies\\tsubspecies\\tRPKMF\\tread_count\\tcovered_bases\\tmean_coverage\\tavg_read_identity\\tPi\\tfiltered_reads_in_sample\\n' > "$output/$sample.detected_virus.info.tsv"
        echo "EsViritu stand-in finished" >&2
        exit 0
        """
    }
}
