// DemultiplexSearchRoute.swift - The one owner of where a demultiplexing run looks for each read's barcode
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Where a demultiplexing run looks for each read's barcode.
public enum DemultiplexSearchRoute: Sendable {
    /// The read names carry the kit's indexes, so the run must split by the index in the read names.
    case headerIndex
    /// The run searches the read bases with this context.
    case inline(any PlatformAdapterContext)
    /// The run cannot start, for the reason the words give.
    case refuse(String)
}

/// The one owner of the search route (ARCH pin 1 of the 3.3 meeting). The run and the CLI ask it, and no other
/// code decides between the read names and the read bases.
///
/// A kit whose platform has `indexesInSeparateReads` (Illumina, Element, Ultima, MGI) is searched in the read bases
/// as a bare index, so a file whose index sits only in its read names gave reads a barcode by chance
/// (DEMUX-HEADER-INDEX-NOT-READ). With no engine named, the owner reads the first read names and takes the header
/// route only when two or more kit barcodes are present in them (ruling BIO-DEMUX-FLOOR item 1, see
/// ``presentBarcodes(of:in:)``). Otherwise the run searches the bases, so a GBS or ddRAD lane whose names carry its
/// one library index keeps its inline split, and one sample's file ends in the chance floor's words. A custom
/// definition is searched as a bare index, as an Illumina kit is, so its run reads the names too. An
/// explicit engine, a context override or sample assignments always search the bases, as recorded commands of
/// earlier versions ran.
public enum DemultiplexSearchRouteOwner {
    /// Read names the probe reads from the start of the input (BIO, `S33-R1-BIO.md` D1c).
    public static let probedReadCount = 1_000
    /// Read names the probe reads on to when exactly one barcode is present in the first 1,000 (BIO-DEMUX-FLOOR 2).
    public static let readOnCount = 10_000
    /// The tail the probe's match count must pass, one in a million, the tail of the chance floor (L5).
    public static let chanceTail = 1e-6
    /// The most mismatches a read-name index may have in each index and still match a barcode (L4, BIO).
    public static let indexMismatches = 1
    /// Two barcodes whose i7 and i5 both lie within this many mismatches refuse the header route (L4, BIO).
    public static let collisionMismatches = 2

    /// The route of `config`, reading the first read names of `input` when the route depends on them. It runs off
    /// the main actor, and a file it cannot read as FASTQ gives no names, so the run searches its bases.
    public static func route(for config: DemultiplexConfig, input: URL) async -> DemultiplexSearchRoute {
        guard readsNames(config) else { return .inline(config.demuxAdapterContext) }
        var names: [FASTQReadNameIndex] = []
        do {
            for try await record in FASTQReader(validateSequence: false).records(from: input) {
                let raw = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
                names.append(FASTQReadNameIndex(rawName: raw))
                // One barcode present in the first names reads on before the owner chooses (BIO-DEMUX-FLOOR item 2).
                if names.count == probedReadCount, presentBarcodes(of: config.barcodeKit, in: names) != 1 { break }
                if names.count >= readOnCount { break }
            }
        } catch {
            return .inline(config.demuxAdapterContext)
        }
        return route(for: config, names: names)
    }

    /// The route of `config` for read names already read.
    public static func route(for config: DemultiplexConfig, names: [FASTQReadNameIndex]) -> DemultiplexSearchRoute {
        guard readsNames(config) else { return .inline(config.demuxAdapterContext) }
        let kit = config.barcodeKit
        var present = presentBarcodes(of: kit, in: Array(names.prefix(probedReadCount)))
        if present == 1, names.count > probedReadCount {
            present = presentBarcodes(of: kit, in: Array(names.prefix(readOnCount)))
        }
        guard present >= 2 else { return .inline(config.demuxAdapterContext) }
        if let words = collisionWords(for: kit) { return .refuse(words) }
        return .headerIndex
    }

    /// Whether the route of `config` depends on its read names.
    static func readsNames(_ config: DemultiplexConfig) -> Bool {
        config.engine == nil && config.adapterContext == nil && config.sampleAssignments.isEmpty
            && (config.barcodeKit.platform.indexesInSeparateReads || config.barcodeKit.vendor == "custom")
    }

    /// Whether `name` carries `barcode`, at most one mismatch in each index. i5 is tried as listed and reverse
    /// complemented, since instruments differ in the strand they read it from (BIO, `S2-R1-BIO.md:52`).
    static func matches(_ name: FASTQReadNameIndex, _ barcode: BarcodeEntry) -> Bool {
        guard let i7 = name.i7, mismatches(i7, barcode.i7Sequence) <= indexMismatches else { return false }
        guard let nameI5 = name.i5, let barcodeI5 = barcode.i5Sequence else { return true }
        return mismatches(nameI5, barcodeI5) <= indexMismatches
            || mismatches(nameI5, PlatformAdapters.reverseComplement(barcodeI5)) <= indexMismatches
    }

