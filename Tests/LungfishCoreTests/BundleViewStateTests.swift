// BundleViewStateTests.swift - Tests for portable per-bundle viewer state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class BundleViewStateTests: XCTestCase {

    func testRoundTripPersistsFilterTextAndSampleDisplayState() throws {
        var sampleState = SampleDisplayState(showGenotypeRows: false, rowHeight: 18)
        sampleState.hiddenSamples = ["blank-control"]

        let state = BundleViewState(
            annotationFilterText: "polymerase",
            variantFilterText: "QUAL > 100",
            hiddenVariantTrackIDs: ["ivar", "freebayes"],
            sampleDisplayState: sampleState
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertEqual(decoded.annotationFilterText, "polymerase")
        XCTAssertEqual(decoded.variantFilterText, "QUAL > 100")
        XCTAssertEqual(decoded.hiddenVariantTrackIDs, ["ivar", "freebayes"])
        XCTAssertEqual(decoded.sampleDisplayState, sampleState)
    }

    func testBackwardCompatibleDecodeDefaultsNewSessionStateFields() throws {
        let json = """
        {
          "annotationHeight" : 16,
          "annotationSpacing" : 2,
          "showAnnotations" : true,
          "showVariants" : true,
          "translationColorScheme" : "zappo",
          "isRNAMode" : false,
          "typeColorOverrides" : []
        }
        """

        let decoded = try JSONDecoder().decode(BundleViewState.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.annotationFilterText, "")
        XCTAssertEqual(decoded.variantFilterText, "")
        XCTAssertEqual(decoded.hiddenVariantTrackIDs, [])
        XCTAssertNil(decoded.sampleDisplayState)
    }

    func testLegacyAllVisibleAnnotationTypesIncludeNewORFTypes() throws {
        let legacyAllVisibleTypes = Set(AnnotationType.allCases).subtracting([.orf, .translation])
        let legacyState = BundleViewState(visibleAnnotationTypes: legacyAllVisibleTypes)
        let data = try JSONEncoder().encode(legacyState)

        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertTrue(decoded.visibleAnnotationTypes?.contains(.orf) ?? false)
        XCTAssertTrue(decoded.visibleAnnotationTypes?.contains(.translation) ?? false)
    }

    func testDefaultHasNoHiddenVariantTracks() {
        XCTAssertEqual(BundleViewState.default.hiddenVariantTrackIDs, [])
    }

    func testAllVariantTrackIDsCanBePersistedAsHidden() throws {
        let state = BundleViewState(hiddenVariantTrackIDs: ["track-a", "track-b"])

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)

        XCTAssertEqual(decoded.hiddenVariantTrackIDs, ["track-a", "track-b"])
    }

    // MARK: - Restored state (plan row S11)

    /// The 17 keys that `.viewstate.json` has always held. The restored state is session
    /// bookkeeping, so it is not one of them.
    private static let savedKeys: Set<String> = [
        "typeColorOverrides", "annotationColorOverrides", "annotationHeight", "annotationSpacing",
        "showAnnotations", "visibleAnnotationTypes", "annotationFilterText",
        "showVariants", "visibleVariantTypes", "variantFilterText", "hiddenVariantTrackIDs", "sampleDisplayState",
        "translationColorScheme", "isRNAMode", "lastChromosome", "lastOrigin", "lastScale",
    ]

    private func makeBundleFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleViewStateTests-\(UUID().uuidString).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func viewStateURL(in folder: URL) -> URL {
        folder.appendingPathComponent(BundleViewState.filename)
    }

    /// A state with every saved field set to something other than its default.
    private func makeFullState() -> BundleViewState {
        var sampleState = SampleDisplayState(showGenotypeRows: false, rowHeight: 18)
        sampleState.hiddenSamples = ["blank-control"]
        return BundleViewState(
            typeColorOverrides: [.gene: AnnotationColor(red: 0.1, green: 0.2, blue: 0.3)],
            annotationColorOverrides: ["chr1:1-10:geneA": AnnotationColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.5)],
            annotationHeight: 22,
            annotationSpacing: 4,
            showAnnotations: false,
            visibleAnnotationTypes: [.gene, .cds],
            annotationFilterText: "polymerase",
            showVariants: false,
            visibleVariantTypes: ["SNP", "DEL"],
            variantFilterText: "QUAL > 100",
            hiddenVariantTrackIDs: ["ivar"],
            sampleDisplayState: sampleState,
            translationColorScheme: .zappo,
            isRNAMode: true,
            lastChromosome: "chr2",
            lastOrigin: 120.5,
            lastScale: 0.25
        )
    }

    func testRestoredStateAddsNoKeyToTheFileAndLosesNoField() throws {
        var state = makeFullState()
        state.markRestored()

        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Self.savedKeys, "The saved file keeps exactly its 17 keys.")

        let decoded = try JSONDecoder().decode(BundleViewState.self, from: data)
        XCTAssertEqual(decoded, state, "Every saved field survives the round trip.")
        XCTAssertFalse(decoded.matchesRestoredState, "A decoded state has no restored state on record.")
    }

    func testEqualityIgnoresTheRestoredState() {
        let plain = makeFullState()
        var marked = plain
        marked.markRestored()
        XCTAssertEqual(plain, marked)
        XCTAssertFalse(plain.matchesRestoredState)
        XCTAssertTrue(marked.matchesRestoredState)
    }

    func testSavingTheRestoredStateWritesNothing() throws {
        let folder = try makeBundleFolder()
        var state = makeFullState()
        state.markRestored()

        XCTAssertFalse(state.saveUnlessRestored(to: folder))

        XCTAssertFalse(FileManager.default.fileExists(atPath: viewStateURL(in: folder).path))
    }

    func testSavingAChangedStateWritesItOnceAndRecordsItAsWritten() throws {
        let folder = try makeBundleFolder()
        var state = makeFullState()
        state.markRestored()
        state.lastScale = 0.125
        XCTAssertFalse(state.matchesRestoredState)

        XCTAssertTrue(state.saveUnlessRestored(to: folder))
        XCTAssertEqual(BundleViewState.load(from: folder), state)
        XCTAssertTrue(state.matchesRestoredState, "The written state is now the one on record.")

        try FileManager.default.removeItem(at: viewStateURL(in: folder))
        XCTAssertFalse(state.saveUnlessRestored(to: folder), "The same state is not written twice.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewStateURL(in: folder).path))
    }

    func testChangingAFieldAndChangingItBackWritesNothing() throws {
        let folder = try makeBundleFolder()
        var state = makeFullState()
        state.markRestored()

        state.annotationHeight = 30
        state.annotationHeight = 22

        XCTAssertFalse(state.saveUnlessRestored(to: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewStateURL(in: folder).path))
    }

    func testSetsCompareByContentSoTheOrderOfInsertionNeverShowsAsAChange() throws {
        let folder = try makeBundleFolder()
        var restored = BundleViewState(visibleVariantTypes: Set((0..<40).map { "T\($0)" }), hiddenVariantTrackIDs: Set((0..<40).map { "id\($0)" }))
        restored.markRestored()
        var rebuilt = restored
        rebuilt.visibleVariantTypes = Set((0..<40).reversed().map { "T\($0)" })
        rebuilt.hiddenVariantTrackIDs = Set((0..<40).reversed().map { "id\($0)" })

        XCTAssertFalse(rebuilt.saveUnlessRestored(to: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewStateURL(in: folder).path))
    }

    func testAStateWithNoRestoredStateOnRecordIsSaved() throws {
        let folder = try makeBundleFolder()
        var state = makeFullState()

        XCTAssertTrue(state.saveUnlessRestored(to: folder))
        XCTAssertEqual(BundleViewState.load(from: folder), state)
    }

    func testSaveToStillWritesWhateverTheRestoredState() throws {
        let folder = try makeBundleFolder()
        var state = makeFullState()
        state.markRestored()

        state.save(to: folder)

        XCTAssertEqual(BundleViewState.load(from: folder), state, "The explicit save keeps its old meaning.")
    }
}
