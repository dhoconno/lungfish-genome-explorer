// TranslationTrackRenderer.swift - Amino acid translation track rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

// MARK: - Translation Track Renderer

/// Static rendering methods for amino acid translation tracks below the nucleotide sequence.
///
/// Two modes:
/// - **CDS translation**: renders a pre-computed `TranslationResult` aligned to genomic coordinates
/// - **Frame translation**: translates the visible sequence on-the-fly in 1–6 reading frames
@MainActor
enum TranslationTrackRenderer {

    /// Height of a single translation sub-track in points.
    static let subTrackHeight: CGFloat = 16

    /// Vertical padding between sub-tracks.
    static let subTrackSpacing: CGFloat = 1

    // MARK: - CDS Translation

    /// Draws a CDS translation result aligned to the genomic coordinate system.
    ///
    /// Each amino acid is rendered as a colored rectangle spanning its codon's genomic position.
    /// At high zoom (>= 8 px/base), single-letter amino acid codes are drawn centered.
    /// Intron-spanning codons are drawn as two rectangles with a thin connector line.
    /// Start codons get a green top border; stop codons are drawn with a dark background and `*`.
    ///
    /// - Parameters:
    ///   - result: The pre-computed translation result with amino acid positions.
    ///   - frame: The current reference frame for coordinate mapping.
    ///   - context: The Core Graphics context to draw into.
    ///   - yOffset: The Y position for the top of the translation track.
    ///   - trackHeight: Height of the translation track (default: `subTrackHeight`).
    ///   - colorScheme: The amino acid color scheme to use.
    static func drawCDSTranslation(
        result: TranslationResult,
        frame: ReferenceFrame,
        context: CGContext,
        yOffset: CGFloat,
        trackHeight: CGFloat = subTrackHeight,
        colorScheme: AminoAcidColorScheme = .zappo
    ) {
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)
        let pixelsPerBase = CGFloat(frame.pixelWidth) / CGFloat(max(1, frame.end - frame.start))

        // Font for amino acid letters (only used when zoomed in enough)
        let showLetters = pixelsPerBase >= 8
        let font = NSFont.monospacedSystemFont(ofSize: min(11, trackHeight * 0.75), weight: .medium)

