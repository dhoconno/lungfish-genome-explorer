// NCBITaxonomyLineage.swift - The species clade a BLAST claim is judged at, read from a local NCBI nodes.dmp
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The tax IDs BLAST verification accepts for a claimed taxon, read from a local NCBI `nodes.dmp`.
///
/// BLAST Verify calls a read verified at 90% identity and 80% coverage, which cannot split host groups, genotypes or
/// strains, so a claim is judged at species level (BIO-BLAST-CLADE Q2). The clade root is the taxon's nearest species-rank
/// ancestor, or the taxon itself when it is at species rank or has no species above it. A record filed above the root,
/// such as the genus, stays outside.
///
/// This type only reads the files. It never downloads, and a missing file or an unknown tax ID is nil, never an error, so
/// a caller keeps the taxon's own tax ID. One read walks a whole file, so call it off the main actor.
public enum NCBITaxonomyLineage {

    /// The clade of one claimed taxon.
    public struct SpeciesClade: Sendable, Equatable {
        /// The nearest species-rank ancestor of the taxon, or the taxon itself at or above species.
        public let root: Int
        /// The taxon and its ancestors up to `root`, taxon first.
        public let path: [Int]
        /// `path`, plus every descendant of `root` when there are at most `limit` of them.
        public let taxIds: Set<Int>
    }

    /// The clade of `taxId`, or nil when `nodes.dmp` is missing or does not hold `taxId`. An ID NCBI merged into another is
    /// not in `nodes.dmp`, so `merged.dmp`, when present, names the ID it became, and the clade is that ID's. `path` then
    /// starts at the new ID.
    ///
    /// - Parameter limit: The most descendants of the root the clade lists, which keeps the `--accepted-taxid` pairs of
    ///   `blast submit` well under the argv limit. A root with more keeps only `path`, and the name rule of
    ///   `BlastTaxonMatching` still takes a strain record that holds a path name.
    public static func speciesClade(of taxId: Int, taxonomyDirectory: URL, limit: Int = 5_000) -> SpeciesClade? {
        guard taxId > 0, taxId < largestTaxId,
              let dump = try? Data(contentsOf: taxonomyDirectory.appendingPathComponent("nodes.dmp"), options: .mappedIfSafe)
        else { return nil }
        let table = NodeTable(dump: dump)
        guard let current = table.holds(taxId) ? taxId : mergedTaxId(of: taxId, taxonomyDirectory: taxonomyDirectory),
              table.holds(current)
        else { return nil }

        let path = table.pathToSpecies(from: current)
        let root = path.last ?? current
        var taxIds = Set(path)
        if let descendants = table.descendants(of: root, limit: limit) {
            taxIds.formUnion(descendants)
        }
        return SpeciesClade(root: root, path: path, taxIds: taxIds)
    }

    /// The taxonomy a BLAST claim of `taxId` is judged against at species level, or nil when the directory is nil, the
    /// tax ID is 0 or less, or the taxonomy does not hold it, so the caller keeps its own `[taxId]`.
    ///
    /// The clade names are `names`, the row's own, then the scientific names of the path that `names.dmp` holds. A path
    /// name puts "Rotavirus A" beside "Human rotavirus A", so a strain record the clade does not list still counts when
    /// its organism holds one. The clade has no relatives, as a route with no tree has none.
    public static func blastTaxonomyContext(
        of taxId: Int,
        names: [String],
        taxonomyDirectory: URL?,
        limit: Int = 5_000
    ) -> BlastTaxonomyContext? {
        guard let taxonomyDirectory,
              let clade = speciesClade(of: taxId, taxonomyDirectory: taxonomyDirectory, limit: limit)
        else { return nil }
        let pathNames = scientificNames(of: clade.path, taxonomyDirectory: taxonomyDirectory)
        var accepted = names
        for id in clade.path {
            if let name = pathNames[id], !accepted.contains(name) { accepted.append(name) }
        }
        return BlastTaxonomyContext(cladeTaxIds: clade.taxIds, cladeNames: accepted)
    }