    /// The barcodes of `kit` present in `names` (BIO-DEMUX-FLOOR item 1). The names are tallied by index value, since
    /// a file's names repeat a few values. A barcode is present when the names within one mismatch of it in each
    /// index number more than its own chance ceiling, at its share `(1 + 3L)/4^L` and a tail of one in a million
    /// split over the kit's barcodes, and their commonest index is the barcode itself. So a library index one
    /// mismatch from a barcode, or another kit's index near one, is not that barcode.
    static func presentBarcodes(of kit: BarcodeKitDefinition, in names: [FASTQReadNameIndex]) -> Int {
        struct IndexValue: Hashable { let i7: String?, i5: String? }
        var tally: [IndexValue: (name: FASTQReadNameIndex, count: Int)] = [:]
        var shapes: [[Int]: Int] = [:]
        for name in names where name.hasIndex {
            tally[IndexValue(i7: name.i7, i5: name.i5), default: (name, 0)].count += 1
            shapes[[name.i7?.count ?? 0, name.i5?.count ?? 0], default: 0] += 1
        }
        let indexed = tally.values.reduce(0) { $0 + $1.count }
        // Equal counts take the later shape in lexicographic order, so a tie routes the same way in every process.
        guard indexed > 0, let shape = shapes.max(by: {
            $0.value != $1.value ? $0.value < $1.value : $0.key.lexicographicallyPrecedes($1.key)
        })?.key else { return 0 }
        func withinOne(_ length: Int) -> Double { (1 + 3 * Double(length)) / pow(4, Double(length)) }
        let tail = chanceTail / Double(max(1, kit.barcodes.count))
        var present = 0
        for barcode in kit.barcodes where barcode.i7Sequence.count == shape[0] {
            var share = withinOne(shape[0])
            if let i5 = barcode.i5Sequence, shape[1] > 0 {
                share *= i5.count == shape[1] ? min(1, 2 * withinOne(shape[1])) : 0
            }
            let near = tally.values.filter { matches($0.name, barcode) }
            let ceiling = DemultiplexChanceFloor.chanceCeiling(trials: indexed, probability: share, tail: tail)
            guard near.reduce(0, { $0 + $1.count }) > ceiling else { continue }
            // A no-call carries no evidence against the barcode: names that differ from it only at an N are the
            // barcode, and a rival is the commonest index that differs at a base the name called.
            let own = near.filter { isExact($0.name, barcode) }.reduce(0) { $0 + $1.count }
            let rival = near.filter { !isExact($0.name, barcode) }.map(\.count).max() ?? 0
            if own > 0, own >= rival { present += 1 }
        }
        return present
    }

    /// Whether `name` carries `barcode` at every base it called, i5 as listed or reverse complemented. An `N` in the
    /// name is a no-call and agrees with any base (the first index cycle of the first tiles of a MiSeq run is often N).
    static func isExact(_ name: FASTQReadNameIndex, _ barcode: BarcodeEntry) -> Bool {
        guard let i7 = name.i7, calledMismatches(i7, barcode.i7Sequence) == 0 else { return false }
        guard let nameI5 = name.i5, let barcodeI5 = barcode.i5Sequence else { return true }
        return calledMismatches(nameI5, barcodeI5) == 0
            || calledMismatches(nameI5, PlatformAdapters.reverseComplement(barcodeI5)) == 0
    }

    /// Mismatches between a name's index and a barcode's at the bases the name called, or `Int.max` when their lengths differ.
    static func calledMismatches(_ name: String, _ barcode: String) -> Int {
        guard name.count == barcode.count else { return Int.max }
        return zip(name.uppercased(), barcode.uppercased()).filter { $0 != $1 && $0 != "N" }.count
    }

    /// Words that refuse the header route when two barcodes lie within two mismatches in every index they both
    /// carry, so one read error could give a read the wrong sample. Barcodes that share an i7 but differ in i5, as
    /// on a combinatorial plate, do not refuse (BIO, L4).
    static func collisionWords(for kit: BarcodeKitDefinition) -> String? {
        let barcodes = kit.barcodes
        for (offset, first) in barcodes.enumerated() {
            for second in barcodes[(offset + 1)...] {
                let i7 = mismatches(first.i7Sequence, second.i7Sequence)
                guard i7 <= collisionMismatches else { continue }
                var total = i7
                if let firstI5 = first.i5Sequence, let secondI5 = second.i5Sequence {
                    let i5 = mismatches(firstI5, secondI5)
                    guard i5 <= collisionMismatches else { continue }
                    total += i5
                }
                return "Barcodes \(first.id) and \(second.id) differ at \(total) bases, so one read error could give a "
                    + "read the wrong sample, and Demultiplex Barcodes did not start. Correct the definition, or "
                    + "remove one of the two barcodes."
            }
        }
        return nil
    }

    /// Mismatches between two indexes of one length, case blind, or `Int.max` when their lengths differ.
    static func mismatches(_ first: String, _ second: String) -> Int {
        guard first.count == second.count else { return Int.max }
        return zip(first.uppercased(), second.uppercased()).filter { $0 != $1 }.count
    }
}
