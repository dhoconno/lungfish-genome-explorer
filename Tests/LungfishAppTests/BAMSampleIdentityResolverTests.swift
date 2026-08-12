import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

final class BAMSampleIdentityResolverTests: XCTestCase {
    func testGroupsReadGroupsByPersistedSampleAndRetainsTrackIDs() throws {
        let resolver = try BAMSampleIdentityResolver.resolve(
            readGroups: [
                .init(id: "rg-a", sample: "S1", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
                .init(id: "rg-b", sample: "S1", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
                .init(id: "rg-c", sample: "S2", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
            ],
            trackIDs: ["track-a"]
        )

        XCTAssertEqual(resolver.identityIndex.canonicalSampleIDs, Set(["S1", "S2"]))
        XCTAssertEqual(resolver.identityIndex.readGroupIDs(forCanonicalSampleID: "S1"), Set(["rg-a", "rg-b"]))
        XCTAssertEqual(resolver.identityIndex.readGroupIDs(forCanonicalSampleID: "S2"), Set(["rg-c"]))
        XCTAssertTrue(resolver.identityIndex.alignmentTrackIDs(forCanonicalSampleID: "S1").isEmpty)
    }

    func testSingleSampleWithoutReadGroupsRequiresExplicitPersistedFallback() throws {
        let resolver = try BAMSampleIdentityResolver.resolve(
            readGroups: [],
            trackIDs: ["track-a"],
            explicitResultSampleID: "S1"
        )

        XCTAssertEqual(resolver.identityIndex.canonicalSampleID(forAlignmentTrackID: nil), "S1")
        XCTAssertEqual(resolver.identityIndex.canonicalSampleID(forReadGroupID: nil), "S1")

        let withoutFallback = try BAMSampleIdentityResolver.resolve(readGroups: [], trackIDs: ["S1.bam"])
        XCTAssertNil(withoutFallback.identityIndex.canonicalSampleID(forAlignmentTrackID: nil))
        XCTAssertNil(withoutFallback.identityIndex.canonicalSampleID(forAlignmentTrackID: "S1.bam"))
    }

    func testMissingOrAmbiguousSampleValuesRemainUnmatched() throws {
        let resolver = try BAMSampleIdentityResolver.resolve(
            readGroups: [
                .init(id: "missing", sample: nil, library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
                .init(id: "blank", sample: "  ", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
            ],
            trackIDs: []
        )
        XCTAssertTrue(resolver.identityIndex.canonicalSampleIDs.isEmpty)
        XCTAssertNil(resolver.identityIndex.canonicalSampleID(forReadGroupID: "missing"))
        XCTAssertNil(resolver.identityIndex.canonicalSampleID(forReadGroupID: "blank"))
    }

    func testCanonicalIDsWinAndAliasesAreOnlyExplicit() throws {
        let resolver = try BAMSampleIdentityResolver.resolve(
            readGroups: [
                .init(id: "rg-1", sample: "S1", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
                .init(id: "rg-2", sample: "S2", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
            ],
            trackIDs: ["track-1", "track-2"],
            aliases: ["S1": ["subject-1"], "S2": ["subject-2"]],
            trackSampleIDs: ["track-1": "S1", "track-2": "S2"]
        )

        XCTAssertEqual(resolver.identityIndex.canonicalSampleID(forMetadataIdentifier: "S1"), "S1")
        XCTAssertEqual(resolver.identityIndex.canonicalSampleID(forMetadataIdentifier: "subject-2"), "S2")
        XCTAssertNil(resolver.identityIndex.canonicalSampleID(forMetadataIdentifier: "track-1"))
        XCTAssertEqual(resolver.identityIndex.canonicalSampleID(forAlignmentTrackID: "track-2"), "S2")
    }

    func testMergeUnionsAllExplicitAliasesWithEquivalentNormalizedCanonicalKeys() {
        let merged = BAMSampleIdentityResolver.merge(
            [
                SampleIdentity(
                    canonicalID: "S1",
                    aliases: [],
                    alignmentTrackIDs: ["track-1"],
                    readGroupIDs: ["rg-1"]
                ),
            ],
            aliases: [
                " S1 ": ["subject-a"],
                "s1": ["subject-b"],
            ]
        )

        XCTAssertEqual(merged, [
            SampleIdentity(
                canonicalID: "S1",
                aliases: ["subject-a", "subject-b"],
                alignmentTrackIDs: ["track-1"],
                readGroupIDs: ["rg-1"]
            ),
        ])
    }

    func testMergeRetainsTrackScopedReadGroupsWhenIDsAreReusedByDifferentSamples() throws {
        let first = try BAMSampleIdentityResolver.resolve(
            readGroups: [
                .init(id: "RG1", sample: "S1", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
            ],
            trackIDs: ["track-a"]
        )
        let second = try BAMSampleIdentityResolver.resolve(
            readGroups: [
                .init(id: "RG1", sample: "S2", library: nil, platform: nil, platformUnit: nil, center: nil, description: nil),
            ],
            trackIDs: ["track-b"]
        )

        let index = try SampleIdentityIndex(samples: BAMSampleIdentityResolver.merge(
            first.identities + second.identities
        ))

        XCTAssertEqual(index.canonicalSampleIDs, Set(["S1", "S2"]))
        XCTAssertEqual(index.canonicalSampleID(forReadGroupID: "RG1", alignmentTrackID: "track-a"), "S1")
        XCTAssertEqual(index.canonicalSampleID(forReadGroupID: "RG1", alignmentTrackID: "track-b"), "S2")
        XCTAssertNil(index.canonicalSampleID(forReadGroupID: "RG1"))
    }
}
