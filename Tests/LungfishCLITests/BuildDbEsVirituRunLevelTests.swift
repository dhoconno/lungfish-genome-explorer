// BuildDbEsVirituRunLevelTests.swift - The build-db esviritu record names the BAM where it ends
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A39 (2.8 rows 267 and 269, the B3 ruling, 2.9 R7). `build-db esviritu` moves each BAM and
// its index from `<sample>_temp/` to `bams/`, marks duplicates in place and removes `_temp/`. Its steps keep
// the files as they were when each ran, and a removal step names what went (P1 of Phase 2.8). The run level
// of its record and of each sidecar names every file as the run left it, so it names nothing in `_temp/` and
// the BAM and its index in `bams/` with the digests of the files that are there (B3, a removal step never
// excuses the run level).

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// The stand-in form. Each sample's detection table holds its header only, so no samtools runs and the
/// files in `_temp/` are placeholders, while the move, the cleanup and the record are the command's own.
final class BuildDbEsVirituRunLevelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbEsVirituRunLevel")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A pin of what the fix keeps (B3). The move is a step that names each file under its old path in
    /// `_temp/` and its new one in `bams/` with the digest it had, the cleanup's removal step names each
    /// old path with that digest, and the run's own step comes last.
    func testTheMoveAndTheRemovalOfTheTempFilesStayStepsOfTheRecord() async throws {
        let result = try EsVirituRunLevel.standInResult(in: root, samples: ["S1", "S2"])
        let before = try EsVirituRunLevel.digests(ofTempFilesIn: result)
        XCTAssertEqual(before.count, 4, "a BAM and its index in each sample's _temp")

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"]).run()

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        XCTAssertEqual(record.steps.last?.toolName, "lungfish build-db esviritu", "the run's own step comes last")
        let move = try XCTUnwrap(record.steps.first { $0.toolName == "Lungfish EsViritu BAM Relocation" })
        let removal = try XCTUnwrap(record.steps.first { $0.toolName == "Lungfish EsViritu BAM Relocation Source Removal" })
        XCTAssertEqual(removal.resolvedOptions["operation"], .string(RecordedRemovalStep.operation))
        XCTAssertEqual(EsVirituRunLevel.sorted(move.inputs), before, "the move names each old path with its digest")
        XCTAssertEqual(EsVirituRunLevel.sorted(removal.inputs), before, "the removal names each old path with that digest")
        XCTAssertEqual(
            EsVirituRunLevel.sorted(move.outputs),
            before.map { EsVirituRunLevel.Named(path: EsVirituRunLevel.movedPath($0.path), digest: $0.digest) },
            "the move names each new path in bams/ with the same digest"
        )
        XCTAssertEqual(
            move.outputs.map { $0.originPath.map(EsVirituRunLevel.resolved) }, move.inputs.map { EsVirituRunLevel.resolved($0.path) },
            "each moved file names its old path as its origin"
        )
        for sample in ["S1", "S2"] {
            let folder = result.appendingPathComponent(sample, isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(sample)_temp").path))
            for suffix in ["", ".bai"] {
                let moved = folder.appendingPathComponent("bams/\(sample).third.filt.sorted.bam\(suffix)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), moved.path)
            }
        }
    }

    /// The run level of the folder's record and of each sidecar names nothing in `_temp/`, which the cleanup
    /// removed, and names every file as it is, and the folder's record names each BAM and its index in `bams/`
    /// with the digest of the file there (2.8 rows 267 and 269).
    func testTheRunLevelNamesTheBAMWhereItEndsAndNothingInTemp() async throws {
        let result = try EsVirituRunLevel.standInResult(in: root, samples: ["S1", "S2"])

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"]).run()

        let records = try EsVirituRunLevel.records(in: result)
        XCTAssertEqual(records.map(\.name), [
            ".lungfish-provenance.json",
            "S1/bams/S1.third.filt.sorted.bam.bai.lungfish-provenance.json", "S1/bams/S1.third.filt.sorted.bam.lungfish-provenance.json",
            "S2/bams/S2.third.filt.sorted.bam.bai.lungfish-provenance.json", "S2/bams/S2.third.filt.sorted.bam.lungfish-provenance.json",
            "esviritu.sqlite.lungfish-provenance.json",
        ])
        XCTAssertEqual(EsVirituRunLevel.problems(of: records), [])
        try EsVirituRunLevel.assertTheRecordNamesEachBAMWhereItEnds(records[0].envelope, in: result)
    }

    /// A markdup rewrites the BAM in place and replaces its index, and its removal step names the bytes that
    /// went (`BuildDbSamtoolsProvenanceTracker.markdup`). The record then names the BAM and its index at its
    /// run level only with the digests of the files there, as the run's own step does, and a step keeps the
    /// bytes it read.
    func testTheRunLevelNamesNoBytesTheMarkdupReplaced() async throws {
        let result = root.appendingPathComponent("esviritu-batch", isDirectory: true)
        let bams = result.appendingPathComponent("S1/bams", isDirectory: true)
        try FileManager.default.createDirectory(at: bams, withIntermediateDirectories: true)
        let bam = bams.appendingPathComponent("S1.third.filt.sorted.bam")
        let index = bams.appendingPathComponent("S1.third.filt.sorted.bam.bai")
        try Data("BAM before markdup\n".utf8).write(to: bam)
        try Data("index before markdup\n".utf8).write(to: index)
        let clock = ProvenanceRunClock()
        let read = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .input)
        let oldIndex = try ProvenanceFileDescriptor.file(url: index, role: .index)
        let header = ProvenanceStep(
            toolName: "samtools", toolVersion: "stand-in", argv: ["samtools", "view", "-H", bam.path], inputs: [read], outputs: [],
            exitStatus: 0, wallTimeSeconds: 0, stderr: nil, startedAt: clock.startedAt, completedAt: clock.now
        )
        try Data("BAM after markdup\n".utf8).write(to: bam)
        try Data("index after markdup\n".utf8).write(to: index)
        let replacement = try XCTUnwrap(RecordedRemovalStep.step(
            toolName: "Lungfish Markdup Replacement", api: "FileManager.replaceItemAt(_:withItemAt:)", removing: [read, oldIndex], clock: clock
        ))

        let record = try await BuildDbCommand.recordBuildDbProvenance(
            tool: .esViritu, resultURL: result, dbURL: result.appendingPathComponent("esviritu.sqlite"), force: true, noCleanup: false,
            globalOptions: try GlobalOptions.parse([]), runClock: clock, inputRecords: [], additionalSteps: [header, replacement],
            events: BuildDbEventSink(progress: { _, _ in }, text: { _ in }, textWarning: { _ in }, warning: { _ in })
        )

        let final = EsVirituRunLevel.named([
            try ProvenanceFileDescriptor.file(url: bam, role: .output), try ProvenanceFileDescriptor.file(url: index, role: .index),
        ])
        XCTAssertEqual(record.steps.last?.toolName, "lungfish build-db esviritu")
        XCTAssertEqual(EsVirituRunLevel.named(record.steps.last?.outputs ?? []), final, "the run's own step names the files as they are")
        XCTAssertEqual(record.steps.first?.inputs, [read], "a step keeps the bytes it read")
        let records = try EsVirituRunLevel.records(in: result)
        XCTAssertEqual(records.count, 3, "the folder's record and the sidecars of the BAM and its index")
        XCTAssertEqual(EsVirituRunLevel.problems(of: records), [])
        let replaced = Set(EsVirituRunLevel.named([read, oldIndex]))
        for (name, envelope) in records + [("the returned record", record)] {
            let runLevel = EsVirituRunLevel.named(envelope.files + envelope.outputs + [envelope.output].compactMap { $0 })
            XCTAssertTrue(replaced.isDisjoint(with: runLevel), "\(name) names the replaced bytes at its run level, \(runLevel)")
            XCTAssertFalse(runLevel.isEmpty, name)
        }
    }

    /// Q-S2 of the pre-2.12 ARCH ruling (lane P4). The sidecar beside each BAM and index keeps, in the run's
    /// order, the steps that wrote its file, the steps without outputs that read it or the `_temp` path it came
    /// from, and the steps that name no file. So it holds the move, the `_temp` removal, the run's own step and
    /// the unnamed markdup stages of every sample, and nothing else of the other sample. A kept step keeps its
    /// inputs whole, and the run level names no file in the other sample's `bams/`.
    func testEachBAMSidecarHoldsOnlyItsOwnSampleSteps() async throws {
        let build = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 2)
        let records = try EsVirituRunLevel.records(in: build.result)
        XCTAssertEqual(EsVirituRunLevel.problems(of: records), [])
        for (name, envelope) in records where name.hasPrefix("S") {
            // Each sidecar accounts for its own gone and replaced files, as `BuiltResultRecordChecks.problems` asks of a record.
            let removed = Set(
                envelope.steps.filter { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) }
                    .flatMap(\.inputs).map { EsVirituRunLevel.resolved($0.path) }
            )
            for step in envelope.steps {
                for file in step.inputs + step.outputs {
                    guard let digest = file.checksumSHA256 else { continue }
                    let now = FileManager.default.fileExists(atPath: file.path)
                        ? ProvenanceRecorder.sha256(of: URL(fileURLWithPath: file.path)) : nil
                    if now == digest { continue }
                    XCTAssertTrue(
                        removed.contains(EsVirituRunLevel.resolved(file.path)),
                        "\(name) step \(step.toolName) names \(EsVirituRunLevel.resolved(file.path)), which is gone or holds other bytes, and no removal step of the sidecar names it"
                    )
                }
            }
        }
        let run = build.labels(of: build.record)
        let everySidecar: Set<String> = ["move", "_temp removal", "run"]
        let folderRecord = try XCTUnwrap(records.first { $0.name == ProvenanceRecorder.provenanceFilename }?.envelope)
        let wholeRecord = EsVirituRunLevel.resolved(build.result.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path)
        for (sample, other) in [("S1", "S2"), ("S2", "S1")] {
            let stem = "\(sample)/bams/\(sample).third.filt.sorted.bam"
            let bam = try XCTUnwrap(records.first { $0.name == "\(stem).lungfish-provenance.json" }?.envelope)
            let index = try XCTUnwrap(records.first { $0.name == "\(stem).bai.lungfish-provenance.json" }?.envelope)
            let bamSteps = Set(
                ["probe", "name sort", "fixmate", "coordinate sort", "markdup", "replacement", "count", "row count"].map { "\(sample) \($0)" }
            )
            let indexSteps = Set(["index", "replacement"].map { "\(sample) \($0)" })
            XCTAssertEqual(build.labels(of: bam), run.filter { everySidecar.contains($0) || bamSteps.contains($0) }, "\(sample)'s BAM")
            XCTAssertEqual(build.labels(of: index), run.filter { everySidecar.contains($0) || indexSteps.contains($0) }, "\(sample)'s index")
            let otherFolder = EsVirituRunLevel.resolved(build.result.appendingPathComponent(other).path) + "/"
            for (name, envelope) in [("BAM", bam), ("index", index)] {
                let named = envelope.files + envelope.steps.flatMap { $0.inputs + $0.outputs }
                XCTAssertEqual(
                    EsVirituRunLevel.named(named).filter { $0.path.hasPrefix(otherFolder) }, [],
                    "the sidecar of \(sample)'s \(name) names a file of \(other)"
                )
                let narrowed = envelope.steps.filter { $0.narrowedFrom != nil }
                XCTAssertEqual(narrowed.map { build.labels[$0.id] ?? $0.toolName }, ["move", "_temp removal", "run"].filter { run.contains($0) })
                for step in narrowed {
                    // ARCH 5. The whole step is the narrowed one with its inputs, outputs and narrowing put back.
                    let whole = try XCTUnwrap(folderRecord.steps.first { $0.id == step.id }, "the folder record holds \(step.toolName)")
                    XCTAssertTrue(step.inputs.allSatisfy(whole.inputs.contains), "\(step.toolName) keeps a subset of its inputs")
                    XCTAssertLessThan(step.inputs.count, whole.inputs.count, step.toolName)
                    XCTAssertEqual(step.narrowedFrom?.inputCount, whole.inputs.count, step.toolName)
                    XCTAssertEqual(step.narrowedFrom.map { EsVirituRunLevel.resolved($0.recordPath) }, wholeRecord, step.toolName)
                    XCTAssertEqual(
                        folderRecord.steps.first { $0.id == step.id },
                        step.with { $0.inputs = whole.inputs; $0.outputs = whole.outputs; $0.narrowedFrom = nil },
                        "\(sample)'s \(name) narrowed only the inputs, the outputs and the one field of \(step.toolName)"
                    )
                }
            }
        }
    }

    /// Q-A3 items 1 and 5. A BAM's sidecar holds its own sample's steps and files, so it holds as many in a batch
    /// of four samples as in a batch of two.
    func testABAMSidecarDoesNotGrowWithTheSampleCount() async throws {
        var sizes: [[Int]] = []
        for samples in [["S1", "S2"], ["S1", "S2", "S3", "S4"]] {
            let folder = root.appendingPathComponent("\(samples.count)", isDirectory: true)
            let build = try await EsVirituRunLevel.markdupBuild(in: folder, samples: samples, rows: 2)
            let sidecar = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(
                fromSidecar: ProvenanceRecorder.fileSidecarURL(for: build.result.appendingPathComponent("S1/bams/S1.third.filt.sorted.bam"))
            ))
            sizes.append([sidecar.steps.count, sidecar.files.count, sidecar.steps.map(\.inputs.count).reduce(0, +)])
        }
        XCTAssertEqual(sizes.first, sizes.last, "steps, files and step inputs of S1's BAM sidecar in a batch of 2 and of 4")
    }

    /// Q-A3 item 1. A rerun over BAMs already in `bams/` and not yet marked has no move, and its run step reads
    /// every BAM. A BAM's sidecar names none of the other sample's BAM or index bytes.
    func testARerunOverUnmarkedBAMsNamesNoOtherSampleBytes() async throws {
        let first = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 1)
        for sample in ["S1", "S2"] {
            try Data("unmarked BAM of \(sample)\n".utf8).write(to: first.result.appendingPathComponent("\(sample)/bams/\(sample).third.filt.sorted.bam"))
        }
        let rerun = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 1, over: first.result)

        let otherBytes = Set(rerun.record.steps.flatMap { $0.inputs + $0.outputs }
            .filter { $0.path.contains("/S2/") && $0.path.contains(".bam") }.compactMap(\.checksumSHA256))
        XCTAssertFalse(otherBytes.isEmpty)
        let sidecar = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: rerun.result.appendingPathComponent("S1/bams/S1.third.filt.sorted.bam"))
        ))
        let named = Set((sidecar.files + sidecar.steps.flatMap { $0.inputs + $0.outputs }).compactMap(\.checksumSHA256))
        XCTAssertEqual(named.intersection(otherBytes), [], "S1's sidecar names bytes of S2")
        XCTAssertEqual(sidecar.steps.filter { $0.narrowedFrom != nil }.map { rerun.labels[$0.id] }, ["run"])
    }

    /// The sidecar beside `sample`'s BAM in `result`, or beside its index.
    private func sidecarEnvelope(of sample: String, index: Bool = false, in result: URL) throws -> ProvenanceEnvelope {
        let file = result.appendingPathComponent("\(sample)/bams/\(sample).third.filt.sorted.bam\(index ? ".bai" : "")")
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: file)), file.path)
    }

    /// Q-A3 item 4, the CLI route (review of lane 13.15 M2, BIO fix 2). A result folder that holds another
    /// workflow's record keeps it, since build-db never replaces a classifier run's record. No record of this run
    /// then holds its steps whole, so no sidecar narrows a step and each keeps every input.
    func testAFolderWithAnotherWorkflowsRecordKeepsEveryStepWhole() async throws {
        let build = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 2, foreignRecordOf: "EsViritu")
        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: build.result)?.workflowName, "EsViritu", "the folder keeps the record it held")
        for sample in ["S1", "S2"] {
            for index in [false, true] {
                let sidecar = try sidecarEnvelope(of: sample, index: index, in: build.result)
                XCTAssertEqual(sidecar.steps.compactMap(\.narrowedFrom), [], "\(sample)'s sidecar (index \(index)) names a whole record")
            }
        }
        let move = try XCTUnwrap(build.record.steps.first { build.labels[$0.id] == "move" })
        let bam = try sidecarEnvelope(of: "S1", in: build.result)
        let keptMove = try XCTUnwrap(bam.steps.first { $0.id == move.id }, "the BAM sidecar holds the move")
        XCTAssertEqual(keptMove.inputs, move.inputs, "the move in S1's BAM sidecar keeps every file it moved")
    }

    /// Q-A3 item 4, the executor route (review of lane 13.15 M2, BIO fix 2). The analysis run executor runs
    /// `build-db esviritu` with no folder record of its own and writes the root record in the same folder from the
    /// steps it is handed, each under its own id. So a narrowed step names the root that will stand there, and the
    /// step is among the steps the executor is handed (`EsVirituCommand+Index.swift` returns `built.record.steps`).
    func testTheExecutorRouteNamesTheRootItWillWrite() async throws {
        let build = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 2, writesFolderRecord: false)
        let rootRecord = build.result.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootRecord.path), "the run writes no folder record, the executor writes the root")
        let sidecar = try sidecarEnvelope(of: "S1", in: build.result)
        let narrowed = sidecar.steps.filter { $0.narrowedFrom != nil }
        XCTAssertEqual(narrowed.map { build.labels[$0.id] }, ["move", "_temp removal", "run"], "the steps that read every sample are narrowed")
        for step in narrowed {
            let whole = try XCTUnwrap(build.record.steps.first { $0.id == step.id }, "the executor hands the root \(step.toolName) under its id")
            XCTAssertEqual(step.narrowedFrom.map { EsVirituRunLevel.resolved($0.recordPath) }, EsVirituRunLevel.resolved(rootRecord.path), step.toolName)
            XCTAssertEqual(step.narrowedFrom?.inputCount, whole.inputs.count, step.toolName)
        }
    }

    /// Q-A3 item 4 and ARCH B5 (review of lane 13.15 M2, ARCH fix 3). In a folder that holds another workflow's
    /// record no record of this run holds a step whole, so no sidecar narrows one and the sidecar of each BAM and
    /// each index, of both samples, keeps today's whole steps. The move keeps every file it moved, the removal
    /// every path it removed and the run's step its inputs. A sidecar still holds none of the other sample's
    /// `fixmate` and coordinate `sort`, since items 2 and 5 need no whole record.
    func testAFolderThatHoldsAnotherWorkflowsRecordKeepsEverySidecarStepWhole() async throws {
        let build = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 2, foreignRecordOf: "EsViritu")
        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: build.result)?.workflowName, "EsViritu", "the folder keeps the record it held")
        var wholeSteps: [(label: String, step: ProvenanceStep)] = []
        for label in ["move", "_temp removal", "run"] {
            let step = try XCTUnwrap(build.record.steps.first { build.labels[$0.id] == label }, label)
            wholeSteps.append((label: label, step: step))
        }
        for (sample, other) in [("S1", "S2"), ("S2", "S1")] {
            for index in [false, true] {
                let kind = index ? "index" : "BAM"
                let sidecar = try sidecarEnvelope(of: sample, index: index, in: build.result)
                XCTAssertEqual(sidecar.steps.compactMap(\.narrowedFrom), [], "\(sample)'s \(kind) sidecar narrows no step")
                for (label, whole) in wholeSteps {
                    let kept = try XCTUnwrap(sidecar.steps.first { $0.id == whole.id }, "\(sample)'s \(kind) sidecar holds the \(label)")
                    XCTAssertEqual(kept.inputs, whole.inputs, "the \(label) in \(sample)'s \(kind) sidecar keeps every input")
                }
                XCTAssertEqual(
                    build.labels(of: sidecar).filter { $0 == "\(other) fixmate" || $0 == "\(other) coordinate sort" }, [],
                    "\(sample)'s \(kind) sidecar holds a stage of \(other)'s duplicate marking"
                )
            }
        }
    }

    /// The database's sidecar stays today's projection of the run (`focusedOnOutput`), with every step that has
    /// no outputs, among them the counts behind `read_count` and `unique_reads`, so it stays the one complete
    /// record of the run (Q-S2, ARCH 7). A pin that passes at the base and after.
    func testTheDatabaseSidecarKeepsTodaysProjectionOfTheRun() async throws {
        let build = try await EsVirituRunLevel.markdupBuild(in: root, samples: ["S1", "S2"], rows: 2)
        let database = build.result.appendingPathComponent("esviritu.sqlite")
        let output = try XCTUnwrap(build.record.outputs.first {
            EsVirituRunLevel.resolved($0.path) == EsVirituRunLevel.resolved(database.path)
        })
        let stored = try Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: database))
        let sidecar = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: stored)
        let today = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self, from: ProvenanceJSON.encoder.encode(build.record.focusedOnOutput(output))
        )
        // `with` clears the signature references that a key in the environment makes the writer add to the file.
        XCTAssertEqual(sidecar.with { _ in }, today.with { _ in }, "the database's sidecar is today's projection of the run")
        let runStep = build.record.steps.last?.id
        XCTAssertEqual(
            build.labels(of: sidecar),
            build.labels(of: build.record.with { $0.steps = $0.steps.filter { $0.outputs.isEmpty || $0.id == runStep } }),
            "it keeps every step without outputs and the run's own step"
        )
    }
}

