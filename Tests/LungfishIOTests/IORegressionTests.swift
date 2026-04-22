// IORegressionTests.swift - Regression tests for LungfishIO types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

// MARK: - QualityScore Tests

final class QualityScoreRegressionTests: XCTestCase {

    // MARK: - QualityEncoding

    func testPhred33AsciiOffset() {
        XCTAssertEqual(QualityEncoding.phred33.asciiOffset, 33)
    }

    func testPhred64AsciiOffset() {
        XCTAssertEqual(QualityEncoding.phred64.asciiOffset, 64)
    }

    func testSolexaAsciiOffset() {
        XCTAssertEqual(QualityEncoding.solexa.asciiOffset, 64)
    }

    func testPhred33MaxQuality() {
        XCTAssertEqual(QualityEncoding.phred33.maxQuality, 93)
    }

    func testPhred64MaxQuality() {
        XCTAssertEqual(QualityEncoding.phred64.maxQuality, 62)
    }

    func testPhred33MinAscii() {
        XCTAssertEqual(QualityEncoding.phred33.minAscii, 33) // '!'
    }

    func testPhred33MaxAscii() {
        XCTAssertEqual(QualityEncoding.phred33.maxAscii, 126) // '~'
    }

    func testDisplayNames() {
        XCTAssertTrue(QualityEncoding.phred33.displayName.contains("Sanger"))
        XCTAssertTrue(QualityEncoding.phred64.displayName.contains("1.3"))
        XCTAssertTrue(QualityEncoding.solexa.displayName.contains("deprecated"))
    }

