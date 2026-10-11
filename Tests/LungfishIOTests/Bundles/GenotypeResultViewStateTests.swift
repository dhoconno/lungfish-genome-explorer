import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO

/// The genotype result's app state file (plan decision S11).
final class GenotypeResultViewStateTests: XCTestCase {
    func testABundleWithNoFileStartsFromTheViewFieldsOfItsSidecar() throws {
        let bundle = try TestTempDirectory.make(prefix: "GenotypeViewState")
        defer { TestTempDirectory.cleanup(bundle) }
        var settings = GenotypeAnnotationSidecar.Settings.default
        settings.preferredSummaryViewMode = "matrix"
        settings.cardDensity = "compact"

        let starting = GenotypeResultViewState.starting(forBundleAt: bundle, sidecarSettings: settings)

        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: bundle))
        XCTAssertEqual(starting.preferredSummaryViewMode, "matrix")
        XCTAssertEqual(starting.viewMode, "outline")
        XCTAssertEqual(starting.panelLayout, "aLeading")
        XCTAssertEqual(starting.cardDensity, "compact")
        XCTAssertEqual(starting.cardDensityThreshold, 30)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.path), [], "reading writes nothing")
    }

    func testTheSavedFileWinsOverTheSidecarAndRoundTrips() throws {
        let bundle = try TestTempDirectory.make(prefix: "GenotypeViewState")
        defer { TestTempDirectory.cleanup(bundle) }
        var settings = GenotypeAnnotationSidecar.Settings.default
        settings.preferredSummaryViewMode = "matrix"
        var chosen = GenotypeResultViewState(startingFrom: settings)
        chosen.preferredSummaryViewMode = "outline"

        try chosen.save(toBundleAt: bundle)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bundle.path), [GenotypeResultViewState.filename])
        XCTAssertEqual(GenotypeResultViewState.load(fromBundleAt: bundle), chosen)
        XCTAssertEqual(GenotypeResultViewState.starting(forBundleAt: bundle, sidecarSettings: settings), chosen)
    }

    func testAFileWithUnknownOrMissingFieldsStillOpens() throws {
        let bundle = try TestTempDirectory.make(prefix: "GenotypeViewState")
        defer { TestTempDirectory.cleanup(bundle) }
        try Data(#"{"preferredSummaryViewMode":"matrix","futureField":[1,2]}"#.utf8)
            .write(to: GenotypeResultViewState.fileURL(forBundleAt: bundle))

        let loaded = try XCTUnwrap(GenotypeResultViewState.load(fromBundleAt: bundle))

        XCTAssertEqual(loaded, GenotypeResultViewState(
            preferredSummaryViewMode: "matrix", viewMode: "outline", panelLayout: "aLeading",
            cardDensity: "auto", cardDensityThreshold: 30
        ))
    }

    func testAnUnreadableFileFallsBackToTheSidecar() throws {
        let bundle = try TestTempDirectory.make(prefix: "GenotypeViewState")
        defer { TestTempDirectory.cleanup(bundle) }
        try Data("not json".utf8).write(to: GenotypeResultViewState.fileURL(forBundleAt: bundle))

        XCTAssertNil(GenotypeResultViewState.load(fromBundleAt: bundle))
        XCTAssertNil(GenotypeResultViewState.starting(forBundleAt: bundle, sidecarSettings: .default).preferredSummaryViewMode)
    }

    /// The view fields stay in the sidecar settings, so an older file decodes
    /// and encodes them as before and the Excel export record keeps them.
    func testTheSidecarSettingsStillCarryTheViewFields() throws {
        var settings = GenotypeAnnotationSidecar.Settings.default
        settings.preferredSummaryViewMode = "matrix"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])

        XCTAssertEqual(object["preferredSummaryViewMode"] as? String, "matrix")
        XCTAssertEqual(object["viewMode"] as? String, "outline")
        XCTAssertEqual(object["panelLayout"] as? String, "aLeading")
        XCTAssertEqual(object["cardDensity"] as? String, "auto")
        XCTAssertEqual(object["cardDensityThreshold"] as? Int, 30)
    }
}
