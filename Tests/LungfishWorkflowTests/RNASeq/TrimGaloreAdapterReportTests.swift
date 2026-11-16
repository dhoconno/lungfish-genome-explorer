// TrimGaloreAdapterReportTests.swift - One reader of a trim call's JSON reports and console line states the adapter
// Trim Galore trimmed, and a result whose samples got different adapters says so in one sentence (Phase 5.3 lane
// EX-ADOPT M4, ruling BIO-PLAN-ADAPTER items 4, 5 and 8)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TrimGaloreAdapterReportTests: XCTestCase {
    static var folder: URL { RNASeqFixtures.root.appendingPathComponent("trim-galore-adapter", isDirectory: true) }
    static let illuminaLine = "Using Illumina adapter for trimming (count: 365). Second best hit was Nextera (count: 0)."
    static let nexteraLine = "Using Nextera adapter for trimming (count: 66736). Second best hit was smallRNA (count: 6)."
    static let fallbackLine = "No adapters detected in the first 200 reads. Defaulting to Illumina adapter."
    static let fallbackWords =
        "No adapter found in the reads Trim Galore checked, so its fallback, the Illumina adapter AGATCGGAAGAGC, was used."

    /// The saved C7 report of `SCR/rulings/tmp-ADJ-ROUTE/auto/`, where Trim Galore 2.3.0 chose Illumina.
    static func illuminaReport() throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent("c7_1.fq.gz_trimming_report.json"))
    }

    /// The C7 report with its adapter set to Nextera, the adapter the GSE225770 line names. No saved report of that
    /// library is here, so the stand-in changes only `parameters.adapters`.
    static func nexteraReport() throws -> Data {
        let text = String(decoding: try illuminaReport(), as: UTF8.self)
        let illumina = #""adapters": [{"name": "Illumina", "sequence": "AGATCGGAAGAGC"}]"#
        XCTAssertTrue(text.contains(illumina), "the saved report names Illumina")
        return Data(text.replacingOccurrences(of: illumina, with: #""adapters": [{"name": "Nextera", "sequence": "CTGTCTCTTATA"}]"#).utf8)
    }

    /// A fixture's text: `trim-pair1.stderr` (EX-PLAN-SALMON's Docker run), `cy0721_01-detection.txt` (the Linux host)
    /// or `fallback.stderr` (Trim Galore 2.3.0 on 200 pairs with no adapter).
    static func console(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    static func words(_ lines: [String: ParameterValue]) -> [String] {
        lines.values.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
    }

    // MARK: - Item 4, the reader

    /// The Docker run's console line and the saved Illumina report: the name and sequence of `parameters.adapters`, the
    /// read 2 adapter "none", `length_cutoff` and the line as Trim Galore wrote it.
    func testTheDockerRunsLineAndTheIlluminaReportReadAutoDetectedIllumina() throws {
        let console = try Self.console("trim-pair1.stderr")
        XCTAssertTrue(console.contains(Self.illuminaLine))
        let lines = TrimGaloreAdapterReport.read(reports: [try Self.illuminaReport()], console: console).lines
        XCTAssertEqual(lines["adapter"], .string("Trim Galore 2.3.0 auto-detected the Illumina adapter AGATCGGAAGAGC in read 1."))
        XCTAssertEqual(lines["adapterName"], .string("Illumina"))
        XCTAssertEqual(lines["adapterSequence"], .string("AGATCGGAAGAGC"))
        XCTAssertEqual(lines["adapterRead2"], .string("none"))
        XCTAssertEqual(lines["lengthCutoff"], .integer(20))
        XCTAssertEqual(lines["adapterDetection"], .string(Self.illuminaLine))
    }

    /// The Linux host's Nextera line on GSE225770 (`SCR/rulings/tmp-BIO-LINUX-HOST/cmp2.out:80`).
    func testTheLinuxHostsNexteraLineReadsAutoDetectedNextera() throws {
        let console = try Self.console("cy0721_01-detection.txt")
        XCTAssertEqual(console, Self.nexteraLine + "\n")
        let lines = TrimGaloreAdapterReport.read(reports: [try Self.nexteraReport()], console: console).lines
        XCTAssertEqual(lines["adapter"], .string("Trim Galore 2.3.0 auto-detected the Nextera adapter CTGTCTCTTATA in read 1."))
        XCTAssertEqual(lines["adapterDetection"], .string(Self.nexteraLine))
    }

    /// Trim Galore's fallback, from a run on reads that hold no adapter, reads the ruling's words. Its report equals an
    /// auto-detected Illumina report, so the words come from the console line and never say auto-detected.
    func testAFallbackReadsTheRulingsWordsAndNeverAutoDetected() throws {
        let console = try Self.console("fallback.stderr")
        XCTAssertTrue(console.contains(Self.fallbackLine))
        let lines = TrimGaloreAdapterReport.read(reports: [try Self.illuminaReport()], console: console).lines
        XCTAssertEqual(lines["adapter"], .string(Self.fallbackWords))
        XCTAssertEqual(lines["adapterDetection"], .string(Self.fallbackLine))
        XCTAssertEqual(lines["adapterName"], .string("Illumina"))
        XCTAssertFalse(Self.words(lines).contains { $0.contains("auto-detected") }, "\(lines)")
    }

    /// A report with no console line, as a console of another Trim Galore version may be, never reads auto-detected.
    func testAReportWithNoDetectionLineNeverReadsAutoDetected() throws {
        let text = try String(contentsOf: Self.folder.appendingPathComponent("trim-pair1.stderr"), encoding: .utf8)
        let console = text.replacingOccurrences(of: Self.illuminaLine + "\n", with: "")
        let lines = TrimGaloreAdapterReport.read(reports: [try Self.illuminaReport()], console: console).lines
        XCTAssertEqual(lines["adapter"], .string(
            "Trim Galore 2.3.0 trimmed the Illumina adapter AGATCGGAAGAGC, and its console output holds no line that says how it chose that adapter."))
        XCTAssertEqual(lines["adapterDetection"], .string("Not recorded"))
        XCTAssertFalse(Self.words(lines).contains { $0.contains("auto-detected") }, "\(lines)")
        let unreadable = TrimGaloreAdapterReport.read(reports: [Data("not a report".utf8)], console: Self.illuminaLine).lines
        XCTAssertEqual(unreadable["adapter"], .string("Not recorded (Trim Galore wrote no readable JSON trimming report for this call)"))
        XCTAssertFalse(Self.words(unreadable).contains { $0.contains("auto-detected") }, "\(unreadable)")
    }

    /// A read 2 adapter that a detection set, such as `--small_rna`'s, is stated as the report holds it.
    func testAReadTwoAdapterIsStatedAsTheReportHoldsIt() throws {
        let text = String(decoding: try Self.illuminaReport(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""adapters_r2": []"#))
        let report = Data(text.replacingOccurrences(of: #""adapters_r2": []"#, with: #""adapters_r2": ["GATCGTCGGACT"]"#).utf8)
        let lines = TrimGaloreAdapterReport.read(reports: [report], console: Self.illuminaLine).lines
        XCTAssertEqual(lines["adapterRead2"], .string("GATCGTCGGACT"))
    }

    // MARK: - Item 8, samples that got different adapters

    /// A trim step of `sample` with the reader's lines.
    static func trimStep(_ sample: String, report: Data, console: String) -> ProvenanceStep {
        var options: [String: ParameterValue] = ["sample": .string(sample)]
        options.merge(TrimGaloreAdapterReport.read(reports: [report], console: console).lines) { _, new in new }
        return ProvenanceStep(
            toolName: "trim_galore", toolVersion: "2.3.0", argv: ["trim_galore"], resolvedOptions: options, exitStatus: 0,
            wallTimeSeconds: 1, startedAt: Date(), completedAt: Date(), managedToolID: ManagedToolID(rawValue: "trim_galore"))
    }

    /// Samples whose trim calls got different adapters give one sentence that names each adapter and its samples, and
    /// samples of one adapter, the fallback's among them, give none.
    func testSamplesThatGotDifferentAdaptersGiveOneSentence() throws {
        let illumina = try Self.illuminaReport(), nextera = try Self.nexteraReport()
        let steps = [
            Self.trimStep("S1", report: illumina, console: Self.illuminaLine),
            Self.trimStep("S2", report: nextera, console: Self.nexteraLine),
            Self.trimStep("S3", report: illumina, console: try Self.console("fallback.stderr")),
        ]
        XCTAssertEqual(
            TrimGaloreAdapterReport.differentAdapters(in: steps),
            "Trim Galore chose different adapters for the samples of this result, the Illumina adapter AGATCGGAAGAGC for S1 and S3 "
                + "and the Nextera adapter CTGTCTCTTATA for S2.")
        XCTAssertNil(TrimGaloreAdapterReport.differentAdapters(in: [steps[0], steps[2]]))
        XCTAssertNil(TrimGaloreAdapterReport.differentAdapters(in: []))
    }
}
