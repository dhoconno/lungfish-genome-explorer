// ViewerFigureRasterizerTests.swift - Drawing, determinism and metadata of figure files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, ruling sections 2.2, 2.5 and 6 of ARCH-B10-graphics). C against C' is
// byte for byte on one host and build, and every format is compared whole. The PDF context
// writes /CreationDate, /ModDate and a trailer /ID from the clock and a random source (lane
// 13.28 measure), and the rasterizer blanks the dates and derives the /ID from the content, so
// no mask is needed (QA ruling QA-GFX-mask). A pin shows that the context still writes them.

import CoreGraphics
import XCTest
import LungfishCore
import LungfishTestSupport
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

    func testFractionalSizeLeavesNoTransparentEdge() throws {
        // The pixel grid rounds 10.5 points up to 11 pixels, so the last column and row lie
        // half outside the scene. The background must still cover them whole.
        let scene = ViewerFigureScene(
            width: 10.5, height: 10.5, appearance: .light, background: ViewerFigurePaint(.windowBackground),
            frame: nil, fonts: [], items: []
        )
        let image = try Support.image(try ViewerFigureRasterizer.render(scene, format: .png, pixelScale: 1))
        XCTAssertEqual(image.width, 11)
        XCTAssertEqual(image.height, 11)
        for (x, y) in [(10, 5), (5, 10), (10, 10)] {
            XCTAssertEqual(try Support.pixel(image, x: x, y: y)[3], 255, "alpha at \(x), \(y)")
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

    func testRefusesAFigureTooLargeToCount() {
        // A finite size whose pixel count does not fit an Int must throw and never trap.
        let scene = ViewerFigureScene(
            width: 1e300, height: 10, appearance: .light, background: ViewerFigurePaint(.windowBackground),
            frame: nil, fonts: [], items: []
        )
        for format in [ViewerFigureFormat.png, .jpeg, .tiff] {
            XCTAssertThrowsError(try ViewerFigureRasterizer.render(scene, format: format)) { error in
                XCTAssertEqual(
                    error as? ViewerFigureRasterizerError, .invalidSize(width: 1e300, height: 10, pixelScale: 2),
                    format.rawValue
                )
            }
        }
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
            XCTAssertEqual(one, two, "\(what) \(format.rawValue)")
        }
    }

    func testSameSceneGivesSameBytesTwiceInOneProcess() throws {
        let first = try Self.renderAll()
        let second = try Self.renderAll()
        try assertSameBytes(first, second, "one process")
    }

    /// The pin of the measured fact (QA 1). If a macOS update stops writing the three values,
    /// this fails and the normalizer can go.
    func testThePDFContextStillWritesTheThreeValues() throws {
        let one = try ViewerFigureRasterizer.pdfAsWritten(Support.sampleScene())
        let two = try ViewerFigureRasterizer.pdfAsWritten(Support.sampleScene())
        XCTAssertNotEqual(one, two, "the context writes a new /ID on every render")
        XCTAssertEqual(one.count, two.count)
        let ranges = ViewerFigurePDFNormalizer.volatileRanges(one)
        XCTAssertEqual(ranges.map(\.count), [1, 1, 1], "each value is written once")
        let volatile = Set(ranges.joined().flatMap { Array($0) })
        let stray = Set(Support.differingOffsets(one, two)).subtracting(volatile)
        XCTAssertTrue(stray.isEmpty, "the PDFs differ outside the three values at \(stray.sorted().prefix(8))")
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
        let root = try TestTempDirectory.make(prefix: "viewer-figure-two-process")
        defer { TestTempDirectory.cleanup(root) }
        var children: [[ViewerFigureFormat: Data]] = []
        for name in ["first", "second"] {
            if !children.isEmpty {
                try await Task.sleep(for: .milliseconds(1100))  // a second apart, so the PDF clock moves
            }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var environment = ProcessInfo.processInfo.environment
            environment[Self.childOutputKey] = folder.path
            // 120 s and not 30 s, since each child loads the whole test bundle. The wait ends when the child exits.
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
        let firstPDF = try XCTUnwrap(children[0][.pdf])
        XCTAssertEqual(ViewerFigurePDFNormalizer.volatileRanges(firstPDF).map(\.count), [0, 0, 1], "no date, one derived /ID")
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

    func testAFigurePDFHoldsNoDateAndADerivedID() throws {
        let rendering = try ViewerFigureRasterizer.renderReporting(scene, format: .pdf)
        XCTAssertNil(rendering.pdfKeptAsWritten)
        let pdf = rendering.data
        XCTAssertEqual(ViewerFigurePDFNormalizer.volatileRanges(pdf).map(\.count), [0, 0, 1])
        let text = try XCTUnwrap(String(data: pdf, encoding: .isoLatin1))
        XCTAssertNil(text.range(of: "/CreationDate"))
        XCTAssertNil(text.range(of: "/ModDate"))
        let derived = Support.derivedPDFID(pdf)
        XCTAssertEqual(derived.count, 32)
        XCTAssertEqual(Support.pdfIDStrings(pdf), [derived, derived], "both /ID strings come from the content")
        XCTAssertNotNil(text.range(of: "/Creator (\(ViewerFigureRasterizer.pdfCreator))"))
        XCTAssertNotNil(text.range(of: "/Producer ("), "the Producer names the macOS build, constant on one host")
    }
}
