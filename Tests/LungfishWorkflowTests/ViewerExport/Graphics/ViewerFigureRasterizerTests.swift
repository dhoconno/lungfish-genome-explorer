// ViewerFigureRasterizerTests.swift - Drawing, determinism and metadata of figure files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, ruling sections 2.2, 2.5 and 6 of ARCH-B10-graphics). C against C' is
// byte for byte on one host and build. PNG, JPEG and TIFF are compared whole. A PDF is
// compared with its /CreationDate, /ModDate and trailer /ID masked, the three values the PDF
// context writes from the clock and a random source (lane 13.28 measure). QA owns the
// contract mask for them. These tests only show that nothing else moves.

import CoreGraphics
import XCTest
import LungfishCore
@testable import LungfishWorkflow

private typealias Support = ViewerFigureTestSupport

final class ViewerFigureRasterizerTests: XCTestCase {
    func testBitmapSizeFollowsThePixelScale() throws {
        for scale in [1.0, 2.0, 1.5] {
            let image = try Support.image(try ViewerFigureRasterizer.render(Support.sampleScene(), format: .png, pixelScale: scale))
            XCTAssertEqual(image.width, Int((120 * scale).rounded(.up)))
            XCTAssertEqual(image.height, Int((40 * scale).rounded(.up)))
        }
    }

    func testDrawsTheThemeColoursWithTheOriginAtTheTopLeft() throws {
        for appearance in ViewerFigureAppearance.allCases {
            let scene = Support.sampleScene(appearance: appearance)
            let image = try Support.image(try ViewerFigureRasterizer.render(scene, format: .png, pixelScale: 1))
            let expect: (ViewerFigureColorRole) -> [UInt8] = { role in
                let color = scene.theme.color(role)
                return [color.red, color.green, color.blue].map { UInt8(($0 * 255).rounded()) } + [255]
            }
            // Within one step of 255, since the 8-bit store may round either way.
            for (x, y, role) in [(5, 5, ViewerFigureColorRole.baseA), (15, 5, .baseT), (5, 36, .windowBackground)] {
                let got = try Support.pixel(image, x: x, y: y)
                for (value, wanted) in zip(got, expect(role)) {
                    XCTAssertEqual(Int(value), Int(wanted), accuracy: 1, "\(role.rawValue) at \(x), \(y) in \(appearance)")
                }
            }
        }
    }

    func testRendersOffTheMainActor() async throws {
        let scene = Support.sampleScene()
        let data = try await Task.detached { try ViewerFigureRasterizer.render(scene, format: .tiff) }.value
        XCTAssertEqual(data, try ViewerFigureRasterizer.render(scene, format: .tiff))
    }

    func testAFontMissingAtDrawTimeFailsTheRender() {
        let scene = ViewerFigureScene(
            width: 20, height: 20, appearance: .light, background: ViewerFigurePaint(.textBackground), frame: nil,
            fonts: [], items: [.text(ViewerFigureText(
                string: "x", fontName: "LungfishNoSuchFace-Regular", fontSize: 9,
                point: ViewerFigurePoint(x: 1, y: 10), anchor: .baselineStart, paint: ViewerFigurePaint(.label)
            ))]
        )
        for format in ViewerFigureFormat.allCases {
            XCTAssertThrowsError(try ViewerFigureRasterizer.render(scene, format: format)) { error in
                XCTAssertEqual(error as? ViewerFigureRasterizerError, .fontMissing("LungfishNoSuchFace-Regular"))
            }
        }
    }

    func testRefusesAnEmptyFigure() {
        let scene = ViewerFigureScene(
            width: 0, height: 10, appearance: .light, background: ViewerFigurePaint(.textBackground),
            frame: nil, fonts: [], items: []
        )
        XCTAssertThrowsError(try ViewerFigureRasterizer.render(scene, format: .png))
    }
}

final class ViewerFigureRasterizerDeterminismTests: XCTestCase {
    private static let childOutputKey = "LUNGFISH_VIEWER_FIGURE_CHILD_OUTPUT"

    private static func renderAll() throws -> [ViewerFigureFormat: Data] {
        var files: [ViewerFigureFormat: Data] = [:]
        for format in ViewerFigureFormat.allCases {
            files[format] = try ViewerFigureRasterizer.render(Support.sampleScene(), format: format)
        }
        return files
    }

    private func assertSameBytes(
        _ first: [ViewerFigureFormat: Data], _ second: [ViewerFigureFormat: Data], _ what: String
    ) throws {
        for format in ViewerFigureFormat.allCases {
            let one = try XCTUnwrap(first[format]), two = try XCTUnwrap(second[format])
            if format == .pdf {
                XCTAssertEqual(one.count, two.count, "\(what) pdf length")
                XCTAssertEqual(Support.maskingPDFVolatileValues(one), Support.maskingPDFVolatileValues(two), "\(what) pdf")
                let volatile = Support.pdfVolatileRanges(one).joined().flatMap { Array($0) }
                let stray = Set(Support.differingOffsets(one, two)).subtracting(volatile)
                XCTAssertTrue(stray.isEmpty, "\(what) pdf differs outside the three values at \(stray.sorted().prefix(8))")
            } else {
                XCTAssertEqual(one, two, "\(what) \(format.rawValue)")
            }
        }
    }

