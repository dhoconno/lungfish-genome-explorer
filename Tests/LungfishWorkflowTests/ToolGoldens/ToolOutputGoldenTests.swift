// ToolOutputGoldenTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Byte-exact goldens of every external tool's stdout, exit code and named
// outputs, run through the LGE runner that serves the tool today (review
// finding R7, Phase 2.2 lane 1B). Phase 2 moves NativeToolRunner,
// CondaManager.runTool and ProcessManager onto one ToolProcess primitive, and
// these goldens must stay byte-identical across that move. They catch a
// truncated stream, a lost exit code and a changed argv.
//
// Run with the managed tools of dependency set 2026.2:
//   LUNGFISH_STORAGE_ROOT=$HOME/.lungfish swift test --skip-update \
//       --build-system swiftbuild --filter ToolOutputGoldenTests
// Set LUNGFISH_CAPTURE_TOOL_GOLDENS=1 to rewrite the goldens. Capture runs
// each case twice and writes nothing for a case whose two runs differ.
// Tests/Fixtures/golden/tools/README.md describes the layout and the masks.
// The test methods below are one line per case of ToolGoldenCase.allCases.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ToolOutputGoldenTests: XCTestCase {
    // MARK: Table integrity

    func testCaseTableHasUniqueIDsATestPerCaseAndNoStaleGolden() {
        let ids = ToolGoldenCase.allCases.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate case ids")

        let testNames = Self.defaultTestSuite.tests.map(\.name)
        for id in ids {
            let method = "test_" + id.replacingOccurrences(of: "-", with: "_")
            XCTAssertTrue(
                testNames.contains { $0.hasSuffix(" \(method)]") || $0.hasSuffix(".\(method)") },
                "case \(id) has no test method \(method)"
            )
        }
        for captured in ToolGoldenStore.capturedCaseIDs() {
            XCTAssertTrue(ids.contains(captured), "golden folder \(captured) has no case in the table")
        }
    }

    // MARK: Runner

    private func check(_ id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard let goldenCase = ToolGoldenCase.named(id) else {
            XCTFail("no case named \(id)", file: file, line: line)
            return
        }
        let storage = ToolGoldenStorage.resolve()
        do {
            try await ToolGoldenHarness.checkAvailability(goldenCase, storage: storage)
        } catch let error as ToolGoldenHarnessError {
            try ToolAvailability.skipOrFail(error.description, file: file, line: line)
        }

        let started = Date()
        let fresh = try await Self.runOnce(goldenCase, storage: storage)

        if ToolGoldenStore.isCaptureMode {
            let second = try await Self.runOnce(goldenCase, storage: storage)
            let drift = ToolGoldenStore.differences(
                expected: fresh, actual: second, expectedLabel: "run-1", actualLabel: "run-2"
            )
            guard drift.isEmpty else {
                XCTFail("\(id) differs between two runs, nothing captured:\n\(drift)", file: file, line: line)
                return
            }
            try ToolGoldenStore.write(id: id, files: fresh)
            print("ToolOutputGoldenTests captured \(id) (two runs) in \(Self.elapsed(since: started))")
            return
        }

        guard let golden = try ToolGoldenStore.read(id: id) else {
            XCTFail("\(id) has no golden. Capture it with LUNGFISH_CAPTURE_TOOL_GOLDENS=1.", file: file, line: line)
            return
        }
        let diff = ToolGoldenStore.differences(
            expected: golden, actual: fresh, expectedLabel: "golden/\(id)", actualLabel: "fresh/\(id)"
        )
        print("ToolOutputGoldenTests compared \(id) in \(Self.elapsed(since: started))")
        if !diff.isEmpty {
            print(diff)
            XCTFail("\(id) differs from its golden:\n\(diff)", file: file, line: line)
        }
    }

    private static func runOnce(_ goldenCase: ToolGoldenCase, storage: ToolGoldenStorage) async throws -> [String: Data] {
        let scratch = try ToolGoldenHarness.makeScratch(for: goldenCase)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await ToolGoldenHarness(goldenCase: goldenCase, storage: storage, scratch: scratch)
            .produceGoldenFiles()
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    // MARK: One test per case

    func test_samtools_view_header() async throws { try await check("samtools-view-header") }
    func test_samtools_view_records_large() async throws { try await check("samtools-view-records-large") }
    func test_samtools_depth_large() async throws { try await check("samtools-depth-large") }
    func test_samtools_flagstat() async throws { try await check("samtools-flagstat") }
    func test_samtools_idxstats() async throws { try await check("samtools-idxstats") }
    func test_samtools_sort_by_name() async throws { try await check("samtools-sort-by-name") }
    func test_samtools_faidx() async throws { try await check("samtools-faidx") }
    func test_samtools_view_missing_input() async throws { try await check("samtools-view-missing-input") }
    func test_bcftools_view() async throws { try await check("bcftools-view") }
    func test_bcftools_stats() async throws { try await check("bcftools-stats") }
    func test_bcftools_view_missing_input() async throws { try await check("bcftools-view-missing-input") }
    func test_tabix_index_vcf() async throws { try await check("tabix-index-vcf") }
    func test_tabix_region_query() async throws { try await check("tabix-region-query") }
    func test_tabix_index_missing_input() async throws { try await check("tabix-index-missing-input") }
    func test_bgzip_decompress_stdout() async throws { try await check("bgzip-decompress-stdout") }
    func test_bgzip_missing_input() async throws { try await check("bgzip-missing-input") }
    func test_seqkit_stats() async throws { try await check("seqkit-stats") }
    func test_seqkit_sliding_large() async throws { try await check("seqkit-sliding-large") }
    func test_seqkit_stats_missing_input() async throws { try await check("seqkit-stats-missing-input") }
    func test_fastp_paired() async throws { try await check("fastp-paired") }
    func test_fastp_missing_input() async throws { try await check("fastp-missing-input") }
    func test_cutadapt_adapter_trim() async throws { try await check("cutadapt-adapter-trim") }
    func test_cutadapt_missing_input() async throws { try await check("cutadapt-missing-input") }
    func test_trim_galore_single() async throws { try await check("trim-galore-single") }
    func test_trim_galore_missing_input() async throws { try await check("trim-galore-missing-input") }
    func test_vsearch_fastx_uniques() async throws { try await check("vsearch-fastx-uniques") }
    func test_vsearch_missing_input() async throws { try await check("vsearch-missing-input") }
    func test_deacon_index_build() async throws { try await check("deacon-index-build") }
    func test_deacon_filter() async throws { try await check("deacon-filter") }
    func test_deacon_filter_missing_index() async throws { try await check("deacon-filter-missing-index") }
    func test_ribodetector_paired() async throws { try await check("ribodetector-paired") }
    func test_ribodetector_missing_output_argument() async throws { try await check("ribodetector-missing-output-argument") }
    func test_bbtools_reformat_stdout() async throws { try await check("bbtools-reformat-stdout") }
    func test_bbtools_bbduk_ktrim() async throws { try await check("bbtools-bbduk-ktrim") }
    func test_bbtools_bbmerge() async throws { try await check("bbtools-bbmerge") }
    func test_bbtools_reformat_missing_input() async throws { try await check("bbtools-reformat-missing-input") }
    func test_lofreq_call() async throws { try await check("lofreq-call") }
    func test_lofreq_call_records() async throws { try await check("lofreq-call-records") }
    func test_lofreq_indelqual_index_call() async throws { try await check("lofreq-indelqual-index-call") }
    func test_lofreq_call_missing_input() async throws { try await check("lofreq-call-missing-input") }
    func test_ivar_trim() async throws { try await check("ivar-trim") }
    func test_ivar_trim_missing_input() async throws { try await check("ivar-trim-missing-input") }
    func test_blastn_subject() async throws { try await check("blastn-subject") }
    func test_blastn_missing_query() async throws { try await check("blastn-missing-query") }
    func test_bedgraphtobigwig_convert() async throws { try await check("bedgraphtobigwig-convert") }
    func test_bedgraphtobigwig_usage_error() async throws { try await check("bedgraphtobigwig-usage-error") }
    func test_medaka_version() async throws { try await check("medaka-version") }
    func test_medaka_invalid_subcommand() async throws { try await check("medaka-invalid-subcommand") }
    func test_medaka_variant_no_arguments() async throws { try await check("medaka-variant-no-arguments") }
    func test_clair3_version() async throws { try await check("clair3-version") }
    func test_clair3_missing_input() async throws { try await check("clair3-missing-input") }
    func test_fasterq_dump_version() async throws { try await check("fasterq-dump-version") }
    func test_fasterq_dump_unknown_option() async throws { try await check("fasterq-dump-unknown-option") }
    func test_prefetch_version() async throws { try await check("prefetch-version") }
    func test_prefetch_unknown_option() async throws { try await check("prefetch-unknown-option") }
    func test_whatshap_version() async throws { try await check("whatshap-version") }
    func test_freyja_version() async throws { try await check("freyja-version") }
    func test_samtools_runprocess_view_count() async throws { try await check("samtools-runprocess-view-count") }
    func test_samtools_runprocess_missing_input() async throws { try await check("samtools-runprocess-missing-input") }
    func test_primer3_about() async throws { try await check("primer3-about") }
    func test_primalscheme3_version() async throws { try await check("primalscheme3-version") }
    func test_olivar_version() async throws { try await check("olivar-version") }
    func test_varvamp_version() async throws { try await check("varvamp-version") }
    func test_bgzip_compress_to_file() async throws { try await check("bgzip-compress-to-file") }
    func test_pigz_compress_to_file() async throws { try await check("pigz-compress-to-file") }
    func test_pigz_missing_input_to_file() async throws { try await check("pigz-missing-input-to-file") }
    func test_samtools_fastq_to_file() async throws { try await check("samtools-fastq-to-file") }
    func test_pipeline_mpileup_ivar_truncated_bam() async throws { try await check("pipeline-mpileup-ivar-truncated-bam") }
    func test_pipeline_samtools_mpileup_ivar_variants() async throws { try await check("pipeline-samtools-mpileup-ivar-variants") }
    func test_pipeline_bcftools_mpileup_call() async throws { try await check("pipeline-bcftools-mpileup-call") }
    func test_pipeline_samtools_missing_input() async throws { try await check("pipeline-samtools-missing-input") }
    func test_conda_environment_probe() async throws { try await check("conda-environment-probe") }
    func test_minimap2_sr_paired_stdout() async throws { try await check("minimap2-sr-paired-stdout") }
    func test_minimap2_missing_input() async throws { try await check("minimap2-missing-input") }
    func test_bwa_mem2_index() async throws { try await check("bwa-mem2-index") }
    func test_bwa_mem2_mem_paired() async throws { try await check("bwa-mem2-mem-paired") }
    func test_bowtie2_build() async throws { try await check("bowtie2-build") }
    func test_bowtie2_align_paired() async throws { try await check("bowtie2-align-paired") }
    func test_mafft_auto() async throws { try await check("mafft-auto") }
    func test_kraken2_viral_paired() async throws { try await check("kraken2-viral-paired") }
    func test_kraken2_missing_database() async throws { try await check("kraken2-missing-database") }
    func test_bracken_viral_species() async throws { try await check("bracken-viral-species") }
    func test_bracken_missing_kmer_distrib() async throws { try await check("bracken-missing-kmer-distrib") }
    func test_bracken_missing_database() async throws { try await check("bracken-missing-database") }
    func test_deacon_filter_conda() async throws { try await check("deacon-filter-conda") }
    func test_ribodetector_paired_conda() async throws { try await check("ribodetector-paired-conda") }
    func test_bbtools_reformat_stdout_conda() async throws { try await check("bbtools-reformat-stdout-conda") }
    func test_nextflow_version() async throws { try await check("nextflow-version") }
    func test_nextflow_run_missing_script() async throws { try await check("nextflow-run-missing-script") }
    func test_snakemake_version() async throws { try await check("snakemake-version") }
    func test_snakemake_missing_snakefile() async throws { try await check("snakemake-missing-snakefile") }
    func test_esviritu_version() async throws { try await check("esviritu-version") }
    func test_esviritu_error() async throws { try await check("esviritu-error") }
    func test_spades_version() async throws { try await check("spades-version") }
    func test_spades_error() async throws { try await check("spades-error") }
    func test_megahit_version() async throws { try await check("megahit-version") }
    func test_megahit_error() async throws { try await check("megahit-error") }
    func test_skesa_version() async throws { try await check("skesa-version") }
    func test_skesa_error() async throws { try await check("skesa-error") }
    func test_flye_version() async throws { try await check("flye-version") }
    func test_flye_error() async throws { try await check("flye-error") }
    func test_hifiasm_version() async throws { try await check("hifiasm-version") }
    func test_hifiasm_error() async throws { try await check("hifiasm-error") }
    func test_savont_version() async throws { try await check("savont-version") }
    func test_savont_error() async throws { try await check("savont-error") }
    func test_gatk_version() async throws { try await check("gatk-version") }
    func test_gatk_error() async throws { try await check("gatk-error") }
    func test_freyja_conda_version() async throws { try await check("freyja-conda-version") }
    func test_freyja_conda_error() async throws { try await check("freyja-conda-error") }
    func test_whatshap_conda_version() async throws { try await check("whatshap-conda-version") }
    func test_whatshap_conda_error() async throws { try await check("whatshap-conda-error") }
}
