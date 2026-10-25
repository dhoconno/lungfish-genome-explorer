// ExecutorRunAdoptionStepTests.swift - The adopted record's pairing, logical step counts and storage launches as the Mac's (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

final class ExecutorRunAdoptionStepTests: XCTestCase {
    private let env = "/opt/conda/envs/bbtools/bin/"
    private let time = "2026-10-24T12:00:00.000Z"

    private func record(_ id: String, tool: String, argv: [String], storage: ExecutorStorageDetails? = nil) -> ExecutorStepRecord {
        ExecutorStepRecord(
            id: id, kind: storage == nil ? .recipe : .storage,
            tool: ExecutorToolRecord(id: tool, version: "1.0", build: "h1", path: argv[0]), outcome: .succeeded, argv: argv,
            environmentNames: ["PATH"], graceSeconds: 30, deadlineSeconds: 7200, toolExitCode: 0, startedAt: time, endedAt: time,
            wallSeconds: 1, qualityCounts: nil, storage: storage
        )
    }

    private func launch(_ tool: String, _ arguments: [String], groups: Int? = nil) -> ExecutorStorageLaunch {
        ExecutorStorageLaunch(
            tool: ExecutorToolRecord(id: tool, version: tool == "bgzip" ? "1.24" : "39.13", build: "h1", path: env + tool),
            argv: [env + tool] + arguments, environmentNames: ["PATH"], outcome: .succeeded, toolExitCode: 0, wallSeconds: 1,
            stderrPath: "work/\(tool).stderr", clumpifyGroups: groups
        )
    }

    /// QV-12 and QV-13: the Mac counts the logical length-filter step over its whole input, the merged reads and each
    /// mate of the unmerged pairs, so the lane's VSP2 record gives 950521 and 950309.
    func testAdoptCountsLogicalStepAsMac() {
        var merged = record("recipe-4", tool: "seqkit", argv: ["/env/seqkit", "seq", "-j", "1", "-m", "50", "work/m.fq.gz", "-o", "work/l.fq.gz"])
        merged.inputReadCount = 750015
        merged.outputReadCount = 749927
        var pairs = record("recipe-4-2", tool: "fastp", argv: ["/env/fastp", "-i", "work/u_R1.fq.gz", "-I", "work/u_R2.fq.gz", "-l", "50"])
        pairs.inputReadCount = 100253
        pairs.outputReadCount = 100191
        XCTAssertEqual(ExecutorRunAdoption.logicalReadCount([merged, pairs]) { $0.inputReadCount.map(Int.init) }, 950521)
        XCTAssertEqual(ExecutorRunAdoption.logicalReadCount([merged, pairs]) { $0.outputReadCount.map(Int.init) }, 950309)
        pairs.outputReadCount = nil
        XCTAssertNil(ExecutorRunAdoption.logicalReadCount([merged, pairs]) { $0.outputReadCount.map(Int.init) })
    }

    /// QV-5: after a merging recipe the adopt records the pairing of the mixed output, as the Mac does.
    func testAdoptRecordsMixedOutputPairingAsMac() {
        let imported = FASTQBatchImporter.RecordedPairing(mode: .interleaved, source: .explicit)
        let mixed = ExecutorRunAdoption.recordedPairing(
            imported: imported, recipeRan: true,
            mixedLayout: RecipeMixedLayoutCounts(mergedReads: 749927, pairs: 100191, unpairedReads: 0)
        )
        XCTAssertEqual(mixed.mode, .singleEnd)
        XCTAssertEqual(mixed.source, .detected)
        let pairsOnly = ExecutorRunAdoption.recordedPairing(
            imported: imported, recipeRan: true, mixedLayout: RecipeMixedLayoutCounts(mergedReads: 0, pairs: 10, unpairedReads: 0)
        )
        XCTAssertEqual(pairsOnly.mode, .interleaved)
        XCTAssertEqual(pairsOnly.source, .detected)
        let noLayout = ExecutorRunAdoption.recordedPairing(imported: imported, recipeRan: true, mixedLayout: nil)
        XCTAssertEqual(noLayout.mode, .interleaved)
        XCTAssertEqual(noLayout.source, .explicit)
    }

