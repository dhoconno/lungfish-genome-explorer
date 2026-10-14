// TypedAPIKeyLeakAssertions.swift - What a run handed an NCBI key on its command line may leave on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, ruling A45-M3 section 2 (finding 6, SWIFT 6 and G5). The GenBank bundle builder
// records the host's argument vector for the run and for each conversion step. A key typed with
// `--api-key` is in that vector, so the record held it. Both bundle routes of the CLI (`fetch ncbi
// --bundle` and the INSDC way of `fetch pathoplexus`) share the builder and share these assertions.

import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

enum TypedAPIKeyLeak {
    /// A key that is shaped like none of NCBI's, so a hit is the test's own key.
    static let key = "LGE0FAKE0KEY0123456789"

    /// The path, below `folder`, of every regular file whose bytes hold `key`, sorted.
    static func filesHolding(_ key: String, under folder: URL) -> [String] {
        let needle = Data(key.utf8)
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        var hits: [String] = []
        while let relative = walker.nextObject() as? String {
            let url = folder.appendingPathComponent(relative)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if data.range(of: needle) != nil { hits.append(relative) }
        }
        return hits.sorted()
    }

    /// Asserts that no file of `bundle` holds the typed key, and that the run's argument vector and each
    /// step's name the flag with `<redacted>` after it, as `fetch genome`'s record and the Conda
    /// records do.
    static func assertHeldNowhere(
        in bundle: URL, envelope: ProvenanceEnvelope, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            filesHolding(key, under: bundle), [], "a file of the bundle holds the typed key", file: file, line: line)
        func assertShowsRedaction(_ argv: [String], _ label: String) {
            guard let flag = argv.firstIndex(of: "--api-key") else { return }
            XCTAssertEqual(
                argv.dropFirst(flag + 1).first, "<redacted>", "\(label) shows the key after --api-key",
                file: file, line: line)
        }
        XCTAssertTrue(
            envelope.argv.contains("--api-key"), "the run's argv keeps the flag the key followed: \(envelope.argv)",
            file: file, line: line)
        assertShowsRedaction(envelope.argv, "the run's argv")
        assertShowsRedaction(envelope.durableReplayArgv ?? [], "the run's replay argv")
        XCTAssertFalse(
            envelope.reproducibleCommand.contains(key), "the run's command holds the typed key", file: file, line: line)
        for step in envelope.steps {
            assertShowsRedaction(step.argv, "the argv of step \(step.toolName)")
            XCTAssertFalse(
                step.reproducibleCommand.contains(key), "the command of step \(step.toolName) holds the typed key",
                file: file, line: line)
        }
        XCTAssertTrue(
            envelope.steps.contains { $0.argv.contains("--api-key") },
            "a conversion step records the host argv, which names the flag", file: file, line: line)
    }
}
