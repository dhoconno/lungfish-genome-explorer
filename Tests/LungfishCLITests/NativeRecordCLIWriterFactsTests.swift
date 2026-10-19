// NativeRecordCLIWriterFactsTests.swift - What the CLI's alignment and tree records say about their run and writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
import LungfishWorkflow

/// Phase 2.7 lane B6 (panel decision P13) for the records the `msa` and `tree` commands write and the
/// reference bundle builder the `msa extract` and `msa consensus` commands run. Each states `status`,
/// names its writer `<external>/<file name>`, records no process ID and copies no conda or container
/// variable the shell set. The test sets those variables to values no writer may copy.
final class NativeRecordCLIWriterFactsTests: XCTestCase {
    static let inherited = [
        "CONDA_DEFAULT_ENV": "b6-inherited-environment",
        "CONDA_PREFIX": "/b6-inherited/conda-prefix",
        "LUNGFISH_CONTAINER_IMAGE": "b6-inherited-container-image",
    ]
    private var saved: [String: String?] = [:]
    private var root: URL!

    override func setUpWithError() throws {
        for (name, value) in Self.inherited {
            saved[name] = ProcessInfo.processInfo.environment[name]
            setenv(name, value, 1)
        }
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/NativeRecordCLIWriterFacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testAlignmentExportRecord() throws {
        let bundle = try alignment(">seq1\nACGT--\n>seq2\nA-GTAA\n")
        let output = root.appendingPathComponent("selected.fa")
        try MSACommand.ExportSubcommand.parse([
            bundle.path, "--output-format", "aligned-fasta", "--output", output.path, "--quiet",
        ]).executeForTesting { _ in }
        try assertNativeFacts(at: output.appendingPathExtension("lungfish-provenance.json"), runtimeKeys: ["runtimeIdentity"])
    }

    func testDiscriminatingSitesRecord() throws {
        let bundle = try alignment(">t1\nACGTACGT\n>t2\nACGTACGT\n>x1\nGCGTGCGT\n>x2\nGCGTGCGT\n")
        let output = root.appendingPathComponent("sites.tsv")
        try MSACommand.DiscriminatingSitesSubcommand.parse([
            bundle.path, "--exclusions", "x1,x2", "--window-length", "8", "--output", output.path, "--quiet",
        ]).executeForTesting { _ in }
        try assertNativeFacts(at: output.appendingPathExtension("lungfish-provenance.json"), runtimeKeys: ["runtimeIdentity"])
    }

    func testAlignmentReferenceBundleRecord() throws {
        let bundle = try alignment(">seq1\nACGT--\n>seq2\nA-GTAA\n>seq3\nACGTAA\n")
        let output = root.appendingPathComponent("selected.lungfishref", isDirectory: true)
        try MSACommand.ExtractSubcommand.parse([
            bundle.path, "--output-kind", "reference", "--output", output.path, "--rows", "seq1,seq2", "--quiet",
        ]).executeForTesting { _ in }
        try assertNativeFacts(at: output.appendingPathComponent(".lungfish-provenance.json"), runtimeKeys: ["runtime"])
    }

    func testSubtreeExportRecord() throws {
        let newick = root.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2)Clade:0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: bundle)
        let output = root.appendingPathComponent("clade.nwk")
        try TreeCommand.ExportSubcommand.SubtreeSubcommand.parse([
            bundle.path, "--label", "Clade", "--output", output.path, "--quiet",
        ]).executeForTesting { _ in }
        // Phase 2.12 lane 12.35. The leaf writes the provenance envelope, which has no `runtime` alias.
        try assertNativeFacts(at: output.appendingPathExtension("lungfish-provenance.json"), runtimeKeys: ["runtimeIdentity"])
    }

    func testInferenceRecord() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fasta = root.appendingPathComponent("input.aligned.fasta")
        try ">A\nACGT\n>B\nACGA\n>C\nACTA\n>D\nTCGT\n".write(to: fasta, atomically: true, encoding: .utf8)
        let msa = project.appendingPathComponent("Input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: fasta, to: msa, options: .init(name: "Input"))
        let output = project.appendingPathComponent("Phylogenetic Trees/Facts.lungfishtree", isDirectory: true)
        try await TreeCommand.InferIQTreeSubcommand.parse([
            msa.path, "--project", project.path, "--output", output.path, "--name", "Facts", "--model", "GTR+G",
            "--seed", "42", "--iqtree-path", try fakeIQTree().path, "--quiet",
        ]).executeForTesting { _ in }
        let url = output.appendingPathComponent(".lungfish-provenance.json")
        try assertNativeFacts(at: url, runtimeKeys: ["runtime", "runtimeIdentity"])
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let externalTool = try XCTUnwrap(record["externalTool"] as? [String: Any])
        try assertRuntime(try XCTUnwrap(externalTool["runtime"] as? [String: Any]), named: "externalTool.runtime")
    }

    // MARK: - Helpers

    private func assertNativeFacts(
        at url: URL, runtimeKeys: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(record["status"] as? String, "completed", file: file, line: line)
        for key in runtimeKeys {
            try assertRuntime(try XCTUnwrap(record[key] as? [String: Any], key, file: file, line: line), named: key, file: file, line: line)
        }
        for value in Self.inherited.values {
            XCTAssertFalse(text.contains(value), "the record copies \(value)", file: file, line: line)
        }
        // A record this release writes reads with its stated status and never as the Older record format.
        let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: url), file: file, line: line)
        XCTAssertTrue([.envelope, .typedRecord].contains(reading.shape), "\(reading.shape)", file: file, line: line)
        XCTAssertTrue(reading.statusWasRecorded, file: file, line: line)
        XCTAssertEqual(reading.envelope.status, .completed, file: file, line: line)
    }

    private func assertRuntime(
        _ runtime: [String: Any], named key: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let writer = "<external>/" + URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).lastPathComponent
        XCTAssertNil(runtime["processIdentifier"], "\(key) holds a process ID", file: file, line: line)
        XCTAssertEqual(runtime["executablePath"] as? String, writer, key, file: file, line: line)
        for name in ["condaEnvironment", "condaPrefix", "containerImage"] {
            XCTAssertTrue(runtime[name] == nil || runtime[name] is NSNull, "\(key).\(name) holds a value", file: file, line: line)
        }
    }

    private func alignment(_ fasta: String) throws -> URL {
        let source = root.appendingPathComponent("alignment-\(UUID().uuidString).fasta")
        try fasta.write(to: source, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("alignment-\(UUID().uuidString).lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle, options: .init(name: "facts"))
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
}