    // MARK: - merged.dmp

    /// The ID `merged.dmp` says `taxId` became, nil when the file is missing or has no row for it. It reads one step.
    private static func mergedTaxId(of taxId: Int, taxonomyDirectory: URL) -> Int? {
        guard let dump = try? Data(contentsOf: taxonomyDirectory.appendingPathComponent("merged.dmp"), options: .mappedIfSafe)
        else { return nil }
        var merged: Int?
        forEachLine(of: dump) { bytes, start, end in
            var cursor = start
            guard readNumber(bytes, &cursor, end) == taxId, skipSeparator(bytes, &cursor, end) else { return true }
            merged = readNumber(bytes, &cursor, end)
            return false
        }
        return merged
    }

    // MARK: - names.dmp

    /// The scientific names of `taxIds` that `names.dmp` holds, none when the file is missing. It takes only the few IDs
    /// of a path, so it looks at each row's first field and decodes only the rows it keeps, where
    /// `TaxonomyNameResolver.resolveFromFile` decodes every chunk of the 317 MB file.
    private static func scientificNames(of taxIds: [Int], taxonomyDirectory: URL) -> [Int: String] {
        guard let dump = try? Data(contentsOf: taxonomyDirectory.appendingPathComponent("names.dmp"), options: .mappedIfSafe)
        else { return [:] }
        let wanted = Set(taxIds)
        let nameClass: StaticString = "\t|\tscientific name\t|"
        var found: [Int: String] = [:]
        forEachLine(of: dump) { bytes, start, end in
            var cursor = start
            guard let id = readNumber(bytes, &cursor, end), wanted.contains(id),
                  skipSeparator(bytes, &cursor, end),
                  end - cursor > nameClass.utf8CodeUnitCount,
                  memcmp(bytes + end - nameClass.utf8CodeUnitCount, nameClass.utf8Start, nameClass.utf8CodeUnitCount) == 0,
                  let tab = memchr(bytes + cursor, 0x09, end - cursor)
            else { return true }
            let length = UnsafePointer(bytes + cursor).distance(to: tab.assumingMemoryBound(to: UInt8.self))
            found[id] = String(decoding: UnsafeBufferPointer(start: bytes + cursor, count: length), as: UTF8.self)
            return found.count < wanted.count
        }
        return found
    }

    // MARK: - The rows of a dump

    /// A row beyond this ID is not a real tax ID and is skipped, so a broken file sizes the four arrays of one read at
    /// about 220 MB at most.
    private static let largestTaxId = 1 << 24

