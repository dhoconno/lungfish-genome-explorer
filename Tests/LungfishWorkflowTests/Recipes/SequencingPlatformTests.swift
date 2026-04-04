// SequencingPlatformTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import LungfishWorkflow
import LungfishIO

// Disambiguate: we are testing the LungfishWorkflow ingestion platform enum.
private typealias SequencingPlatform = LungfishWorkflow.SequencingPlatform

@Suite("SequencingPlatform")
struct SequencingPlatformTests {

    @Test func testIlluminaDefaults() {
        let platform = SequencingPlatform.illumina
        #expect(platform.displayName == "Illumina")
        #expect(platform.defaultPairing == .interleaved)
        #expect(platform.defaultOptimizeStorage == true)
        #expect(platform.defaultQualityBinning == .illumina4)
        #expect(platform.defaultCompressionLevel == .balanced)
    }

    @Test func testONTDefaults() {
        let platform = SequencingPlatform.ont
        #expect(platform.displayName == "Oxford Nanopore")
        #expect(platform.defaultPairing == .singleEnd)
        #expect(platform.defaultOptimizeStorage == false)
        #expect(platform.defaultQualityBinning == .none)
        #expect(platform.defaultCompressionLevel == .balanced)
    }

    @Test func testPacBioDefaults() {
        let platform = SequencingPlatform.pacbio
        #expect(platform.displayName == "PacBio HiFi")
        #expect(platform.defaultPairing == .singleEnd)
        #expect(platform.defaultOptimizeStorage == false)
        #expect(platform.defaultQualityBinning == .none)
    }

    @Test func testUltimaDefaults() {
        let platform = SequencingPlatform.ultima
        #expect(platform.displayName == "Ultima Genomics")
        #expect(platform.defaultPairing == .interleaved)
        #expect(platform.defaultOptimizeStorage == true)
        #expect(platform.defaultQualityBinning == .illumina4)
    }

    @Test func testAutoDetectIllumina() {
        let header = "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT"
        let detected = SequencingPlatform.detect(fromFASTQHeader: header)
        #expect(detected == .illumina)
    }

    @Test func testAutoDetectONT() {
        let header = "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1"
        let detected = SequencingPlatform.detect(fromFASTQHeader: header)
        #expect(detected == .ont)
    }

    @Test func testAutoDetectPacBio() {
        let header = "@m64011_190830_220126/101/ccs"
        let detected = SequencingPlatform.detect(fromFASTQHeader: header)
        #expect(detected == .pacbio)
    }

    @Test func testAutoDetectUnknown() {
        let header = "@read1 some random format"
        let detected = SequencingPlatform.detect(fromFASTQHeader: header)
        #expect(detected == nil)
    }
}
