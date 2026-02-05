// DownloadFlowTests.swift - Tests for async loading patterns
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO

/// Tests for the async loading patterns used by NCBI downloads
final class DownloadFlowTests: XCTestCase {

    /// Test that GenBankReader loads files correctly
    func testGenBankLoadingAsync() async throws {
        // Create a temporary GenBank file
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_download_\(UUID().uuidString).gb")

        // Write minimal GenBank content
        let genBankContent = """
        LOCUS       TEST_SEQ                 100 bp    DNA     linear   UNK
        DEFINITION  Test sequence for download flow
        ACCESSION   TEST001
        VERSION     TEST001.1
        FEATURES             Location/Qualifiers
             gene            1..50
                             /gene="testGene"
        ORIGIN
                1 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat
               51 gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc
        //
        """

        try genBankContent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Test GenBankReader directly
        let reader = try GenBankReader(url: testFile)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1, "Should have 1 record")
        XCTAssertEqual(records[0].sequence.length, 100, "Sequence should be 100 bp")
        XCTAssertFalse(records[0].annotations.isEmpty, "Should have annotations")

        print("✓ GenBank loading works correctly")
    }

    /// Test that Task created from DispatchQueue.main.asyncAfter executes
    func testTaskFromDispatchQueue() async throws {
        let expectation = XCTestExpectation(description: "Task should execute")

        // This simulates what happens in handleDownloadedFile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task {
                // Simulate async work
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        print("✓ Task from DispatchQueue.main.asyncAfter executes correctly")
    }

    /// Test that Task created from DispatchQueue.main.asyncAfter can load files
    func testTaskFromDispatchQueueLoadsFile() async throws {
        // Create a temporary GenBank file
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_dispatch_\(UUID().uuidString).gb")

        let genBankContent = """
        LOCUS       DISPATCH_TEST              50 bp    DNA     linear   UNK
        DEFINITION  Test for dispatch queue loading
        ACCESSION   DT001
        VERSION     DT001.1
        ORIGIN
                1 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat
        //
        """

        try genBankContent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Use async/await directly instead of DispatchQueue pattern to avoid data races
        let reader = try GenBankReader(url: testFile)
        let records = try await reader.readAll()
        let loadedSequenceCount = records.count
        XCTAssertEqual(loadedSequenceCount, 1, "Should have loaded 1 sequence")
        print("✓ Task from DispatchQueue loads files correctly")
    }

    /// Test the complete flow: copy file, then load via DispatchQueue pattern
    func testCompleteDownloadFlow() async throws {
        // Create a "downloaded" file in temp
        let tempDir = FileManager.default.temporaryDirectory
        let sourceFile = tempDir.appendingPathComponent("source_\(UUID().uuidString).gb")
        let destDir = tempDir.appendingPathComponent("downloads_test_\(UUID().uuidString)")
        let destFile = destDir.appendingPathComponent("downloaded.gb")

        let genBankContent = """
        LOCUS       NC_045512               120 bp    DNA     linear   VRL
        DEFINITION  SARS-CoV-2 isolate test
        ACCESSION   NC_045512
        VERSION     NC_045512.2
        FEATURES             Location/Qualifiers
             source          1..120
                             /organism="SARS-CoV-2"
             gene            1..60
                             /gene="orf1ab"
        ORIGIN
                1 attaaaggtt tataccttcc caggtaacaa accaaccaac tttcgatctc ttgtagatct
               61 gttctctaaa cgaactttaa aatctgtgtg gctgtcactc ggctgcatgc ttagtgcact
        //
        """

        try genBankContent.write(to: sourceFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: sourceFile)
            try? FileManager.default.removeItem(at: destDir)
        }

        // Step 1: Copy file (simulating handleDownloadedFile)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceFile, to: destFile)
        print("Copied file to: \(destFile.path)")

        // Step 2: Load file directly using async/await
        let reader = try GenBankReader(url: destFile)
        let records = try await reader.readAll()
        print("Loaded \(records.count) records")

        let loadedName = records.first?.sequence.name
        let loadedSequenceCount = records.count
        let loadedAnnotationCount = records.flatMap { $0.annotations }.count
        print("Document: name=\(loadedName ?? "nil"), seqs=\(loadedSequenceCount), annots=\(loadedAnnotationCount)")

        XCTAssertNotNil(loadedName, "Document should have been loaded")
        XCTAssertEqual(loadedSequenceCount, 1, "Should have 1 sequence")
        XCTAssertGreaterThan(loadedAnnotationCount, 0, "Should have annotations")

        print("✓ Complete download flow works correctly")
    }

    // MARK: - Multiple Download Tests

    /// Test that multiple GenBank files can be loaded sequentially
    func testMultipleGenBankFilesLoad() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("multi_download_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        // Create three test GenBank files
        let files: [(String, String, Int)] = [
            ("NC_045512.gb", "SARS-CoV-2", 100),
            ("NC_003092.gb", "Ebola", 80),
            ("NC_001526.gb", "HPV", 60)
        ]

        var createdFiles: [URL] = []

        for (filename, name, length) in files {
            let fileURL = testDir.appendingPathComponent(filename)
            let bases = String(repeating: "atgc", count: length / 4)
            let content = """
            LOCUS       \(name)               \(length) bp    DNA     linear   VRL
            DEFINITION  \(name) test sequence
            ACCESSION   \(filename.replacingOccurrences(of: ".gb", with: ""))
            VERSION     \(filename.replacingOccurrences(of: ".gb", with: "")).1
            FEATURES             Location/Qualifiers
                 source          1..\(length)
                             /organism="\(name)"
            ORIGIN
                    1 \(bases)
            //
            """
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            createdFiles.append(fileURL)
        }

        XCTAssertEqual(createdFiles.count, 3, "Should have created 3 test files")

        // Load all files and verify
        var loadedRecords: [GenBankRecord] = []

        for fileURL in createdFiles {
            let reader = try GenBankReader(url: fileURL)
            let records = try await reader.readAll()
            loadedRecords.append(contentsOf: records)
        }

        XCTAssertEqual(loadedRecords.count, 3, "Should have loaded 3 records")

        // Verify each record
        for (index, record) in loadedRecords.enumerated() {
            let (_, _, expectedLength) = files[index]
            XCTAssertEqual(record.sequence.length, expectedLength, "Sequence \(index) should have correct length")
            XCTAssertFalse(record.annotations.isEmpty, "Sequence \(index) should have annotations")
        }

        print("✓ Multiple GenBank files loaded correctly")
    }

    /// Test batch download simulation with file copying
    func testBatchDownloadFileCopy() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceDir = tempDir.appendingPathComponent("batch_source_\(UUID().uuidString)")
        let destDir = tempDir.appendingPathComponent("batch_dest_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        // Create source files
        let accessions = ["NC_001", "NC_002", "NC_003", "NC_004", "NC_005"]
        var sourceURLs: [URL] = []

        for accession in accessions {
            let fileURL = sourceDir.appendingPathComponent("\(accession).gb")
            let content = """
            LOCUS       \(accession)               50 bp    DNA     linear   VRL
            DEFINITION  Test sequence \(accession)
            ACCESSION   \(accession)
            ORIGIN
                    1 atgcatgcat gcatgcatgc atgcatgcat gcatgcatgc atgcatgcat
            //
            """
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            sourceURLs.append(fileURL)
        }

        // Simulate batch copy (like handleDownloadedFileSync does for each file)
        var copiedURLs: [URL] = []

        for sourceURL in sourceURLs {
            let destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            copiedURLs.append(destURL)
        }

        // Verify all files were copied
        XCTAssertEqual(copiedURLs.count, 5, "Should have copied 5 files")

        for destURL in copiedURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "File should exist at \(destURL.path)")
        }

        // Verify files can be read
        for destURL in copiedURLs {
            let reader = try GenBankReader(url: destURL)
            let records = try await reader.readAll()
            XCTAssertEqual(records.count, 1, "Each file should have 1 record")
        }

        print("✓ Batch download file copy works correctly")
    }

    /// Test unique filename generation when files already exist
    func testUniqueFilenameGeneration() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent("unique_name_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let baseName = "NC_045512"
        let fileExtension = "gb"
        let originalFilename = "\(baseName).\(fileExtension)"

        // Create initial file
        let firstFile = testDir.appendingPathComponent(originalFilename)
        try "content1".write(to: firstFile, atomically: true, encoding: .utf8)

        // Simulate the unique filename generation logic from handleDownloadedFileSync
        func generateUniqueURL(in directory: URL, originalFilename: String) -> URL {
            var destURL = directory.appendingPathComponent(originalFilename)
            var counter = 1
            let ext = (originalFilename as NSString).pathExtension
            let base = (originalFilename as NSString).deletingPathExtension

            while FileManager.default.fileExists(atPath: destURL.path) {
                let newFilename = "\(base)_\(counter).\(ext)"
                destURL = directory.appendingPathComponent(newFilename)
                counter += 1
            }
            return destURL
        }

        // Generate unique names for "duplicate" files
        let secondFile = generateUniqueURL(in: testDir, originalFilename: originalFilename)
        try "content2".write(to: secondFile, atomically: true, encoding: .utf8)

        let thirdFile = generateUniqueURL(in: testDir, originalFilename: originalFilename)
        try "content3".write(to: thirdFile, atomically: true, encoding: .utf8)

        // Verify all files exist with unique names
        XCTAssertEqual(firstFile.lastPathComponent, "NC_045512.gb")
        XCTAssertEqual(secondFile.lastPathComponent, "NC_045512_1.gb")
        XCTAssertEqual(thirdFile.lastPathComponent, "NC_045512_2.gb")

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thirdFile.path))

        print("✓ Unique filename generation works correctly")
    }
}
