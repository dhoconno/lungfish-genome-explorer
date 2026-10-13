// TaxTriageParitySourceManifestMaskTests.swift - The TaxTriage parity's source-manifest mask hides one number and no line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30, BIO ruling Q1 step 6 and the conditions of QA, UX and ARCH on vote V-B30.
// `TaxTriageParityComparison.sourceManifestPolicy(_:)` masks only the runtime number in a TaxTriage entry's summary, so
// two runs whose entries differ in the seconds they ran compare equal, while another sample count, a missing runtime
// line or another status still differ. Each case writes a one-entry `analyses-manifest.json` into a bundle under each
// of two side roots through `AnalysisManifestStore`, as the executor's source record does, and compares the two files
// as the parity's source-manifest compare does, with the classifier parity's masks. It runs no stand-in, so it is a
// pure class of the unit tier.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport

final class TaxTriageParitySourceManifestMaskTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-manifest-mask").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testTwoRuntimesOfOneEntryCompareEqual() throws {
        XCTAssertEqual(try differences(Self.summary(runtime: "2.5"), Self.summary(runtime: "6.3")), [])
    }

    func testARuntimeOfSeveralDigitsCompareEqual() throws {
        XCTAssertEqual(try differences(Self.summary(runtime: "1234.5"), Self.summary(runtime: "0.1")), [])
    }

    func testWithoutTheMaskTheTwoRuntimesDiffer() throws {
        let found = try differences(Self.summary(runtime: "2.5"), Self.summary(runtime: "6.3"), masked: false)
        XCTAssertEqual(found.count, 1, "the compare's own masks leave the runtime: \(found)")
    }

    func testAnotherSampleCountStillDiffers() throws {
        let found = try differences(Self.summary(samples: 1), Self.summary(samples: 2))
        XCTAssertEqual(found.count, 1, found.joined(separator: "\n"))
    }

    func testASummaryWithoutItsRuntimeLineStillDiffers() throws {
        let found = try differences(Self.summary(runtime: "2.5"), Self.summary(runtime: nil))
        XCTAssertEqual(found.count, 1, "the mask needs the line, so a missing one shows: \(found)")
    }

    func testAnotherStatusStillDiffers() throws {
        let found = try differences(
            Self.summary(status: "completed with warnings"),
            Self.summary(status: "completed successfully")
        )
        XCTAssertEqual(found.count, 1, found.joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// A one-sample summary in the words `TaxTriageResult.summary` writes, its runtime as the second line.
    private static func summary(
        status: String = "completed successfully",
        runtime: String? = "2.5",
        samples: Int = 1
    ) -> String {
        var lines = ["TaxTriage pipeline \(status)"]
        if let runtime {
            lines.append("Runtime: \(runtime)s")
        }
        lines += ["Samples: \(samples)", "Reports: \(samples)", "Metrics: \(samples)", "Total output files: \(9 * samples)"]
        return lines.joined(separator: "\n")
    }

    /// The differences of two one-entry manifests whose summaries are `summaryA` and `summaryB`, under the source
    /// manifest's policy, or under the compare's own policy when `masked` is false.
    private func differences(_ summaryA: String, _ summaryB: String, masked: Bool = true) throws -> [String] {
        let rootA = root.appendingPathComponent("A", isDirectory: true)
        let rootB = root.appendingPathComponent("B", isDirectory: true)
        let fileA = try manifest(in: rootA, summary: summaryA)
        let fileB = try manifest(in: rootB, summary: summaryB)
        let policy = ClassifierParityComparison.maskPolicy(sideRoots: [rootA, rootB])
        return try OutputEquivalence.differences(
            fileA,
            fileB,
            kind: .bundle,
            masks: masked ? TaxTriageParityComparison.sourceManifestPolicy(policy) : policy
        )
    }

    /// `Project.lungfish/Imports/S1.lungfishfastq/analyses-manifest.json` under `sideRoot`, with one entry.
    private func manifest(in sideRoot: URL, summary: String) throws -> URL {
        let bundle = sideRoot.appendingPathComponent("Project.lungfish/Imports/S1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let entry = AnalysisManifestEntry(
            tool: "taxtriage",
            analysisDirectoryName: "taxtriage-batch-2026-10-13T10-00-00",
            displayName: "TaxTriage Classification",
            parameters: ["k2Confidence": .double(0.2), "platform": .string("ILLUMINA")],
            summary: summary
        )
        try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundle)
        return bundle.appendingPathComponent(AnalysisManifest.filename)
    }
}