    /// Calls `body` with the offsets of each line until it returns false.
    private static func forEachLine(of dump: Data, _ body: (UnsafePointer<UInt8>, Int, Int) -> Bool) {
        dump.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var start = 0
            while start < raw.count {
                let newline = memchr(bytes + start, 0x0A, raw.count - start)
                let end = newline.map { bytes.distance(to: UnsafePointer($0.assumingMemoryBound(to: UInt8.self))) } ?? raw.count
                guard body(bytes, start, end) else { return }
                start = end + 1
            }
        }
    }

    private static func readNumber(_ bytes: UnsafePointer<UInt8>, _ cursor: inout Int, _ end: Int) -> Int? {
        var value = 0
        let first = cursor
        while cursor < end, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39, cursor - first < 10 {
            value = value * 10 + Int(bytes[cursor] - 0x30)
            cursor += 1
        }
        return cursor == first ? nil : value
    }

    /// Skips the `\t|\t` between two fields.
    private static func skipSeparator(_ bytes: UnsafePointer<UInt8>, _ cursor: inout Int, _ end: Int) -> Bool {
        guard cursor + 2 < end, bytes[cursor] == 0x09, bytes[cursor + 1] == 0x7C, bytes[cursor + 2] == 0x09 else {
            return false
        }
        cursor += 3
        return true
    }

    // MARK: - The table of one read

    /// The parent and species flag of every row of one `nodes.dmp`, indexed by tax ID. The file holds about 2.7 million
    /// rows at IDs under 4 million, so flat arrays cost a fraction of a dictionary's time and memory.
    private struct NodeTable {
        /// NCBI's lineages run to about 50 ranks, so a longer walk is a loop in a broken file.
        private static let deepestLineage = 256

        /// The parent of each tax ID, 0 for an ID with no row.
        private var parents: [Int32] = Array(repeating: 0, count: 1 << 16)
        private var isSpecies: [Bool] = Array(repeating: false, count: 1 << 16)

        init(dump: Data) {
            forEachLine(of: dump) { bytes, start, end in
                readRow(bytes, from: start, to: end)
                return true
            }
        }

        /// Reads `id\t|\tparent\t|\trank\t|...` between two offsets. A row of any other shape is skipped.
        private mutating func readRow(_ bytes: UnsafePointer<UInt8>, from start: Int, to end: Int) {
            var cursor = start
            guard let id = readNumber(bytes, &cursor, end), skipSeparator(bytes, &cursor, end),
                  let parent = readNumber(bytes, &cursor, end), skipSeparator(bytes, &cursor, end),
                  id > 0, id < largestTaxId, parent > 0, parent < largestTaxId
            else { return }
            if id >= parents.count {
                let grown = max(id + 1, parents.count * 2)
                parents.append(contentsOf: repeatElement(0, count: grown - parents.count))
                isSpecies.append(contentsOf: repeatElement(false, count: grown - isSpecies.count))
            }
            parents[id] = Int32(parent)
            isSpecies[id] = Self.rankIsSpecies(bytes, cursor, end)
        }

        /// Whether the field at `cursor` is exactly `species`.
        private static func rankIsSpecies(_ bytes: UnsafePointer<UInt8>, _ cursor: Int, _ end: Int) -> Bool {
            let word: StaticString = "species"
            let length = word.utf8CodeUnitCount
            guard cursor + length < end, bytes[cursor + length] == 0x09 else { return false }
            return memcmp(bytes + cursor, word.utf8Start, length) == 0
        }

        func holds(_ taxId: Int) -> Bool {
            taxId > 0 && taxId < parents.count && parents[taxId] != 0
        }

        /// The taxon and its ancestors up to the nearest species, or the taxon alone when it is a species or has none above it.
        func pathToSpecies(from taxId: Int) -> [Int] {
            guard !isSpecies[taxId] else { return [taxId] }
            var path = [taxId]
            var current = taxId
            while path.count < Self.deepestLineage {
                let parent = Int(parents[current])
                guard parent != current, holds(parent) else { break }
                path.append(parent)
                if isSpecies[parent] { return path }
                current = parent
            }
            return [taxId]
        }

        /// Every descendant of `root` without `root`, or nil when there are more than `limit`.
        func descendants(of root: Int, limit: Int) -> [Int]? {
            var firstChild = [Int32](repeating: 0, count: parents.count)
            var nextSibling = [Int32](repeating: 0, count: parents.count)
            for id in 1..<parents.count where parents[id] != 0 && Int(parents[id]) != id {
                let parent = Int(parents[id])
                guard parent < parents.count else { continue }
                nextSibling[id] = firstChild[parent]
                firstChild[parent] = Int32(id)
            }
            var found: [Int] = []
            var pending = [root]
            while let id = pending.popLast() {
                var child = Int(firstChild[id])
                while child != 0 {
                    // Each pass counts one row, so a loop in a broken file ends at the limit.
                    guard found.count < limit else { return nil }
                    if child != root {
                        found.append(child)
                        pending.append(child)
                    }
                    child = Int(nextSibling[child])
                }
            }
            return found
        }
    }
}
