// TranslationTrackRendererTests.swift - Tests for CDS translation track rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class TranslationTrackRendererTests: XCTestCase {

    // MARK: - Helpers

    private func makeFrame(start: Double = 0, end: Double = 1000, pixelWidth: Int = 800) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: start, end: end, pixelWidth: pixelWidth)
    }

    private func makeBitmapContext(width: Int = 800, height: Int = 100) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
    }

    /// R3-R3H-8: drawCDSTranslation must not crash when a CDS translation
    /// yields zero amino acids. TranslationEngine.translateCDS returns a
    /// non-nil TranslationResult as soon as at least one exon interval
    /// yields non-empty sequence text, without checking the concatenated
    /// coding sequence is at least 3bp long -- a CDS annotation clipped at
    /// a chromosome boundary, or a malformed/truncated CDS from a GFF3 or
    /// GenBank import, can produce a coding sequence under 3bp, leaving
    /// aminoAcidPositions empty while the result is still non-nil.
    /// Previously `drawIntronConnectors`'s `for i in 1..<positions.count`
    /// trapped with "Range requires lowerBound <= upperBound" whenever
    /// positions.count == 0 (1..<0 is an invalid Range).
    func testDrawCDSTranslationDoesNotCrashWhenAminoAcidPositionsIsEmpty() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()

        // Coding sequence under 3bp: translateCDS/translateFrames' while
        // loop runs zero times, so aminoAcidPositions is empty, but the
        // result itself is still non-nil (mirrors what
        // TranslationEngine.translateCDS returns for a clipped/truncated CDS).
        let emptyResult = TranslationResult(
            protein: "",
            codingSequence: "AT",
            aminoAcidPositions: [],
            codonTable: .standard,
            phaseOffset: 0
        )

        // Must not trap. If this test crashes the process, the fix has
        // regressed.
        TranslationTrackRenderer.drawCDSTranslation(
            result: emptyResult,
            frame: frame,
            context: ctx,
            yOffset: 0
        )
    }

    /// Sanity check that the fix doesn't disturb normal (non-empty)
    /// rendering: a single amino acid still draws without crashing and
    /// without drawing any intron connector (nothing to connect with only
    /// one position).
    func testDrawCDSTranslationRendersSingleAminoAcidWithoutCrashing() {
        let frame = makeFrame()
        let ctx = makeBitmapContext()

        let singleAAResult = TranslationResult(
            protein: "M",
            codingSequence: "ATG",
            aminoAcidPositions: [
                AminoAcidPosition(
                    index: 0,
                    aminoAcid: "M",
                    codon: "ATG",
                    genomicRanges: [GenomicRange(start: 100, end: 103)],
                    isStart: true,
                    isStop: false
                )
            ],
            codonTable: .standard,
            phaseOffset: 0
        )

        TranslationTrackRenderer.drawCDSTranslation(
            result: singleAAResult,
            frame: frame,
            context: ctx,
            yOffset: 0
        )
    }

    /// Amino acid letters are SF Mono Medium sized to the track. Looking that font up per draw
    /// could return nil under load, and CoreText raised on the nil font, so the renderer keeps
    /// the face instead.
    func testAminoAcidLettersDrawWithoutLookingSFMonoMediumUp() throws {
        let frame = makeFrame(start: 0, end: 60, pixelWidth: 600)
        let result = TranslationResult(
            protein: "MK",
            codingSequence: "ATGAAA",
            aminoAcidPositions: [
                AminoAcidPosition(
                    index: 0, aminoAcid: "M", codon: "ATG",
                    genomicRanges: [GenomicRange(start: 9, end: 12)], isStart: true, isStop: false
                ),
                AminoAcidPosition(
                    index: 1, aminoAcid: "K", codon: "AAA",
                    genomicRanges: [GenomicRange(start: 12, end: 15)], isStart: false, isStop: false
                ),
            ],
            codonTable: .standard,
            phaseOffset: 0
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 100, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let lookups = monospacedSystemFontLookups(weight: .medium) {
            TranslationTrackRenderer.drawCDSTranslation(
                result: result, frame: frame, context: graphics.cgContext, yOffset: 0
            )
            TranslationTrackRenderer.drawFrameTranslations(
                frames: [.plus1, .minus1],
                sequence: String(repeating: "ATGAAACCC", count: 6) + "TAA",
                sequenceStart: 0,
                frame: frame,
                context: graphics.cgContext,
                yOffset: 20
            )
        }
        XCTAssertEqual(lookups, [], "amino acid letters looked SF Mono Medium up while drawing")
    }
}
