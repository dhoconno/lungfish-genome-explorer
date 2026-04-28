import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class SequenceViewerFetchInvalidationTests: XCTestCase {
    func testStaleReadFetchCannotCommitAfterIdentityChangeAndNewFetchBegins() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        let regionA = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let regionB = GenomicRegion(chromosome: "chr1", start: 300, end: 400)
        let readA = makeRead(name: "read-A", position: 120)
        let readB = makeRead(name: "read-B", position: 320)

        let fetchA = view.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: regionA)
        view.testInvalidateAlignmentFetchState(bundleURL: bundleURL("A"), trackID: "track-B", region: regionB)
        let fetchB = view.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-B", region: regionB)

        XCTAssertFalse(view.testCommitReadFetch(fetchA, reads: [readA], region: regionA))
        XCTAssertNil(view.cachedReadRegion)
        XCTAssertTrue(view.testCachedAlignedReads.isEmpty)
        XCTAssertTrue(view.testIsFetchingReads)

        XCTAssertTrue(view.testCommitReadFetch(fetchB, reads: [readB], region: regionB))
        XCTAssertEqual(view.cachedReadRegion, regionB)
        XCTAssertEqual(view.testCachedAlignedReads.map(\.name), ["read-B"])
        XCTAssertFalse(view.testIsFetchingReads)
    }

    func testStaleDepthFetchCannotCommitAfterSettingsChangeAndNewFetchBegins() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        let regionA = GenomicRegion(chromosome: "chr2", start: 100, end: 200)
        let regionB = GenomicRegion(chromosome: "chr2", start: 100, end: 200)

        view.minMapQSetting = 0
        let fetchA = view.testBeginDepthFetch(bundleURL: bundleURL("A"), trackID: nil, region: regionA)

        view.minMapQSetting = 30
        view.testInvalidateAlignmentFetchState(bundleURL: bundleURL("A"), trackID: nil, region: regionB)
        let fetchB = view.testBeginDepthFetch(bundleURL: bundleURL("A"), trackID: nil, region: regionB)

        XCTAssertFalse(view.testCommitDepthFetch(fetchA, points: [.init(position: 125, depth: 3)], region: regionA))
        XCTAssertNil(view.cachedDepthRegion)
        XCTAssertTrue(view.testCachedDepthPoints.isEmpty)
        XCTAssertTrue(view.testIsFetchingDepth)

        XCTAssertTrue(view.testCommitDepthFetch(fetchB, points: [.init(position: 125, depth: 9)], region: regionB))
        XCTAssertEqual(view.cachedDepthRegion, regionB)
        XCTAssertEqual(view.testCachedDepthPoints, [.init(position: 125, depth: 9)])
        XCTAssertFalse(view.testIsFetchingDepth)
    }

    func testStaleConsensusFetchCannotCommitAfterConsensusSettingsChangeAndNewFetchBegins() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        let regionA = GenomicRegion(chromosome: "chr3", start: 10, end: 14)
        let regionB = GenomicRegion(chromosome: "chr3", start: 10, end: 14)

        view.consensusMinDepthSetting = 8
        let fetchA = view.testBeginConsensusFetch(bundleURL: bundleURL("A"), trackID: nil, region: regionA)

        view.consensusMinDepthSetting = 20
        view.testInvalidateAlignmentFetchState(bundleURL: bundleURL("A"), trackID: nil, region: regionB)
        let fetchB = view.testBeginConsensusFetch(bundleURL: bundleURL("A"), trackID: nil, region: regionB)

        XCTAssertFalse(view.testCommitConsensusFetch(fetchA, sequence: "AAAA", region: regionA))
        XCTAssertNil(view.cachedConsensusRegion)
        XCTAssertNil(view.testCachedConsensusSequence)
        XCTAssertTrue(view.testIsFetchingConsensus)

        XCTAssertTrue(view.testCommitConsensusFetch(fetchB, sequence: "CCCC", region: regionB))
        XCTAssertEqual(view.cachedConsensusRegion, regionB)
        XCTAssertEqual(view.testCachedConsensusSequence, "CCCC")
        XCTAssertFalse(view.testIsFetchingConsensus)
    }

    func testClearReferenceBundleInvalidatesAlignmentFetchGates() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        let region = GenomicRegion(chromosome: "chr4", start: 100, end: 200)
        let readFetch = view.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)
        let depthFetch = view.testBeginDepthFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)
        let consensusFetch = view.testBeginConsensusFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)

        view.clearReferenceBundle()

        XCTAssertFalse(view.testCommitReadFetch(readFetch, reads: [makeRead(name: "stale-read", position: 120)], region: region))
        XCTAssertFalse(view.testCommitDepthFetch(depthFetch, points: [.init(position: 125, depth: 3)], region: region))
        XCTAssertFalse(view.testCommitConsensusFetch(consensusFetch, sequence: "AAAA", region: region))
        XCTAssertNil(view.cachedReadRegion)
        XCTAssertNil(view.cachedDepthRegion)
        XCTAssertNil(view.cachedConsensusRegion)
    }

    func testShowReadsSettingsChangeInvalidatesInFlightReadFetch() {
        let viewer = ViewerViewController()
        _ = viewer.view
        let region = GenomicRegion(chromosome: "chr5", start: 100, end: 200)
        viewer.viewerView.showReads = true
        let staleFetch = viewer.viewerView.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)

        viewer.applyReadDisplaySettings([NotificationUserInfoKey.showReads: false])

        XCTAssertFalse(
            viewer.viewerView.testCommitReadFetch(
                staleFetch,
                reads: [makeRead(name: "stale-read", position: 120)],
                region: region
            )
        )
        XCTAssertNil(viewer.viewerView.cachedReadRegion)
        XCTAssertFalse(viewer.viewerView.testIsFetchingReads)

        let currentFetch = viewer.viewerView.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)
        XCTAssertNotEqual(staleFetch.identity, currentFetch.identity)
        XCTAssertTrue(
            viewer.viewerView.testCommitReadFetch(
                currentFetch,
                reads: [makeRead(name: "current-read", position: 130)],
                region: region
            )
        )
    }

    func testLimitReadRowsSettingsChangeInvalidatesInFlightReadFetch() {
        let viewer = ViewerViewController()
        _ = viewer.view
        let region = GenomicRegion(chromosome: "chr6", start: 100, end: 200)
        viewer.viewerView.limitReadRowsSetting = false
        let staleFetch = viewer.viewerView.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)

        viewer.applyReadDisplaySettings([NotificationUserInfoKey.limitReadRows: true])

        XCTAssertFalse(
            viewer.viewerView.testCommitReadFetch(
                staleFetch,
                reads: [makeRead(name: "stale-read", position: 120)],
                region: region
            )
        )
        XCTAssertNil(viewer.viewerView.cachedReadRegion)
        XCTAssertFalse(viewer.viewerView.testIsFetchingReads)

        let currentFetch = viewer.viewerView.testBeginReadFetch(bundleURL: bundleURL("A"), trackID: "track-A", region: region)
        XCTAssertNotEqual(staleFetch.identity, currentFetch.identity)
        XCTAssertTrue(
            viewer.viewerView.testCommitReadFetch(
                currentFetch,
                reads: [makeRead(name: "current-read", position: 130)],
                region: region
            )
        )
    }

    private func bundleURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: "/tmp/viewer-fetch-\(suffix).lungfishref", isDirectory: true)
    }

    private func makeRead(name: String, position: Int) -> AlignedRead {
        AlignedRead(
            name: name,
            flag: 0,
            chromosome: "chr1",
            position: position,
            mapq: 60,
            cigar: CIGAROperation.parse("10M") ?? [],
            sequence: "ACTGACTGAA",
            qualities: Array(repeating: 37, count: 10)
        )
    }
}
