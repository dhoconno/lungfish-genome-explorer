// FASTQCLIMaterializerMixedRolesTests.swift - A mixed bundle materializes every file of every role, or refuses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The fullMixed materializer took only the first file of each role, skipped a
// missing merged or unpaired file without a word, and dropped the R1 reads
// when the manifest named no R2 (D3, Phase 1.5 lane A7). Every listed file of
// every role is now read, and a missing file or an R1 without its R2 throws.
// These cases need no external tool.

import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class FASTQCLIMaterializerMixedRolesTests: XCTestCase {
    private var root: URL!
    private var work: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("materializer-mixed-roles-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// A self-rooted fullMixed bundle whose manifest lists `entries`. Only
    /// the files in `written` exist on disk.
    private func makeMixedBundle(
        entries: [ReadClassification.FileEntry],
        written: [String: [String]]
    ) throws -> URL {
        let bundle = root.appendingPathComponent("mixed.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (filename, names) in written {
            try Self.fastq(names).write(to: bundle.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let classification = ReadClassification(files: entries)
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "mixed",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: entries[0].filename,
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 1, baseCount: 10),
                pairingMode: .interleaved,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    private func materialize(_ bundle: URL) async throws -> URL {
        try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundle, tempDirectory: work)
    }

    private func names(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }

    /// Before the fix only `merged_a.fastq` was read (2 of 4 merged reads).
    func testEveryMergedFileIsRead() async throws {
        let bundle = try makeMixedBundle(
            entries: [
                .init(filename: "merged_a.fastq", role: .merged, readCount: 2),
                .init(filename: "merged_b.fastq", role: .merged, readCount: 2),
            ],
            written: ["merged_a.fastq": ["a1", "a2"], "merged_b.fastq": ["b1", "b2"]]
        )
        let output = try await materialize(bundle)
        XCTAssertEqual(try names(output), ["a1", "a2", "b1", "b2"])
    }

    /// Before the fix the missing unpaired file was skipped and the merged
    /// reads came back alone (2 of 3 listed reads).
    func testAMissingUnpairedFileThrows() async throws {
        let bundle = try makeMixedBundle(
            entries: [
                .init(filename: "merged.fastq", role: .merged, readCount: 2),
                .init(filename: "singletons.fastq", role: .unpaired, readCount: 1),
            ],
            written: ["merged.fastq": ["m1", "m2"]]
        )
        do {
            let output = try await materialize(bundle)
            XCTFail("a missing role file must throw, got \(try names(output))")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("singletons.fastq"), "the error names the missing file: \(error)")
        }
    }

    /// Before the fix the merged file was skipped and the call failed only
    /// because nothing at all was left. With the unpaired file present it
    /// returned the unpaired reads alone.
    func testAMissingMergedFileThrows() async throws {
        let bundle = try makeMixedBundle(
            entries: [
                .init(filename: "merged.fastq", role: .merged, readCount: 2),
                .init(filename: "singletons.fastq", role: .unpaired, readCount: 1),
            ],
            written: ["singletons.fastq": ["s1"]]
        )
        do {
            let output = try await materialize(bundle)
            XCTFail("a missing role file must throw, got \(try names(output))")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("merged.fastq"), "the error names the missing file: \(error)")
        }
    }

    /// Before the fix an R1 listed without an R2 was dropped, and only the
    /// merged reads came back (1 of 2 listed reads).
    func testAnR1WithoutAnR2Throws() async throws {
        let bundle = try makeMixedBundle(
            entries: [
                .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
                .init(filename: "merged.fastq", role: .merged, readCount: 1),
            ],
            written: ["unmerged_R1.fastq": ["u1/1"], "merged.fastq": ["m1"]]
        )
        do {
            let output = try await materialize(bundle)
            XCTFail("an R1 without an R2 must throw, got \(try names(output))")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("R2"), "the error says the R2 is missing: \(error)")
        }
    }

    /// A missing R2 file throws before the pair is interleaved, naming the file.
    func testAMissingR2FileThrowsNamingIt() async throws {
        let bundle = try makeMixedBundle(
            entries: [
                .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
                .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
                .init(filename: "merged.fastq", role: .merged, readCount: 1),
            ],
            written: ["unmerged_R1.fastq": ["u1/1"], "merged.fastq": ["m1"]]
        )
        do {
            let output = try await materialize(bundle)
            XCTFail("a missing R2 must throw, got \(try names(output))")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("unmerged_R2.fastq"), "the error names the missing file: \(error)")
        }
    }
}
