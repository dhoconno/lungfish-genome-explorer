// ViewerFigureTestSupport.swift - A fixed figure scene and byte helpers for the renderer tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import LungfishWorkflow

enum ViewerFigureTestSupport {
    /// A small fixed scene that uses every item kind, two text anchors and a translucent paint.
    static func sampleScene(appearance: ViewerFigureAppearance = .light) -> ViewerFigureScene {
        let frame = ViewerFigureFrame(chromosome: "MN908947.3", start: 21562, end: 21662, pixelWidth: 120)
        let label = ViewerFigurePaint(.label)
        return ViewerFigureScene(
            width: 120, height: 40, appearance: appearance, background: ViewerFigurePaint(.windowBackground),
            frame: frame,
            fonts: [ViewerFigureFontResolution(requested: "Menlo-Regular", resolved: "Menlo-Regular", size: 9)],
            items: [
                .fill(rect: ViewerFigureRect(x: 0, y: 0, width: 10, height: 10), paint: ViewerFigurePaint(.baseA)),
                .fill(rect: ViewerFigureRect(x: 10, y: 0, width: 10, height: 10), paint: ViewerFigurePaint(.baseT)),
                .strokeRect(rect: ViewerFigureRect(x: 24.5, y: 2.5, width: 20, height: 6), lineWidth: 1, paint: label),
                .strokeSegments(
                    segments: [
                        ViewerFigureSegment(from: ViewerFigurePoint(x: 0, y: 20.5), to: ViewerFigurePoint(x: 120, y: 20.5)),
                        ViewerFigureSegment(from: ViewerFigurePoint(x: 60.5, y: 14), to: ViewerFigurePoint(x: 60.5, y: 20)),
                    ],
                    lineWidth: 1, paint: ViewerFigurePaint(.tertiaryLabel, alpha: 0.6)
                ),
                .text(ViewerFigureText(
                    string: "21,612", fontName: "Menlo-Regular", fontSize: 9,
                    point: ViewerFigurePoint(x: 60.5, y: 32), anchor: .baselineCenter, paint: label
                )),
                .text(ViewerFigureText(
                    string: "ACGT", fontName: "Menlo-Regular", fontSize: 9,
                    point: ViewerFigurePoint(x: 118, y: 12), anchor: .baselineEnd, paint: ViewerFigurePaint(.secondaryLabel)
                )),
            ]
        )
    }

    /// The byte ranges of the two hex strings of every trailer /ID, in file order.
    static func pdfIDDigitRanges(_ data: Data) -> [Range<Int>] {
        // Latin-1 maps each byte to one UTF-16 unit, so string offsets are byte offsets.
        let text = (String(data: data, encoding: .isoLatin1) ?? "") as NSString
        let expression = try! NSRegularExpression(pattern: ViewerFigurePDFNormalizer.idPattern)
        return expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).flatMap { match in
            [match.range(at: 1), match.range(at: 2)].map { $0.location ..< $0.location + $0.length }
        }
    }

    /// The hex strings of every trailer /ID, in file order.
    static func pdfIDStrings(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        return pdfIDDigitRanges(data).map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    /// The /ID the rasterizer should write, the first 32 hex digits of the SHA-256 of the bytes
    /// with every /ID digit set to 0 (QA ruling QA-GFX-mask, QM-2 item d), worked out here with
    /// CryptoKit and not with the normalizer's own code.
    static func derivedPDFID(_ data: Data) -> String {
        var bytes = [UInt8](data)
        for range in pdfIDDigitRanges(data) {
            for index in range {
                bytes[index] = UInt8(ascii: "0")
            }
        }
        return String(SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The offsets at which two equal-length byte strings differ.
    static func differingOffsets(_ first: Data, _ second: Data) -> [Int] {
        zip(first.indices, zip(first, second)).compactMap { index, pair in pair.0 == pair.1 ? nil : index - first.startIndex }
    }

    /// The image and container properties ImageIO reads back from a bitmap.
    static func imageProperties(_ data: Data) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    static func image(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The 8-bit sRGB RGBA value of one pixel, counted from the top left.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes
    }

    /// The chunk types of a PNG in file order.
    static func pngChunkTypes(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var types: [String] = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self))
            offset += 12 + length
        }
        return types
    }
}
