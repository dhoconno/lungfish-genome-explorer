// NativeRecordTypedReadingTests.swift - Alignment, tree and receipt records that state their status read as typed records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Phase 2.7 lanes B6 and B8 (panel decision P13). The primitive adapter recognizes an alignment,
/// tree or genotype workbook receipt record as a typed record only when it states its status, so a
/// record written before 2.7 keeps the Older record format and a new one reads with its stated status
/// and can be exported as a script. Options in the envelope's three groups read as those groups.
final class NativeRecordTypedReadingTests: XCTestCase {
    private static var alignmentRecord: [String: Any] { [
        "schemaVersion": 1,
        "createdAt": "2026-10-11T12:00:00Z",
        "workflowName": "multiple-sequence-alignment-mafft",
        "toolName": "lungfish align mafft",
        "toolVersion": "0.1.0",
        "argv": ["lungfish", "align", "mafft", "input.lungfishref", "--output", "aligned.lungfishmsa"],
        "reproducibleCommand": "lungfish align mafft input.lungfishref --output aligned.lungfishmsa",
        "runtimeIdentity": ["executablePath": "<external>/lungfish-cli", "operatingSystemVersion": "macOS test"],
        "input": ["path": "/project/input.lungfishref", "checksumSHA256": String(repeating: "a", count: 64), "fileSize": 10],
        "output": ["path": "/project/aligned.lungfishmsa", "checksumSHA256": String(repeating: "b", count: 64), "fileSize": 20],
        // A keyed `files` map, as the alignment import writes it, which the envelope decoder refuses.
        "files": ["alignment/primary.aligned.fasta": [
            "path": "/project/aligned.lungfishmsa/alignment/primary.aligned.fasta",
            "checksumSHA256": String(repeating: "c", count: 64), "fileSize": 30,
        ]],
        "exitStatus": 0,
        "wallTimeSeconds": 2.0,
    ] }

    func testAnAlignmentRecordReadsAsATypedRecordOnlyWhenItStatesItsStatus() throws {
        let older = try ProvenanceEnvelopeReader.read(Self.data(Self.alignmentRecord))
        XCTAssertEqual(older.shape, .primitive, "a record written before 2.7 keeps the Older record format")
        XCTAssertFalse(older.statusWasRecorded)
        XCTAssertTrue(ProvenanceExportPinGate.isOlderRecordFormat(older.shape))

        let current = try ProvenanceEnvelopeReader.read(Self.data(Self.alignmentRecord.merging(["status": "completed"]) { $1 }))
        XCTAssertEqual(current.shape, .typedRecord)
        XCTAssertTrue(current.statusWasRecorded)
        XCTAssertEqual(current.envelope.status, .completed)
        XCTAssertFalse(ProvenanceExportPinGate.isOlderRecordFormat(current.shape), "a typed record can export as a script")
        XCTAssertNil(current.envelope.runtimeIdentity.processIdentifier)
        XCTAssertEqual(current.envelope.runtimeIdentity.executablePath, "<external>/lungfish-cli")

        let cancelled = try ProvenanceEnvelopeReader.read(Self.data(Self.alignmentRecord.merging(["status": "cancelled"]) { $1 }))
        XCTAssertEqual(cancelled.envelope.status, .cancelled, "the stated status wins over the exit status")
    }

    func testTreeAndReceiptRecordsThatStateTheirStatusReadAsTypedRecords() throws {
        let typed: [String: [String: Any]] = [
            "tree inference": [
                "workflowName": "phylogenetic-tree-infer-iqtree", "toolName": "lungfish tree infer iqtree",
                "argv": ["lungfish", "tree", "infer", "iqtree"], "exitStatus": 0, "status": "completed",
            ],
            "tree import": [
                "workflowName": "lungfish import tree", "toolName": "lungfish import tree",
                "checksums": ["tree/primary.nwk": String(repeating: "c", count: 64)], "exitStatus": 0, "status": "completed",
            ],
            "workbook receipt": [
                "workflowName": "genotype.export.xlsx", "toolName": "lungfish genotype Excel export",
                "argv": ["lungfish-cli", "genotype", "export-xlsx"], "exitStatus": 0, "status": "completed",
            ],
            "workbook receipt since lane 13.51": [
                "workflowName": "lungfish genotype export-xlsx", "requestWorkflowName": "genotype.export.xlsx",
                "toolName": "lungfish-cli", "toolKind": "cli",
                "argv": ["lungfish-cli", "genotype", "export-xlsx"], "exitStatus": 0, "status": "completed",
            ],
        ]
        for (name, record) in typed {
            let reading = try ProvenanceEnvelopeReader.read(Self.data(record))
            XCTAssertEqual(reading.shape, .typedRecord, name)
            XCTAssertTrue(reading.statusWasRecorded, name)
            var older = record
            older["status"] = nil
            XCTAssertEqual(try ProvenanceEnvelopeReader.read(Self.data(older)).shape, .primitive, "\(name) without status")
        }

        let untyped: [String: [String: Any]] = [
            "a word that names no status": Self.alignmentRecord.merging(["status": "succeeded"]) { $1 },
            "another writer's record": ["toolName": "iqtree2", "operation": "tree", "exitStatus": 0, "status": "completed"],
        ]
        for (name, record) in untyped {
            let reading = try ProvenanceEnvelopeReader.read(Self.data(record))
            XCTAssertEqual(reading.shape, .primitive, name)
            XCTAssertFalse(reading.statusWasRecorded, name)
        }
    }

    /// The options of a version 2 envelope the envelope decoder refuses read as the three groups.
    func testOptionsInTheEnvelopeGroupsReadAsThoseGroups() throws {
        let grouped: [String: Any] = [
            "schemaVersion": 2, "createdAt": "2026-10-11T12:00:00Z", "workflowName": "fastq.trim",
            "toolName": "lungfish-cli fastq trim", "exitStatus": 0,
            "options": [
                "explicit": ["threads": 4],
                "defaults": ["threads": 2, "quality": 20],
                "resolvedDefaults": ["readSetPlan": "paired"],
            ],
        ]
        let reading = try ProvenanceEnvelopeReader.read(Self.data(grouped))
        XCTAssertEqual(reading.shape, .primitive, "no runtimeIdentity, so the envelope decoder refuses it")
        XCTAssertEqual(reading.envelope.options.explicit, ["threads": .integer(4)])
        XCTAssertEqual(reading.envelope.options.defaults, ["threads": .integer(2), "quality": .integer(20)])
        XCTAssertEqual(reading.envelope.options.resolvedDefaults, ["readSetPlan": .string("paired")])

        var flat = grouped
        flat["options"] = ["defaults": ["threads": 2], "name": "x"]
        let flatReading = try ProvenanceEnvelopeReader.read(Self.data(flat))
        XCTAssertEqual(flatReading.envelope.options.explicit["name"], .string("x"))
        XCTAssertEqual(flatReading.envelope.options.explicit["defaults"], .dictionary(["threads": .integer(2)]))
        XCTAssertEqual(flatReading.envelope.options.defaults, [:], "options beside other keys read as before")
    }

    private static func data(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }
}