    func testCaseIterable() {
        XCTAssertEqual(QualityEncoding.allCases.count, 3)
    }

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for encoding in QualityEncoding.allCases {
            let data = try encoder.encode(encoding)
            let decoded = try decoder.decode(QualityEncoding.self, from: data)
            XCTAssertEqual(encoding, decoded)
        }
    }

    // MARK: - QualityScore Construction

    func testFromAsciiPhred33() {
        // 'I' = ASCII 73, Phred+33 offset = 73-33 = 40
        let qs = QualityScore(ascii: "IIIII", encoding: .phred33)
        XCTAssertEqual(qs.count, 5)
        XCTAssertFalse(qs.isEmpty)
        XCTAssertEqual(qs.qualityAt(0), 40)
    }

    func testFromValues() {
        let qs = QualityScore(values: [10, 20, 30, 40], encoding: .phred33)
        XCTAssertEqual(qs.count, 4)
        XCTAssertEqual(qs.qualityAt(2), 30)
    }

    func testEmptyInit() {
        let qs = QualityScore()
        XCTAssertTrue(qs.isEmpty)
        XCTAssertEqual(qs.count, 0)
        XCTAssertEqual(qs.meanQuality, 0)
    }

    // MARK: - Statistics

    func testMeanQuality() {
        let qs = QualityScore(values: [10, 20, 30], encoding: .phred33)
        XCTAssertEqual(qs.meanQuality, 20.0, accuracy: 0.001)
    }

    func testMinMaxQuality() {
        let qs = QualityScore(values: [5, 15, 25, 35], encoding: .phred33)
        XCTAssertEqual(qs.minQuality, 5)
        XCTAssertEqual(qs.maxQuality, 35)
    }

    func testMedianQualityOddCount() {
        let qs = QualityScore(values: [10, 20, 30], encoding: .phred33)
        XCTAssertEqual(qs.medianQuality, 20.0, accuracy: 0.001)
    }

    func testMedianQualityEvenCount() {
        let qs = QualityScore(values: [10, 20, 30, 40], encoding: .phred33)
        XCTAssertEqual(qs.medianQuality, 25.0, accuracy: 0.001)
    }

    func testQ30Percentage() {
        let qs = QualityScore(values: [20, 30, 35, 40, 25], encoding: .phred33)
        // 3 out of 5 are >= 30
        XCTAssertEqual(qs.q30Percentage, 60.0, accuracy: 0.001)
    }

    func testQ20Percentage() {
        let qs = QualityScore(values: [10, 20, 30], encoding: .phred33)
        // 2 out of 3 are >= 20
        XCTAssertEqual(qs.q20Percentage, 66.666, accuracy: 0.01)
    }

    func testQualityHistogram() {
        let qs = QualityScore(values: [30, 30, 20, 30], encoding: .phred33)
        let hist = qs.qualityHistogram()
        XCTAssertEqual(hist[30], 3)
        XCTAssertEqual(hist[20], 1)
    }

    // MARK: - Access

    func testQualityAtOutOfBounds() {
        let qs = QualityScore(values: [10, 20], encoding: .phred33)
        XCTAssertEqual(qs.qualityAt(-1), 0) // negative
        XCTAssertEqual(qs.qualityAt(5), 0)  // past end
    }

    func testQualitiesInRange() {
        let qs = QualityScore(values: [10, 20, 30, 40, 50], encoding: .phred33)
        let range = qs.qualitiesIn(1..<3)
        XCTAssertEqual(range, [20, 30])
    }

    func testErrorProbability() {
        let qs = QualityScore(values: [20], encoding: .phred33)
        // Q20 → P = 10^(-20/10) = 0.01
        XCTAssertEqual(qs.errorProbabilityAt(0), 0.01, accuracy: 0.0001)
    }

    // MARK: - Conversion

    func testToAscii() {
        let qs = QualityScore(values: [40], encoding: .phred33)
        let ascii = qs.toAscii()
        // Q40 + offset 33 = ASCII 73 = 'I'
        XCTAssertEqual(ascii, "I")
    }

    func testConvertEncoding() {
        let qs = QualityScore(values: [30, 40], encoding: .phred33)
        let converted = qs.convert(to: .phred64)
        XCTAssertEqual(converted.encoding, .phred64)
        XCTAssertEqual(converted.count, 2)
        // Values are stored normalized, so they should be the same
        XCTAssertEqual(converted.qualityAt(0), 30)
    }

    // MARK: - Trimming

    func testTrimPosition() {
        // Quality drops at the end: high...high...low
        let qs = QualityScore(values: [30, 30, 30, 30, 30, 5, 5, 5, 5, 5], encoding: .phred33)
        let pos = qs.trimPosition(threshold: 20, windowSize: 3)
        XCTAssertGreaterThan(pos, 0)
        XCTAssertLessThan(pos, 10) // should trim the low-quality tail
    }

    func testTrimPositionAllHighQuality() {
        let qs = QualityScore(values: [30, 30, 30, 30, 30], encoding: .phred33)
        let pos = qs.trimPosition(threshold: 20, windowSize: 3)
        XCTAssertEqual(pos, 5) // no trimming needed
    }

    // MARK: - Collection Conformance

    func testRandomAccessCollection() {
        let qs = QualityScore(values: [10, 20, 30], encoding: .phred33)
        XCTAssertEqual(qs.startIndex, 0)
        XCTAssertEqual(qs.endIndex, 3)
        XCTAssertEqual(qs[0], 10)
        XCTAssertEqual(qs[2], 30)
    }

    // MARK: - Encoding Detection

    func testDetectPhred33() {
        // '!' = 33, clearly Phred+33
        let detected = QualityEncoding.detect(from: "!\"#$%")
        XCTAssertEqual(detected, .phred33)
    }

    func testDetectEmpty() {
        let detected = QualityEncoding.detect(from: "")
        XCTAssertEqual(detected, .phred33) // default
    }

    // MARK: - Description

    func testDescription() {
        let qs = QualityScore(values: [30, 30, 30], encoding: .phred33)
        XCTAssertTrue(qs.description.contains("count: 3"))
        XCTAssertTrue(qs.description.contains("Q30:"))
    }
}

// MARK: - FASTAIndex Tests

