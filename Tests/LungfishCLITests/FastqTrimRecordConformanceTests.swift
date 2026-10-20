// FastqTrimRecordConformanceTests.swift - Pins the provenance record of `lungfish fastq trim` (Phase 2.13 lane 13.13)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// The record that `FastqTrimSubcommand.writeProvenance` hands to `recordFASTQNativeToolProvenance`, taken with the real
/// fastp on a fixed six-read file. M3 of lane 13.13 reaches the writer from that function by a form the ratchet reads,
/// and this pin shows that the record stays the same. The pin holds the stable facts of the record. The ids, the dates,
/// the durations and the tool versions change on every run, so they stay out of it.
final class FastqTrimRecordConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-trim-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTrimRecordKeepsItsFacts() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.fastp) else {
            try ToolAvailability.skipOrFail("fastp is not available in this test environment")
        }
        let input = root.appendingPathComponent("reads.fastq")
        let sequence = String(repeating: "ACGTACGTAC", count: 6)
        let quality = String(repeating: "I", count: 50) + String(repeating: "#", count: 10)
        let text = (1...6).map { "@read\($0)\n\(sequence)\n+\n\(quality)\n" }.joined()
        try text.write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("reads.trimmed.fastq")

        try await FastqTrimSubcommand.parse([input.path, "-o", output.path]).run()

        let run = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: root))
        let sidecar = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        )
        let facts: [String: Any] = ["run": try facts(of: run), "sidecar": try facts(of: sidecar)]
        let data = try JSONSerialization.data(
            withJSONObject: facts,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try assertBytes(data, equalFixture: "fastq-trim-record-facts.json")
    }

    // MARK: - Facts

    private func facts(of envelope: ProvenanceEnvelope) throws -> [String: String] {
        let physicalRoot = "/private" + root.path
        let plainRoot = root.path
        func masked(_ text: String) -> String {
            text.replacingOccurrences(of: physicalRoot, with: "<root>")
                .replacingOccurrences(of: plainRoot, with: "<root>")
                .replacingOccurrences(of: #"\S*/bin/fastp "#, with: "<fastp> ", options: .regularExpression)
                .replacingOccurrences(of: #" -w \d+ "#, with: " -w N ", options: .regularExpression)
        }
        func json<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return masked(String(decoding: try encoder.encode(value), as: UTF8.self))
        }
        return [
            "workflowName": envelope.workflowName,
            "argv": masked(envelope.argv.joined(separator: " ")),
            "exitStatus": String(describing: envelope.exitStatus),
            "steps": envelope.steps
                .map { "\($0.toolName): " + masked($0.argv.joined(separator: " ")) }
                .joined(separator: "\n"),
            "explicit": try json(envelope.options.explicit),
            "resolved": try json(envelope.options.resolvedDefaults),
            "inputs": envelope.files.map { "\($0.role.rawValue) \(masked($0.path))" }.sorted().joined(separator: "\n"),
            "outputs": envelope.outputs.map { masked($0.path) }.sorted().joined(separator: "\n"),
        ]
    }

    // MARK: - Fixture

    private func assertBytes(
        _ data: Data,
        equalFixture name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/provenance-record-pins", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["LUNGFISH_CAPTURE_RECORD_PINS"] == "1",
           !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(
            data,
            expected,
            "\(name) moved. It now reads:\n\(String(decoding: data, as: UTF8.self))",
            file: file,
            line: line
        )
    }
}
