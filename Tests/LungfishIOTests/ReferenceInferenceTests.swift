// ReferenceInferenceTests.swift - Tests for reference genome inference from BAM headers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

// MARK: - ReferenceInference Tests

final class ReferenceInferenceTests: XCTestCase {

    // MARK: - Human GRCh38

    func testInferGRCh38FromUCSCNames() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 248_956_422, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr2", length: 242_193_529, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chrX", length: 156_040_895, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chrM", length: 16_569, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "GRCh38")
        XCTAssertEqual(result.organism, "Human")
        XCTAssertEqual(result.namingConvention, "UCSC")
        XCTAssertGreaterThanOrEqual(result.confidence, .medium)
    }

    func testInferGRCh38FromEnsemblNames() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "1", length: 248_956_422, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "2", length: 242_193_529, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "MT", length: 16_569, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "GRCh38")
        XCTAssertEqual(result.organism, "Human")
        XCTAssertEqual(result.namingConvention, "Ensembl")
    }

    // MARK: - Human GRCh37

    func testInferGRCh37() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 249_250_621, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr2", length: 243_199_373, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "GRCh37")
        XCTAssertEqual(result.organism, "Human")
    }

    // MARK: - Mouse

    func testInferGRCm39() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 195_154_279, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr2", length: 181_755_017, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "GRCm39")
        XCTAssertEqual(result.organism, "Mouse")
    }

    func testInferGRCm38() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 195_471_971, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr2", length: 182_113_224, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "GRCm38")
        XCTAssertEqual(result.organism, "Mouse")
    }

    // MARK: - SARS-CoV-2

    func testInferSARSCoV2() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "MN908947.3", length: 29_903, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
        XCTAssertEqual(result.organism, "Severe acute respiratory syndrome coronavirus 2")
    }

    func testInferSARSCoV2RefSeq() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "NC_045512.2", length: 29_903, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "SARS-CoV-2")
    }

    // MARK: - Drosophila

    func testInferDrosophila() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr2L", length: 23_513_712, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr2R", length: 25_286_936, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr3L", length: 28_110_227, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chr3R", length: 32_079_331, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chrX", length: 23_542_271, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "dm6")
        XCTAssertEqual(result.organism, "Drosophila")
    }

    // MARK: - Assembly Tag

    func testInferFromAssemblyTag() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 248_956_422, md5: nil, assembly: "GRCh38", uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.assembly, "GRCh38")
        XCTAssertEqual(result.confidence, .high)
    }

    // MARK: - Edge Cases

    func testInferFromEmptySequences() {
        let result = ReferenceInference.infer(from: [])
        XCTAssertNil(result.assembly)
        XCTAssertNil(result.organism)
        XCTAssertEqual(result.confidence, .none)
        XCTAssertEqual(result.sequenceCount, 0)
        XCTAssertEqual(result.totalLength, 0)
    }

    func testInferFromUnknownAssembly() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "scaffold_1", length: 5_000_000, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "scaffold_2", length: 3_000_000, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertNil(result.assembly)
        XCTAssertEqual(result.confidence, .none)
        XCTAssertEqual(result.sequenceCount, 2)
        XCTAssertEqual(result.totalLength, 8_000_000)
    }

    // MARK: - Naming Convention Detection

    func testDetectUCSCNaming() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 100, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.namingConvention, "UCSC")
    }

    func testDetectEnsemblNaming() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "1", length: 100, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "MT", length: 16569, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.namingConvention, "Ensembl")
    }

    func testDetectRefSeqNaming() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "NC_000001.11", length: 248_956_422, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.namingConvention, "RefSeq")
    }

    // MARK: - Result Properties

    func testResultSequenceCountAndTotalLength() {
        let sequences = [
            SAMParser.ReferenceSequence(name: "chr1", length: 248_956_422, md5: nil, assembly: nil, uri: nil, species: nil),
            SAMParser.ReferenceSequence(name: "chrM", length: 16_569, md5: nil, assembly: nil, uri: nil, species: nil),
        ]
        let result = ReferenceInference.infer(from: sequences)
        XCTAssertEqual(result.sequenceCount, 2)
        XCTAssertEqual(result.totalLength, 248_956_422 + 16_569)
    }

    // MARK: - @SQ Parser Integration

    func testParseReferenceSequences() {
        let header = """
        @HD\tVN:1.6\tSO:coordinate
        @SQ\tSN:chr1\tLN:248956422\tM5:6aef897c3d6ff0c78aff06ac189178dd\tAS:GRCh38
        @SQ\tSN:chr2\tLN:242193529
        @SQ\tSN:chrM\tLN:16569\tSP:Homo sapiens\tUR:file://ref.fa
        """
        let sequences = SAMParser.parseReferenceSequences(from: header)
        XCTAssertEqual(sequences.count, 3)

        XCTAssertEqual(sequences[0].name, "chr1")
        XCTAssertEqual(sequences[0].length, 248_956_422)
        XCTAssertEqual(sequences[0].md5, "6aef897c3d6ff0c78aff06ac189178dd")
        XCTAssertEqual(sequences[0].assembly, "GRCh38")
        XCTAssertNil(sequences[0].species)

        XCTAssertEqual(sequences[1].name, "chr2")
        XCTAssertEqual(sequences[1].length, 242_193_529)
        XCTAssertNil(sequences[1].md5)

        XCTAssertEqual(sequences[2].name, "chrM")
        XCTAssertEqual(sequences[2].length, 16_569)
        XCTAssertEqual(sequences[2].species, "Homo sapiens")
        XCTAssertEqual(sequences[2].uri, "file://ref.fa")
    }

    func testParseReferenceSequencesEmpty() {
        let sequences = SAMParser.parseReferenceSequences(from: "@HD\tVN:1.6")
        XCTAssertTrue(sequences.isEmpty)
    }

    func testParseReferenceSequencesMissingSN() {
        // Missing SN tag should skip the line
        let header = "@SQ\tLN:1000"
        let sequences = SAMParser.parseReferenceSequences(from: header)
        XCTAssertTrue(sequences.isEmpty)
    }

    func testParseReferenceSequencesMissingLN() {
        // Missing LN tag should skip the line
        let header = "@SQ\tSN:chr1"
        let sequences = SAMParser.parseReferenceSequences(from: header)
        XCTAssertTrue(sequences.isEmpty)
    }

    // MARK: - Confidence Comparison

    func testConfidenceComparable() {
        XCTAssertTrue(ReferenceInference.Confidence.high > .medium)
        XCTAssertTrue(ReferenceInference.Confidence.medium > .low)
        XCTAssertTrue(ReferenceInference.Confidence.low > .none)
    }
}