final class FASTAIndexRegressionTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTAIndexTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Entry

    func testEntryInit() {
        let entry = FASTAIndex.Entry(name: "chr1", length: 1000, offset: 50, lineBases: 80, lineWidth: 81)
        XCTAssertEqual(entry.name, "chr1")
        XCTAssertEqual(entry.length, 1000)
        XCTAssertEqual(entry.offset, 50)
        XCTAssertEqual(entry.lineBases, 80)
        XCTAssertEqual(entry.lineWidth, 81)
    }

    func testEntryCodable() throws {
        let entry = FASTAIndex.Entry(name: "seq1", length: 500, offset: 10, lineBases: 60, lineWidth: 61)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(FASTAIndex.Entry.self, from: data)
        XCTAssertEqual(decoded.name, "seq1")
        XCTAssertEqual(decoded.length, 500)
    }

    // MARK: - Index from Entries

    func testIndexFromEntries() {
        let entries = [
            FASTAIndex.Entry(name: "chr1", length: 1000, offset: 6, lineBases: 80, lineWidth: 81),
            FASTAIndex.Entry(name: "chr2", length: 500, offset: 2000, lineBases: 80, lineWidth: 81)
        ]
        let index = FASTAIndex(entries: entries)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.sequenceNames, ["chr1", "chr2"])
    }

    func testIndexLookup() {
        let entries = [
            FASTAIndex.Entry(name: "MT192765.1", length: 29903, offset: 15, lineBases: 80, lineWidth: 81)
        ]
        let index = FASTAIndex(entries: entries)
        XCTAssertNotNil(index.entry(for: "MT192765.1"))
        XCTAssertNil(index.entry(for: "nonexistent"))
        XCTAssertEqual(index.length(of: "MT192765.1"), 29903)
    }

    // MARK: - Byte Offset Calculation

    func testByteOffset() {
        let entry = FASTAIndex.Entry(name: "seq", length: 200, offset: 10, lineBases: 80, lineWidth: 81)
        let entries = [entry]
        let index = FASTAIndex(entries: entries)

        // Position 0 → at entry.offset
        XCTAssertEqual(index.byteOffset(for: 0, in: entry), 10)

        // Position 80 → second line: offset + 1 * lineWidth + 0
        XCTAssertEqual(index.byteOffset(for: 80, in: entry), 10 + 81)

        // Position 85 → second line + 5: offset + 1 * lineWidth + 5
        XCTAssertEqual(index.byteOffset(for: 85, in: entry), 10 + 81 + 5)
    }

    // MARK: - Read/Write .fai

    func testReadFaiFile() throws {
        let faiContent = "chr1\t248956422\t112\t70\t71\nchr2\t242193529\t253404903\t70\t71\n"
        let faiURL = tempDir.appendingPathComponent("test.fasta.fai")
        try faiContent.write(to: faiURL, atomically: true, encoding: .utf8)

        let index = try FASTAIndex(url: faiURL)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.sequenceNames, ["chr1", "chr2"])
        XCTAssertEqual(index.length(of: "chr1"), 248956422)
        XCTAssertEqual(index.length(of: "chr2"), 242193529)
    }

    func testWriteFaiFile() throws {
        let entries = [
            FASTAIndex.Entry(name: "seq1", length: 100, offset: 6, lineBases: 80, lineWidth: 81)
        ]
        let index = FASTAIndex(entries: entries)
        let outputURL = tempDir.appendingPathComponent("output.fai")
        try index.write(to: outputURL)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("seq1\t100\t6\t80\t81"))
    }

    func testRoundTripFai() throws {
        let entries = [
            FASTAIndex.Entry(name: "chrX", length: 155270560, offset: 50, lineBases: 70, lineWidth: 71),
            FASTAIndex.Entry(name: "chrY", length: 59373566, offset: 200000000, lineBases: 70, lineWidth: 71)
        ]
        let original = FASTAIndex(entries: entries)
        let outputURL = tempDir.appendingPathComponent("roundtrip.fai")
        try original.write(to: outputURL)

        let loaded = try FASTAIndex(url: outputURL)
        XCTAssertEqual(loaded.count, original.count)
        XCTAssertEqual(loaded.sequenceNames, original.sequenceNames)
        XCTAssertEqual(loaded.length(of: "chrX"), 155270560)
    }

    func testMissingFileThrows() {
        let url = tempDir.appendingPathComponent("nonexistent.fai")
        XCTAssertThrowsError(try FASTAIndex(url: url))
    }

    func testInvalidFaiThrows() throws {
        let badContent = "only_two_fields\t100\n"
        let url = tempDir.appendingPathComponent("bad.fai")
        try badContent.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FASTAIndex(url: url))
    }

    // MARK: - FASTAIndexBuilder

    func testBuildIndex() throws {
        let fastaContent = ">seq1\nACGTACGTACGT\n>seq2\nGGGGAAAATTTT\nCCCC\n"
        let fastaURL = tempDir.appendingPathComponent("test.fasta")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        let index = try FASTAIndexBuilder.build(for: fastaURL)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.sequenceNames, ["seq1", "seq2"])
        XCTAssertEqual(index.length(of: "seq1"), 12) // ACGTACGTACGT
        XCTAssertEqual(index.length(of: "seq2"), 16) // GGGGAAAATTTTCCCC
    }

    func testBuildAndWriteEmptyFASTAProducesEmptyIndex() throws {
        let fastaURL = tempDir.appendingPathComponent("empty.fasta")
        try "".write(to: fastaURL, atomically: true, encoding: .utf8)

        try FASTAIndexBuilder.buildAndWrite(for: fastaURL)

        let faiURL = fastaURL.appendingPathExtension("fai")
        XCTAssertTrue(FileManager.default.fileExists(atPath: faiURL.path))

        let index = try FASTAIndex(url: faiURL)
        XCTAssertEqual(index.count, 0)
        XCTAssertTrue(index.sequenceNames.isEmpty)
    }

    func testBuildAndWrite() throws {
        let fastaContent = ">genome\nATCG\n"
        let fastaURL = tempDir.appendingPathComponent("genome.fasta")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        try FASTAIndexBuilder.buildAndWrite(for: fastaURL)

        let faiURL = fastaURL.appendingPathExtension("fai")
        XCTAssertTrue(FileManager.default.fileExists(atPath: faiURL.path))

        let index = try FASTAIndex(url: faiURL)
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.length(of: "genome"), 4)
    }
}

