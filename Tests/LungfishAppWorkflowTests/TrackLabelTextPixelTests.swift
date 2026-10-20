// TrackLabelTextPixelTests.swift - Text pixels of the track labels, AppKit against CoreText
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import LungfishApp
import LungfishWorkflow

/// Draws each label the read and variant renderers draw, once as AppKit drew it before lane
/// 13.29 and once through `ViewerFigureTrackText`, in both appearances at 2x, and measures the
/// pixels that differ. The ink box of each label stays within one point of AppKit's. When
/// `LUNGFISH_TEXT_PIXEL_DIR` names a folder, both images of each case are written there.
@MainActor
final class TrackLabelTextPixelTests: XCTestCase {
    private enum Place {
        case at(CGPoint)
        case rightOf(maxX: CGFloat, y: CGFloat)
        case centred(CGRect)
        case leftCentred(x: CGFloat, rect: CGRect)
        case truncated(CGRect)
    }

    private struct LabelCase {
        let name: String
        let text: String
        let appKitFont: NSFont
        let face: ViewerFigureTrackText.Face
        let appKitColor: NSColor
        let role: ViewerFigureColorRole
        let place: Place
    }

    private static let width = 240
    private static let height = 24
    private static let scale: CGFloat = 2

    private var cases: [LabelCase] {
        let insertion = NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1)
        return [
            LabelCase(name: "coverage-max", text: "max: 128x", appKitFont: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                      face: .monospacedDigitSystem, appKitColor: .secondaryLabelColor, role: .secondaryLabel,
                      place: .rightOf(maxX: 240, y: 2)),
            LabelCase(name: "depth-legend", text: "Depth (log)", appKitFont: .systemFont(ofSize: 9, weight: .regular),
                      face: .system, appKitColor: .secondaryLabelColor, role: .secondaryLabel, place: .at(CGPoint(x: 18, y: 3))),
            LabelCase(name: "depth-summary", text: "max: 44x  mean: 24.5x", appKitFont: .systemFont(ofSize: 9, weight: .regular),
                      face: .system, appKitColor: .secondaryLabelColor, role: .secondaryLabel, place: .rightOf(maxX: 240, y: 2)),
            LabelCase(name: "depth-covered", text: "100% covered", appKitFont: .systemFont(ofSize: 9, weight: .regular),
                      face: .system, appKitColor: .secondaryLabelColor, role: .secondaryLabel, place: .at(CGPoint(x: 70, y: 3))),
            LabelCase(name: "insertion", text: "+ACGTAC...(12)", appKitFont: .monospacedSystemFont(ofSize: 7, weight: .semibold),
                      face: .monospacedSemibold, appKitColor: insertion, role: .insertion, place: .at(CGPoint(x: 10, y: 0.5))),
            LabelCase(name: "overflow", text: "+5 reads not shown (max 75 rows)", appKitFont: .systemFont(ofSize: 9),
                      face: .system, appKitColor: .labelColor, role: .label, place: .centred(CGRect(x: 0, y: 4, width: 240, height: 16))),
            LabelCase(name: "variant-summary", text: "3 variants", appKitFont: .systemFont(ofSize: 8, weight: .medium),
                      face: .systemMedium, appKitColor: .secondaryLabelColor, role: .secondaryLabel,
                      place: .leftCentred(x: 4, rect: CGRect(x: 0, y: 2, width: 240, height: 20))),
            LabelCase(name: "sample-name", text: "Sample-with-a-long-name-0001", appKitFont: .systemFont(ofSize: 10),
                      face: .system, appKitColor: .labelColor, role: .label, place: .truncated(CGRect(x: 4, y: 3, width: 60, height: 10))),
        ]
    }

    private func drawAppKit(_ label: LabelCase) {
        let attributes: [NSAttributedString.Key: Any] = [.font: label.appKitFont, .foregroundColor: label.appKitColor]
        let text = label.text as NSString
        let size = text.size(withAttributes: attributes)
        switch label.place {
        case .at(let point): text.draw(at: point, withAttributes: attributes)
        case .rightOf(let maxX, let y): text.draw(at: CGPoint(x: maxX - size.width - 4, y: y), withAttributes: attributes)
        case .centred(let rect):
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
        case .leftCentred(let x, let rect):
            text.draw(at: CGPoint(x: x, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
        case .truncated(let rect):
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var truncating = attributes
            truncating[.paragraphStyle] = style
            text.draw(in: rect, withAttributes: truncating)
        }
    }

    private func drawCoreText(_ label: LabelCase, theme: ViewerFigureTheme, in context: CGContext) {
        let font = ViewerFigureTrackText.font(label.face, size: Double(label.appKitFont.pointSize))
        let color = theme.color(label.role).cgColor
        let width = CGFloat(ViewerFigureTrackText.width(label.text, font: font))
        let height = CGFloat(ViewerFigureTrackText.boxHeight(font))
        let topLeft: CGPoint
        switch label.place {
        case .at(let point): topLeft = point
        case .rightOf(let maxX, let y): topLeft = CGPoint(x: maxX - width - 4, y: y)
        case .centred(let rect): topLeft = CGPoint(x: rect.midX - width / 2, y: rect.minY + (rect.height - height) / 2)
        case .leftCentred(let x, let rect): topLeft = CGPoint(x: x, y: rect.minY + (rect.height - height) / 2)
        case .truncated(let rect):
            ViewerFigureTrackText.drawTruncatingTail(label.text, font: font, color: color, in: rect, context: context)
            return
        }
        ViewerFigureTrackText.draw(label.text, font: font, color: color, topLeft: topLeft, in: context)
    }

    /// Renders into a 2x sRGB bitmap with a top-left origin, as the live flipped view draws.
    private func render(_ draw: (CGContext) -> Void) -> (bytes: [UInt8], image: CGImage?) {
        let width = Int(CGFloat(Self.width) * Self.scale)
        let height = Int(CGFloat(Self.height) * Self.scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var image: CGImage?
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: Self.scale, y: -Self.scale)
            draw(context)
            image = context.makeImage()
        }
        return (bytes, image)
    }

    /// The box of the pixels with ink, in pixels, as minX, minY, maxX, maxY.
    private static func inkBox(_ bytes: [UInt8]) -> [Int]? {
        let width = Int(CGFloat(Self.width) * Self.scale)
        var box: [Int]?
        for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] > 16 {
            let pixel = index / 4
            let (x, y) = (pixel % width, pixel / width)
            box = box.map { [min($0[0], x), min($0[1], y), max($0[2], x), max($0[3], y)] } ?? [x, y, x, y]
        }
        return box
    }

    private static func write(_ image: CGImage?, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["LUNGFISH_TEXT_PIXEL_DIR"], let image else { return }
        let directory = URL(fileURLWithPath: folder, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    func testEachLabelKeepsItsInkBoxWithinOnePointOfAppKit() throws {
        for label in cases {
            for (appearanceLabel, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let old = render { context in
                    let previous = NSGraphicsContext.current
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    appearance.performAsCurrentDrawingAppearance { drawAppKit(label) }
                    NSGraphicsContext.current = previous
                }
                let new = render { context in drawCoreText(label, theme: .resolved(for: appearance), in: context) }
                let key = "\(label.name)-\(appearanceLabel)"
                Self.write(old.image, name: "\(key)-appkit")
                Self.write(new.image, name: "\(key)-coretext")
                var differing = 0
                var maxDelta = 0
                for pixel in stride(from: 0, to: old.bytes.count, by: 4) {
                    let delta = (0..<4).map { abs(Int(old.bytes[pixel + $0]) - Int(new.bytes[pixel + $0])) }.max() ?? 0
                    if delta > 8 { differing += 1 }
                    maxDelta = max(maxDelta, delta)
                }
                let oldBox = try XCTUnwrap(Self.inkBox(old.bytes), "\(key) AppKit drew no ink")
                let newBox = try XCTUnwrap(Self.inkBox(new.bytes), "\(key) CoreText drew no ink")
                let shift = zip(oldBox, newBox).map { $1 - $0 }
                print("TEXTPIXELS \(key) differing=\(differing) maxDelta=\(maxDelta) appkitInk=\(oldBox) coretextInk=\(newBox) shift=\(shift)")
                guard case .truncated(let rect) = label.place else {
                    XCTAssertTrue(shift.allSatisfy { abs($0) <= Int(Self.scale) }, "\(key) ink box moved \(shift) pixels at 2x")
                    continue
                }
                // CoreText cuts a long name at a different glyph than AppKit's truncating tail, so
                // only the left, top and bottom of the ink keep their place. The right edge is a
                // measured difference (lane 13.29 c3 report) and stays inside the label's rectangle.
                XCTAssertTrue([shift[0], shift[1], shift[3]].allSatisfy { abs($0) <= Int(Self.scale) }, "\(key) ink box moved \(shift)")
                XCTAssertLessThanOrEqual(CGFloat(newBox[2]), rect.maxX * Self.scale, "\(key) ink leaves its rectangle")
            }
        }
    }
}
