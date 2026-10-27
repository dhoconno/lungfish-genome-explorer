// FASTQBundleExportFixtures.swift - The three FASTQ bundles the sidebar export tests build
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38. The bundles the pin (QA 1) ran the in-app writer on at the lane base, which the parity class
// `FASTQBundleExportCLIGUIParityReplayTests` now runs on its three sides: a plain bundle, a bundle of three source
// chunks and a derived bundle. The pin tests went with the in-app writer, and its builders stayed here.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

enum FASTQBundleExportFixtures {
    static let reads = "@r1\nACGT\n+\nIIII\n@r2\nTTGA\n+\nIIII\n"

    /// A bundle with one FASTQ file named `reads.fastq`.
    static func makePlainBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("plain.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(reads.utf8).write(to: bundle.appendingPathComponent("reads.fastq"))
        return bundle
    }

    /// A bundle whose reads sit in three chunks that `source-files.json` lists in order.
    static func makeChunkedBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("chunked.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for index in 0..<3 {
            let data = Data("@c\(index)\nACGT\n+\nIIII\n".utf8)
            try data.write(to: chunks.appendingPathComponent("sample_\(index).fastq"))
            entries.append(.init(
                filename: "chunks/sample_\(index).fastq", originalPath: "/run/sample_\(index).fastq",
                sizeBytes: Int64(data.count), isSymlink: false
            ))
        }
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        return bundle
    }

    /// A derived bundle whose payload is a full FASTQ of its own, which the materializer copies.
    static func makeDerivedBundle(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("derived.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(reads.utf8).write(to: bundle.appendingPathComponent("full.fastq"))
        let operation = FASTQDerivativeOperation(kind: .subsampleCount)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "derived",
                parentBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootFASTQFilename: "root.fastq",
                payload: .full(fastqFilename: "full.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 2, baseCount: 8),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }
}
