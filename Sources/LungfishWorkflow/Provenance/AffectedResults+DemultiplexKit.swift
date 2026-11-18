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
    /// the record placed mates. Of the built-in kits only the Fluidigm Access Array kit is such a kit
    /// (`DemultiplexSaturatedKitTests`). Cutadapt searches its bare 10-base barcodes anywhere in the read and places nearly
    /// every read in one by chance, so its record is such a run at any error rate (BIO-SATKIT-FLUIDIGM item 5 and Q2). A
    /// definition whose `# kit:` line names that kit is searched as the kit is, so its record is such a run at any rate too
    /// (BIO-SATKIT-ANYWHERE item 5). A record that names another engine, another built-in kit, a definition built on
    /// another kit, a dual kit or a file that cannot be read is not such a run. A record of a custom dual kit at Both Ends
    /// with no sample sheet, whose pairs were searched anywhere in the read, names the narrower kind of
    /// ``searchedCustomDualPairsAnywhere(_:)``, which `kind(of:)` asks first (DEMUX-DUAL-UNANCHORED, BIO-DUAL-ANCHOR item 7).
    /// It reads a file, so the Inspector's lookup runs it off the main actor.
    static func searchedWithAKitTheFloorCannotJudge(_ envelope: ProvenanceEnvelope) -> Bool {
        let options = envelope.options.explicit
        if case .string(let engine)? = options["engine"], engine != "cutadapt" { return false }
        if case .dictionary(let floor)? = options["chanceFloor"], case .string(let null)? = floor["null"] {
            if null == DemultiplexChanceFloor.Null.saturatedKit.rawValue { return true }
            if null == DemultiplexChanceFloor.Null.startComposition.rawValue { return false }
        }
        let fluidigm = BarcodeKitRegistry.fluidigmAccessArray.id
        if ["kit", "resolvedKit"].contains(where: { options[$0] == .string(fluidigm) }) { return true }
        guard case .string(let named)? = options["kit"], BarcodeKitRegistry.kit(byID: named) == nil else { return false }
        let url = URL(fileURLWithPath: named)
        guard let data = try? Data(contentsOf: url),
              let kit = try? BarcodeKitRegistry.loadCustomKit(data: data, name: url.deletingPathExtension().lastPathComponent)
        else { return false }
        if kit.sourceKitID == fluidigm { return true }
        guard kit.pairingMode == .singleEnd else { return false }
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

    /// Whether a `lungfish fastq demultiplex` record is a Cutadapt search of a custom dual-index definition at Both Ends with
    /// no sample sheet. Every published build up to Preview 2026.11.11 searched its pairs as `i7...i5` with no anchor, so each
    /// barcode was found anywhere in the read and reads with no barcode landed in samples by chance (DEMUX-DUAL-UNANCHORED,
    /// BIO-DUAL-ANCHOR item 7 and Q4). The record names the engine `cutadapt` or no engine, a definition that loads as dual,
    /// `.fixedDual`, `.custom` and `.unknown` with no `# kit:` line, the location Both Ends, which is the default, and a
    /// floor that measured no null. The error rate and the overlap do not matter. The copy of the definition the run kept
    /// (`customBarcodeKit`) is read before the file `kit` names, so a definition moved or replaced since the run still names
    /// the kind. The CLI has no sample sheet. It reads a file, so the Inspector's lookup runs it off the main actor.
    static func searchedCustomDualPairsAnywhere(_ envelope: ProvenanceEnvelope) -> Bool {
        let options = envelope.options.explicit
        if case .string(let engine)? = options["engine"], engine != "cutadapt" { return false }
        if case .dictionary(let floor)? = options["chanceFloor"],
           floor["null"] == .string(DemultiplexChanceFloor.Null.startComposition.rawValue) { return false }
        var location = "bothends"
        if case .string(let named)? = options["resolvedLocation"] ?? options["location"] { location = named.lowercased() }
        guard ["bothends", "both", "both-ends", "both_ends"].contains(location),
              let kit = recordedCustomKit(options) else { return false }
        return kit.isDualIndexed && kit.pairingMode == .fixedDual && kit.kitType == .custom && kit.platform == .unknown
            && kit.sourceKitID == nil
    }

    /// Whether a `lungfish fastq demultiplex` record is a Cutadapt search of a custom dual-index definition at 5' End or 3'
    /// End with no sample sheet. Every published build up to Preview 2026.11.12 searched one barcode of each pair free and
    /// the other strand as the swapped pair, so reads from the reverse strand were left unassigned and chance matches
    /// could fill a sample (DEMUX-DUAL-BARE-REVERSE, BIO-BARE-REVERSE items 5 (v) and 6, Q3 and Q4). The record names the
    /// engine `cutadapt` or no engine, the resolved location, else the location, in a spelling `--location` takes for 5'
    /// End or 3' End, and a definition that loads as the one of ``searchedCustomDualPairsAnywhere(_:)``, the kept copy
    /// first. The floor does not matter, since no null finds the reads of the reverse strand. The CLI has no sample sheet.
    /// It reads a file, so the Inspector's lookup runs it off the main actor.
    static func searchedCustomDualPairsAtOneEnd(_ envelope: ProvenanceEnvelope) -> Bool {
        let options = envelope.options.explicit
        if case .string(let engine)? = options["engine"], engine != "cutadapt" { return false }
        guard case .string(let named)? = options["resolvedLocation"] ?? options["location"],
              ["5prime", "five-prime", "fiveprime", "3prime", "three-prime", "threeprime"].contains(named.lowercased()),
              let kit = recordedCustomKit(options) else { return false }
        return kit.isDualIndexed && kit.pairingMode == .fixedDual && kit.kitType == .custom && kit.platform == .unknown
            && kit.sourceKitID == nil
    }

    /// The custom definition a demultiplexing record names: the copy the run kept in its result folder, else the file `kit`
    /// names when it is no built-in kit id, or nil when neither can be read.
    private static func recordedCustomKit(_ options: [String: ParameterValue]) -> BarcodeKitDefinition? {
        var urls: [URL] = []
        switch options["customBarcodeKit"] {
        case .file(let url)?: urls.append(url)
        case .string(let path)?: urls.append(URL(fileURLWithPath: path))
        default: break
        }
        if case .string(let named)? = options["kit"], BarcodeKitRegistry.kit(byID: named) == nil {
            urls.append(URL(fileURLWithPath: named))
        }
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let kit = try? BarcodeKitRegistry.loadCustomKit(data: data, name: url.deletingPathExtension().lastPathComponent) {
                return kit
            }
        }
        return nil
    }
}
