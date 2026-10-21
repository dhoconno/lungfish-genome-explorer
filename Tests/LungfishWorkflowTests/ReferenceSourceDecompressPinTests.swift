// ReferenceSourceDecompressPinTests.swift - Pin what the reference import's decompress step does before zstd and xz move
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.17 M1. `ReferenceSourcePreparer` decompresses a wrapped reference with the system gzip and bzip2
// and, until M3, with `/usr/bin/xz` and `/usr/bin/env zstd`. This pins the part that stays when the last two move onto
// managed tools. A gzip and a bzip2 wrapper give the FASTA they hold, and an unknown wrapper is refused with the words
// a person reads. Neither gzip nor bzip2 is managed, so these tests run on every Mac.

import XCTest
@testable import LungfishWorkflow

final class ReferenceSourceDecompressPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceSourceDecompressPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let fasta = ">chr1\nACGTACGTAC\n>chr2\nTTGGCCAATT\n"

    /// Compresses `fasta` with a system tool (`-k` keeps the source) and returns the wrapped file.
    private func wrapped(by tool: String, suffix: String) throws -> URL {
        let plain = root.appendingPathComponent("reference.fa")
        try fasta.write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-kf", plain.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) wraps the fixture")
        let result = root.appendingPathComponent("reference.fa" + suffix)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), "\(tool) wrote \(result.lastPathComponent)")
        try FileManager.default.removeItem(at: plain)
        return result
    }

    private func sequenceNames(of source: URL) async throws -> [String] {
        try await ReferenceSourcePreparer().prepare(
            sourceURL: source,
            bundleName: "Pin",
            tempDirectory: root.appendingPathComponent("working-\(UUID().uuidString)", isDirectory: true)
        ).sequenceNames
    }

    func testAGzipWrapperGivesTheFastaItHolds() async throws {
        let source = try wrapped(by: "/usr/bin/gzip", suffix: ".gz")
        let names = try await sequenceNames(of: source)
        XCTAssertEqual(names, ["chr1", "chr2"])
    }

    func testABzip2WrapperGivesTheFastaItHolds() async throws {
        let source = try wrapped(by: "/usr/bin/bzip2", suffix: ".bz2")
        let names = try await sequenceNames(of: source)
        XCTAssertEqual(names, ["chr1", "chr2"])
    }

    func testACorruptGzipWrapperIsRefusedAsAFailedDecompression() async throws {
        let source = root.appendingPathComponent("broken.fa.gz")
        try Data("this is not gzip data".utf8).write(to: source)
        do {
            _ = try await sequenceNames(of: source)
            XCTFail("a corrupt wrapper must not give a reference")
        } catch let error as ReferenceBundleImportError {
            guard case .decompressionFailed(let detail) = error else {
                return XCTFail("expected a failed decompression, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty, "the failure says why")
        }
    }
}
