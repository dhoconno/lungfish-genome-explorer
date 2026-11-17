// AffectedResults+DemultiplexKit.swift - Whether a demultiplexing record searched with a kit the chance floor cannot judge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension AffectedResults {
    /// Whether a `lungfish fastq demultiplex` record is a Cutadapt search whose kit, at the record's error rate, holds half
    /// of all reads or more by chance, the kit the floor cannot judge (DEMUX-FLOOR-SATURATED-KIT, BIO-DEMUX-THREE section 1).
    ///
    /// A record whose floor names its null says it: `saturated-kit` is such a run and `start-composition` a kit the floor
    /// measured. Any other record names its kit by the definition file, which the run keeps in its result folder since
    /// a2dcd689f, so the file is read. The share is the floor's (`DemultiplexChanceFloor.isSaturated`) on the lines a kit of
    /// single barcodes searches, `^barcode` at each 5' offset or `barcode$` at each 3' offset, as fragments of two mates when
    /// the record placed mates. A built-in kit is never that short (`DemultiplexSaturatedKitTests`), and a record that names
    /// another engine, a dual kit or a file that cannot be read is not such a run. It reads a file, so the Inspector's
    /// lookup runs it off the main actor.
    static func searchedWithAKitTheFloorCannotJudge(_ envelope: ProvenanceEnvelope) -> Bool {
        let options = envelope.options.explicit
        if case .string(let engine)? = options["engine"], engine != "cutadapt" { return false }
        if case .dictionary(let floor)? = options["chanceFloor"], case .string(let null)? = floor["null"] {
            if null == DemultiplexChanceFloor.Null.saturatedKit.rawValue { return true }
            if null == DemultiplexChanceFloor.Null.startComposition.rawValue { return false }
        }
        guard case .string(let named)? = options["kit"], BarcodeKitRegistry.kit(byID: named) == nil else { return false }
        let url = URL(fileURLWithPath: named)
        guard let data = try? Data(contentsOf: url),
              let kit = try? BarcodeKitRegistry.loadCustomKit(data: data, name: url.deletingPathExtension().lastPathComponent),
              kit.pairingMode == .singleEnd else { return false }
        func number(_ key: String) -> Double? {
            switch options[key] {
            case .number(let value)?: return value
            case .integer(let value)?: return Double(value)
            default: return nil
            }
        }
        var location = "bothends"
        if case .string(let named)? = options["location"] { location = named.lowercased() }
        let threePrime = ["3prime", "three-prime", "threeprime"].contains(location)
        let offsets = max(0, Int(number(threePrime ? "maxDistanceFrom3Prime" : "maxDistanceFrom5Prime") ?? 0))
        let patterns = Dictionary(kit.barcodes.map { barcode -> (String, [String]) in
            let sequence = barcode.i7Sequence.uppercased()
            return (barcode.id, (0...offsets).map { offset in
                let wildcard = String(repeating: "N", count: offset)
                return threePrime ? sequence + wildcard + "$" : "^" + wildcard + sequence
            })
        }, uniquingKeysWith: +)
        var pairs = 0
        if case .dictionary(let mates)? = options["mateCalls"], case .integer(let count)? = mates["pairs"] { pairs = count }
        return DemultiplexChanceFloor.isSaturated(
            patterns: patterns, errorRate: number("errorRate") ?? 0.15, allowsIndels: true, unit: pairs > 0 ? 2 : 1
        )
    }
}
