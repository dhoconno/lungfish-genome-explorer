// GATKVariantCallPinConformanceTests.swift - The GATK call pin on real GATK
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M1 (2.9 O5, live tests first). `GATKVariantCallPinTests` pins the pair on a stand-in
// runner. This class runs the same steps on the managed gatk-core environment with a tiny reference and a
// forty-read BAM that carries one heterozygous SNP. The class name holds `Conformance`, so the unit tier
// never runs it. Without the tools it skips, and under `LUNGFISH_REQUIRE_TOOLS=1` it fails. It prints the
// run's `##GATKCommandLine` header line, which is where the G5 rule's `Date=` lives.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class GATKVariantCallPinConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gatk-variant-call-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Forty reads of 100 bases that all cover the SNP, half with the alternate base, on both strands.
    private func samText() -> String {
        let reference = Array(GATKPinBundle.referenceSequence)
        let alternate = Character(GATKPinBundle.snpBases.alternate)
        var lines = ["@HD\tVN:1.6\tSO:coordinate", "@SQ\tSN:chr1\tLN:300", "@RG\tID:rg1\tSM:sample\tPL:ILLUMINA\tLB:lib1"]
        for index in 0..<40 {
            let start = 51 + index * 2
            var bases = Array(reference[(start - 1)..<(start + 99)])
            if index % 2 == 1 { bases[GATKPinBundle.snpPosition - start] = alternate }
            let flag = index % 4 < 2 ? 0 : 16
            let quality = String(repeating: "I", count: 100)
            lines.append("read\(index)\t\(flag)\tchr1\t\(start)\t60\t100M\t*\t0\t0\t\(String(bases))\t\(quality)\tRG:Z:rg1")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testRealGATKCallsTheTinyFixtureAndTheAttachLeavesATrack() async throws {
        let conda = CondaManager.shared
        do {
            _ = try await conda.toolPath(name: "gatk", environment: "gatk-core")
            _ = try await conda.toolPath(name: "samtools", environment: "samtools")
        } catch {
            try ToolAvailability.skipOrFail("gatk-core or samtools is not installed: \(error)")
        }
        let fixture = try GATKPinBundle.make(in: root, outputName: "\(GATKPinBundle.trackID).vcf")

        let dictionary = fixture.referenceURL.deletingPathExtension().appendingPathExtension("dict")
        let dictionaryRun = try await conda.runTool(
            name: "gatk",
            arguments: ["CreateSequenceDictionary", "-R", fixture.referenceURL.path, "-O", dictionary.path],
            environment: "gatk-core",
            timeout: 600
        )
        XCTAssertEqual(dictionaryRun.exitCode, 0, dictionaryRun.stderr)

        let sam = root.appendingPathComponent("sample.sam")
        try Data(samText().utf8).write(to: sam)
        let view = try await conda.runTool(
            name: "samtools", arguments: ["view", "-b", "-o", fixture.bamURL.path, sam.path], environment: "samtools", timeout: 120
        )
        XCTAssertEqual(view.exitCode, 0, view.stderr)
        let index = try await conda.runTool(
            name: "samtools", arguments: ["index", fixture.bamURL.path], environment: "samtools", timeout: 120
        )
        XCTAssertEqual(index.exitCode, 0, index.stderr)

        let configuration = GATKHaplotypeCallerConfiguration(
            referenceFASTAURL: fixture.referenceURL,
            inputBAMURL: fixture.bamURL,
            outputVCFURL: fixture.outputVCFURL,
            emitReferenceConfidence: .none
        )
        let request = GATKPipelineExecutionRequest.haplotypeCaller(
            configuration: configuration,
            toolVersion: await GATKInstalledToolVersion.probe(condaManager: conda) ?? "unknown",
            runtimeIdentity: GATKRuntimeIdentity(
                condaEnvironment: conda.rootPrefix.appendingPathComponent("envs/gatk-core", isDirectory: true).path
            )
        )
        let result = try await GATKPipelineExecutor(runner: ManagedGATKCommandRunner()).run(request)
        let attachment = try await GATKBundleVariantAttachmentService().attach(
            request: GATKBundleVariantAttachmentRequest(
                bundleURL: fixture.bundleURL,
                alignmentTrackID: "aln-1",
                outputTrackID: GATKPinBundle.trackID,
                outputTrackName: "Sample BAM \u{2022} GATK HaplotypeCaller",
                outputVCFURL: fixture.outputVCFURL,
                executionProvenanceURL: result.provenanceURL,
                executionRequest: request
            )
        )

        let vcf = try String(contentsOf: fixture.outputVCFURL, encoding: .utf8)
        let lines = vcf.split(separator: "\n", omittingEmptySubsequences: true)
        let header = lines.first { $0.hasPrefix("##GATKCommandLine") }.map(String.init) ?? ""
        print("GATK-PIN header line: \(header)")
        if let directory = ProcessInfo.processInfo.environment["LUNGFISH_RECORD_PINS_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try (vcf).write(toFile: directory + "/gatk-real-run.vcf", atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(header.contains("ID=HaplotypeCaller"), "GATK names its command line in the VCF header: \(header)")
        XCTAssertTrue(header.contains("Date=\""), "the header line holds the run's date: \(header)")
        XCTAssertTrue(header.contains("Version=\"\(request.toolVersion)\""), "the version the record names is the one GATK wrote in its header: \(header) against \(request.toolVersion)")

        let dataLines = lines.filter { !$0.hasPrefix("#") }
        XCTAssertEqual(attachment.variantCount, dataLines.count, "the track holds every call GATK made")
        XCTAssertGreaterThanOrEqual(dataLines.count, 1, "GATK calls the heterozygous SNP of the fixture")
        XCTAssertEqual(attachment.trackInfo.source, "GATK HaplotypeCaller")
        XCTAssertEqual(attachment.trackInfo.path, "variants/gatk/\(GATKPinBundle.trackID).vcf")
        XCTAssertEqual(attachment.trackInfo.databasePath, "variants/gatk/\(GATKPinBundle.trackID).db")

        let execution = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: result.provenanceURL))
        XCTAssertEqual(execution.status, .completed)
        XCTAssertEqual(Array(execution.argv.prefix(2)), ["gatk", "HaplotypeCaller"], "with no CLI command the record names the first GATK command")
        let steps = try execution.legacyWorkflowRun().steps
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.exitCode, 0)
        XCTAssertEqual(Array((steps.first?.command ?? []).prefix(2)), ["gatk", "HaplotypeCaller"])

        let attach = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: attachment.provenanceURL)).legacyWorkflowRun()
        XCTAssertEqual(attach.name, "GATK HaplotypeCaller bundle attachment")
        XCTAssertEqual(Array((attach.steps.first?.command ?? []).prefix(3)), [LungfishAppIdentity.recordedToolName, "gatk-attach", "--bundle"])
    }
}
