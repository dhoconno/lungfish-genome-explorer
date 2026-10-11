// NativeRecordDigestPinTests.swift - The digests native alignment and tree records hold, pinned before Phase 2.7 B6
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishIO

/// Alignment and tree records that are not envelopes cite bundles by digest, and other records
/// cite those records (risk K6 of Phase 2.7). Lane B6 changes what these records say about the
/// process that wrote them and must leave every digest path alone. `treeDigest` is pinned to literal
/// hex over fixed bytes, and `bundleDigest` and the per-file checksums are pinned to the bytes of the
/// bundle on disk. Each record also keeps the keys of its own shape.
final class NativeRecordDigestPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-record-digest-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Literal digests of fixed bytes, computed outside Swift with `hashlib.sha256`.
    func testDerivedTreeRecordDigestsAreByteIdentical() throws {
        let source = root.appendingPathComponent("Source.lungfishtree", isDirectory: true)
        let output = root.appendingPathComponent("Output.lungfishtree", isDirectory: true)
        try write([
            "tree/primary.nwk": "((A:0.1,B:0.2):0.3,C:0.4);\n",
            "manifest.json": "{\"name\":\"pin-source\"}\n",
            ".lungfish-provenance.json": "{\"pin\":true}\n",
        ], into: source)
        try write([
            "tree/primary.nwk": "(A:0.1,B:0.2);\n",
            "manifest.json": "{\"name\":\"pin-output\"}\n",
        ], into: output)

        let record = try derivedTreeProvenance(
            workflowName: "phylogenetic-tree-extract-subtree",
            actionID: "tree.extract.subtree",
            provenance: .init(toolName: "lungfish tree extract-subtree", argv: ["lungfish", "tree", "extract-subtree"]),
            sourceBundleURL: source,
            outputBundleURL: output,
            payloadPaths: ["manifest.json", "tree/primary.nwk"],
            warnings: [],
            wallTimeSeconds: 1,
            metadataURL: nil
        )

        let sourceDigest = "b4e93fabb3a36625fefd29e5de68ae1dc15684685c650f34d01b22cc4e560652"
        let outputDigest = "8b5fb0c3045dfcc35b4f98c6505b0b438d57deb1802d44cfd6bc1df3cd2f076d"
        for key in ["input", "inputBundle"] {
            let file = try XCTUnwrap(record[key] as? [String: Any], key)
            XCTAssertEqual(file["sha256"] as? String, sourceDigest, key)
            XCTAssertEqual(file["fileSizeBytes"] as? Int64, 62, key)
        }
        for key in ["output", "outputBundle"] {
            let file = try XCTUnwrap(record[key] as? [String: Any], key)
            XCTAssertEqual(file["sha256"] as? String, outputDigest, key)
            XCTAssertEqual(file["fileSizeBytes"] as? Int64, 37, key)
        }
        let treeFile = try XCTUnwrap(record["inputTreeFile"] as? [String: Any])
        XCTAssertEqual(treeFile["sha256"] as? String, "07a1ff81243cc639aa93e4604a56cf39d607bc399f80607c23ddc53f03c9f991")
        XCTAssertEqual(record["checksums"] as? [String: String], [
            "manifest.json": "ad89a7913cd2e0a256e6834438f0707fbd38e96dc176c5f4f09437cf8b243467",
            "tree/primary.nwk": "f8f0f08ecbf0338cbc64869e081e27276c091a8f92d19d4c1216cb0166323b94",
        ])
        XCTAssertEqual(record["fileSizes"] as? [String: Int64], ["manifest.json": 22, "tree/primary.nwk": 15])
        assertKeeps(record, keys: [
            "schemaVersion", "workflowName", "actionID", "toolName", "toolVersion", "argv", "command",
            "reproducibleCommand", "options", "runtime", "runtimeIdentity", "input", "inputBundle", "inputTreeFile",
            "output", "outputBundle", "checksums", "fileSizes", "exitStatus", "wallTimeSeconds", "warnings", "createdAt",
        ])
        for key in ["runtime", "runtimeIdentity"] {
            assertKeeps(try XCTUnwrap(record[key] as? [String: Any], key), keys: ["operatingSystem", "swiftRuntime"])
        }
    }

    /// `bundleDigest` over the recorded per-file checksums, each the SHA-256 of the file's bytes.
    func testAlignmentImportRecordDigestsFollowTheBundleBytes() throws {
        let fasta = root.appendingPathComponent("input.fasta")
        try ">seq1\nACGT--\n>seq2\nA-GTAA\n".write(to: fasta, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: fasta, to: bundle, options: .init(name: "input"))
        let record = try jsonObject(bundle.appendingPathComponent(".lungfish-provenance.json"))

        let files = try XCTUnwrap(record["files"] as? [String: [String: Any]])
        XCTAssertTrue(files.keys.contains("manifest.json"))
        var checksums: [String: String] = [:]
        for (path, file) in files {
            let bytes = try Data(contentsOf: bundle.appendingPathComponent(path))
            XCTAssertEqual(file["checksumSHA256"] as? String, sha256(bytes), path)
            XCTAssertEqual(file["fileSize"] as? Int, bytes.count, path)
            checksums[path] = try XCTUnwrap(file["checksumSHA256"] as? String)
        }
        let output = try XCTUnwrap(record["output"] as? [String: Any])
        XCTAssertEqual(output["checksumSHA256"] as? String, bundleDigest(checksums))
        let input = try XCTUnwrap(record["input"] as? [String: Any])
        let original = try Data(contentsOf: bundle.appendingPathComponent("alignment/source.original"))
        XCTAssertEqual(input["checksumSHA256"] as? String, sha256(original))
        assertKeeps(record, keys: [
            "schemaVersion", "workflowName", "toolName", "toolVersion", "argv", "reproducibleCommand", "options",
            "runtimeIdentity", "input", "output", "files", "exitStatus", "wallTimeSeconds", "warnings", "createdAt",
            "inputFiles",
        ])
        assertKeeps(try XCTUnwrap(record["runtimeIdentity"] as? [String: Any]), keys: [
            "executablePath", "operatingSystemVersion",
        ])
    }

    /// The tree import record's output digest is `bundleDigest` over its own `checksums`.
    func testTreeImportRecordDigestsFollowTheBundleBytes() throws {
        let newick = root.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2):0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: bundle)
        let record = try jsonObject(bundle.appendingPathComponent(".lungfish-provenance.json"))

        let checksums = try XCTUnwrap(record["checksums"] as? [String: String])
        XCTAssertTrue(checksums.keys.contains("manifest.json"))
        for (path, checksum) in checksums {
            XCTAssertEqual(checksum, sha256(try Data(contentsOf: bundle.appendingPathComponent(path))), path)
        }
        let output = try XCTUnwrap(record["output"] as? [String: Any])
        XCTAssertEqual(output["sha256"] as? String, bundleDigest(checksums))
        XCTAssertEqual(output["checksumSHA256"] as? String, bundleDigest(checksums))
        let input = try XCTUnwrap(record["input"] as? [String: Any])
        XCTAssertEqual(input["sha256"] as? String, sha256(try Data(contentsOf: newick)))
        assertKeeps(record, keys: [
            "schemaVersion", "id", "createdAt", "workflowName", "workflowVersion", "toolName", "toolVersion", "tool",
            "argv", "reproducibleCommand", "command", "options", "runtime", "runtimeIdentity", "files", "input",
            "output", "outputs", "steps", "checksums", "fileSizes", "exitStatus", "wallTimeSeconds", "warnings",
            "signatures",
        ])
        for key in ["runtime", "runtimeIdentity"] {
            assertKeeps(try XCTUnwrap(record[key] as? [String: Any], key), keys: [
                "appVersion", "executablePath", "operatingSystemVersion", "architecture", "operatingSystem",
                "swiftRuntime",
            ])
        }
    }

    // MARK: - Helpers

    private func write(_ files: [String: String], into directory: URL) throws {
        for (path, text) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bundleDigest(_ checksums: [String: String]) -> String {
        sha256(Data(checksums.keys.sorted().map { "\($0)=\(checksums[$0] ?? "")" }.joined(separator: "\n").utf8))
    }

    private func assertKeeps(_ object: [String: Any], keys: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        let missing = keys.subtracting(object.keys)
        XCTAssertTrue(missing.isEmpty, "the record lost \(missing.sorted())", file: file, line: line)
    }
}
