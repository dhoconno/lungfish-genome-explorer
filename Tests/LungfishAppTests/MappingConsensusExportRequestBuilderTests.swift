import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class MappingConsensusExportRequestBuilderTests: XCTestCase {
    func testBuildPrefersSelectedContigAndUsesBiologicalConsensusFlags() {
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            selectedContig: .init(
                contigName: "NC_045512",
                contigLength: 29_903,
                mappedReads: 197,
                mappedReadPercent: 98.5,
                meanDepth: 0.9,
                coverageBreadth: 43.0,
                medianMAPQ: 60.0,
                meanIdentity: 99.5
            ),
            fallbackChromosome: nil,
            consensusMode: .bayesian,
            consensusMinDepth: 12,
            consensusMinMapQ: 0,
            consensusMinBaseQ: 0,
            excludeFlags: 0xD04,
            useAmbiguity: false
        )

        XCTAssertEqual(request.chromosome, "NC_045512")
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 29_903)
        XCTAssertFalse(request.showDeletions)
        XCTAssertTrue(request.showInsertions)
        XCTAssertEqual(request.recordName, "sample NC_045512 consensus")
        XCTAssertEqual(request.suggestedName, "sample-NC_045512-consensus")
    }

    func testBuildFallsBackToVisibleChromosomeWhenNoTableSelectionExists() {
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            selectedContig: nil,
            fallbackChromosome: ChromosomeInfo(
                name: "chr2",
                length: 512,
                offset: 0,
                lineBases: 80,
                lineWidth: 81
            ),
            consensusMode: .simple,
            consensusMinDepth: 5,
            consensusMinMapQ: 7,
            consensusMinBaseQ: 9,
            excludeFlags: 0x904,
            useAmbiguity: true
        )

        XCTAssertEqual(request.chromosome, "chr2")
        XCTAssertEqual(request.end, 512)
        XCTAssertEqual(request.mode, .simple)
        XCTAssertTrue(request.useAmbiguity)
    }

    func testBuildPrefersExplicitRegionForVisibleViewport() {
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            selectedContig: .init(
                contigName: "whole",
                contigLength: 10_000,
                mappedReads: 100,
                mappedReadPercent: 100,
                meanDepth: 12,
                coverageBreadth: 100,
                medianMAPQ: 60,
                meanIdentity: 99
            ),
            fallbackChromosome: nil,
            explicitRegion: .init(chromosome: "chr2", start: 120, end: 480, label: "visible"),
            consensusMode: .simple,
            consensusMinDepth: 5,
            consensusMinMapQ: 7,
            consensusMinBaseQ: 9,
            excludeFlags: 0x904,
            useAmbiguity: true
        )

        XCTAssertEqual(request.chromosome, "chr2")
        XCTAssertEqual(request.start, 120)
        XCTAssertEqual(request.end, 480)
        XCTAssertEqual(request.recordName, "sample chr2:121-480 visible consensus")
        XCTAssertEqual(request.suggestedName, "sample-chr2-121-480-visible-consensus")
    }

    func testBuildClampsExplicitRegionToNonEmptyInterval() {
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            selectedContig: nil,
            fallbackChromosome: nil,
            explicitRegion: .init(chromosome: "chr2", start: -10, end: -1, label: "selection"),
            consensusMode: .simple,
            consensusMinDepth: 5,
            consensusMinMapQ: 7,
            consensusMinBaseQ: 9,
            excludeFlags: 0x904,
            useAmbiguity: true
        )

        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 1)
        XCTAssertEqual(request.suggestedName, "sample-chr2-1-1-selection-consensus")
    }
}
