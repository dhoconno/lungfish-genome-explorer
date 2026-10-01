// ProvenanceLineageResolverTests.swift - Lineage walks upstream through input sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// A variant track's record names the BAM it read; the BAM's record names the
/// reads it mapped. The resolver follows those links by path (re-rooted into
/// the current project when the record was written elsewhere) and by SHA-256
/// when the recorded path resolves nothing, so the chain starts at the reads.
final class ProvenanceLineageResolverTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    /// The project root the records were written under, on another machine.
    private let foreign = "/elsewhere/Original Demo.lungfish"

    private let readsSHA = String(repeating: "a", count: 64)
    private let bamSHA = String(repeating: "b", count: 64)
    private let vcfSHA = String(repeating: "c", count: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineage-resolver-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Copied Demo.lungfish", isDirectory: true)
        for folder in ["Imports/reads.lungfishfastq", "Analyses/minimap2-1/ref.lungfishref/variants"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func record(_ path: String, _ sha: String, _ role: FileRole) -> FileRecord {
        FileRecord(path: path, sha256: sha, sizeBytes: 4, format: nil, role: role)
    }

    /// Writes a legacy `WorkflowRun` sidecar verbatim, as the shipped demos
    /// were written: absolute paths of the recording machine, no placeholders.
    @discardableResult
    private func writeLegacy(_ run: WorkflowRun, to relativePath: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = project.appendingPathComponent(relativePath)
        try encoder.encode(run).write(to: url, options: .atomic)
        return url
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

    private func writeChain(createBAM: Bool) throws -> URL {
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
        if createBAM {
            try Data("bam!".utf8).write(to: project.appendingPathComponent("Analyses/minimap2-1/reads.sorted.bam"))
        }
        return try writeLegacy(
            run("lungfish variants call", tool: "bcftools",
                inputs: [record(bamPath, bamSHA, .input)],
                outputs: [record(vcfPath, vcfSHA, .output)]),
            to: "Analyses/minimap2-1/ref.lungfishref/variants/vc-1.lungfish-provenance.json"
        )
    }

    private func resolve(_ sidecar: URL) throws -> [ProvenanceLineageResolver.ResolvedRun] {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        return ProvenanceLineageResolver().resolve(envelope: envelope, sidecarURL: sidecar)
    }

    // MARK: - Tests

    func testChainStartsAtTheReadsWhenRecordedPathsAreForeign() throws {
        let sidecar = try writeChain(createBAM: false)
        let runs = try resolve(sidecar)
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish import fastq", "lungfish map", "lungfish variants call"])
        XCTAssertEqual(
            runs.compactMap(\.sidecarURL?.lastPathComponent),
            [".lungfish-provenance.json", ".lungfish-provenance.json", "vc-1.lungfish-provenance.json"]
        )
    }

    func testChainFollowsARerootedPathBeforeFallingBackToChecksums() throws {
        let sidecar = try writeChain(createBAM: true)
        let runs = try resolve(sidecar)
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish import fastq", "lungfish map", "lungfish variants call"])
        // The variant record's BAM input reads as the copy inside this project.
        let variants = try XCTUnwrap(runs.last)
        XCTAssertEqual(
            variants.envelope.steps.first?.inputs.first?.path,
            project.standardizedFileURL.appendingPathComponent("Analyses/minimap2-1/reads.sorted.bam").path
        )
    }

    func testCycleTerminatesAndUnreadableSidecarsAreSkipped() throws {
        let sidecar = try writeChain(createBAM: false)
        // A record whose output is the reads and whose input is the VCF closes a loop.
        try writeLegacy(
            run("lungfish loop", tool: "loop",
                inputs: [record("\(foreign)/x/vc-1.vcf.gz", vcfSHA, .input)],
                outputs: [record("\(foreign)/x/reads.fastq.gz", readsSHA, .output)]),
            to: "Analyses/loop.lungfish-provenance.json"
        )
        try Data("{ not json".utf8).write(to: project.appendingPathComponent("Analyses/broken.lungfish-provenance.json"))

        let runs = try resolve(sidecar)
        XCTAssertTrue(runs.map(\.envelope.workflowName).contains("lungfish map"), "\(runs.map(\.envelope.workflowName))")
        XCTAssertEqual(runs.last?.envelope.workflowName, "lungfish variants call")
        XCTAssertEqual(Set(runs.map(\.envelope.id)).count, runs.count, "each run appears once")
    }

    func testMissingUpstreamKeepsWhatIsKnown() throws {
        let sidecar = try writeLegacy(
            run("lungfish variants call", tool: "bcftools",
                inputs: [record("\(foreign)/Analyses/minimap2-1/reads.sorted.bam", bamSHA, .input)],
                outputs: [record("\(foreign)/x/vc-1.vcf.gz", vcfSHA, .output)]),
            to: "Analyses/minimap2-1/ref.lungfishref/variants/vc-1.lungfish-provenance.json"
        )
        let runs = try resolve(sidecar)
        XCTAssertEqual(runs.map(\.envelope.workflowName), ["lungfish variants call"])
    }
}
