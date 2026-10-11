// NativeRecordCLIDigestPinTests.swift - The digests the CLI's alignment and tree records hold, pinned before Phase 2.7 B6
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishCLI
@testable import LungfishIO

/// The `msa` and `tree` commands write records that are not envelopes and cite bundles by digest
/// (risk K6 of Phase 2.7). Lane B6 changes what these records say about the process that wrote them
/// and must leave every digest path alone, so each digest is pinned to the bundle bytes on disk, by
/// the rule each writer uses, and each record keeps the keys of its own shape.
final class NativeRecordCLIDigestPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/NativeRecordCLIDigestPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAlignmentExportRecordCitesTheManifestDigest() throws {
        let bundle = try alignment(">seq1\nACGT--\n>seq2\nA-GTAA\n")
        let output = root.appendingPathComponent("selected.fa")
        try MSACommand.ExportSubcommand.parse([
            bundle.path, "--output-format", "aligned-fasta", "--output", output.path, "--rows", "seq1", "--quiet",
        ]).executeForTesting { _ in }
        let record = try jsonObject(output.appendingPathExtension("lungfish-provenance.json"))

        XCTAssertEqual(try file(record, "inputBundle")["checksumSHA256"] as? String, try manifestDigest(bundle))
        XCTAssertEqual(try file(record, "outputFile")["checksumSHA256"] as? String, sha256(try Data(contentsOf: output)))
        assertKeeps(record, keys: [
            "schemaVersion", "workflowName", "actionID", "toolName", "toolVersion", "argv", "reproducibleCommand",
            "options", "runtimeIdentity", "inputBundle", "inputAlignmentFile", "outputFile", "exitStatus",
            "wallTimeSeconds", "warnings", "createdAt",
        ])
        assertKeeps(try file(record, "runtimeIdentity"), keys: ["executablePath", "operatingSystemVersion"])
    }

    func testDiscriminatingSitesRecordCitesTheManifestDigest() throws {
        let bundle = try alignment(">t1\nACGTACGT\n>t2\nACGTACGT\n>x1\nGCGTGCGT\n>x2\nGCGTGCGT\n")
        let output = root.appendingPathComponent("sites.tsv")
        try MSACommand.DiscriminatingSitesSubcommand.parse([
            bundle.path, "--exclusions", "x1,x2", "--window-length", "8", "--output", output.path, "--quiet",
        ]).executeForTesting { _ in }
        let record = try jsonObject(output.appendingPathExtension("lungfish-provenance.json"))

        XCTAssertEqual(try file(record, "inputBundle")["checksumSHA256"] as? String, try manifestDigest(bundle))
        let outputs = try XCTUnwrap(record["outputFiles"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 3)
        for output in outputs {
            let path = try XCTUnwrap(output["path"] as? String)
            XCTAssertEqual(output["checksumSHA256"] as? String, sha256(try Data(contentsOf: URL(fileURLWithPath: path))), path)
        }
        assertKeeps(record, keys: [
            "schemaVersion", "workflowName", "actionID", "toolName", "toolVersion", "argv", "reproducibleCommand",
            "inputBundle", "inputAlignmentFile", "outputFiles", "options", "discriminatingColumnCount",
            "candidateWindowCount", "runtimeIdentity", "exitStatus", "wallTimeSeconds", "createdAt",
        ])
        assertKeeps(try file(record, "runtimeIdentity"), keys: ["executablePath", "operatingSystemVersion"])
    }

    /// The reference bundle's digest skips hidden files, so its own record never feeds it.
    func testAlignmentReferenceRecordCitesTheVisibleDirectoryDigest() throws {
        let bundle = try alignment(">seq1\nACGT--\n>seq2\nA-GTAA\n>seq3\nACGTAA\n")
        let output = root.appendingPathComponent("selected.lungfishref", isDirectory: true)
        try MSACommand.ExtractSubcommand.parse([
            bundle.path, "--output-kind", "reference", "--output", output.path, "--rows", "seq1,seq2",
            "--columns", "2-5", "--name", "selected-reference", "--quiet",
        ]).executeForTesting { _ in }
        let record = try jsonObject(output.appendingPathComponent(".lungfish-provenance.json"))

        XCTAssertEqual(try file(record, "outputBundle")["checksumSHA256"] as? String, try visibleDirectoryDigest(output))
        XCTAssertEqual(try file(record, "inputBundle")["checksumSHA256"] as? String, try manifestDigest(bundle))
        assertKeeps(record, keys: [
            "workflowName", "actionID", "toolName", "toolVersion", "argv", "reproducibleCommand", "runtime",
            "inputBundle", "inputAlignmentFile", "outputBundle", "outputBundlePath", "outputFiles", "metadataFiles",
            "options", "exitStatus", "wallTimeSeconds", "warnings",
        ])
        assertKeeps(try file(record, "runtime"), keys: ["executablePath", "operatingSystemVersion"])
    }

    /// A tree command's directory digest covers every regular file, hidden ones included.
    func testSubtreeExportRecordCitesTheTreeDigests() throws {
        let newick = root.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2)Clade:0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: bundle)
        let output = root.appendingPathComponent("clade.nwk")
        try TreeCommand.ExportSubcommand.SubtreeSubcommand.parse([
            bundle.path, "--label", "Clade", "--output", output.path, "--quiet",
        ]).executeForTesting { _ in }
        let record = try jsonObject(output.appendingPathExtension("lungfish-provenance.json"))

        XCTAssertEqual(try file(record, "inputBundle")["sha256"] as? String, try treeDirectoryDigest(bundle))
        let tree = bundle.appendingPathComponent("tree/primary.nwk")
        XCTAssertEqual(try file(record, "inputTreeFile")["sha256"] as? String, sha256(try Data(contentsOf: tree)))
        XCTAssertEqual(try file(record, "outputFile")["sha256"] as? String, sha256(try Data(contentsOf: output)))
        assertKeeps(record, keys: [
            "schemaVersion", "workflowName", "actionID", "toolName", "toolVersion", "argv", "command",
            "reproducibleCommand", "options", "runtime", "runtimeIdentity", "inputBundle", "inputTreeFile",
            "outputFile", "exitStatus", "wallTimeSeconds", "warnings", "createdAt",
        ])
        for key in ["runtime", "runtimeIdentity"] {
            assertKeeps(try file(record, key), keys: ["executablePath", "operatingSystem", "swiftRuntime"])
        }
    }

    func testInferenceRecordCitesTheTreeDigests() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fasta = root.appendingPathComponent("input.aligned.fasta")
        try ">A\nACGT\n>B\nACGA\n>C\nACTA\n>D\nTCGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        let msa = project.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: fasta, to: msa, options: .init(name: "Input"))
        let output = project.appendingPathComponent("Phylogenetic Trees/Pin.lungfishtree", isDirectory: true)
        try await TreeCommand.InferIQTreeSubcommand.parse([
            msa.path, "--project", project.path, "--output", output.path, "--name", "Pin", "--model", "GTR+G",
            "--seed", "42", "--iqtree-path", try fakeIQTree().path, "--quiet",
        ]).executeForTesting { _ in }
        let record = try jsonObject(output.appendingPathComponent(".lungfish-provenance.json"))

        let checksums = try XCTUnwrap(record["checksums"] as? [String: String])
        for (path, checksum) in checksums {
            XCTAssertEqual(checksum, sha256(try Data(contentsOf: output.appendingPathComponent(path))), path)
        }
        XCTAssertEqual(try file(record, "output")["sha256"] as? String, digest(checksums))
        XCTAssertEqual(try file(record, "input")["sha256"] as? String, try treeDirectoryDigest(msa))
        assertKeeps(record, keys: [
            "schemaVersion", "workflowName", "toolName", "toolVersion", "argv", "command", "reproducibleCommand",
            "externalTool", "options", "runtime", "runtimeIdentity", "input", "inputs", "output", "checksums",
            "fileSizes", "exitStatus", "wallTimeSeconds", "warnings", "stderr",
        ])
        let externalTool = try file(record, "externalTool")
        assertKeeps(externalTool, keys: [
            "toolName", "toolVersion", "executablePath", "executable", "argv", "arguments", "command",
            "reproducibleCommand", "exitStatus", "wallTimeSeconds", "stdout", "stderr", "runtime",
        ])
        for runtime in [try file(record, "runtime"), try file(record, "runtimeIdentity"), try file(externalTool, "runtime")] {
            assertKeeps(runtime, keys: ["executablePath", "operatingSystem", "swiftRuntime"])
        }
    }

    // MARK: - Helpers

    private func alignment(_ fasta: String) throws -> URL {
        let source = root.appendingPathComponent("alignment-\(UUID().uuidString).fasta")
        try fasta.write(to: source, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("alignment-\(UUID().uuidString).lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle, options: .init(name: "pin"))
        return bundle
    }

    private func fakeIQTree() throws -> URL {
        let url = root.appendingPathComponent("iqtree3")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "IQ-TREE multicore version 3.1.1"
          exit 0
        fi
        prefix=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --prefix) prefix="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        echo "((t0001:0.1,t0002:0.2):0.05,t0003:0.3,t0004:0.4);" > "$prefix.treefile"
        exit 0
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// `msa export`, `msa discriminating-sites` and the reference builder's input digest.
    private func manifestDigest(_ bundle: URL) throws -> String {
        let manifest = try jsonObject(bundle.appendingPathComponent("manifest.json"))
        return digest(try XCTUnwrap(manifest["checksums"] as? [String: String]))
    }

    /// The `tree` commands' digest of a directory, over every regular file below it.
    private func treeDirectoryDigest(_ directory: URL) throws -> String {
        var checksums: [String: String] = [:]
        for path in try regularFiles(in: directory, skippingHidden: false) {
            checksums[path] = sha256(try Data(contentsOf: directory.appendingPathComponent(path)))
        }
        return digest(checksums)
    }

    /// The reference builder's digest of its output bundle, over visible files with their sizes.
    private func visibleDirectoryDigest(_ directory: URL) throws -> String {
        let entries = try regularFiles(in: directory, skippingHidden: true).map { path -> String in
            let bytes = try Data(contentsOf: directory.appendingPathComponent(path))
            return "\(path)\t\(bytes.count)\t\(sha256(bytes))"
        }
        return sha256(Data(entries.sorted().joined(separator: "\n").utf8))
    }

    private func regularFiles(in directory: URL, skippingHidden: Bool) throws -> [String] {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: skippingHidden ? [.skipsHiddenFiles] : []
        ))
        var paths: [String] = []
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            XCTAssertTrue(path.hasPrefix(base), path)
            paths.append(String(path.dropFirst(base.count)))
        }
        return paths
    }

    private func digest(_ checksums: [String: String]) -> String {
        sha256(Data(checksums.keys.sorted().map { "\($0)=\(checksums[$0] ?? "")" }.joined(separator: "\n").utf8))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func file(_ record: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(record[key] as? [String: Any], key)
    }

    private func assertKeeps(_ object: [String: Any], keys: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        let missing = keys.subtracting(object.keys)
        XCTAssertTrue(missing.isEmpty, "the record lost \(missing.sorted())", file: file, line: line)
    }
}
