// NativeRecordWorkflowWriterTests.swift - Records the IO and Workflow writers write since Phase 2.7 B6, read back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.7 lane B6 (panel decision P13). The alignment and tree records the IO writers write, the
/// genotype workbook receipt and the TaxTriage record state their status, name no install path or
/// storage path and copy no conda variable the shell set, and the reader reads them with that status.
final class NativeRecordWorkflowWriterTests: XCTestCase {
    /// The records the IO writers write now read with their stated status, and never as the Older
    /// record format. With its status removed, as a record written before 2.7, the alignment import
    /// record keeps the Older record format.
    func testRecordsTheIOWritersWriteReadWithTheirStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b6-io-records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fasta = root.appendingPathComponent("input.fasta")
        try ">seq1\nACGT--\n>seq2\nA-GTAA\n".write(to: fasta, atomically: true, encoding: .utf8)
        let msa = root.appendingPathComponent("input.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: fasta, to: msa, options: .init(name: "input"))
        let newick = root.appendingPathComponent("source.nwk")
        try "((A:0.1,B:0.2):0.3,C:0.4);".write(to: newick, atomically: true, encoding: .utf8)
        let tree = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: root.appendingPathComponent("T.lungfishtree"))
        let rerooted = root.appendingPathComponent("R.lungfishtree", isDirectory: true)
        _ = try tree.rerootedBundle(on: "C", to: rerooted, provenance: .init(toolName: "lungfish tree reroot", argv: ["lungfish"]))

        for bundle in [msa, tree.url, rerooted] {
            let sidecar = bundle.appendingPathComponent(".lungfish-provenance.json")
            let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: sidecar))
            XCTAssertFalse(ProvenanceExportPinGate.isOlderRecordFormat(reading.shape), bundle.lastPathComponent)
            XCTAssertTrue(reading.statusWasRecorded, bundle.lastPathComponent)
            XCTAssertEqual(reading.envelope.status, .completed, bundle.lastPathComponent)
            XCTAssertNil(reading.envelope.runtimeIdentity.processIdentifier, bundle.lastPathComponent)
        }
        // The tree records decode as envelopes, as they did before, and now state their status. The
        // alignment import record's keyed `files` map sends it to the adapter, which reads it as typed.
        XCTAssertEqual(try ProvenanceEnvelopeReader.read(fromSidecar: tree.url.appendingPathComponent(".lungfish-provenance.json"))?.shape, .envelope)
        let sidecar = msa.appendingPathComponent(".lungfish-provenance.json")
        XCTAssertEqual(try ProvenanceEnvelopeReader.read(fromSidecar: sidecar)?.shape, .typedRecord)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        older["status"] = nil
        XCTAssertEqual(try ProvenanceEnvelopeReader.read(Self.data(older)).shape, .primitive, "an alignment record written before 2.7")
    }

    func testTheWorkbookReceiptStatesItsStatusAndNamesNoInstallOrStoragePath() async throws {
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "needs the managed openpyxl python")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b6-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = "2026-10-11T12:00:00Z"
        let result = GenotypeTestFixtures.makeResult(calls: [GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A*001", reads: 3)])
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil))
        let roots = PortablePath.defaultManagedRoots
        let output = root.appendingPathComponent("report.xlsx")
        let exported = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot,
            outputURL: output, provenance: .init(toolVersion: "test-version", argv: ["lungfish-cli", "genotype", "export-xlsx"],
                runtimeContext: [
                    "cliExecutable": "/Applications/Lungfish.app/Contents/MacOS/lungfish-cli",
                    "condaEnvironment": "openpyxl",
                    "condaPrefix": roots.toolRoot.path,
                    "python": roots.toolRoot.appendingPathComponent("envs/openpyxl/bin/python").path,
                ]))
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.receiptURL)) as? [String: Any])

        XCTAssertEqual(receipt["status"] as? String, "completed")
        XCTAssertEqual(receipt["schemaVersion"] as? Int, 1, "the receipt keeps its own shape")
        XCTAssertEqual(receipt["runtimeContext"] as? [String: String], [
            "cliExecutable": "<external>/lungfish-cli",
            "condaEnvironment": "openpyxl",
            "condaPrefix": "<tool-root>",
            "python": "<tool-root>/envs/openpyxl/bin/python",
        ])
        let runtime = try XCTUnwrap(receipt["runtime"] as? [String: Any])
        let pythonExecutable = try XCTUnwrap(runtime["pythonExecutable"] as? String)
        for managedRoot in [roots.toolRoot.path, roots.storageRoot.path] {
            XCTAssertFalse(pythonExecutable.hasPrefix(managedRoot + "/"), pythonExecutable)
        }
        XCTAssertNotNil(runtime["renderer"] as? [String: Any], "the renderer summary stays")
        XCTAssertEqual(receipt["executedArgv"] as? [String], exported.execution.executedArgv, "what ran keeps its real path")

        let reading = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: exported.receiptURL))
        XCTAssertEqual(reading.shape, .typedRecord)
        XCTAssertEqual(reading.envelope.status, .completed)
    }

    func testTheTaxTriageRecordStatesNoInheritedCondaPrefix() throws {
        let saved = ProcessInfo.processInfo.environment["CONDA_PREFIX"]
        setenv("CONDA_PREFIX", "/b6-inherited/conda-prefix", 1)
        defer { if let saved { setenv("CONDA_PREFIX", saved, 1) } else { unsetenv("CONDA_PREFIX") } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("b6-taxtriage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("report"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fastq = directory.appendingPathComponent("SampleD.fastq")
        let report = directory.appendingPathComponent("report/SampleD.organisms.report.txt")
        let log = directory.appendingPathComponent("nextflow.log")
        try "@r\nACGT\n+\nIIII\n".write(to: fastq, atomically: true, encoding: .utf8)
        try "organism\treads\nExample virus\t7\n".write(to: report, atomically: true, encoding: .utf8)
        try "TaxTriage complete\n".write(to: log, atomically: true, encoding: .utf8)
        let config = TaxTriageConfig(samples: [TaxTriageSample(sampleId: "SampleD", fastq1: fastq)],
            outputDirectory: directory, maxCpus: 4, profile: "docker")
        try TaxTriageResult(config: config, runtime: 1, exitCode: 0, outputDirectory: directory, reportFiles: [report],
            logFile: log, traceFile: nil, allOutputFiles: [report, log]).save()

        _ = try XCTUnwrap(try MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: directory))
        let envelope = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: directory)?.envelope)
        XCTAssertEqual(envelope.runtimeIdentity.condaEnvironment, "nextflow")
        XCTAssertNil(envelope.runtimeIdentity.condaPrefix, "the shell's CONDA_PREFIX is not the run's")
    }

    private static func data(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }
}
