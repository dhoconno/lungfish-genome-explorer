// FASTQBundleExportPinTests.swift - The sidebar FASTQ bundle export as it stood at the lane 12.38 base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38 M1 (QA 1). A pin with no Sources edit. `AppDelegate.exportFASTQBundleForSidebar` writes a
// plain bundle's file, several source chunks joined, or a derived bundle materialized, and records the tool
// `Lungfish Genome Explorer FASTQ Export` with the argv `Lungfish Genome Explorer export-fastq`. The pin holds the
// exact output bytes of the three kinds and the facts of each record, so the lane's report names what the leaf moves.
// The failure alert of the batch (`performFASTQExports`) is built inside a detached task and no test can reach it,
// so its words are read from the code and listed in the lane report. The lane deletes the writer, and the parity
// class `FASTQBundleExportCLIGUIParityReplayTests` freezes it from here on.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQBundleExportPinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "fastq-bundle-export-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    static let reads = "@r1\nACGT\n+\nIIII\n@r2\nTTGA\n+\nIIII\n"

    /// A bundle with one FASTQ file named `reads.fastq`.
    static func makePlainBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("plain.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(reads.utf8).write(to: bundle.appendingPathComponent("reads.fastq"))
        return bundle
    }

    /// A bundle whose reads sit in three chunks that `source-files.json` lists in order.
    static func makeChunkedBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("chunked.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for index in 0..<3 {
            let data = Data("@c\(index)\nACGT\n+\nIIII\n".utf8)
            try data.write(to: chunks.appendingPathComponent("sample_\(index).fastq"))
            entries.append(.init(
                filename: "chunks/sample_\(index).fastq", originalPath: "/run/sample_\(index).fastq",
                sizeBytes: Int64(data.count), isSymlink: false
            ))
        }
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        return bundle
    }

    /// A derived bundle whose payload is a full FASTQ of its own, which the materializer copies.
    static func makeDerivedBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("derived.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(reads.utf8).write(to: bundle.appendingPathComponent("full.fastq"))
        let operation = FASTQDerivativeOperation(kind: .subsampleCount)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "derived",
                parentBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootFASTQFilename: "root.fastq",
                payload: .full(fastqFilename: "full.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 8),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// The facts of the record beside `output`, with the scratch root written as `$ROOT`.
    static func facts(of output: URL, root: URL) throws -> [String] {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        let prefixes = ["/private" + root.standardizedFileURL.path, root.standardizedFileURL.path]
        func relative(_ text: String) -> String {
            prefixes.reduce(text) { $0.replacingOccurrences(of: $1, with: "$ROOT") }
        }
        var lines = [
            "tool=\(envelope.toolName)", "kind=\(envelope.tool.kind ?? "none")", "workflow=\(envelope.workflowName)",
            "argv=\(envelope.argv.map(relative).joined(separator: " "))",
            "replay=\((envelope.durableReplayArgv ?? []).map(relative).joined(separator: " "))",
            "explicit=\(envelope.options.explicit.keys.sorted().joined(separator: ","))",
            "defaults=\(envelope.options.defaults.keys.sorted().joined(separator: ","))",
            "resolved=\(envelope.options.resolvedDefaults.keys.sorted().joined(separator: ","))",
            "steps=\(envelope.steps.map(\.toolName).joined(separator: ","))",
        ]
        for file in envelope.files.sorted(by: { $0.path < $1.path }) {
            var digestMatches = "no digest"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               let sha = file.checksumSHA256 {
                let actual = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: file.path)))
                    .map { String(format: "%02x", $0) }.joined()
                digestMatches = sha == actual ? "digest ok" : "digest wrong"
            } else if file.checksumSHA256 != nil {
                digestMatches = "digest of a folder"
            }
            lines.append("\(file.role) \(relative(file.path)) \(digestMatches)")
        }
        return lines
    }

    /// The lines every case shares, then the case's argv and files.
    static func expectedFacts(argv: String, files: [String], explicit: String = "inputChunkCount,isDerived,output,outputGzipCompressed,sourceBundle") -> [String] {
        [
            "tool=Lungfish Genome Explorer FASTQ Export", "kind=cli", "workflow=FASTQ Export", "argv=\(argv)", "replay=",
            "explicit=\(explicit)", "defaults=", "resolved=", "steps=Lungfish Genome Explorer FASTQ Export",
        ] + files
    }

    private func export(_ bundle: URL, to name: String, isDerived: Bool) async throws -> URL {
        let output = scratch.appendingPathComponent("out", isDirectory: true).appendingPathComponent(name)
        try await AppDelegate.exportFASTQBundleForSidebar(bundleURL: bundle, outputURL: output, isDerived: isDerived)
        return output
    }

    /// The three scalar parameters the record keeps next to the two paths.
    private func assertParameters(of output: URL, isDerived: Bool, chunks: Int, gzip: Bool) throws {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.options.explicit["isDerived"], .boolean(isDerived))
        XCTAssertEqual(envelope.options.explicit["inputChunkCount"], .integer(chunks))
        XCTAssertEqual(envelope.options.explicit["outputGzipCompressed"], .boolean(gzip))
    }

    func testAPlainBundleIsCopiedAndRecorded() async throws {
        let bundle = try Self.makePlainBundle(in: scratch)
        let output = try await export(bundle, to: "plain.fastq", isDerived: false)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), Self.reads)
        XCTAssertEqual(try Self.facts(of: output, root: scratch), Self.expectedFacts(
            argv: "Lungfish Genome Explorer export-fastq $ROOT/plain.lungfishfastq --output $ROOT/out/plain.fastq",
            files: ["input $ROOT/plain.lungfishfastq/reads.fastq digest ok", "output $ROOT/out/plain.fastq digest ok"]
        ))
        try assertParameters(of: output, isDerived: false, chunks: 1, gzip: false)
    }

    func testSeveralChunksAreJoinedInManifestOrderAndRecorded() async throws {
        let bundle = try Self.makeChunkedBundle(in: scratch)
        let output = try await export(bundle, to: "chunked.fastq", isDerived: false)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "@c0\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n@c2\nACGT\n+\nIIII\n"
        )
        XCTAssertEqual(try Self.facts(of: output, root: scratch), Self.expectedFacts(
            argv: "Lungfish Genome Explorer export-fastq $ROOT/chunked.lungfishfastq --output $ROOT/out/chunked.fastq --source-chunks 3",
            files: [
                "input $ROOT/chunked.lungfishfastq/chunks/sample_0.fastq digest ok",
                "input $ROOT/chunked.lungfishfastq/chunks/sample_1.fastq digest ok",
                "input $ROOT/chunked.lungfishfastq/chunks/sample_2.fastq digest ok",
                "input $ROOT/chunked.lungfishfastq/source-files.json digest ok",
                "output $ROOT/out/chunked.fastq digest ok",
            ]
        ))
        try assertParameters(of: output, isDerived: false, chunks: 3, gzip: false)
    }

    /// The materializer copies the payload, so the bytes are the payload's even under a `.gz` name. The record names
    /// the bundle folder as an input with no digest, and the derived manifest with its digest.
    func testADerivedBundleIsMaterializedAndRecorded() async throws {
        let bundle = try Self.makeDerivedBundle(in: scratch)
        let output = try await export(bundle, to: "derived.fastq.gz", isDerived: true)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), Self.reads)
        XCTAssertEqual(try Self.facts(of: output, root: scratch), Self.expectedFacts(
            argv: "Lungfish Genome Explorer export-fastq $ROOT/derived.lungfishfastq --output $ROOT/out/derived.fastq.gz --materialize-derived",
            files: [
                "input $ROOT/derived.lungfishfastq no digest",
                "input $ROOT/derived.lungfishfastq/derived.manifest.json digest ok",
                "output $ROOT/out/derived.fastq.gz digest ok",
            ]
        ))
        try assertParameters(of: output, isDerived: true, chunks: 0, gzip: true)
    }
}
