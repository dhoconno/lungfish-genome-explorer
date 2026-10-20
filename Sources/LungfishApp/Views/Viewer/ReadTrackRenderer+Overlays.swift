// ReadTrackRenderer+Overlays.swift - Downsampling, overlays and mate links of the read track renderer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import LungfishCore
import LungfishWorkflow

extension ReadTrackRenderer {

    // MARK: - Intelligent Downsampling

    /// Downsamples reads for high-coverage regions to keep rendering fast.
    ///
    /// Uses reservoir sampling to maintain a representative subset.
    /// Preserves strand balance and read distribution across the region.
    ///
    /// - Parameters:
    ///   - reads: Input reads
    ///   - maxReads: Maximum reads to retain
    ///   - regionStart: Start of the visible region
    ///   - regionEnd: End of the visible region
    /// - Returns: Downsampled reads and the total count before sampling
    public static func downsample(
        _ reads: [AlignedRead],
        maxReads: Int = 5_000,
        regionStart: Int = 0,
        regionEnd: Int = Int.max
    ) -> (reads: [AlignedRead], totalCount: Int) {
        guard reads.count > maxReads else { return (reads, reads.count) }

        let totalCount = reads.count

        // Split by strand to maintain balance
        var forward: [AlignedRead] = []
        var reverse: [AlignedRead] = []
        forward.reserveCapacity(reads.count / 2)
        reverse.reserveCapacity(reads.count / 2)
        for read in reads {
            if read.isReverse {
                reverse.append(read)
            } else {
                forward.append(read)
            }
        }

        // Allocate proportionally to each strand
        let fwdShare = Int(Double(maxReads) * Double(forward.count) / Double(totalCount))
        let revShare = maxReads - fwdShare

        let sampledFwd = reservoirSample(forward, count: fwdShare)
        let sampledRev = reservoirSample(reverse, count: revShare)

        var result = sampledFwd + sampledRev
        result.sort { $0.position < $1.position }
        return (result, totalCount)
    }

    /// Reservoir sampling: picks `count` random elements from `source`.
    static func reservoirSample(_ source: [AlignedRead], count: Int) -> [AlignedRead] {
        guard count > 0 else { return [] }
        guard source.count > count else { return source }

        var reservoir = Array(source.prefix(count))
        for i in count..<source.count {
            let j = Int.random(in: 0...i)
            if j < count {
                reservoir[j] = source[i]
            }
        }
        return reservoir
    }

    // MARK: - Base Quality Heatmap

    /// Draws per-base quality shading on a base-level read.
    ///
    /// Low quality bases are shaded yellow/red, high quality bases are transparent.
    /// Used when `ReadColorMode.baseQuality` is active.
    static func drawBaseQualityOverlay(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        context: CGContext,
        y: CGFloat,
        readHeight: CGFloat
    ) {
        guard !read.qualities.isEmpty else { return }
        let pixelsPerBase = 1.0 / frame.scale
        let cellWidth = CGFloat(pixelsPerBase)

        var byteIndex = 0
        var refPos = read.position

        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    guard byteIndex < read.qualities.count else { refPos += 1; byteIndex += 1; continue }
                    let q = read.qualities[byteIndex]
                    byteIndex += 1

                    let x = frame.screenPosition(for: Double(refPos))
                    refPos += 1

                    // Quality threshold: highlight bases below Q20
                    if q < 20 {
                        let intensity = CGFloat(20 - q) / 20.0 * 0.4
                        context.setFillColor(CGColor(red: 1.0, green: 0.8, blue: 0.0, alpha: intensity))
                        context.fill(CGRect(x: x, y: y, width: cellWidth, height: readHeight))
                    }
                }

            case .insertion, .softClip:
                for _ in 0..<op.length {
                    byteIndex += 1
                }

            case .deletion, .skip:
                refPos += op.length

