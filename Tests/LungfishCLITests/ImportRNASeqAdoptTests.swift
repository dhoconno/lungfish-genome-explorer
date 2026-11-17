// ImportRNASeqAdoptTests.swift - `import rnaseq <result folder> --adopt`, and the proof that the adopted result equals
// the import of its salmon folder with the set's table (Phase 5.3 lane EX-ADOPT M2, prog:250)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ImportRNASeqAdoptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "import-rnaseq-adopt").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/rnaseq", isDirectory: true)

    /// gffread's stand-in, as `StandInTranscriptDeriver` of LungfishWorkflowTests writes: one record of each transcript
    /// id, contig and strand of the GTF it is given, in file order, at its merged exon length.
    private struct StandInDeriver: ReferenceSetTranscriptDeriving {
        func toolVersion() async throws -> String { "0.12.9" }
        func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws {
            var records: [(id: String, place: String)] = []
            var exons: [String: [ClosedRange<Int>]] = [:]
            for line in try String(contentsOf: annotation, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard cells.count == 9, ["exon", "CDS", "transcript"].contains(cells[2]),
                      let range = cells[8].range(of: #"transcript_id "[^"]+""#, options: .regularExpression) else { continue }
                let id = String(cells[8][range].dropFirst("transcript_id \"".count).dropLast())
                let place = "\(id)\t\(cells[0])\t\(cells[6])"
                if exons[place] == nil {
                    records.append((id, place))
                    exons[place] = []
                }
                if cells[2] == "exon", let start = Int(cells[3]), let end = Int(cells[4]) { exons[place]?.append(start...end) }
            }
            let fasta = records.map { record -> String in
                let length = max(ReferenceSetAnnotationReader.mergedLength(exons[record.place] ?? []), 4)
                return ">\(record.id)\n\(String(String(repeating: "ACGT", count: length / 4 + 1).prefix(length)))\n"
            }
            try Data(fasta.joined().utf8).write(to: output)
        }
    }

    /// The refset-mito set of the LGE layout under `storage`, the set EX-PLAN-SALMON's pinned plan names.
    private func buildSet(storage: URL) async throws -> ReferenceSetOutcome {
        let mito = Self.fixtures.appendingPathComponent("refset-mito", isDirectory: true)
        let request = ReferenceSetRequest(
            name: "Cynomolgus mitochondrion", species: "Macaca fascicularis", assemblyName: "Macaca_fascicularis_5.0",
            annotationSource: "RefSeq", annotationRelease: "101", genome: mito.appendingPathComponent("cynomolgus-mt.fa"),
            annotation: mito.appendingPathComponent("cynomolgus-mt.gtf"), layout: .lge,
            assemblyReport: mito.appendingPathComponent("cynomolgus-mt_assembly_report.txt"))
        let owner = ReferenceSetOwner(storageRoot: storage, deriver: StandInDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(request)
    }

    /// salmon's four files over the set's transcripts, by the pinned plan's `home` paths under `quant/`.
    private func salmonFiles(_ set: ReferenceSetOutcome) throws -> [String: Data] {
        let names = try ReferenceSetAnnotationReader.fastaRecords(set.url.appendingPathComponent("derived/transcripts.fa")).map(\.name)
        let rows = names.enumerated().map { "\($1)\t100\t80.0\t10.0\t\(Double($0 * 7 + 3))\n" }
        let meta = """
            {"salmon_version": "2.11.0", "num_processed": 1000, "num_mapped": 900, "percent_mapped": 90.0,
             "library_types": ["IU"], "seq_bias_correct": false, "gc_bias_correct": true, "pos_bias_correct": false,
             "index_seq_hash": "a1", "index_name_hash": "b2", "index_decoy_seq_hash": "c3", "index_decoy_name_hash": "d4"}
            """
        return [
            "quant/quant.sf": Data(("Name\tLength\tEffectiveLength\tTPM\tNumReads\n" + rows.joined()).utf8),
            "quant/cmd_info.json": Data(#"{"salmon_version": "2.11.0", "libType": "A"}"#.utf8),
            "quant/lib_format_counts.json": Data(#"{"expected_format": "IU", "compatible_fragment_ratio": 1.0, "strand_mapping_bias": 0.5}"#.utf8),
            "quant/aux_info/meta_info.json": Data(meta.utf8),
        ]
    }

    /// A returned folder of the pinned plan's bytes: each `home` output (the salmon files from `salmon`) and a succeeded
    /// record true to the plan, whose steps hold the plan's argv after the tool's path, as the executor records it.
    private func returnedFolder(_ name: String, salmon: [String: Data]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let planBytes = try Data(contentsOf: Self.fixtures.appendingPathComponent("salmon-plan/plan.json"))
        try planBytes.write(to: folder.appendingPathComponent("plan.json"))
        let plan = try ExecutionPlan.decode(planBytes)
        let time = "2026-11-15T12:00:00.000Z"
        // The trim call's JSON reports and console, the saved C7 report and EX-PLAN-SALMON's Docker console (lane EX-ADOPT M4).
        let adapter = Self.fixtures.appendingPathComponent("trim-galore-adapter", isDirectory: true)
        let report = try Data(contentsOf: adapter.appendingPathComponent("c7_1.fq.gz_trimming_report.json"))
        let trim = [
            "trim-pair1/pair1_R1.fastq_trimming_report.json": report, "trim-pair1/pair1_R2.fastq_trimming_report.json": report,
            "logs/trim-pair1.stderr": try Data(contentsOf: adapter.appendingPathComponent("trim-pair1.stderr")),
        ]
        var steps: [ExecutorStepRecord] = []
        for step in plan.steps {
            var outputs: [ExecutorStepRecord.Output] = []
            for path in step.outputs {
                let policy = step.outputPolicy?[path] ?? .stays
                let bytes = salmon[path] ?? trim[path] ?? Data("\(step.id) wrote \(path)\n".utf8)
                if policy == .home {
                    let url = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url)
                }
                outputs.append(.init(path: path, bytes: UInt64(bytes.count), sha256: PortableDigest.sha256Hex(of: bytes), policy: policy))
            }
            let tool = step.tool.map { ExecutorToolRecord(id: $0.id, version: $0.version, build: $0.build, path: "/opt/conda/bin/\($0.id)") }
            steps.append(ExecutorStepRecord(
                id: step.id, kind: step.kind, tool: tool, outcome: .succeeded, argv: [tool?.path ?? ""] + step.arguments,
                environmentNames: ["HOME", "PATH", "TMPDIR"], graceSeconds: 30, deadlineSeconds: step.deadlineSeconds,
                toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 1, outputs: outputs))
        }
        let executor = try XCTUnwrap(plan.entries.first { $0.role == .executor })
        let record = ExecutorRunRecord(
            outcome: .succeeded, executorArguments: ["run", "--plan", "plan.json"],
            executor: ExecutorBinaryIdentity(sha256: executor.sha256, size: executor.size, buildPin: plan.executor),
            plan: ExecutorFileDigest(relativePath: "plan.json", sha256: PortableDigest.sha256Hex(of: planBytes), size: Int64(planBytes.count)),
            imageManifest: ExecutorImageManifestRecord(sha256: plan.imageManifest.sha256, size: plan.imageManifest.size, source: .image),
            runtimeIdentity: ExecutorRuntimeIdentity(
                kernelRelease: "5.14.0-503.el9.x86_64", machine: "x86_64", pidNamespaceDepth: 2, cgroupVersion: 2, observedLimits: [],
                subreaper: ExecutorStepRecord.Subreaper(state: "set", setterResult: 0, setterResultName: "0", getterResult: 0, getterValue: 1),
                orphanSweep: .subreaper),
            inputs: plan.entries.filter { $0.role != .executor }, steps: steps, startedAt: time, endedAt: time, wallSeconds: 3)
        try record.encoded().write(to: folder.appendingPathComponent(ExecutorRunRecord.fileName))
        return folder
    }

    private func project(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ arguments: [String]) async throws {
        try await ImportCommand.RNASeqSubcommand.parse(arguments + ["--quiet"]).run()
    }

    private func result(in project: URL) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Analyses").path)
            .filter { $0.hasSuffix(".lungfishrnaseq") && !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 1, "\(names)")
        return project.appendingPathComponent("Analyses/\(try XCTUnwrap(names.first))", isDirectory: true)
    }

    private func manifestObject(_ result: URL) throws -> [String: NSObject] {
        let data = try Data(contentsOf: result.appendingPathComponent(RNASeqResultManifest.filename))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: NSObject])
    }

    // MARK: - M2 item 3, the proof of prog:250

    /// The adopted result of a run of the pinned plan equals `import rnaseq` of the same salmon folder with `--tx2gene`
    /// set to the set's table: the count tables, their gene and transcript rows, the samples, each salmon file's
    /// SHA-256 and the quality table. The manifest differs only in the keys named here, and `--dry-run` writes nothing.
    func testAdoptedResultEqualsTheImportOfItsSalmonFolderWithTheSetsTable() async throws {
        let storage = root.appendingPathComponent("store", isDirectory: true)
        let set = try await buildSet(storage: storage)
        let salmon = try salmonFiles(set)
        let returned = try returnedFolder("returned", salmon: salmon)
        let adoptedProject = try project("adopted"), importedProject = try project("imported")
        let adopt = [returned.path, "--adopt", "--project", adoptedProject.path, "--name", "mito", "--storage-root", storage.path]
        try await run(adopt + ["--dry-run"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: adoptedProject.path), [], "a dry run writes nothing")
        try await run(adopt)

        let folder = root.appendingPathComponent("salmon/sample1", isDirectory: true)
        for (path, data) in salmon {
            let url = folder.appendingPathComponent(String(path.dropFirst("quant/".count)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let table = set.url.appendingPathComponent(set.manifest.derived.transcriptGenes.path)
        try await run([folder.path, "--project", importedProject.path, "--name", "mito", "--tx2gene", table.path])

        let (adoptedURL, importedURL) = (try result(in: adoptedProject), try result(in: importedProject))
        let adopted = try RNASeqResultBundle.load(from: adoptedURL), imported = try RNASeqResultBundle.load(from: importedURL)
        XCTAssertEqual(adopted.counts.map(\.entry.rows), [.gene, .transcript])
        XCTAssertEqual(adopted.counts.map(\.table), imported.counts.map(\.table))
        XCTAssertEqual(adopted.counts.map(\.entry), imported.counts.map(\.entry))
        XCTAssertEqual(adopted.samples, imported.samples)
        XCTAssertEqual(adopted.manifest.sourceFiles, imported.manifest.sourceFiles)
        XCTAssertEqual(adopted.manifest.sourceFiles.map(\.sha256).sorted(), salmon.values.map(PortableDigest.sha256Hex(of:)).sorted())
        XCTAssertEqual(adopted.quality, imported.quality)
        let (one, other) = (try manifestObject(adoptedURL), try manifestObject(importedURL))
        let differing = Set(one.keys).union(other.keys).filter { one[$0] != other[$0] }
        XCTAssertTrue(
            differing.isSubset(of: ["origin", "route", "referenceSet", "genes", "notHost", "createdAt"]), "\(differing.sorted())")
        XCTAssertTrue(["origin", "route", "referenceSet"].allSatisfy(differing.contains), "\(differing.sorted())")
    }

    // MARK: - M5 item 3 and M6 item 3, the help

    /// The help of --adopt names each count it takes, salmon's on the reads or by LGE's default route, STAR GeneCounts'
    /// column, featureCounts' table, STARsolo's matrix and the UMI branch's UMIs, the refusal of a UMI sample whose check
    /// failed, and the refusal of a table counted on another GTF.
    func testAdoptHelpNamesEachRouteItTakes() {
        let help = ImportCommand.RNASeqSubcommand.helpMessage(columns: 1000)
        for words in [
            "The counts are those the plan's route names, salmon's on the reads or by LGE's default route (STAR, then salmon "
                + "-a on STAR's transcriptome alignments), STAR GeneCounts' column 2 (unstranded), featureCounts' table, or the "
                + "UMI branch's count of UMIs per gene from umi_tools.",
            "A UMI sample whose layout check failed has no counts and is refused in the check's words.",
            "A STARsolo plan of rnaseq solo-plan gives the filtered matrix of Solo.out/Gene as one single-cell result.",
            "a STAR, featureCounts or umi_tools table counted on another GTF is refused.",
        ] {
            XCTAssertTrue(help.contains(words), words)
        }
    }

    // MARK: - M2 item 2, the route

    /// A refused adopt writes nothing in the project: here the storage root holds no set the plan names.
    func testAdoptThatIsRefusedWritesNothing() async throws {
        let storage = root.appendingPathComponent("empty-store", isDirectory: true)
        let returned = try returnedFolder("returned", salmon: [:])
        let project = try project("refused")
        do {
            try await run([returned.path, "--adopt", "--project", project.path, "--name", "mito", "--storage-root", storage.path])
            XCTFail("The adopt took a plan whose set the storage root does not hold")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
    }

    /// No option that sets a count, a table, a sheet or a set is taken with --adopt, nor --dry-run or --storage-root
    /// without it, and each refusal writes nothing.
    func testAdoptRefusesEachOptionThatSetsACountAndTheAdoptOptionsAloneAreRefused() async throws {
        let returned = try returnedFolder("returned", salmon: [:])
        let project = try project("options")
        let table = root.appendingPathComponent("table.tsv")
        try Data("transcript_id\tgene_id\nT1\tG1\n".utf8).write(to: table)
        let base = [returned.path, "--adopt", "--project", project.path, "--name", "mito"]
        let refused: [[String]] = [
            base + ["--tx2gene", table.path], base + ["--samples", table.path], base + ["--unit", "reads"],
            base + ["--genome", "hg19"], base + ["--reference-set", root.path], base + ["--not-host-bam", "S=\(table.path)"],
            [returned.path, returned.path, "--adopt", "--project", project.path, "--name", "mito"],
            [table.path, "--project", project.path, "--name", "mito", "--unit", "reads", "--dry-run"],
            [table.path, "--project", project.path, "--name", "mito", "--unit", "reads", "--storage-root", root.path],
        ]
        for arguments in refused {
            do {
                try await run(arguments)
                XCTFail("Took \(arguments.dropFirst(2).joined(separator: " "))")
            } catch let code as ExitCode {
                XCTAssertEqual(code, CLIExitCode.inputError.exitCode, "\(arguments)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
    }
}
