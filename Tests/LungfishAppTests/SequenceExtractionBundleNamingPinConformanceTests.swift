// SequenceExtractionBundleNamingPinConformanceTests.swift - Pins the bundle names the extraction builder gives today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishTestSupport

/// Phase 2.10 lane A44 review F2. The extraction builder keeps a private pair that sanitizes and
/// uniquifies a bundle name, beside the pair of `BundleBuildHelpers` that `DownloadBundleNamingPinTests`
/// pins, and the two pairs already differ on an empty name. Lane A48 folds them, so this class
/// records today's names of the extraction pair through the builder's public entry first. Each case
/// builds a real bundle, which runs the managed bgzip and samtools faidx, so the class sits in the
/// conformance tier and skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.
final class SequenceExtractionBundleNamingPinConformanceTests: XCTestCase {
    private var output: URL!

    override func setUpWithError() throws {
        output = try TestTempDirectory.make(prefix: "extraction-naming-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(output)
    }

    /// A slash and a colon become hyphens and a space becomes an underscore. A name already taken
    /// in the folder gets `_1`, then `_2`.
    func testADesiredNameIsSanitizedAndMadeUnique() async throws {
        try await requireTools()
        var names: [String] = []
        for _ in 0..<3 {
            names.append(try await build(desiredName: "Influenza A/H1N1: segment 4", sourceName: "ignored").lastPathComponent)
        }
        XCTAssertEqual(names, [
            "Influenza_A-H1N1-_segment_4.lungfishref",
            "Influenza_A-H1N1-_segment_4_1.lungfishref",
            "Influenza_A-H1N1-_segment_4_2.lungfishref",
        ])
    }

    /// With no desired name the result's source name is the raw name, and it takes the same rules.
    func testTheSourceNameIsUsedWhenNoNameIsDesired() async throws {
        try await requireTools()
        let first = try await build(desiredName: nil, sourceName: "Segment 4: HA/1").lastPathComponent
        let second = try await build(desiredName: "", sourceName: "Segment 4: HA/1").lastPathComponent
        XCTAssertEqual([first, second], ["Segment_4-_HA-1.lungfishref", "Segment_4-_HA-1_1.lungfishref"])
    }

    /// An empty name, here from a blank source name, falls back to a visible name. Since lane A48
    /// folded this builder's pair into `BundleBuildHelpers`, its one uniquer gives the name.
    func testAnEmptyNameFallsBackToExtractedSequence() async throws {
        try await requireTools()
        let first = try await build(desiredName: nil, sourceName: "  ").lastPathComponent
        let second = try await build(desiredName: nil, sourceName: "").lastPathComponent
        XCTAssertEqual([first, second], ["extracted_sequence.lungfishref", "extracted_sequence_1.lungfishref"])
    }

    // MARK: - Helpers

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }

    /// Builds a bundle of one twelve base sequence into the test folder through the public entry.
    private func build(desiredName: String?, sourceName: String) async throws -> URL {
        let result = LungfishCore.ExtractionResult(
            fastaHeader: "naming-pin:1-12", nucleotideSequence: "ACGTACGTACGT", proteinSequence: nil,
            sourceName: sourceName, chromosome: "naming-pin", effectiveStart: 0, effectiveEnd: 12,
            isReverseComplement: false)
        let context = SequenceExtractionBundleCommandContext(
            workflowName: "sequence extraction", toolName: "lungfish-cli extract", argv: ["lungfish-cli", "extract"],
            explicitOptions: [:], defaultOptions: [:], resolvedOptions: [:], inputURLs: [])
        let request = SequenceExtractionBundleBuildRequest(
            result: result, outputDirectory: output, desiredBundleName: desiredName, commandContext: context)
        return try await SequenceExtractionBundleBuilder().buildBundle(request: request)
    }
}
