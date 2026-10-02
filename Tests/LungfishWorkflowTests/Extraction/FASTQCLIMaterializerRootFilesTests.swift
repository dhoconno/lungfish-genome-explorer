// FASTQCLIMaterializerRootFilesTests.swift - The materializer reads every file of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A bundle that holds several files (an ONT import or a merged bundle, listed
// in source-files.json) is every one of them, and a derivative of such a root
// applies its recipe to every one of them. FASTQCLIMaterializer used to return
// the first file of a physical multi-file bundle and read one file of a root,
// so a dashboard derivative of an ONT import covered chunk 0 and could not be
// materialized at all once it recorded the chunk's bare name (R3, lane 1x).
//
// Trim and orientation materialization are pure Swift. Subsets run seqkit,
// so those tests skip when the managed seqkit is not installed.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQCLIMaterializerRootFilesTests: XCTestCase {
    private var root: URL!
    private var imports: URL!
    private var work: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("materializer-root-files-\(UUID().uuidString)", isDirectory: true)
        imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    /// Read names say which chunk a read came from, and every sequence is
    /// distinct so a trimmed or reverse-complemented record is recognisable.
    private static let sequences: [String: String] = [
        "m1": "AAAACCCCGG", "m2": "TTTTGGGGAA",
        "m3": "ACGTACGTAC", "m4": "GGGGCCCCAA", "m5": "TTTTAAAACC",
    ]

    private static func fastq(_ names: [String]) -> String {
        names.map { name in
            let sequence = sequences[name] ?? "ACGTACGTAC"
            return "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
    }

    private func makeMultiFileRoot() throws -> (bundle: URL, chunks: [URL]) {
        let bundle = imports.appendingPathComponent("multi.lungfishfastq", isDirectory: true)
        let chunksDirectory = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        let chunks = [
            chunksDirectory.appendingPathComponent("run_0.fastq"),
            chunksDirectory.appendingPathComponent("run_1.fastq"),
        ]
        try Self.fastq(["m1", "m2"]).write(to: chunks[0], atomically: true, encoding: .utf8)
        try Self.fastq(["m3", "m4", "m5"]).write(to: chunks[1], atomically: true, encoding: .utf8)
        try Self.fastq(["m1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        return (bundle, chunks)
    }

    /// A single-file root holding exactly chunk 0's reads, the root the old
    /// materializer effectively read.
    private func makeChunkZeroRoot() throws -> (bundle: URL, file: URL) {
        let bundle = imports.appendingPathComponent("chunk-zero.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("run_0.fastq")
        try Self.fastq(["m1", "m2"]).write(to: file, atomically: true, encoding: .utf8)
        return (bundle, file)
    }

    private func makeSingleFileRoot() throws -> (bundle: URL, file: URL) {
        let bundle = imports.appendingPathComponent("single.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("single.fastq")
        try Self.fastq(["m3", "m4"]).write(to: file, atomically: true, encoding: .utf8)
        return (bundle, file)
    }

    /// A virtual derivative over `rootBundle`, as the dashboard writes one.
    @discardableResult
    private func makeDerived(
        named name: String,
        root rootBundle: URL,
        rootFile: String,
        payload: FASTQDerivativePayload,
        files: [String: String],
        kind: FASTQDerivativeOperationKind = .lengthFilter
    ) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (filename, content) in files {
            try content.write(to: bundle.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let operation = FASTQDerivativeOperation(kind: kind)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "@/Imports/\(rootBundle.lastPathComponent)",
                rootBundleRelativePath: "@/Imports/\(rootBundle.lastPathComponent)",
                rootFASTQFilename: rootFile,
                payload: payload,
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    private func trimTable(_ rows: [(key: String, start: Int, end: Int)]) -> String {
        FASTQTrimPositionFile.formatHeader + "\nread_id\tmate\ttrim_start\ttrim_end\n"
            + rows.map { "\($0.key)\t0\t\($0.start)\t\($0.end)\n" }.joined()
    }

    private func materialize(_ bundle: URL) async throws -> URL {
        let directory = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundle, tempDirectory: directory)
    }

    private func records(_ url: URL) async throws -> [(id: String, sequence: String)] {
        var result: [(String, String)] = []
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            result.append((record.identifier, record.sequence))
        }
        return result
    }

    private func names(_ url: URL) async throws -> [String] {
        try await records(url).map(\.id)
    }

    private func requireSeqkit() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
    }

    // MARK: - Physical bundles

    func testAPhysicalMultiFileBundleMaterializesToEveryFileInManifestOrder() async throws {
        let multi = try makeMultiFileRoot()
        let materialized = try await materialize(multi.bundle)

        let materializedNames = try await names(materialized)
        XCTAssertEqual(materializedNames, ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertTrue(materialized.standardizedFileURL.path.hasPrefix(work.standardizedFileURL.path + "/"), "a joined copy, not a chunk")
        let concatenation = try XCTUnwrap(SequenceInputConcatenation.load(for: materialized), "the join leaves its sidecar")
        XCTAssertEqual(concatenation.memberURLs.map(\.standardizedFileURL.path), multi.chunks.map(\.standardizedFileURL.path))
        XCTAssertEqual(concatenation.bundleURL.standardizedFileURL.path, multi.bundle.standardizedFileURL.path)
    }

    func testASingleFileBundleMaterializesToItsFileInPlace() async throws {
        let single = try makeSingleFileRoot()
        let materialized = try await materialize(single.bundle)
        XCTAssertEqual(materialized.standardizedFileURL.path, single.file.standardizedFileURL.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).filter { !$0.hasPrefix(".") }.count, 1, "nothing but the empty temp folder was written")
    }

    // MARK: - Subsets (seqkit)

    func testASubsetOverAMultiFileRootSelectsReadsFromEveryFile() async throws {
        try await requireSeqkit()
        let multi = try makeMultiFileRoot()
        let derived = try makeDerived(
            named: "subset", root: multi.bundle, rootFile: "chunks/run_0.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            files: ["read-ids.txt": "m1\nm4\n", "preview.fastq": Self.fastq(["m1"])]
        )
        let materializedNames = try await names(try await materialize(derived))
        XCTAssertEqual(materializedNames, ["m1", "m4"])
    }

    /// Every dashboard derivative of an ONT or merged root on disk today
    /// records the chunk's bare name and could not be materialized at all.
    /// After the change it materializes to the reads its list names, which
    /// are chunk 0's, byte for byte what a single-file root of chunk 0 gives.
    func testABareNameRecordedBeforeLane1xMaterializesTheReadsItsListNames() async throws {
        try await requireSeqkit()
        let multi = try makeMultiFileRoot()
        let chunkZero = try makeChunkZeroRoot()
        let files = ["read-ids.txt": "m1\nm2\n", "preview.fastq": Self.fastq(["m1"])]
        let overMulti = try makeDerived(
            named: "old-subset", root: multi.bundle, rootFile: "run_0.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"), files: files
        )
        let overChunkZero = try makeDerived(
            named: "chunk-zero-subset", root: chunkZero.bundle, rootFile: "run_0.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"), files: files
        )

        let fromMulti = try await materialize(overMulti)
        let fromChunkZero = try await materialize(overChunkZero)
        let fromMultiNames = try await names(fromMulti)
        XCTAssertEqual(fromMultiNames, ["m1", "m2"])
        XCTAssertEqual(try Data(contentsOf: fromMulti), try Data(contentsOf: fromChunkZero), "byte-identical to the chunk-0 root")
    }

    func testADemuxedVirtualOverAMultiFileRootSelectsAndOrientsReadsFromEveryFile() async throws {
        try await requireSeqkit()
        let multi = try makeMultiFileRoot()
        let derived = try makeDerived(
            named: "demuxed", root: multi.bundle, rootFile: "chunks/run_0.fastq",
            payload: .demuxedVirtual(
                barcodeID: "bc01", readIDListFilename: "read-ids.txt", previewFilename: "preview.fastq",
                trimPositionsFilename: nil, orientMapFilename: "orient-map.tsv"
            ),
            files: ["read-ids.txt": "m2\nm3\n", "orient-map.tsv": "m2\t+\nm3\t-\n", "preview.fastq": Self.fastq(["m2"])],
            kind: .demultiplex
        )
        let materialized = try await records(try await materialize(derived))
        XCTAssertEqual(materialized.map(\.id), ["m2", "m3"])
        XCTAssertEqual(materialized.map(\.sequence), ["TTTTGGGGAA", "GTACGTACGT"], "m3 comes back reverse complemented")
    }

    // MARK: - Trims (pure Swift)

    func testATrimOverAMultiFileRootTrimsReadsFromEveryFile() async throws {
        let multi = try makeMultiFileRoot()
        let derived = try makeDerived(
            named: "trim", root: multi.bundle, rootFile: "chunks/run_0.fastq",
            payload: .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
            files: [FASTQBundle.trimPositionFilename: trimTable([("m2#0", 2, 8), ("m5#0", 0, 5)])],
            kind: .fixedTrim
        )
        let materialized = try await records(try await materialize(derived))
        XCTAssertEqual(materialized.map(\.id), ["m2", "m5"])
        XCTAssertEqual(materialized.map(\.sequence), ["TTGGGG", "TTTTA"])
    }

    /// A trim table made over chunk 0 alone keys its rows `id#0`, the first
    /// occurrence of each ID in the root stream. Streaming every member with
    /// chunk 0 first resolves the same rows to the same records, so the old
    /// derivative materializes byte for byte as it would over chunk 0 alone,
    /// whether it recorded the member path or the bare name.
    func testAChunkZeroOnlyTrimTableMaterializesByteIdenticallyOverEveryMember() async throws {
        let multi = try makeMultiFileRoot()
        let chunkZero = try makeChunkZeroRoot()
        let table = trimTable([("m1#0", 1, 9), ("m2#0", 3, 10)])
        let expected = try await materialize(try makeDerived(
            named: "chunk-zero-trim", root: chunkZero.bundle, rootFile: "run_0.fastq",
            payload: .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
            files: [FASTQBundle.trimPositionFilename: table], kind: .fixedTrim
        ))
        for (name, rootFile) in [("member-path-trim", "chunks/run_0.fastq"), ("bare-name-trim", "run_0.fastq")] {
            let materialized = try await materialize(try makeDerived(
                named: name, root: multi.bundle, rootFile: rootFile,
                payload: .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
                files: [FASTQBundle.trimPositionFilename: table], kind: .fixedTrim
            ))
            XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: expected), "\(rootFile)")
            let sequences = try await records(materialized).map(\.sequence)
            XCTAssertEqual(sequences, ["AAACCCCG", "TGGGGAA"], "\(rootFile)")
        }
    }

    // MARK: - Orientation maps (pure Swift)

    func testAnOrientMapOverAMultiFileRootOrientsReadsFromEveryFile() async throws {
        let multi = try makeMultiFileRoot()
        let derived = try makeDerived(
            named: "oriented", root: multi.bundle, rootFile: "chunks/run_0.fastq",
            payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
            files: ["orient-map.tsv": "m1\t+\nm4\t-\n", "preview.fastq": Self.fastq(["m1"])],
            kind: .orient
        )
        let materialized = try await records(try await materialize(derived))
        XCTAssertEqual(materialized.map(\.id), ["m1", "m4"])
        XCTAssertEqual(materialized.map(\.sequence), ["AAAACCCCGG", "TTGGGGCCCC"], "m4 comes back reverse complemented")
    }

    func testAChunkZeroOnlyOrientMapMaterializesByteIdenticallyOverEveryMember() async throws {
        let multi = try makeMultiFileRoot()
        let chunkZero = try makeChunkZeroRoot()
        let files = ["orient-map.tsv": "m1\t-\nm2\t+\n", "preview.fastq": Self.fastq(["m1"])]
        let payload = FASTQDerivativePayload.orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq")
        let expected = try await materialize(try makeDerived(
            named: "chunk-zero-oriented", root: chunkZero.bundle, rootFile: "run_0.fastq", payload: payload, files: files, kind: .orient
        ))
        let materialized = try await materialize(try makeDerived(
            named: "bare-name-oriented", root: multi.bundle, rootFile: "run_0.fastq", payload: payload, files: files, kind: .orient
        ))
        XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: expected))
        let materializedNames = try await names(materialized)
        XCTAssertEqual(materializedNames, ["m1", "m2"])
    }

    // MARK: - A root missing a member

    func testAMultiFileRootMissingAMemberIsRefused() async throws {
        let multi = try makeMultiFileRoot()
        let derived = try makeDerived(
            named: "oriented-missing", root: multi.bundle, rootFile: "chunks/run_0.fastq",
            payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
            files: ["orient-map.tsv": "m1\t+\n", "preview.fastq": Self.fastq(["m1"])],
            kind: .orient
        )
        try FileManager.default.removeItem(at: multi.chunks[1])
        do {
            _ = try await materialize(derived)
            XCTFail("a root missing a member must not be read as a shorter bundle")
        } catch let error as FASTQBundlePathError {
            XCTAssertEqual(error, .missingMember(bundle: "multi.lungfishfastq", path: "chunks/run_1.fastq"))
        }
    }
}
