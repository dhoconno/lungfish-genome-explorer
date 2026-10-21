// FastqTranslateLooseLongReadTests.swift - A loose Oxford Nanopore file keeps its ids through `fastq translate`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.42 M2, a guard of BIO ruling section 3d, green at the base and after. `fastq translate` used to
// ask for the platform itself and now reads it through `FASTQInputLayoutResolver`, which for a file outside every
// bundle reads the file's own sidecar, so a loose Oxford Nanopore file whose ids repeat takes no `.1` or `.2`.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport

final class FastqTranslateLooseLongReadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "fastq-translate-loose-long-read")
        let captured = folder!
        addTeardownBlock { TestTempDirectory.cleanup(captured) }
    }

    func testLooseOxfordNanoporeFileWithItsOwnSidecarKeepsItsIds() async throws {
        let id = "8f2e0c7a-0001-4f7a-9d1a-0123456789ab"
        let text = "@\(id) runid=abc\nATGGCTAGCAAAGGAGAA\n+\nIIIIIIIIIIIIIIIIII\n"
            + "@\(id) runid=abc\nATGAAACCCGGGTTT\n+\nIIIIIIIIIIIIIII\n"
        let file = folder.appendingPathComponent("ont.fastq")
        try Data(text.utf8).write(to: file)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: file)

        let written = try await runFastqTranslatePin(file, frame: 1, output: folder.appendingPathComponent("ont.fa"))

        XCTAssertEqual(String(decoding: written, as: UTF8.self), [
            ">\(id)_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(id)_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
    }

    /// A file two levels inside an Oxford Nanopore bundle has no sidecar of its own, and the bundle records the platform.
    /// The base asked the enclosing bundle at any depth, so the ids stay as sequenced, the bytes the bundle's top-level
    /// file gives (13.42 BIO review fix 1).
    func testFileTwoLevelsInsideLongReadBundleKeepsItsIds() async throws {
        let id = "8f2e0c7a-0001-4f7a-9d1a-0123456789ab"
        let text = "@\(id) runid=abc\nATGGCTAGCAAAGGAGAA\n+\nIIIIIIIIIIIIIIIIII\n"
            + "@\(id) runid=abc\nATGAAACCCGGGTTT\n+\nIIIIIIIIIIIIIII\n"
        let bundle = folder.appendingPathComponent("ont.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let topLevel = bundle.appendingPathComponent("reads.fastq")
        let nested = chunks.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: topLevel)
        try Data(text.utf8).write(to: nested)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: topLevel)
        XCTAssertNil(FASTQMetadataStore.load(for: nested))

        let expected = try await runFastqTranslatePin(topLevel, frame: 1, output: folder.appendingPathComponent("top.fa"))
        let written = try await runFastqTranslatePin(nested, frame: 1, output: folder.appendingPathComponent("nested.fa"))

        XCTAssertEqual(String(decoding: expected, as: UTF8.self), [
            ">\(id)_frame+1 [Standard] [6 aa]", "MASKGE",
            ">\(id)_frame+1 [Standard] [5 aa]", "MKPGF",
        ].joined(separator: "\n") + "\n")
        XCTAssertEqual(written, expected)
    }
}
