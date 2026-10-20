// TrackRendererPixelPinTests.swift - Pins the pixels of the read and variant track renderers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
import LungfishWorkflow

/// Pins what each public draw function of `ReadTrackRenderer` and `VariantTrackRenderer` puts
/// outside its text, under the light and the dark appearance, and the rows `packReads` gives a
/// fixed read set that passes the 75-row cap (lane 13.29, M1). The renderers move into
/// LungfishWorkflow and take a `ViewerFigureTheme` in M2, and these values must not move.
///
/// Each case samples a grid every 8 points from (3, 3), skipping the rectangles that hold text,
/// and stores each sample as `RRGGBBAA` in `TrackRendererPixelPinTable`. A sample may differ by
/// 2 in a channel, the rounding of a theme value to four places. Set
/// `LUNGFISH_RECORD_RENDER_PINS=1` to print the table instead of checking it.
@MainActor
final class TrackRendererPixelPinTests: XCTestCase {

    private struct PinCase {
        let name: String
        let width: Int
        let height: Int
        let textRects: [CGRect]
        let draw: @MainActor (CGContext, ViewerFigureTheme) -> Void
    }

    private static let tolerance = 2
    private var recording: Bool { ProcessInfo.processInfo.environment["LUNGFISH_RECORD_RENDER_PINS"] == "1" }

    // MARK: - Fixtures

    private static func read(
        _ name: String, flag: UInt16 = 0, at position: Int, cigar: [(CIGAROperation.Op, Int)], sequence: String? = nil
    ) -> AlignedRead {
        let ops = cigar.map { CIGAROperation(op: $0.0, length: $0.1) }
        let queryLength = ops.filter { [.match, .insertion, .softClip, .seqMatch, .seqMismatch].contains($0.op) }
            .reduce(0) { $0 + $1.length }
        let seq = sequence ?? String(repeating: "A", count: queryLength)
        return AlignedRead(
            name: name, flag: flag, chromosome: "chr1", position: position, mapq: 60, cigar: ops,
            sequence: seq, qualities: Array(repeating: 30, count: seq.count)
        )
    }

    private static func frame(end: Double, width: Int, leadingInset: CGFloat = 0) -> ReferenceFrame {
        let frame = ReferenceFrame(chromosome: "chr1", start: 0, end: end, pixelWidth: width)
        frame.leadingInset = leadingInset
        return frame
    }

    private static func variant(_ name: String, _ start: Int, _ end: Int, _ type: String) -> SequenceAnnotation {
        SequenceAnnotation(
            type: .gene, name: name, chromosome: "chr1", start: start, end: end, strand: .unknown,
            qualifiers: ["variant_type": AnnotationQualifier(type)]
        )
    }

    private var cases: [PinCase] {
        let coverageReads = [
            Self.read("f1", at: 10, cigar: [(.match, 100)]),
            Self.read("f2", at: 50, cigar: [(.match, 100)]),
            Self.read("r1", flag: 16, at: 80, cigar: [(.match, 100)]),
        ]
        let depth = (0..<200).map { ReadTrackRenderer.CoveragePoint(position: $0, depth: 5 + ($0 % 40)) }
        var mismatched = Array(repeating: Character("A"), count: 100)
        mismatched[50] = "C"
        let packed: [(row: Int, read: AlignedRead)] = [
            (0, Self.read("p1", at: 10, cigar: [(.match, 100)], sequence: String(mismatched))),
            (1, Self.read("p2", flag: 16, at: 60, cigar: [(.match, 40), (.deletion, 10), (.match, 50)])),
            (0, Self.read("p3", at: 150, cigar: [(.softClip, 10), (.match, 90)])),
            (1, Self.read("p4", at: 200, cigar: [(.match, 30), (.insertion, 5), (.match, 65)])),
        ]
        let reference = "ACGTACGTACGTACGTACGT"
        var baseRead = Array(reference)
        baseRead[5] = "T"
        let bases: [(row: Int, read: AlignedRead)] = [
            (0, Self.read("b1", at: 0, cigar: [(.match, 20)], sequence: String(baseRead))),
            (1, Self.read("b2", flag: 16, at: 2, cigar: [(.match, 18)], sequence: String(reference.dropFirst(2)))),
        ]
        let variants = [Self.variant("v1", 80, 81, "SNP"), Self.variant("v2", 100, 110, "DEL"), Self.variant("v3", 150, 151, "INS")]
        let sites = [
            VariantSite(position: 100, ref: "A", alt: "G", variantType: "SNP",
                        genotypes: ["S1": .homRef, "S2": .het, "S3": .homAlt, "S4": .noCall]),
            VariantSite(position: 150, ref: "AT", alt: "A", variantType: "DEL",
                        genotypes: ["S1": .het, "S2": .noCall, "S3": .homRef, "S4": .homAlt]),
        ]
        let genotypes = GenotypeDisplayData(
            sampleNames: ["S1", "S2", "S3", "S4"], sites: sites,
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 200)
        )
        var state = SampleDisplayState(showGenotypeRows: true, rowHeight: 12)
        state.sampleGutterWidthOverride = 60
        let genotypeState = state

