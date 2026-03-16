// PrimerTrimFixtureIntegrationTests.swift - Real-read primer trimming fixture coverage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

final class PrimerTrimFixtureIntegrationTests: XCTestCase {
    private let runner = NativeToolRunner.shared

    private let primers: [String: String] = [
        "MHC-E_F": "CCAATGGGTGTCGGGTTTCT",
        "MHC-E_R": "CAGGTCAGTGTGAGGAAGGG",
        "MHCI_5UTRa": "ATTCTCCGCAGACGCCVAG",
        "MHCI_5UTR": "AGAGTCTCCTCAGACGCCGAG",
        "MHCI_3UTRa": "CCTCGCAGTCCCACACAAG",
        "MHCI_3UTRb": "CCTGCTTCTCAGTTCCACACAAG",
        "MHCI_3UTRc": "CTGCATCTCAGTCCCACACAAG",
    ]

    private func fixtureURL(_ name: String, ext: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "PrimerTrimFixtures"
        ) else {
            throw XCTSkip("Missing test fixture \(name).\(ext)")
        }
        return url
    }

    private func readFASTQIDs(from url: URL) throws -> [String] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var ids: [String] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index + 3 < lines.count {
            let header = String(lines[index])
            guard header.hasPrefix("@") else {
                throw XCTSkip("Unexpected FASTQ header format in \(url.lastPathComponent)")
            }
            ids.append(String(header.dropFirst()).split(separator: " ", maxSplits: 1).first.map(String.init) ?? "")
            index += 4
        }
        return ids
    }

    private func expectedIDs(for primerName: String, in fixtureURL: URL) throws -> (forward: String, both: [String]) {
        let ids = try readFASTQIDs(from: fixtureURL)
            .filter { $0.hasPrefix("\(primerName)|") }
            .sorted()
        guard ids.count == 2 else {
            throw XCTSkip("Expected exactly two fixture reads for \(primerName), found \(ids.count)")
        }
        guard let forward = ids.first(where: { $0.contains("|forward|") }) else {
            throw XCTSkip("Missing forward-orientation fixture read for \(primerName)")
        }
        return (forward, ids)
    }

    private func matchedIDs(
        primer: String,
        fixtureURL: URL,
        reverseComplementAware: Bool,
        tempDir: URL
    ) async throws -> [String] {
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("fastq")
        var args = [
            "-g", "^\(primer)",
            "--discard-untrimmed",
            "-e", "0.12",
            "--overlap", "12",
            "-o", outputURL.path,
            fixtureURL.path,
        ]
        if reverseComplementAware {
            args.insert("--revcomp", at: 2)
        }
        let result = try await runner.run(.cutadapt, arguments: args, timeout: 120)
        XCTAssertTrue(result.isSuccess, "cutadapt failed: \(result.stderr)")
        return try readFASTQIDs(from: outputURL).sorted()
    }

    func testPrimerFixtureDetectsNativeAndReverseComplementOrientations() async throws {
        let fixtureURL = try fixtureURL("mhc_primer_orientation_subset", ext: "fastq")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerTrimFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (name, primer) in primers.sorted(by: { $0.key < $1.key }) {
            let expected = try expectedIDs(for: name, in: fixtureURL)

            let nativeIDs = try await matchedIDs(
                primer: primer,
                fixtureURL: fixtureURL,
                reverseComplementAware: false,
                tempDir: tempDir
            )
            XCTAssertEqual(nativeIDs, [expected.forward], "Native orientation should match only the forward fixture read for \(name)")

            let revcompIDs = try await matchedIDs(
                primer: primer,
                fixtureURL: fixtureURL,
                reverseComplementAware: true,
                tempDir: tempDir
            )
            XCTAssertEqual(revcompIDs, expected.both, "Reverse-complement-aware mode should match both fixture orientations for \(name)")
        }
    }
}