    func testSameSceneGivesSameBytesTwiceInOneProcess() throws {
        let first = try Self.renderAll()
        let second = try Self.renderAll()
        try assertSameBytes(first, second, "one process")
        // The negative control: the trailer /ID is new on every render, so the PDF bytes differ.
        XCTAssertNotEqual(first[.pdf], second[.pdf])
    }

    /// Runs only as the child of the two-process test, which names an output folder.
    func testChildRenderWritesFigures() throws {
        guard let folder = ProcessInfo.processInfo.environment[Self.childOutputKey] else {
            throw XCTSkip("runs only as the child of testSameSceneGivesSameBytesInTwoProcesses")
        }
        for (format, data) in try Self.renderAll() {
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("figure.\(format.fileExtension)"))
        }
    }

    func testSameSceneGivesSameBytesInTwoProcesses() async throws {
        let xctest = try XCTUnwrap(Bundle.main.executableURL)
        let bundle = Bundle(for: Self.self).bundleURL
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-figure-two-process-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var children: [[ViewerFigureFormat: Data]] = []
        for name in ["first", "second"] {
            if !children.isEmpty {
                try await Task.sleep(for: .milliseconds(1100))  // a second apart, so the PDF clock moves
            }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var environment = ProcessInfo.processInfo.environment
            environment[Self.childOutputKey] = folder.path
            let spec = ToolProcessSpec(
                executableURL: xctest,
                arguments: ["-XCTest", "LungfishWorkflowTests.ViewerFigureRasterizerDeterminismTests/testChildRenderWritesFigures", bundle.path],
                environment: environment, timeout: .seconds(120), label: "viewer figure child render"
            )
            let result = try await ToolProcess.run(spec)
            XCTAssertTrue(result.isSuccess, "child \(name) failed: \(result.stderrWholeLines)")
            var files: [ViewerFigureFormat: Data] = [:]
            for format in ViewerFigureFormat.allCases {
                files[format] = try Data(contentsOf: folder.appendingPathComponent("figure.\(format.fileExtension)"))
            }
            children.append(files)
        }
        try assertSameBytes(children[0], children[1], "two processes")
        try assertSameBytes(children[0], try Self.renderAll(), "child against this process")
        let firstDates = Support.pdfVolatileRanges(try XCTUnwrap(children[0][.pdf]))
        XCTAssertEqual(firstDates.map(\.count), [1, 1, 1], "each volatile PDF value is written once")
    }
}

final class ViewerFigureMetadataTests: XCTestCase {
    private let scene = ViewerFigureTestSupport.sampleScene()

    func testBitmapsCarryNoTimeSoftwareOrHost() throws {
        for format in [ViewerFigureFormat.png, .jpeg, .tiff] {
            let properties = try Support.imageProperties(try ViewerFigureRasterizer.render(scene, format: format))
            let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
            let exif = properties["{Exif}"] as? [String: Any] ?? [:]
            let png = properties["{PNG}"] as? [String: Any] ?? [:]
            for (dictionary, keys) in [
                (tiff, ["DateTime", "Software", "HostComputer", "Artist"]),
                (exif, ["DateTimeOriginal", "DateTimeDigitized", "SubsecTime"]),
                (png, ["CreationTime", "ModificationTime", "Software", "Comment"]),
            ] {
                XCTAssertEqual(Set(dictionary.keys).intersection(keys), [], format.rawValue)
            }
            XCTAssertEqual(properties["DPIWidth"] as? Double, 144, format.rawValue)
            XCTAssertEqual(properties["ProfileName"] as? String, "sRGB IEC61966-2.1", format.rawValue)
        }
        let tiff = try Support.imageProperties(try ViewerFigureRasterizer.render(scene, format: .tiff))["{TIFF}"] as? [String: Any]
        XCTAssertEqual(tiff?["Compression"] as? Int, 5, "the explicit dictionary asks for LZW")
    }

    func testPNGHoldsNoTimeOrTextChunk() throws {
        let chunks = Support.pngChunkTypes(try ViewerFigureRasterizer.render(scene, format: .png))
        XCTAssertEqual(chunks.first, "IHDR")
        XCTAssertEqual(chunks.last, "IEND")
        XCTAssertEqual(Set(chunks).intersection(["tIME", "tEXt", "iTXt", "zTXt"]), [], "\(chunks)")
        // ImageIO writes an eXIf chunk with ColorSpace and the pixel size only, and
        // testBitmapsCarryNoTimeSoftwareOrHost checks that it holds no time.
    }

    func testPDFWritesExactlyTheThreeMeasuredVolatileValues() throws {
        let pdf = try ViewerFigureRasterizer.render(scene, format: .pdf)
        XCTAssertEqual(Support.pdfVolatileRanges(pdf).map(\.count), [1, 1, 1])
        let text = try XCTUnwrap(String(data: pdf, encoding: .isoLatin1))
        XCTAssertNotNil(text.range(of: "/Creator (\(ViewerFigureRasterizer.pdfCreator))"))
        XCTAssertNotNil(text.range(of: "/Producer ("), "the Producer names the macOS build, constant on one host")
    }
}
