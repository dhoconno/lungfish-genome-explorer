// DemultiplexingPipeline+HeaderIndex.swift - The split of reads by the index bcl2fastq wrote in their names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Calls each read's barcode from the index in its name, as bcl2fastq and BCL Convert write it
/// (DEMUX-HEADER-INDEX-NOT-READ, L4 and L6 of the 3.3 tally). The exact-bare pass calls it per record in place of
/// its search of the bases, so the split goes through that pass's bundle writer and both mates of a pair follow
/// their fragment's call (A9, D6).
///
/// A name matches a barcode at most one mismatch in each index, an `N` counting as a mismatch, and gets a call only
/// when exactly one barcode matches. i5 is compared only when both the name and the barcode carry one, as
/// ``DemultiplexSearchRouteOwner`` does. An instrument reads i5 from one strand for the whole run, so i5 is read in
/// one orientation for each file, as listed or reverse complemented, by the majority of the file's first 1,000
/// names, ties as listed.
struct DemultiplexHeaderIndexCaller: Sendable {
    /// Names read from the start of each file to choose its i5 orientation.
    static let orientationNameCount = 1_000
    /// The most mismatches a name may have in each index and still match a barcode (L4, BIO).
    static let indexMismatches = DemultiplexSearchRouteOwner.indexMismatches

    /// Whether this file's names carry i5 reverse complemented against the kit.
    let i5ReverseComplemented: Bool
    /// The barcodes, by their offset in the kit, of every index value within one mismatch of their i7.
    private let byI7: [String: [Int]]
    /// The barcodes of every index value within one mismatch of their i5 in this file's orientation.
    private let byI5: [String: [Int]]
    /// Whether each barcode carries an i5.
    private let carriesI5: [Bool]

    init(kit: BarcodeKitDefinition, i5ReverseComplemented: Bool) {
        self.i5ReverseComplemented = i5ReverseComplemented
        var byI7: [String: [Int]] = [:]
        var byI5: [String: [Int]] = [:]
        for (offset, barcode) in kit.barcodes.enumerated() {
            for value in Self.withinOne(barcode.i7Sequence) { byI7[value, default: []].append(offset) }
            guard let i5 = barcode.i5Sequence else { continue }
            let oriented = i5ReverseComplemented ? PlatformAdapters.reverseComplement(i5) : i5
            for value in Self.withinOne(oriented) { byI5[value, default: []].append(offset) }
        }
        self.byI7 = byI7
        self.byI5 = byI5
        carriesI5 = kit.barcodes.map { $0.i5Sequence != nil }
    }

    /// The caller of `file`, its i5 orientation chosen from the file's first names. A kit with no i5 reads no name.
    static func reading(_ file: URL, kit: BarcodeKitDefinition) async throws -> DemultiplexHeaderIndexCaller {
        guard kit.barcodes.contains(where: { $0.i5Sequence != nil }) else {
            return DemultiplexHeaderIndexCaller(kit: kit, i5ReverseComplemented: false)
        }
        let listed = DemultiplexHeaderIndexCaller(kit: kit, i5ReverseComplemented: false)
        let flipped = DemultiplexHeaderIndexCaller(kit: kit, i5ReverseComplemented: true)
        var asListed = 0
        var reversed = 0
        var read = 0
        for try await record in FASTQReader(validateSequence: false).records(from: file) {
            let name = FASTQReadNameIndex(rawName: record.description.map { "\(record.identifier) \($0)" } ?? record.identifier)
            if name.i5 != nil {
                if !listed.candidates(name).isEmpty { asListed += 1 }
                if !flipped.candidates(name).isEmpty { reversed += 1 }
            }
            read += 1
            if read >= orientationNameCount { break }
        }
        return reversed > asListed ? flipped : listed
    }

    /// The callers of `files`, in file order.
    static func reading(_ files: [URL], kit: BarcodeKitDefinition) async throws -> [DemultiplexHeaderIndexCaller] {
        var callers: [DemultiplexHeaderIndexCaller] = []
        for file in files { callers.append(try await reading(file, kit: kit)) }
        return callers
    }

    /// The offset in the kit of the one barcode the FASTQ header line `header` carries, or nil when it carries none
    /// or more than one.
    func call(header: String) -> Int? {
        let found = candidates(FASTQReadNameIndex(rawName: header.hasPrefix("@") ? header.dropFirst() : Substring(header)))
        return found.count == 1 ? found[0] : nil
    }

    /// The barcodes `name` matches, at most one mismatch in each index.
    func candidates(_ name: FASTQReadNameIndex) -> [Int] {
        guard let i7 = name.i7, let near = byI7[i7] else { return [] }
        guard let i5 = name.i5 else { return near }
        let nearI5 = byI5[i5] ?? []
        return near.filter { !carriesI5[$0] || nearI5.contains($0) }
    }

    /// The command-line words of `callers`, one i5 orientation a file in file order when the kit carries i5.
    static func commandLine(_ callers: [DemultiplexHeaderIndexCaller], kit: BarcodeKitDefinition, threads: Int) -> String {
        var words = ["header-index-demux", "--index-mismatches", String(indexMismatches)]
        if kit.barcodes.contains(where: { $0.i5Sequence != nil }) {
            words += ["--i5", callers.map { $0.i5ReverseComplemented ? "reverse-complement" : "as-listed" }.joined(separator: ",")]
        }
        return (words + (threads > 1 ? ["--threads", String(threads)] : [])).joined(separator: " ")
    }

    /// Every value of `index`'s length within one mismatch of it, upper case, a no-call `N` at one base included.
    static func withinOne(_ index: String) -> Set<String> {
        let bases = Array(index.uppercased())
        var values: Set<String> = [String(bases)]
        for position in bases.indices {
            for base in "ACGTN" where base != bases[position] {
                var changed = bases
                changed[position] = base
                values.insert(String(changed))
            }
        }
        return values
    }
}
