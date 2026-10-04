// MergeBundleOverRawRootFixture.swift - A PE merge bundle whose recorded root is the raw import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// A raw interleaved import and a PE merge bundle (`fullMixed`) made from it,
/// in a project's `Imports` folder, as the app records them: the merge
/// bundle's root is the raw import (Phase 1.5 lane A7, D1).
///
/// Fragments x1 to x3 were merged, so the merge bundle holds them as one
/// 30-base read each, while the raw import holds them as two 20-base mates.
/// Fragment u1 was not merged and is a pair in both. Every read starts with
/// ``barcode`` so a demultiplex assigns all of them to one barcode. Read
/// names carry Casava comments, so a merged read and its raw mates share a
/// read ID, as bbmerge writes them.
public struct MergeBundleOverRawRootFixture {
    public static let barcode = "ACGTTGCAAGTC"
    /// A raw mate, 20 bases.
    public static let mateSequence = barcode + "ACGTACGT"
    /// A merged read, 30 bases.
    public static let mergedSequence = barcode + "GATTACAGATTACAGATT"
    public static let mergedFragments = ["x1", "x2", "x3"]

    public let imports: URL
    public let rawRoot: URL
    public let mergeBundle: URL

    public init(project: URL) throws {
        let fm = FileManager.default
        imports = project.appendingPathComponent("Imports", isDirectory: true)
        rawRoot = imports.appendingPathComponent("raw.lungfishfastq", isDirectory: true)
        mergeBundle = imports.appendingPathComponent("merged.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: mergeBundle, withIntermediateDirectories: true)

        let rawRecords = (Self.mergedFragments + ["u1"]).flatMap { name in
            [("\(name) 1:N:0:1", Self.mateSequence), ("\(name) 2:N:0:1", Self.mateSequence)]
        }
        try Self.write(rawRecords, to: rawRoot.appendingPathComponent("raw.fastq"))
        try Self.write(
            Self.mergedFragments.map { ("\($0) 1:N:0:1", Self.mergedSequence) },
            to: mergeBundle.appendingPathComponent("merged.fastq")
        )
        try Self.write([("u1 1:N:0:1", Self.mateSequence)], to: mergeBundle.appendingPathComponent("unmerged_R1.fastq"))
        try Self.write([("u1 2:N:0:1", Self.mateSequence)], to: mergeBundle.appendingPathComponent("unmerged_R2.fastq"))

        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 3),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
        ])
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "merged",
                parentBundleRelativePath: "@/Imports/raw.lungfishfastq",
                rootBundleRelativePath: "@/Imports/raw.lungfishfastq",
                rootFASTQFilename: "raw.fastq",
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 5, baseCount: 130),
                pairingMode: .interleaved,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: mergeBundle
        )
    }

    /// A virtual subset of the merge bundle written before lane A7: its
    /// parent is the merge bundle and its root the raw import. Its read-ID
    /// list names `readIDs`.
    public func legacySubset(named name: String, readIDs: [String]) throws -> URL {
        let bundle = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try (readIDs.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try Self.write(
            readIDs.map { ("\($0) 1:N:0:1", Self.mergedSequence) },
            to: bundle.appendingPathComponent("preview.fastq")
        )
        let merge = FASTQDerivativeOperation(kind: .pairedEndMerge)
        let filter = FASTQDerivativeOperation(kind: .lengthFilter, minLength: 25)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: "@/Imports/merged.lungfishfastq",
                rootBundleRelativePath: "@/Imports/raw.lungfishfastq",
                rootFASTQFilename: "raw.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [merge, filter],
                operation: filter,
                cachedStatistics: .placeholder(readCount: readIDs.count, baseCount: Int64(readIDs.count * 30)),
                pairingMode: .interleaved,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    /// Record IDs (first word) and sequences of a FASTQ file, in file order.
    public static func records(in url: URL) throws -> [(id: String, sequence: String)] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var records: [(String, String)] = []
        var index = 0
        while index + 1 < lines.count {
            let header = lines[index]
            if header.hasPrefix("@") {
                let id = header.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                records.append((id, String(lines[index + 1])))
            }
            index += 4
        }
        return records
    }

    private static func write(_ records: [(String, String)], to url: URL) throws {
        let text = records.map { id, sequence in
            "@\(id)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
