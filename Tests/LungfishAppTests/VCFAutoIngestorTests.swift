// VCFAutoIngestorTests.swift - Tests for VCF auto-ingestion pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

final class VCFAutoIngestorTests: XCTestCase {

    private nonisolated(unsafe) var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VCFAutoIngestorTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeVCF(_ content: String, filename: String = "test.vcf") -> URL {
        let url = tempDir.appendingPathComponent(filename)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func outputDir() -> URL {
        let dir = tempDir.appendingPathComponent("output")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Single File Ingestion

    func testIngestSingleVCFCreatesBundle() async throws {
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        chr1\t200\trs2\tC\tT\t25.0\tPASS\t.
        """)
        let out = outputDir()

        let result = try await VCFAutoIngestor.ingest(
            vcfURL: vcf,
            outputDirectory: out
        )

        XCTAssertEqual(result.variantCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
        XCTAssertTrue(result.bundleURL.pathExtension == "lungfishref")
    }

    func testIngestEmptyVCFThrows() async {
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """)
        let out = outputDir()

        do {
            _ = try await VCFAutoIngestor.ingest(vcfURL: vcf, outputDirectory: out)
            XCTFail("Expected error for empty VCF")
        } catch {
            // Expected: empty VCF should throw
        }
    }

    func testIngestNoURLsThrows() async {
        let out = outputDir()

        do {
            _ = try await VCFAutoIngestor.ingest(
                vcfURLs: [],
                outputDirectory: out
            )
            XCTFail("Expected error for empty URL list")
        } catch {
            // Expected
        }
    }

    func testIngestWithCancellation() async {
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\t.
        """)
        let out = outputDir()

        do {
            _ = try await VCFAutoIngestor.ingest(
                vcfURL: vcf,
                outputDirectory: out,
                shouldCancel: { true }
            )
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            // Cancellation can happen at different phases
        }

        // Bundle directory should be cleaned up on cancellation
        let bundleName = vcf.deletingPathExtension().lastPathComponent
        let potentialBundle = out.appendingPathComponent("\(bundleName).lungfishref")
        XCTAssertFalse(FileManager.default.fileExists(atPath: potentialBundle.path),
            "Bundle should be cleaned up on cancellation")
    }

    func testIngestExistingBundleThrowsWithoutReplace() async throws {
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        """)
        let out = outputDir()

        _ = try await VCFAutoIngestor.ingest(vcfURL: vcf, outputDirectory: out)

        do {
            _ = try await VCFAutoIngestor.ingest(vcfURL: vcf, outputDirectory: out)
            XCTFail("Expected fileWriteFileExists error")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteFileExists)
        }
    }

    func testIngestWithReplaceExistingBundle() async throws {
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        """)
        let out = outputDir()

        _ = try await VCFAutoIngestor.ingest(vcfURL: vcf, outputDirectory: out)
        let result = try await VCFAutoIngestor.ingest(
            vcfURL: vcf,
            outputDirectory: out,
            replaceExistingBundle: true
        )
        XCTAssertEqual(result.variantCount, 1)
    }

    func testIngestReportsMonotonicProgress() async throws {
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        chr1\t200\trs2\tC\tT\t25.0\tPASS\t.
        chr1\t300\trs3\tG\tA\t40.0\tPASS\t.
        """)
        let out = outputDir()

        let progressValues = LockedArray<Double>()

        _ = try await VCFAutoIngestor.ingest(
            vcfURL: vcf,
            outputDirectory: out,
            progressHandler: { progress, _ in
                progressValues.append(progress)
            }
        )

        let values = progressValues.snapshot
        XCTAssertFalse(values.isEmpty, "Should have received progress callbacks")
        XCTAssertEqual(values.last ?? 0, 1.0, accuracy: 0.001, "Final progress should be 1.0")
        for i in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1],
                "Progress should be monotonically non-decreasing")
        }
    }

    func testIngestMultiVCF() async throws {
        let vcf1 = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        """, filename: "sample1.vcf")

        let vcf2 = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t200\trs2\tC\tT\t25.0\tPASS\t.
        """, filename: "sample2.vcf")

        let out = outputDir()

        let result = try await VCFAutoIngestor.ingest(
            vcfURLs: [vcf1, vcf2],
            outputDirectory: out
        )

        XCTAssertEqual(result.variantCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
    }

    func testIngestBundleCleanupOnFailure() async {
        // Write a corrupt VCF that will fail during parsing
        let vcf = writeVCF("""
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\tNOT_A_NUMBER\trs1\tA\tG\t30.0\tPASS\t.
        """)
        let out = outputDir()

        do {
            _ = try await VCFAutoIngestor.ingest(vcfURL: vcf, outputDirectory: out)
        } catch {
            // Expected: corrupt VCF may throw
        }

        // Check that no partial bundle directory was left behind
        let contents = try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        let bundles = (contents ?? []).filter { $0.pathExtension == "lungfishref" }
        // If a bundle exists, it should either be empty or not exist
        for bundle in bundles {
            // If the import failed, the bundle should either not exist or be cleaned up
            // A manifest.json indicates completion — if there is no manifest, the bundle is partial
            let hasManifest = FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("manifest.json").path
            )
            if !hasManifest {
                XCTFail("Partial bundle without manifest should have been cleaned up: \(bundle.lastPathComponent)")
            }
        }
    }
}

/// Thread-safe array for collecting progress values from @Sendable closures.
private final class LockedArray<T>: @unchecked Sendable {
    private var storage: [T] = []
    private let lock = NSLock()

    func append(_ value: T) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var snapshot: [T] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
