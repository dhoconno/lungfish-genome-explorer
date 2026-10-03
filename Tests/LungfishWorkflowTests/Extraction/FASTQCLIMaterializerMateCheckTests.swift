// FASTQCLIMaterializerMateCheckTests.swift - A paired or mixed bundle interleaves its mates by name, or refuses
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The materializer interleaved the R1 and R2 files of a paired or mixed
// bundle with reformat.sh by position and never checked mate names, so an R2
// file out of step with its R1 gave mis-paired reads (Phase 1.5 lane A7, Lead
// A review R2). It now interleaves with FASTQPairInterleaver and requires
// mates, so such a bundle throws. The output for files in step is the bytes
// reformat.sh wrote.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQCLIMaterializerMateCheckTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("materializer-mate-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func fastq(_ names: [String], sequence: String = "ACGTACGTAC") -> String {
        names.map { "@\($0)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n" }.joined()
    }

    private func makeBundle(
        _ name: String,
        payload: FASTQDerivativePayload,
        files: [String: String]
    ) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for (filename, content) in files {
            try content.write(to: bundle.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: files.keys.sorted()[0],
                payload: payload,
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 1, baseCount: 10),
                pairingMode: .interleaved,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    private func materialize(_ bundle: URL) async throws -> URL {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return try await FASTQCLIMaterializer(runner: .shared).materialize(bundleURL: bundle, tempDirectory: work)
    }

    private func assertMateMismatch(_ bundle: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let output = try await materialize(bundle)
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            XCTFail("an R2 out of step with its R1 must throw, got\n\(text)", file: file, line: line)
        } catch let error as FASTQPairInterleaver.InterleaveError {
            guard case .mateNameMismatch = error else {
                return XCTFail("expected a mate name mismatch, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected a mate name mismatch, got \(error)", file: file, line: line)
        }
    }

    /// Before the fix the deinterleaved bundle materialized p1/1, p2/2, p2/1,
    /// p1/2, two mis-paired pairs.
    func testAPairedBundleWithAnR2OutOfStepThrows() async throws {
        let bundle = try makeBundle(
            "paired",
            payload: .fullPaired(r1Filename: "R1.fastq", r2Filename: "R2.fastq"),
            files: ["R1.fastq": Self.fastq(["p1/1", "p2/1"]), "R2.fastq": Self.fastq(["p2/2", "p1/2"])]
        )
        await assertMateMismatch(bundle)
    }

    /// Before the fix the merge bundle materialized u1 1:N, u2 2:N, u2 1:N,
    /// u1 2:N, then the merged read.
    func testAMixedBundleWithAnR2OutOfStepThrows() async throws {
        let classification = ReadClassification(files: [
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 2),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 2),
            .init(filename: "merged.fastq", role: .merged, readCount: 1),
        ])
        let bundle = try makeBundle(
            "mixed",
            payload: .fullMixed(classification),
            files: [
                "unmerged_R1.fastq": Self.fastq(["u1 1:N:0:1", "u2 1:N:0:1"]),
                "unmerged_R2.fastq": Self.fastq(["u2 2:N:0:1", "u1 2:N:0:1"]),
                "merged.fastq": Self.fastq(["m1"]),
            ]
        )
        await assertMateMismatch(bundle)
    }

    /// For R1 and R2 files in step, the materialized bytes are the bytes
    /// reformat.sh interleaves the same files to, for identical, `/1` `/2`
    /// and Casava names alike.
    func testFilesInStepMaterializeToTheBytesReformatWrites() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.reformat) else {
            try ToolAvailability.skipOrFail("managed reformat.sh is not installed (the reference bytes come from it)")
        }
        let namings: [(String, [String], [String])] = [
            ("identical", ["a", "b"], ["a", "b"]),
            ("slash", ["a/1", "b/1"], ["a/2", "b/2"]),
            ("casava", ["a 1:N:0:1", "b 1:N:0:1"], ["a 2:N:0:1", "b 2:N:0:1"]),
        ]
        for (name, r1Names, r2Names) in namings {
            let bundle = try makeBundle(
                name,
                payload: .fullPaired(r1Filename: "R1.fastq", r2Filename: "R2.fastq"),
                files: [
                    "R1.fastq": Self.fastq(r1Names, sequence: "ACGTTGCAAC"),
                    "R2.fastq": Self.fastq(r2Names, sequence: "GGTTCCAAGT"),
                ]
            )
            let materialized = try await materialize(bundle)

            let reference = root.appendingPathComponent("\(name)-reformat.fastq")
            let environment = CoreToolLocator.bbToolsEnvironment(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            )
            let result = try await NativeToolRunner.shared.run(
                .reformat,
                arguments: [
                    "in1=\(bundle.appendingPathComponent("R1.fastq").path)",
                    "in2=\(bundle.appendingPathComponent("R2.fastq").path)",
                    "out=\(reference.path)",
                    "interleaved=t",
                ],
                environment: environment,
                timeout: 600
            )
            XCTAssertTrue(result.isSuccess, result.stderr)
            XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: reference), name)
        }
    }
}
