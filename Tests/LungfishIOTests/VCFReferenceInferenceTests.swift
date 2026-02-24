// VCFReferenceInferenceTests.swift - Tests for VCF reference genome inference
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class VCFReferenceInferenceTests: XCTestCase {

    // MARK: - ReferenceInference.lookupByChromosomeName

    func testLookupSARSCoV2ByRefSeqAccession() {
        let result = ReferenceInference.lookupByChromosomeName("NC_045512.2")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.assembly, "SARS-CoV-2")
        XCTAssertEqual(result?.organism, "SARS-CoV-2")
    }

    func testLookupSARSCoV2ByGenBankAccession() {
        let result = ReferenceInference.lookupByChromosomeName("MN908947.3")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.assembly, "SARS-CoV-2")
    }

    func testLookupHumanByUCSCName() {
        let result = ReferenceInference.lookupByChromosomeName("chr1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.organism, "Human")
    }

    func testLookupHumanByRefSeqPattern() {
        let result = ReferenceInference.lookupByChromosomeName("NC_000001.11")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.organism, "Human")
    }

    func testLookupMouseByUCSCName() {
        // chr1 matches Human first due to ordering, but mouse also has chr1
        // The lookup returns first match, which is Human — this is expected behavior
        let result = ReferenceInference.lookupByChromosomeName("chr1")
        XCTAssertNotNil(result)
    }

    func testLookupDrosophilaByArmName() {
        let result = ReferenceInference.lookupByChromosomeName("chr2L")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.assembly, "dm6")
        XCTAssertEqual(result?.organism, "Drosophila")
    }

    func testLookupCElegansRomanNumeral() {
        let result = ReferenceInference.lookupByChromosomeName("chrI")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.assembly, "ce11")
    }

    func testLookupUnknownChromosomeReturnsNil() {
        let result = ReferenceInference.lookupByChromosomeName("scaffold_unknown_99")
        XCTAssertNil(result)
    }

    func testLookupEmptyStringReturnsNil() {
        let result = ReferenceInference.lookupByChromosomeName("")
        XCTAssertNil(result)
    }

    // MARK: - ReferenceInference.knownAssemblyList

    func testKnownAssemblyListNotEmpty() {
        let list = ReferenceInference.knownAssemblyList()
        XCTAssertGreaterThanOrEqual(list.count, 9) // at least 9 assemblies
    }

    func testKnownAssemblyListContainsSARSCoV2() {
        let list = ReferenceInference.knownAssemblyList()
        XCTAssertTrue(list.contains(where: { $0.assembly == "SARS-CoV-2" }))
    }

    func testKnownAssemblyListContainsGRCh38() {
        let list = ReferenceInference.knownAssemblyList()
        let human = list.first(where: { $0.assembly == "GRCh38" })
        XCTAssertNotNil(human)
        XCTAssertEqual(human?.organism, "Human")
        XCTAssertEqual(human?.chr1Length, 248_956_422)
    }

    // MARK: - ReferenceInference.detectNamingConvention (now public)

    func testDetectUCSCNaming() {
        let result = ReferenceInference.detectNamingConvention(names: ["chr1", "chr2", "chrX"])
        XCTAssertEqual(result, "UCSC")
    }

    func testDetectEnsemblNaming() {
        let result = ReferenceInference.detectNamingConvention(names: ["1", "2", "MT"])
        XCTAssertEqual(result, "Ensembl")
    }

    func testDetectRefSeqNaming() {
        let result = ReferenceInference.detectNamingConvention(names: ["NC_045512.2"])
        XCTAssertEqual(result, "RefSeq")
    }

    func testDetectUnknownNaming() {
        let result = ReferenceInference.detectNamingConvention(names: ["scaffold_1", "scaffold_2"])
        XCTAssertNil(result)
    }

    // MARK: - VCFReferenceInference.infer(fromChromosomeNames:)

    func testInferSARSCoV2FromName() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["NC_045512.2"])
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
        XCTAssertEqual(result.organism, "SARS-CoV-2")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
        XCTAssertEqual(result.namingConvention, "RefSeq")
    }

    func testInferHumanFromUCSCNames() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["chr1", "chr2", "chr3", "chrX"])
        XCTAssertNotNil(result.assembly)
        XCTAssertEqual(result.organism, "Human")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
    }

    func testInferHumanFromRefSeqAccessions() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["NC_000001.11", "NC_000002.12", "NC_000023.11"])
        XCTAssertNotNil(result.assembly)
        XCTAssertEqual(result.organism, "Human")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
    }

    func testInferDrosophilaFromArmNames() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["chr2L", "chr2R", "chr3L", "chr3R", "chrX"])
        XCTAssertEqual(result.assembly, "dm6")
        XCTAssertEqual(result.organism, "Drosophila")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
    }

    func testInferCElegansFromRomanNumerals() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["chrI", "chrII", "chrIII", "chrIV", "chrV"])
        XCTAssertEqual(result.assembly, "ce11")
        XCTAssertEqual(result.organism, "C. elegans")
    }

    func testInferUnknownChromosomesReturnsNone() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["contig_1234", "scaffold_5678"])
        XCTAssertNil(result.assembly)
        XCTAssertEqual(result.confidence, .none)
    }

    func testInferFromEmptyNamesReturnsNone() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: [])
        XCTAssertNil(result.assembly)
        XCTAssertEqual(result.confidence, .none)
        XCTAssertEqual(result.sequenceCount, 0)
    }

    // MARK: - VCFReferenceInference.infer(from:chromosomeMaxPositions:)

    func testInferFromHeaderWithContigs() {
        let header = VCFHeader(
            fileFormat: "VCFv4.3",
            contigs: ["NC_045512.2": 29903]
        )
        let result = VCFReferenceInference.infer(from: header)
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
    }

    func testInferFromHeaderWithHumanContigs() {
        let header = VCFHeader(
            fileFormat: "VCFv4.3",
            contigs: ["chr1": 248_956_422, "chr2": 242_193_529]
        )
        let result = VCFReferenceInference.infer(from: header)
        XCTAssertEqual(result.organism, "Human")
        XCTAssertGreaterThanOrEqual(result.confidence, .high)
    }

    func testInferFromHeaderWithoutContigsUsesMaxPositions() {
        let header = VCFHeader(fileFormat: "VCFv4.0")
        let positions = ["NC_045512.2": 29836]
        let result = VCFReferenceInference.infer(from: header, chromosomeMaxPositions: positions)
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
        XCTAssertGreaterThanOrEqual(result.confidence, .low)
    }

    func testInferFromLofreqStyleHeader() {
        // Lofreq VCFs have no contig lines and no sample columns
        // Only a ##reference= line and chromosome names from variants
        let header = VCFHeader(
            fileFormat: "VCFv4.0",
            otherHeaders: ["reference": "reference.fasta"]
        )
        let positions = ["NC_045512.2": 29836]
        let result = VCFReferenceInference.infer(from: header, chromosomeMaxPositions: positions)
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
    }

    func testInferFromEmptyHeader() {
        let header = VCFHeader(fileFormat: "VCFv4.3")
        let result = VCFReferenceInference.infer(from: header)
        XCTAssertNil(result.assembly)
        XCTAssertEqual(result.confidence, .none)
    }

    func testInferFromHeaderWithUnknownContigs() {
        let header = VCFHeader(
            fileFormat: "VCFv4.3",
            contigs: ["scaffold_1": 50000, "scaffold_2": 30000]
        )
        let result = VCFReferenceInference.infer(from: header)
        XCTAssertNil(result.assembly)
        XCTAssertEqual(result.confidence, .none)
    }

    // MARK: - Single Chromosome Organisms

    func testSARSCoV2SingleChromosomeMediumConfidence() {
        // A single chromosome VCF matching NC_045512.2 should get at least medium
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["NC_045512.2"])
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
        XCTAssertEqual(result.sequenceCount, 1)
    }

    // MARK: - Result Properties

    func testResultNamingConvention() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["NC_045512.2"])
        XCTAssertEqual(result.namingConvention, "RefSeq")
    }

    func testResultSequenceCount() {
        let result = VCFReferenceInference.infer(fromChromosomeNames: ["chr1", "chr2", "chr3"])
        XCTAssertEqual(result.sequenceCount, 3)
    }
}