    /// QV-14, QV-15, QV-19: the storage step's two clumpify launches and its writer become three envelope steps with the
    /// record's argv and the environment each ran from, the writer probe none, and the command line joins the two
    /// clumpify launches as the Mac's does.
    func testAdoptWritesStorageLaunchesAsMac() throws {
        let pairs = launch("clumpify.sh", ["in=.clumpify-split-X/pairs.fastq", "out=.clumpify-split-X/pairs.clumped.fastq", "interleaved=t"], groups: 1)
        let unpaired = launch("clumpify.sh", ["in=.clumpify-split-X/unpaired.fastq", "out=.clumpify-split-X/unpaired.clumped.fastq", "interleaved=f"], groups: 1)
        let writer = launch("bgzip", ["-@", "1", "-c", ".clumpify-split-X/combined.fastq"])
        let storage = ExecutorStorageDetails(
            clumpingRan: true, qualityBinning: .illumina4, inputBytes: 10, outputBytes: 5,
            launches: [launch("bgzip", ["-h"]), pairs, unpaired, writer]
        )
        let step = record("storage", tool: "clumpify.sh", argv: pairs.argv, storage: storage)
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(step, parent: UUID()))
        XCTAssertEqual(steps.map(\.toolName), ["clumpify.sh", "clumpify.sh", "bgzip"])
        XCTAssertEqual(steps.map(\.command), [pairs.argv, unpaired.argv, writer.argv])
        XCTAssertEqual(steps.map { $0.managedToolID?.rawValue }, ["bbtools", "bbtools", "bbtools"])
        guard case .integer(let groups)? = steps[0].resolvedOptions?["clumpifyGroups"] else {
            return XCTFail("the clumpify step carries no group count: \(String(describing: steps[0].resolvedOptions))")
        }
        XCTAssertEqual(groups, 1)
        XCTAssertEqual(
            ExecutorRunAdoption.processingCommandLine(step),
            pairs.argv.joined(separator: " ") + " && " + unpaired.argv.joined(separator: " ")
        )
        XCTAssertNil(ExecutorRunAdoption.storageLaunchSteps(record("recipe-1", tool: "fastp", argv: ["/env/fastp"]), parent: UUID()))
    }

    /// QV-15: the compress launch is its own writer, so its step states the record's writer by name as the Mac's
    /// `bgzip` step does, and a clumpify launch, which wrote no stored gzip, states none.
    func testAdoptWritesTheWriterOnTheCompressLaunchAsMac() throws {
        let pairs = launch("clumpify.sh", ["in=.clumpify-split-X/pairs.fastq", "out=.clumpify-split-X/pairs.clumped.fastq"], groups: 1)
        let writer = launch("bgzip", ["-@", "1", "-c", ".clumpify-split-X/combined.fastq"])
        let storage = ExecutorStorageDetails(
            writer: ExecutorStorageWriter(name: "bgzip", tool: writer.tool), clumpingRan: true, qualityBinning: .illumina4,
            inputBytes: 10, outputBytes: 5, launches: [pairs, writer]
        )
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(record("storage", tool: "clumpify.sh", argv: pairs.argv, storage: storage), parent: UUID()))
        XCTAssertEqual(steps.map(\.toolName), ["clumpify.sh", "bgzip"])
        XCTAssertNil(steps[0].resolvedOptions?["writer"], "a clumpify launch states no writer")
        XCTAssertEqual(steps[1].resolvedOptions?["writer"], .dictionary(["name": .string("bgzip")]),
                       "the writer step states the record's writer: \(String(describing: steps[1].resolvedOptions))")
    }

    /// The interleave step of a merging recipe (C4-3 C-3): one `<program> -dc <read>` launch for each read, with the read's
    /// SHA-256 and size and no output of its own, the tool a plan pin. The caller sets the step's recorded outputs.
    private func interleaveStep(
        program: String, tool: String, version: String, reads: [String]
    ) -> (step: ExecutorStepRecord, launches: [ExecutorStorageLaunch]) {
        let pin = ExecutorToolRecord(id: tool, version: version, build: "h2", path: program)
        let launches = reads.enumerated().map { index, path in
            ExecutorStorageLaunch(
                tool: pin, argv: [program, "-dc", path], environmentNames: ["PATH"], outcome: .succeeded, toolExitCode: 0,
                wallSeconds: 2, stderrPath: "/dev/null", inputs: [ExecutorFileDigest(relativePath: path, sha256: "ab\(index)", size: 40 + Int64(index))]
            )
        }
        let step = ExecutorStepRecord(
            id: "recipe-5", kind: .interleave, tool: pin, outcome: .succeeded, argv: [], environmentNames: ["PATH"],
            graceSeconds: 30, deadlineSeconds: 7200, toolExitCode: 0, startedAt: time, endedAt: time, wallSeconds: 4,
            qualityCounts: nil,
            storage: ExecutorStorageDetails(clumpingRan: false, qualityBinning: .illumina4, inputBytes: 10, outputBytes: 5, launches: launches)
        )
        return (step, launches)
    }

    /// C4-3 C-3: each decompressor the node's interleave step started becomes its own envelope step under the
    /// executor's, with the plan pin's tool id, the launch's argv, exit status 0 and its input with the input's SHA-256, and
    /// no output of its own; the mixed file, the interleave step's recorded output, is the output of the step that ends it
    /// (AMV2 ARCH fix 4, BIO fix 3: the three inputs of a merging recipe, each exit status).
    func testAdoptWritesEachDecompressorLaunchAsAStep() throws {
        let reads = ["work/s_lengthfilter_merged.fq.gz", "work/s_lengthfilter_unmerged_R1.fq.gz", "work/s_lengthfilter_unmerged_R2.fq.gz"]
        let (built, launches) = interleaveStep(program: "/opt/conda/envs/pigz/bin/pigz", tool: "pigz", version: "2.8", reads: reads)
        var step = built
        step.outputs = [.init(path: "work/s_mixed.fastq.gz", bytes: 9, sha256: "cd")]
        let parent = UUID()
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(step, parent: parent), "the interleave step's launches are steps")
        XCTAssertEqual(steps.map(\.toolName), ["pigz", "pigz", "pigz"])
        XCTAssertEqual(steps.map(\.toolVersion), ["2.8", "2.8", "2.8"])
        XCTAssertEqual(steps.map(\.command), launches.map(\.argv))
        XCTAssertEqual(steps.map(\.exitCode), [0, 0, 0])
        XCTAssertEqual(steps.map { $0.inputs.map(\.path) }, reads.map { [$0] })
        XCTAssertEqual(steps.map { $0.inputs.map(\.sha256) }, [["ab0"], ["ab1"], ["ab2"]])
        XCTAssertEqual(steps.map { $0.inputs.map(\.sizeBytes) }, [[40], [41], [42]])
        XCTAssertEqual(steps.map { $0.outputs.map(\.sha256) }, [[], [], ["cd"]], "the mixed file is the last step's recorded output")
        XCTAssertEqual(steps.last?.outputs.map(\.path), ["work/s_mixed.fastq.gz"])
        XCTAssertEqual(steps.last?.outputs.map(\.sizeBytes), [9])
        XCTAssertEqual(steps.last?.outputs.map(\.role), [.output])
        XCTAssertEqual(steps.map(\.parentStepID), [parent, parent, parent])
    }

    /// AMV2 SWIFT fix 3: `RunCommand` picks the decompressor from `gzip`, `pigz` and `bgzip`, so a plan that pins `bgzip`
    /// alone reads with `bgzip -dc`, which writes to a pipe. The adopted step states the argv the reader ran and no
    /// `> <output>`; the storage step's `bgzip` writer keeps its redirect.
    func testAdoptWritesNoRedirectOnABgzipDecompressorStep() throws {
        let (built, launches) = interleaveStep(
            program: "/opt/conda/envs/bbtools/bin/bgzip", tool: "bgzip", version: "1.24", reads: ["work/s_a.fq.gz", "work/s_b.fq.gz"]
        )
        var step = built
        step.outputs = [.init(path: "out/mixed.fastq", bytes: 3, sha256: "aa")]
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(step, parent: UUID()))
        XCTAssertEqual(steps.map(\.command), launches.map(\.argv), "a reader writes to a pipe, so its step holds no redirect")

        let writer = launch("bgzip", ["-@", "1", "-c", ".clumpify-split-X/combined.fastq"])
        let storage = ExecutorStorageDetails(clumpingRan: true, qualityBinning: .illumina4, inputBytes: 10, outputBytes: 5, launches: [writer])
        var storageStep = record("storage", tool: "bgzip", argv: writer.argv, storage: storage)
        storageStep.outputs = [.init(path: "out/s.fastq.gz", bytes: 3, sha256: "dd")]
        let written = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(storageStep, parent: UUID()))
        XCTAssertEqual(written.map(\.command), [writer.argv + [">", "out/s.fastq.gz"]], "the storage writer states its output")
    }

    /// AMV2 SWIFT fix 5 (C4-3 C-4): only a program of the form `<tool-root>/envs/<name>/bin/<tool>` names a managed
    /// environment; a path outside any environment, a file under an environment but not in `bin` and no path name none.
    func testManagedToolIDTakesOnlyAProgramOfAnEnvironmentsBinFolder() {
        func tool(_ path: String) -> ExecutorToolRecord { ExecutorToolRecord(id: "bgzip", version: "1.24", build: "h1", path: path) }
        XCTAssertEqual(ExecutorRunAdoption.managedToolID(tool("/opt/conda/envs/bbtools/bin/bgzip"))?.rawValue, "bbtools")
        XCTAssertNil(ExecutorRunAdoption.managedToolID(tool("/usr/bin/bgzip")))
        XCTAssertNil(ExecutorRunAdoption.managedToolID(tool("/opt/conda/envs/bbtools/lib/bgzip")))
        XCTAssertNil(ExecutorRunAdoption.managedToolID(nil))
    }

    /// A storage launch of the CHTC image, where every tool sits at `/opt/lge/env/bin/<tool>` and no path names an
    /// environment (ARCH-X3 R-1).
    private func imageLaunch(
        _ tool: String, version: String, build: String, source: ExecutorToolVersionSource = .imageManifest
    ) -> ExecutorStorageLaunch {
        let path = "/opt/lge/env/bin/" + tool
        return ExecutorStorageLaunch(
            tool: ExecutorToolRecord(id: tool, version: version, build: build, path: path, versionSource: source),
            argv: [path, "in=work/x.fastq"], environmentNames: ["PATH"], outcome: .succeeded, toolExitCode: 0, wallSeconds: 1,
            stderrPath: "work/\(tool).stderr"
        )
    }

    /// The tool names and managed tool ids of the envelope steps one storage step's launches become, in step order.
    private func imageToolIDs(_ launches: [ExecutorStorageLaunch]) throws -> (names: [String], ids: [String?]) {
        let storage = ExecutorStorageDetails(
            clumpingRan: true, qualityBinning: .illumina4, inputBytes: 10, outputBytes: 5, launches: launches
        )
        let step = record("storage", tool: launches[0].tool.id, argv: launches[0].argv, storage: storage)
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(step, parent: UUID()))
        return (steps.map(\.toolName), steps.map { $0.managedToolID?.rawValue })
    }

    /// ARCH-X3 R-1: the CHTC image holds every tool at `/opt/lge/env/bin/<tool>`, so no path names an environment. A tool whose
    /// version and build the node read from the image manifest names the one linux-64 lock entry that lists it and pins that
    /// version and build: `clumpify.sh` 40.02 `h09cc210_0` is `bbtools` and `bgzip` 1.24 `ha79157c_0` is `htslib`.
    func testImageToolNamesItsLinuxLockEntry() throws {
        let launched = try imageToolIDs([
            imageLaunch("clumpify.sh", version: "40.02", build: "h09cc210_0"),
            imageLaunch("bgzip", version: "1.24", build: "ha79157c_0"),
        ])
        XCTAssertEqual(launched.names, ["clumpify.sh", "bgzip"])
        XCTAssertEqual(launched.ids, ["bbtools", "htslib"])
    }

    /// ARCH-X3 R-1: a tool names no id when the lock does not pin its build, when its version is the plan's pin and not what
    /// the node read, and when it is a tool another entry lists but at another version and build (`java` is among the bbtools
    /// entry's executables, and the image's `java` is openjdk 25.0.2 `h1602c4f_26`).
    func testImageToolOffTheLockNamesNone() throws {
        let launched = try imageToolIDs([
            imageLaunch("clumpify.sh", version: "40.02", build: "h0000000_0"),
            imageLaunch("bgzip", version: "1.24", build: "ha79157c_0", source: .planPin),
            imageLaunch("java", version: "25.0.2", build: "h1602c4f_26"),
        ])
        XCTAssertEqual(launched.names, ["clumpify.sh", "bgzip", "java"])
        XCTAssertEqual(launched.ids, [nil, nil, nil])
    }

    /// QV-23: each storage launch's envelope step lists the files the launch read and wrote, by the record's path,
    /// SHA-256 and size, as the Mac's clumpify and bgzip steps do.
    func testAdoptWritesEachStorageLaunchsFilesWithDigests() throws {
        var pairs = launch("clumpify.sh", ["in=.clumpify-split-X/pairs.fastq", "out=.clumpify-split-X/pairs.clumped.fastq"], groups: 1)
        pairs.inputs = [ExecutorFileDigest(relativePath: ".clumpify-split-X/pairs.fastq", sha256: "aa", size: 7)]
        pairs.outputs = [ExecutorFileDigest(relativePath: ".clumpify-split-X/pairs.clumped.fastq", sha256: "bb", size: 7)]
        var writer = launch("bgzip", ["-@", "1", "-c", ".clumpify-split-X/combined.fastq"])
        writer.inputs = [ExecutorFileDigest(relativePath: ".clumpify-split-X/combined.fastq", sha256: "cc", size: 9)]
        writer.outputs = [ExecutorFileDigest(relativePath: "out/s.fastq.gz", sha256: "dd", size: 3)]
        let storage = ExecutorStorageDetails(
            clumpingRan: true, qualityBinning: .illumina4, inputBytes: 10, outputBytes: 5, launches: [launch("bgzip", ["-h"]), pairs, writer]
        )
        let steps = try XCTUnwrap(ExecutorRunAdoption.storageLaunchSteps(record("storage", tool: "clumpify.sh", argv: pairs.argv, storage: storage), parent: UUID()))
        XCTAssertEqual(steps.map { $0.inputs.map(\.path) }, [[".clumpify-split-X/pairs.fastq"], [".clumpify-split-X/combined.fastq"]])
        XCTAssertEqual(steps.map { $0.inputs.map(\.sha256) }, [["aa"], ["cc"]])
        XCTAssertEqual(steps.map { $0.outputs.map(\.path) }, [[".clumpify-split-X/pairs.clumped.fastq"], ["out/s.fastq.gz"]])
        XCTAssertEqual(steps.map { $0.outputs.map(\.sha256) }, [["bb"], ["dd"]])
        XCTAssertEqual(steps.map { $0.outputs.map(\.sizeBytes) }, [[7], [3]])
        XCTAssertEqual(steps.map { $0.inputs.map(\.role) }, [[.input], [.input]])
        XCTAssertEqual(steps.map { $0.outputs.map(\.role) }, [[.output], [.output]])
    }

    /// QV-7 and QV-23: a recipe process's report, a record output no later plan step reads, goes into the bundle's
    /// `metadata/recipe-step-artifacts/` by the Mac's own copy; the sidecar result holds the published path and the
    /// rewrite keyed by the node's argv token, and the envelope step's replay argv and outputs name the copy. A report
    /// whose bytes differ from the record is refused, and so is one the folder lacks, as the Mac's import refuses it.
    func testAdoptCopiesEachReportAndNamesTheCopyAsMac() throws {
        let root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionStep")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("returned", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("work"), withIntermediateDirectories: true)
        let report = "work/s_fused_fastp_report.json"
        let bytes = Data("{\"summary\":{}}\n".utf8)
        try bytes.write(to: folder.appendingPathComponent(report))
        let digest = try XCTUnwrap(ProvenanceRecorder.sha256(of: folder.appendingPathComponent(report)))
        var step = record("recipe-1", tool: "fastp", argv: ["/env/fastp", "-i", "work/s_R1.fq.gz", "-o", "work/s_out.fq.gz", "-j", report])
        step.outputs = [.init(path: "work/s_out.fq.gz", bytes: 4, sha256: "aa"), .init(path: report, bytes: UInt64(bytes.count), sha256: digest)]
        let consumed: Set<String> = ["work/s_out.fq.gz"]
        let reports = try ExecutorRunAdoption.recordedReports(step, folder: folder, consumed: consumed)
        XCTAssertEqual(reports, [folder.appendingPathComponent(report).path], "only the output no later step reads is a report")

        let staging = root.appendingPathComponent("Imports/.s.building-X", isDirectory: true)
        let published = root.appendingPathComponent("Imports/s.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let result = RecipeStepResult(stepName: "Trim", tool: "fastp", commandArguments: step.argv, durationSeconds: 1, auxiliaryOutputPaths: reports)
        let copied = ExecutorRunAdoption.rewritesKeyedByRecordPath(
            try FASTQBatchImporter.materializeRecipeAuxiliaryOutputs([result], stagingBundleURL: staging, publishedBundleURL: published),
            folder: folder
        )
        let artifact = "metadata/recipe-step-artifacts/1-1-trim-s_fused_fastp_report.json"
        let publishedReport = published.appendingPathComponent(artifact).path
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent(artifact)), bytes, "the bundle holds the node's report")
        XCTAssertEqual(copied.first?.auxiliaryOutputPaths, [publishedReport])
        XCTAssertEqual(copied.first?.auxiliaryCommandPathRewrites, [report: publishedReport])

        let files = FASTQBatchImporter.recipeProvenanceFiles(
            for: try XCTUnwrap(copied.first), command: step.argv, originalInputURLs: [],
            bundleFASTQURL: staging.appendingPathComponent("s.fastq.gz"), stagingBundleURL: staging, publishedBundleURL: published
        )
        let envelopeStep = ExecutorRunAdoption.nodeStepExecution(step, parent: UUID(), title: nil, recipeFiles: files)
        XCTAssertEqual(envelopeStep.command, step.argv, "argv stays the node's")
        XCTAssertEqual(envelopeStep.durableReplayArgv, Array(step.argv.dropLast()) + [publishedReport])
        XCTAssertEqual(envelopeStep.outputs.last?.path, publishedReport)
        XCTAssertEqual(envelopeStep.outputs.last?.sha256, digest)

        step.outputs[1].sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ExecutorRunAdoption.recordedReports(step, folder: folder, consumed: consumed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not hold the bytes the run record states"), error.localizedDescription)
        }
        // The record names the report and the folder lacks it: refused, as the Mac's import refuses it (AMV2 SWIFT fix 2, BIO fix 1).
        step.outputs[1].sha256 = digest
        try FileManager.default.removeItem(at: folder.appendingPathComponent(report))
        XCTAssertThrowsError(try ExecutorRunAdoption.recordedReports(step, folder: folder, consumed: consumed)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("is in the run record but not in the returned folder"), error.localizedDescription
            )
        }
    }

    /// Vote C4-4 D-3 (BIO B-D3-1): the one naming function gives a copy the sample's name only where the plan's work stem
    /// and `_` lead the work file's name. An import passes no stem, so its copy names are the work file's names as before.
    func testReportCopyNameTakesTheSampleOnlyWhereTheWorkStemLeads() {
        func name(_ file: String, _ stem: (work: String, sample: String)?) -> String {
            FASTQBatchImporter.recipeArtifactFilename(
                stepIndex: 0, artifactIndex: 1, stepName: "Remove duplicates", sourceURL: URL(fileURLWithPath: "/run/work/" + file), stem: stem
            )
        }
        let adopt = (work: ExecutorPlanEmitter.workStem, sample: "C079876_S1")
        XCTAssertEqual(name("sample_fused_fastp_report.json", adopt), "1-2-remove-duplicates-C079876_S1_fused_fastp_report.json")
        XCTAssertEqual(name("sampled_report.json", adopt), "1-2-remove-duplicates-sampled_report.json", "only the stem and `_`")
        XCTAssertEqual(name("x_sample_report.json", adopt), "1-2-remove-duplicates-x_sample_report.json", "only a leading stem")
        XCTAssertEqual(name("sample_fused_fastp_report.json", nil), "1-2-remove-duplicates-sample_fused_fastp_report.json")
        XCTAssertEqual(
            name("C079876_S1_fused_fastp_report_0F1E.json", nil), "1-2-remove-duplicates-C079876_S1_fused_fastp_report_0F1E.json",
            "an import's copy keeps its work file's name"
        )
    }

    /// AMV2 SWIFT fix 1: a report is read through the resolver the payload uses. A record output that names a path out of
    /// the folder, a report that is a link to a file outside the folder whose bytes match the record, and one that is a link
    /// to a file inside the folder are each refused with the report named; the same bytes as a regular file pass.
    func testAdoptRefusesAReportThatIsALinkOrLeavesTheFolder() throws {
        let root = try TestTempDirectory.make(prefix: "ExecutorRunAdoptionLink")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("returned", isDirectory: true)
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let bytes = Data("{\"summary\":{}}\n".utf8)
        let outside = root.appendingPathComponent("outside.json")
        let inside = folder.appendingPathComponent("inside.json")
        try bytes.write(to: outside)
        try bytes.write(to: inside)
        let digest = try XCTUnwrap(ProvenanceRecorder.sha256(of: outside))
        let link = work.appendingPathComponent("r.json")
        func report(at path: String) -> ExecutorStepRecord {
            var step = record("recipe-1", tool: "fastp", argv: ["/env/fastp", "-j", path])
            step.outputs = [.init(path: path, bytes: UInt64(bytes.count), sha256: digest)]
            return step
        }
        let cases: [(label: String, path: String, target: URL?)] = [
            ("a path out of the folder", "../outside.json", nil),
            ("a link to a file outside the folder", "work/r.json", outside),
            ("a link to a file inside the folder", "work/r.json", inside),
        ]
        for (label, path, target) in cases {
            try? FileManager.default.removeItem(at: link)
            if let target { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
            XCTAssertThrowsError(try ExecutorRunAdoption.recordedReports(report(at: path), folder: folder, consumed: []), label) { error in
                guard let refusal = error as? ExecutorAdoptRefusal else { return XCTFail("\(label): \(error)") }
                XCTAssertEqual(refusal.field, "steps", label)
                XCTAssertTrue(refusal.reason.contains(path), "\(label): \(refusal.reason)")
            }
        }
        try? FileManager.default.removeItem(at: link)
        try bytes.write(to: link)
        XCTAssertEqual(try ExecutorRunAdoption.recordedReports(report(at: "work/r.json"), folder: folder, consumed: []), [link.path])
    }
}
