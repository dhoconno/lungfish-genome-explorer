import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class MappingConsensusExportRequestBuilderTests: XCTestCase {
    func testBuildUsesOnlyTheRequiredResolvedRegionAndContextFilters() throws {
        let context = try makeContext()
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            context: context,
            region: .init(scope: .selectedRegion, contig: "NC_045512", start: 120, end: 480),
            consensusMode: .bayesian,
            useAmbiguity: true
        )

        XCTAssertEqual(request.chromosome, "NC_045512")
        XCTAssertEqual(request.start, 120)
        XCTAssertEqual(request.end, 480)
        XCTAssertEqual(request.consensusRequest.filters, context.filters)
        XCTAssertTrue(request.showDeletions)
        XCTAssertFalse(request.showInsertions)
        XCTAssertEqual(request.recordName, "sample NC_045512:121-480 selected consensus")
        XCTAssertEqual(request.suggestedName, "sample-NC_045512-121-480-selectedRegion-consensus")
    }

    func testBuildWholeContigUsesExplicitWholeContigResolution() throws {
        let context = try makeContext()
        let request = try! MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            context: context,
            region: try AlignmentConsensusScope.wholeContig.resolve(in: context, selection: nil),
            consensusMode: .simple,
            useAmbiguity: true
        )

        XCTAssertEqual(request.chromosome, "NC_045512")
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 29_903)
        XCTAssertEqual(request.mode, .simple)
        XCTAssertTrue(request.useAmbiguity)
        XCTAssertTrue(request.showDeletions)
        XCTAssertFalse(request.showInsertions)
    }

    func testBuildRejectsARegionOutsideTheActionContextInsteadOfFallingBack() throws {
        let context = try makeContext()
        XCTAssertThrowsError(try MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            context: context,
            region: .init(scope: .selectedRegion, contig: "other", start: 1, end: 2),
            consensusMode: .simple,
            useAmbiguity: false
        ))
    }

    func testScientificFactoryAndExportUseIdenticalContextFiltersAndProjection() throws {
        let context = try makeContext()
        let region = ResolvedAlignmentRegion(
            scope: .selectedRegion,
            contig: "NC_045512",
            start: 10,
            end: 20
        )
        let trackRequest = AlignmentConsensusRequestFactory.build(
            context: context,
            region: region,
            consensusMode: .bayesian,
            useAmbiguity: true
        )
        let export = try MappingConsensusExportRequestBuilder.build(
            sampleName: "sample",
            context: context,
            region: region,
            consensusMode: .bayesian,
            useAmbiguity: true
        )

        XCTAssertEqual(trackRequest, export.consensusRequest)
        XCTAssertEqual(trackRequest.filters.readGroups, ["rg1"])
        XCTAssertEqual(trackRequest.filters.excludedFlags, 0xD04)
        XCTAssertEqual(trackRequest.insertionPolicy, .omit)
        XCTAssertEqual(trackRequest.deletionPolicy, .n)
    }

    private func makeContext() throws -> AlignmentActionContext {
        let bam = URL(fileURLWithPath: "/tmp/sample.bam")
        let index = URL(fileURLWithPath: "/tmp/sample.bam.bai")
        return try .init(
            identity: .init(workflow: "mapping", resultID: "result", sampleID: "sample", evidenceID: "track"),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: "NC_045512", contigLength: 29_903,
            alignmentSnapshot: .init(url: bam, byteCount: 1, sha256: "bam"),
            indexSnapshot: .init(url: index, byteCount: 1, sha256: "index"),
            decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: 12, minimumMapQ: 7, minimumBaseQuality: 9, excludedFlags: 0xD04, readGroups: ["rg1"]),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback,
            presentationLabel: "sample NC_045512"
        )
    }
}