            case .hardClip, .padding:
                break
            }
        }
    }

    // MARK: - Split-Read Visualization

    /// Draws connecting lines between a primary alignment and its supplementary alignments (SA tag).
    ///
    /// These lines indicate chimeric/split-read alignments, commonly seen at structural
    /// variant breakpoints. Lines connect from the soft-clipped end of the primary read
    /// to the supplementary alignment positions.
    static func drawSplitReadIndicators(
        read: AlignedRead,
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        y: CGFloat,
        readHeight: CGFloat,
        currentChromosome: String
    ) {
        let supps = read.parsedSupplementaryAlignments
        guard !supps.isEmpty else { return }

        let readMidY = y + readHeight / 2

        context.saveGState()
        context.setStrokeColor(figureTheme.color(.splitRead).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [3, 2])

        for supp in supps {
            guard supp.chromosome == currentChromosome else { continue }

            // Draw arc connecting primary and supplementary
            let primaryEndPx: CGFloat
            if read.isReverse {
                primaryEndPx = frame.screenPosition(for: Double(read.position))
            } else {
                primaryEndPx = frame.screenPosition(for: Double(read.alignmentEnd))
            }

            let suppStartPx = frame.screenPosition(for: Double(supp.position))

            // Arc height based on distance
            let dist = abs(suppStartPx - primaryEndPx)
            let arcHeight = min(dist * 0.15, 20)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: primaryEndPx, y: readMidY))

            let midX = (primaryEndPx + suppStartPx) / 2
            path.addQuadCurve(
                to: CGPoint(x: suppStartPx, y: readMidY),
                control: CGPoint(x: midX, y: readMidY - arcHeight)
            )

            context.addPath(path)
            context.strokePath()

            // Small triangle at supplementary end
            let triSize: CGFloat = 3
            let triPath = CGMutablePath()
            if suppStartPx > primaryEndPx {
                triPath.move(to: CGPoint(x: suppStartPx, y: readMidY))
                triPath.addLine(to: CGPoint(x: suppStartPx - triSize, y: readMidY - triSize))
                triPath.addLine(to: CGPoint(x: suppStartPx - triSize, y: readMidY + triSize))
            } else {
                triPath.move(to: CGPoint(x: suppStartPx, y: readMidY))
                triPath.addLine(to: CGPoint(x: suppStartPx + triSize, y: readMidY - triSize))
                triPath.addLine(to: CGPoint(x: suppStartPx + triSize, y: readMidY + triSize))
            }
            triPath.closeSubpath()
            context.setFillColor(figureTheme.color(.splitRead).cgColor)
            context.addPath(triPath)
            context.fillPath()
        }

        context.setLineDash(phase: 0, lengths: [])
        context.restoreGState()
    }

    // MARK: - Paired-End Linking

    /// Draws connecting lines between mate pairs that are both visible in the viewport.
    ///
    /// Finds reads with the same name and draws a thin line connecting them,
    /// which helps visualize fragment structure and insert sizes.
    static func drawMatePairLinks(
        packedReads: [(row: Int, read: AlignedRead)],
        frame: ViewerFigureFrame,
        context: CGContext,
        figureTheme: ViewerFigureTheme,
        rect: CGRect,
        readHeight: CGFloat
    ) {
        // Build lookup of read name -> (row, read) for paired reads
        var nameLookup: [String: [(row: Int, read: AlignedRead)]] = [:]
        for (row, read) in packedReads where read.isPaired {
            nameLookup[read.name, default: []].append((row, read))
        }

        context.saveGState()
        context.setStrokeColor(figureTheme.color(.mateLink).cgColor)
        context.setLineWidth(0.5)

        for (_, mates) in nameLookup where mates.count == 2 {
            let (row1, read1) = mates[0]
            let (row2, read2) = mates[1]

            // Only draw if both are on the same row (typical for properly paired reads)
            guard row1 == row2 else { continue }

            let y = rect.minY + CGFloat(row1) * (readHeight + rowGap) + readHeight / 2

            let end1 = frame.screenPosition(for: Double(read1.alignmentEnd))
            let start2 = frame.screenPosition(for: Double(read2.position))

            // Draw connecting line between mates
            let left = min(end1, start2)
            let right = max(end1, start2)
            guard right - left > 2 else { continue } // Skip if overlapping

            context.move(to: CGPoint(x: left, y: y))
            context.addLine(to: CGPoint(x: right, y: y))
            context.strokePath()
        }

        context.restoreGState()
    }

    // MARK: - Base at Position Helper

    /// Returns a sort key for the base at a reference position in a read.
    /// Used for base-at-position sorting to investigate variants.
    nonisolated static func baseAtRefPos(_ read: AlignedRead, pos: Int) -> UInt8 {
        guard pos >= read.position, pos < read.alignmentEnd else { return 255 }
        let seqBytes = Array(read.sequence.utf8)
        var byteIndex = 0
        var refPos = read.position
        for op in read.cigar {
            switch op.op {
            case .match, .seqMatch, .seqMismatch:
                for _ in 0..<op.length {
                    if refPos == pos, byteIndex < seqBytes.count {
                        return seqBytes[byteIndex] & 0xDF // uppercase
                    }
                    refPos += 1
                    byteIndex += 1
                }
            case .insertion, .softClip:
                byteIndex += op.length
            case .deletion, .skip:
                refPos += op.length
            case .hardClip, .padding:
                break
            }
        }
        return 255 // Position not covered by this read
    }
}
