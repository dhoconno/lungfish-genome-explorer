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
}
