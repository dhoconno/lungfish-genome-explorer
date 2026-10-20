// VariantsCallGATKRunRecordTests.swift - Each GATK call into a bundle keeps its own run record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.16, item 5 of the BIO ruling on REC-RUN (PLAN12 section 8, X10). Every GATK run in a bundle
// wrote `variants/gatk/.lungfish-provenance.json`, so a later run replaced the record that an earlier track's
// attach record cites by digest. A stand-in `GATKCommandRunning` answers, so no GATK is needed.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class VariantsCallGATKRunRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variants-call-gatk-run-record")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testASecondGATKCallKeepsTheFirstTracksRecords() async throws {
        let bundle = try makeBundle()
        let first = try await callGATK(bundle: bundle, name: "First GATK")
        let firstAttach = try Data(contentsOf: first.provenanceURL)
        let cited = try citedRunRecord(of: first.provenanceURL, in: bundle)
        let firstRun = try Data(contentsOf: cited.url)

        _ = try await callGATK(bundle: bundle, name: "Second GATK")

        XCTAssertEqual(try Data(contentsOf: first.provenanceURL), firstAttach, "the first track's attach record is as it was")
        XCTAssertEqual(try Data(contentsOf: cited.url), firstRun, "the first track's run record is as it was")
        XCTAssertEqual(cited.sha256, ProvenanceRecorder.sha256(of: cited.url), "the attach record's digest of its run record matches the file")
        XCTAssertEqual(cited.url.lastPathComponent, "\(first.trackInfo.id).gatk-run.lungfish-provenance.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedRunRecord(in: bundle).path), "no call writes the shared name")
    }

    func testAFailedSecondGATKRunLeavesTheFirstTracksRunRecord() async throws {
        let bundle = try makeBundle()
        let first = try await callGATK(bundle: bundle, name: "First GATK")
        let cited = try citedRunRecord(of: first.provenanceURL, in: bundle)
        let firstRun = try Data(contentsOf: cited.url)

        do {
            _ = try await callGATK(bundle: bundle, name: "Second GATK", exitCode: 3)
            XCTFail("a non-zero GATK exit fails the call")
        } catch let error as GATKPipelineExecutionError {
            guard case .commandFailed(let exitCode, let recordURL) = error else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 3)
            XCTAssertNotEqual(recordURL.standardizedFileURL.path, cited.url.standardizedFileURL.path, "the failed run records into its own track's name")
            XCTAssertTrue(recordURL.lastPathComponent.hasSuffix(".gatk-run.lungfish-provenance.json"), recordURL.lastPathComponent)
        }

        XCTAssertEqual(try Data(contentsOf: cited.url), firstRun, "the first track's run record is as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedRunRecord(in: bundle).path), "no call writes the shared name")
    }

    // MARK: Helpers

    private func sharedRunRecord(in bundle: URL) -> URL {
        bundle.appendingPathComponent("variants/gatk/\(ProvenanceRecorder.provenanceFilename)")
    }

    /// The run record an attach record cites in `sourceExecutionProvenance`, with the digest its input gave that file.
    private func citedRunRecord(of attachRecordURL: URL, in bundle: URL) throws -> (url: URL, sha256: String?) {
        let run = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: attachRecordURL)).legacyWorkflowRun()
        let cited = try XCTUnwrap(run.parameters["sourceExecutionProvenance"]?.stringValue)
        let name = URL(fileURLWithPath: cited).lastPathComponent
        let input = try XCTUnwrap(run.steps.flatMap(\.inputs).first { URL(fileURLWithPath: $0.path).lastPathComponent == name })
        return (bundle.appendingPathComponent("variants/gatk/\(name)"), input.sha256)
    }

    private func callGATK(bundle: URL, name: String, exitCode: Int32 = 0) async throws -> GATKBundleVariantAttachmentResult {
        let command = try VariantsCommand.CallSubcommand.parse(
            ["--bundle", bundle.path, "--alignment-track", "aln-1", "--caller", "gatk", "--name", name]
        )
        return try await command.executeGATK(
            runner: RunRecordStandInGATKRunner(exitCode: exitCode),
            toolVersion: "4.6.1.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/envs/gatk-core"),
            recordedArguments: command.recordedCommandLine(arguments: []),
            outputExtension: "vcf",
            emitEvent: { _ in }
        )
    }

    private func makeBundle() throws -> URL {
        let bundle = root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        for folder in ["genome", "alignments"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(">chr1\nACGTACGTACGT\n".utf8).write(to: bundle.appendingPathComponent("genome/reference.fa"))
        try Data("chr1\t12\t6\t12\t13\n".utf8).write(to: bundle.appendingPathComponent("genome/reference.fa.fai"))
        try Data("bam-bytes".utf8).write(to: bundle.appendingPathComponent("alignments/sample.bam"))
        try Data("bai-bytes".utf8).write(to: bundle.appendingPathComponent("alignments/sample.bam.bai"))
        try BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: 12,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 12, offset: 6, lineBases: 12, lineWidth: 13)]
            ),
            alignments: [
                AlignmentTrackInfo(id: "aln-1", name: "Sample BAM", sourcePath: "alignments/sample.bam", indexPath: "alignments/sample.bam.bai"),
            ]
        ).save(to: bundle)
        return bundle
    }
}

/// Answers a GATK command as GATK does for a tiny run: it writes the VCF named by `-O` and its index. With a
/// non-zero `exitCode` it writes nothing and fails.
private struct RunRecordStandInGATKRunner: GATKCommandRunning {
    let exitCode: Int32

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        guard exitCode == 0 else {
            return GATKCommandExecutionResult(exitCode: exitCode, stdout: "", stderr: "stand-in failure", wallTime: 0.1)
        }
        guard let flag = command.arguments.firstIndex(of: "-O") else { throw NSError(domain: "RunRecordStandInGATKRunner", code: 1) }
        let output = URL(fileURLWithPath: command.arguments[flag + 1])
        let vcf = "##fileformat=VCFv4.2\n##contig=<ID=chr1,length=12>\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
            + "chr1\t4\t.\tT\tG\t60\tPASS\tDP=18\n"
        try Data(vcf.utf8).write(to: output)
        try Data().write(to: output.appendingPathExtension("idx"))
        return GATKCommandExecutionResult(exitCode: 0, stdout: "", stderr: "", wallTime: 0.5)
    }
}
