// CrossModuleTests.swift - Comprehensive cross-module integration tests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishUI

/// Cross-module integration tests that exercise real data flow between
/// LungfishCore, LungfishIO, and LungfishUI.
///
/// These tests create real temporary files on disk and verify that data
/// produced by one module is correctly consumed by another.
@MainActor
final class CrossModuleTests: XCTestCase {

    // MARK: - Test Lifecycle

    var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishCrossModule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - 1. File I/O -> Core Data Model Tests

    /// Reads a multi-sequence FASTA file and verifies that the resulting
    /// `Sequence` objects have correct names, lengths, alphabet, and that
    /// `reverseComplement()` produces the expected bases.
    func testFASTAReaderProducesValidSequences() async throws {
        // Arrange: write a two-sequence FASTA with known content
        let fastaContent = """
        >chr1 Chromosome 1
        ATCGATCGATCGATCG
        AAAACCCCGGGGTTTT
        >chrM Mitochondrial DNA
        GCTAGCTAGCTA
        """
        let fastaURL = tempDirectory.appendingPathComponent("test.fa")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        // Act: read with FASTAReader
        let reader = try FASTAReader(url: fastaURL)
        let sequences = try await reader.readAll(alphabet: .dna)

        // Assert: two sequences with correct properties
        XCTAssertEqual(sequences.count, 2, "Expected 2 sequences in FASTA")

        let seq1 = sequences[0]
        XCTAssertEqual(seq1.name, "chr1")
        XCTAssertEqual(seq1.description, "Chromosome 1")
        XCTAssertEqual(seq1.alphabet, .dna)
        XCTAssertEqual(seq1.length, 32)
        XCTAssertEqual(seq1.asString(), "ATCGATCGATCGATCGAAAACCCCGGGGTTTT")

        let seq2 = sequences[1]
        XCTAssertEqual(seq2.name, "chrM")
        XCTAssertEqual(seq2.length, 12)
        XCTAssertEqual(seq2.asString(), "GCTAGCTAGCTA")

        // Verify reverseComplement round-trips through Core model
        let rc = seq2.reverseComplement()
        XCTAssertNotNil(rc, "DNA sequence should support reverseComplement")
        XCTAssertEqual(rc!.asString(), "TAGCTAGCTAGC")

        // Double reverse complement should yield original
        let rcrc = rc!.reverseComplement()
        XCTAssertNotNil(rcrc)
        XCTAssertEqual(rcrc!.asString(), seq2.asString())
    }

    /// Reads a GenBank file and verifies that annotations have proper types,
    /// intervals (0-based half-open), qualifiers, and strand information.
    func testGenBankReaderProducesAnnotations() async throws {
        let genbankContent = """
        LOCUS       pBR322                100 bp    DNA     circular UNK
        DEFINITION  Cloning vector pBR322.
        ACCESSION   J01749
        VERSION     J01749.1
        FEATURES             Location/Qualifiers
             gene            1..30
                             /gene="tet"
                             /product="tetracycline resistance protein"
             CDS             complement(40..90)
                             /gene="bla"
                             /product="beta-lactamase"
                             /note="ampicillin resistance"
        ORIGIN
                1 atgcgatcga tcgatcgatc gatcgatcga tcgatcgatc gatcgatcga
               51 tcgatcgatc gatcgatcga tcgatcgatc gatcgatcga tcgatcgatc
        //
        """
        let gbURL = tempDirectory.appendingPathComponent("test.gb")
        try genbankContent.write(to: gbURL, atomically: true, encoding: .utf8)

        let reader = try GenBankReader(url: gbURL)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1)
        let record = records[0]

        // Verify locus metadata
        XCTAssertEqual(record.locus.name, "pBR322")
        XCTAssertEqual(record.locus.moleculeType, .dna)
        XCTAssertEqual(record.locus.topology, .circular)
        XCTAssertEqual(record.accession, "J01749")
        XCTAssertEqual(record.version, "J01749.1")

        // Verify the sequence was parsed
        XCTAssertEqual(record.sequence.length, 100)
        XCTAssertEqual(record.sequence.alphabet, .dna)

        // Verify annotations
        XCTAssertEqual(record.annotations.count, 2)

        // Gene annotation (forward strand, 1..30 -> 0-based [0, 30))
        let gene = record.annotations.first { $0.type == .gene }
        XCTAssertNotNil(gene, "Should have a gene annotation")
        XCTAssertEqual(gene!.name, "tet")
        XCTAssertEqual(gene!.strand, .forward)
        XCTAssertEqual(gene!.intervals.count, 1)
        XCTAssertEqual(gene!.intervals[0].start, 0)
        XCTAssertEqual(gene!.intervals[0].end, 30)
        XCTAssertEqual(gene!.qualifier("gene"), "tet")
        XCTAssertEqual(gene!.qualifier("product"), "tetracycline resistance protein")

