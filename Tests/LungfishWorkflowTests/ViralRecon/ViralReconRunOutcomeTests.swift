// ViralReconRunOutcomeTests.swift - The samples a finished Viral Recon run failed, by BIO's definition
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, ARCH's ruling on M3 (commit 3) with BIO's definition. nf-core/viralrecon 3.0.0 drops a
// sample with no reads after fastp (`workflows/viralrecon.nf:262-291`) or fewer mapped reads than
// `min_mapped_reads` (`:355-372`) before it calls variants, and prints no line for it. So after exit 0 a sample of
// the effective samplesheet that its caller never reached failed, and a sample its caller reached with no variants
// did not. The caller's files below are the release's (`conf/modules_illumina.config:395-470`,
// `conf/modules_nanopore.config:44-51`). iVar keeps `<sample>.tsv` for a sample with no variants, as Q35's V2 kept
// `sampleA.tsv` with no VCF, and BCFtools publishes no file for such a sample
// (`subworkflows/local/variants_bcftools/main.nf:40`), so its trace row is the evidence.

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class ViralReconRunOutcomeTests: XCTestCase {
    private var results: URL!

    override func setUpWithError() throws {
        results = try TestTempDirectory.make(prefix: "viralrecon-run-outcome")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(results)
    }

    private static let amplicon = ["platform": "illumina", "protocol": "amplicon"]
    private static let ivarHeader = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\n"

    private func write(_ relative: String, _ text: String = "") throws {
        let url = results.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testASampleWithNoVariantOutputFailsAndOneWithNoVariantsDoesNot() throws {
        // V2's sampleA, called with no variants, keeps its iVar table and has no VCF.
        try write("variants/bowtie2/sampleA.sorted.bam")
        try write("variants/ivar/sampleA.tsv", Self.ivarHeader)
        // sample.B, called with variants.
        try write("variants/bowtie2/sample.B.sorted.bam")
        try write("variants/ivar/sample.B.tsv", Self.ivarHeader + "MN908947.3\t241\tC\tT\n")
        try write("variants/ivar/sample.B.vcf.gz")
        // sampleC, aligned with fewer mapped reads than min_mapped_reads, and sampleD, with no reads after fastp.
        try write("variants/bowtie2/sampleC.sorted.bam")
        // sampleE, whose VCF alone is kept, as the stand-in Nextflow writes it.
        try write("variants/ivar/sampleE.vcf.gz")

        let failed = ViralReconRunOutcome.failedSamples(
            ["sampleA", "sample.B", "sampleC", "sampleD", "sampleE"],
            resultsDirectory: results,
            params: Self.amplicon,
            traceText: nil
        )

        XCTAssertEqual(failed, ["sampleC", "sampleD"])
    }

    /// BIO's files for each caller the release can run, and none for a run that skips variant calling.
    func testEachCallerNamesItsOwnFile() {
        let ivar = ViralReconRunOutcome.Caller(
            fileTemplates: ["variants/ivar/@SAMPLE@.tsv", "variants/ivar/@SAMPLE@.vcf.gz"],
            processName: "IVAR_VARIANTS"
        )
        let bcftools = ViralReconRunOutcome.Caller(fileTemplates: ["variants/bcftools/@SAMPLE@.vcf.gz"], processName: "BCFTOOLS_MPILEUP")
        let artic = ViralReconRunOutcome.Caller(fileTemplates: ["artic_minion/@SAMPLE@.pass.vcf.gz"], processName: "ARTIC_MINION")

        XCTAssertEqual(ViralReconRunOutcome.caller(params: Self.amplicon), ivar, "an amplicon run calls with iVar unless told otherwise")
        XCTAssertEqual(ViralReconRunOutcome.caller(params: ["platform": "illumina", "protocol": "metagenomic"]), bcftools)
        XCTAssertEqual(ViralReconRunOutcome.caller(params: Self.amplicon.merging(["variant_caller": "bcftools"]) { $1 }), bcftools)
        XCTAssertEqual(ViralReconRunOutcome.caller(params: ["platform": "illumina", "protocol": "metagenomic", "variant_caller": "ivar"]), ivar)
        XCTAssertEqual(ViralReconRunOutcome.caller(params: ["platform": "nanopore", "protocol": "amplicon"]), artic)
        XCTAssertNil(ViralReconRunOutcome.caller(params: Self.amplicon.merging(["skip_variants": "true"]) { $1 }))
        XCTAssertEqual(
            ViralReconRunOutcome.failedSamples(["S1"], resultsDirectory: results, params: Self.amplicon.merging(["skip_variants": "true"]) { $1 }, traceText: nil),
            [],
            "a run that calls no variants fails no sample"
        )
    }

    func testABCFtoolsSampleWithNoVariantsIsCalledByItsTraceRow() throws {
        let params = ["platform": "illumina", "protocol": "metagenomic"]
        try write("variants/bcftools/S3.vcf.gz")
        let trace = "task_id\tname\tstatus\n"
            + "1\tNFCORE_VIRALRECON:VIRALRECON:VARIANTS_BCFTOOLS:BCFTOOLS_MPILEUP (S1)\tCOMPLETED\n"
            + "2\tNFCORE_VIRALRECON:VIRALRECON:VARIANTS_BCFTOOLS:BCFTOOLS_MPILEUP (S2)\tFAILED\n"

        XCTAssertEqual(
            ViralReconRunOutcome.failedSamples(["S1", "S2", "S3"], resultsDirectory: results, params: params, traceText: trace),
            ["S2"]
        )
        XCTAssertEqual(
            ViralReconRunOutcome.failedSamples(["S1", "S2", "S3"], resultsDirectory: results, params: params, traceText: nil),
            ["S1", "S2"],
            "with no trace a BCFtools sample without variants cannot be told from a dropped one"
        )
    }

    func testTheSamplesheetNamesEachSampleOnceInOrder() throws {
        try write("illumina.csv", "sample,fastq_1,fastq_2\nS2,/r/a_1.fastq.gz,/r/a_2.fastq.gz\nS1,/r/b.fastq.gz,\nS2,/r/c_1.fastq.gz,/r/c_2.fastq.gz\n")
        try write("nanopore.csv", "sample,barcode\r\nA,1\r\nB,2\r\n")
        try write("other.csv", "name,reads\nA,1\n")

        XCTAssertEqual(ViralReconRunOutcome.sampleNames(inSamplesheetAt: results.appendingPathComponent("illumina.csv")), ["S2", "S1"])
        XCTAssertEqual(ViralReconRunOutcome.sampleNames(inSamplesheetAt: results.appendingPathComponent("nanopore.csv")), ["A", "B"])
        XCTAssertEqual(ViralReconRunOutcome.sampleNames(inSamplesheetAt: results.appendingPathComponent("other.csv")), [])
        XCTAssertEqual(ViralReconRunOutcome.sampleNames(inSamplesheetAt: results.appendingPathComponent("missing.csv")), [])
    }

    /// UX's words in the ruling.
    func testTheFailedSamplesLineCountsAndNamesThem() {
        XCTAssertEqual(
            ViralReconRunOutcome.failedSamplesLine(["S1"]),
            "1 failed sample: S1. Too few reads were left after trimming or mapping to call variants."
        )
        XCTAssertEqual(
            ViralReconRunOutcome.failedSamplesLine(["S1", "S2"]),
            "2 failed samples: S1, S2. Too few reads were left after trimming or mapping to call variants."
        )
        XCTAssertNil(ViralReconRunOutcome.failedSamplesLine([]))
    }
}