/// The live form, over the BAMs of `esviritu-mini` with the managed samtools, whose markdup rewrites each
/// BAM in place and indexes it again (2.9 O5). `LUNGFISH_REQUIRE_TOOLS=1` turns a missing samtools into a
/// failure. `BuildDbEsVirituRunLevelTests` is the stand-in form.
final class BuildDbEsVirituRunLevelLiveConformanceTests: XCTestCase {
    func testEveryRecordOfAMarkdupBuildNamesTheBAMWhereItEnds() async throws {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let root = try TestTempDirectory.make(prefix: "BuildDbEsVirituRunLevelLive")
        defer { TestTempDirectory.cleanup(root) }
        let result = root.appendingPathComponent("esviritu-mini", isDirectory: true)
        try FileManager.default.copyItem(at: BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-mini"), to: result)
        let before = try EsVirituRunLevel.digests(ofTempFilesIn: result)

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "-q"]).run()

        let records = try EsVirituRunLevel.records(in: result)
        let folderRecord = try XCTUnwrap(records.first { $0.name == ProvenanceRecorder.provenanceFilename }?.envelope)
        XCTAssertTrue(
            folderRecord.steps.contains { $0.toolName == "Lungfish Markdup Replacement" },
            "the markdup rewrote a BAM in place, \(folderRecord.steps.map(\.toolName))"
        )
        XCTAssertEqual(EsVirituRunLevel.problems(of: records), [])
        try EsVirituRunLevel.assertTheRecordNamesEachBAMWhereItEnds(folderRecord, in: result)
        let removal = try XCTUnwrap(folderRecord.steps.first { $0.toolName == "Lungfish EsViritu BAM Relocation Source Removal" })
        XCTAssertEqual(EsVirituRunLevel.sorted(removal.inputs), before, "the removal names each file the move took from _temp/")
    }
}

