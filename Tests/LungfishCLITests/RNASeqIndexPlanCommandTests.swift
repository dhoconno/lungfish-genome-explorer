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
import LungfishCore
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

    /// A gzip member of `plain` in one stored block, which a gzip reader unpacks and which needs no tool to write.
    static func gzipped(_ plain: Data) -> Data {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in plain {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        func little(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) } }
        let length = UInt16(plain.count)
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF, 0x01])
        out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
        out.append(plain)
        out.append(contentsOf: little(~crc) + little(UInt32(plain.count)))
        return out
    }

    /// A small set of schema 2 built by the owner under `root/store`, and that storage root. `gzipGenome` gives the owner
    /// `genome.fa.gz`, which the set keeps as it came.
    static func builtSet(in root: URL, gzipGenome: Bool = false) async throws -> (storage: URL, set: URL) {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let fasta = inputs.appendingPathComponent(gzipGenome ? "genome.fa.gz" : "genome.fa"), gtf = inputs.appendingPathComponent("genes.gtf")
        try (gzipGenome ? gzipped(Data(genome.utf8)) : Data(genome.utf8)).write(to: fasta)
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
        // `enumerator(atPath:)` gives each path relative to `folder`. The URL enumerator yields `/private/var/...` for a folder
        // that `resolvingSymlinksInPath()` named `/var/...`, so a cut at `folder.path.count` left the folder's own name in the key.
        for case let relative as String in try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path)) {
            let url = folder.appendingPathComponent(relative)
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            files[relative] = url.lastPathComponent.hasSuffix(".tar") ? "tar" : digest
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

    // MARK: - index-adopt to success

    /// The key folder of the run record below. The adopt reads `--genomeSAindexNbases 2`, which is what `index-plan` gives the
    /// 60-base genome of `builtSet`, and `--genomeSAsparseD 2` from the STAR step.
    private static let indexKeyFolder = "star-2.7.11b-sa2-sparse2"

    /// The record file where the format page puts it, built by hand from its pieces so that the test pins the place and not the
    /// store's own function. The pieces are the storage root, `rnaseq-index-records`, the set id, the key folder and the file name.
    private static func indexRecordFile(in storage: URL, setID: String) -> URL {
        storage.appendingPathComponent("rnaseq-index-records", isDirectory: true).appendingPathComponent(setID, isDirectory: true)
            .appendingPathComponent(indexKeyFolder, isDirectory: true).appendingPathComponent("index-record.json")
    }

    /// The `executor` of M-INDEX's run record, the cross-build of `dev-e65d22fcaeec`: the running binary's SHA-256 and size, and
    /// the plan's build pin, as the executor states them (`SCR/rulings/ARCH-5-1-C-3.md`, Item 2 and What binds 9).
    private static func executorObject(lgeVersion: String = "dev-e65d22fcaeec") -> [String: Any] {
        ["sha256": String(repeating: "25d9f5eb", count: 8), "size": 59_025_792,
         "buildPin": ["lgeVersion": lgeVersion, "lgeCommit": "e65d22fcaeec873520e8d7cab4a02ca419a6807f",
                      "targetTriple": "x86_64-swift-linux-musl", "toolchainID": "swift-6.4.0-RELEASE",
                      "toolchainSHA256": String(repeating: "8fd03185", count: 8),
                      "staticLinuxSDKID": "swift-6.4.0-RELEASE_static-linux-0.1.0",
                      "staticLinuxSDKSHA256": String(repeating: "47d2fd89", count: 8)]]
    }

    /// Writes the `run-record.json` of an index run that succeeded into `result`, in the shape the executor writes it and the
    /// adopt reads it. It names the set's counting GTF by its SHA-256, holds one STAR step with its argv, and gives each of the
    /// 15 index files as a staged output and the log as a home output. `edited` gives that one staged output another digest.
    /// It states the executor as the executor does (`docs/formats/executor-run-record.md`, the `executor` key), with `lgeVersion`
    /// for the build pin, and leaves out the executor's key `missing` names, or the whole object for `executor`.
    /// The staged outputs come back by plan path with their bytes and SHA-256.
    @discardableResult
    private func writeIndexRunRecord(
        for set: URL, in result: URL, editing edited: String? = nil, made: (path: String, sha256: String)? = nil,
        lgeVersion: String = "dev-e65d22fcaeec", leaving missing: String? = nil, sparse: Int = 2
    ) throws -> [String: (bytes: UInt64, sha256: String)] {
        let manifest = try ReferenceSetManifest.load(from: set)
        let gtf = try manifest.requireCountingGTF()
        var staged: [String: (bytes: UInt64, sha256: String)] = [:]
        for (index, name) in STARIndexPlan.indexFiles.enumerated() {
            let path = "star-index/\(name)"
            staged[path] = (UInt64(1_000 + index), path == edited ? String(repeating: "e", count: 64) : String(format: "%064llx", index + 1))
        }
        var outputs: [[String: Any]] = staged.sorted { $0.key < $1.key }.map {
            ["path": $0.key, "bytes": $0.value.bytes, "sha256": $0.value.sha256, "policy": "staged"]
        }
        outputs.append(["path": "star-index/Log.out", "bytes": 5_000, "sha256": String(repeating: "f", count: 64), "policy": "home"])
        // The recorded argv names --sjdbOverhang 100, STAR's default, as the plan's STAR step does (FIX-IDX-1).
        let argv = ["--runMode", "genomeGenerate", "--genomeDir", "star-index", "--runThreadN", "8", "--sjdbOverhang", "100",
                    "--genomeSAindexNbases", "2", "--genomeSAsparseD", "\(sparse)"]
        let step: [String: Any] = [
            "id": "star-index", "outcome": "succeeded", "argv": argv, "outputs": outputs,
            "tool": ["id": "STAR", "version": "2.7.11b", "build": "h5814d7d_9", "path": "/opt/conda/envs/2.7.11b/bin/STAR"]]
        let read = made ?? (gtf.path, gtf.sha256)
        let input: [String: Any] = [
            "role": "reference", "relativePath": "references/\(manifest.id)/\(read.path)", "size": 10, "sha256": read.sha256,
            "reference": ["setID": manifest.id, "path": read.path]]
        var record: [String: Any] = [
            "schemaVersion": ExecutorRunRecord.currentSchemaVersion, "outcome": "succeeded", "inputs": [input], "steps": [step]]
        var executor = Self.executorObject(lgeVersion: lgeVersion)
        if let missing { executor[missing] = nil }
        if missing != "executor" { record["executor"] = executor }
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: result.appendingPathComponent(ExecutorRunRecord.fileName))
        return staged
    }

    /// The route a person takes once the job came home. `--set` names the set by its id, so the leaf finds the set folder under
    /// `--storage-root`, and the record lands under that same root. The record holds the run record's digests and the staging
    /// path of each file, and the summary of the leaf names the record file.
    func testAdoptWritesTheRecordOfASucceededRunUnderTheStorageRoot() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let id = try ReferenceSetManifest.load(from: set).id
        let result = root.appendingPathComponent("result", isDirectory: true)
        let staged = try writeIndexRunRecord(for: set, in: result)
        let arguments = [result.path, "--set", id, "--storage-root", storage.path, "--staging-folder", Self.staging,
                         "--batch", "idx", "--format", "json"]
        try await RNASeqIndexAdoptSubcommand.parse(arguments).run()
        let url = Self.indexRecordFile(in: storage, setID: id)
        // A second adopt of the same run finds the equal record and changes nothing, so its summary is the first one's.
        let summary = try RNASeqIndexAdoptSubcommand.parse(arguments).adopt()
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.json.utf8)) as? [String: Any])
        XCTAssertEqual(facts["record"] as? String, url.path)
        XCTAssertEqual(facts["setID"] as? String, id)
        XCTAssertEqual(facts["key"] as? String, Self.indexKeyFolder)
        XCTAssertEqual((facts["files"] as? NSNumber)?.intValue, 15)
        XCTAssertEqual((facts["bytes"] as? NSNumber)?.uint64Value, staged.values.reduce(UInt64(0)) { $0 + $1.bytes })
        XCTAssertTrue(summary.lines.contains(url.path), "the text output names the record file: \(summary.lines)")
        XCTAssertTrue(summary.lines.first?.contains(Self.indexKeyFolder) == true, "\(summary.lines)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the record is under --storage-root at \(url.path)")
        let record = try JSONDecoder().decode(STARIndexRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(record.setID, id)
        XCTAssertEqual(record.key.folderName, Self.indexKeyFolder)
        XCTAssertEqual(record.tool, PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9"))
        XCTAssertEqual(record.files.count, 15)
        XCTAssertEqual(Set(record.files.map(\.planPath)), Set(staged.keys))
        for file in record.files {
            XCTAssertEqual(file.stagingPath, "\(Self.staging)/batches/idx/index/staged/\(file.planPath)", file.planPath)
            XCTAssertEqual(file.sha256, staged[file.planPath]?.sha256, file.planPath)
            XCTAssertEqual(file.bytes, staged[file.planPath]?.bytes, file.planPath)
        }
    }

    /// The family's replay case for the leaf. The same run adopted twice leaves the record file as the first adopt wrote it, and
    /// a run record that names another digest for the same set and key is refused with the input code and changes nothing.
    func testAdoptWritesTheRecordOnceAndAReplayChangesNothing() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let id = try ReferenceSetManifest.load(from: set).id
        let result = root.appendingPathComponent("result", isDirectory: true)
        try writeIndexRunRecord(for: set, in: result)
        let arguments = [result.path, "--set", id, "--storage-root", storage.path, "--staging-folder", Self.staging,
                         "--batch", "idx", "--quiet"]
        let url = Self.indexRecordFile(in: storage, setID: id)
        try await RNASeqIndexAdoptSubcommand.parse(arguments).run()
        let first = try Data(contentsOf: url)
        try await RNASeqIndexAdoptSubcommand.parse(arguments).run()
        XCTAssertEqual(try Data(contentsOf: url), first, "the same run adopted again changes nothing")
        try writeIndexRunRecord(for: set, in: result, editing: "star-index/SA")
        do {
            try await RNASeqIndexAdoptSubcommand.parse(arguments).run()
            XCTFail("a run that names another digest for the same index replaced the record")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertEqual(try Data(contentsOf: url), first, "and the record of the first run stays as it was")
    }

    // MARK: - The run that built the index (INDEX-PIN, SCR/rulings/ARCH-5-1-C-3.md What binds 9)

    /// The bytes of `url`, or nil, so that a file that is not there fails the assertion and not the test.
    private func bytes(of url: URL) -> Data? { try? Data(contentsOf: url) }

    /// The adopt's arguments for the run record in `result`, and the record's file and the copy beside it.
    private func adoptParts(_ storage: URL, _ set: URL, _ result: URL) throws
        -> (arguments: [String], record: URL, copy: URL) {
        let id = try ReferenceSetManifest.load(from: set).id
        let record = Self.indexRecordFile(in: storage, setID: id)
        return ([result.path, "--set", id, "--storage-root", storage.path, "--staging-folder", Self.staging, "--batch", "idx", "--quiet"],
                record, record.deletingLastPathComponent().appendingPathComponent(ExecutorRunRecord.fileName))
    }

    /// The record names the run that built the index (the run record's SHA-256 and bytes, the executor as the run record
    /// states it, and the adopt's batch and sample), and the run record sits beside it byte for byte. The leaf's lines and
    /// facts name the copy, the run record's SHA-256 and the executor build.
    func testAdoptNamesTheRunAndTheExecutorBuildAndKeepsTheRunRecordBesideTheRecord() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let result = root.appendingPathComponent("result", isDirectory: true)
        try writeIndexRunRecord(for: set, in: result)
        let runBytes = try Data(contentsOf: result.appendingPathComponent(ExecutorRunRecord.fileName))
        let digest = PortableDigest.sha256Hex(of: runBytes)
        let parts = try adoptParts(storage, set, result)
        let summary = try RNASeqIndexAdoptSubcommand.parse(parts.arguments).adopt()
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: parts.record)) as? [String: Any])
        XCTAssertEqual(written["schemaVersion"] as? Int, 2, "a new adopt writes schema 2")
        let run = try XCTUnwrap(written["run"] as? [String: Any], "the record names the run that built the index")
        XCTAssertEqual(run["runRecordSHA256"] as? String, digest)
        XCTAssertEqual((run["runRecordBytes"] as? NSNumber)?.intValue, runBytes.count)
        XCTAssertEqual(run["batch"] as? String, "idx")
        XCTAssertEqual(run["sample"] as? String, STARIndexPlan.sampleName)
        let executor = try XCTUnwrap(run["executor"] as? [String: Any], "the executor as the run record states it")
        XCTAssertEqual(NSDictionary(dictionary: executor), NSDictionary(dictionary: Self.executorObject()), "key for key")
        XCTAssertEqual(bytes(of: parts.copy), runBytes, "the copy beside the record equals the run record by bytes")
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.json.utf8)) as? [String: Any])
        XCTAssertEqual(facts["runRecordSHA256"] as? String, digest)
        XCTAssertEqual(facts["executorBuild"] as? String, "dev-e65d22fcaeec")
        XCTAssertEqual(facts["runRecordCopy"] as? String, parts.copy.path)
        XCTAssertTrue(summary.lines.contains { $0.contains(parts.copy.path) && $0.contains(digest) && $0.contains("dev-e65d22fcaeec") },
                      "a line names the copy, the SHA-256 and the executor build: \(summary.lines)")
    }

    /// The same adopt again changes nothing. A copy that is missing is written again, and so is a damaged one that sits beside
    /// an equal record, from the bytes the adopt read, since they match the record's digest.
    func testAMissingOrDamagedCopyIsWrittenAgainAndTheSameAdoptChangesNothingElse() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let result = root.appendingPathComponent("result", isDirectory: true)
        try writeIndexRunRecord(for: set, in: result)
        let runBytes = try Data(contentsOf: result.appendingPathComponent(ExecutorRunRecord.fileName))
        let parts = try adoptParts(storage, set, result)
        try await RNASeqIndexAdoptSubcommand.parse(parts.arguments).run()
        let first = try Data(contentsOf: parts.record)
        XCTAssertEqual(bytes(of: parts.copy), runBytes, "the first adopt keeps the copy")
        try await RNASeqIndexAdoptSubcommand.parse(parts.arguments).run()
        XCTAssertEqual(bytes(of: parts.record), first, "the same adopt again leaves the record as it was")
        XCTAssertEqual(bytes(of: parts.copy), runBytes, "and the copy")
        try? FileManager.default.removeItem(at: parts.copy)
        try await RNASeqIndexAdoptSubcommand.parse(parts.arguments).run()
        XCTAssertEqual(bytes(of: parts.copy), runBytes, "a missing copy is written again")
        XCTAssertEqual(bytes(of: parts.record), first, "and the record is as it was")
        try Data("damaged".utf8).write(to: parts.copy)
        try await RNASeqIndexAdoptSubcommand.parse(parts.arguments).run()
        XCTAssertEqual(bytes(of: parts.copy), runBytes, "a damaged copy beside an equal record is written again")
        XCTAssertEqual(bytes(of: parts.record), first, "and the record is as it was")
    }

    /// A run record of the same index by digest with another executor build is another run, so it is refused in words that name
    /// the record's file and the other build, and the record and the copy of the run kept stay as they were.
    func testAnotherRunOfTheSameIndexBuiltByAnotherExecutorBuildIsRefusedAndBothFilesStay() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let result = root.appendingPathComponent("result", isDirectory: true)
        try writeIndexRunRecord(for: set, in: result)
        let parts = try adoptParts(storage, set, result)
        try await RNASeqIndexAdoptSubcommand.parse(parts.arguments).run()
        let (record, copy) = (bytes(of: parts.record), bytes(of: parts.copy))
        XCTAssertNotNil(copy, "the first adopt keeps the copy")
        try writeIndexRunRecord(for: set, in: result, lgeVersion: "dev-0123456789ab")
        XCTAssertThrowsError(try RNASeqIndexAdoptSubcommand.parse(parts.arguments).adopt()) { error in
            let words = (error as? STARIndexError)?.message ?? "\(error)"
            for part in [parts.record.path, "executor build dev-e65d22fcaeec", "dev-0123456789ab", "remove that file"] {
                XCTAssertTrue(words.contains(part), "\(part) is missing from: \(words)")
            }
        }
        XCTAssertEqual(bytes(of: parts.record), record, "a refusal leaves the record as it was")
        XCTAssertEqual(bytes(of: parts.copy), copy, "and the copy of the run it names")
    }

    /// A record adopted before LGE kept the run (schema 1) beside the same index is refused in words of its own, and the
    /// adopt writes no copy beside it, since a copy beside a record that names no run would name a run the record does not.
    func testASchemaOneRecordOfTheSameIndexIsRefusedInWordsThatSayWhyAndNoCopyIsWritten() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let result = root.appendingPathComponent("result", isDirectory: true)
        try writeIndexRunRecord(for: set, in: result)
        let parts = try adoptParts(storage, set, result)
        try await RNASeqIndexAdoptSubcommand.parse(parts.arguments).run()
        // The record as the adopt wrote it before this change: schema 1, no `run`, and no copy.
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: parts.record)) as? [String: Any])
        old["run"] = nil
        old["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: old, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: parts.record)
        try? FileManager.default.removeItem(at: parts.copy)
        let schemaOne = bytes(of: parts.record)
        XCTAssertThrowsError(try RNASeqIndexAdoptSubcommand.parse(parts.arguments).adopt()) { error in
            let words = (error as? STARIndexError)?.message ?? "\(error)"
            for part in [parts.record.path, "before LGE kept the run", "was not replaced", "--storage-root", "remove that file"] {
                XCTAssertTrue(words.contains(part), "\(part) is missing from: \(words)")
            }
            XCTAssertFalse(words.contains("other digests") || words.contains("same digests"), words)
        }
        XCTAssertEqual(bytes(of: parts.record), schemaOne, "the schema 1 record stays as it was")
        XCTAssertNil(bytes(of: parts.copy), "no run-record.json is written beside it")
    }

    /// A run record whose executor lacks the build pin, the SHA-256 or the size is refused in words that name what it lacks, and
    /// nothing is written, since a record that cannot name the executor build would be the record this change was made to end.
    func testARunRecordWithoutTheExecutorsBuildPinSHA256OrSizeIsRefusedInWordsAndWritesNothing() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let result = root.appendingPathComponent("result", isDirectory: true)
        let parts = try adoptParts(storage, set, result)
        for key in ["buildPin", "sha256", "size", "executor"] {
            try writeIndexRunRecord(for: set, in: result, leaving: key)
            XCTAssertThrowsError(try RNASeqIndexAdoptSubcommand.parse(parts.arguments).adopt(), key) { error in
                let words = (error as? STARIndexError)?.message ?? "\(error)"
                let named = key == "executor" ? ["buildPin", "sha256", "size"] : [key]
                for part in ["executor"] + named {
                    XCTAssertTrue(words.contains(part), "\(part) is missing from: \(words)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent(STARIndexRecordStore.folderName).path), key)
        }
    }

    // MARK: - The 10x variant (SOLO-PLAN, ARCH-SOLO-GTF items 2 to 4)

    /// The plan writes the made GTF into its own folder only, `staging-files.json` names it from there, and the adopt with
    /// the same list makes it again from the set, records `gtfFilter` and refuses a run that read another GTF.
    func testTheTenxVariantWritesItsGTFIntoThePlanFolderOnlyAndTheAdoptChecksIt() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let id = try ReferenceSetManifest.load(from: set).id
        let files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("tenx/idx")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let setFiles = try tree(set)
        let base = Self.planArguments(set: set, storage: storage, output: out, files: files)
        let unknown = try RNASeqIndexPlanSubcommand.parse(base + ["--tenx-filter", "GRCh38"])
        XCTAssertThrowsError(try unknown.writePlan()) {
            XCTAssertEqual(($0 as? STARIndexError)?.message, "--tenx-filter is mkgtf-3.0.0 or gencode-2020-A, not GRCh38.")
        }
        let command = try RNASeqIndexPlanSubcommand.parse(base + ["--tenx-filter", "mkgtf-3.0.0"])
        let argv = command.canonicalArgv()
        XCTAssertEqual(try RNASeqIndexPlanSubcommand.parse(Array(argv.dropFirst(3))).canonicalArgv(), argv)
        XCTAssertTrue(argv.joined(separator: " ").contains("--tenx-filter mkgtf-3.0.0"), "\(argv)")
        try await command.run()
        let made = out.appendingPathComponent("made/tenx1-mkgtf-3.0.0/genes.gtf")
        let madeBytes = try Data(contentsOf: made)
        XCTAssertEqual(madeBytes, try Data(contentsOf: set.appendingPathComponent("derived/genes.gtf")), "G1 is protein_coding")
        XCTAssertEqual(try tree(set), setFiles, "the set is not touched")
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: out.appendingPathComponent("staging-files.json"))) as? [String: Any])
        let entries = try XCTUnwrap(listed["files"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { $0["source"] as? String == made.path }, "\(entries)")
        XCTAssertEqual(entry["sha256"] as? String, PortableDigest.sha256Hex(of: madeBytes))
        // A shared entry is kept once in the staging folder by its SHA-256, so the made file sits there as any reference does.
        XCTAssertEqual(entry["stagingPath"] as? String, "\(Self.staging)/shared/\(PortableDigest.sha256Hex(of: madeBytes))-genes.gtf")
        XCTAssertEqual(entry["role"] as? String, "reference")
        XCTAssertFalse(entries.contains { ($0["source"] as? String)?.hasSuffix("derived/genes.gtf") == true }, "STAR reads the made file only")

        let result = root.appendingPathComponent("result", isDirectory: true)
        let path = "made/tenx1-mkgtf-3.0.0/genes.gtf"
        try writeIndexRunRecord(for: set, in: result, made: (path, PortableDigest.sha256Hex(of: madeBytes)))
        let adopt = [result.path, "--set", id, "--storage-root", storage.path, "--staging-folder", Self.staging, "--batch", "idx",
                     "--tenx-filter", "mkgtf-3.0.0", "--format", "json"]
        let facts = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try RNASeqIndexAdoptSubcommand.parse(adopt).adopt().json.utf8)) as? [String: Any])
        XCTAssertEqual(facts["key"] as? String, Self.indexKeyFolder + "-tenx1-mkgtf-3.0.0")
        XCTAssertEqual(facts["tenxFilter"] as? String, "mkgtf-3.0.0")
        let recordFile = URL(fileURLWithPath: try XCTUnwrap(facts["record"] as? String))
        let record = try JSONDecoder().decode(STARIndexRecord.self, from: Data(contentsOf: recordFile))
        XCTAssertEqual(record.key.gtfFilter?.sha256, PortableDigest.sha256Hex(of: madeBytes))
        XCTAssertEqual(record.key.gtfFilter?.genesLeftOut, 0)
        try writeIndexRunRecord(for: set, in: result, made: (path, String(repeating: "d", count: 64)))
        XCTAssertThrowsError(try RNASeqIndexAdoptSubcommand.parse(adopt).adopt()) {
            XCTAssertTrue(($0 as? STARIndexError)?.message.contains("with SHA-256 \(String(repeating: "d", count: 64))") == true, "\($0)")
        }
    }

    // MARK: - The suffix array sparsity (SOLO-PLAN-M1-BIO R3)

    /// `--genomeSAsparseD 3` reaches STAR's argv in the written plan, the key, the JSON facts and the last line, the
    /// recorded argv parses to equal options, and the adopt of that run records the plan's `-sparse3` key, since it reads
    /// the value from the run's argv. Leaving the option out writes the plan of `--genomeSAsparseD 2` byte for byte.
    func testTheSparsityOptionReachesThePlanTheKeyAndTheLastLineAndTheAdoptRecordsThatKey() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let id = try ReferenceSetManifest.load(from: set).id
        let files = try Self.writeImageFiles(in: root)
        func arguments(_ name: String, _ extra: [String]) -> [String] {
            Self.planArguments(set: set, storage: storage, output: root.appendingPathComponent("sparse/\(name)/idx"), files: files) + extra
        }
        func written(_ name: String, _ extra: [String]) throws -> (lines: [String], facts: [String: Any], plan: Data) {
            let out = root.appendingPathComponent("sparse/\(name)/idx")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let summary = try RNASeqIndexPlanSubcommand.parse(arguments(name, extra)).writePlan()
            let walk = try XCTUnwrap(FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil))
            let tar = try XCTUnwrap(walk.compactMap { $0 as? URL }.first { $0.lastPathComponent == "plan.tar" }, "the sample's plan.tar")
            let plan = try XCTUnwrap(Self.tarMember(endingWith: "plan.json", in: try Data(contentsOf: tar)), "plan.json in plan.tar")
            let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.json.utf8)) as? [String: Any])
            return (summary.lines, facts, Data(plan))
        }
        let three = try written("three", ["--genomeSAsparseD", "3"])
        let key = Self.indexKeyFolder.replacingOccurrences(of: "-sparse2", with: "-sparse3")
        let step = try XCTUnwrap(try ExecutionPlan.decode(three.plan).steps.last)
        let at = try XCTUnwrap(step.arguments.firstIndex(of: "--genomeSAsparseD"))
        XCTAssertEqual(step.arguments[at + 1], "3")
        XCTAssertEqual(three.facts["key"] as? String, key)
        XCTAssertEqual(three.facts["genomeSAsparseD"] as? Int, 3)
        XCTAssertEqual(three.lines.last, "STAR builds the suffix array with --genomeSAsparseD 3, where LGE's default is 2. A larger "
            + "value needs less memory and maps more slowly, and the key \(key) holds it.")
        let (plain, two) = (try written("plain", []), try written("two", ["--genomeSAsparseD", "2"]))
        XCTAssertEqual(plain.plan, two.plan, "the default plan, byte for byte")
        XCTAssertEqual(plain.lines.last, "STAR builds the suffix array with --genomeSAsparseD 2, LGE's default.")
        let argv = try RNASeqIndexPlanSubcommand.parse(arguments("again", ["--genomeSAsparseD", "3"])).canonicalArgv()
        XCTAssertTrue(argv.joined(separator: " ").contains("--genomeSAsparseD 3"), "\(argv)")
        XCTAssertEqual(try RNASeqIndexPlanSubcommand.parse(Array(argv.dropFirst(3))).canonicalArgv(), argv)
        XCTAssertFalse(try RNASeqIndexPlanSubcommand.parse(arguments("again", [])).canonicalArgv().contains("--genomeSAsparseD"))
        let zero = try RNASeqIndexPlanSubcommand.parse(arguments("zero", ["--genomeSAsparseD", "0"]))
        XCTAssertThrowsError(try zero.writePlan()) {
            XCTAssertTrue(($0 as? STARIndexError)?.message.hasPrefix("--genomeSAsparseD is the distance") == true, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sparse/zero/idx").path))
        let result = root.appendingPathComponent("sparse-result", isDirectory: true)
        try writeIndexRunRecord(for: set, in: result, sparse: 3)
        let adopt = [result.path, "--set", id, "--storage-root", storage.path, "--staging-folder", Self.staging, "--batch", "idx",
                     "--format", "json"]
        let adopted = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try RNASeqIndexAdoptSubcommand.parse(adopt).adopt().json.utf8)) as? [String: Any])
        XCTAssertEqual(adopted["key"] as? String, key, "the record of the value the plan was written with")
    }

    /// BIO-SOLO-M4 item 10: LGE's request figures were measured at `--genomeSAsparseD 2`, so a value below 2 without
    /// `--request-memory-mib` is refused in words and writes nothing, whatever other figure is given. With the memory figure
    /// the plan is written.
    func testSparsityOneWithoutAMemoryRequestIsRefusedInWords() async throws {
        let (storage, set) = try await Self.builtSet(in: root)
        let files = try Self.writeImageFiles(in: root)
        let words = "--genomeSAsparseD 1 keeps every suffix and needs about twice the suffix-array memory of 2, and LGE's request "
            + "figures were measured at 2. Give --request-memory-mib. No plan was written."
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sparse-one"), withIntermediateDirectories: true)
        let out = root.appendingPathComponent("sparse-one/idx")
        for figures in [[], ["--request-cpus", "2", "--request-disk-gib", "20"]] {
            let command = try RNASeqIndexPlanSubcommand.parse(
                Self.planArguments(set: set, storage: storage, output: out, files: files, figures: figures) + ["--genomeSAsparseD", "1"])
            XCTAssertThrowsError(try command.writePlan()) { XCTAssertEqual(($0 as? STARIndexError)?.message, words, "\(figures)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "\(figures)")
        }
        let given = try RNASeqIndexPlanSubcommand.parse(
            Self.planArguments(set: set, storage: storage, output: out, files: files) + ["--genomeSAsparseD", "1"]).writePlan()
        XCTAssertTrue(given.lines.last?.hasPrefix("STAR builds the suffix array with --genomeSAsparseD 1, where") == true, "\(given.lines)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "with --request-memory-mib the plan is written")
    }

    // MARK: - A gzip genome and the records folder

    /// The bytes of the first member of an uncompressed tar whose name ends with `suffix`.
    private static func tarMember(endingWith suffix: String, in tar: Data) -> Data? {
        var offset = 0
        while offset + 512 <= tar.count {
            let header = tar[offset..<(offset + 512)]
            guard header.contains(where: { $0 != 0 }) else { return nil }
            let name = String(decoding: header.prefix(100).prefix(while: { $0 != 0 }), as: UTF8.self)
            let sizeField = tar[(offset + 124)..<(offset + 136)].prefix(while: { $0 != 0 && $0 != 0x20 })
            guard let size = Int(String(decoding: sizeField, as: UTF8.self), radix: 8) else { return nil }
            if name.hasSuffix(suffix), offset + 512 + size <= tar.count { return tar[(offset + 512)..<(offset + 512 + size)] }
            offset += 512 + (size + 511) / 512 * 512
        }
        return nil
    }

    /// A set whose genome is gzip keeps it as it came, so the plan unpacks it with pigz into `unpacked-genome.fa` and STAR reads
    /// that file, never the `.gz` (`STARIndexPlan.swift`, the unpack step). The plan is read back out of the written `plan.tar`.
    func testAGzipGenomeGetsAnUnpackStepAndStarReadsTheUnpackedFile() async throws {
        let (storage, set) = try await Self.builtSet(in: root, gzipGenome: true)
        let files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("out", isDirectory: true).appendingPathComponent("idx")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await RNASeqIndexPlanSubcommand.parse(Self.planArguments(set: set, storage: storage, output: out, files: files)).run()
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil))
        let tar = try XCTUnwrap(walk.compactMap { $0 as? URL }.first { $0.lastPathComponent == "plan.tar" }, "the sample's plan.tar")
        let member = try XCTUnwrap(Self.tarMember(endingWith: "plan.json", in: try Data(contentsOf: tar)), "plan.json in plan.tar")
        let plan = try ExecutionPlan.decode(member)
        let id = try XCTUnwrap(plan.pipeline?.referenceSet.id)
        XCTAssertEqual(plan.steps.map(\.id), ["unpack-genome", "star-index"], "the gzip genome is unpacked before STAR reads it")
        guard plan.steps.count == 2, case let (unpack, star) = (plan.steps[0], plan.steps[1]) else { return }
        XCTAssertEqual(unpack.tool, PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_1"))
        XCTAssertEqual(unpack.arguments, ["-d", "-c", "references/\(id)/genome/genome.fa.gz"])
        XCTAssertEqual(unpack.standardOutput, "unpacked-genome.fa")
        XCTAssertTrue(star.inputs.contains("unpacked-genome.fa"), "\(star.inputs)")
        XCTAssertTrue(star.arguments.contains("unpacked-genome.fa"), "\(star.arguments)")
        XCTAssertFalse(star.arguments.contains { $0.hasSuffix(".gz") }, "STAR never reads the .gz itself: \(star.arguments)")
        XCTAssertEqual(plan.tools.map(\.id), ["STAR", "pigz"], "the plan pins pigz since a step runs it")
    }

    /// No cleanup of LGE reaches `rnaseq-index-records/` (`docs/formats/reference-set.md`, Index records). The one cleanup that
    /// walks a storage root, `removeOldLocalCopies` after a change of root, takes the old root's `conda` and `databases` and
    /// leaves everything else, so the record stays where it was.
    func testTheCleanupAfterAChangeOfStorageRootLeavesTheIndexRecordsFolder() async throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let (oldRoot, newRoot) = (root.appendingPathComponent("old-root", isDirectory: true), root.appendingPathComponent("new-root", isDirectory: true))
        let configStore = ManagedStorageConfigStore(homeDirectory: home, environmentProvider: { [:] })
        try configStore.setActiveRoot(oldRoot)
        guard configStore.currentLocation().rootURL.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            return XCTFail("the fixture refuses a storage root outside its temporary folder")
        }
        let record = oldRoot.appendingPathComponent(STARIndexRecordStore.folderName, isDirectory: true)
            .appendingPathComponent("set-1/star-2.7.11b-sa2-sparse2", isDirectory: true).appendingPathComponent("index-record.json")
        let bytes = Data("{\"set\": \"set-1\"}\n".utf8)
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: record)
        for managed in ["conda", "databases"] {
            try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent(managed), withIntermediateDirectories: true)
        }
        let coordinator = ManagedStorageCoordinator(
            configStore: configStore, validator: { ManagedStorageLocation(rootURL: $0) },
            databaseMigrator: { _, _ in }, toolInstaller: { _ in }, verifier: { _ in })
        try await coordinator.changeLocation(to: newRoot)
        try await coordinator.removeOldLocalCopies()
        for managed in ["conda", "databases"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent(managed).path), "the cleanup took \(managed)")
        }
        XCTAssertEqual(try? Data(contentsOf: record), bytes, "and left the index record where it was")
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
        try await assertCancelLeavesNoFolder(everyCoreBusy: false)
    }

    /// The same cancel with every core busy, which the grace must still cover, as a debug CLI under load may pass it. The
    /// siblings have the case too (`RNASeqQuantCommandTests`, `ImportCommandsSIGTERMTests`). The burners start once the leaf
    /// holds at its checkpoint and before the SIGTERM, so the load covers the cancel and not the start of the process.
    func testSIGTERMWithEveryCoreBusyStillCancelsThePlanWithinTheGrace() async throws {
        try await assertCancelLeavesNoFolder(everyCoreBusy: true)
    }

    private func assertCancelLeavesNoFolder(everyCoreBusy: Bool) async throws {
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
        let burners = try everyCoreBusy ? CLISIGTERMHarness.launchBurners(count: ProcessInfo.processInfo.activeProcessorCount) : []
        defer { burners.forEach { $0.stop() } }
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertTrue(
            (stop.standardOutput + stop.standardError).contains(RNASeqIndexPlanSubcommand.cancelledMessage), stop.standardError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a cancel leaves no plan folder")
    }
}
