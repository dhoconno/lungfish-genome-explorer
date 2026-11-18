// RoutingSafetyNetFixtures+RNASeq.swift - An RNA-seq result for the routing table and the view-switch matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The result is written by `RNASeqResultWriter`, the one writer of the kind, from an in-memory two-sample count table,
// so the folder is the one `lungfish-cli import rnaseq` leaves and the routing row opens what the CLI writes.

import Foundation
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension RoutingSafetyNetFixtures {
    /// A two-sample bulk RNA-seq result in `directory`, and the name its manifest carries.
    static func rnaseqResultBundle(in directory: URL) throws -> (bundle: URL, name: String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let table = RNASeqCountTable(sampleIDs: ["S1", "S2"], rows: [
            RNASeqCountTable.Row(id: "G1", counts: [10, 20]),
            RNASeqCountTable.Row(id: "G2", counts: [0, 5]),
        ])
        let name = "Two sample test"
        let request = RNASeqResultWriter.Request(
            name: name, modality: .bulk,
            origin: .init(kind: .imported, tool: "salmon", toolVersion: "1.10.0"),
            route: .init(id: "salmon-selective-alignment", tool: "salmon", toolVersion: "1.10.0", settings: ["unit": "NumReads"]),
            referenceSet: nil,
            samples: ["S1", "S2"].map { RNASeqSampleRecord(id: $0, runs: [$0]) },
            genes: .ids(table.rows.map(\.id)),
            counts: [.init(rows: .gene, column: .default, unit: .reads, table: table)],
            sourceFiles: [], notHost: [])
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        let bundle = try writer.write(
            request, to: directory.appendingPathComponent("two-sample.lungfishrnaseq", isDirectory: true), envelope: envelope)
        return (bundle, name)
    }
}