/// What the run-level tests stage and read.
enum EsVirituRunLevel {
    /// A named file by its resolved path, with its digest.
    struct Named: Hashable, CustomStringConvertible {
        let path: String
        let digest: String?

        var description: String { "\(path) \(digest.map { String($0.prefix(12)) } ?? "with no digest")" }
    }

    /// The path with its deepest existing folder resolved, since a removed file or folder cannot be, so that
    /// /var/folders and /private/var/folders are one place.
    static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    static func named(_ files: [ProvenanceFileDescriptor]) -> [Named] {
        files.map { Named(path: resolved($0.path), digest: $0.checksumSHA256) }
    }

    /// `files` named in path order, since the move takes the sample folders in the order the folder lists them.
    static func sorted(_ files: [ProvenanceFileDescriptor]) -> [Named] {
        named(files).sorted { $0.path < $1.path }
    }

    /// Where the move puts a file of `<sample>/<sample>_temp/`, which is `<sample>/bams/`.
    static func movedPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let bams = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bams", isDirectory: true)
        return resolved(bams.appendingPathComponent(url.lastPathComponent).path)
    }

    /// The header of EsViritu's detection table, as `BuildDbCommandEsVirituCleanupTests` writes it.
    static let detectionHeader = [
        "sample_ID", "name", "description", "length", "segment", "accession", "assembly", "assembly_length", "kingdom",
        "phylum", "class", "order", "family", "genus", "species", "subspecies", "rpkmf", "read_count", "covered_bases",
        "mean_coverage", "avg_read_identity", "pi", "filtered_reads_in_sample",
    ].joined(separator: "\t")

    /// A batch result whose samples each hold a detection table with its header only and a placeholder BAM
    /// and index in `<sample>_temp/`.
    static func standInResult(in root: URL, samples: [String]) throws -> URL {
        let result = root.appendingPathComponent("esviritu-batch", isDirectory: true)
        for sample in samples {
            let folder = result.appendingPathComponent(sample, isDirectory: true)
            let temp = folder.appendingPathComponent("\(sample)_temp", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try Data((detectionHeader + "\n").utf8).write(to: folder.appendingPathComponent("\(sample).detected_virus.info.tsv"))
            try Data("stand-in BAM of \(sample)\n".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam"))
            try Data("stand-in index of \(sample)\n".utf8).write(to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam.bai"))
        }
        return result
    }

    /// A stand-in `build-db esviritu` run whose markdup pass and read counts ran, with the record that
    /// `recordBuildDbProvenance` wrote and a label for each of its steps.
    struct MarkdupBuild {
        let result: URL
        let record: ProvenanceEnvelope
        let labels: [UUID: String]

        /// The label of each step `envelope` holds, in its order.
        func labels(of envelope: ProvenanceEnvelope) -> [String] {
            envelope.steps.map { labels[$0.id] ?? "unlabeled \($0.toolName)" }
        }
    }

    /// Builds `samples` the way the command records them, from its own move and removal steps and samtools steps
    /// in the shapes `BuildDbSamtoolsProvenanceTracker` records. Each sample's BAM and index move from `_temp/` to
    /// `bams/` from the folder listing, as `relocateEsVirituBAMs` moves them, so the move names `/private/var` where
    /// the samtools steps name `/var`. Each BAM in path order then gets a header probe, the name sort that reads it,
    /// the fixmate and coordinate sort that name no file, the markdup, its index, the replacement of its old bytes
    /// and two counts. Two counts follow for each of `rows` detections of each sample, the `_temp` folders go and
    /// their removal is a step, and the record of a stand-in database is written.
    /// Over `existing`, a result whose BAMs are already in `bams/`, it builds again with no move and no removal of
    /// `_temp`, as a rerun does. Each markdup stage after the first depends on the stage before it (Q-A3 item 5).
    /// With `foreignRecordOf` the folder already holds a record of that workflow, as a classifier run leaves it, and
    /// with `writesFolderRecord` false the run writes no folder record, as on the executor route (Q-A3 item 4).
    static func markdupBuild(
        in root: URL, samples: [String], rows: Int, over existing: URL? = nil,
        foreignRecordOf workflow: String? = nil, writesFolderRecord: Bool = true
    ) async throws -> MarkdupBuild {
        let fileManager = FileManager.default
        let result = try existing ?? standInResult(in: root, samples: samples)
        let inputs = BuildDbCommand.buildDbInputRecords(tool: .esViritu, resultURL: result)
        let clock = ProvenanceRunClock()
        var steps: [ProvenanceStep] = []
        var labels: [UUID: String] = [:]
        func add(_ step: ProvenanceStep, _ label: String) {
            steps.append(step)
            labels[step.id] = label
        }
        func samtools(
            _ arguments: [String], inputs: [ProvenanceFileDescriptor] = [], outputs: [ProvenanceFileDescriptor] = [],
            afterTheLastStep: Bool = false
        ) -> ProvenanceStep {
            ProvenanceStep(
                toolName: "samtools", toolVersion: "stand-in", argv: ["samtools"] + arguments, inputs: inputs, outputs: outputs,
                exitStatus: 0, wallTimeSeconds: 0, stderr: nil, dependsOn: afterTheLastStep ? steps.suffix(1).map(\.id) : [],
                startedAt: clock.startedAt, completedAt: clock.now
            )
        }

        var moved: [(source: URL, destination: URL)] = []
        for folder in try fileManager.contentsOfDirectory(at: result, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
        where existing == nil {
            let sample = folder.lastPathComponent
            let bams = folder.appendingPathComponent("bams", isDirectory: true)
            try fileManager.createDirectory(at: bams, withIntermediateDirectories: true)
            for name in ["\(sample).third.filt.sorted.bam", "\(sample).third.filt.sorted.bam.bai"] {
                let move = (source: folder.appendingPathComponent("\(sample)_temp/\(name)"), destination: bams.appendingPathComponent(name))
                try fileManager.moveItem(at: move.source, to: move.destination)
                moved.append(move)
            }
        }
        let move = BuildDbCommand.EsVirituSubcommand.bamRelocationStep(moved, resultURL: result, recordedInputs: inputs, clock: clock)
        XCTAssertEqual(move == nil, existing != nil, "a first build moves the BAMs and a rerun does not")
        if let move { add(move, "move") }

        let bamURLs = samples.sorted().map { (sample: $0, url: result.appendingPathComponent("\($0)/bams/\($0).third.filt.sorted.bam")) }
        for (sample, bam) in bamURLs {
            let index = URL(fileURLWithPath: bam.path + ".bai")
            let read = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .input)
            let oldIndex = try ProvenanceFileDescriptor.file(url: index, role: .index)
            let scratch = bam.path + ".markdup.tmp"
            add(samtools(["view", "-H", bam.path], inputs: [read]), "\(sample) probe")
            add(samtools(["sort", "-n", "-o", scratch + ".name.bam", bam.path], inputs: [read]), "\(sample) name sort")
            add(samtools(["fixmate", "-m", scratch + ".name.bam", scratch + ".fixmate.bam"], afterTheLastStep: true), "\(sample) fixmate")
            add(samtools(["sort", "-o", scratch + ".sorted.bam", scratch + ".fixmate.bam"], afterTheLastStep: true), "\(sample) coordinate sort")
            try Data("BAM of \(sample) after markdup\n".utf8).write(to: bam)
            try Data("index of \(sample) after markdup\n".utf8).write(to: index)
            let marked = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .output)
            add(samtools(["markdup", scratch + ".sorted.bam", scratch], outputs: [marked], afterTheLastStep: true), "\(sample) markdup")
            let newIndex = try ProvenanceFileDescriptor.file(url: index, role: .index)
            add(samtools(["index", bam.path], inputs: [marked], outputs: [newIndex], afterTheLastStep: true), "\(sample) index")
            add(try XCTUnwrap(RecordedRemovalStep.step(
                toolName: "Lungfish Markdup Replacement", api: "FileManager.replaceItemAt(_:withItemAt:)",
                removing: [read, oldIndex], clock: clock
            )), "\(sample) replacement")
            let counted = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .input)
            for flags in ["4", "1028"] {
                add(samtools(["view", "-c", "-F", flags, bam.path], inputs: [counted]), "\(sample) count")
            }
        }
        for (sample, bam) in bamURLs {
            let counted = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .input)
            for row in 1...rows {
                for flags in ["3332", "2308"] {
                    add(samtools(["view", "-c", "-F", flags, bam.path, "ACC\(row)"], inputs: [counted]), "\(sample) row count")
                }
            }
        }
        if let move {
            for sample in samples {
                try fileManager.removeItem(at: result.appendingPathComponent("\(sample)/\(sample)_temp", isDirectory: true))
            }
            add(try XCTUnwrap(BuildDbCommand.EsVirituSubcommand.relocationSourceRemovalStep([move], clock: clock)), "_temp removal")
        }

        let database = result.appendingPathComponent("esviritu.sqlite")
        try Data("stand-in database\n".utf8).write(to: database)
        if let workflow {
            // A folder that holds another workflow's record, as a classifier run leaves it (Q-A3 item 4).
            let table = result.appendingPathComponent("\(samples[0])/\(samples[0]).detected_virus.info.tsv")
            let written = try ProvenanceFileDescriptor.file(url: table, role: .output)
            let foreign = try ProvenanceRunBuilder(
                workflowName: workflow, workflowVersion: "test", toolName: "stand-in", toolVersion: "stand-in"
            )
            .argv(["lungfish-cli", "stand-in", result.path])
            .runtime(ProvenanceRuntimeIdentity())
            .output(table, role: .output)
            .step(ProvenanceStep(
                toolName: "stand-in", toolVersion: "stand-in", argv: ["stand-in"], outputs: [written],
                exitStatus: 0, wallTimeSeconds: 0
            ))
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
            try ProvenanceWriter().write(foreign, to: result)
        }
        let record = try await BuildDbCommand.recordBuildDbProvenance(
            tool: .esViritu, resultURL: result, dbURL: database, force: true, noCleanup: false,
            globalOptions: try GlobalOptions.parse([]), runClock: clock, inputRecords: inputs, additionalSteps: steps,
            writesFolderRecord: writesFolderRecord,
            events: BuildDbEventSink(progress: { _, _ in }, text: { _ in }, textWarning: { _ in }, warning: { _ in })
        )
        if let runStep = record.steps.last {
            labels[runStep.id] = "run"
        }
        return MarkdupBuild(result: result, record: record, labels: labels)
    }

    /// Each file in a `_temp/` folder of `result`, in path order, with its digest.
    static func digests(ofTempFilesIn result: URL) throws -> [Named] {
        let files = FileManager.default.enumerator(at: result, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.deletingLastPathComponent().lastPathComponent.hasSuffix("_temp") } ?? []
        return try files.map { Named(path: resolved($0.path), digest: try XCTUnwrap(ProvenanceRecorder.sha256(of: $0))) }
            .sorted { $0.path < $1.path }
    }

    /// Every record in `result` with its path below it, the folder's records and each file's sidecar.
    static func records(in result: URL) throws -> [(name: String, envelope: ProvenanceEnvelope)] {
        let urls = FileManager.default.enumerator(at: result, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(ProvenanceRecorder.provenanceFilename) } ?? []
        let prefix = resolved(result.path) + "/"
        return try urls.map { url in
            let envelope = url.lastPathComponent == ProvenanceRecorder.provenanceFilename
                ? ProvenanceRecorder.loadEnvelope(from: url.deletingLastPathComponent())
                : ProvenanceRecorder.loadEnvelope(fromSidecar: url)
            return (String(resolved(url.path).dropFirst(prefix.count)), try XCTUnwrap(envelope, url.path))
        }
        .sorted { $0.name < $1.name }
    }

    /// Each file a record names that is gone or holds other bytes than the record states, and that the
    /// result does not account for, one line each, as the classifier parity's named-file rule reads them
    /// (P1 of Phase 2.8, B3). A step's naming is accounted for by a removal step of the result that names
    /// the path, with the stated digest when the file holds other bytes, and that comes no earlier when
    /// both stand in one record, or by a later step of the record that reads the same bytes. The run level
    /// names every file as it is, and nothing in `_temp/`.
    static func problems(of records: [(name: String, envelope: ProvenanceEnvelope)]) -> [String] {
        var digests: [String: String?] = [:]
        func current(_ path: String) -> String?? {
            guard FileManager.default.fileExists(atPath: path) else { return .none }
            if let known = digests[path] { return .some(known) }
            let digest = ProvenanceRecorder.sha256(of: URL(fileURLWithPath: path))
            digests[path] = digest
            return .some(digest)
        }
        let removals = records.flatMap { record in
            record.envelope.steps.enumerated()
                .filter { $0.element.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) }
                .flatMap { index, step in step.inputs.map { (record: record.name, step: index, named: Named(path: resolved($0.path), digest: $0.checksumSHA256)) } }
        }
        var lines: Set<String> = []
        for record in records {
            let steps = record.envelope.steps
            for (index, step) in steps.enumerated() {
                for file in step.inputs + step.outputs {
                    guard let digest = file.checksumSHA256 else { continue }
                    let found = current(file.path)
                    guard found == nil || found! != digest else { continue }
                    let gone = found == nil
                    let path = resolved(file.path)
                    let removed = removals.contains {
                        $0.named.path == path && ($0.record != record.name || $0.step >= index) && (gone || $0.named.digest == digest)
                    }
                    let readLater = steps[(index + 1)...].contains { later in
                        later.inputs.contains { resolved($0.path) == path && $0.checksumSHA256 == digest }
                    }
                    if !removed, !readLater {
                        lines.insert("\(record.name) step \(index) \(step.toolName) names \(path) \(gone ? "that does not exist" : "with another digest")")
                    }
                }
            }
            for file in record.envelope.files + record.envelope.outputs + [record.envelope.output].compactMap({ $0 }) {
                let path = resolved(file.path)
                if path.contains("_temp/") { lines.insert("\(record.name) run level names \(path) in _temp/") }
                switch current(file.path) {
                case .none: lines.insert("\(record.name) run level names \(path) that does not exist")
                case .some(let found) where file.checksumSHA256 != nil && found != file.checksumSHA256:
                    lines.insert("\(record.name) run level names \(path) with another digest")
                default: break
                }
            }
        }
        return lines.sorted()
    }

    /// The folder's record names each BAM and index in a `bams/` folder of `result` as an output with the
    /// digest of the file there.
    static func assertTheRecordNamesEachBAMWhereItEnds(
        _ record: ProvenanceEnvelope, in result: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let kept = FileManager.default.enumerator(at: result, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.deletingLastPathComponent().lastPathComponent == "bams" && !$0.lastPathComponent.hasSuffix(ProvenanceRecorder.provenanceFilename) } ?? []
        XCTAssertFalse(kept.isEmpty, "the move kept files in bams/", file: file, line: line)
        let outputs = Set(named(record.outputs))
        for url in kept {
            let now = Named(path: resolved(url.path), digest: ProvenanceRecorder.sha256(of: url))
            XCTAssertTrue(outputs.contains(now), "the record names \(now) as an output, \(outputs)", file: file, line: line)
        }
    }
}
