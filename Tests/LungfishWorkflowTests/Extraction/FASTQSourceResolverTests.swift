// FASTQSourceResolverTests.swift - Tests for centralized FASTQ source resolution
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
import Foundation
import os
@testable import LungfishWorkflow

@Suite("FASTQSourceResolver")
struct FASTQSourceResolverTests {

    @Test("Resolves physical FASTQ file directly")
    func physicalFASTQ() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        let resolver = FASTQSourceResolver()
        let resolved = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
        #expect(resolved.count == 1)
        #expect(resolved[0].lastPathComponent == "reads.fastq")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Throws for nonexistent bundle")
    func nonexistentBundle() async throws {
        let resolver = FASTQSourceResolver()
        do {
            _ = try await resolver.resolve(
                bundleURL: URL(fileURLWithPath: "/nonexistent.lungfishfastq"),
                tempDirectory: FileManager.default.temporaryDirectory,
                progress: { _, _ in }
            )
            Issue.record("Should have thrown")
        } catch {
            // Expected
        }
    }

    @Test("UUID temp file names never contain materialized")
    func tempFileNaming() {
        let name = FASTQSourceResolver.tempFileName(extension: "fastq")
        #expect(!name.contains("materialized"))
        #expect(name.hasSuffix(".fastq"))
        #expect(name.count > 10)
    }

    @Test("Skips preview.fastq when other FASTQ files exist")
    func skipsPreviewFASTQ() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)
        let readsURL = bundleURL.appendingPathComponent("reads.fastq.gz")
        try Data([0x1f, 0x8b]).write(to: readsURL)

        let resolver = FASTQSourceResolver()
        let resolved = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
        #expect(resolved.count == 1)
        #expect(resolved[0].lastPathComponent == "reads.fastq.gz")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Falls back to preview.fastq when it is the only FASTQ")
    func fallsBackToPreview() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("test.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)

        let resolver = FASTQSourceResolver()
        let resolved = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
        #expect(resolved.count == 1)
        #expect(resolved[0].lastPathComponent == "preview.fastq")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Resolves multi-file bundle via source-files.json")
    func multiFileBundle() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("multi.lungfishfastq")
        let chunksDir = bundleURL.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        // Create chunk files
        let chunk1 = chunksDir.appendingPathComponent("chunk_0.fastq.gz")
        let chunk2 = chunksDir.appendingPathComponent("chunk_1.fastq.gz")
        try Data([0x1f, 0x8b]).write(to: chunk1)
        try Data([0x1f, 0x8b]).write(to: chunk2)

        // Write source-files.json manifest
        let manifest = """
        {
            "version": 1,
            "files": [
                {"filename": "chunks/chunk_0.fastq.gz", "originalPath": "/orig/chunk_0.fastq.gz", "sizeBytes": 100, "isSymlink": false},
                {"filename": "chunks/chunk_1.fastq.gz", "originalPath": "/orig/chunk_1.fastq.gz", "sizeBytes": 200, "isSymlink": false}
            ]
        }
        """
        try manifest.write(to: bundleURL.appendingPathComponent("source-files.json"), atomically: true, encoding: .utf8)

        let resolver = FASTQSourceResolver()
        let resolved = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
        #expect(resolved.count == 2)
        #expect(resolved[0].lastPathComponent == "chunk_0.fastq.gz")
        #expect(resolved[1].lastPathComponent == "chunk_1.fastq.gz")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Resolves paired-end FASTQ files")
    func pairedEndFASTQ() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("paired.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let r1 = bundleURL.appendingPathComponent("reads_R1.fastq.gz")
        let r2 = bundleURL.appendingPathComponent("reads_R2.fastq.gz")
        try Data([0x1f, 0x8b]).write(to: r1)
        try Data([0x1f, 0x8b]).write(to: r2)

        let resolver = FASTQSourceResolver()
        let resolved = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
        #expect(resolved.count == 2)

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Derived bundle without materializer throws")
    func derivedBundleNoMaterializer() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("derived.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Write a derived manifest to mark it as virtual
        let manifestData = """
        {
            "rootBundleRelativePath": "../root.lungfishfastq",
            "operations": []
        }
        """
        try manifestData.write(
            to: bundleURL.appendingPathComponent("derived.manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        // Only preview.fastq exists
        try "@SEQ1\nACGT\n+\nIIII\n".write(
            to: bundleURL.appendingPathComponent("preview.fastq"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = FASTQSourceResolver()
        do {
            _ = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
            Issue.record("Should have thrown for derived bundle without materializer")
        } catch is ExtractionError {
            // Expected — noSourceFASTQ
        }

        try FileManager.default.removeItem(at: tmp)
    }

    @Test("Derived bundle with materializer invokes callback")
    func derivedBundleWithMaterializer() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        let bundleURL = tmp.appendingPathComponent("derived.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Write a derived manifest
        let manifestData = """
        {
            "rootBundleRelativePath": "../root.lungfishfastq",
            "operations": []
        }
        """
        try manifestData.write(
            to: bundleURL.appendingPathComponent("derived.manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "@SEQ1\nACGT\n+\nIIII\n".write(
            to: bundleURL.appendingPathComponent("preview.fastq"),
            atomically: true,
            encoding: .utf8
        )

        // Create a fake materialized file that the materializer will "produce"
        let materializedURL = tmp.appendingPathComponent("\(UUID().uuidString.prefix(12)).fastq")
        try "@SEQ1\nACGT\n+\nIIII\n@SEQ2\nTTTT\n+\nIIII\n".write(
            to: materializedURL,
            atomically: true,
            encoding: .utf8
        )

        let materializerCalled = OSAllocatedUnfairLock(initialState: false)
        let resolver = FASTQSourceResolver()
        resolver.materializer = { _, _, _ in
            materializerCalled.withLock { $0 = true }
            return materializedURL
        }

        let resolved = try await resolver.resolve(bundleURL: bundleURL, tempDirectory: tmp, progress: { _, _ in })
        #expect(materializerCalled.withLock { $0 })
        #expect(resolved.count == 1)
        #expect(resolved[0] == materializedURL)

        try FileManager.default.removeItem(at: tmp)
    }
}