        // CDS annotation (complement = reverse strand, 40..90 -> 0-based [39, 90))
        let cds = record.annotations.first { $0.type == .cds }
        XCTAssertNotNil(cds, "Should have a CDS annotation")
        XCTAssertEqual(cds!.name, "bla")
        XCTAssertEqual(cds!.strand, .reverse)
        XCTAssertEqual(cds!.intervals.count, 1)
        XCTAssertEqual(cds!.intervals[0].start, 39)
        XCTAssertEqual(cds!.intervals[0].end, 90)
        XCTAssertEqual(cds!.qualifier("note"), "ampicillin resistance")
    }

    /// Reads a FASTQ file and verifies that quality scores are preserved
    /// and can be converted to `Sequence.qualityScores` format.
    func testFASTQReaderPreservesQuality() async throws {
        // FASTQ with known quality scores
        // 'I' = ASCII 73 - 33 = Q40, '5' = ASCII 53 - 33 = Q20, '!' = ASCII 33 - 33 = Q0
        let fastqContent = """
        @read1 length=10
        ATCGATCGAT
        +
        IIIIIIIIII
        @read2 length=10
        GCTAGCTAGC
        +
        IIIII55555
        """
        let fastqURL = tempDirectory.appendingPathComponent("test.fq")
        try fastqContent.write(to: fastqURL, atomically: true, encoding: .utf8)

        let reader = FASTQReader(encoding: .phred33)
        let records = try await reader.readAll(from: fastqURL)

        XCTAssertEqual(records.count, 2)

        // First read: all Q40
        let read1 = records[0]
        XCTAssertEqual(read1.identifier, "read1")
        XCTAssertEqual(read1.sequence, "ATCGATCGAT")
        XCTAssertEqual(read1.length, 10)
        XCTAssertEqual(read1.quality.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(read1.quality.qualityAt(i), 40,
                           "All bases in read1 should be Q40")
        }
        XCTAssertEqual(read1.quality.meanQuality, 40.0, accuracy: 0.01)

        // Second read: first 5 at Q40, last 5 at Q20
        let read2 = records[1]
        XCTAssertEqual(read2.identifier, "read2")
        XCTAssertEqual(read2.quality.count, 10)
        for i in 0..<5 {
            XCTAssertEqual(read2.quality.qualityAt(i), 40)
        }
        for i in 5..<10 {
            XCTAssertEqual(read2.quality.qualityAt(i), 20)
        }
        XCTAssertEqual(read2.quality.meanQuality, 30.0, accuracy: 0.01)

        // Verify quality scores can be converted to Sequence qualityScores
        let coreSequence = try LungfishCore.Sequence(
            name: read1.identifier,
            alphabet: .dna,
            bases: read1.sequence,
            qualityScores: (0..<read1.quality.count).map { read1.quality.qualityAt($0) }
        )
        XCTAssertNotNil(coreSequence.qualityScores)
        XCTAssertEqual(coreSequence.qualityScores!.count, 10)
        XCTAssertEqual(coreSequence.qualityScores![0], 40)
    }

    /// Reads a GFF3 file and verifies that annotations have correct intervals
    /// (converted from 1-based inclusive to 0-based half-open).
    func testGFF3ReaderAnnotationsHaveIntervals() async throws {
        // GFF3 uses 1-based inclusive coordinates
        let gff3Content = """
        ##gff-version 3
        chr1\tENSEMBL\tgene\t1001\t2000\t.\t+\t.\tID=gene1;Name=BRCA1
        chr1\tENSEMBL\texon\t1001\t1200\t.\t+\t.\tID=exon1;Parent=gene1;Name=exon1
        chr1\tENSEMBL\texon\t1500\t2000\t.\t+\t.\tID=exon2;Parent=gene1;Name=exon2
        chr2\tENSEMBL\tgene\t5001\t6000\t.\t-\t.\tID=gene2;Name=TP53
        """
        let gff3URL = tempDirectory.appendingPathComponent("test.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: gff3URL)

        XCTAssertEqual(annotations.count, 4)

        // Gene annotation: GFF3 1001..2000 -> 0-based [1000, 2000)
        let gene1 = annotations.first { $0.name == "BRCA1" }
        XCTAssertNotNil(gene1)
        XCTAssertEqual(gene1!.type, .gene)
        XCTAssertEqual(gene1!.chromosome, "chr1")
        XCTAssertEqual(gene1!.strand, .forward)
        XCTAssertEqual(gene1!.intervals.count, 1)
        XCTAssertEqual(gene1!.intervals[0].start, 1000)
        XCTAssertEqual(gene1!.intervals[0].end, 2000)
        XCTAssertEqual(gene1!.intervals[0].length, 1000)

        // Exon annotations
        let exon1 = annotations.first { $0.name == "exon1" }
        XCTAssertNotNil(exon1)
        XCTAssertEqual(exon1!.type, .exon)
        XCTAssertEqual(exon1!.intervals[0].start, 1000)
        XCTAssertEqual(exon1!.intervals[0].end, 1200)

        let exon2 = annotations.first { $0.name == "exon2" }
        XCTAssertNotNil(exon2)
        XCTAssertEqual(exon2!.intervals[0].start, 1499)
        XCTAssertEqual(exon2!.intervals[0].end, 2000)

        // Gene on reverse strand
        let gene2 = annotations.first { $0.name == "TP53" }
        XCTAssertNotNil(gene2)
        XCTAssertEqual(gene2!.chromosome, "chr2")
        XCTAssertEqual(gene2!.strand, .reverse)
        XCTAssertEqual(gene2!.intervals[0].start, 5000)
        XCTAssertEqual(gene2!.intervals[0].end, 6000)
    }

    /// Reads a BED file and verifies that annotation names and types are
    /// correctly populated from the BED columns.
    func testBEDReaderAnnotationsHaveNames() async throws {
        // BED6 format: chrom, start, end, name, score, strand
        let bedContent = """
        chr1\t100\t500\tpeak1\t900\t+
        chr1\t1000\t2000\tpeak2\t750\t-
        chr2\t300\t800\tpeak3\t500\t.
        """
        let bedURL = tempDirectory.appendingPathComponent("test.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

        let reader = BEDReader()
        let features = try await reader.readAll(from: bedURL)
        XCTAssertEqual(features.count, 3)

        // Verify BED features
        XCTAssertEqual(features[0].chrom, "chr1")
        XCTAssertEqual(features[0].chromStart, 100)
        XCTAssertEqual(features[0].chromEnd, 500)
        XCTAssertEqual(features[0].name, "peak1")
        XCTAssertEqual(features[0].score, 900)
        XCTAssertEqual(features[0].strand, .forward)

        // Convert to annotations and verify Core types
        let annotations = features.map { $0.toAnnotation() }
        XCTAssertEqual(annotations.count, 3)

        XCTAssertEqual(annotations[0].name, "peak1")
        XCTAssertEqual(annotations[0].type, .region)
        XCTAssertEqual(annotations[0].intervals[0].start, 100)
        XCTAssertEqual(annotations[0].intervals[0].end, 500)
        XCTAssertEqual(annotations[0].strand, .forward)

        XCTAssertEqual(annotations[1].name, "peak2")
        XCTAssertEqual(annotations[1].strand, .reverse)

        XCTAssertEqual(annotations[2].name, "peak3")
        XCTAssertEqual(annotations[2].strand, .unknown)

        // Verify overlaps method from Core works on IO-produced annotations
        XCTAssertTrue(annotations[0].overlaps(start: 200, end: 300))
        XCTAssertFalse(annotations[0].overlaps(start: 600, end: 700))
    }

    // MARK: - 2. Core -> UI Integration Tests

    /// Creates a `Sequence` from Core, wraps it in a `SequenceTrack` from UI,
    /// and verifies track properties are properly initialized.
    func testSequenceTrackCreation() throws {
        let sequence = try LungfishCore.Sequence(
            name: "chr1",
            alphabet: .dna,
            bases: String(repeating: "ATCG", count: 250)  // 1000 bp
        )

        let track = SequenceTrack(name: "Reference Sequence", sequence: sequence)

        XCTAssertEqual(track.name, "Reference Sequence")
        XCTAssertNotNil(track.currentSequence)
        XCTAssertEqual(track.currentSequence!.name, "chr1")
        XCTAssertEqual(track.currentSequence!.length, 1000)
        XCTAssertTrue(track.isVisible)
        XCTAssertFalse(track.showComplementStrand)

        // Verify the track can accept a new sequence
        let seq2 = try LungfishCore.Sequence(
            name: "chr2",
            alphabet: .dna,
            bases: String(repeating: "GCTA", count: 100)
        )
        track.setSequence(seq2)
        XCTAssertEqual(track.currentSequence!.name, "chr2")
        XCTAssertEqual(track.currentSequence!.length, 400)
    }

    /// Creates a `ReferenceFrame` matching the length of a parsed sequence
    /// and verifies coordinate conversion between genomic and screen space.
    func testReferenceFrameForSequence() throws {
        let sequence = try LungfishCore.Sequence(
            name: "chr17",
            alphabet: .dna,
            bases: String(repeating: "ATCG", count: 500)  // 2000 bp
        )

        let frame = ReferenceFrame(
            chromosome: sequence.name,
            chromosomeLength: sequence.length,
            widthInPixels: 1000
        )

        // At full zoom-out: 2000 bp in 1000 pixels = 2 bp/pixel
        XCTAssertEqual(frame.chromosome, "chr17")
        XCTAssertEqual(frame.chromosomeLength, 2000)
        XCTAssertEqual(frame.scale, 2.0, accuracy: 0.001)
        XCTAssertEqual(frame.origin, 0)
        XCTAssertEqual(frame.end, 2000, accuracy: 0.001)

        // Test coordinate conversion: position 1000 should be at pixel 500
        let screenX = frame.screenPosition(for: 1000)
        XCTAssertEqual(screenX, 500.0, accuracy: 0.001)

        // And back
        let genomicPos = frame.genomicPosition(for: 500)
        XCTAssertEqual(genomicPos, 1000.0, accuracy: 0.001)

        // Jump to a sub-region
        frame.jumpTo(start: 500, end: 1500)
        XCTAssertEqual(frame.origin, 500, accuracy: 0.001)
        XCTAssertEqual(frame.end, 1500, accuracy: 0.001)
        // 1000 bp in 1000 pixels = 1 bp/pixel
        XCTAssertEqual(frame.scale, 1.0, accuracy: 0.001)
    }

    /// Creates a `TileCache`, stores and retrieves sequence tile data,
    /// verifying the LRU eviction and statistics.
    func testTileCacheWithRealData() async throws {
        let cache = TileCache<SequenceTileContent>(capacity: 5)
        let trackId = UUID()

        // Insert tiles
        for i in 0..<5 {
            let content = SequenceTileContent(
                sequence: String(repeating: "ATCG", count: 25),
                gcContent: Float(i) * 0.1 + 0.3,
                dominantBase: ["A", "T", "C", "G", "A"][i]
            )
            let key = TileKey(trackId: trackId, chromosome: "chr1", tileIndex: i, zoom: 5)
            let tile = Tile(key: key, startBP: i * 100, endBP: (i + 1) * 100, content: content)
            await cache.set(tile, for: key)
        }

        // Verify cache contains all tiles
        let stats = await cache.statistics()
        XCTAssertEqual(stats.currentSize, 5)

        // Retrieve a tile and verify content
        let key2 = TileKey(trackId: trackId, chromosome: "chr1", tileIndex: 2, zoom: 5)
        let retrieved = await cache.get(key2)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved!.startBP, 200)
        XCTAssertEqual(retrieved!.endBP, 300)
        XCTAssertEqual(retrieved!.content.sequence.count, 100)

        // Verify LRU eviction: add one more tile, tile 0 should be evicted
        // (tile 2 was just accessed so it moves to end)
        let newContent = SequenceTileContent(
            sequence: String(repeating: "NNNN", count: 25),
            gcContent: 0.0,
            dominantBase: "N"
        )
        let newKey = TileKey(trackId: trackId, chromosome: "chr1", tileIndex: 5, zoom: 5)
        let newTile = Tile(key: newKey, startBP: 500, endBP: 600, content: newContent)
        await cache.set(newTile, for: newKey)

        let statsAfter = await cache.statistics()
        XCTAssertEqual(statsAfter.currentSize, 5)
        XCTAssertGreaterThanOrEqual(statsAfter.evictions, 1)

        // Tile 5 (newly added) should be present
        let tile5 = await cache.get(newKey)
        XCTAssertNotNil(tile5)

        // Clear cache
        await cache.clear()
        let clearedStats = await cache.statistics()
        XCTAssertEqual(clearedStats.currentSize, 0)
    }

    /// Loads GFF3 annotations and creates a `FeatureTrack` from UI,
    /// verifying the track can hold and report the annotations.
    func testAnnotationTrackFromGFF3() async throws {
        let gff3Content = """
        ##gff-version 3
        chr1\t.\tgene\t1\t1000\t.\t+\t.\tID=g1;Name=GeneA
        chr1\t.\texon\t1\t300\t.\t+\t.\tID=e1;Parent=g1;Name=exonA1
        chr1\t.\texon\t700\t1000\t.\t+\t.\tID=e2;Parent=g1;Name=exonA2
        chr1\t.\tgene\t2000\t3000\t.\t-\t.\tID=g2;Name=GeneB
        """
        let gff3URL = tempDirectory.appendingPathComponent("annotations.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: gff3URL)
        XCTAssertEqual(annotations.count, 4)

        // Create a FeatureTrack with these annotations
        let featureTrack = FeatureTrack(
            name: "Gene Annotations",
            annotations: annotations,
            height: 80
        )

        XCTAssertEqual(featureTrack.name, "Gene Annotations")
        XCTAssertEqual(featureTrack.height, 80)
        XCTAssertTrue(featureTrack.isVisible)

        // The track should have a tooltip for a position inside GeneA
        // First load the track data for a reference frame
        let frame = ReferenceFrame(
            chromosome: "chr1",
            chromosomeLength: 5000,
            widthInPixels: 1000
        )
        try await featureTrack.load(for: frame)

        // Verify tooltip at position inside GeneA (0-based: 0..1000)
        let tooltip = featureTrack.tooltipText(at: 500, y: 40)
        XCTAssertNotNil(tooltip)
        XCTAssertTrue(tooltip!.contains("GeneA") || tooltip!.contains("exon"),
                       "Tooltip should reference GeneA or one of its exons")
    }

    // MARK: - 3. Round-Trip File Conversion Tests

    /// Writes sequences to FASTA, reads them back, and verifies the content
    /// matches the original.
    func testFASTARoundTrip() async throws {
        // Create original sequences
        let seq1 = try LungfishCore.Sequence(
            name: "contig1",
            description: "First contig",
            alphabet: .dna,
            bases: "ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG"
        )
        let seq2 = try LungfishCore.Sequence(
            name: "contig2",
            description: "Second contig",
            alphabet: .dna,
            bases: "GCTAGCTAGCTAGCTAGCTAGCTAGCTA"
        )

        // Write to FASTA
        let fastaURL = tempDirectory.appendingPathComponent("roundtrip.fa")
        let writer = FASTAWriter(url: fastaURL, lineWidth: 20)
        try writer.write([seq1, seq2])

        // Read back
        let reader = try FASTAReader(url: fastaURL)
        let readBack = try await reader.readAll(alphabet: .dna)

        // Verify
        XCTAssertEqual(readBack.count, 2)
        XCTAssertEqual(readBack[0].name, "contig1")
        XCTAssertEqual(readBack[0].description, "First contig")
        XCTAssertEqual(readBack[0].asString(), seq1.asString())
        XCTAssertEqual(readBack[0].length, seq1.length)

        XCTAssertEqual(readBack[1].name, "contig2")
        XCTAssertEqual(readBack[1].description, "Second contig")
        XCTAssertEqual(readBack[1].asString(), seq2.asString())
    }

    /// Writes a GenBank record, reads it back, and verifies both sequence
    /// content and annotation features are preserved.
    func testGenBankRoundTrip() async throws {
        // Build a GenBank record
        let bases = "ATGCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGA"
        let sequence = try LungfishCore.Sequence(
            name: "TEST_PLASMID",
            description: "Test plasmid for round-trip",
            alphabet: .dna,
            bases: bases
        )

        let annotations = [
            SequenceAnnotation(
                type: .gene,
                name: "lacZ",
                chromosome: "TEST_PLASMID",
                start: 0,
                end: 50,
                strand: .forward,
                qualifiers: ["gene": AnnotationQualifier("lacZ"),
                             "product": AnnotationQualifier("beta-galactosidase")]
            ),
            SequenceAnnotation(
                type: .cds,
                name: "ampR",
                chromosome: "TEST_PLASMID",
                start: 60,
                end: 95,
                strand: .reverse,
                qualifiers: ["gene": AnnotationQualifier("ampR"),
                             "product": AnnotationQualifier("ampicillin resistance")]
            ),
        ]

        let locus = LocusInfo(
            name: "TEST_PLASMID",
            length: bases.count,
            moleculeType: .dna,
            topology: .circular,
            division: "SYN"
        )

        let record = GenBankRecord(
            sequence: sequence,
            annotations: annotations,
            locus: locus,
            definition: "Test plasmid for round-trip",
            accession: "TP0001",
            version: "TP0001.1"
        )

        // Write
        let gbURL = tempDirectory.appendingPathComponent("roundtrip.gb")
        let writer = GenBankWriter(url: gbURL)
        try writer.write([record])

        // Read back
        let reader = try GenBankReader(url: gbURL)
        let readBack = try await reader.readAll()

        XCTAssertEqual(readBack.count, 1)
        let rt = readBack[0]

        // Verify sequence content (GenBank stores as uppercase)
        XCTAssertEqual(rt.sequence.asString(), bases.uppercased())
        XCTAssertEqual(rt.sequence.length, bases.count)
        XCTAssertEqual(rt.locus.name, "TEST_PLASMID")
        XCTAssertEqual(rt.accession, "TP0001")

        // Verify annotations survived round-trip
        XCTAssertEqual(rt.annotations.count, 2)

        let geneAnnotation = rt.annotations.first { $0.type == .gene }
        XCTAssertNotNil(geneAnnotation)
        XCTAssertEqual(geneAnnotation!.qualifier("gene"), "lacZ")

        let cdsAnnotation = rt.annotations.first { $0.type == .cds }
        XCTAssertNotNil(cdsAnnotation)
        XCTAssertEqual(cdsAnnotation!.strand, .reverse)
    }

    /// Writes GFF3 annotations, reads them back, and verifies that feature
    /// names, types, strands, and coordinate systems are preserved.
    func testGFF3RoundTrip() async throws {
        let annotations = [
            SequenceAnnotation(
                type: .gene,
                name: "MYC",
                chromosome: "chr8",
                start: 1000,
                end: 5000,
                strand: .forward,
                qualifiers: [
                    "ID": AnnotationQualifier("gene001"),
                    "Name": AnnotationQualifier("MYC"),
                ]
            ),
            SequenceAnnotation(
                type: .exon,
                name: "MYC_exon1",
                chromosome: "chr8",
                start: 1000,
                end: 1500,
                strand: .forward,
                qualifiers: [
                    "ID": AnnotationQualifier("exon001"),
                    "Name": AnnotationQualifier("MYC_exon1"),
                    "Parent": AnnotationQualifier("gene001"),
                ]
            ),
        ]

        // Write
        let gff3URL = tempDirectory.appendingPathComponent("roundtrip.gff3")
        try await GFF3Writer.write(annotations, to: gff3URL, source: "TestSuite")

        // Read back
        let reader = GFF3Reader()
        let readBackAnnotations = try await reader.readAsAnnotations(from: gff3URL)

        XCTAssertEqual(readBackAnnotations.count, 2)

        // Verify gene
        let geneRT = readBackAnnotations.first { $0.name == "MYC" }
        XCTAssertNotNil(geneRT)
        XCTAssertEqual(geneRT!.type, .gene)
        XCTAssertEqual(geneRT!.chromosome, "chr8")
        XCTAssertEqual(geneRT!.strand, .forward)
        // GFF3Writer converts 0-based [1000, 5000) -> 1-based 1001..5000
        // GFF3Reader converts 1-based 1001..5000 -> 0-based [1000, 5000)
        XCTAssertEqual(geneRT!.intervals[0].start, 1000)
        XCTAssertEqual(geneRT!.intervals[0].end, 5000)

        // Verify exon
        let exonRT = readBackAnnotations.first { $0.name == "MYC_exon1" }
        XCTAssertNotNil(exonRT)
        XCTAssertEqual(exonRT!.type, .exon)
        XCTAssertEqual(exonRT!.intervals[0].start, 1000)
        XCTAssertEqual(exonRT!.intervals[0].end, 1500)
    }

    /// Writes FASTQ records, reads them back, and verifies that sequence
    /// content and quality scores survive the round-trip.
    func testFASTQRoundTrip() async throws {
        let records = [
            FASTQRecord(
                identifier: "read_001",
                description: "test read 1",
                sequence: "ATCGATCGATCGATCGATCG",
                qualityString: "IIIIIIIIIIIIIIIIIIII",
                encoding: .phred33
            ),
            FASTQRecord(
                identifier: "read_002",
                description: "test read 2",
                sequence: "GCTAGCTAGCTAGCTAGCTA",
                qualityString: "55555IIIII55555IIIII",
                encoding: .phred33
            ),
        ]

        // Write
        let fastqURL = tempDirectory.appendingPathComponent("roundtrip.fq")
        try FASTQWriter.write(records, to: fastqURL, encoding: .phred33)

        // Read back
        let reader = FASTQReader(encoding: .phred33)
        let readBack = try await reader.readAll(from: fastqURL)

        XCTAssertEqual(readBack.count, 2)

        // Verify first record
        XCTAssertEqual(readBack[0].identifier, "read_001")
        XCTAssertEqual(readBack[0].description, "test read 1")
        XCTAssertEqual(readBack[0].sequence, "ATCGATCGATCGATCGATCG")
        XCTAssertEqual(readBack[0].quality.count, 20)
        XCTAssertEqual(readBack[0].quality.meanQuality, 40.0, accuracy: 0.01)

        // Verify second record quality pattern
        XCTAssertEqual(readBack[1].identifier, "read_002")
        XCTAssertEqual(readBack[1].sequence, "GCTAGCTAGCTAGCTAGCTA")
        // First 5 bases should be Q20 ('5')
        for i in 0..<5 {
            XCTAssertEqual(readBack[1].quality.qualityAt(i), 20,
                           "Base \(i) should have Q20")
        }
        // Next 5 should be Q40 ('I')
        for i in 5..<10 {
            XCTAssertEqual(readBack[1].quality.qualityAt(i), 40,
                           "Base \(i) should have Q40")
        }
    }

    // MARK: - 4. Multi-Format Loading Tests

    /// Creates a directory with multiple genomic file formats, uses the
    /// `FormatRegistry` to detect each file's type, and verifies that the
    /// appropriate readers can parse each file.
    func testLoadMultipleFormatsFromFolder() async throws {
        // Create a FASTA file
        let fastaContent = """
        >chr1 test chromosome
        ATCGATCGATCGATCGATCG
        """
        let fastaURL = tempDirectory.appendingPathComponent("genome.fa")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        // Create a GFF3 file
        let gff3Content = """
        ##gff-version 3
        chr1\t.\tgene\t1\t20\t.\t+\t.\tID=g1;Name=TestGene
        """
        let gff3URL = tempDirectory.appendingPathComponent("annotations.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        // Create a BED file
        let bedContent = """
        chr1\t5\t15\tpeak1\t500\t+
        """
        let bedURL = tempDirectory.appendingPathComponent("peaks.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

        // Detect formats using FormatRegistry
        let registry = FormatRegistry.shared

        let fastaFormat = await registry.detectFormat(url: fastaURL)
        XCTAssertEqual(fastaFormat, .fasta, "Should detect .fa as FASTA")

        let gff3Format = await registry.detectFormat(url: gff3URL)
        XCTAssertEqual(gff3Format, .gff3, "Should detect .gff3 as GFF3")

        let bedFormat = await registry.detectFormat(url: bedURL)
        XCTAssertEqual(bedFormat, .bed, "Should detect .bed as BED")

        // Verify each file can be loaded with its corresponding reader
        let fastaReader = try FASTAReader(url: fastaURL)
        let sequences = try await fastaReader.readAll(alphabet: .dna)
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "chr1")

        let gff3Reader = GFF3Reader()
        let gff3Annotations = try await gff3Reader.readAsAnnotations(from: gff3URL)
        XCTAssertEqual(gff3Annotations.count, 1)
        XCTAssertEqual(gff3Annotations[0].name, "TestGene")

        let bedReader = BEDReader()
        let bedAnnotations = try await bedReader.readAsAnnotations(from: bedURL)
        XCTAssertEqual(bedAnnotations.count, 1)
        XCTAssertEqual(bedAnnotations[0].name, "peak1")
    }

    /// Loads sequences from FASTA and annotations from GFF3, then verifies
    /// they can be associated by chromosome name through the Core data model.
    func testSequenceAnnotationMerge() async throws {
        // Create FASTA with two chromosomes
        let fastaContent = """
        >chr1 Chromosome 1
        ATCGATCGATCGATCGATCGATCGATCGATCGATCGATCG
        >chr2 Chromosome 2
        GCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTAGCTA
        """
        let fastaURL = tempDirectory.appendingPathComponent("genome.fa")
        try fastaContent.write(to: fastaURL, atomically: true, encoding: .utf8)

        // Create GFF3 with annotations on both chromosomes
        let gff3Content = """
        ##gff-version 3
        chr1\t.\tgene\t1\t20\t.\t+\t.\tID=g1;Name=GeneOnChr1
        chr1\t.\texon\t5\t15\t.\t+\t.\tID=e1;Parent=g1;Name=ExonOnChr1
        chr2\t.\tgene\t10\t30\t.\t-\t.\tID=g2;Name=GeneOnChr2
        """
        let gff3URL = tempDirectory.appendingPathComponent("annotations.gff3")
        try gff3Content.write(to: gff3URL, atomically: true, encoding: .utf8)

        // Load both
        let fastaReader = try FASTAReader(url: fastaURL)
        let sequences = try await fastaReader.readAll(alphabet: .dna)

        let gff3Reader = GFF3Reader()
        let annotations = try await gff3Reader.readAsAnnotations(from: gff3URL)

        // Associate annotations with sequences by chromosome name
        for sequence in sequences {
            let matching = annotations.filter { $0.belongsToSequence(named: sequence.name) }

            if sequence.name == "chr1" {
                XCTAssertEqual(matching.count, 2,
                               "chr1 should have 2 annotations (gene + exon)")
                XCTAssertTrue(matching.contains { $0.name == "GeneOnChr1" })
                XCTAssertTrue(matching.contains { $0.name == "ExonOnChr1" })

                // Verify annotation coordinates are within sequence bounds
                for ann in matching {
                    XCTAssertGreaterThanOrEqual(ann.intervals[0].start, 0)
                    XCTAssertLessThanOrEqual(ann.intervals[0].end, sequence.length)
                }
            } else if sequence.name == "chr2" {
                XCTAssertEqual(matching.count, 1,
                               "chr2 should have 1 annotation")
                XCTAssertEqual(matching[0].name, "GeneOnChr2")
                XCTAssertEqual(matching[0].strand, .reverse)
            }
        }

        // Build a FeatureTrack for chr1 annotations
        let chr1Annotations = annotations.filter { $0.chromosome == "chr1" }
        let track = FeatureTrack(name: "chr1 Genes", annotations: chr1Annotations)
        XCTAssertEqual(track.name, "chr1 Genes")
    }

    // MARK: - 5. Reference Bundle Integration

    /// Creates a `BundleManifest`, saves it to JSON, reloads it, and verifies
    /// that all fields including nested structures survive the round-trip.
    func testReferenceBundleManifestRoundTrip() throws {
        let createdDate = Date(timeIntervalSinceReferenceDate: 700000000)
        let modifiedDate = Date(timeIntervalSinceReferenceDate: 700001000)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Human Reference Genome",
            identifier: "org.lungfish.test.hg38",
            description: "GRCh38 reference for testing",
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            source: SourceInfo(
                organism: "Homo sapiens",
                commonName: "Human",
                taxonomyId: 9606,
                assembly: "GRCh38",
                assemblyAccession: "GCF_000001405.40",
                database: "NCBI"
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 3_088_286_401,
                chromosomes: [
                    ChromosomeInfo(
                        name: "chr1",
                        length: 248_956_422,
                        offset: 6,
                        lineBases: 70,
                        lineWidth: 71,
                        aliases: ["1", "CM000663.2"],
                        isPrimary: true,
                        isMitochondrial: false
                    ),
                    ChromosomeInfo(
                        name: "chrM",
                        length: 16_569,
                        offset: 999999,
                        lineBases: 70,
                        lineWidth: 71,
                        aliases: ["MT"],
                        isPrimary: false,
                        isMitochondrial: true
                    ),
                ],
                md5Checksum: "abc123def456"
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "NCBI RefSeq Genes",
                    description: "Gene annotations from NCBI",
                    path: "annotations/genes.bb",
                    annotationType: .gene,
                    featureCount: 60000,
                    source: "NCBI",
                    version: "110"
                ),
            ],
            variants: [
                VariantTrackInfo(
                    id: "dbsnp",
                    name: "dbSNP",
                    description: "Common variants from dbSNP",
                    path: "variants/dbsnp.bcf",
                    indexPath: "variants/dbsnp.bcf.csi",
                    variantType: .snp,
                    variantCount: 150_000_000,
                    source: "NCBI",
                    version: "156"
                ),
            ],
            tracks: [
                SignalTrackInfo(
                    id: "gc_content",
                    name: "GC Content",
                    description: "GC content in 5bp windows",
                    path: "tracks/gc_content.bw",
                    signalType: .gcContent,
                    minValue: 0.0,
                    maxValue: 1.0,
                    source: "Computed"
                ),
            ]
        )

        // Save to temp directory (mimicking a bundle structure)
        let bundleDir = tempDirectory.appendingPathComponent("test.lungfishref")
        try FileManager.default.createDirectory(
            at: bundleDir,
            withIntermediateDirectories: true
        )
        try manifest.save(to: bundleDir)

        // Reload
        let loaded = try BundleManifest.load(from: bundleDir)

        // Verify all top-level fields
        XCTAssertEqual(loaded.formatVersion, "1.0")
        XCTAssertEqual(loaded.name, "Human Reference Genome")
        XCTAssertEqual(loaded.identifier, "org.lungfish.test.hg38")
        XCTAssertEqual(loaded.description, "GRCh38 reference for testing")

        // Verify source info
        XCTAssertEqual(loaded.source.organism, "Homo sapiens")
        XCTAssertEqual(loaded.source.commonName, "Human")
        XCTAssertEqual(loaded.source.taxonomyId, 9606)
        XCTAssertEqual(loaded.source.assembly, "GRCh38")
        XCTAssertEqual(loaded.source.assemblyAccession, "GCF_000001405.40")
        XCTAssertEqual(loaded.source.database, "NCBI")

        // Verify genome info
        XCTAssertEqual(loaded.genome!.path, "genome/sequence.fa.gz")
        XCTAssertEqual(loaded.genome!.indexPath, "genome/sequence.fa.gz.fai")
        XCTAssertEqual(loaded.genome!.gzipIndexPath, "genome/sequence.fa.gz.gzi")
        XCTAssertEqual(loaded.genome!.totalLength, 3_088_286_401)
        XCTAssertEqual(loaded.genome!.md5Checksum, "abc123def456")

        // Verify chromosomes
        XCTAssertEqual(loaded.genome!.chromosomes.count, 2)
        let chr1 = loaded.genome!.chromosomes[0]
        XCTAssertEqual(chr1.name, "chr1")
        XCTAssertEqual(chr1.length, 248_956_422)
        XCTAssertEqual(chr1.offset, 6)
        XCTAssertEqual(chr1.lineBases, 70)
        XCTAssertEqual(chr1.lineWidth, 71)
        XCTAssertEqual(chr1.aliases, ["1", "CM000663.2"])
        XCTAssertTrue(chr1.isPrimary)
        XCTAssertFalse(chr1.isMitochondrial)

        let chrM = loaded.genome!.chromosomes[1]
        XCTAssertEqual(chrM.name, "chrM")
        XCTAssertEqual(chrM.length, 16_569)
        XCTAssertTrue(chrM.isMitochondrial)
        XCTAssertFalse(chrM.isPrimary)
        XCTAssertEqual(chrM.aliases, ["MT"])

        // Verify annotation tracks
        XCTAssertEqual(loaded.annotations.count, 1)
        XCTAssertEqual(loaded.annotations[0].id, "genes")
        XCTAssertEqual(loaded.annotations[0].name, "NCBI RefSeq Genes")
        XCTAssertEqual(loaded.annotations[0].path, "annotations/genes.bb")
        XCTAssertEqual(loaded.annotations[0].annotationType, .gene)
        XCTAssertEqual(loaded.annotations[0].featureCount, 60000)

        // Verify variant tracks
        XCTAssertEqual(loaded.variants.count, 1)
        XCTAssertEqual(loaded.variants[0].id, "dbsnp")
        XCTAssertEqual(loaded.variants[0].name, "dbSNP")
        XCTAssertEqual(loaded.variants[0].variantType, .snp)
        XCTAssertEqual(loaded.variants[0].variantCount, 150_000_000)
        XCTAssertEqual(loaded.variants[0].indexPath, "variants/dbsnp.bcf.csi")

        // Verify signal tracks
        XCTAssertEqual(loaded.tracks.count, 1)
        XCTAssertEqual(loaded.tracks[0].id, "gc_content")
        XCTAssertEqual(loaded.tracks[0].signalType, .gcContent)
        XCTAssertEqual(loaded.tracks[0].minValue, 0.0)
        XCTAssertEqual(loaded.tracks[0].maxValue, 1.0)

        // Verify validation passes
        let errors = loaded.validate()
        XCTAssertTrue(errors.isEmpty, "Manifest should pass validation, got: \(errors)")

        // Verify equality (Equatable conformance)
        XCTAssertEqual(manifest, loaded)
    }
}
