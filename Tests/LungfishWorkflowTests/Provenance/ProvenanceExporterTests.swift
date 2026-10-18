// ProvenanceExporterTests.swift - An export is all or nothing, whatever its caller's task does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// A lineage walk stops when the task that asked for it is cancelled, which suits the Inspector
/// that shows it. An export writes a record, and a record that reads as complete with its upstream
/// runs missing is worse than none, so the exporter walks the whole chain whatever its task does.
/// The pin gate reads the same chain, so a cancelled gate must not miss an unpinned upstream tool.
final class ProvenanceExporterTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    /// The project root the records were written under, on another machine.
    private let foreign = "/elsewhere/Original Demo.lungfish"

    private let readsSHA = String(repeating: "a", count: 64)
    private let bamSHA = String(repeating: "b", count: 64)
    private let vcfSHA = String(repeating: "c", count: 64)

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "exporter-cancel")
        project = root.appendingPathComponent("Copied Demo.lungfish", isDirectory: true)
        for folder in ["Imports/reads.lungfishfastq", "Analyses/minimap2-1/ref.lungfishref/variants"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        if let root {
            TestTempDirectory.cleanup(root)
        }
    }

    // MARK: - Fixtures

    private func record(_ path: String, _ sha: String, _ role: FileRole) -> FileRecord {
        FileRecord(path: path, sha256: sha, sizeBytes: 4, format: nil, role: role)
    }

    private func run(_ name: String, tool: String, inputs: [FileRecord], outputs: [FileRecord]) -> WorkflowRun {
        WorkflowRun(
            name: name,
            endTime: Date(),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: tool, toolVersion: "1.0",
                    command: [tool, "run"],
                    inputs: inputs, outputs: outputs,
                    exitCode: 0, wallTime: 1
                ),
            ]
        )
    }

    /// Writes a legacy `WorkflowRun` sidecar verbatim, as the shipped demos were written.
    @discardableResult
    private func writeLegacy(_ run: WorkflowRun, to relativePath: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = project.appendingPathComponent(relativePath)
        try encoder.encode(run).write(to: url, options: .atomic)
        return url
    }

    /// The import of some reads, the mapping of those reads and the variant call on the BAM, each
    /// with a sidecar of its own. The BAM is not on disk, so the walk upstream of the variant record
    /// finds the other two by checksum. Returns the variant record's sidecar.
    private func writeChain() throws -> URL {
        let readsPath = "\(foreign)/Imports/reads.lungfishfastq/reads.fastq.gz"
        let bamPath = "\(foreign)/Analyses/minimap2-1/reads.sorted.bam"
        let vcfPath = "\(foreign)/Analyses/minimap2-1/ref.lungfishref/variants/vc-1.vcf.gz"
        try writeLegacy(
            run("lungfish import fastq", tool: "clumpify.sh",
                inputs: [record("/elsewhere/inputs/raw.fastq.gz", String(repeating: "9", count: 64), .input)],
                outputs: [record(readsPath, readsSHA, .output)]),
            to: "Imports/reads.lungfishfastq/.lungfish-provenance.json"
        )
        try writeLegacy(
            run("lungfish map", tool: "minimap2",
                inputs: [record(readsPath, readsSHA, .input)],
                outputs: [record(bamPath, bamSHA, .output)]),
            to: "Analyses/minimap2-1/.lungfish-provenance.json"
        )
        return try writeLegacy(
            run("lungfish variants call", tool: "bcftools",
                inputs: [record(bamPath, bamSHA, .input)],
                outputs: [record(vcfPath, vcfSHA, .output)]),
            to: "Analyses/minimap2-1/ref.lungfishref/variants/vc-1.lungfish-provenance.json"
        )
    }

    // MARK: - Tests

    /// A cancel must not cut an export's walk short. Cancelled before it starts, the export still
    /// writes the record of every run that fed the selected one, and the chain the pin gate reads
    /// still holds all three sidecars.
    func testExportIgnoresTaskCancellation() async throws {
        let sidecar = try writeChain()
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let output = root.appendingPathComponent("export", isDirectory: true)
        let exporter = ProvenanceExporter(signingProvider: nil)

        let outcome = try await Task.detached { () throws -> (cancelled: Bool, sidecars: [URL]) in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try exporter.exportBundle(envelope, format: .json, to: output, sourceSidecarURL: sidecar)
            let expansion = exporter.expandProvenanceChain(
                startingWith: envelope,
                sourceSidecarURL: sidecar,
                sourceRootURL: nil
            )
            return (Task.isCancelled, expansion.sidecarURLs)
        }.value

        XCTAssertTrue(outcome.cancelled, "the export ran in a cancelled task")
        let written = try Data(contentsOf: output.appendingPathComponent("provenance.json"))
        let exported = try ProvenanceEnvelopeReader.decodeCanonical(written)
        XCTAssertEqual(
            exported.steps.map(\.toolName),
            ["clumpify.sh", "minimap2", "bcftools"],
            "the exported record keeps the runs upstream of the selected one"
        )
        XCTAssertEqual(
            outcome.sidecars.map(\.lastPathComponent),
            [".lungfish-provenance.json", ".lungfish-provenance.json", "vc-1.lungfish-provenance.json"],
            "the chain the pin gate reads is whole"
        )
    }
}
