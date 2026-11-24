// ReadLengthTable.swift - The fragments an extraction names, with the lengths kraken2 recorded and the lengths found
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import Synchronization

/// The read IDs an extraction names: how many, whether it names one, and each in turn. The seqkit pass writes them to the
/// file it reads from, a chunk at a time, and the pass over a pair of files read in step asks for each record's ID.
protocol ReadIDCollection: Sendable {
    var idCount: Int { get }
    func contains(_ id: String) -> Bool
    func forEachID(_ body: (String) throws -> Void) throws
}

extension Set<String>: ReadIDCollection {
    var idCount: Int { count }

    func forEachID(_ body: (String) throws -> Void) throws {
        for id in self { try body(id) }
    }
}

/// The fragments one extraction names, keyed by fragment ID, each with the lengths kraken2 recorded for it and the lengths
/// the read check found in the extracted reads (READ-IDENTITY-EXTRACT-MEMORY, ruling BIOQA-ROWS-MEMORY items 2 and 3).
///
/// One value of fixed size stands behind each ID: the lengths of up to two mates as kraken2 gave them and as the check
/// found them, with the mate each belongs to. A host taxon of 20 M pairs therefore costs the table's bucket and the ID's
/// own string, about 170 B a fragment, where a set of IDs, a dictionary of arrays and the check's own dictionary of
/// arrays cost 780 B. The scan fills the table, the seqkit pass reads its IDs, and the check marks the lengths found in
/// place and counts them, one after the other on one task. The table is a class so that the check marks the table the
/// scan filled, and no copy of its storage can be made. The storage sits behind a lock, taken once a call, so the class
/// is Sendable with no escape hatch.
///
/// A fragment that does not fit its value, a third length under one ID, a mate other than 1 and 2 or a length over 4 GB,
/// keeps its lists in `spilled` instead, as arrays. The verdict is the one ``KrakenReadLength/agree(expected:found:)``
/// gives on those lists either way, so every verdict is the one the dictionary of arrays gave.
final class ReadLengthTable: ReadIDCollection {
    private let storage = Mutex(Storage())

    init() {}

    /// The number of fragments, named or not.
    var count: Int { storage.withLock { $0.entries.count } }
    var idCount: Int { count }
    var isEmpty: Bool { storage.withLock { $0.entries.isEmpty } }

    func contains(_ id: String) -> Bool {
        storage.withLock { $0.entries[id] != nil }
    }

    func forEachID(_ body: (String) throws -> Void) throws {
        try storage.withLock { storage in
            for id in storage.entries.keys { try body(id) }
        }
    }

    // MARK: - The scan

    /// Adds the fragment `id`. `expected` are the lengths its per-read line gave: nil for a line with no length column,
    /// which the check leaves out, and an empty list for a column that could not be read, which it checks by ID only.
    func record(_ id: String, expected: [KrakenReadLength]?) {
        storage.withLock { $0.record(id, expected: expected) }
    }

    // MARK: - The check

    /// Whether `id` is a fragment whose per-read line gave a length column, the ones the check counts.
    func isNamed(_ id: String) -> Bool {
        storage.withLock { $0.entries[id]?.isNamed ?? false }
    }

    /// Marks `read` as found under `id`, in place. An ID that is not a named fragment is not marked, since the check
    /// counts only named fragments.
    func markFound(_ id: String, _ read: KrakenReadLength) {
        storage.withLock { $0.markFound(id, read) }
    }

    /// Marks the two mates of a pair as found under `id`.
    func markFound(_ id: String, mate1: KrakenReadLength, mate2: KrakenReadLength) {
        storage.withLock { storage in
            storage.markFound(id, mate1)
            storage.markFound(id, mate2)
        }
    }

    /// The tally of the named fragments: found with the lengths kraken2 recorded, missing, or found with another length.
    func tally() -> KrakenReadCheck {
        storage.withLock { $0.tally() }
    }

    // MARK: - Storage

    /// The lists of a fragment that does not fit its value.
    private struct Spill {
        var expected: [KrakenReadLength]
        var found: [KrakenReadLength]
    }

    private struct Storage {
        var entries: [String: Entry] = [:]
        var spilled: [String: Spill] = [:]

        mutating func record(_ id: String, expected: [KrakenReadLength]?) {
            guard let expected else {
                if entries[id] == nil { entries[id] = Entry() }
                return
            }
            var unplaced: [KrakenReadLength] = []
            entries[id, default: Entry()].record(expected, unplaced: &unplaced)
            if !unplaced.isEmpty { spill(id, expected: unplaced) }
        }

