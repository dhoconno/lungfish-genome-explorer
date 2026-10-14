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
}
