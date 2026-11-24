// DemultiplexingPipeline+SearchLines.swift - The most Cutadapt lines a dual-index run at Both Ends may give
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// The other strand of the molecule a linked pair `first...second` names, the pair read on the opposite strand with the
    /// location's anchors kept, or nil when that strand reads as the pair itself and the pair is searched as one strand
    /// (BIO-BARE-REVERSE item 2). The writer of the built-in dual route and the line cap both ask it, so the cap counts the
    /// lines the writer writes (BIO-DEMUX-CAP item 1).
    static func otherStrand(first: String, second: String) -> (first: String, second: String)? {
        let reverseFirst = PlatformAdapters.reverseComplement(second)
        let reverseSecond = PlatformAdapters.reverseComplement(first)
        guard reverseFirst != first || reverseSecond != second else { return nil }
        return (reverseFirst, reverseSecond)
    }

    /// The strands the built-in dual route writes for `entries`: two for each pair, and one for a pair whose other strand
    /// reads as itself.
    static func linkedStrandCount(of entries: [(name: String, first: String, second: String)]) -> Int {
        entries.reduce(0) { total, entry in
            let other = otherStrand(first: entry.first.uppercased(), second: entry.second.uppercased())
            return total + (other == nil ? 1 : 2)
        }
    }

    /// Refuses a dual-index run at Both Ends with no sample sheet whose Cutadapt lines pass ``observedPairLineCap``, before
    /// the adapter file is written and before Cutadapt starts. Each pair gives a line for each of its strands and each
    /// combination of 5' and 3' distance, `strands` strands in all across `pairs` pairs, so 96 pairs at 8/8 are 15,552 lines.
    /// Cutadapt spends 451 s on them before it reads the first read and 0.17 s a read after it, about 12 hours for a million
    /// reads on the app's 4 cores, so the run is refused in words (BIO-DUAL-ANCHOR item 5, DEMUX-BUILTIN-DUAL-LINES). Each
    /// distance is clamped to the cap before the lines are multiplied, and a negative distance counts as 0, as the writers
    /// read it, so a distance of `Int.max` is refused in words and does not overflow.
    func requireSearchLinesWithinCap(config: DemultiplexConfig, pairs: Int, strands: Int) throws {
        let cap = Self.observedPairLineCap
        let cells = (max(0, min(config.maxDistanceFrom5Prime, cap)) + 1) * (max(0, min(config.maxDistanceFrom3Prime, cap)) + 1)
        let lines = cells * strands
        guard lines <= cap else {
            throw DemultiplexError.tooManySearchLines(
                kitName: config.barcodeKit.displayName, pairs: pairs,
                maxDistanceFrom5Prime: config.maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: config.maxDistanceFrom3Prime, lines: lines
            )
        }
    }

    /// The offsets `0...distance` a writer searches at one end. A negative distance is 0, and a distance above
    /// ``observedPairLineCap`` is clamped to it, so a typed `Int.max` builds no array of its own length. The clamp serves only
    /// the end a writer does not read: the end it reads is checked first by
    /// ``requireOneEndSearchLinesWithinCap(config:barcodes:strands:)``, so a run of 6,000 lines or fewer has the offsets
    /// `Array(0...max(0, distance))` gave (DEMUX-ONEEND-INTMAX-CRASH).
    static func offsets(upTo distance: Int) -> [Int] {
        Array(0...max(0, min(distance, Self.observedPairLineCap)))
    }

    /// Refuses a run at one end whose Cutadapt lines pass ``observedPairLineCap``, before the adapter file is written and
    /// before Cutadapt starts. A single-index kit, a dual kit at 5' End or 3' End and a sample sheet at one end give a line
    /// for each strand of each barcode and each distance from 0 to the one typed for the end the writer reads, `strands`
    /// strands in all across `barcodes` barcodes (the single-end writer reads the 5' Distance at Both Ends). The distance of
    /// the other end is not read and is not refused. The lines are counted without clamping and are `Int.max` when the count
    /// overflows, so a typed distance of `Int.max` is refused in words (DEMUX-ONEEND-INTMAX-CRASH).
    func requireOneEndSearchLinesWithinCap(config: DemultiplexConfig, barcodes: Int, strands: Int) throws {
        let fromThreePrime = config.barcodeLocation == .threePrime
        let distance = fromThreePrime ? config.maxDistanceFrom3Prime : config.maxDistanceFrom5Prime
        let (cells, cellsOverflowed) = max(0, distance).addingReportingOverflow(1)
        let (product, productOverflowed) = cells.multipliedReportingOverflow(by: strands)
        let lines = (cellsOverflowed || productOverflowed) ? Int.max : product
        guard lines <= Self.observedPairLineCap else {
            throw DemultiplexError.tooManyOneEndSearchLines(
                kitName: config.barcodeKit.displayName, barcodes: barcodes, fromThreePrime: fromThreePrime,
                distance: distance, lines: lines
            )
        }
    }
}
