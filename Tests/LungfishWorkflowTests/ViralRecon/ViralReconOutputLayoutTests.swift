// ViralReconOutputLayoutTests.swift - A Viral Recon run's outputs are read from the folders its params send them to
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// VR-INVENTORY (ux-text RATE-BIO 0.1, S2). nf-core/viralrecon 3.0.0 publishes the VCF to `variants/<variant_caller>/`
// and the consensus and lineage tables to `variants/<variant_caller>/consensus/<consensus_caller>/`
// (`conf/modules_illumina.config:13-14,575-698`), and a Nanopore run's to `artic_minion/`
// (`conf/modules_nanopore.config:44-50,185-251`). The inventory read only the default Illumina folders, so a
// `--variant_caller bcftools`, a `--consensus_caller ivar` or a Nanopore run gave a result with no VCF, no consensus
// and no lineage table, and said nothing.

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class ViralReconOutputLayoutTests: XCTestCase {
    private var results: URL!

    override func setUpWithError() throws {
        results = try TestTempDirectory.make(prefix: "viralrecon-output-layout")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(results)
    }

    private static let amplicon = ["platform": "illumina", "protocol": "amplicon", "skip_freyja": "true"]
    private static let ivarHeader = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\n"

    private func write(_ relatives: String..., text: String = "") throws {
        for relative in relatives {
            let url = results.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func relative(_ url: URL?) -> String? {
        guard let url else { return nil }
        let root = results.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
    }

    private func discover(_ params: [String: String], sample: String = "S1") -> ViralReconResultInventory {
        ViralReconResultInventory.discover(in: results, sampleName: sample, params: params)
    }

    // MARK: - The folders a run used

    func testABcftoolsRunIsReadFromTheBcftoolsFolders() throws {
        let consensus = "variants/bcftools/consensus/bcftools"
        try write("variants/bcftools/S1.vcf.gz", "\(consensus)/S1.consensus.fa",
                  "\(consensus)/pangolin/S1.pangolin.csv", "\(consensus)/nextclade/S1.csv")

        let inventory = discover(Self.amplicon.merging(["variant_caller": "bcftools"]) { $1 })

        XCTAssertEqual(relative(inventory.variantVCF), "variants/bcftools/S1.vcf.gz")
        XCTAssertEqual(relative(inventory.consensusFASTA), "\(consensus)/S1.consensus.fa")
        XCTAssertEqual(inventory.lineageFiles.compactMap(relative),
                       ["\(consensus)/nextclade/S1.csv", "\(consensus)/pangolin/S1.pangolin.csv"])
        XCTAssertEqual(inventory.absentOutputs, [])
    }

    func testAnIvarConsensusRunIsReadFromTheIvarConsensusFolder() throws {
        let consensus = "variants/ivar/consensus/ivar"
        try write("variants/ivar/S1.tsv", "variants/ivar/S1.vcf.gz", "\(consensus)/S1.consensus.fa",
                  "\(consensus)/pangolin/S1.pangolin.csv", "\(consensus)/nextclade/S1.csv")

        let inventory = discover(Self.amplicon.merging(["consensus_caller": "ivar"]) { $1 })

        XCTAssertEqual(relative(inventory.variantVCF), "variants/ivar/S1.vcf.gz")
        XCTAssertEqual(relative(inventory.consensusFASTA), "\(consensus)/S1.consensus.fa")
        XCTAssertEqual(inventory.lineageFiles.compactMap(relative),
                       ["\(consensus)/nextclade/S1.csv", "\(consensus)/pangolin/S1.pangolin.csv"])
        XCTAssertEqual(inventory.absentOutputs, [])
    }

    func testANanoporeRunIsReadFromArticMinion() throws {
        try write("artic_minion/S1.pass.vcf.gz", "artic_minion/S1.consensus.fasta",
                  "artic_minion/pangolin/S1.pangolin.csv", "artic_minion/nextclade/S1.csv")

        let inventory = discover(["platform": "nanopore", "protocol": "amplicon", "skip_freyja": "true"])

        XCTAssertEqual(relative(inventory.variantVCF), "artic_minion/S1.pass.vcf.gz")
        XCTAssertEqual(relative(inventory.consensusFASTA), "artic_minion/S1.consensus.fasta")
        XCTAssertEqual(inventory.lineageFiles.compactMap(relative),
                       ["artic_minion/nextclade/S1.csv", "artic_minion/pangolin/S1.pangolin.csv"])
        XCTAssertEqual(inventory.absentOutputs, [])
    }

    // The default run, as a new wizard writes its params and as callers with no params read it, reads as before.
    func testTheDefaultRunReadsAsBefore() throws {
        let consensus = "variants/ivar/consensus/bcftools"
        try write("variants/ivar/S1.tsv", "variants/ivar/S1.vcf.gz", "\(consensus)/S1.consensus.fa",
                  "\(consensus)/pangolin/S1.pangolin.csv", "\(consensus)/nextclade/S1.csv")
        let wizard = Self.amplicon.merging(["variant_caller": "ivar", "consensus_caller": "bcftools",
                                            "skip_freyja_boot": "true"]) { $1 }

        for inventory in [discover(wizard), ViralReconResultInventory.discover(in: results, sampleName: "S1")] {
            XCTAssertEqual(relative(inventory.variantVCF), "variants/ivar/S1.vcf.gz")
            XCTAssertEqual(relative(inventory.consensusFASTA), "\(consensus)/S1.consensus.fa")
            XCTAssertEqual(inventory.lineageFiles.compactMap(relative),
                           ["\(consensus)/nextclade/S1.csv", "\(consensus)/pangolin/S1.pangolin.csv"])
            XCTAssertEqual(inventory.absentOutputs, [])
        }
        XCTAssertEqual(ViralReconOutputLayout(params: wizard), ViralReconOutputLayout(params: ViralReconOutputLayout.defaultRunParams))
    }

    // MARK: - What is absent, and why

    func testACalledSampleNamesEachOutputTheRunDidNotWrite() throws {
        try write("variants/ivar/S1.tsv", "variants/ivar/S1.vcf.gz")

        XCTAssertEqual(discover(Self.amplicon).absentOutputs,
                       [.consensusNotWritten, .pangolinNotWritten, .nextcladeNotWritten])
    }

    // iVar keeps its table for a sample it called with no variants and writes no VCF
    // (`subworkflows/local/variants_ivar/main.nf:43`). The BCFtools consensus reads that VCF
    // (`workflows/viralrecon.nf:549-551`), so the sample has no consensus or lineage table by design.
    func testAnIvarSampleWithNoVariantsReadsAsNoVariantsNotAsMissingFiles() throws {
        try write("variants/ivar/S1.tsv", text: Self.ivarHeader)

        XCTAssertEqual(discover(Self.amplicon).absentOutputs, [.noVariantsNoConsensus])
    }

    // An iVar consensus is made from the alignment (`workflows/viralrecon.nf:532-533`), so it stays expected.
    func testWithAnIvarConsensusASampleWithNoVariantsStillExpectsItsConsensus() throws {
        let consensus = "variants/ivar/consensus/ivar"
        try write("variants/ivar/S1.tsv", text: Self.ivarHeader)
        try write("\(consensus)/S1.consensus.fa", "\(consensus)/pangolin/S1.pangolin.csv")

        XCTAssertEqual(discover(Self.amplicon.merging(["consensus_caller": "ivar"]) { $1 }).absentOutputs,
                       [.noVariants, .nextcladeNotWritten])
    }

    // BCFtools publishes no file for a sample with no variants (`subworkflows/local/variants_bcftools/main.nf:40`),
    // so its trace row is the evidence that it called the sample.
    func testABcftoolsSampleWithNoVariantsIsToldFromAFailedOneByItsTraceRow() throws {
        try write("pipeline_info/execution_trace_2026-11-21_10-00-00.txt",
                  text: "task_id\tname\tstatus\n1\tNFCORE_VIRALRECON:VIRALRECON:VARIANTS_BCFTOOLS:BCFTOOLS_MPILEUP (S1)\tCOMPLETED\n")
        let params = Self.amplicon.merging(["variant_caller": "bcftools"]) { $1 }

        XCTAssertEqual(discover(params).absentOutputs, [.noVariantsNoConsensus])
        XCTAssertEqual(discover(params, sample: "S2").absentOutputs, [.sampleFailed])
    }

    func testANanoporeSampleTheCallerReachedNamesItsMissingFiles() throws {
        try write("pipeline_info/execution_trace_2026-11-21_10-00-00.txt",
                  text: "task_id\tname\tstatus\n1\tNFCORE_VIRALRECON:VIRALRECON:ARTIC_MINION (S1)\tCOMPLETED\n")

        XCTAssertEqual(discover(["platform": "nanopore", "skip_freyja": "true"]).absentOutputs,
                       [.variantsNotWritten, .consensusNotWritten, .pangolinNotWritten, .nextcladeNotWritten])
    }

    func testASkippedStepIsNotExpected() throws {
        try write("variants/ivar/S1.tsv", "variants/ivar/S1.vcf.gz")

        XCTAssertEqual(discover(Self.amplicon.merging(["skip_consensus": "true"]) { $1 }).absentOutputs, [])
        XCTAssertEqual(discover(Self.amplicon.merging(["skip_pangolin": "true"]) { $1 }).absentOutputs,
                       [.consensusNotWritten, .nextcladeNotWritten])
        XCTAssertEqual(discover(Self.amplicon.merging(["skip_variants": "true"]) { $1 }, sample: "S9").absentOutputs, [])
    }

    // MARK: - The result records what is absent

    func testTheResultSidecarNamesTheAbsentOutputsOnlyWhenThereAreAny() throws {
        let reference = results.appendingPathComponent("ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        try write("variants/ivar/S1.tsv", "variants/ivar/S1.vcf.gz")
        let consensus = "variants/ivar/consensus/bcftools"
        try write("variants/ivar/S2.tsv", "variants/ivar/S2.vcf.gz", "\(consensus)/S2.consensus.fa",
                  "\(consensus)/pangolin/S2.pangolin.csv", "\(consensus)/nextclade/S2.csv")

        func sidecar(_ sample: String) throws -> [String: Any] {
            let ingested = try ViralReconResultIngest.ingest(
                resultsDirectory: results, sampleName: sample, referenceBundleURL: reference,
                into: results.appendingPathComponent("Analyses/\(sample)", isDirectory: true), params: Self.amplicon)
            let data = try Data(contentsOf: ingested.bundleDirectory.appendingPathComponent("viralrecon-result.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        XCTAssertEqual(try sidecar("S1")["absentOutputs"] as? [String],
                       ["consensusNotWritten", "pangolinNotWritten", "nextcladeNotWritten"])
        XCTAssertNil(try sidecar("S2")["absentOutputs"])
    }
}