// MARK: - TaxonNode Tests

final class TaxonNodeRegressionTests: XCTestCase {

    func makeSampleTree() -> TaxonTree {
        let root = TaxonNode(taxId: 1, name: "root", rank: .root, depth: 0,
                             readsDirect: 0, readsClade: 100,
                             fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil)
        let bacteria = TaxonNode(taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
                                 readsDirect: 5, readsClade: 80,
                                 fractionClade: 0.8, fractionDirect: 0.05, parentTaxId: 1)
        let ecoli = TaxonNode(taxId: 562, name: "Escherichia coli", rank: .species, depth: 4,
                              readsDirect: 50, readsClade: 50,
                              fractionClade: 0.5, fractionDirect: 0.5, parentTaxId: 2)
        let saureus = TaxonNode(taxId: 1280, name: "Staphylococcus aureus", rank: .species, depth: 4,
                                readsDirect: 25, readsClade: 25,
                                fractionClade: 0.25, fractionDirect: 0.25, parentTaxId: 2)
        let unclassified = TaxonNode(taxId: 0, name: "unclassified", rank: .unclassified, depth: 0,
                                     readsDirect: 20, readsClade: 20,
                                     fractionClade: 0.2, fractionDirect: 0.2, parentTaxId: nil)

        root.addChild(bacteria)
        bacteria.addChild(ecoli)
        bacteria.addChild(saureus)

        return TaxonTree(root: root, unclassifiedNode: unclassified, totalReads: 120)
    }

    // MARK: - TaxonNode Properties

    func testNodeProperties() {
        let node = TaxonNode(taxId: 562, name: "Escherichia coli", rank: .species, depth: 4,
                             readsDirect: 50, readsClade: 50,
                             fractionClade: 0.5, fractionDirect: 0.5, parentTaxId: 2)
        XCTAssertEqual(node.taxId, 562)
        XCTAssertEqual(node.name, "Escherichia coli")
        XCTAssertEqual(node.rank, .species)
        XCTAssertEqual(node.depth, 4)
        XCTAssertEqual(node.readsDirect, 50)
        XCTAssertEqual(node.readsClade, 50)
        XCTAssertNil(node.brackenReads)
    }

    func testAddChild() {
        let parent = TaxonNode(taxId: 1, name: "root", rank: .root, depth: 0,
                               readsDirect: 0, readsClade: 100,
                               fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil)
        let child = TaxonNode(taxId: 2, name: "child", rank: .domain, depth: 1,
                              readsDirect: 0, readsClade: 50,
                              fractionClade: 0.5, fractionDirect: 0.0, parentTaxId: 1)
        parent.addChild(child)
        XCTAssertEqual(parent.children.count, 1)
        XCTAssertTrue(child.parent === parent)
    }

    func testAllDescendants() {
        let tree = makeSampleTree()
        let descendants = tree.root.allDescendants()
        XCTAssertEqual(descendants.count, 4) // root, bacteria, ecoli, saureus
    }

    func testLeaves() {
        let tree = makeSampleTree()
        let leaves = tree.root.leaves()
        XCTAssertEqual(leaves.count, 2) // ecoli, saureus
    }

