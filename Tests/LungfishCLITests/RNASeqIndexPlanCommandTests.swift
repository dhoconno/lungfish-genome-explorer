// RNASeqIndexPlanCommandTests.swift - `lungfish-cli rnaseq index-plan` and `index-adopt` (Phase 5.3 lane EX-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cases (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family). The recorded argv parses to equal options,
// a replay of the command gives a plan folder of equal files, and a refusal writes nothing. The cancel case with a real
// SIGTERM is `RNASeqIndexPlanSIGTERMTests` below.

import ArgumentParser
import CryptoKit
import Foundation
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqIndexPlanCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-index-plan-cli").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// A stand-in for gffread that writes the one transcript of the annotation below at its merged exon length.
    private struct StandInDeriver: ReferenceSetTranscriptDeriving {
        func toolVersion() async throws -> String { "0.12.9" }
        func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws {
            try Data(">T1\nACGTACGTACGTACGTACGT\n".utf8).write(to: output)
        }
    }

    static let genome = ">chr1 test chromosome\n" + String(repeating: "ACGTACGTAC", count: 6) + "\n"
    static let annotation = """
        chr1\tt\tgene\t1\t30\t.\t+\t.\tgene_id "G1"; gene_name "Alpha"; gene_biotype "protein_coding";
        chr1\tt\ttranscript\t1\t30\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        chr1\tt\texon\t1\t10\t.\t+\t.\tgene_id "G1"; transcript_id "T1";
        chr1\tt\texon\t21\t30\t.\t+\t.\tgene_id "G1"; transcript_id "T1";

        """

    /// A small set of schema 2 built by the owner under `root/store`, and that storage root.
    static func builtSet(in root: URL) async throws -> (storage: URL, set: URL) {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let fasta = inputs.appendingPathComponent("genome.fa"), gtf = inputs.appendingPathComponent("genes.gtf")
        try Data(genome.utf8).write(to: fasta)
        try Data(annotation.utf8).write(to: gtf)
        let storage = root.appendingPathComponent("store", isDirectory: true)
        let owner = ReferenceSetOwner(
            storageRoot: storage, deriver: StandInDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let request = ReferenceSetRequest(
            name: "Index plan test", species: "Test species", assemblyName: "Test_1.0", annotationSource: "Test",
            annotationRelease: "1", genome: fasta, annotation: gtf, layout: .lge, assemblyReport: nil)
        return (storage, try await owner.build(request).url)
    }

    /// The executor's `manifest.json`, the image's tool manifest with both STAR builds and pigz, and the `image.json` that
    /// pins it, as `ImportFastqPlanOptionsTests` writes them.
    static func writeImageFiles(in root: URL) throws -> (executor: URL, image: URL, tools: URL) {
        let folder = root.appendingPathComponent("executor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executor = Data("executor stand-in".utf8)
        try executor.write(to: folder.appendingPathComponent("lungfish-executor"))
        let digest = String(repeating: "b", count: 64)
        let manifest: [String: Any] = [
            "sha256": PortableDigest.sha256Hex(of: executor), "size": executor.count, "lgeVersion": "dev-0123456789ab",
            "lgeCommit": String(repeating: "1", count: 40), "targetTriple": "x86_64-swift-linux-musl", "toolchainID": "swift-6.2",
            "toolchainSHA256": digest, "staticLinuxSDKID": "swift-6.2-static-linux", "staticLinuxSDKSHA256": digest,
        ]
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        let tools = [("STAR", "2.7.11b", "h5814d7d_9", "star"), ("STAR", "2.7.3a", "h5ca1c30_1", "star"), ("pigz", "2.8", "h421ea60_1", "pigz")]
        let toolManifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/envs/\($0.1)/bin/\($0.0)", condaPackage: $0.3)
        }).encoded()
        let toolsURL = root.appendingPathComponent("image-manifest.json")
        try toolManifest.write(to: toolsURL)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: toolManifest), "size": toolManifest.count],
        ]
        let imageURL = root.appendingPathComponent("image.json")
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: imageURL)
        return (manifestURL, imageURL, toolsURL)
    }

    static let staging = "/staging/groups/g/1/lge"
    static let figures = ["--request-memory-mib", "4096", "--request-cpus", "2", "--request-disk-gib", "20"]

    static func planArguments(set: URL, storage: URL, output: URL, files: (executor: URL, image: URL, tools: URL), figures: [String] = figures) -> [String] {
        ["--set", set.path, "--storage-root", storage.path, "--star", "2.7.11b", "--output", output.path, "--staging-folder", staging,
         "--executor-manifest", files.executor.path, "--image", files.image.path, "--image-tool-manifest", files.tools.path, "--quiet"] + figures
    }

    /// Each file below `folder` by its path inside it, with its SHA-256.
    private func tree(_ folder: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            files[String(url.path.dropFirst(folder.path.count + 1))] = url.lastPathComponent.hasSuffix(".tar") ? "tar" : digest
        }
        return files
    }

    func testTheGroupRegistersBothLeaves() {
        let names = RNASeqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("index-plan") && names.contains("index-adopt"), "the group lists \(names)")
    }

    func testTheRecordedArgvParsesToEqualOptions() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true).appendingPathComponent("idx")
        let command = try RNASeqIndexPlanSubcommand.parse(Self.planArguments(set: set, storage: storage, output: out, files: files))
        let argv = command.canonicalArgv()
        XCTAssertEqual(Array(argv.prefix(3)), ["lungfish-cli", "rnaseq", "index-plan"])
        let reparsed = try RNASeqIndexPlanSubcommand.parse(Array(argv.dropFirst(3)))
        XCTAssertEqual(reparsed.canonicalArgv(), argv)
        XCTAssertTrue(argv.contains(out.path) && argv.contains(set.path), "the record names absolute paths: \(argv)")
    }

    func testAReplayOfTheCommandGivesAPlanFolderOfEqualFiles() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let files = try Self.writeImageFiles(in: root)
        let (first, second) = (root.appendingPathComponent("a/idx"), root.appendingPathComponent("b/idx"))
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await RNASeqIndexPlanSubcommand.parse(Self.planArguments(set: set, storage: storage, output: folder, files: files)).run()
        }
        let (a, b) = (try tree(first), try tree(second))
        XCTAssertEqual(a.keys.sorted(), b.keys.sorted())
        XCTAssertTrue(a.keys.contains { $0.hasSuffix("plan.tar") }, "the sample's plan.tar is in \(a.keys.sorted())")
        for (path, digest) in a { XCTAssertEqual(b[path], digest, path) }
    }

    func testARefusalExitsWithTheInputCodeAndWritesNothing() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("refused")
        let saved = RNASeqFixtures.root.appendingPathComponent(
            "refset-v1/macaca_fascicularis-Macaca_fascicularis_5.0-refseq101-lge-3c71d550d4fa.lungfishrefset", isDirectory: true)
        let cases: [(String, URL, [String])] = [
            ("a genome with no measured figures and none given", set, []),
            ("a set of schema 1", saved, Self.figures),
            ("a set that is not there", root.appendingPathComponent("nothing.lungfishrefset"), Self.figures),
        ]
        for (what, folder, figures) in cases {
            do {
                let arguments = Self.planArguments(set: folder, storage: storage, output: out, files: files, figures: figures)
                try await RNASeqIndexPlanSubcommand.parse(arguments).run()
                XCTFail("\(what) was planned")
            } catch let code as ExitCode {
                XCTAssertEqual(code, CLIExitCode.inputError.exitCode, what)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), what)
        }
    }

    func testAdoptRefusesAMissingRunRecordAndAFailedRunAndWritesNoRecord() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let result = root.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let arguments = [result.path, "--set", set.path, "--staging-folder", Self.staging, "--batch", "idx", "--storage-root", storage.path, "--quiet"]
        let failed = "{\"schemaVersion\": \(ExecutorRunRecord.currentSchemaVersion), \"outcome\": \"failed\", \"failedStepID\": \"star-index\", "
            + "\"reason\": \"out of memory\", \"inputs\": [], \"steps\": []}"
        for (what, record) in [("no run record", nil), ("a failed run", failed)] as [(String, String?)] {
            if let record { try Data(record.utf8).write(to: result.appendingPathComponent(ExecutorRunRecord.fileName)) }
            do {
                try await RNASeqIndexAdoptSubcommand.parse(arguments).run()
                XCTFail("\(what) was adopted")
            } catch let code as ExitCode {
                XCTAssertEqual(code, CLIExitCode.inputError.exitCode, what)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent(STARIndexRecordStore.folderName).path), what)
        }
    }
}

