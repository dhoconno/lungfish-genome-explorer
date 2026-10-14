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
