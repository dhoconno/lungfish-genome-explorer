// ViewerFigureTrackTextParityTests.swift - CoreText track labels against the AppKit labels they replace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import CoreText
import XCTest
@testable import LungfishApp
import LungfishWorkflow

/// Lane 13.29 M2. The track renderers drew labels with `NSString` in the system font, and now
/// draw them through `ViewerFigureTrackText`. The face, the width and the line height must be
/// the ones AppKit used, so a label keeps its place in the live viewer (UX 1).
@MainActor
final class ViewerFigureTrackTextParityTests: XCTestCase {

    private let strings = ["max: 128x", "Depth (log)", "+12 reads not shown (max 75 rows)", "3 variants", "S1", "I5"]

    private func assertSameFace(_ face: ViewerFigureTrackText.Face, as nsFont: NSFont, size: Double) {
        // AppKit names the face `.AppleSystemUIFont` and CoreText `.SFNS-Regular`, so the face is
        // checked by its metrics. The line box differs: AppKit's `size` height is 14 at 11 points
        // and 10 at 8 points, where ascent, descent and leading give 12.96 and 9.42, so M2's
        // baseline step measures the label offsets and does not take one from the other.
        let font = ViewerFigureTrackText.font(face, size: size)
        XCTAssertEqual(Double(CTFontGetSize(font)), size)
        XCTAssertEqual(Double(CTFontGetAscent(font)), Double(nsFont.ascender), accuracy: 0.01, "\(face)")
        XCTAssertEqual(Double(CTFontGetDescent(font)), Double(-nsFont.descender), accuracy: 0.01, "\(face)")
        for string in strings {
            let appKit = (string as NSString).size(withAttributes: [.font: nsFont])
            XCTAssertEqual(ViewerFigureTrackText.width(string, font: font), Double(appKit.width), accuracy: 0.01, "\(face) \(string)")
        }
    }

    func testTheSystemFacesMatchTheAppKitFontsTheRenderersUsed() {
        assertSameFace(.system, as: NSFont.systemFont(ofSize: 9), size: 9)
        assertSameFace(.system, as: NSFont.systemFont(ofSize: 11), size: 11)
        assertSameFace(.systemMedium, as: NSFont.systemFont(ofSize: 8, weight: .medium), size: 8)
        assertSameFace(.monospacedDigitSystem, as: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), size: 9)
        XCTAssertEqual(ViewerFigureTrackText.mediumWeight, Double(NSFont.Weight.medium.rawValue), accuracy: 0.0001)
    }

    func testTheThemeFollowsTheBestMatchOfAquaAndDarkAqua() throws {
        let cases: [(NSAppearance.Name, ViewerFigureTheme)] = [
            (.aqua, .light), (.darkAqua, .dark), (.vibrantLight, .light), (.vibrantDark, .dark),
            (.accessibilityHighContrastAqua, .light), (.accessibilityHighContrastDarkAqua, .dark),
        ]
        for (name, theme) in cases {
            XCTAssertEqual(ViewerFigureTheme.resolved(for: try XCTUnwrap(NSAppearance(named: name))), theme, name.rawValue)
        }
    }

    func testTheFigureFrameCarriesEveryValueOfTheLiveFrame() {
        let live = ReferenceFrame(chromosome: "chr2", start: 10.5, end: 990.25, pixelWidth: 640, sequenceLength: 5_000)
        live.leadingInset = 96
        live.trailingInset = ReferenceFrame.defaultTrailingInset
        let figure = live.figureFrame
        XCTAssertEqual(figure.chromosome, "chr2")
        XCTAssertEqual(figure.start, 10.5)
        XCTAssertEqual(figure.end, 990.25)
        XCTAssertEqual(figure.pixelWidth, 640)
        XCTAssertEqual(figure.sequenceLength, 5_000)
        XCTAssertEqual(figure.leadingInset, 96)
        XCTAssertEqual(figure.trailingInset, ReferenceFrame.defaultTrailingInset)
        for x in stride(from: 0.0, through: 640, by: 37.5) {
            XCTAssertEqual(figure.genomicPosition(for: x), live.genomicPosition(for: x), accuracy: 1e-9)
        }
    }

    /// A label drawn at a top-left point puts its ink inside the line box below that point, as
    /// `NSString.draw(at:)` did in the flipped view.
    func testALabelDrawsBelowItsTopLeftPointInAFlippedContext() throws {
        let width = 120
        let height = 30
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let font = ViewerFigureTrackText.font(.system, size: 9)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            ViewerFigureTrackText.draw(
                "max: 12x", font: font, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                topLeft: CGPoint(x: 10, y: 8), in: context
            )
        }
        var inkRows = Set<Int>()
        var inkColumns = Set<Int>()
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 {
                inkRows.insert(y)
                inkColumns.insert(x)
            }
        }
        let top = try XCTUnwrap(inkRows.min())
        let bottom = try XCTUnwrap(inkRows.max())
        XCTAssertGreaterThanOrEqual(top, 8)
        XCTAssertLessThanOrEqual(Double(bottom), 8 + ViewerFigureTrackText.lineHeight(font))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(inkColumns.min()), 10)
        XCTAssertLessThanOrEqual(Double(try XCTUnwrap(inkColumns.max())), 10 + ViewerFigureTrackText.width("max: 12x", font: font) + 1)
    }
}
