// ViewerGraphicBundleSourceTests.swift - The contig names and files a bundle figure reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.30 (GFX-2, M3). The annotation track queries the names the live bundle query tries, the read
// track takes the live view's alias map, and a bgzipped FASTA is read with its `.gzi`, which the record names.

import Compression
import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import XCTest

final class ViewerGraphicBundleSourceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewerGraphicBundleSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A bundle with `chr1` (alias `1`) of 3,000 bases and the annotation track `genes`, whose one gene at 1101 to
    /// 1400 the database holds under `databaseContig`. With `bgzip`, the FASTA is `sequence.fa.gz` with its `.gzi`.
    private func makeBundle(
        _ name: String, databaseContig: String = "chr1", bgzip: Bool = false,
        alignments: [AlignmentTrackInfo] = []
    ) throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        for sub in ["genome", "annotations", "alignments"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let bases = String(repeating: "ACGTTGCA", count: 375)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        let fasta = Data((">chr1\n" + lines.joined(separator: "\n") + "\n").utf8)
        let fastaPath = bgzip ? "genome/sequence.fa.gz" : "genome/sequence.fa"
        try (bgzip ? Self.bgzf(fasta) : fasta).write(to: bundle.appendingPathComponent(fastaPath))
        try "chr1\t3000\t6\t60\t61\n".write(to: bundle.appendingPathComponent(fastaPath + ".fai"), atomically: true, encoding: .utf8)
        if bgzip {
            try Data(count: 8).write(to: bundle.appendingPathComponent(fastaPath + ".gzi"))
        }
        let bed = folder.appendingPathComponent("\(name).bed")
        try "\(databaseContig)\t1100\t1400\tgene-a\t0\t+\n".write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db"))
        try BundleManifest(
            name: "Source Fixture",
            identifier: "org.lungfish.source-fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: fastaPath, indexPath: fastaPath + ".fai", gzipIndexPath: bgzip ? fastaPath + ".gzi" : nil,
                totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61, aliases: ["1"])]
            ),
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db")],
            alignments: alignments,
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    private func figure(_ bundleURL: URL, tracks: [String]) async throws -> ViewerGraphicFigure {
        let bundle = try ViewerGraphicBundle(url: bundleURL)
        return try await ViewerGraphicExport.figure(
            bundle: bundle, region: try bundle.region(contig: "chr1", start: 1100, end: 1300), trackIDs: tracks,
            settings: .init(region: "chr1:1101-1300", width: 600, format: .png), viewState: nil, viewStateURL: nil
        )
    }

    /// One BGZF block holding `data`, then the empty end block, as `bgzip` writes a file under 64 KB.
    static func bgzf(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var block = Data([0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0, 0xFF, 6, 0, 0x42, 0x43, 2, 0])
        let size = 18 + deflated.count + 8 - 1
        block += Data([UInt8(size & 0xFF), UInt8(size >> 8)]) + deflated
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        for value in [crc ^ 0xFFFF_FFFF, UInt32(data.count)] {
            block += Data([0, 8, 16, 24].map { UInt8((value >> $0) & 0xFF) })
        }
        return block + Data([
            0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0, 0xFF, 6, 0, 0x42, 0x43, 2, 0, 0x1B, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ])
    }

    /// 13.29 fix 2, fix 3. The live bundle query tries the contig's name, its aliases and the database names
    /// `mapVCFChromosomes` maps to it, so a database that holds the gene under `1` draws it as one under `chr1` does.
    func testAnAnnotationDatabaseUnderAnAliasDrawsAsUnderTheName() async throws {
        let named = try await figure(try makeBundle("named"), tracks: ["genes"])
        let aliased = try await figure(try makeBundle("aliased", databaseContig: "1"), tracks: ["genes"])
        XCTAssertEqual(
            String(decoding: try aliased.scene.goldenJSON(), as: UTF8.self),
            String(decoding: try named.scene.goldenJSON(), as: UTF8.self)
        )
        XCTAssertTrue(named.scene.items.count > 2, "the gene is drawn")
        let versioned = try ViewerGraphicBundle(url: try makeBundle("versioned", databaseContig: "chr1.2"))
        XCTAssertEqual(
            try versioned.annotationChromosomeNames(
                contig: "chr1", databaseURL: versioned.url.appendingPathComponent("annotations/genes.db")
            ),
            ["chr1", "1", "chr1.2"]
        )
    }

    /// 13.29 fix 2, fix 3. The live view maps a manifest contig no alignment names to the unused alignment name of
    /// the same length, read from the alignment tracks' metadata databases, and the figure names each database read.
    func testAlignmentAliasesFollowTheLiveViewsLengthRule() throws {
        let track = AlignmentTrackInfo(
            id: "reads", name: "Reads", sourcePath: "alignments/reads.bam", indexPath: "alignments/reads.bam.bai",
            metadataDBPath: "alignments/reads.stats.db"
        )
        let bundleURL = try makeBundle("aliases", alignments: [track])
        let databaseURL = bundleURL.appendingPathComponent("alignments/reads.stats.db")
        let database = try AlignmentMetadataDatabase.create(at: databaseURL)
        database.addChromosomeStats(chromosome: "NC_000001.1", length: 3000, mapped: 10, unmapped: 0)
        database.addChromosomeStats(chromosome: "NC_000099.1", length: 99, mapped: 1, unmapped: 0)
        let aliases = try ViewerGraphicBundle(url: bundleURL).alignmentChromosomeAliases()
        XCTAssertEqual(aliases.map, ["chr1": "NC_000001.1"])
        XCTAssertEqual(aliases.opened.map(\.lastPathComponent), ["reads.stats.db"])
        let plain = try ViewerGraphicBundle(url: try makeBundle("no-alignments")).alignmentChromosomeAliases()
        XCTAssertEqual(plain.map, [:])
        XCTAssertEqual(plain.opened, [])
    }

    /// MD20 and the manager's addition. A bgzipped FASTA is read through `BgzipIndexedFASTAReader` and draws the
    /// plain FASTA's scene, and the record's inputs name its `.gzi` after its `.fai`.
    func testABgzippedFASTADrawsThePlainScene() async throws {
        let plain = try await figure(try makeBundle("plain"), tracks: [ViewerFigureSequenceTrack.trackID])
        let compressed = try await figure(try makeBundle("bgzip", bgzip: true), tracks: [ViewerFigureSequenceTrack.trackID])
        XCTAssertEqual(
            String(decoding: try compressed.scene.goldenJSON(), as: UTF8.self),
            String(decoding: try plain.scene.goldenJSON(), as: UTF8.self)
        )
        XCTAssertEqual(
            compressed.inputURLs.map(\.lastPathComponent),
            ["manifest.json", "sequence.fa.gz", "sequence.fa.gz.fai", "sequence.fa.gz.gzi"]
        )
        XCTAssertEqual(plain.inputURLs.map(\.lastPathComponent), ["manifest.json", "sequence.fa", "sequence.fa.fai"])
    }
}
