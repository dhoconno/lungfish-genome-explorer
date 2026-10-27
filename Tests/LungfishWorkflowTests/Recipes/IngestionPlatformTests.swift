// IngestionPlatformTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LungfishWorkflow
import LungfishIO

@Suite("IngestionPlatform")
struct IngestionPlatformTests {

    @Test func testIlluminaDefaults() {
        let platform = IngestionPlatform.illumina
        #expect(platform.displayName == "Illumina")
        #expect(platform.defaultPairing == .interleaved)
        #expect(platform.defaultOptimizeStorage == true)
        #expect(platform.defaultQualityBinning == .fiveStep)  // fiveStep on every platform (owner ruling of 2026-10-27)
        #expect(platform.defaultCompressionLevel == .balanced)
    }

    @Test func testONTDefaults() {
        let platform = IngestionPlatform.ont
        #expect(platform.displayName == "Oxford Nanopore")
        #expect(platform.defaultPairing == .singleEnd)
        #expect(platform.defaultOptimizeStorage == false)
        #expect(platform.defaultQualityBinning == .fiveStep)
        #expect(platform.defaultCompressionLevel == .balanced)
    }

    @Test func testPacBioDefaults() {
        let platform = IngestionPlatform.pacbio
        #expect(platform.displayName == "PacBio")
        #expect(platform.defaultPairing == .singleEnd)
        #expect(platform.defaultOptimizeStorage == false)
        #expect(platform.defaultQualityBinning == .fiveStep)
    }

    @Test func testUltimaDefaults() {
        let platform = IngestionPlatform.ultima
        #expect(platform.displayName == "Ultima Genomics")
        #expect(platform.defaultPairing == .interleaved)
        #expect(platform.defaultOptimizeStorage == true)
        #expect(platform.defaultQualityBinning == .fiveStep)
    }

    /// BIO-BIN (Phase 3.0 lane BIN, S1), with the owner's ruling of 2026-10-27. Every platform bins in steps of five,
    /// which keeps every Q10, Q20 and Q30 count as sequenced, and None stays on offer to keep every score. The unknown
    /// case is read through the import configuration, the reader that resolves a sample's platform.
    @Test func testDefaultBinningPerPlatform() {
        #expect(IngestionPlatform.illumina.defaultQualityBinning.rawValue == "fiveStep")
        #expect(IngestionPlatform.ont.defaultQualityBinning == .fiveStep)
        #expect(IngestionPlatform.pacbio.defaultQualityBinning == .fiveStep)
        let project = URL(fileURLWithPath: "/tmp/binning-default.lungfish")
        for platform in LungfishIO.SequencingPlatform.allCases {
            let config = FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .given(platform), threadsSource: .default, clumpifyHeapGB: nil
            )
            #expect(config.qualityBinning == .fiveStep, "\(platform)")
        }
    }

    @Test func testAutoDetectIllumina() {
        let header = "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT"
        let detected = LungfishIO.SequencingPlatform.detect(fromHeader: header)
        #expect(detected == .illumina)
    }

    @Test func testAutoDetectONT() {
        let header = "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1"
        let detected = LungfishIO.SequencingPlatform.detect(fromHeader: header)
        #expect(detected == .oxfordNanopore)
    }

    @Test func testAutoDetectPacBio() {
        let header = "@m64011_190830_220126/101/ccs"
        let detected = LungfishIO.SequencingPlatform.detect(fromHeader: header)
        #expect(detected == .pacbio)
    }

    @Test func testAutoDetectUnknown() {
        let header = "@read1 some random format"
        let detected = LungfishIO.SequencingPlatform.detect(fromHeader: header)
        #expect(detected == nil)
    }

    // MARK: - Relationship to LungfishIO.SequencingPlatform

    @Test func testSequencingPlatformOfEachImportPlatform() {
        #expect(IngestionPlatform.illumina.sequencingPlatform == .illumina)
        #expect(IngestionPlatform.ont.sequencingPlatform == .oxfordNanopore)
        #expect(IngestionPlatform.pacbio.sequencingPlatform == .pacbio)
        #expect(IngestionPlatform.ultima.sequencingPlatform == .ultima)
    }

    @Test func testImportPlatformOfEachCanonicalPlatform() {
        #expect(IngestionPlatform(importing: .illumina) == .illumina)
        #expect(IngestionPlatform(importing: .oxfordNanopore) == .ont)
        #expect(IngestionPlatform(importing: .pacbio) == .pacbio)
        #expect(IngestionPlatform(importing: .ultima) == .ultima)
        #expect(IngestionPlatform(importing: .element) == .illumina)
        #expect(IngestionPlatform(importing: .mgi) == .illumina)
        #expect(IngestionPlatform(importing: .unknown) == .illumina)
    }

    @Test func testEveryImportPlatformRoundTripsThroughItsCanonicalPlatform() {
        for platform in IngestionPlatform.allCases {
            #expect(IngestionPlatform(importing: platform.sequencingPlatform) == platform)
        }
    }

    @Test func testImporterAndAssemblyMappingsAgreeWithTheCanonicalPlatform() {
        for platform in IngestionPlatform.allCases {
            let canonical = platform.sequencingPlatform
            #expect(FASTQBatchImporter.persistedSequencingPlatform(for: platform) == canonical)
            #expect(
                FASTQBatchImporter.persistedAssemblyReadType(for: platform)
                    == FASTQAssemblyReadType(sequencingPlatform: canonical)
            )
            #expect(
                AssemblyReadType.detect(fromWorkflowPlatform: platform)
                    == AssemblyReadType.detect(from: canonical)
            )
        }
    }
}
