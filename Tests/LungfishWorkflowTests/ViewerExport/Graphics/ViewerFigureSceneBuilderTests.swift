// ViewerFigureSceneBuilderTests.swift - Fonts by checked name, and the scene builder base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, ruling sections 2.2 and 2.5 of ARCH-B10-graphics, BIO 4).

import CoreText
import XCTest
@testable import LungfishWorkflow

final class ViewerFigureFontsTests: XCTestCase {
    func testInstalledFaceResolvesToItselfWithNoFallback() throws {
        let (font, resolution) = try ViewerFigureFonts.resolve(["Menlo-Regular"], size: 9)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Menlo-Regular")
        XCTAssertEqual(CTFontGetSize(font), 9)
        XCTAssertEqual(resolution, ViewerFigureFontResolution(requested: "Menlo-Regular", resolved: "Menlo-Regular", size: 9))
        XCTAssertFalse(resolution.fallback)
    }

    func testMissingFaceIsNeverSubstitutedSilently() {
        // CoreText returns some face for any name, so only the name check can see this.
        let raw = CTFontCreateWithName("LungfishNoSuchFace-Regular" as CFString, 9, nil)
        XCTAssertNotEqual(CTFontCopyPostScriptName(raw) as String, "LungfishNoSuchFace-Regular")
        XCTAssertNil(ViewerFigureFonts.font(named: "LungfishNoSuchFace-Regular", size: 9))
    }

    func testMissingFaceFallsBackInOrderAndRecordsIt() throws {
        let (font, resolution) = try ViewerFigureFonts.resolve(["LungfishNoSuchFace-Regular", "Menlo-Bold"], size: 10)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Menlo-Bold")
        XCTAssertEqual(resolution.requested, "LungfishNoSuchFace-Regular")
        XCTAssertEqual(resolution.resolved, "Menlo-Bold")
        XCTAssertTrue(resolution.fallback)

        let last = try ViewerFigureFonts.resolve(["LungfishNoSuchFace-Regular"], size: 10).resolution
        XCTAssertEqual(last.resolved, ViewerFigureFonts.fallbackName)
        XCTAssertTrue(last.fallback)
    }

    func testMetricsMeasureTheLine() {
        let font = ViewerFigureFonts.font(named: "Menlo-Regular", size: 10)!
        let one = ViewerFigureFonts.metrics("A", font: font)
        let four = ViewerFigureFonts.metrics("ACGT", font: font)
        XCTAssertGreaterThan(one.width, 0)
        XCTAssertEqual(four.width, one.width * 4, accuracy: 0.001, "Menlo is monospaced")
        XCTAssertGreaterThan(one.ascent, 0)
        XCTAssertGreaterThan(one.descent, 0)
    }
}

/// A track that draws a band and a label, and notes whether it ran on the main thread.
private struct BandTrack: ViewerFigureTrackBuilding {
    let height: Double
    let role: ViewerFigureColorRole
    let fontNames: [String]

    func build(into canvas: inout ViewerFigureCanvas, frame: ViewerFigureFrame, area: ViewerFigureRect) async throws {
        XCTAssertFalse(Self.onMainThread(), "a track builds off the main actor")
        canvas.fill(area, ViewerFigurePaint(role))
        canvas.strokeSegments([], lineWidth: 1, ViewerFigurePaint(.separator))
        let x = Double(frame.screenPosition(for: (frame.start + frame.end) / 2))
        try canvas.text(
            frame.chromosome, fontNames: fontNames, size: 9, at: ViewerFigurePoint(x: x, y: area.y + area.height - 2),
            anchor: .baselineCenter, ViewerFigurePaint(.label)
        )
    }

    private static func onMainThread() -> Bool {
        Thread.isMainThread
    }
}

final class ViewerFigureSceneBuilderTests: XCTestCase {
    // 64 bases a point, so the midpoint lands on x 150 exactly.
    private let frame = ViewerFigureFrame(chromosome: "chr21", start: 0, end: 19200, pixelWidth: 300)

    @MainActor
    func testBuildStacksTracksOffTheMainActorAndRecordsFonts() async throws {
        let scene = try await ViewerFigureSceneBuilder.build(
            frame: frame, appearance: .dark,
            tracks: [
                BandTrack(height: 20, role: .windowBackground, fontNames: ["Menlo-Regular"]),
                BandTrack(height: 14, role: .baseA, fontNames: ["LungfishNoSuchFace-Regular", "Menlo-Regular"]),
                BandTrack(height: 6, role: .baseC, fontNames: ["Menlo-Regular"]),
            ]
        )
        XCTAssertEqual(scene.width, 300)
        XCTAssertEqual(scene.height, 40)
        XCTAssertEqual(scene.appearance, .dark)
        XCTAssertEqual(scene.frame, frame)
        XCTAssertEqual(scene.background, ViewerFigurePaint(.textBackground))
        XCTAssertEqual(scene.formatVersion, ViewerFigureScene.currentFormatVersion)
        let fills = scene.items.compactMap { item -> ViewerFigureRect? in
            if case .fill(let rect, _) = item { return rect }
            return nil
        }
        XCTAssertEqual(fills, [
            ViewerFigureRect(x: 0, y: 0, width: 300, height: 20),
            ViewerFigureRect(x: 0, y: 20, width: 300, height: 14),
            ViewerFigureRect(x: 0, y: 34, width: 300, height: 6),
        ])
        XCTAssertEqual(scene.items.count, 6, "an empty segment list adds no item")
        XCTAssertEqual(scene.fonts, [
            ViewerFigureFontResolution(requested: "Menlo-Regular", resolved: "Menlo-Regular", size: 9),
            ViewerFigureFontResolution(requested: "LungfishNoSuchFace-Regular", resolved: "Menlo-Regular", size: 9),
        ])
        guard case .text(let text) = scene.items[5] else {
            return XCTFail("the last item is the third track's label")
        }
        XCTAssertEqual(text.fontName, "Menlo-Regular", "a text run names the resolved face")
        XCTAssertEqual(text.point, ViewerFigurePoint(x: 150, y: 38))
    }

    func testCancelledBuildStopsBeforeTheFirstTrack() async {
        let frame = frame
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ViewerFigureSceneBuilder.build(
                frame: frame, appearance: .light, tracks: [BandTrack(height: 10, role: .baseG, fontNames: ["Menlo-Regular"])]
            )
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled build returned a scene")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testSceneEncodesWithSortedKeysAndRoundTrips() throws {
        let scene = ViewerFigureTestSupport.sampleScene()
        let json = try scene.goldenJSON()
        XCTAssertEqual(json.last, 0x0A)
        XCTAssertEqual(try JSONDecoder().decode(ViewerFigureScene.self, from: json), scene)
        XCTAssertEqual(try scene.goldenJSON(), json, "encoding is stable")
        let text = String(decoding: json, as: UTF8.self)
        let topKeys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { $0.split(separator: "\"")[1] }
        XCTAssertEqual(topKeys, ["appearance", "background", "fonts", "formatVersion", "frame", "height", "items", "width"])
    }
}
