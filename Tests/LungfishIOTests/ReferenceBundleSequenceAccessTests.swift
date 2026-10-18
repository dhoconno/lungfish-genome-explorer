// ReferenceBundleSequenceAccessTests.swift - One name index and one sequence reader per open bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishIO

/// The body `ReferenceBundle.chromosome(named:)` had before the name index, kept as the oracle.
private func linearScanChromosome(named name: String, in chromosomes: [ChromosomeInfo]) -> ChromosomeInfo? {
    if let exact = chromosomes.first(where: { $0.name == name || $0.aliases.contains(name) }) {
        return exact
    }
    guard let mappedName = mapVCFChromosomes([name], toBundleChromosomes: chromosomes)[name] else {
        return nil
    }
    return chromosomes.first { $0.name == mappedName }
}

final class ReferenceBundleSequenceAccessTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceBundleSequenceAccessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Name resolution

    /// Eight records whose names and aliases collide in each way the lookup order decides.
    /// Every length differs, so a length names the record a lookup returned.
    private static let lookupRecords: [ChromosomeInfo] = [
        ChromosomeInfo(name: "chr1", length: 101, offset: 6, lineBases: 60, lineWidth: 61, aliases: ["1"]),
        ChromosomeInfo(name: "chr2", length: 102, offset: 6, lineBases: 60, lineWidth: 61, aliases: ["2", "chrX"]),
        ChromosomeInfo(name: "chrX", length: 103, offset: 6, lineBases: 60, lineWidth: 61),
        ChromosomeInfo(name: "MN908947", length: 104, offset: 6, lineBases: 60, lineWidth: 61),
        ChromosomeInfo(
            name: "NC_041754.1", length: 105, offset: 6, lineBases: 60, lineWidth: 61,
            fastaDescription: "Macaca mulatta chromosome 7"
        ),
        ChromosomeInfo(name: "contigA", length: 106, offset: 6, lineBases: 60, lineWidth: 61, aliases: ["shared"]),
        ChromosomeInfo(name: "contigB", length: 107, offset: 6, lineBases: 60, lineWidth: 61, aliases: ["shared"]),
        ChromosomeInfo(name: "contigA", length: 108, offset: 6, lineBases: 60, lineWidth: 61),
    ]

    /// Every name, every alias, and the names only the fallback resolves or nothing resolves.
    private static var lookupProbes: [String] {
        let names = lookupRecords.map(\.name)
        let aliases = lookupRecords.flatMap(\.aliases)
        return names + aliases + ["MN908947.3", "X", "7", "nope"]
    }

    /// A bundle over `lookupRecords` with no files behind it, enough for name lookups.
    private func makeLookupBundle() -> ReferenceBundle {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Lookup",
            identifier: "test.lookup",
            source: SourceInfo(organism: "Test organism", assembly: "Lookup", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Self.lookupRecords.reduce(0) { $0 + $1.length },
                chromosomes: Self.lookupRecords
            )
        )
        return ReferenceBundle(url: tempDirectory.appendingPathComponent("Lookup.lungfishref"), manifest: manifest)
    }

    func testChromosomeNamedMatchesTheLinearScan() {
        let bundle = makeLookupBundle()

        for probe in Self.lookupProbes {
            let found = bundle.chromosome(named: probe)
            let expected = linearScanChromosome(named: probe, in: Self.lookupRecords)
            XCTAssertEqual(found?.name, expected?.name, "name for \(probe)")
            XCTAssertEqual(found?.length, expected?.length, "length for \(probe)")
            XCTAssertEqual(bundle.chromosomeLength(named: probe), expected?.length, "chromosomeLength for \(probe)")
        }

        // The rules the oracle encodes, spelled out.
        XCTAssertEqual(bundle.chromosome(named: "chrX")?.length, 102, "An alias on an earlier record wins over a later name.")
        XCTAssertEqual(bundle.chromosome(named: "X")?.length, 103, "The chr prefix fallback finds the record named chrX.")
        XCTAssertEqual(bundle.chromosome(named: "7")?.name, "NC_041754.1", "The description fallback finds chromosome 7.")
        XCTAssertEqual(bundle.chromosome(named: "MN908947.3")?.name, "MN908947", "The version fallback strips .3.")
        XCTAssertEqual(bundle.chromosome(named: "shared")?.length, 106, "The first record with a shared alias wins.")
        XCTAssertEqual(bundle.chromosome(named: "contigA")?.length, 106, "The first record with a repeated name wins.")
        XCTAssertNil(bundle.chromosome(named: "nope"))
    }

    func testLookupsBuildTheNameIndexOnceAndNeverParseTheFai() {
        let bundle = makeLookupBundle()
        let keys = Self.lookupRecords.map(\.name) + Self.lookupRecords.flatMap(\.aliases)

        for lookup in 0..<100 {
            XCTAssertNotNil(bundle.chromosome(named: keys[lookup % keys.count]))
        }

        XCTAssertEqual(bundle.sequenceCache.nameIndexBuildCount, 1)
        XCTAssertEqual(bundle.sequenceCache.fallbackRunCount, 0)
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 0)
    }

    func testFallbackRunsOncePerMissingName() {
        let bundle = makeLookupBundle()

        for _ in 0..<3 {
            for probe in ["MN908947.3", "nope"] {
                let expected = linearScanChromosome(named: probe, in: Self.lookupRecords)
                XCTAssertEqual(bundle.chromosome(named: probe), expected, "answer for \(probe)")
            }
        }

        XCTAssertEqual(bundle.sequenceCache.fallbackRunCount, 2)
        XCTAssertEqual(bundle.sequenceCache.nameIndexBuildCount, 1)
    }

    func testFirstChromosomeNameIsTheFirstManifestRecord() {
        let bundle = makeLookupBundle()

        XCTAssertEqual(bundle.firstChromosomeName, "chr1")
        XCTAssertEqual(bundle.firstChromosomeName, bundle.chromosomeNames.first)
    }

    // MARK: - Sequence fetches

    /// Three records wrapped at 20 bases, so most reads cross a line break.
    /// MN908947 holds the first 40 bases of SARS-CoV-2 Wuhan-Hu-1.
    private static let sequenceRecords: [(name: String, aliases: [String], bases: String)] = [
        ("chr1", ["1"], "ACGTTGCAACGGATCTTAGCCATGACTGGTACCATTGCAGTCAAGCTTGACGGTATCCGA"),
        ("chr2", [], "TTGACCAGTAGGCATCGATCCGTAAGTCTTGCAGGATCAATGCCATTAGG"),
        ("MN908947", [], "ATTAAAGGTTTATACCTTCCCAGGTAACAAACCAACCAAC"),
    ]

    /// The bases a fetch must return, cut from the records rather than read back.
    private static func bases(of name: String, _ range: Range<Int>) -> String {
        let record = sequenceRecords.first { $0.name == name }!
        return String(Array(record.bases)[range])
    }

    /// The records as FASTA wrapped at `lineBases`, with each `.fai` line taken from the bytes written.
    private static func fastaLayout(lineBases: Int) -> (fasta: Data, fai: String, chromosomes: [ChromosomeInfo]) {
        var fasta = Data()
        var fai = ""
        var chromosomes: [ChromosomeInfo] = []
        for record in sequenceRecords {
            fasta.append(contentsOf: Array(">\(record.name)\n".utf8))
            let offset = fasta.count
            var remaining = Substring(record.bases)
            while !remaining.isEmpty {
                fasta.append(contentsOf: Array(remaining.prefix(lineBases).utf8) + [0x0a])
                remaining = remaining.dropFirst(lineBases)
            }
            fai += "\(record.name)\t\(record.bases.count)\t\(offset)\t\(lineBases)\t\(lineBases + 1)\n"
            chromosomes.append(ChromosomeInfo(
                name: record.name, length: Int64(record.bases.count), offset: Int64(offset),
                lineBases: lineBases, lineWidth: lineBases + 1, aliases: record.aliases
            ))
        }
        return (fasta, fai, chromosomes)
    }

    /// A bundle over `sequenceRecords`, bgzip-compressed with a `.gzi` index or plain.
    private func makeSequenceBundle(compressed: Bool) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent(compressed ? "Bgzip.lungfishref" : "Plain.lungfishref")
        let genomeDir = bundleURL.appendingPathComponent("genome")
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let layout = Self.fastaLayout(lineBases: 20)
        let fastaName = compressed ? "sequence.fa.gz" : "sequence.fa"
        if compressed {
            try bgzf(layout.fasta).write(to: genomeDir.appendingPathComponent(fastaName))
            // The data fits one block, and a .gzi lists only the blocks after the first.
            try Data(count: 8).write(to: genomeDir.appendingPathComponent("\(fastaName).gzi"))
        } else {
            try layout.fasta.write(to: genomeDir.appendingPathComponent(fastaName))
        }
        try layout.fai.write(to: genomeDir.appendingPathComponent("\(fastaName).fai"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: compressed ? "Bgzip" : "Plain",
            identifier: compressed ? "test.bgzip" : "test.plain",
            source: SourceInfo(organism: "Test organism", assembly: "Fetch", database: "Test"),
            genome: GenomeInfo(
                path: "genome/\(fastaName)",
                indexPath: "genome/\(fastaName).fai",
                gzipIndexPath: compressed ? "genome/\(fastaName).gzi" : nil,
                totalLength: layout.chromosomes.reduce(0) { $0 + $1.length },
                chromosomes: layout.chromosomes
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    /// One BGZF block holding `payload`, then the empty block bgzip ends every file with.
    private func bgzf(_ payload: Data) throws -> Data {
        let deflated = try (payload as NSData).compressed(using: .zlib) as Data
        var block = Data([0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0, 0xff, 6, 0, 0x42, 0x43, 2, 0])
        appendLittleEndian(UInt16(18 + deflated.count + 8 - 1), to: &block)
        block.append(deflated)
        appendLittleEndian(crc32(payload), to: &block)
        appendLittleEndian(UInt32(payload.count), to: &block)
        block.append(Data([0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0, 0xff, 6, 0, 0x42, 0x43, 2, 0, 0x1b, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        return block
    }

    private func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    func testFetchesParseTheIndexOncePerBundle() async throws {
        let bundle = try await ReferenceBundle(url: try makeSequenceBundle(compressed: true))

        let first = try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: 5, end: 47))
        let second = try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "MN908947", start: 0, end: 30))
        let third = try await bundle.fetchSequence(region: GenomicRegion(chromosome: "1", start: 18, end: 41))
        let fourth = try await bundle.fetchSequence(region: GenomicRegion(chromosome: "MN908947", start: 12, end: 33))

        XCTAssertEqual(first, Self.bases(of: "chr1", 5..<47))
        XCTAssertEqual(second, Self.bases(of: "MN908947", 0..<30))
        XCTAssertEqual(third, Self.bases(of: "chr1", 18..<41), "The alias 1 reads the record chr1.")
        XCTAssertEqual(fourth, Self.bases(of: "MN908947", 12..<33))
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 1)
    }

    func testConcurrentFirstFetchesBuildTheReaderOnce() async throws {
        let bundle = try await ReferenceBundle(url: try makeSequenceBundle(compressed: true))
        let region = GenomicRegion(chromosome: "chr2", start: 3, end: 40)

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask { try await bundle.fetchSequence(region: region) }
            }
            var results: [String] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(results, Array(repeating: Self.bases(of: "chr2", 3..<40), count: 16))
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 1)
    }

    func testUncompressedBundleReadsThroughTheCache() async throws {
        let bundleURL = try makeSequenceBundle(compressed: false)
        let bundle = try await ReferenceBundle(url: bundleURL)
        let genomeDir = bundleURL.appendingPathComponent("genome")
        let reference = try IndexedFASTAReader(
            url: genomeDir.appendingPathComponent("sequence.fa"),
            indexURL: genomeDir.appendingPathComponent("sequence.fa.fai")
        )
        let whole = GenomicRegion(chromosome: "chr2", start: 0, end: 50)
        let acrossALineBreak = GenomicRegion(chromosome: "chr1", start: 19, end: 22)

        let fetchedWhole = try bundle.fetchSequenceSync(region: whole)
        let fetchedAcross = try await bundle.fetchSequence(region: acrossALineBreak)

        XCTAssertEqual(fetchedWhole, try reference.fetchSync(region: whole))
        XCTAssertEqual(fetchedAcross, try reference.fetchSync(region: acrossALineBreak))
        XCTAssertEqual(fetchedWhole, Self.bases(of: "chr2", 0..<50))
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 1)
    }

    func testAFailedReaderBuildIsNotKept() async throws {
        let bundleURL = try makeSequenceBundle(compressed: false)
        let bundle = try await ReferenceBundle(url: bundleURL)
        let faiURL = bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        let fai = try Data(contentsOf: faiURL)
        try FileManager.default.removeItem(at: faiURL)
        let region = GenomicRegion(chromosome: "chr1", start: 0, end: 10)

        for _ in 0..<2 {
            XCTAssertThrowsError(try bundle.fetchSequenceSync(region: region)) { error in
                guard case FASTAError.indexNotFound = error else {
                    return XCTFail("A missing .fai throws indexNotFound, not \(error)")
                }
            }
        }
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 0)

        try fai.write(to: faiURL)
        XCTAssertEqual(try bundle.fetchSequenceSync(region: region), Self.bases(of: "chr1", 0..<10))
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 1)
    }

    func testPrepareSequenceAccessBuildsTheIndexAndTheReaderOnce() async throws {
        let bundle = try await ReferenceBundle(url: try makeSequenceBundle(compressed: true))

        try bundle.prepareSequenceAccess()
        try bundle.prepareSequenceAccess()
        XCTAssertEqual(bundle.sequenceCache.nameIndexBuildCount, 1)
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 1)

        let fetched = try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr2", start: 10, end: 30))
        XCTAssertEqual(fetched, Self.bases(of: "chr2", 10..<30))
        XCTAssertEqual(bundle.sequenceCache.nameIndexBuildCount, 1)
        XCTAssertEqual(bundle.sequenceCache.readerBuildCount, 1)
    }
}
