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
        /// Whether `taxIds` lists every tax ID of the clade, false when the root has more than `limit` descendants.
        public let listsEveryTaxId: Bool
    }

    /// The clade of `taxId`, or nil when `nodes.dmp` is missing or does not hold `taxId`. An ID NCBI merged into another is
    /// not in `nodes.dmp`, so `merged.dmp`, when present, names the ID it became, and the clade is that ID's. `path` then
    /// starts at the new ID.
    ///
    /// A species whose scientific name ends in " sp.", such as "Human rhinovirus sp.", is NCBI's catch-all for records
    /// whose species nobody named, so it roots no clade (BLAST-CATCHALL-SPECIES). A claim below it is judged at the
    /// claimed taxon and its own descendants, and a claim on it keeps none of its children, since they need not be one
    /// species. Its name is read from `names.dmp`, and without that file every species roots its clade.
    ///
    /// - Parameter limit: The most descendants of the root the clade lists, which keeps the `--accepted-taxid` pairs of
    ///   `blast submit` well under the argv limit. A root with more keeps only `path`, and the name rule of
    ///   `BlastTaxonMatching` still takes a strain record that holds a path name.
    public static func speciesClade(of taxId: Int, taxonomyDirectory: URL, limit: Int = 5_000) -> SpeciesClade? {
        guard let found = nodeTable(holding: taxId, taxonomyDirectory: taxonomyDirectory) else { return nil }
        let path = found.table.pathToSpecies(from: found.taxId)
        let speciesRoot = path.last ?? found.taxId
        let rootName = scanScientificNames(of: [speciesRoot], holding: [], taxonomyDirectory: taxonomyDirectory).names[speciesRoot]
        return buildClade(of: found.taxId, speciesPath: path, in: found.table, speciesName: rootName, limit: limit)
    }

    /// The taxonomy a BLAST claim of `taxId` is judged against at species level, or nil when the directory is nil, the
    /// tax ID is 0 or less, or the taxonomy does not hold it, so the caller keeps its own `[taxId]`.
    ///
    /// When the clade lists every tax ID, a hit's tax ID decides, and names judge only an ID the dump lacks, such as a
    /// strain newer than the dump. The clade names are then `names`, the row's own, less any name that the scientific
    /// name of a taxon outside the clade holds as a whole phrase, so no record the dump files in another species, such
    /// as Woolly monkey hepatitis B virus for a Hepatitis B virus row, matches by name. No path name judges
    /// (BLAST-NAME-PHRASE-LEAK, BLAST-LINEAGE-PATH-NAMES). When the species has more descendants than `limit` (Influenza A
    /// and B and Norovirus in the dump of 2026-10-09), names must judge its strains, so the clade names are `names` and
    /// the path's names, less any that a taxon outside the species root holds as a whole phrase, unless every such
    /// taxon sits under 28384 other sequences: Influenza A keeps "Influenza A virus", whose one outside holder is the
    /// lab construct synthetic Influenza A virus, and a Bat norovirus row drops "Bat norovirus", which Jingmen bat
    /// norovirus 1, another Norovirus species, holds (BIO-BLAST ruling A). The clade has no relatives, as a route with no
    /// tree has none. Its basis is `species` (BLAST-ESVIRITU-FIRST-WORD), and a caller that falls back to the row's own
    /// tax ID or name sets its own.
    public static func blastTaxonomyContext(
        of taxId: Int,
        names: [String],
        taxonomyDirectory: URL?,
        limit: Int = 5_000
    ) -> BlastTaxonomyContext? {
        guard let taxonomyDirectory, let found = nodeTable(holding: taxId, taxonomyDirectory: taxonomyDirectory)
        else { return nil }
        let path = found.table.pathToSpecies(from: found.taxId)
        let scan = scanScientificNames(of: Set(path), holding: names, taxonomyDirectory: taxonomyDirectory)
        let clade = buildClade(
            of: found.taxId, speciesPath: path, in: found.table, speciesName: scan.names[path.last ?? found.taxId], limit: limit
        )
        guard clade.listsEveryTaxId else {
            var accepted = names
            for id in clade.path {
                if let name = scan.names[id], !accepted.contains(name) { accepted.append(name) }
            }
            // One more pass finds the taxa that hold each path name, and a name a taxon outside the species holds
            // judges nothing, unless every such taxon is a construct under 28384 other sequences (BIO-BLAST ruling A).
            let pathNames = Array(accepted.dropFirst(names.count))
            let holders = scan.holders + (pathNames.isEmpty ? [] : scanScientificNames(
                of: [], holding: pathNames, taxonomyDirectory: taxonomyDirectory
            ).holders)
            let judging = accepted.indices.filter { index in
                holders[index].allSatisfy { found.table.isUnder($0, clade.root) || found.table.isUnder($0, otherSequences) }
            }.map { accepted[$0] }
            return BlastTaxonomyContext(cladeTaxIds: clade.taxIds, cladeNames: judging, basis: .species)
        }
        let judging = names.indices.filter { scan.holders[$0].allSatisfy(clade.taxIds.contains) }.map { names[$0] }
        return BlastTaxonomyContext(cladeTaxIds: clade.taxIds, cladeNames: judging, basis: .species)
    }

    /// The table of one read of `nodes.dmp` and the ID `taxId` stands under there, its own or the one `merged.dmp` says
    /// it became, or nil when the file is missing or holds neither.
    private static func nodeTable(holding taxId: Int, taxonomyDirectory: URL) -> (table: NodeTable, taxId: Int)? {
        guard taxId > 0, taxId < largestTaxId,
              let dump = try? Data(contentsOf: taxonomyDirectory.appendingPathComponent("nodes.dmp"), options: .mappedIfSafe)
        else { return nil }
        let table = NodeTable(dump: dump)
        guard let current = table.holds(taxId) ? taxId : mergedTaxId(of: taxId, taxonomyDirectory: taxonomyDirectory),
              table.holds(current)
        else { return nil }
        return (table, current)
    }

    /// The clade of `taxId` from its path up to the nearest species, with the catch-all rule of ``speciesClade(of:taxonomyDirectory:limit:)``.
    private static func buildClade(
        of taxId: Int, speciesPath: [Int], in table: NodeTable, speciesName: String?, limit: Int
    ) -> SpeciesClade {
        let speciesRoot = speciesPath.last ?? taxId
        let isCatchAll = speciesName?.hasSuffix(" sp.") ?? false
        if isCatchAll, taxId == speciesRoot {
            return SpeciesClade(root: taxId, path: [taxId], taxIds: [taxId], listsEveryTaxId: true)
        }
        let path = isCatchAll ? [taxId] : speciesPath
        let root = path.last ?? taxId
        let descendants = table.descendants(of: root, limit: limit)
        return SpeciesClade(
            root: root, path: path, taxIds: Set(path).union(descendants ?? []), listsEveryTaxId: descendants != nil
        )
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

    /// One pass over the scientific names of `names.dmp`: the names of `taxIds`, and for each of `phrases` the IDs whose
    /// name holds it as a whole phrase, in any case, as ``BlastTaxonMatching`` reads a hit's organism. With no phrase
    /// it stops once it has every name it wants, and it decodes only the rows it keeps, where
    /// `TaxonomyNameResolver.resolveFromFile` decodes every chunk of the 317 MB file. A missing file gives nothing.
    private static func scanScientificNames(
        of taxIds: Set<Int>, holding phrases: [String], taxonomyDirectory: URL
    ) -> (names: [Int: String], holders: [[Int]]) {
        var holders = Array(repeating: [Int](), count: phrases.count)
        guard let dump = try? Data(contentsOf: taxonomyDirectory.appendingPathComponent("names.dmp"), options: .mappedIfSafe)
        else { return ([:], holders) }
        let needles = phrases.map { Array($0.lowercased().trimmingCharacters(in: .whitespaces).utf8) }
        let nameClass: StaticString = "\t|\tscientific name\t|"
        var found: [Int: String] = [:]
        var lowered: [UInt8] = []
        forEachLine(of: dump) { bytes, start, end in
            var cursor = start
            guard let id = readNumber(bytes, &cursor, end), needles.isEmpty ? taxIds.contains(id) : true,
                  skipSeparator(bytes, &cursor, end),
                  end - cursor > nameClass.utf8CodeUnitCount,
                  memcmp(bytes + end - nameClass.utf8CodeUnitCount, nameClass.utf8Start, nameClass.utf8CodeUnitCount) == 0,
                  let tab = memchr(bytes + cursor, 0x09, end - cursor)
            else { return true }
            let length = UnsafePointer(bytes + cursor).distance(to: tab.assumingMemoryBound(to: UInt8.self))
            if taxIds.contains(id) {
                found[id] = String(decoding: UnsafeBufferPointer(start: bytes + cursor, count: length), as: UTF8.self)
            }
            guard !needles.isEmpty else { return found.count < taxIds.count }
            lowered.removeAll(keepingCapacity: true)
            for offset in 0..<length {
                let byte = bytes[cursor + offset]
                lowered.append(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte)
            }
            for (index, needle) in needles.enumerated() where holdsPhrase(lowered, needle) {
                holders[index].append(id)
            }
            return true
        }
        return (found, holders)
    }

    /// Whether lower-case `text` holds `phrase` with no letter or digit on either side, the bytes of
    /// `BlastTaxonMatching.containsPhrase`. A byte of a multi-byte character counts as a letter.
    private static func holdsPhrase(_ text: [UInt8], _ phrase: [UInt8]) -> Bool {
        guard let first = phrase.first, text.count >= phrase.count else { return false }
        func isWordByte(_ byte: UInt8) -> Bool { (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || byte >= 0x80 }
        var start = 0
        while start <= text.count - phrase.count {
            if text[start] == first, text[start..<(start + phrase.count)].elementsEqual(phrase),
               start == 0 || !isWordByte(text[start - 1]),
               start + phrase.count == text.count || !isWordByte(text[start + phrase.count]) {
                return true
            }
            start += 1
        }
        return false
    }

    // MARK: - The rows of a dump

    /// A row beyond this ID is not a real tax ID and is skipped, so a broken file sizes the four arrays of one read at
    /// about 220 MB at most.
    private static let largestTaxId = 1 << 24

    /// NCBI's "other sequences" (28384), where artificial sequences such as synthetic Influenza A virus (1522430) sit.
    /// Their records are sequence of the organism made in a lab, so a name only they hold outside the species still
    /// judges (BIO-BLAST ruling A, backlog BLAST-SYNTHETIC-SUPPORT).
    private static let otherSequences = 28384

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

        /// Whether `taxId` is `ancestor` or below it, false for an ID with no row or a walk that never reaches it.
        func isUnder(_ taxId: Int, _ ancestor: Int) -> Bool {
            var current = taxId
            for _ in 0..<Self.deepestLineage {
                if current == ancestor { return true }
                guard holds(current) else { return false }
                let parent = Int(parents[current])
                guard parent != current else { return false }
                current = parent
            }
            return false
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