        mutating func markFound(_ id: String, _ read: KrakenReadLength) {
            guard let index = entries.index(forKey: id), entries.values[index].isNamed else { return }
            if entries.values[index].isSpilled {
                spilled[id]?.found.append(read)
            } else if !entries.values[index].appendFound(read) {
                spill(id, found: [read])
            }
        }

        func tally() -> KrakenReadCheck {
            var check = KrakenReadCheck()
            for (id, entry) in entries where entry.isNamed {
                if entry.isSpilled, let lists = spilled[id] {
                    check.add(expected: lists.expected, found: lists.found)
                } else {
                    check.add(expected: entry.expectedReads, found: entry.foundReads)
                }
            }
            return check
        }

        /// Moves the fragment `id` to the lists, with what its value holds, and adds `expected` and `found` to them.
        private mutating func spill(_ id: String, expected: [KrakenReadLength] = [], found: [KrakenReadLength] = []) {
            guard let entry = entries[id] else { return }
            var lists = spilled[id] ?? Spill(expected: entry.expectedReads, found: entry.foundReads)
            lists.expected += expected
            lists.found += found
            spilled[id] = lists
            entries[id]?.bits |= Entry.spilledBit
        }
    }

    // MARK: - One fragment

    /// Up to two lengths kraken2 recorded and up to two lengths found, in the order they came, with the mate of each
    /// (0 for none). `bits` holds, from the lowest: the expected count (2 bits), the found count (2), the expected mates
    /// (2 each), the found mates (2 each), then the flags for a named fragment and for one that spilled.
    private struct Entry {
        var expected0: UInt32 = 0
        var expected1: UInt32 = 0
        var found0: UInt32 = 0
        var found1: UInt32 = 0
        var bits: UInt16 = 0

        static let namedBit: UInt16 = 1 << 12
        static let spilledBit: UInt16 = 1 << 13

        var isNamed: Bool { bits & Entry.namedBit != 0 }
        var isSpilled: Bool { bits & Entry.spilledBit != 0 }
        var expectedCount: Int { Int(bits & 3) }
        var foundCount: Int { Int(bits >> 2 & 3) }

        /// The two-bit code of a mate, or nil for a mate that is neither none, 1 nor 2.
        private static func code(_ mate: Int?) -> UInt16? {
            switch mate {
            case nil: return 0
            case 1?: return 1
            case 2?: return 2
            default: return nil
            }
        }

        private static func mate(_ code: UInt16) -> Int? {
            code == 0 ? nil : Int(code)
        }

        /// Names the fragment and places each of `reads` in a free expected slot, in order. From the first that fits no
        /// slot, that one and every later one goes to `unplaced`, so the lists keep their order.
        mutating func record(_ reads: [KrakenReadLength], unplaced: inout [KrakenReadLength]) {
            bits |= Entry.namedBit
            var placing = !isSpilled
            for read in reads {
                if placing, appendExpected(read) { continue }
                placing = false
                unplaced.append(read)
            }
            if !placing { bits |= Entry.spilledBit }
        }

        private mutating func appendExpected(_ read: KrakenReadLength) -> Bool {
            guard let code = Entry.code(read.mate), let length = UInt32(exactly: read.length) else { return false }
            switch expectedCount {
            case 0:
                expected0 = length
                bits |= code << 4
            case 1:
                expected1 = length
                bits |= code << 6
            default:
                return false
            }
            bits += 1
            return true
        }

        /// Places `read` in a free found slot, or returns false when it fits none.
        mutating func appendFound(_ read: KrakenReadLength) -> Bool {
            guard let code = Entry.code(read.mate), let length = UInt32(exactly: read.length) else { return false }
            switch foundCount {
            case 0:
                found0 = length
                bits |= code << 8
            case 1:
                found1 = length
                bits |= code << 10
            default:
                return false
            }
            bits += 4
            return true
        }

        var expectedReads: [KrakenReadLength] {
            var reads: [KrakenReadLength] = []
            if expectedCount > 0 { reads.append(KrakenReadLength(mate: Entry.mate(bits >> 4 & 3), length: Int(expected0))) }
            if expectedCount > 1 { reads.append(KrakenReadLength(mate: Entry.mate(bits >> 6 & 3), length: Int(expected1))) }
            return reads
        }

        var foundReads: [KrakenReadLength] {
            var reads: [KrakenReadLength] = []
            if foundCount > 0 { reads.append(KrakenReadLength(mate: Entry.mate(bits >> 8 & 3), length: Int(found0))) }
            if foundCount > 1 { reads.append(KrakenReadLength(mate: Entry.mate(bits >> 10 & 3), length: Int(found1))) }
            return reads
        }
    }
}
