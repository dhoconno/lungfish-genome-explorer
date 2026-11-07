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
/// route only when more of them carry an index within one mismatch of a kit barcode in each index than chance gives
/// at a tail of one in a million (BIO's rule, `S33-R1-BIO.md` A2, L1 and L4 of the 3.3 tally). Otherwise the run
/// searches the bases, so a GBS or ddRAD lane whose names carry its one library index keeps its inline split. An
/// explicit engine, a context override or sample assignments always search the bases, as recorded commands of
/// earlier versions ran.
public enum DemultiplexSearchRouteOwner {
    /// Read names the probe reads from the start of the input (BIO, `S33-R1-BIO.md` D1c).
    public static let probedReadCount = 1_000
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
                if names.count >= probedReadCount { break }
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
        let indexed = names.filter(\.hasIndex)
        guard !indexed.isEmpty else { return .inline(config.demuxAdapterContext) }
        let matched = indexed.filter { name in kit.barcodes.contains { matches(name, $0) } }.count
        let ceiling = DemultiplexChanceFloor.chanceCeiling(
            trials: indexed.count,
            probability: chanceMatchShare(of: kit, names: indexed),
            tail: chanceTail
        )
        guard matched > ceiling else { return .inline(config.demuxAdapterContext) }
        if let words = collisionWords(for: kit) { return .refuse(words) }
        return .headerIndex
    }

    /// Whether the route of `config` depends on its read names.
    static func readsNames(_ config: DemultiplexConfig) -> Bool {
        config.engine == nil && config.adapterContext == nil && config.sampleAssignments.isEmpty
            && config.barcodeKit.platform.indexesInSeparateReads
    }

    /// Whether `name` carries `barcode`, at most one mismatch in each index. i5 is tried as listed and reverse
    /// complemented, since instruments differ in the strand they read it from (BIO, `S2-R1-BIO.md:52`).
    static func matches(_ name: FASTQReadNameIndex, _ barcode: BarcodeEntry) -> Bool {
        guard let i7 = name.i7, mismatches(i7, barcode.i7Sequence) <= indexMismatches else { return false }
        guard let nameI5 = name.i5, let barcodeI5 = barcode.i5Sequence else { return true }
        return mismatches(nameI5, barcodeI5) <= indexMismatches
            || mismatches(nameI5, PlatformAdapters.reverseComplement(barcodeI5)) <= indexMismatches
    }

    /// The share of random indexes of the names' commonest shape that match some barcode of `kit`.
    static func chanceMatchShare(of kit: BarcodeKitDefinition, names: [FASTQReadNameIndex]) -> Double {
        var shapes: [[Int]: Int] = [:]
        for name in names { shapes[[name.i7?.count ?? 0, name.i5?.count ?? 0], default: 0] += 1 }
        guard let shape = shapes.max(by: { $0.value < $1.value })?.key else { return 0 }
        func withinOne(_ length: Int) -> Double { (1 + 3 * Double(length)) / pow(4, Double(length)) }
        var share = 0.0
        for barcode in kit.barcodes where barcode.i7Sequence.count == shape[0] {
            var match = withinOne(shape[0])
            if let i5 = barcode.i5Sequence, shape[1] > 0 {
                match *= i5.count == shape[1] ? min(1, 2 * withinOne(shape[1])) : 0
            }
            share += match
        }
        return min(1, share)
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