    func testPathFromRoot() {
        let tree = makeSampleTree()
        let ecoli = tree.node(taxId: 562)!
        let path = ecoli.pathFromRoot()
        XCTAssertEqual(path.count, 3) // root -> bacteria -> ecoli
        XCTAssertEqual(path.first?.taxId, 1)
        XCTAssertEqual(path.last?.taxId, 562)
    }

    // MARK: - Equatable/Hashable

    func testEquatable() {
        let a = TaxonNode(taxId: 562, name: "E. coli", rank: .species, depth: 0,
                          readsDirect: 0, readsClade: 0, fractionClade: 0, fractionDirect: 0, parentTaxId: nil)
        let b = TaxonNode(taxId: 562, name: "different", rank: .genus, depth: 5,
                          readsDirect: 99, readsClade: 99, fractionClade: 0.5, fractionDirect: 0.5, parentTaxId: nil)
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, b) // equality is reference identity, not taxId
    }

    func testHashable() {
        let a = TaxonNode(taxId: 562, name: "E. coli", rank: .species, depth: 0,
                          readsDirect: 0, readsClade: 0, fractionClade: 0, fractionDirect: 0, parentTaxId: nil)
        let b = TaxonNode(taxId: 562, name: "other", rank: .genus, depth: 1,
                          readsDirect: 5, readsClade: 5, fractionClade: 0, fractionDirect: 0, parentTaxId: nil)
        var set = Set<TaxonNode>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 2) // distinct node identities remain distinct in sets
    }

    // MARK: - TaxonTree

    func testTreeStatistics() {
        let tree = makeSampleTree()
        XCTAssertEqual(tree.totalReads, 120)
        XCTAssertEqual(tree.classifiedReads, 100) // root.readsClade
        XCTAssertEqual(tree.unclassifiedReads, 20)
        XCTAssertEqual(tree.speciesCount, 2)
    }

    func testTreeFractions() {
        let tree = makeSampleTree()
        XCTAssertEqual(tree.classifiedFraction, 100.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(tree.unclassifiedFraction, 20.0 / 120.0, accuracy: 0.001)
    }

    func testNodeLookupByTaxId() {
        let tree = makeSampleTree()
        XCTAssertNotNil(tree.node(taxId: 562))
        XCTAssertEqual(tree.node(taxId: 562)?.name, "Escherichia coli")
        XCTAssertNotNil(tree.node(taxId: 0)) // unclassified
        XCTAssertNil(tree.node(taxId: 99999))
    }

    func testFindByName() {
        let tree = makeSampleTree()
        let results = tree.find(name: "coli")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.taxId, 562)
    }

    func testFindByNameCaseInsensitive() {
        let tree = makeSampleTree()
        let results = tree.find(name: "BACTERIA")
        XCTAssertEqual(results.count, 1)
    }

    func testNodesAtRank() {
        let tree = makeSampleTree()
        let species = tree.nodes(at: .species)
        XCTAssertEqual(species.count, 2)
    }

    func testDominantSpecies() {
        let tree = makeSampleTree()
        XCTAssertEqual(tree.dominantSpecies?.taxId, 562) // E. coli has 50 reads
    }

    func testShannonDiversity() {
        let tree = makeSampleTree()
        let h = tree.shannonDiversity
        XCTAssertGreaterThan(h, 0.0)
    }

    func testSimpsonDiversity() {
        let tree = makeSampleTree()
        let d = tree.simpsonDiversity
        XCTAssertGreaterThan(d, 0.0)
        XCTAssertLessThan(d, 1.0)
    }

    func testZeroReadsFractions() {
        let root = TaxonNode(taxId: 1, name: "root", rank: .root, depth: 0,
                             readsDirect: 0, readsClade: 0,
                             fractionClade: 0, fractionDirect: 0, parentTaxId: nil)
        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 0)
        XCTAssertEqual(tree.classifiedFraction, 0.0)
        XCTAssertEqual(tree.unclassifiedFraction, 0.0)
    }
}

// MARK: - FormatIdentifier Tests

final class FormatIdentifierRegressionTests: XCTestCase {

