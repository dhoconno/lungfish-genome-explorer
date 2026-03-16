import XCTest
@testable import LungfishIO

final class SequencingPlatformTests: XCTestCase {

    // MARK: - Display Names

    func testDisplayNames() {
        XCTAssertEqual(SequencingPlatform.illumina.displayName, "Illumina")
        XCTAssertEqual(SequencingPlatform.oxfordNanopore.displayName, "Oxford Nanopore")
        XCTAssertEqual(SequencingPlatform.pacbio.displayName, "PacBio")
        XCTAssertEqual(SequencingPlatform.element.displayName, "Element Biosciences")
        XCTAssertEqual(SequencingPlatform.ultima.displayName, "Ultima Genomics")
        XCTAssertEqual(SequencingPlatform.mgi.displayName, "MGI / DNBSEQ")
        XCTAssertEqual(SequencingPlatform.unknown.displayName, "Unknown")
    }

    // MARK: - Platform Capabilities

    func testReadsCanBeReverseComplemented() {
        XCTAssertTrue(SequencingPlatform.oxfordNanopore.readsCanBeReverseComplemented)
        XCTAssertTrue(SequencingPlatform.pacbio.readsCanBeReverseComplemented)
        XCTAssertFalse(SequencingPlatform.illumina.readsCanBeReverseComplemented)
        XCTAssertFalse(SequencingPlatform.element.readsCanBeReverseComplemented)
        XCTAssertFalse(SequencingPlatform.ultima.readsCanBeReverseComplemented)
        XCTAssertFalse(SequencingPlatform.mgi.readsCanBeReverseComplemented)
        XCTAssertFalse(SequencingPlatform.unknown.readsCanBeReverseComplemented)
    }

    func testIndexesInSeparateReads() {
        XCTAssertTrue(SequencingPlatform.illumina.indexesInSeparateReads)
        XCTAssertTrue(SequencingPlatform.element.indexesInSeparateReads)
        XCTAssertTrue(SequencingPlatform.ultima.indexesInSeparateReads)
        XCTAssertTrue(SequencingPlatform.mgi.indexesInSeparateReads)
        XCTAssertFalse(SequencingPlatform.oxfordNanopore.indexesInSeparateReads)
        XCTAssertFalse(SequencingPlatform.pacbio.indexesInSeparateReads)
        XCTAssertFalse(SequencingPlatform.unknown.indexesInSeparateReads)
    }

    func testMayNeedPolyGTrimming() {
        XCTAssertTrue(SequencingPlatform.illumina.mayNeedPolyGTrimming)
        XCTAssertTrue(SequencingPlatform.element.mayNeedPolyGTrimming)
        XCTAssertFalse(SequencingPlatform.oxfordNanopore.mayNeedPolyGTrimming)
        XCTAssertFalse(SequencingPlatform.pacbio.mayNeedPolyGTrimming)
        XCTAssertFalse(SequencingPlatform.ultima.mayNeedPolyGTrimming)
        XCTAssertFalse(SequencingPlatform.mgi.mayNeedPolyGTrimming)
        XCTAssertFalse(SequencingPlatform.unknown.mayNeedPolyGTrimming)
    }

    func testRecommendedErrorRate() {
        XCTAssertEqual(SequencingPlatform.oxfordNanopore.recommendedErrorRate, 0.15, accuracy: 0.001)
        XCTAssertEqual(SequencingPlatform.illumina.recommendedErrorRate, 0.10, accuracy: 0.001)
        XCTAssertEqual(SequencingPlatform.pacbio.recommendedErrorRate, 0.10, accuracy: 0.001)
        XCTAssertEqual(SequencingPlatform.element.recommendedErrorRate, 0.10, accuracy: 0.001)
        XCTAssertEqual(SequencingPlatform.mgi.recommendedErrorRate, 0.10, accuracy: 0.001)
    }

    func testRecommendedMinimumOverlap() {
        XCTAssertEqual(SequencingPlatform.oxfordNanopore.recommendedMinimumOverlap, 20)
        XCTAssertEqual(SequencingPlatform.pacbio.recommendedMinimumOverlap, 14)
        XCTAssertEqual(SequencingPlatform.illumina.recommendedMinimumOverlap, 5)
        XCTAssertEqual(SequencingPlatform.element.recommendedMinimumOverlap, 5)
        XCTAssertEqual(SequencingPlatform.mgi.recommendedMinimumOverlap, 5)
    }

