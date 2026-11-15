// SingleCellNotHost+Run.swift - The pass at import: the set's extras, one samtools view a sample, the raw matrix by path (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The pass runs at `import rnaseq` before the writer, so the result and its `cells.sqlite` are written once
// (BIO-NOTHOST-BARCODE item 8). Each BAM and raw matrix is read by path, named by sha256 in the record and never copied.
// samtools prints the alignments of the set's not-host records into a temporary file, which the counter reads 1 MiB at
// a time and which is removed before the writer starts.

import Foundation
import LungfishCore
import LungfishIO

extension SingleCellNotHostPass {
    /// The set as the import reads it.
    public struct ReferenceSet: Sendable {
        public var manifest: ReferenceSetManifest
        public var extras: [SingleCellNotHostExtra]
        public var records: [SingleCellNotHostRecord]
        public var genesTable: URL
        public var geneIDs: Set<String>
        public var notHostFeatures: [String]
    }

    /// Reads the set's manifest, its gene table and the length of each not-host record from the extra's FASTA. A mask
    /// of the set's schema 1 holds no intervals, so no extra has a mask yet (BIO-NOTHOST-BARCODE item 6).
    public static func readSet(_ url: URL) throws -> ReferenceSet {
        let manifest = try ReferenceSetManifest.load(from: url)
        let extras = manifest.extras.filter(\.notHost).map {
            SingleCellNotHostExtra(name: $0.name, kind: $0.kind, records: $0.records, mask: nil)
        }
        var records: [SingleCellNotHostRecord] = []
        for extra in manifest.extras where extra.notHost {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(extra.path)) else {
                throw SingleCellNotHostError.extraRecordUnreadable(extra: extra.name, file: extra.path)
            }
            var lengths: [String: Int] = [:]
            var current: String?
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                if line.hasPrefix(">") {
                    current = String(line.dropFirst().prefix { !$0.isWhitespace })
                } else if let current {
                    lengths[current, default: 0] += line.filter { !$0.isWhitespace }.count
                }
            }
            for record in extra.records {
                guard let length = lengths[record] else { throw SingleCellNotHostError.extraRecordUnreadable(extra: extra.name, file: extra.path) }
                records.append(.init(name: record, length: length))
            }
        }
        let genes = url.appendingPathComponent(manifest.derived.genes.path)
        let lines = try String(contentsOf: genes, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst()
        let rows = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        return ReferenceSet(
            manifest: manifest, extras: extras, records: records, genesTable: genes,
            geneIDs: Set(rows.compactMap { $0.first.map(String.init) }),
            notHostFeatures: rows.filter { $0.count > 5 && $0[5] == "true" }.map { String($0[0]) })
    }

    /// The raw matrix and barcodes of a folder, Cell Ranger's `raw_feature_bc_matrix/` or STARsolo's `Solo.out/Gene/raw/`.
    static func rawFiles(_ folder: SingleCellFolder) throws -> (matrix: URL, barcodes: URL) {
        let raw = folder.url.appendingPathComponent(folder.tool == .starsolo ? "Solo.out/Gene/raw" : "raw_feature_bc_matrix", isDirectory: true)
        func find(_ name: String) -> URL? {
            [name + ".gz", name].map { raw.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let matrix = find("matrix.mtx"), let barcodes = find("barcodes.tsv") else {
            throw SingleCellNotHostError.noRawMatrix(sample: folder.sample, folder: folder.url.lastPathComponent)
        }
        return (matrix, barcodes)
    }

    /// Counts each folder's BAM over the set's not-host records and returns the result and the record's facts.
    public static func run(
        _ folders: [SingleCellFolder], set: ReferenceSet, bams: [String: URL], runner: NativeToolRunner = .shared
    ) async throws -> (SingleCellNotHostResult, [String: ParameterValue]) {
        if let stray = bams.keys.sorted().first(where: { name in !folders.contains { $0.sample == name } }) {
            throw SingleCellNotHostError.bamOfNoSample(stray, samples: folders.map(\.sample))
        }
        if let first = folders.first, let gene = zip(first.featureIDs, first.featureTypeOfRow)
            .first(where: { $1 == SingleCellFolderReader.geneExpression && !set.geneIDs.contains($0) })?.0 {
            throw SingleCellNotHostError.geneNotInSet(gene: gene, sample: first.sample, set: set.manifest.id)
        }
        var samples: [SingleCellNotHostSample] = []
        var bamFacts: [ParameterValue] = []
        var rawFacts: [ParameterValue] = []
        var poolFacts: [ParameterValue] = []
        for folder in folders {
            try Task.checkCancellation()
            guard let bam = bams[folder.sample] else { throw SingleCellNotHostError.noBAMForSample(folder.sample) }
            let indexes = [bam.path + ".bai", bam.deletingPathExtension().path + ".bai", bam.path + ".csi"]
            guard indexes.contains(where: FileManager.default.fileExists(atPath:)) else { throw SingleCellNotHostError.bamNotIndexed(bam.path) }
            let header = try await runner.run(.samtools, arguments: ["view", "-H", bam.path])
            guard header.exitCode == 0 else { throw SingleCellNotHostError.samtoolsFailed(bam: bam.lastPathComponent, words: header.stderr) }
            try SingleCellNotHostCounter.checkHeader(header.stdout, bam: bam.lastPathComponent, records: set.records)
            var counter = SingleCellNotHostCounter(extras: set.extras)
            let sam = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-nothost-\(UUID().uuidString).sam")
            defer { try? FileManager.default.removeItem(at: sam) }
            let view = try await runner.runWithFileOutput(.samtools, arguments: ["view", bam.path] + counter.recordNames, outputFile: sam)
            guard view.exitCode == 0 else { throw SingleCellNotHostError.samtoolsFailed(bam: bam.lastPathComponent, words: view.stderr) }
            try counter.add(samFile: sam)
            let files = try rawFiles(folder)
            let raw = try SingleCellRawMatrix.read(matrix: files.matrix, barcodes: files.barcodes, sample: folder.sample)
            let pool = SingleCellAmbientPool(raw)
            let cells = try MatrixMarketReader.textLines(of: folder.url.appendingPathComponent(folder.barcodes))
            samples.append(sample(folder.sample, cells: cells, raw: raw, pool: pool, tallies: counter.tallies(), extras: set.extras))
            let (bamSHA, bamSize) = try SingleCellFolderReader.hashFile(bam)
            let (rawSHA, _) = try SingleCellFolderReader.hashFile(files.matrix)
            bamFacts.append(.string("\(folder.sample): \(bam.path) (sha256 \(bamSHA), \(bamSize) bytes)"))
            rawFacts.append(.string("\(folder.sample): \(files.matrix.path) (sha256 \(rawSHA))"))
            poolFacts.append(.string("\(folder.sample): " + (pool.words ?? "ranks \(pool.firstRank ?? 0)-\(pool.lastRank ?? 0), \(pool.members.count) barcodes of \(pool.barcodesWithUMI) with a UMI, UMIs \(pool.umiRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""), \(pool.umis) UMIs")))
        }
        let version = await runner.getToolVersion(.samtools) ?? RNASeqImportFacts.notRecorded
        let facts: [String: ParameterValue] = [
            "notHostReferenceSet": .string(set.manifest.id),
            "notHostBAMs": .array(bamFacts),
            "notHostRawMatrices": .array(rawFacts),
            "notHostMasks": .array(set.extras.map { .string("\($0.name) (\($0.kind.rawValue)): " + ($0.maskWords.isEmpty ? "no rRNA mask, none needed" : $0.maskWords)) }),
            "ambientPools": .array(poolFacts),
            "notHostRule": .string("A UMI is a unique (CB, UB) pair of NH 1 primary alignments, kept per record. The pool is ranks 45,000 to 90,000 by raw UMI, ties in barcode-byte order. A cell is flagged at 2 or more UMIs and BH q under 0.001 of the Poisson upper tail at rate (pool not-host UMIs + 1) / pool UMIs."),
            "samtoolsVersion": .string(version),
        ]
        return (SingleCellNotHostResult(extras: set.extras, records: set.records, samples: samples), facts)
    }
}
