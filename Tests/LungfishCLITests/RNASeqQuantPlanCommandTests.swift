// RNASeqQuantPlanCommandTests.swift - `lungfish-cli rnaseq quant --write-plan` (Phase 5.3 lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The family's cases (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tests per family): the argv parses to equal options, a replay
// gives a plan folder of equal files, every refusal writes nothing, and a real SIGTERM leaves no folder. The plan's own bytes
// are `SalmonPlanTests`.

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqQuantPlanCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-quant-plan-cli").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let staging = "/staging/groups/g/1/lge"
    static let figures = ["--request-memory-mib", "4096", "--request-cpus", "2", "--request-disk-gib", "20"]

    /// The executor's `manifest.json`, the tool manifest of an image that holds salmon 2.11.0 and Trim Galore 2.3.0, and the
    /// `image.json` that pins it, as `RNASeqIndexPlanCommandTests.writeImageFiles` writes them for STAR.
    static func writeImageFiles(in root: URL) throws -> (executor: URL, image: URL, tools: URL) {
        let folder = root.appendingPathComponent("executor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executor = Data("executor stand-in".utf8), digest = String(repeating: "b", count: 64)
        try executor.write(to: folder.appendingPathComponent("lungfish-executor"))
        let manifest: [String: Any] = [
            "sha256": PortableDigest.sha256Hex(of: executor), "size": executor.count, "lgeVersion": "dev-0123456789ab",
            "lgeCommit": String(repeating: "1", count: 40), "targetTriple": "x86_64-swift-linux-musl", "toolchainID": "swift-6.2",
            "toolchainSHA256": digest, "staticLinuxSDKID": "swift-6.2-static-linux", "staticLinuxSDKSHA256": digest,
        ]
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        let tools = [("salmon", "2.11.0", "hfa8f182_0", "salmon"), ("trim_galore", "2.3.0", "hf1b6044_0", "trim-galore")]
        let toolManifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/envs/\($0.0)/bin/\($0.0)", condaPackage: $0.3)
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

    /// The small set under `root/store` and a stand-in for the index this Mac published for it, in the cache's layout
    /// (`SalmonPlanTests.publishIndex`). With `published` false the cache holds none.
    func setWithIndex(published: Bool = true) async throws -> (storage: URL, id: String) {
        let (storage, set) = try await RNASeqIndexPlanCommandTests.builtSet(in: root)
        let id = try ReferenceSetManifest.load(from: set).id
        if published { try publish(storage: storage, id: id) }
        return (storage, id)
    }

    func publish(storage: URL, id: String) throws {
        let key = SalmonIndexKey(setID: id, salmonVersion: "2.11.0", k: 31, decoys: .genome)
        let folder = SalmonIndexCache(storageRoot: storage, host: RunFitHostFacts(physicalMemoryBytes: 0)).folder(for: key)
        let index = folder.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        for (name, text) in [("info.json", "{\"k\": 31}\n"), ("refseq.bin", "refseq\n"), ("pos.bin", "pos\n")] {
            try Data(text.utf8).write(to: index.appendingPathComponent(name))
        }
        let file = SalmonIndexKeyFile(
            schemaVersion: 1, setID: id, salmonVersion: "2.11.0", k: 31, decoys: .genome,
            referenceSetSHA256: String(repeating: "c", count: 64), salmonBuild: "salmon-2.11.0-hfa8f182_0",
            argv: ["index"], indexSeqHash: "seq1", indexNameHash: "name1", indexDecoySeqHash: "dseq1", indexDecoyNameHash: "dname1")
        try JSONEncoder().encode(file).write(to: folder.appendingPathComponent(SalmonIndexKeyFile.filename))
    }

    /// A bundle of two read files named as R1 and R2, whose sidecar holds the import's metadata and no recipe.
    func pairBundle(_ name: String) throws -> URL {
        let bundle = root.appendingPathComponent("imports/\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for mate in [1, 2] {
            let text = (1...4).map { "@\(name)r\($0) \(mate):N:0:1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: bundle.appendingPathComponent("\(name)_R\(mate).fastq"))
        }
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .pairedEnd, pairingSource: .detected, recipeApplied: nil)),
            for: bundle.appendingPathComponent("\(name)_R1.fastq"))
        return bundle
    }

    /// The arguments of `rnaseq quant --write-plan` on `reads`, which are bundle paths or none for staged reads.
    func arguments(
        reads: [String], set: (storage: URL, id: String), out: URL, files: (executor: URL, image: URL, tools: URL),
        extra: [String] = figures
    ) -> [String] {
        reads + ["--set", set.id, "--storage-root", set.storage.path, "--write-plan", out.path, "--staging-folder", Self.staging,
                 "--executor-manifest", files.executor.path, "--image", files.image.path, "--image-tool-manifest", files.tools.path,
                 "--quiet"] + extra
    }

    /// Each file below `folder` by its path inside it, with its SHA-256, and a tar as `tar`.
    func tree(_ folder: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        for case let relative as String in try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path)) {
            let url = folder.appendingPathComponent(relative)
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[relative] = url.lastPathComponent.hasSuffix(".tar") ? "tar" : SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return files
    }

    func plan(in folder: URL, _ sample: String) throws -> ExecutionPlan {
        try ExecutionPlan.decode(Data(contentsOf: folder.appendingPathComponent("\(sample)/plan.json")))
    }

    // MARK: - The family's cases

    func testTheGivenArgvParsesToEqualOptionsAtTheRootAndAtTheLeaf() async throws {
        let set = try await setWithIndex(), files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("out/quant")
        let given = arguments(reads: [try pairBundle("sample1").path], set: set, out: out, files: files, extra: Self.figures + [
            "--trim", "--poly-g-trimming", "on", "--job-requirements", "Machine == \"a\"", "--dry-run"])
        func facts(_ command: RNASeqCommand.QuantSubcommand) -> [String?] {
            let o = command.planOptions
            return [command.setID, command.bundles.first, command.project, command.polyGTrimming, "\(command.trim)", o.writePlan,
                    o.stagingFolder, o.executorManifest, o.image, o.imageToolManifest, o.requestMemoryMiB.map(String.init),
                    o.requestCPUs.map(String.init), o.requestDiskGiB.map(String.init), o.jobRequirements, "\(o.dryRun)"]
        }
        let leaf = try RNASeqCommand.QuantSubcommand.parse(given)
        let atRoot = try XCTUnwrap(try LungfishCLI.parseAsRoot(["rnaseq", "quant"] + given) as? RNASeqCommand.QuantSubcommand)
        XCTAssertEqual(facts(atRoot), facts(leaf))
        XCTAssertEqual(leaf.planOptions.writePlan, out.path)
        XCTAssertEqual(leaf.planOptions.requestCPUs, 2)
        XCTAssertEqual(leaf.planOptions.requestMemoryMiB, 4096)
        XCTAssertEqual(leaf.polyGTrimming, "on")
        XCTAssertTrue(leaf.planOptions.dryRun && leaf.planOptions.isOn)
        XCTAssertNil(leaf.project, "a plan names no project")
    }

    func testAReplayOfTheCommandGivesAPlanFolderOfEqualFilesAndPlansThatDecode() async throws {
        let set = try await setWithIndex(), files = try Self.writeImageFiles(in: root)
        let bundle = try pairBundle("sample1")
        let (first, second) = (root.appendingPathComponent("a/quant"), root.appendingPathComponent("b/quant"))
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await RNASeqCommand.QuantSubcommand.parse(
                arguments(reads: [bundle.path], set: set, out: folder, files: files, extra: Self.figures + ["--trim"])).run()
        }
        let (a, b) = (try tree(first), try tree(second))
        XCTAssertEqual(a.keys.sorted(), b.keys.sorted())
        XCTAssertTrue(a.keys.contains("sample1/plan.tar"), "the sample's plan.tar is in \(a.keys.sorted())")
        for (path, digest) in a { XCTAssertEqual(b[path], digest, path) }
        let made = try plan(in: first, "sample1")
        XCTAssertEqual(made.steps.map { $0.tool?.id }, ["trim_galore", "salmon"])
        XCTAssertEqual(made.steps.first?.arguments.first, "--no_poly_g")
        let argv = try XCTUnwrap(made.steps.last?.arguments)
        XCTAssertEqual(argv.firstIndex(of: "-p").map { argv[$0 + 1] }, "2", "salmon's -p equals --request-cpus: \(argv)")
    }

    // MARK: - Staged reads

    static let stagedReads: [(path: String, size: Int64, sha256: String)] = [
        ("\(staging)/input/S1_1.fastq.gz", 5_000_000, String(repeating: "a", count: 64)),
        ("\(staging)/input/S1_2.fastq.gz", 5_100_000, String(repeating: "b", count: 64)),
        ("\(staging)/input/S2_1.fastq.gz", 6_000_000, String(repeating: "c", count: 64)),
        ("\(staging)/input/S2_2.fastq.gz", 6_100_000, String(repeating: "d", count: 64)),
    ]

    /// The list and the sheet of two samples whose reads are in the staging folder and nowhere on this Mac. S1 names its model.
    func writeStagedFiles(dropping dropped: Int? = nil) throws -> (list: URL, sheet: URL) {
        let (list, sheet) = (root.appendingPathComponent("staged.tsv"), root.appendingPathComponent("samples.csv"))
        let kept = Self.stagedReads.enumerated().filter { $0.offset != dropped }.map(\.element)
        let lines = ["file\tbytes\tsha256"] + kept.map { "\($0.path)\t\($0.size)\t\($0.sha256)" }
        try (lines.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)
        let reads = Self.stagedReads
        let rows = ["sample,r1,r2,model", "S1,\(reads[0].path),\(reads[1].path),NovaSeq 6000", "S2,\(reads[2].path),\(reads[3].path),"]
        try (rows.joined(separator: "\n") + "\n").write(to: sheet, atomically: true, encoding: .utf8)
        return (list, sheet)
    }

    func stagedArguments(set: (storage: URL, id: String), out: URL, files: (executor: URL, image: URL, tools: URL), dropping: Int? = nil) throws -> [String] {
        let staged = try writeStagedFiles(dropping: dropping)
        return arguments(reads: [], set: set, out: out, files: files,
                         extra: Self.figures + ["--staged-reads", staged.list.path, "--samplesheet", staged.sheet.path])
    }

    func testStagedReadsGiveOnePlanASampleThatPinsTheListAndOpensNoRead() async throws {
        let set = try await setWithIndex(), files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("out/quant")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await RNASeqCommand.QuantSubcommand.parse(try stagedArguments(set: set, out: out, files: files)).run()
        for (sample, reads) in [("S1", Array(Self.stagedReads[0...1])), ("S2", Array(Self.stagedReads[2...3]))] {
            let made = try plan(in: out, sample)
            let inputs = made.entries.filter { $0.role == .input }
            XCTAssertEqual(inputs.map(\.sha256), reads.map { $0.sha256 }, sample)
            XCTAssertEqual(inputs.map(\.size), reads.map { $0.size }, sample)
            XCTAssertEqual(made.sample.originalSizeBytes, reads.reduce(Int64(0)) { $0 + $1.size }, sample)
        }
        XCTAssertEqual(try plan(in: out, "S1").sample.instrument, PlanSampleInstrument(model: "NovaSeq 6000", inferred: false))
        XCTAssertNil(try plan(in: out, "S2").sample.instrument, "a sheet cell with no model gives no instrument")
        XCTAssertTrue(try tree(out).keys.filter { $0.contains(".fastq") }.isEmpty, "a staged read is never copied")
    }

    // MARK: - Refusals and the dry run

    /// Runs the leaf on `arguments`, which it refuses with the input code, and returns the words. No plan folder is made.
    func refusal(_ arguments: [String], out: URL) async throws -> String {
        let command = try RNASeqCommand.QuantSubcommand.parse(arguments)
        var words = ""
        do {
            _ = try await command.writePlanFolder()
            XCTFail("the plan was written")
        } catch {
            words = CLIFailureWords.describe(error)
        }
        do {
            try await command.run()
            XCTFail("the leaf did not refuse: \(words)")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode, words)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), words)
        return words
    }

    /// Red first (brief, item 3): with no published index the plan is refused in words that name `lungfish-cli rnaseq index`
    /// and never builds one, with the run and with `--dry-run`. The other refusals follow the order the writer takes them in.
    func testARefusalSaysWhatToDoExitsWithTheInputCodeAndWritesNothing() async throws {
        let set = try await setWithIndex(published: false), files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("refused"), bundle = try pairBundle("sample1").path
        let plain = arguments(reads: [bundle], set: set, out: out, files: files)
        for extra in [[], ["--dry-run"]] {
            let words = try await refusal(plain + extra, out: out)
            XCTAssertTrue(words.contains("lungfish-cli rnaseq index"), words)
        }
        try publish(storage: set.storage, id: set.id)
        let unmeasured = try await refusal(arguments(reads: [bundle], set: set, out: out, files: files, extra: []), out: out)
        XCTAssertTrue(unmeasured.contains("--request-memory-mib") && unmeasured.contains("--request-disk-gib"), unmeasured)
        let missingLine = try await refusal(try stagedArguments(set: set, out: out, files: files, dropping: 3), out: out)
        XCTAssertTrue(missingLine.contains("has no line for it"), missingLine)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            try await RNASeqCommand.QuantSubcommand.parse(plain).run()
            XCTFail("an existing folder was planned into")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "the existing folder is as it was")
    }

    /// The refusals that the arguments alone decide are made before any file is read, and each names the option.
    func testArgumentRefusalsNameTheOptionAndTheWayOut() async throws {
        let set = try await setWithIndex(), files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("never"), bundle = try pairBundle("sample1").path
        let plain = arguments(reads: [bundle], set: set, out: out, files: files)
        let cases: [(String, [String], String)] = [
            ("--threads with --write-plan", plain + ["--threads", "4"], "--threads does not apply"),
            ("--project with --write-plan", plain + ["--project", root.path], "leave out --project"),
            ("a plan option with no --write-plan", ["--project", root.path, bundle, "--set", set.id, "--dry-run"], "is an option of --write-plan"),
            ("bundles with --staged-reads", try stagedArguments(set: set, out: out, files: files) + [bundle], "no bundles"),
            ("no staging folder", ["--set", set.id, "--write-plan", out.path, bundle] + Self.figures, "--staging-folder"),
            ("no reads", ["--set", set.id, "--write-plan", out.path, "--staging-folder", Self.staging], "Name FASTQ bundles"),
        ]
        for (what, argv, words) in cases {
            XCTAssertThrowsError(try RNASeqCommand.QuantSubcommand.parse(argv), what) { error in
                let message = RNASeqCommand.QuantSubcommand.message(for: error)
                XCTAssertTrue(message.contains(words), "\(what): \(message)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testDryRunMakesTheSummaryAndWritesNothing() async throws {
        let set = try await setWithIndex(), files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("dry")
        let given = arguments(reads: [try pairBundle("sample1").path], set: set, out: out, files: files, extra: Self.figures + ["--dry-run"])
        let summary = try await RNASeqCommand.QuantSubcommand.parse(given).writePlanFolder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a dry run writes no folder")
        XCTAssertTrue(summary.lines.first?.contains("Planned 1 sample(s) of the set \(set.id)") == true, "\(summary.lines)")
    }

    // MARK: - Sheets of single-end reads (CHTC-QUANT-SINGLE-END milestone 2)

    /// The image of `writeImageFiles` with both STARs, pigz and featureCounts in its tool manifest, as the chain tests write it.
    private func writeSTARImageFiles() throws -> (executor: URL, image: URL, tools: URL) {
        let files = try Self.writeImageFiles(in: root)
        let tools = [("STAR", "2.7.11b", "h5814d7d_9"), ("STAR", "2.7.3a", "h5ca1c30_1"), ("pigz", "2.8", "h421ea60_1"),
                     ("salmon", "2.11.0", "hfa8f182_0"), ("trim_galore", "2.3.0", "hf1b6044_0"), ("featureCounts", "2.1.1", "h577a1d6_0")]
        let manifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/envs/\($0.0)-\($0.1)/bin/\($0.0)", condaPackage: $0.0.lowercased())
        }).encoded()
        try manifest.write(to: files.tools)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: manifest), "size": manifest.count],
        ]
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: files.image)
        return files
    }

    /// The small set, a stand-in record of the STAR `version` index that `rnaseq index-adopt` wrote for it, and the published salmon
    /// index, so every chain can plan what the sheet names and only the sheet is refused.
    private func setWithSTARIndex(star version: String) async throws -> (storage: URL, id: String) {
        let (storage, setFolder) = try await RNASeqIndexPlanCommandTests.builtSet(in: root)
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let star = PlanToolPin(id: "STAR", version: version, build: version == "2.7.3a" ? "h5ca1c30_1" : "h5814d7d_9")
        let key = STARIndexKey.folderName(star: version, nbases: 4, sparseD: 2)
        let files = ["Genome", "SA", "chrName.txt"].map { name -> STARIndexRecord.File in
            let data = Data("\(name) of \(key)\n".utf8)
            return STARIndexRecord.File(path: name, planPath: "star-index/\(name)",
                                        stagingPath: "\(Self.staging)/batches/m-index/index/staged/star-index/\(name)",
                                        bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let record = STARIndexRecord(setID: manifest.id, key: STARIndexKey(
            folderName: key, setID: manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: star,
            genomeSAindexNbases: 4, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: [manifest.genome.path],
            countingGTFSHA256: manifest.derived.countingGTF?.sha256 ?? ""), tool: star, files: files)
        _ = try STARIndexRecordStore(storageRoot: storage).write(record)
        try publish(storage: storage, id: manifest.id)
        return (storage, manifest.id)
    }

    /// Records what `import fastq` reports as failed, since the Mac import reads a sheet through the same reader.
    private final class FailureRecorder: FASTQImportReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [String] = []
        var failed: [String] { lock.withLock { failures } }
        func text(_ line: String) {}
        func pairingNotice(sample: String, message: String) {}
        func log(_ event: ImportLogEvent) {}
        func fail(_ message: String, detail: String?, exitCode: CLIExitCode) -> ExitCode {
            lock.withLock { failures.append(message) }
            return exitCode.exitCode
        }
        func failedEvent(_ message: String) {}
    }

    /// The three sheets this route still cannot take are each refused before any plan, with the input code and no folder, in words
    /// that name the single-end form: a sheet with no r2 column says to leave r2 empty, an empty r1 cell says to name the read in r1,
    /// and a sheet that mixes one read file and a read pair says to write two plan folders. The mix is refused whatever `--trim`
    /// says and on every chain (SE-M1-BIO R2), so the untrimmed mix, which the batch writer lets through, is a case, and so is the
    /// salmon chain. `import fastq` still refuses an empty r2 cell in the words it always had.
    func testThePlanRouteSheetRefusalsNameTheSingleEndForm() async throws {
        let set = try await setWithSTARIndex(star: "2.7.3a"), files = try writeSTARImageFiles()
        let list = try writeStagedFiles().list
        let reads = Self.stagedReads.map(\.path)
        func refused(_ name: String, _ rows: [String], chain: String = "star-2.7.3a-genecounts", trim: Bool = false) async throws
            -> (words: String, sheet: URL) {
            let sheet = root.appendingPathComponent("\(name).csv")
            try (rows.joined(separator: "\n") + "\n").write(to: sheet, atomically: true, encoding: .utf8)
            let out = root.appendingPathComponent("refused-\(name)")
            let extra = Self.figures + ["--staged-reads", list.path, "--samplesheet", sheet.path, "--chain", chain] + (trim ? ["--trim"] : [])
            let words = try await refusal(arguments(reads: [], set: set, out: out, files: files, extra: extra), out: out)
            return (words, sheet)
        }
        let noR2 = try await refused("no-r2", ["sample,r1,model", "S1,\(reads[0]),NovaSeq 6000"])
        XCTAssertEqual(noR2.words, "The sample sheet \(noR2.sheet.path) needs the columns sample, r1 and r2, written comma-separated. "
                       + "Leave r2 empty for a sample of single-end reads.")
        let noR1 = try await refused("empty-r1", ["sample,r1,r2", "S1,,\(reads[1])"])
        XCTAssertEqual(noR1.words, "Sample sheet line 2 has an empty r1 value. Name a sample's read file in r1, and leave r2 empty for "
                       + "single-end reads.")
        let mix = "The sample sheet gives S2 one read file and S1 a read pair. A plan folder holds samples of one layout, so write the "
            + "single-end samples and the pairs in two plan folders."
        for (name, chain, trim) in [("mixed-untrimmed", "star-2.7.3a-genecounts", false), ("mixed-trimmed", "star-2.7.3a-genecounts", true),
                                    ("mixed-salmon", "salmon", false)] {
            let mixed = try await refused(name, ["sample,r1,r2", "S1,\(reads[0]),\(reads[1])", "S2,\(reads[2]),"], chain: chain, trim: trim)
            XCTAssertEqual(mixed.words, mix, name)
        }
        let emptyR2 = root.appendingPathComponent("empty-r2.csv")
        try "sample,r1,r2\nS1,\(reads[0]),\n".write(to: emptyR2, atomically: true, encoding: .utf8)
        let recorder = FailureRecorder()
        do {
            _ = try await FASTQImportRun(input: [], samplesheet: emptyR2.path, project: root.appendingPathComponent("P.lungfish").path)
                .run(reporter: recorder, cancellation: .followsCallingTask)
            XCTFail("import fastq took a sheet with an empty r2 cell")
        } catch is ExitCode {}
        XCTAssertEqual(recorder.failed, ["Could not parse sample sheet: Sample sheet line 2 has an empty r2 value."])
    }

    /// The staging-folder front of the refusal in `STARPlan.checkDefaultRoute`: a sheet of single-end reads on either STAR then
    /// salmon chain is refused before any plan, in the route's words, with the input code and no folder written.
    func testASingleEndSheetOnTheStarSalmonChainsIsRefusedBeforeAnyPlan() async throws {
        let set = try await setWithSTARIndex(star: "2.7.11b"), files = try writeSTARImageFiles()
        let list = try writeStagedFiles().list
        let sheet = root.appendingPathComponent("single-end.csv")
        try "sample,r1,r2\nS1,\(Self.stagedReads[0].path),\n".write(to: sheet, atomically: true, encoding: .utf8)
        for chain in ["star-salmon", "star-salmon-errormodel"] {
            let out = root.appendingPathComponent("refused-\(chain)")
            let extra = Self.figures + ["--staged-reads", list.path, "--samplesheet", sheet.path, "--chain", chain]
            let words = try await refusal(arguments(reads: [], set: set, out: out, files: files, extra: extra), out: out)
            XCTAssertTrue(words.hasPrefix("The STAR then salmon route, --chain star-salmon and star-salmon-errormodel, was measured on "
                                          + "read pairs only"), "\(chain): \(words)")
            XCTAssertTrue(words.contains("the sample S1 holds single-end reads"), "\(chain): \(words)")
        }
    }

    // MARK: - Cancel

    func testSIGTERMCancelsThePlanAndLeavesNoFolder() async throws {
        try await assertCancelLeavesNoFolder(everyCoreBusy: false)
    }

    /// The same cancel with every core busy, which the grace must still cover (`RNASeqIndexPlanSIGTERMTests`).
    func testSIGTERMWithEveryCoreBusyStillCancelsThePlanWithinTheGrace() async throws {
        try await assertCancelLeavesNoFolder(everyCoreBusy: true)
    }

    private func assertCancelLeavesNoFolder(everyCoreBusy: Bool) async throws {
        let set = try await setWithIndex(), files = try Self.writeImageFiles(in: root)
        let out = root.appendingPathComponent("quant"), hold = root.appendingPathComponent("held")
        let given = arguments(reads: [try pairBundle("sample1").path], set: set, out: out, files: files)
            .filter { $0 != "--quiet" } + ["--format", "json"]
        let run = try CLISIGTERMHarness.launchCLI(
            ["rnaseq", "quant"] + given, environment: [ViewerExportLeaf.holdFileVariable: hold.path], workingDirectory: root,
            testClass: Self.self)
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
            (stop.standardOutput + stop.standardError).contains(RNASeqCommand.QuantSubcommand.planCancelledMessage), stop.standardError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a cancel leaves no plan folder")
    }
}
