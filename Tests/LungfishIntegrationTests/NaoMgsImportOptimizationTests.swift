// NaoMgsImportOptimizationTests.swift — Tests for NAO-MGS import optimization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO

struct NaoMgsImportOptimizationTests {

    // MARK: - Line Progress Callback

    @Test
    func parseVirusHitsCallsLineProgressCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Use a lock-protected counter to avoid Sendable mutation errors in Swift 6
        final class Counter: @unchecked Sendable {
            var values: [Int] = []
            func append(_ v: Int) { values.append(v) }
        }
        let counter = Counter()

        let hits = try await parser.parseVirusHits(at: url) { lineCount in
            counter.append(lineCount)
        }

        #expect(hits.count == 35, "Fixture has 35 data rows")
        #expect(!counter.values.isEmpty, "lineProgress should have been called at least once")
        // Final reported count should be >= 35 (header + 35 data lines = 36 total lines)
        #expect(counter.values.last! >= 35)
    }

    @Test
    func parseVirusHitsWorksWithoutCallback() async throws {
        let url = TestFixtures.naomgs.virusHitsTsvGz
        let parser = NaoMgsResultParser()

        // Existing signature still works with no callback
        let hits = try await parser.parseVirusHits(at: url)
        #expect(hits.count == 35)
    }
}
