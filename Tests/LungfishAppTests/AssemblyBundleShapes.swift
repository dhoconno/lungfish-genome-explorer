// AssemblyBundleShapes.swift - FASTQ bundles of each shape an assembly can name, for the app's assembly tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishIO

/// One `.lungfishfastq` bundle of each shape an assembly can name, in a
/// project's `Imports` folder, and two loose FASTQ files beside it. Read names
/// say where each read came from, so a test can tell which reads a run used
/// (R3, lane 1q).
struct AssemblyBundleShapes {
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
    /// A root bundle whose one file holds the strictly interleaved pairs i1 to i3.
    let interleaved: URL
    /// Two FASTQ files outside any bundle, read a1 and reads b1 and b2.
    let looseFiles: [URL]

    init(in project: URL) throws {
        let fm = FileManager.default
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        func bundle(_ name: String) throws -> URL {
            let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ names: [String], to url: URL) throws {
            try Self.fastq(names).write(to: url, atomically: true, encoding: .utf8)
        }

        single = try bundle("single")
        try write(["s1", "s2", "s3"], to: single.appendingPathComponent("single.fastq"))

        multiFile = try bundle("multi")
        let chunks = multiFile.appendingPathComponent("chunks", isDirectory: true)
        try fm.createDirectory(at: chunks, withIntermediateDirectories: true)
        multiFileChunks = [chunks.appendingPathComponent("run_0.fastq"), chunks.appendingPathComponent("run_1.fastq")]
        try write(["m1", "m2"], to: multiFileChunks[0])
        try write(["m3", "m4", "m5"], to: multiFileChunks[1])
        try write(["m1"], to: multiFile.appendingPathComponent("preview.fastq"))
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: multiFile)

        oriented = try bundle("single-oriented")
        try "s1\t+\ns3\t-\n".write(to: oriented.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try write(["s1"], to: oriented.appendingPathComponent("preview.fastq"))
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
        try write(["p1/1", "p2/1"], to: pairedFiles[0])
        try write(["p1/2", "p2/2"], to: pairedFiles[1])
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
        try write(["x1", "x2", "x3"], to: mixedMembers[0])
        try write(["u1/1"], to: mixedMembers[1])
        try write(["u1/2"], to: mixedMembers[2])
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

        interleaved = try bundle("interleaved")
        try write(["i1/1", "i1/2", "i2/1", "i2/2", "i3/1", "i3/2"], to: interleaved.appendingPathComponent("interleaved.fastq"))

        let reads = project.appendingPathComponent("Reads", isDirectory: true)
        try fm.createDirectory(at: reads, withIntermediateDirectories: true)
        looseFiles = [reads.appendingPathComponent("loose_a.fastq"), reads.appendingPathComponent("loose_b.fastq")]
        try write(["a1"], to: looseFiles[0])
        try write(["b1", "b2"], to: looseFiles[1])
    }

    static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// The record names of a FASTQ file, in file order.
    static func readNames(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }

    private static func saveDerivedManifest(
        in bundle: URL,
        root: String,
        rootFile: String,
        payload: FASTQDerivativePayload,
        kind: FASTQDerivativeOperationKind,
        pairing: IngestionMetadata.PairingMode,
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
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }
}
