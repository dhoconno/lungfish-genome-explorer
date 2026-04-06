// FASTQOperationIntegrationTests.swift
// Integration tests: create derivative bundle → verify preview → materialize → verify output.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQOperationIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQInteg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    /// Creates a root `.lungfishfastq` bundle with synthetic FASTQ reads.
    private func makeSyntheticRootBundle(readCount: Int = 100, readLength: Int = 100) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent(
            "root.\(FASTQBundle.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")

        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        for i in 0..<readCount {
            var seq = ""
            for j in 0..<readLength {
                seq.append(bases[(i + j) % 4])
            }
            lines.append(contentsOf: [
                "@read\(i + 1)",
                seq,
                "+",
                String(repeating: "I", count: readLength),
            ])
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: fastqURL, atomically: true, encoding: .utf8)
        return bundleURL
    }

    /// Creates a derived subset `.lungfishfastq` bundle pointing back to `rootBundleURL`.
    private func makeSubsetBundle(rootBundleURL: URL, readIDs: [String]) throws -> URL {
        let derivedURL = tempDir.appendingPathComponent(
            "subset.\(FASTQBundle.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: derivedURL, withIntermediateDirectories: true)

        // Write read-id list
        let readIDURL = derivedURL.appendingPathComponent("read-ids.txt")
        try readIDs.joined(separator: "\n").appending("\n")
            .write(to: readIDURL, atomically: true, encoding: .utf8)

        // Write preview.fastq (up to first 1000 reads)
        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        let bases: [Character] = ["A", "C", "G", "T"]
        var previewLines: [String] = []
        for (idx, id) in readIDs.prefix(1000).enumerated() {
            var seq = ""
            for j in 0..<100 { seq.append(bases[(idx + j) % 4]) }
            previewLines.append(contentsOf: [
                "@\(id)", seq, "+", String(repeating: "I", count: 100),
            ])
        }
        try previewLines.joined(separator: "\n").appending("\n")
            .write(to: previewURL, atomically: true, encoding: .utf8)

        // Write manifest — use "../root.lungfishfastq" so resolveBundle(relativePath:from:)
        // finds the sibling root bundle when called from the derived bundle directory.
        let rootRelPath = "../\(rootBundleURL.lastPathComponent)"
        let manifest = FASTQDerivedBundleManifest(
            name: "subset",
            parentBundleRelativePath: rootRelPath,
            rootBundleRelativePath: rootRelPath,
            rootFASTQFilename: "reads.fastq",
            payload: .subset(readIDListFilename: "read-ids.txt"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .subsampleCount, count: readIDs.count),
            cachedStatistics: .placeholder(readCount: readIDs.count, baseCount: Int64(readIDs.count * 100)),
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedURL)
        return derivedURL
    }

    /// Creates a derived trim `.lungfishfastq` bundle pointing back to `rootBundleURL`.
    /// Trim uses v2 absolute coordinates: trimStart = trimFrom5, trimEnd = readLength - trimFrom3.
    private func makeTrimBundle(
        rootBundleURL: URL,
        trimFrom5: Int,
        trimFrom3: Int,
        readLength: Int = 100,
        readCount: Int
    ) throws -> URL {
        let derivedURL = tempDir.appendingPathComponent(
            "trimmed.\(FASTQBundle.directoryExtension)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: derivedURL, withIntermediateDirectories: true)

        // Write v2 trim-positions.tsv (absolute coordinates, positional read IDs)
        var trimRecords: [FASTQTrimRecord] = []
        for i in 0..<readCount {
            trimRecords.append(FASTQTrimRecord(
                readID: "read\(i + 1)#0",
                trimStart: trimFrom5,
                trimEnd: readLength - trimFrom3
            ))
        }
        let trimURL = derivedURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        try FASTQTrimPositionFile.write(trimRecords, to: trimURL)

        // Write preview.fastq
        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        let bases: [Character] = ["A", "C", "G", "T"]
        var lines: [String] = []
        let trimmedLength = readLength - trimFrom5 - trimFrom3
        for i in 0..<min(readCount, 1000) {
            var seq = ""
            for j in trimFrom5..<(readLength - trimFrom3) { seq.append(bases[(i + j) % 4]) }
            lines.append(contentsOf: [
                "@read\(i + 1)", seq, "+", String(repeating: "I", count: trimmedLength),
            ])
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: previewURL, atomically: true, encoding: .utf8)

        // Write manifest — use "../root.lungfishfastq" so resolveBundle(relativePath:from:)
        // finds the sibling root bundle when called from the derived bundle directory.
        let rootRelPath = "../\(rootBundleURL.lastPathComponent)"
        let manifest = FASTQDerivedBundleManifest(
            name: "trimmed",
            parentBundleRelativePath: rootRelPath,
            rootBundleRelativePath: rootRelPath,
            rootFASTQFilename: "reads.fastq",
            payload: .trim(trimPositionFilename: FASTQBundle.trimPositionFilename),
            lineage: [],
            operation: FASTQDerivativeOperation(
                kind: .fixedTrim,
                trimFrom5Prime: trimFrom5,
                trimFrom3Prime: trimFrom3
            ),
            cachedStatistics: .placeholder(
                readCount: readCount,
                baseCount: Int64(readCount * trimmedLength)
            ),
            pairingMode: nil
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: derivedURL)
        return derivedURL
    }

    private func loadFASTQRecords(from url: URL) async throws -> [FASTQRecord] {
        let reader = FASTQReader(validateSequence: false)
        var records: [FASTQRecord] = []
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }

    // MARK: - Materialization Tests

    func testMaterializeSubsetBundle() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 50)
        let readIDs = (1...10).map { "read\($0)" }
        let derivedURL = try makeSubsetBundle(rootBundleURL: rootURL, readIDs: readIDs)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let materializedURL = try await materializer.materialize(
            bundleURL: derivedURL,
            tempDirectory: outputDir,
            progress: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path),
            "Materialized FASTQ should exist on disk")
        let records = try await loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.count, 10, "Subset should contain exactly 10 reads")

        let outputIDs = Set(records.map { $0.identifier })
        for id in readIDs {
            XCTAssertTrue(outputIDs.contains(id), "Missing read '\(id)' in materialized output")
        }
    }

    func testMaterializeTrimBundle() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 50, readLength: 100)
        let derivedURL = try makeTrimBundle(
            rootBundleURL: rootURL, trimFrom5: 10, trimFrom3: 10, readCount: 50
        )

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let materializedURL = try await materializer.materialize(
            bundleURL: derivedURL,
            tempDirectory: outputDir,
            progress: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path),
            "Materialized FASTQ should exist on disk")
        let records = try await loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.count, 50, "All 50 reads should appear in trim output")

        for record in records {
            XCTAssertEqual(record.sequence.count, 80,
                "Trimmed read should be 80 bp (100 - 10 - 10), got \(record.sequence.count) for \(record.identifier)")
        }
    }

    func testMaterializeRootBundle() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 30)

        let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let materializedURL = try await materializer.materialize(
            bundleURL: rootURL,
            tempDirectory: outputDir,
            progress: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path),
            "Root bundle materialization should return a valid FASTQ path")
        let records = try await loadFASTQRecords(from: materializedURL)
        XCTAssertEqual(records.count, 30, "Root bundle should have all 30 reads")
    }

    func testPreviewFileExistsInSubsetBundle() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 50)
        let readIDs = (1...10).map { "read\($0)" }
        let derivedURL = try makeSubsetBundle(rootBundleURL: rootURL, readIDs: readIDs)

        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
            "Subset bundle should contain preview.fastq")

        let records = try await loadFASTQRecords(from: previewURL)
        XCTAssertGreaterThan(records.count, 0, "preview.fastq should contain at least one read")
    }

    func testPreviewFileExistsInTrimBundle() async throws {
        let rootURL = try makeSyntheticRootBundle(readCount: 50, readLength: 100)
        let derivedURL = try makeTrimBundle(
            rootBundleURL: rootURL, trimFrom5: 5, trimFrom3: 5, readCount: 50
        )

        let previewURL = derivedURL.appendingPathComponent("preview.fastq")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path),
            "Trim bundle should contain preview.fastq")

        let records = try await loadFASTQRecords(from: previewURL)
        XCTAssertGreaterThan(records.count, 0, "preview.fastq should contain at least one read")

        for record in records {
            XCTAssertEqual(record.sequence.count, 90,
                "Preview trim reads should be 90 bp (100 - 5 - 5), got \(record.sequence.count) for \(record.identifier)")
        }
    }
}
