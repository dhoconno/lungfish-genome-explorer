// RecursivePairDetectionTests.swift - Tests for recursive directory pair detection
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class RecursivePairDetectionTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecursivePairDetectionTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmpDir = tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        super.tearDown()
    }

    // MARK: - SamplePair relativePath

    func testSamplePairRelativePathDefault() {
        let pair = SamplePair(sampleName: "Sample", r1: URL(fileURLWithPath: "/tmp/Sample_R1.fq.gz"), r2: nil)
        XCTAssertNil(pair.relativePath, "Default relativePath should be nil")
    }

    func testSamplePairRelativePathSet() {
        let pair = SamplePair(
            sampleName: "Sample",
            r1: URL(fileURLWithPath: "/tmp/plate1/Sample_R1.fq.gz"),
            r2: nil,
            relativePath: "plate1"
        )
        XCTAssertEqual(pair.relativePath, "plate1")
    }

    // MARK: - Recursive Directory Scanning

    func testDetectPairsFromDirectoryRecursive() throws {
        // Create nested plate1/plate2 structure
        let plate1 = tmpDir.appendingPathComponent("plate1")
        let plate2 = tmpDir.appendingPathComponent("plate2")
        try FileManager.default.createDirectory(at: plate1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plate2, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: plate1.appendingPathComponent("SampleA_R1_001.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: plate1.appendingPathComponent("SampleA_R2_001.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: plate2.appendingPathComponent("SampleB_R1_001.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: plate2.appendingPathComponent("SampleB_R2_001.fq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 2)

        let sampleA = pairs.first { $0.sampleName == "SampleA" }
        let sampleB = pairs.first { $0.sampleName == "SampleB" }
        XCTAssertNotNil(sampleA)
        XCTAssertNotNil(sampleB)
        XCTAssertEqual(sampleA?.relativePath, "plate1")
        XCTAssertEqual(sampleB?.relativePath, "plate2")
        XCTAssertNotNil(sampleA?.r2)
        XCTAssertNotNil(sampleB?.r2)
    }

    func testDetectPairsFromDirectoryRecursiveDeeplyNested() throws {
        // run1/plate1/lane1 deep nesting
        let deepDir = tmpDir.appendingPathComponent("run1/plate1/lane1")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)

        FileManager.default.createFile(atPath: deepDir.appendingPathComponent("Deep_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: deepDir.appendingPathComponent("Deep_R2.fq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].sampleName, "Deep")
        XCTAssertEqual(pairs[0].relativePath, "run1/plate1/lane1")
        XCTAssertNotNil(pairs[0].r2)
    }

    func testDetectPairsFromDirectoryRecursiveMixedLevels() throws {
        // Files at root AND in subdirectory
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("Root_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("Root_R2.fq.gz").path, contents: nil)

        let sub = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("Sub_R1.fq.gz").path, contents: nil)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("Sub_R2.fq.gz").path, contents: nil)

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.count, 2)

        let rootPair = pairs.first { $0.sampleName == "Root" }
        let subPair = pairs.first { $0.sampleName == "Sub" }
        XCTAssertNotNil(rootPair)
        XCTAssertNotNil(subPair)
        XCTAssertNil(rootPair?.relativePath, "Root-level files should have nil relativePath")
        XCTAssertEqual(subPair?.relativePath, "subdir")
    }

    // MARK: - Mates of two folders (F7, the --recursive ruling)

    /// A recursive scan detected each folder alone, so mates kept in `R1/`
    /// and `R2/` imported as two single-end samples, while the Import
    /// Center's scan and explicit files paired them. It now detects every
    /// file it finds by the rule they use. A pair of two folders takes the
    /// folder that holds both mates' folders.
    func testARecursiveScanPairsMatesOfTwoFoldersByNamesNoOtherFileHas() throws {
        let x1 = try touch("R1/x_R1.fastq.gz"), x2 = try touch("R2/x_R2.fastq.gz")
        let y1 = try touch("run1/R1/y_R1.fastq.gz"), y2 = try touch("run1/R2/y_R2.fastq.gz")

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.map(\.sampleName), ["x", "y"])
        XCTAssertEqual(pairs.map { Self.paths($0.inputFiles) }, [Self.paths([x1, x2]), Self.paths([y1, y2])])
        XCTAssertEqual(pairs.map(\.relativePath), [nil, "run1"])
    }

    func testARecursiveScanNeverPairsANameTwoFoldersShareAcrossFolders() throws {
        // Folder A holds a whole pair. B's R1 and C's R2 are named as mates,
        // but each name is also one of A's mates.
        let a = [try touch("A/reads_R1.fastq"), try touch("A/reads_R2.fastq")]
        let b1 = try touch("B/reads_R1.fastq"), c2 = try touch("C/reads_R2.fastq")

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.map(\.sampleName), ["reads", "reads_R1", "reads_R2"])
        XCTAssertEqual(pairs.map { Self.paths($0.inputFiles) }, [Self.paths(a), Self.paths([b1]), Self.paths([c2])])
        XCTAssertEqual(pairs.map(\.relativePath), ["A", "B", "C"])
    }

    func testARecursiveScanJoinsARunsThirdFileOfAnotherFolderByNamesNoOtherFileHas() throws {
        let r1 = try touch("A/SRR1_1.fastq"), r2 = try touch("A/SRR1_2.fastq"), third = try touch("B/SRR1.fastq")

        let pairs = try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)

        XCTAssertEqual(pairs.map { Self.paths($0.inputFiles) }, [Self.paths([r1, r2, third])])
        XCTAssertEqual(pairs.map(\.relativePath), ["A"], "the pair's folder places the bundle")
    }

    // MARK: - Bundle Output Path

    func testBundleOutputPathWithRelativePath() {
        let pair = SamplePair(
            sampleName: "Sample1",
            r1: URL(fileURLWithPath: "/data/plate1/Sample1_R1.fq.gz"),
            r2: nil,
            relativePath: "plate1"
        )

        let projectDir = URL(fileURLWithPath: "/projects/Test.lungfish")
        let expected = projectDir
            .appendingPathComponent("Imports")
            .appendingPathComponent("plate1")
            .appendingPathComponent("Sample1.lungfishfastq")

        let actual = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDir)
        XCTAssertEqual(actual, expected)
    }

    func testBundleOutputPathWithoutRelativePath() {
        let pair = SamplePair(
            sampleName: "Sample1",
            r1: URL(fileURLWithPath: "/data/Sample1_R1.fq.gz"),
            r2: nil
        )

        let projectDir = URL(fileURLWithPath: "/projects/Test.lungfish")
        let expected = projectDir
            .appendingPathComponent("Imports")
            .appendingPathComponent("Sample1.lungfishfastq")

        let actual = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDir)
        XCTAssertEqual(actual, expected)
    }

    // MARK: - Empty Subdirs

    func testDetectPairsFromDirectoryRecursiveEmptySubdirs() throws {
        // Empty subdirs should not cause errors, but if no FASTQ files anywhere, should throw
        let emptyA = tmpDir.appendingPathComponent("emptyA")
        let emptyB = tmpDir.appendingPathComponent("emptyB")
        try FileManager.default.createDirectory(at: emptyA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyB, withIntermediateDirectories: true)

        XCTAssertThrowsError(try FASTQBatchImporter.detectPairsFromDirectoryRecursive(tmpDir)) { error in
            guard case BatchImportError.noFASTQFilesFound = error else {
                XCTFail("Expected noFASTQFilesFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    /// An empty file at `path` under the scanned folder. Detection reads names alone.
    private func touch(_ path: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// Paths as a scan and a list spell them alike.
    private static func paths(_ urls: [URL]) -> [String] {
        urls.map(\.standardizedFileURL.path)
    }
}
