// FASTQExportGzipTests.swift - The gzip step of the FASTQ export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishTestSupport

/// Pins the bytes the FASTQ export's gzip step writes, so the move of its launch onto
/// ``ToolProcess`` (Phase 2.10 lane S38) changes none of them. The tool is the real
/// `/usr/bin/gzip`. The gzip header carries a name and a time, so the pin compares
/// the decompressed bytes and not the file.
final class FASTQExportGzipTests: XCTestCase {
    private func makeChunkedBundle(in directory: URL, chunks: [Data]) throws -> URL {
        let bundleURL = directory.appendingPathComponent("sample.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunksURL = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for (index, chunk) in chunks.enumerated() {
            let name = "chunks/sample_\(index).fastq"
            try chunk.write(to: bundleURL.appendingPathComponent(name))
            entries.append(.init(
                filename: name,
                originalPath: "/run/sample_\(index).fastq",
                sizeBytes: Int64(chunk.count),
                isSymlink: false
            ))
        }
        try FASTQSourceFileManifest(files: entries).save(to: bundleURL)
        return bundleURL
    }

    /// Three plain chunks exported to a `.fastq.gz` go through the gzip step. The file must
    /// pass `gzip -t` and decompress to the bytes of the chunks in order.
    func testExportOfPlainChunksToGzipDecompressesToTheChunkBytes() async throws {
        let temp = try TestTempDirectory.make(prefix: "fastq-export-gzip")
        defer { TestTempDirectory.cleanup(temp) }

        let chunks = (0..<3).map { chunk in
            Data((0..<3_000).map { read in
                "@chunk\(chunk)_read\(read)\n\(String(repeating: "ACGTTGCA", count: 12))\n+\n\(String(repeating: "I", count: 96))\n"
            }.joined().utf8)
        }
        let bundleURL = try makeChunkedBundle(in: temp, chunks: chunks)
        let outputURL = temp.appendingPathComponent("export.fastq.gz")

        try await AppDelegate.exportFASTQBundleForSidebar(bundleURL: bundleURL, outputURL: outputURL, isDerived: false)

        let test = try await SystemToolProbe.run("gzip", ["-t", outputURL.path])
        XCTAssertTrue(test.isSuccess, "gzip -t: \(test.stderrText)")
        let decompressed = try await SystemToolProbe.run("gzip", ["-dc", outputURL.path], stdout: .capture())
        XCTAssertTrue(decompressed.isSuccess, decompressed.stderrText)
        let expected = chunks.reduce(into: Data()) { $0.append($1) }
        XCTAssertGreaterThan(expected.count, 1_000_000)
        XCTAssertTrue(decompressed.stdout == expected, "The export decompresses to \(decompressed.stdout.count) bytes, not the \(expected.count) of the chunks")
    }
}
