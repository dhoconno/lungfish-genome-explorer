// BundleShapeFixtures.swift - One FASTQ bundle of every shape a sequence command resolves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishIO

/// One `.lungfishfastq` bundle of each shape the app and `lungfish-cli`
/// resolve, in a project's `Imports` folder, with read names that say where
/// each read came from. The app's resolution of each shape is in lane 1n's
/// before and after tables.
struct BundleShapeFixtures {
    /// A root bundle with one file, reads s1 to s3.
    let single: URL
    /// A root bundle whose two chunk files are listed in `source-files.json`
    /// (the ONT import shape), reads m1 and m2 then m3 to m5.
    let multiFile: URL
    let multiFileChunks: [URL]
    /// A virtual bundle that orients s1 and s3 of `single`.
    let oriented: URL
    /// A `fullPaired` derivative, R1 (p1/1, p2/1) and R2 (p1/2, p2/2).
    let paired: URL
    let pairedFiles: [URL]
    /// A `fullMixed` derivative, merged reads x1 to x3 and the unmerged pair u1.
    let mixed: URL
    let mixedFiles: [URL]
    /// A `fullFASTA` derivative, records f1 and f2.
    let fasta: URL
    /// A `full` derivative, reads g1 and g2.
    let full: URL

    init(in imports: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        func bundle(_ name: String) throws -> URL {
            let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        single = try bundle("single")
        try Self.fastq(["s1", "s2", "s3"]).write(to: single.appendingPathComponent("single.fastq"), atomically: true, encoding: .utf8)

        multiFile = try bundle("multi")
        let chunks = multiFile.appendingPathComponent("chunks", isDirectory: true)
        try fm.createDirectory(at: chunks, withIntermediateDirectories: true)
        multiFileChunks = [chunks.appendingPathComponent("run_0.fastq"), chunks.appendingPathComponent("run_1.fastq")]
        try Self.fastq(["m1", "m2"]).write(to: multiFileChunks[0], atomically: true, encoding: .utf8)
        try Self.fastq(["m3", "m4", "m5"]).write(to: multiFileChunks[1], atomically: true, encoding: .utf8)
        try Self.fastq(["m1"]).write(to: multiFile.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: multiFile)

        oriented = try bundle("single-oriented")
        try "s1\t+\ns3\t-\n".write(to: oriented.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try Self.fastq(["s1"]).write(to: oriented.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try Self.saveDerivedManifest(
            in: oriented,
            root: "@/Imports/single.lungfishfastq",
            rootFile: "single.fastq",
            payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
            kind: .orient,
            pairing: .singleEnd
        )

        paired = try bundle("paired")
        pairedFiles = [paired.appendingPathComponent("sample_R1.fastq"), paired.appendingPathComponent("sample_R2.fastq")]
        try Self.fastq(["p1/1", "p2/1"]).write(to: pairedFiles[0], atomically: true, encoding: .utf8)
        try Self.fastq(["p1/2", "p2/2"]).write(to: pairedFiles[1], atomically: true, encoding: .utf8)
        try Self.saveDerivedManifest(
            in: paired,
            root: ".",
            rootFile: "sample_R1.fastq",
            payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
            kind: .interleaveReformat,
            pairing: .pairedEnd
        )

        let mixedBundle = try bundle("mixed")
        let mixedMembers = ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"].map {
            mixedBundle.appendingPathComponent($0)
        }
        mixed = mixedBundle
        mixedFiles = mixedMembers
        try Self.fastq(["x1", "x2", "x3"]).write(to: mixedMembers[0], atomically: true, encoding: .utf8)
        try Self.fastq(["u1/1"]).write(to: mixedMembers[1], atomically: true, encoding: .utf8)
        try Self.fastq(["u1/2"]).write(to: mixedMembers[2], atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 3),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
        ])
        try Self.saveDerivedManifest(
            in: mixed,
            root: ".",
            rootFile: "merged.fastq",
            payload: .fullMixed(classification),
            kind: .pairedEndMerge,
            pairing: .pairedEnd,
            classification: classification
        )

        fasta = try bundle("converted")
        try ">f1\nACGTACGTAC\n>f2\nACGTACGTAC\n".write(to: fasta.appendingPathComponent("converted.fasta"), atomically: true, encoding: .utf8)
        try Self.saveDerivedManifest(
            in: fasta,
            root: ".",
            rootFile: "converted.fasta",
            payload: .fullFASTA(fastaFilename: "converted.fasta"),
            kind: .translate,
            pairing: .singleEnd,
            format: .fasta
        )

        full = try bundle("full")
        try Self.fastq(["g1", "g2"]).write(to: full.appendingPathComponent("full.fastq"), atomically: true, encoding: .utf8)
        try Self.saveDerivedManifest(
            in: full,
            root: ".",
            rootFile: "full.fastq",
            payload: .full(fastqFilename: "full.fastq"),
            kind: .deduplicate,
            pairing: .singleEnd
        )
    }

    static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// The record names of a FASTQ or FASTA file, in file order.
    static func readNames(in url: URL) throws -> [String] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.first?.hasPrefix(">") == true {
            return lines.filter { $0.hasPrefix(">") }.map { String($0.dropFirst()) }
        }
        return lines.enumerated().compactMap { index, line in
            index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil
        }
    }

    private static func saveDerivedManifest(
        in bundle: URL,
        root: String,
        rootFile: String,
        payload: FASTQDerivativePayload,
        kind: FASTQDerivativeOperationKind,
        pairing: IngestionMetadata.PairingMode,
        format: SequenceFormat = .fastq,
        classification: ReadClassification? = nil
    ) throws {
        let operation = FASTQDerivativeOperation(kind: kind)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: bundle.deletingPathExtension().lastPathComponent,
                parentBundleRelativePath: root,
                rootBundleRelativePath: root,
                rootFASTQFilename: rootFile,
                payload: payload,
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: pairing,
                readClassification: classification,
                sequenceFormat: format
            ),
            in: bundle
        )
    }
}
