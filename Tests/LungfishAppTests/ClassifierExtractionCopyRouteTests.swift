// ClassifierExtractionCopyRouteTests.swift - The copy step of the extraction sheet's clipboard and share rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.11, review fix 1. Since lane 12.11 the clipboard and share rows run
// `lungfish-cli extract reads --by-classifier` into a scratch file, and the only step in the app is
// `ClassifierExtractionCopyRoute.deliver()`, which counts the file's reads, refuses a clipboard copy
// over the cap and hands over the text or the file. These tests pin that live step over a file in a
// test folder, with no tool and no CLI. The cap and refusal-word pins moved here from
// `TaxonomyExtractionDestinationPinTests`, whose resolver no clipboard or share row reaches any more.

import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

final class ClassifierExtractionCopyRouteTests: XCTestCase {
    private var root: URL!

    /// Two FASTQ records, four lines each, ending in a newline.
    private static let twoReadFASTQ = "@b1\nACGT\n+\nIIII\n@b2\nTTGA\n+\nIIII\n"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-copy-route")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A route over `text` written to a file of the test folder, as the command would have left it.
    private func route(_ delivery: ClassifierExtractionCopyRoute.Delivery, text: String) throws -> ClassifierExtractionCopyRoute {
        let scratchDirectory = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let scratchFile = scratchDirectory.appendingPathComponent("kraken2-concat.fastq")
        try Data(text.utf8).write(to: scratchFile)
        return ClassifierExtractionCopyRoute(
            delivery: delivery,
            format: .fastq,
            scratchDirectory: scratchDirectory,
            scratchFile: scratchFile,
            arguments: ["extract", "reads"]
        )
    }

    private func write(_ text: String, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testTheClipboardCapIsInclusiveAndARefusalNamesTheCountAndTheCap() async throws {
        let atTheCap = try route(.clipboard(cap: 2), text: Self.twoReadFASTQ)
        guard case .clipboard(let payload, let byteCount, let readCount) = try await atTheCap.deliver() else {
            return XCTFail("a selection at the cap is copied")
        }
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(payload, Self.twoReadFASTQ)
        XCTAssertEqual(byteCount, Self.twoReadFASTQ.utf8.count)

        let overTheCap = try route(.clipboard(cap: 1), text: Self.twoReadFASTQ)
        do {
            _ = try await overTheCap.deliver()
            XCTFail("a selection over the cap is refused")
        } catch {
            guard case .clipboardCapExceeded(let requested, let cap)? = error as? ClassifierExtractionError else {
                return XCTFail("the cap refusal, not \(error)")
            }
            XCTAssertEqual(requested, 2)
            XCTAssertEqual(cap, 1)
            // The refusal is words a person reads in the sheet (UX inv 47).
            XCTAssertEqual(
                error.localizedDescription,
                "Selection contains 2 reads, which exceeds the clipboard cap of 1. Choose Save to File, Save as Bundle, or Share instead."
            )
        }
    }

    func testTheShareDeliveryReturnsTheFileAndItsReadCount() async throws {
        let share = try route(.share, text: Self.twoReadFASTQ)
        guard case .share(let url, let readCount) = try await share.deliver() else {
            return XCTFail("a share outcome")
        }
        XCTAssertEqual(url, share.scratchFile)
        XCTAssertEqual(readCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: share.scratchFile.path), "deliver leaves the shared file in place")
    }

    func testRecordsAreCountedByLayout() throws {
        let fastqWithNoFinalNewline = try write(
            "@r1\nACGT\n+\nIIII\n@r2\nACGT\n+\nIIII\n@r3\nACGT\n+\nIIII",
            named: "three.fastq"
        )
        XCTAssertEqual(try ClassifierExtractionCopyRoute.countRecords(in: fastqWithNoFinalNewline, format: .fastq), 3)

        let wrappedFASTA = try write(
            ">r1 length>8\nACGT\nACGT\n>r2\nAC\nGT\nAC\n",
            named: "two.fasta"
        )
        XCTAssertEqual(try ClassifierExtractionCopyRoute.countRecords(in: wrappedFASTA, format: .fasta), 2)

        let empty = try write("", named: "empty.fastq")
        XCTAssertEqual(try ClassifierExtractionCopyRoute.countRecords(in: empty, format: .fastq), 0)
    }
}
