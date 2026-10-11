// ProvenanceFileParameterTests.swift - A recorded file parameter reads back as the record holds it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Finding F5. A file value decoded through `URL(fileURLWithPath:)`, which puts the reading
/// process's working folder in front of a relative path, so a recorded `<workspace>/reads.fastq`
/// read back as `<cwd>/<workspace>/reads.fastq`, and an export or a rewrite of the record wrote
/// that. A file value now reads back as written. An absolute value decodes and encodes as before,
/// which the golden records depend on.
final class ProvenanceFileParameterTests: XCTestCase {
    func testAPlaceholderFileValueDecodesAndEncodesAsWritten() throws {
        for path in ["<workspace>/reads.fastq", "<external>/reads.fastq", "reads/sample 1%20b.fastq", "~/reads.fastq"] {
            let value = try decode(path)
            XCTAssertEqual(value.fileValue?.path, path, "decoded \(path)")
            XCTAssertEqual(value.toArgumentString(), path, "argument of \(path)")
            XCTAssertEqual(try encodedValue(of: value), path, "re-encoded \(path)")
        }
    }

    func testAnAbsoluteFileValueDecodesAndEncodesAsBefore() throws {
        let written = ParameterValue.file(URL(fileURLWithPath: "/data/run/reads.fastq"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(decoding: try encoder.encode(written), as: UTF8.self),
            #"{"type":"file","value":"\/data\/run\/reads.fastq"}"#
        )
        XCTAssertEqual(try decode("/data/run/reads.fastq"), written)
    }

    /// A record whose explicit options hold a placeholder file value exports it as recorded.
    func testAnExportOfARecordKeepsItsPlaceholderFileValues() throws {
        let record = Data(#"""
        {
          "createdAt": "2026-10-10T00:00:00Z",
          "workflowName": "fastq-trim",
          "toolName": "fastp",
          "argv": ["fastp", "-i", "<workspace>/reads.fastq"],
          "runtimeIdentity": {"appVersion": "Lungfish 2026.10.10 (fixture)"},
          "options": {
            "explicit": {"reads": {"type": "file", "value": "<workspace>/reads.fastq"}},
            "defaults": {},
            "resolvedDefaults": {}
          },
          "status": "completed",
          "exitStatus": 0
        }
        """#.utf8)
        let envelope = try ProvenanceEnvelopeReader.decode(record)
        XCTAssertEqual(envelope.options.explicit["reads"]?.fileValue?.path, "<workspace>/reads.fastq")

        let exported = try ProvenanceExporter(signingProvider: nil).exportJSON(envelope.legacyWorkflowRun())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any])
        let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
        let reads = try XCTUnwrap(parameters["reads"] as? [String: Any])
        XCTAssertEqual(reads["value"] as? String, "<workspace>/reads.fastq", "the export keeps the recorded path")
    }

    // MARK: Helpers

    private func decode(_ path: String) throws -> ParameterValue {
        let json = try JSONSerialization.data(withJSONObject: ["type": "file", "value": path])
        return try JSONDecoder().decode(ParameterValue.self, from: json)
    }

    private func encodedValue(of value: ParameterValue) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        return try XCTUnwrap(object["value"] as? String)
    }
}