        // Draw track background
        let trackRect = CGRect(
            x: 0, y: yOffset,
            width: CGFloat(frame.pixelWidth), height: trackHeight
        )
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor)
        context.fill(trackRect)

        // Draw each amino acid that overlaps the visible window
        for aaPos in result.aminoAcidPositions {
            // Check if any genomic range overlaps the visible window
            let overlaps = aaPos.genomicRanges.contains { range in
                range.start < visibleEnd && range.end > visibleStart
            }
            guard overlaps else { continue }

            // Get color for this amino acid
            let rgb = colorScheme.color(for: aaPos.aminoAcid)
            let fillColor: CGColor
            if aaPos.isStop {
                fillColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 0.9).cgColor
            } else {
                fillColor = NSColor(
                    calibratedRed: CGFloat(rgb.red),
                    green: CGFloat(rgb.green),
                    blue: CGFloat(rgb.blue),
                    alpha: 0.85
                ).cgColor
            }

            if aaPos.genomicRanges.count == 1 {
                // Normal codon: single rectangle
                let range = aaPos.genomicRanges[0]
                let x = frame.screenPosition(for: Double(range.start))
                let endX = frame.screenPosition(for: Double(range.end))
                let width = endX - x
                guard width > 0.1 else { continue }

                let rect = CGRect(x: x, y: yOffset, width: width, height: trackHeight)
                context.setFillColor(fillColor)
                context.fill(rect)

                // Start codon: green top indicator
                if aaPos.isStart {
                    context.setFillColor(NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.2, alpha: 0.9).cgColor)
                    context.fill(CGRect(x: x, y: yOffset, width: width, height: 2))
                }

                // Draw thin vertical separator on the right edge
                if width > 2 {
                    context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
                    context.setLineWidth(0.5)
                    context.move(to: CGPoint(x: endX, y: yOffset))
                    context.addLine(to: CGPoint(x: endX, y: yOffset + trackHeight))
                    context.strokePath()
                }

                // Draw letter if space permits
                if showLetters {
                    drawAminoAcidLetter(
                        aaPos.aminoAcid, in: rect,
                        font: font, context: context
                    )
                }
            } else {
                // Intron-spanning codon: two rectangles with connector
                drawIntronSpanningCodon(
                    aaPos: aaPos, fillColor: fillColor,
                    frame: frame, context: context,
                    yOffset: yOffset, trackHeight: trackHeight,
                    showLetters: showLetters, font: font
                )
            }
        }

        // Draw "Translation" label at left edge
        drawTrackLabel("Translation", yOffset: yOffset, trackHeight: trackHeight, context: context)
    }

    // MARK: - Frame Translation

    /// Draws on-the-fly multi-frame translations of the visible sequence.
    ///
    /// Each reading frame is rendered as a stacked sub-track with a frame label (+1, +2, etc.).
    /// Amino acids are colored using the specified color scheme.
    ///
    /// - Parameters:
    ///   - frames: Which reading frames to translate and display.
    ///   - sequence: The nucleotide sequence for the visible region.
    ///   - sequenceStart: The genomic start position of `sequence`.
    ///   - frame: The current reference frame for coordinate mapping.
    ///   - context: The Core Graphics context to draw into.
    ///   - yOffset: The Y position for the top of the first frame sub-track.
    ///   - table: The codon table to use for translation.
    ///   - colorScheme: The amino acid color scheme to use.
    static func drawFrameTranslations(
        frames: [ReadingFrame],
        sequence: String,
        sequenceStart: Int,
        frame: ReferenceFrame,
        context: CGContext,
        yOffset: CGFloat,
        table: CodonTable = .standard,
        colorScheme: AminoAcidColorScheme = .zappo
    ) {
        let pixelsPerBase = CGFloat(frame.pixelWidth) / CGFloat(max(1, frame.end - frame.start))
        let showLetters = pixelsPerBase >= 8
        let font = NSFont.monospacedSystemFont(ofSize: min(10, subTrackHeight * 0.7), weight: .medium)

        let translations = TranslationEngine.translateFrames(frames, sequence: sequence, table: table)

        for (i, (readingFrame, protein)) in translations.enumerated() {
            let subY = yOffset + CGFloat(i) * (subTrackHeight + subTrackSpacing)

            // Draw sub-track background
            let bgRect = CGRect(
                x: 0, y: subY,
                width: CGFloat(frame.pixelWidth), height: subTrackHeight
            )
            context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.2).cgColor)
            context.fill(bgRect)

            // Calculate the genomic offset for this frame
            let frameOffset = readingFrame.offset
            let isReverse = readingFrame.isReverse
            let workingStart: Int
            if isReverse {
                // For reverse frames, amino acids map from the end of the sequence
                workingStart = sequenceStart
            } else {
                workingStart = sequenceStart + frameOffset
            }

            // Draw each amino acid
            for (aaIndex, aa) in protein.enumerated() {
                let codonGenomicStart: Int
                if isReverse {
                    // Reverse frame: codons map from end backward
                    let seqLen = sequence.count
                    let codonEndInRC = frameOffset + aaIndex * 3 + 3
                    codonGenomicStart = sequenceStart + seqLen - codonEndInRC
                } else {
                    codonGenomicStart = workingStart + aaIndex * 3
                }
                let codonGenomicEnd = codonGenomicStart + 3

                // Skip if outside visible window
                guard codonGenomicEnd > Int(frame.start) && codonGenomicStart < Int(frame.end) else {
                    continue
                }

                let x = frame.screenPosition(for: Double(codonGenomicStart))
                let endX = frame.screenPosition(for: Double(codonGenomicEnd))
                let width = endX - x
                guard width > 0.1 else { continue }

                // Color
                let rgb = colorScheme.color(for: aa)
                let fillColor: CGColor
                if aa == Character("*") {
                    fillColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 0.8).cgColor
                } else {
                    fillColor = NSColor(
                        calibratedRed: CGFloat(rgb.red),
                        green: CGFloat(rgb.green),
                        blue: CGFloat(rgb.blue),
                        alpha: 0.75
                    ).cgColor
                }

                let rect = CGRect(x: x, y: subY, width: width, height: subTrackHeight)
                context.setFillColor(fillColor)
                context.fill(rect)

                // Separator
                if width > 2 {
                    context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.2).cgColor)
                    context.setLineWidth(0.5)
                    context.move(to: CGPoint(x: endX, y: subY))
                    context.addLine(to: CGPoint(x: endX, y: subY + subTrackHeight))
                    context.strokePath()
                }

                // Letter
                if showLetters {
                    drawAminoAcidLetter(aa, in: rect, font: font, context: context)
                }
            }

            // Frame label
            drawTrackLabel(readingFrame.rawValue, yOffset: subY, trackHeight: subTrackHeight, context: context)
        }
    }

    /// Returns the total height needed for a set of frame translation sub-tracks.
    static func totalHeight(for frames: [ReadingFrame]) -> CGFloat {
        guard !frames.isEmpty else { return 0 }
        return CGFloat(frames.count) * subTrackHeight + CGFloat(frames.count - 1) * subTrackSpacing
    }

    /// Returns the total height needed for a CDS translation track.
    static func cdsTrackHeight() -> CGFloat {
        subTrackHeight
    }

    // MARK: - Private Helpers

    /// Draws a single amino acid letter centered in the given rectangle.
    private static func drawAminoAcidLetter(
        _ aminoAcid: Character,
        in rect: CGRect,
        font: NSFont,
        context: CGContext
    ) {
        let str = String(aminoAcid) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = str.size(withAttributes: attributes)
        guard rect.width >= size.width * 0.8 else { return }
        let letterRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        str.draw(in: letterRect, withAttributes: attributes)
    }

    /// Draws an intron-spanning codon as two rectangles with a connector line.
    private static func drawIntronSpanningCodon(
        aaPos: AminoAcidPosition,
        fillColor: CGColor,
        frame: ReferenceFrame,
        context: CGContext,
        yOffset: CGFloat,
        trackHeight: CGFloat,
        showLetters: Bool,
        font: NSFont
    ) {
        let centerY = yOffset + trackHeight / 2

        var drawnRects: [CGRect] = []
        for range in aaPos.genomicRanges {
            let x = frame.screenPosition(for: Double(range.start))
            let endX = frame.screenPosition(for: Double(range.end))
            let width = endX - x
            guard width > 0.1 else { continue }

            let rect = CGRect(x: x, y: yOffset, width: width, height: trackHeight)
            context.setFillColor(fillColor)
            context.fill(rect)
            drawnRects.append(rect)

            // Start codon indicator
            if aaPos.isStart {
                context.setFillColor(NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.2, alpha: 0.9).cgColor)
                context.fill(CGRect(x: x, y: yOffset, width: width, height: 2))
            }
        }

        // Draw connector line between the two rectangles
        if drawnRects.count == 2 {
            let gapStart = drawnRects[0].maxX
            let gapEnd = drawnRects[1].minX
            if gapEnd > gapStart {
                context.setStrokeColor(fillColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [2, 2])
                context.move(to: CGPoint(x: gapStart, y: centerY))
                context.addLine(to: CGPoint(x: gapEnd, y: centerY))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
        }

        // Draw letter centered over the combined extent
        if showLetters, let first = drawnRects.first, let last = drawnRects.last {
            let combinedRect = CGRect(
                x: first.minX,
                y: yOffset,
                width: last.maxX - first.minX,
                height: trackHeight
            )
            drawAminoAcidLetter(aaPos.aminoAcid, in: combinedRect, font: font, context: context)
        }
    }

    /// Draws a small label at the left edge of a track.
    private static func drawTrackLabel(
        _ text: String,
        yOffset: CGFloat,
        trackHeight: CGFloat,
        context: CGContext
    ) {
        let label = text as NSString
        let font = NSFont.systemFont(ofSize: 8, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = label.size(withAttributes: attributes)

        // Background pill for readability
        let pillRect = CGRect(
            x: 2, y: yOffset + (trackHeight - size.height) / 2 - 1,
            width: size.width + 4, height: size.height + 2
        )
        context.setFillColor(NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.addPath(pillPath)
        context.fillPath()

        let labelRect = CGRect(
            x: 4, y: yOffset + (trackHeight - size.height) / 2,
            width: size.width, height: size.height
        )
        label.draw(in: labelRect, withAttributes: attributes)
    }
}
