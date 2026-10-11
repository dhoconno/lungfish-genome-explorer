// NativeRecordWriterFactsTests.swift - What the IO alignment and tree records say about their run and writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Phase 2.7 lane B6 (panel decision P13). An alignment or tree record that keeps its own shape
/// states `status`, names its writer `<external>/<file name>`, records no process ID and records no
/// conda or container value inherited from the shell that started LGE. The test sets those
/// variables to values no writer may copy.
final class NativeRecordWriterFactsTests: XCTestCase {
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
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-record-writer-facts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testAlignmentImportRecordStatesItsStatusAndNoInheritedFacts() throws {
        let fasta = root.appendingPathComponent("input.fasta")
        try ">seq1\nACGT--\n>seq2\nA-GTAA\n".write(to: fasta, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: fasta, to: bundle, options: .init(name: "input"))

        try assertNativeFacts(at: bundle.appendingPathComponent(".lungfish-provenance.json"), runtimeKeys: ["runtimeIdentity"])
    }

    func testTreeImportRecordStatesItsStatusAndNoInheritedFacts() throws {
        let newick = root.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2):0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let bundle = root.appendingPathComponent("Tree.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: bundle)

        try assertNativeFacts(at: bundle.appendingPathComponent(".lungfish-provenance.json"), runtimeKeys: ["runtime", "runtimeIdentity"])
    }

    func testDerivedTreeRecordStatesItsStatusAndNoInheritedFacts() throws {
        let newick = root.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2):0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let source = try PhylogeneticTreeBundleImporter.importTree(
            from: newick, to: root.appendingPathComponent("Source.lungfishtree", isDirectory: true)
        )
        let output = root.appendingPathComponent("Rerooted.lungfishtree", isDirectory: true)
        _ = try source.rerootedBundle(
            on: "C", to: output,
            provenance: .init(toolName: "lungfish tree reroot", argv: ["lungfish", "tree", "reroot"])
        )

        try assertNativeFacts(at: output.appendingPathComponent(".lungfish-provenance.json"), runtimeKeys: ["runtime", "runtimeIdentity"])
    }

    /// `status` completed, the writer as `<external>/<file name>` where the shape names one, no
    /// process ID, and no inherited conda or container value anywhere in the record.
    private func assertNativeFacts(
        at url: URL, runtimeKeys: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(record["status"] as? String, "completed", file: file, line: line)
        let writer = "<external>/" + URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).lastPathComponent
        for key in runtimeKeys {
            let runtime = try XCTUnwrap(record[key] as? [String: Any], key, file: file, line: line)
            XCTAssertNil(runtime["processIdentifier"], "\(key) holds a process ID", file: file, line: line)
            if runtime["executablePath"] != nil {
                XCTAssertEqual(runtime["executablePath"] as? String, writer, key, file: file, line: line)
            }
            for name in ["condaEnvironment", "condaPrefix", "containerImage"] {
                XCTAssertTrue(runtime[name] == nil || runtime[name] is NSNull, "\(key).\(name) holds a value", file: file, line: line)
            }
        }
        for value in Self.inherited.values {
            XCTAssertFalse(text.contains(value), "the record copies \(value)", file: file, line: line)
        }
    }
}