    func testCaseInsensitiveConstruction() {
        let a = FormatIdentifier("FASTA")
        let b = FormatIdentifier("fasta")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, "fasta")
    }

    func testStringLiteral() {
        let id: FormatIdentifier = "bam"
        XCTAssertEqual(id.id, "bam")
    }

    func testBuiltInFormats() {
        XCTAssertEqual(FormatIdentifier.fasta.id, "fasta")
        XCTAssertEqual(FormatIdentifier.fastq.id, "fastq")
        XCTAssertEqual(FormatIdentifier.bam.id, "bam")
        XCTAssertEqual(FormatIdentifier.vcf.id, "vcf")
        XCTAssertEqual(FormatIdentifier.gff3.id, "gff3")
        XCTAssertEqual(FormatIdentifier.bed.id, "bed")
        XCTAssertEqual(FormatIdentifier.bigwig.id, "bigwig")
    }

    func testExtensions() {
        XCTAssertTrue(FormatIdentifier.fasta.extensions.contains("fa"))
        XCTAssertTrue(FormatIdentifier.fasta.extensions.contains("fasta"))
        XCTAssertTrue(FormatIdentifier.fasta.extensions.contains("fna"))
        XCTAssertTrue(FormatIdentifier.bam.extensions.contains("bam"))
        XCTAssertTrue(FormatIdentifier.vcf.extensions.contains("vcf"))
    }

    func testMimeTypes() {
        XCTAssertTrue(FormatIdentifier.fasta.mimeTypes.contains("text/x-fasta"))
        XCTAssertTrue(FormatIdentifier.bam.mimeTypes.contains("application/x-bam"))
    }

    func testCodableRoundTrip() throws {
        let original = FormatIdentifier.fasta
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FormatIdentifier.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testHashable() {
        var set = Set<FormatIdentifier>()
        set.insert(FormatIdentifier.fasta)
        set.insert(FormatIdentifier("FASTA"))
        XCTAssertEqual(set.count, 1)
    }

    func testDescription() {
        XCTAssertEqual(FormatIdentifier.fasta.description, "fasta")
        XCTAssertEqual(FormatIdentifier.bam.debugDescription, "FormatIdentifier(bam)")
    }

    func testIndexFormats() {
        XCTAssertEqual(FormatIdentifier.fai.id, "fai")
        XCTAssertEqual(FormatIdentifier.bai.id, "bai")
        XCTAssertEqual(FormatIdentifier.tbi.id, "tbi")
        XCTAssertEqual(FormatIdentifier.csi.id, "csi")
    }

    func testDocumentFormats() {
        XCTAssertEqual(FormatIdentifier.csv.id, "csv")
        XCTAssertEqual(FormatIdentifier.tsv.id, "tsv")
        XCTAssertTrue(FormatIdentifier.markdown.extensions.contains("md"))
    }
}

// MARK: - FormatDescriptor Tests

final class FormatDescriptorRegressionTests: XCTestCase {

    func testConstruction() {
        let desc = FormatDescriptor(
            identifier: .fasta,
            displayName: "FASTA",
            formatDescription: "Simple sequence format",
            extensions: ["fa", "fasta"],
            capabilities: DocumentCapability(),
            uiCategory: .sequence
        )
        XCTAssertEqual(desc.identifier, .fasta)
        XCTAssertEqual(desc.displayName, "FASTA")
        XCTAssertEqual(desc.uiCategory, .sequence)
        XCTAssertTrue(desc.canRead)
        XCTAssertTrue(desc.canWrite)
        XCTAssertFalse(desc.isBinary)
    }

    func testMatchesExtension() {
        let desc = FormatDescriptor(
            identifier: .fasta,
            displayName: "FASTA",
            formatDescription: "seq",
            extensions: ["fa", "fasta", "fna"],
            capabilities: DocumentCapability()
        )
        let faURL = URL(fileURLWithPath: "/tmp/test.fa")
        let fastaURL = URL(fileURLWithPath: "/tmp/test.fasta")
        let bamURL = URL(fileURLWithPath: "/tmp/test.bam")
        let gzURL = URL(fileURLWithPath: "/tmp/test.fa.gz")

        XCTAssertTrue(desc.matchesExtension(faURL))
        XCTAssertTrue(desc.matchesExtension(fastaURL))
        XCTAssertFalse(desc.matchesExtension(bamURL))
        XCTAssertTrue(desc.matchesExtension(gzURL)) // compound extension
    }

    func testPrimaryExtension() {
        let desc = FormatDescriptor(
            identifier: .fasta,
            displayName: "FASTA",
            formatDescription: "seq",
            extensions: ["fasta", "fa", "fna"],
            capabilities: DocumentCapability()
        )
        // Primary = first sorted
        XCTAssertEqual(desc.primaryExtension, "fa")
    }

