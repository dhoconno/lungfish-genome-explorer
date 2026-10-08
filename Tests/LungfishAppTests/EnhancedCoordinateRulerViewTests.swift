import AppKit
import XCTest
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class EnhancedCoordinateRulerViewTests: XCTestCase {

    func testInfoBarLayoutKeepsLabelsBeforePositionControlsInNarrowPane() {
        let layout = EnhancedCoordinateRulerView.infoBarTextLayout(
            viewWidth: 330,
            rangeTextWidth: 150,
            totalTextWidth: 85
        )

        XCTAssertLessThanOrEqual(layout.rangeRect.maxX, layout.textClipMaxX)
        XCTAssertNil(layout.totalRect)
        XCTAssertLessThan(layout.rangeRect.width, 150)
    }

    func testInfoBarLayoutShowsTotalTextWhenSpaceAllows() {
        let layout = EnhancedCoordinateRulerView.infoBarTextLayout(
            viewWidth: 900,
            rangeTextWidth: 150,
            totalTextWidth: 85
        )

        XCTAssertEqual(layout.rangeRect.width, 150)
        XCTAssertEqual(layout.totalRect?.width, 85)
        XCTAssertLessThanOrEqual(layout.totalRect?.maxX ?? 0, layout.textClipMaxX)
    }

    /// The range text and position labels are SF Mono Medium. Looking that font up per draw
    /// could return nil under load, and CoreText raised on the nil font, so the ruler keeps it.
    func testRulerDrawsWithoutLookingSFMonoMediumUp() throws {
        let ruler = EnhancedCoordinateRulerView(
            frame: NSRect(x: 0, y: 0, width: 900, height: EnhancedCoordinateRulerView.recommendedHeight)
        )
        ruler.referenceFrame = ReferenceFrame(
            chromosome: "chr1", start: 1_000, end: 2_000, pixelWidth: 900, sequenceLength: 50_000
        )
        let rep = try XCTUnwrap(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))

        let lookups = monospacedSystemFontLookups(weight: .medium) {
            ruler.cacheDisplay(in: ruler.bounds, to: rep)
        }
        XCTAssertEqual(lookups, [], "the ruler looked SF Mono Medium up while drawing")
    }
}
