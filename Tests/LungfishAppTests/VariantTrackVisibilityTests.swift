import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class VariantTrackVisibilityTests: XCTestCase {
    func testIndexCompletionPublishesRestoredHiddenTracksWithVariantTypes() {
        let viewModel = AnnotationSectionViewModel()
        var publishedHiddenTrackIDs: Set<String>?
        viewModel.onVariantFilterChanged = {
            publishedHiddenTrackIDs = viewModel.hiddenVariantTrackIDs
        }

        MainWindowController.synchronizeVariantFilterState(
            viewModel,
            variantTypes: ["SNP"],
            tracks: [
                .init(id: "track-a", name: "Caller A"),
                .init(id: "track-b", name: "Caller B"),
            ],
            hiddenTrackIDs: ["track-a", "stale-track"]
        )

        XCTAssertEqual(viewModel.hiddenVariantTrackIDs, ["track-a"])
        XCTAssertEqual(publishedHiddenTrackIDs, ["track-a"])
    }

    func testViewModelReconcilesHiddenTracksByIDAndLeavesNewTrackVisible() {
        let viewModel = AnnotationSectionViewModel()
        viewModel.setAvailableVariantTracks([
            .init(id: "a", name: "Caller"),
            .init(id: "b", name: "Caller"),
        ])

        viewModel.setVariantTrackVisible(trackID: "a", visible: false)
        viewModel.setAvailableVariantTracks([
            .init(id: "a", name: "Caller"),
            .init(id: "c", name: "New"),
        ])

        XCTAssertEqual(viewModel.hiddenVariantTrackIDs, ["a"])
        XCTAssertFalse(viewModel.hiddenVariantTrackIDs.contains("c"))
    }

    func testViewModelPreservesHideAllAcrossInventoryRefresh() {
        let viewModel = AnnotationSectionViewModel()
        let tracks = [
            VariantTrackVisibilityItem(id: "a", name: "Caller A"),
            VariantTrackVisibilityItem(id: "b", name: "Caller B"),
        ]
        viewModel.setAvailableVariantTracks(tracks)
        viewModel.setAllVariantTracksVisible(false)
        viewModel.setAvailableVariantTracks(tracks)

        XCTAssertEqual(viewModel.hiddenVariantTrackIDs, ["a", "b"])
        XCTAssertEqual(viewModel.availableVariantTracks, tracks)
    }

    func testDrawerHidesOnlyMatchingTrackWhenRowIDsOverlap() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let rows = [
            makeResult(trackID: "a", trackName: "Caller", name: "a"),
            makeResult(trackID: "b", trackName: "Caller", name: "b"),
        ]

        drawer.setHiddenVariantTrackIDs(["a"])

        XCTAssertEqual(drawer.applyVariantColumnFilters(to: rows).map(\.trackId), ["b"])
    }

    func testViewerTrackVisibilityAppliesWithoutTableKeysAndKeepsUntrackedLegacyItems() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        viewer.cachedVariantAnnotations = [
            makeAnnotation(trackID: "a", rowID: "7", name: "a"),
            makeAnnotation(trackID: "b", rowID: "7", name: "b"),
            SequenceAnnotation(type: .snp, name: "legacy", chromosome: "chr1", start: 30, end: 31, strand: .unknown),
        ]
        viewer.cachedGenotypeData = GenotypeDisplayData(
            sampleNames: ["sample"],
            sites: [makeSite(trackID: "a"), makeSite(trackID: "b")],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 100)
        )

        viewer.setHiddenVariantTrackIDs(["a"])

        XCTAssertEqual(Set(viewer.filteredVisibleVariantAnnotations.map(\.name)), ["b", "legacy"])
        XCTAssertEqual(viewer.filteredVisibleGenotypeData()?.sites.compactMap(\.sourceTrackId), ["b"])
    }

    func testViewerTrackVisibilityIntersectsTableKeysAndGenotypes() {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        viewer.cachedVariantAnnotations = [
            makeAnnotation(trackID: "a", rowID: "7", name: "a"),
            makeAnnotation(trackID: "b", rowID: "7", name: "b"),
        ]
        viewer.cachedGenotypeData = GenotypeDisplayData(
            sampleNames: ["sample"],
            sites: [makeSite(trackID: "a"), makeSite(trackID: "b")],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 100)
        )
        viewer.setLocalVariantRenderFilterKeys(["a:7", "b:7"])
        viewer.setHiddenVariantTrackIDs(["a"])

        XCTAssertEqual(viewer.filteredVisibleVariantAnnotations.map { $0.qualifiers["variant_track_id"]?.values.first }, ["b"])
        XCTAssertEqual(viewer.filteredVisibleGenotypeData()?.sites.compactMap(\.sourceTrackId), ["b"])
    }

    func testViewerCanRestoreTrackAfterAllHidden() {
        let viewer = SequenceViewerView(frame: .zero)
        viewer.cachedVariantAnnotations = [makeAnnotation(trackID: "a", rowID: "7", name: "a")]
        viewer.cachedGenotypeData = GenotypeDisplayData(
            sampleNames: ["sample"],
            sites: [makeSite(trackID: "a")],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 100)
        )

        viewer.setHiddenVariantTrackIDs(["a"])
        XCTAssertTrue(viewer.filteredVisibleVariantAnnotations.isEmpty)
        XCTAssertTrue(viewer.filteredVisibleGenotypeData()?.sites.isEmpty == true)
        viewer.setHiddenVariantTrackIDs([])

        XCTAssertEqual(viewer.filteredVisibleVariantAnnotations.map(\.name), ["a"])
        XCTAssertEqual(viewer.filteredVisibleGenotypeData()?.sites.compactMap(\.sourceTrackId), ["a"])
    }

    private func makeResult(trackID: String, trackName: String, name: String) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: name, chromosome: "chr1", start: 10, end: 11,
            trackId: trackID, trackName: trackName, type: "SNP",
            ref: "A", alt: "G", variantRowId: 7
        )
    }

    private func makeAnnotation(trackID: String, rowID: String, name: String) -> SequenceAnnotation {
        SequenceAnnotation(
            type: .snp, name: name, chromosome: "chr1", start: 10, end: 11,
            strand: .unknown,
            qualifiers: [
                "variant_track_id": AnnotationQualifier(trackID),
                "variant_row_id": AnnotationQualifier(rowID),
            ]
        )
    }

    private func makeSite(trackID: String) -> VariantSite {
        VariantSite(
            position: 10, ref: "A", alt: "G", variantType: "SNP",
            genotypes: ["sample": .het], databaseRowId: 7, sourceTrackId: trackID
        )
    }
}