        return [
            PinCase(name: "coverage-reads", width: 200, height: 60, textRects: [CGRect(x: 120, y: 0, width: 80, height: 16)]) { context, figureTheme in
                ReadTrackRenderer.drawCoverage(
                    reads: coverageReads, frame: Self.frame(end: 200, width: 200).figureFrame, context: context, figureTheme: figureTheme,
                    rect: CGRect(x: 0, y: 0, width: 200, height: 60)
                )
            },
            PinCase(name: "coverage-depth", width: 200, height: 60, textRects: [CGRect(x: 16, y: 0, width: 184, height: 16)]) { context, figureTheme in
                ReadTrackRenderer.drawCoverage(
                    depthPoints: depth, regionStart: 0, regionEnd: 200, frame: Self.frame(end: 200, width: 200).figureFrame,
                    context: context, figureTheme: figureTheme, rect: CGRect(x: 0, y: 0, width: 200, height: 60)
                )
            },
            PinCase(name: "packed-reads", width: 200, height: 60, textRects: [CGRect(x: 30, y: 44, width: 140, height: 16)]) { context, figureTheme in
                ReadTrackRenderer.drawPackedReads(
                    packedReads: packed, overflow: 5, frame: Self.frame(end: 400, width: 200).figureFrame,
                    referenceSequence: String(repeating: "A", count: 400), referenceStart: 0, maxRowsLimit: 75,
                    maskedPositions: [300, 301], context: context, figureTheme: figureTheme, rect: CGRect(x: 0, y: 0, width: 200, height: 60)
                )
            },
            PinCase(name: "base-reads", width: 200, height: 50, textRects: [CGRect(x: 20, y: 34, width: 160, height: 16)]) { context, figureTheme in
                ReadTrackRenderer.drawBaseReads(
                    packedReads: bases, overflow: 2, frame: Self.frame(end: 20, width: 200).figureFrame,
                    referenceSequence: reference, referenceStart: 0, maxRowsLimit: 75, context: context, figureTheme: figureTheme,
                    rect: CGRect(x: 0, y: 0, width: 200, height: 50)
                )
            },
            PinCase(name: "variant-summary", width: 200, height: 24, textRects: [CGRect(x: 0, y: 0, width: 60, height: 20)]) { context, figureTheme in
                VariantTrackRenderer.drawSummaryBar(
                    variants: variants, frame: Self.frame(end: 200, width: 200).figureFrame, context: context, figureTheme: figureTheme, yOffset: 0
                )
            },
            PinCase(name: "variant-genotypes", width: 260, height: 40, textRects: [CGRect(x: 1, y: 0, width: 58, height: 40)]) { context, figureTheme in
                VariantTrackRenderer.drawGenotypeRows(
                    genotypeData: genotypes, frame: Self.frame(end: 200, width: 260, leadingInset: 72).figureFrame,
                    context: context, figureTheme: figureTheme, yOffset: 0, state: genotypeState, availableHeight: 36
                )
            },
        ]
    }

    // MARK: - Drawing and sampling

    /// Draws into an sRGB bitmap whose origin is the top left, as in the live flipped view, with
    /// the named appearance current, and returns the grid samples outside the text rectangles.
    private func samples(_ pin: PinCase, appearance: NSAppearance.Name) -> String {
        let bytesPerRow = pin.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pin.height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: pin.width, height: pin.height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(pin.height))
            context.scaleBy(x: 1, y: -1)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { pin.draw(context, .resolved(for: NSAppearance(named: appearance)!)) }
            NSGraphicsContext.current = previous
        }
        var hex = ""
        for y in stride(from: 3, to: pin.height, by: 8) {
            for x in stride(from: 3, to: pin.width, by: 8)
            where !pin.textRects.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
                let offset = y * bytesPerRow + x * 4
                hex += bytes[offset..<offset + 4].map { String(format: "%02X", $0) }.joined()
            }
        }
        return hex
    }

    private static func channels(_ hex: String) -> [Int] {
        var values: [Int] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            values.append(Int(hex[index..<next], radix: 16) ?? -1)
            index = next
        }
        return values
    }

    func testEachDrawFunctionKeepsItsPixelsOutsideTextInBothAppearances() {
        for pin in cases {
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let key = "\(pin.name)-\(label)"
                let got = samples(pin, appearance: appearance)
                if recording {
                    print("RENDERPIN \(key) \(got)")
                    continue
                }
                guard let expected = TrackRendererPixelPinTable.samples[key] else {
                    XCTFail("no pinned samples for \(key)")
                    continue
                }
                let (a, b) = (Self.channels(got), Self.channels(expected))
                XCTAssertEqual(a.count, b.count, "\(key) sample count")
                let differing = zip(a, b).enumerated().filter { abs($0.element.0 - $0.element.1) > Self.tolerance }
                XCTAssertTrue(differing.isEmpty, "\(key): \(differing.count) channels differ, first at sample \(differing.first.map { $0.offset / 4 } ?? -1)")
            }
        }
    }

    func testPackReadsKeepsItsRowsAndOverflowPastTheRowCap() {
        let stacked = (0..<80).map { Self.read(String(format: "s%02d", $0), flag: $0 % 2 == 0 ? 0 : 16, at: 100 + $0 % 3, cigar: [(.match, 50)]) }
        let reads = [Self.read("a", at: 0, cigar: [(.match, 50)])] + stacked + [Self.read("b", at: 170, cigar: [(.match, 30)])]
        let result = ReadTrackRenderer.packReads(reads, frame: Self.frame(end: 400, width: 400).figureFrame, maxRows: 75)
        let rows = result.packed.map { "\($0.read.name):\($0.row)" }.joined(separator: " ")
        if recording {
            print("PACKPIN overflow=\(result.overflow) \(rows)")
            return
        }
        XCTAssertEqual(ReadTrackRenderer.maxReadRows, 75)
        XCTAssertEqual(result.overflow, TrackRendererPixelPinTable.packOverflow)
        XCTAssertEqual(rows, TrackRendererPixelPinTable.packRows)
    }
}
