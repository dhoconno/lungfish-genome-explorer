// ExecutorPlanStagedIndexTests.swift - The pin of a STAR index an earlier run staged on Linux (Phase 5.3 lane EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// Milestone 1 of lane EX-PLAN-STAR. A later plan pins each file of a STAR index that an earlier run left in the staging
/// folder, from the record `rnaseq index-adopt` wrote (`docs/formats/executor-plan.md`, Reference entries), and the
/// batch reads each such file where it sits, as it reads a staged read.
final class ExecutorPlanStagedIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanStagedIndex")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// The set of the stand-in plans of ``ExecutorPlanBatchSchemaTwoTests`` and ``ExecutorPlanIndexShapeFixture``.
    static let setID = ExecutorPlanIndexShapeFixture.setID
    static let key = "star-2.7.11b-sa7-sparse2"
    static let staging = "/staging/groups/g/1/lge-chtc-test"
    /// Where the index batch `m-index` left its files, `<staging folder>/batches/<batch>/index/staged/<plan path>`.
    static let indexFolder = "\(staging)/batches/m-index/index/staged/star-index"
    static let star = PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9")
    static let texts = ["Genome": "genome stand-in\n", "SA": "suffix array stand-in\n", "chrName.txt": "MT\n"]
    static let names = texts.keys.sorted()

    /// A record as `rnaseq index-adopt` writes one, of three stand-in files left under `folder`.
    static func record(folder: String = indexFolder, tool: PlanToolPin = star) -> STARIndexRecord {
        let files = names.map { name in
            let data = Data((texts[name] ?? "").utf8)
            return STARIndexRecord.File(path: name, planPath: "star-index/\(name)", stagingPath: "\(folder)/\(name)",
                                        bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let key = STARIndexKey(
            folderName: key, setID: setID, referenceSetSHA256: String(repeating: "d", count: 64), star: tool,
            genomeSAindexNbases: 7, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: ["genome/ref.fa"],
            countingGTFSHA256: String(repeating: "c", count: 64))
        return STARIndexRecord(setID: setID, key: key, tool: tool, files: files)
    }

    static func indexPath(_ name: String) -> String { "references/\(setID)/indexes/\(key)/\(name)" }

    private let layout = ExecutorPlanStagingLayout(folder: staging, batch: "star-counts")

    private func refusal(_ body: () throws -> Void) -> String {
        do {
            try body()
            XCTFail("no refusal")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    /// Item 1. Each file of the adopted record is one `reference` entry at `references/<set>/indexes/<key>/<path>`, with
    /// `reference.path` its path inside the index, `index {key, tool}` the key's folder name and the record's tool, and the
    /// record's SHA-256 and bytes. Its staging path is a submit value beside the entries, never a plan byte.
    func testEachFileOfTheAdoptedRecordIsOneReferenceEntryWithItsStagingPath() throws {
        let store = STARIndexRecordStore(storageRoot: root)
        let record = Self.record()
        try store.write(record)
        let pinned = try ExecutorPlanStagedIndex.pin(setID: Self.setID, key: Self.key, store: store, star: Self.star, layout: layout)
        XCTAssertEqual(pinned.record, record)
        let identity = PlanReferenceIndex(key: Self.key, tool: Self.star)
        XCTAssertEqual(pinned.entries, record.files.map { file in
            PlanEntry(role: .reference, relativePath: Self.indexPath(file.path), sha256: file.sha256, size: Int64(file.bytes),
                      reference: PlanReferenceIdentity(setID: Self.setID, path: file.path, index: identity))
        })
        XCTAssertEqual(pinned.entries.map(\.relativePath), pinned.entries.map(\.relativePath).sorted())
        XCTAssertEqual(pinned.stagingPaths, Dictionary(uniqueKeysWithValues: Self.names.map {
            (Self.indexPath($0), "\(Self.indexFolder)/\($0)")
        }))
        // Another build of the index's STAR version maps on it.
        let other = PlanToolPin(id: "STAR", version: "2.7.11b", build: "h0_0")
        XCTAssertEqual(try ExecutorPlanStagedIndex.pin(record, star: other, layout: layout), pinned)
    }

    /// Item 1. A set and key with no record is refused in words that name `rnaseq index-plan` and `rnaseq index-adopt`.
    func testASetAndKeyWithNoRecordIsRefusedNamingIndexPlanAndIndexAdopt() {
        let store = STARIndexRecordStore(storageRoot: root)
        let words = refusal {
            _ = try ExecutorPlanStagedIndex.pin(setID: Self.setID, key: Self.key, store: store, star: Self.star, layout: layout)
        }
        for part in [Self.setID, Self.key, "lungfish-cli rnaseq index-plan --set \(Self.setID) --star 2.7.11b",
                     "lungfish-cli rnaseq index-adopt", "never builds one"] {
            XCTAssertTrue(words.contains(part), "\(part) in \(words)")
        }
    }

    /// Item 1. A mapping STAR whose version is not the version that built the index is refused, in words that name both.
    func testAMappingSTAROfAnotherVersionThanTheIndexIsRefused() {
        let mapping = PlanToolPin(id: "STAR", version: "2.7.3a", build: "h0_0")
        let words = refusal { _ = try ExecutorPlanStagedIndex.pin(Self.record(), star: mapping, layout: layout) }
        for part in ["STAR 2.7.3a", "STAR 2.7.11b", Self.key, "--star 2.7.3a"] {
            XCTAssertTrue(words.contains(part), "\(part) in \(words)")
        }
    }

    /// Item 1. A record whose staging paths are not below the batch's `--staging-folder`, or lie in the batch's own folder
    /// where its jobs write, is refused in words that name the file and the folder.
    func testARecordWhoseFilesAreNotBelowTheStagingFolderIsRefused() {
        let elsewhere = "/staging/groups/other/lge/batches/m-index/index/staged/star-index"
        let outside = refusal { _ = try ExecutorPlanStagedIndex.pin(Self.record(folder: elsewhere), star: Self.star, layout: layout) }
        for part in ["\(elsewhere)/Genome", "not inside the staging folder \(Self.staging)", "--staging-folder"] {
            XCTAssertTrue(outside.contains(part), "\(part) in \(outside)")
        }
        let same = ExecutorPlanStagingLayout(folder: Self.staging, batch: "m-index")
        let inside = refusal { _ = try ExecutorPlanStagedIndex.pin(Self.record(), star: Self.star, layout: same) }
        XCTAssertTrue(inside.contains("\(Self.staging)/batches/m-index, where this batch's jobs write"), inside)
    }

    /// Item 2. `run-local.sh` places each index file from the same path below its data folder,
    /// `batches/m-index/index/staged/<plan path>`, and the job's wrapper moves it to its plan path, where the executor
    /// reads it. The `docker` and the executor are stand-ins, as ``LinuxRunScriptTests`` runs them.
    func testRunLocalPlacesEachIndexFileFromItsPathBelowTheDataFolder() throws {
        typealias Fixture = ExecutorPlanIndexShapeFixture
        func source(_ name: String, _ text: String) throws -> Fixture.Source {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return try Fixture.Source(url)
        }
        let executor = try source("lungfish-executor", [
            "#!/bin/sh", "find references -type f | LC_ALL=C sort > run-record.json",
            "cat \(Self.indexPath("Genome")) >> run-record.json", "mkdir -p out", "echo picked > \(Fixture.homeOutput)",
        ].joined(separator: "\n") + "\n")
        let manifest = PlanImageManifestPin(sha256: String(repeating: "0", count: 64), size: 4096)
        var job = Fixture.job(
            executor: executor, reference: try source("ref.fa", Fixture.referenceText), list: try source("ids.txt", Fixture.listText),
            seqkit: PlanToolPin(id: "seqkit", version: "2.13.0", build: "b0"), pigz: PlanToolPin(id: "pigz", version: "2.8", build: "b0"),
            imageManifest: manifest)
        let pinned = try ExecutorPlanStagedIndex.pin(Self.record(), star: Self.star, layout: layout)
        job.emission.plan.entries += pinned.entries
        job.stagedReferencePaths = pinned.stagingPaths
        let sif = Data("stand-in SIF".utf8)
        let image = ExecutorPlanImageRecord(
            sif: ExecutorPlanImageFile(fileName: "lge-tools-test.sif", sha256: PortableDigest.sha256Hex(of: sif), size: Int64(sif.count)),
            imageManifest: manifest)
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let batch = try ExecutorPlanBatchWriter.write([job], image: image, layout: layout, into: folder)

        // The data folder a lab makes from staging-files.json, each file at its path below the staging folder. An index
        // file has no source on the Mac, so it comes from the run that left it.
        let data = root.appendingPathComponent("data", isDirectory: true)
        for file in batch.files {
            let target = data.appendingPathComponent(layout.pathBelowFolder(file.stagingPath))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let path = file.source {
                try FileManager.default.copyItem(atPath: path, toPath: target.path)
            } else {
                let text = file.role == "barcodeList" ? Fixture.listText : Self.texts[target.lastPathComponent] ?? "stand-in SIF"
                try Data(text.utf8).write(to: target)
            }
        }
        let bin = root.appendingPathComponent("stand-in-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let docker = bin.appendingPathComponent("docker")
        try ([
            "#!/bin/sh", "case $1 in", "  version) echo 28.3.2; exit 0 ;;", "  image) echo sha256:0123; exit 0 ;;",
            "  run) shift ;;", "  *) exit 64 ;;", "esac", "dir=\"\"", "while [ \"$#\" -gt 0 ]; do", "  case $1 in",
            "    --rm) shift ;;", "    --workdir) dir=$2; shift 2 ;;", "    --*) shift 2 ;;", "    *) break ;;", "  esac", "done",
            "shift", "cd \"$dir\" || exit 125", "exec \"$@\"",
        ].joined(separator: "\n") + "\n").write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)

        let run = try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [folder.appendingPathComponent(LinuxRunScript.fileName).path, "--runtime", "docker", "--image", "lge-test:1",
                        "--data", data.path],
            environment: ProcessInfo.processInfo.environment.merging(["PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 },
            timeout: .seconds(30), label: "run-local"
        )).waitBlocking()
        XCTAssertEqual(Int(run.status), 0, run.stderrText)
        let record = try String(contentsOf: folder.appendingPathComponent("index/result/run-record.json"), encoding: .utf8)
        XCTAssertEqual(record.split(separator: "\n").map(String.init),
                       [Fixture.referencePath] + Self.names.map(Self.indexPath) + ["genome stand-in"])
    }
}