/// The family's cancel case, as `RNASeqPseudobulkSIGTERMTests` has it. The leaf holds on `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`
/// (a debug build only) once it made the plan, so the signal reaches it before it writes a file. It exits 125 and leaves
/// neither a plan folder nor a process.
final class RNASeqIndexPlanSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-index-plan-sigterm").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func testSIGTERMCancelsThePlanAndLeavesNoFolder() async throws {
        let (storage, set) = try await RNASeqIndexPlanCommandTests.builtSet(in: root)
        let files = try RNASeqIndexPlanCommandTests.writeImageFiles(in: root)
        let out = root.appendingPathComponent("idx")
        let hold = root.appendingPathComponent("held")
        let arguments = RNASeqIndexPlanCommandTests.planArguments(set: set, storage: storage, output: out, files: files)
            .filter { $0 != "--quiet" } + ["--format", "json"]
        let run = try CLISIGTERMHarness.launchCLI(
            ["rnaseq", "index-plan"] + arguments, environment: [ViewerExportLeaf.holdFileVariable: hold.path],
            workingDirectory: root, testClass: Self.self)
        defer { run.stop() }
        let held = await CLISIGTERMHarness.waitForFile(hold)
        XCTAssertTrue(held, "the leaf made the plan and reached the checkpoint")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "nothing is written while it holds")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(RNASeqIndexPlanSubcommand.cancelledMessage), stop.standardError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a cancel leaves no plan folder")
    }
}