    func testHasMagicBytes() {
        let withMagic = FormatDescriptor(
            identifier: .bam,
            displayName: "BAM",
            formatDescription: "binary alignment",
            extensions: ["bam"],
            magicBytes: Data([0x42, 0x41, 0x4d, 0x01]),
            capabilities: DocumentCapability(),
            isBinary: true
        )
        let withoutMagic = FormatDescriptor(
            identifier: .fasta,
            displayName: "FASTA",
            formatDescription: "seq",
            extensions: ["fa"],
            capabilities: DocumentCapability()
        )
        XCTAssertTrue(withMagic.hasMagicBytes)
        XCTAssertFalse(withoutMagic.hasMagicBytes)
    }

    func testBinaryFormat() {
        let desc = FormatDescriptor(
            identifier: .bam,
            displayName: "BAM",
            formatDescription: "binary",
            extensions: ["bam"],
            capabilities: DocumentCapability(),
            isBinary: true
        )
        XCTAssertTrue(desc.isBinary)
    }

    func testDescription() {
        let desc = FormatDescriptor(
            identifier: .vcf,
            displayName: "VCF",
            formatDescription: "variants",
            extensions: ["vcf"],
            capabilities: DocumentCapability()
        )
        XCTAssertEqual(desc.description, "VCF (vcf)")
    }
}

// MARK: - UICategory Tests

final class UICategoryRegressionTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(UICategory.allCases.count, 11)
    }

    func testDisplayNames() {
        XCTAssertEqual(UICategory.sequence.displayName, "Sequence")
        XCTAssertEqual(UICategory.alignment.displayName, "Alignment")
        XCTAssertEqual(UICategory.variant.displayName, "Variant")
        XCTAssertEqual(UICategory.annotation.displayName, "Annotation")
        XCTAssertEqual(UICategory.unknown.displayName, "Other")
    }

    func testIconNames() {
        for category in UICategory.allCases {
            XCTAssertFalse(category.iconName.isEmpty, "\(category) has empty icon")
        }
    }

    func testIsGenomicsCategory() {
        XCTAssertTrue(UICategory.sequence.isGenomicsCategory)
        XCTAssertTrue(UICategory.alignment.isGenomicsCategory)
        XCTAssertTrue(UICategory.variant.isGenomicsCategory)
        XCTAssertFalse(UICategory.document.isGenomicsCategory)
        XCTAssertFalse(UICategory.image.isGenomicsCategory)
        XCTAssertFalse(UICategory.unknown.isGenomicsCategory)
    }

    func testCodableRoundTrip() throws {
        for category in UICategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(UICategory.self, from: data)
            XCTAssertEqual(category, decoded)
        }
    }
}

// MARK: - CompressionType Tests

final class CompressionTypeRegressionTests: XCTestCase {

    func testAllCases() {
        XCTAssertEqual(CompressionType.allCases.count, 6)
    }

    func testFileExtensions() {
        XCTAssertNil(CompressionType.none.fileExtension)
        XCTAssertEqual(CompressionType.gzip.fileExtension, "gz")
        XCTAssertEqual(CompressionType.bgzf.fileExtension, "bgz")
        XCTAssertEqual(CompressionType.zstd.fileExtension, "zst")
        XCTAssertEqual(CompressionType.bzip2.fileExtension, "bz2")
        XCTAssertEqual(CompressionType.xz.fileExtension, "xz")
    }

    func testDetectFromURL() {
        XCTAssertEqual(CompressionType.detect(from: URL(fileURLWithPath: "/tmp/test.gz")), .gzip)
        XCTAssertEqual(CompressionType.detect(from: URL(fileURLWithPath: "/tmp/test.bgz")), .bgzf)
        XCTAssertEqual(CompressionType.detect(from: URL(fileURLWithPath: "/tmp/test.zst")), .zstd)
        XCTAssertEqual(CompressionType.detect(from: URL(fileURLWithPath: "/tmp/test.bz2")), .bzip2)
        XCTAssertEqual(CompressionType.detect(from: URL(fileURLWithPath: "/tmp/test.xz")), .xz)
        XCTAssertEqual(CompressionType.detect(from: URL(fileURLWithPath: "/tmp/test.fasta")), .none)
    }

    func testCodableRoundTrip() throws {
        for ct in CompressionType.allCases {
            let data = try JSONEncoder().encode(ct)
            let decoded = try JSONDecoder().decode(CompressionType.self, from: data)
            XCTAssertEqual(ct, decoded)
        }
    }
}
