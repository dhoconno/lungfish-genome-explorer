// MetagenomicsImportServiceTests.swift - Shared import service regression coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow

@Suite(.serialized)
struct MetagenomicsImportServiceTests {
    @Test
    func kraken2ImportCreatesCanonicalResultDirectory() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-kraken2-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceKreport = workspace.appendingPathComponent("input.kreport")
        try """
        0.00\t0\t0\tU\t0\tunclassified
        100.00\t10\t0\tR\t1\troot
        50.00\t5\t5\tS\t12345\t  Example species
        """.write(to: sourceKreport, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importKraken2(
            kreportURL: sourceKreport,
            outputDirectory: outputDirectory
        )

        #expect(FileManager.default.fileExists(atPath: result.resultDirectory.path))
        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("classification.kreport").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("classification.kraken").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("classification-result.json").path
        ))
        #expect(result.totalReads == 10)
        #expect(result.speciesCount == 1)
    }

    @Test
    func esVirituImportCreatesSidecar() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-esviritu-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = workspace.appendingPathComponent("esv-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let detectionURL = sourceDirectory.appendingPathComponent("SampleA.detected_virus.info.tsv")
        try esVirituDetectionFixture().write(to: detectionURL, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importEsViritu(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory
        )

        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("esviritu-result.json").path
        ))
        #expect(result.importedFileCount >= 1)
        #expect(result.virusCount >= 1)
    }

    @Test
    func taxTriageImportCreatesSidecar() throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-taxtriage-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceDirectory = workspace.appendingPathComponent("taxtriage-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let reportURL = sourceDirectory.appendingPathComponent("top_report.tsv")
        try """
        taxid\tname\treads
        111\tVirus A\t12
        222\tVirus B\t8
        """.write(to: reportURL, atomically: true, encoding: .utf8)

        let logURL = sourceDirectory.appendingPathComponent("nextflow.log")
        try """
        NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR35517992.SRR35517992.dwnld.references)` terminated with an error exit status (1) -- Error is ignored
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try MetagenomicsImportService.importTaxTriage(
            inputURL: sourceDirectory,
            outputDirectory: outputDirectory
        )

        let sidecar = try TaxTriageResult.load(from: result.resultDirectory)

        #expect(FileManager.default.fileExists(
            atPath: result.resultDirectory.appendingPathComponent("taxtriage-result.json").path
        ))
        #expect(result.importedFileCount >= 1)
        #expect(result.reportEntryCount == 2)
        #expect(sidecar.ignoredFailures.count == 1)
        #expect(sidecar.ignoredFailures.first?.sampleID == "SRR35517992")
    }

    @Test
    func naoMgsImportCreatesCanonicalBundle() async throws {
        let workspace = makeTemporaryDirectory(prefix: "metagenomics-import-naomgs-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceFile = workspace.appendingPathComponent("virus_hits_final.tsv")
        try """
        sample\tseq_id\taligner_taxid_lca\tquery_seq\tquery_qual\tprim_align_genome_id_all\tprim_align_ref_start\tprim_align_cigar\tquery_len\tprim_align_edit_distance\tprim_align_query_rc
        SAMPLE_A\tread1\t111\tACGTACGT\tFFFFFFFF\tACCN0001\t10\t8M\t8\t0\tFalse
        SAMPLE_A\tread2\t111\tACGTACGA\tFFFFFFFF\tACCN0002\t20\t8M\t8\t1\tFalse
        SAMPLE_A\tread3\t222\tACGTACGG\tFFFFFFFF\tACCN0003\t30\t8M\t8\t0\tTrue
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDirectory = workspace.appendingPathComponent("imports", isDirectory: true)
        let result = try await MetagenomicsImportService.importNaoMgs(
            inputURL: sourceFile,
            outputDirectory: outputDirectory,
            sampleName: "SAMPLE_A",
            minIdentity: 90,
            fetchReferences: false
        )

        let bundle = result.resultDirectory
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("hits.sqlite").path))
        #expect(result.sampleName == "SAMPLE_A")
        #expect(result.taxonCount == 2)
        // createdBAM reflects whether samtools was available in the test environment;
        // both true and false are valid outcomes after the materialization step was added.
    }

    @Test
    func managedSamtoolsExecutableURLUsesSamtoolsEnvironmentLayout() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "samtools-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDir = home.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let samtoolsURL = binDir.appendingPathComponent("samtools")
        try "#!/bin/sh\nexit 0\n".write(to: samtoolsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsURL.path)

        let resolved = MetagenomicsImportService.managedSamtoolsExecutableURL(homeDirectory: home)

        #expect(resolved?.path == samtoolsURL.path)
    }
}

private func makeTemporaryDirectory(prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func esVirituDetectionFixture() -> String {
    [
        "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample",
        "SampleA\tExample virus\tExample description\t1000\t\tACCN0001\tGCF_000001\t1000\tViruses\t\t\t\tExampleviridae\tExamplevirus\tExample virus species\t\t1.5\t42\t900\t12.4\t97.2\t0.01\t10000",
    ].joined(separator: "\n")
}