    // MARK: - Vendor String Init

    func testInitFromVendorString() {
        XCTAssertEqual(SequencingPlatform(vendor: "illumina"), .illumina)
        XCTAssertEqual(SequencingPlatform(vendor: "oxford-nanopore"), .oxfordNanopore)
        XCTAssertEqual(SequencingPlatform(vendor: "oxfordnanopore"), .oxfordNanopore)
        XCTAssertEqual(SequencingPlatform(vendor: "ont"), .oxfordNanopore)
        XCTAssertEqual(SequencingPlatform(vendor: "pacbio"), .pacbio)
        XCTAssertEqual(SequencingPlatform(vendor: "pacific-biosciences"), .pacbio)
        XCTAssertEqual(SequencingPlatform(vendor: "element"), .element)
        XCTAssertEqual(SequencingPlatform(vendor: "element-biosciences"), .element)
        XCTAssertEqual(SequencingPlatform(vendor: "ultima"), .ultima)
        XCTAssertEqual(SequencingPlatform(vendor: "ultima-genomics"), .ultima)
        XCTAssertEqual(SequencingPlatform(vendor: "mgi"), .mgi)
        XCTAssertEqual(SequencingPlatform(vendor: "bgi"), .mgi)
        XCTAssertEqual(SequencingPlatform(vendor: "dnbseq"), .mgi)
        XCTAssertEqual(SequencingPlatform(vendor: "mgi-tech"), .mgi)
    }

    func testInitFromVendorStringCaseInsensitive() {
        XCTAssertEqual(SequencingPlatform(vendor: "ILLUMINA"), .illumina)
        XCTAssertEqual(SequencingPlatform(vendor: "Oxford-Nanopore"), .oxfordNanopore)
        XCTAssertEqual(SequencingPlatform(vendor: "ONT"), .oxfordNanopore)
        XCTAssertEqual(SequencingPlatform(vendor: "PacBio"), .pacbio)
    }

    func testInitFromVendorStringUnderscoreNormalization() {
        XCTAssertEqual(SequencingPlatform(vendor: "oxford_nanopore"), .oxfordNanopore)
        XCTAssertEqual(SequencingPlatform(vendor: "element_biosciences"), .element)
        XCTAssertEqual(SequencingPlatform(vendor: "mgi_tech"), .mgi)
    }

    func testInitFromVendorStringUnknown() {
        XCTAssertEqual(SequencingPlatform(vendor: ""), .unknown)
        XCTAssertEqual(SequencingPlatform(vendor: "foo"), .unknown)
        XCTAssertEqual(SequencingPlatform(vendor: "454"), .unknown)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        for platform in SequencingPlatform.allCases {
            let data = try JSONEncoder().encode(platform)
            let decoded = try JSONDecoder().decode(SequencingPlatform.self, from: data)
            XCTAssertEqual(decoded, platform)
        }
    }

    func testCaseIterable() {
        XCTAssertEqual(SequencingPlatform.allCases.count, 7)
    }

    // MARK: - Poly-G Trim Quality

    func testDefaultPolyGTrimQualityForTwoColorPlatforms() {
        XCTAssertEqual(SequencingPlatform.illumina.defaultPolyGTrimQuality, 20)
        XCTAssertEqual(SequencingPlatform.element.defaultPolyGTrimQuality, 20)
    }

    func testDefaultPolyGTrimQualityNilForOtherPlatforms() {
        XCTAssertNil(SequencingPlatform.oxfordNanopore.defaultPolyGTrimQuality)
        XCTAssertNil(SequencingPlatform.pacbio.defaultPolyGTrimQuality)
        XCTAssertNil(SequencingPlatform.ultima.defaultPolyGTrimQuality)
        XCTAssertNil(SequencingPlatform.mgi.defaultPolyGTrimQuality)
        XCTAssertNil(SequencingPlatform.unknown.defaultPolyGTrimQuality)
    }

    func testPolyGTrimQualityConsistentWithMayNeedFlag() {
        for platform in SequencingPlatform.allCases {
            if platform.mayNeedPolyGTrimming {
                XCTAssertNotNil(platform.defaultPolyGTrimQuality, "\(platform) needs poly-G but has nil quality")
            } else {
                XCTAssertNil(platform.defaultPolyGTrimQuality, "\(platform) doesn't need poly-G but has quality")
            }
        }
    }
}
