// DemultiplexDefinitionCopyTests.swift - A run on a custom definition keeps the definition it read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN (D1b, L8 with QA's round 2 line). The Demux tab's plan reaches the run as a custom
// definition in the project, which the next Demultiplex… rewrites. So the run copies the definition into its result
// folder, the recorded command names the copy, and the record names it with its digest, so a replay reads the
// definition the run read and not the plan as it is now.

import CryptoKit
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class DemultiplexDefinitionCopyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-definition-copy")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    /// 200 reads whose names carry D701 and 100 whose names carry D702, on seeded random bases.
    private func writeReads(to url: URL) throws {
        var state: UInt64 = 0x5EED
        func base() -> Character {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Array("ACGT")[Int((state >> 33) % 4)]
        }
        let indexes = Array(repeating: "ATTACTCG", count: 200) + Array(repeating: "TCCGGAGA", count: 100)
        let text = indexes.enumerated().map { read in
            let sequence = String((0..<60).map { _ in base() })
            return "@r\(read.offset) 1:N:0:\(read.element)\n\(sequence)\n+\n\(String(repeating: "I", count: 60))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func definition(_ first: String, _ second: String) -> String {
        "id,sequence,sample_name\n\(first),ATTACTCG,\(first) sample\n\(second),TCCGGAGA,\(second) sample\n"
    }

    private func run(_ arguments: [String]) async throws {
        var command = try FastqDemultiplexSubcommand.parse(arguments)
        try await command.run()
    }

    private func counts(in output: URL) throws -> [String: Int] {
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "no manifest in \(output.path)")
        return Dictionary(uniqueKeysWithValues: manifest.barcodes.filter { $0.readCount > 0 }.map { ($0.barcodeID, $0.readCount) })
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func testCustomDefinitionRunKeepsItsDefinitionInTheResultFolderAndRecordsItsDigest() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let definitions = project.appendingPathComponent("Barcode Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        try writeReads(to: input)
        let source = definitions.appendingPathComponent("plan.csv")
        try definition("Water_blank", "NTC_1").write(to: source, atomically: true, encoding: .utf8)
        let bytes = try Data(contentsOf: source)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)

        try await run([input.path, "--kit", source.path, "-o", output.path])

        let copy = output.appendingPathComponent("plan.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the run kept no copy of its definition")
        XCTAssertEqual(try? Data(contentsOf: copy), bytes, "the copy is not the definition the run read")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        let kitIndex = try XCTUnwrap(envelope.argv.firstIndex(of: "--kit"), "\(envelope.argv)")
        XCTAssertEqual(canonical(envelope.argv[kitIndex + 1]), canonical(copy.path), "the recorded command names another definition")
        let record = envelope.files.first { canonical($0.path) == canonical(copy.path) }
        XCTAssertEqual(record?.checksumSHA256, hex(bytes), "the record does not name the copy with its digest")
        XCTAssertEqual(try counts(in: output), ["Water_blank": 200, "NTC_1": 100])
    }

    /// Review DEMUXPLAN-ARCH, should-fix 1: a definition named like a file the run writes in its result folder refuses
    /// before the run writes anything, and the words say to rename it.
    func testDefinitionNamedLikeAnOutputRefusesBeforeTheRunWritesAnything() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let definitions = project.appendingPathComponent("Barcode Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        try writeReads(to: input)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)
        for name in [".plan.csv", "demux-manifest.json", "plan.lungfishfastq", "plan.lungfish-provenance.json"] {
            let source = definitions.appendingPathComponent(name)
            try definition("S1", "S2").write(to: source, atomically: true, encoding: .utf8)
            do {
                try await run([input.path, "--kit", source.path, "-o", output.path])
                XCTFail("a definition named \(name) did not refuse")
            } catch {
                let words = String(describing: error)
                XCTAssertTrue(words.contains(name), words)
                XCTAssertTrue(words.contains("Rename the definition"), words)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the run made its result folder for \(name)")
        }
    }

    /// The copy never replaces a file that is already in the result folder: keeping it refuses, and that file stays.
    func testKeepRefusesANameAlreadyInTheResultFolderAndLeavesThatFileAlone() throws {
        let folder = root.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = try XCTUnwrap(try DemultiplexDefinitionCopy.make(
            sourceURL: root.appendingPathComponent("plan.csv"), data: Data("new".utf8)
        ))
        let existing = folder.appendingPathComponent("plan.csv")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try copy.keep(in: folder))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
    }
}
