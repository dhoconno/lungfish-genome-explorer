// V15ParityReportTests.swift - C4-4 D-4: the reports parsed and compared, with the command line, paths and times removed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishTestSupport
@testable import LungfishPortable

/// C4-4 D-4 (SWIFT SW4-8 and SW4-9, BIO B-D4-1 to B-D4-3, QA Q4-7 to Q4-9, CHTC CH-6, UX U4-6). A small fastp JSON and deacon
/// summary stand for the two reports; each test plants one change and reads the findings.
final class V15ParityReportTests: XCTestCase {
    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private func fastp(
        afterReads: Int = 1000, rate: Double = 0.732151, command: String = "/env/fastp -i a -o b -j r.json", version: String = "1.3.6"
    ) -> [String: Any] {
        ["summary": ["fastp_version": version, "sequencing": "paired end (151 cycles + 151 cycles)",
                     "before_filtering": ["total_reads": 2000, "q20_rate": 0.97],
                     "after_filtering": ["total_reads": afterReads, "q20_rate": 0.98]] as [String: Any],
         "filtering_result": ["passed_filter_reads": 990, "low_quality_reads": 3],
         "duplication": ["rate": rate], "insert_size": ["peak": 150, "unknown": 5, "histogram": [0, 4, 9, 16]] as [String: Any],
         "command": command]
    }

    private func deacon(seqsOut: Int = 900, version: String = "deacon 0.16.0", time: Double = 3.58, path: String = "/a/in.fq.gz") -> [String: Any] {
        ["version": version, "index": path, "input": path, "input2": path, "output": path, "output2": path, "k": 31, "w": 15,
         "seqs_in": 1000, "seqs_out": seqsOut, "seqs_removed": 100, "bp_in": 150_000, "bp_out": 135_000, "time": time,
         "seqs_per_second": 677_977, "bp_per_second": 66_731_178, "seqs_per_second_total": 677_045, "bp_per_second_total": 66_639_426]
    }

    private func compare(_ adopted: [String: Any], _ mac: [String: Any]) -> V15ReportComparison {
        V15Reports.compare(adopted: data(adopted), mac: data(mac), label: "report")
    }

    private func text(_ findings: [V15Finding]) -> String { findings.map(\.description).joined(separator: "\n") }

    /// SW4-9, QA Q4-9, UX U4-6: a count changed in the adopted fastp JSON gives exactly one finding that names its key, and the
    /// same reports unchanged give none.
    func testParsedReportFailsOnChangedCount() {
        XCTAssertEqual(text(compare(fastp(), fastp()).findings), "")
        let planted = compare(fastp(afterReads: 1001), fastp()).findings
        XCTAssertEqual(planted.count, 1, text(planted))
        XCTAssertTrue(planted.first?.key.hasSuffix("summary.after_filtering.total_reads") == true, text(planted))
        XCTAssertEqual(planted.first?.adopted, "1001")
        XCTAssertEqual(planted.first?.mac, "1000")
    }

    /// CH-6, SW4-9: a changed `command` gives no finding and is printed with its class, a changed rate gives one finding that
    /// names `duplication.rate`, and the tool version is compared and never removed (Q4-9).
    func testParsedReportIgnoresCommandAndComparesRatesAndVersion() {
        let command = compare(fastp(command: "/mac/fastp -i x -o y"), fastp())
        XCTAssertEqual(text(command.findings), "")
        XCTAssertTrue(command.reported.contains { $0.contains("command") && $0.contains("command line") }, command.reported.description)
        let rate = compare(fastp(rate: 0.732152), fastp()).findings
        XCTAssertEqual(rate.count, 1, text(rate))
        XCTAssertTrue(rate.first?.key.hasSuffix("duplication.rate") == true, text(rate))
        let version = compare(fastp(version: "1.3.7"), fastp()).findings
        XCTAssertEqual(version.count, 1, text(version))
        XCTAssertTrue(version.first?.key.hasSuffix("summary.fastp_version") == true, text(version))
    }

    /// QA Q4-9, UX U4-6: a count changed in the deacon summary gives one finding that names the key, the version is compared,
    /// and the five path keys, the time and the four rates computed from it are set aside with their class printed.
    func testParsedDeaconSummaryFailsOnChangedCountAndSetsAsideNamedKeys() {
        let counts = compare(deacon(seqsOut: 899), deacon()).findings
        XCTAssertEqual(counts.count, 1, text(counts))
        XCTAssertTrue(counts.first?.key.hasSuffix("seqs_out") == true, text(counts))
        let named = compare(deacon(time: 9.99, path: "/mac/in.fq.gz"), deacon())
        XCTAssertEqual(text(named.findings), "")
        for (key, keyClass) in V15Reports.deaconRemoved {
            XCTAssertTrue(named.reported.contains { $0.contains("key=\(key) ") && $0.contains("class=\(keyClass.rawValue)") }, "\(key): \(named.reported)")
        }
        XCTAssertEqual(compare(deacon(version: "deacon 0.17.0"), deacon()).findings.count, 1, "the version is compared")
    }

    /// B-D4-2: a key on one route only fails, a report that does not parse fails, and so does a report of neither kind.
    func testReportKeyOnOneRouteOnlyAndUnparsableReportFail() {
        var withoutRate = fastp()
        withoutRate.removeValue(forKey: "duplication")
        let oneRoute = compare(withoutRate, fastp()).findings
        XCTAssertEqual(oneRoute.count, 1, text(oneRoute))
        XCTAssertTrue(oneRoute.first?.key.hasSuffix("duplication") == true, text(oneRoute))
        let garbage = V15Reports.compare(adopted: Data("not json".utf8), mac: data(fastp()), label: "report")
        XCTAssertEqual(garbage.findings.count, 1, text(garbage.findings))
        XCTAssertTrue(garbage.findings.first?.why.contains("parse") == true, text(garbage.findings))
        let neither = compare(["unrelated": 1], ["unrelated": 1]).findings
        XCTAssertEqual(neither.count, 1, text(neither))
        XCTAssertTrue(neither.first?.why.contains("neither") == true, text(neither))
    }

    /// QA Q4-8: the file's hash and size are checked against the record's entry before the file is parsed, so a report swapped
    /// after it was recorded fails on the hash.
    func testReportBytesMustMatchTheRecordedDigestAndSize() {
        let bytes = data(fastp())
        let record: [String: Any] = ["path": "r.json", "checksumSHA256": PortableDigest.sha256Hex(of: bytes), "fileSize": bytes.count]
        XCTAssertEqual(text(V15Reports.integrity(of: bytes, record: record, label: "report", route: .adopted)), "")
        let swapped = V15Reports.integrity(of: data(fastp(afterReads: 1001)), record: record, label: "report", route: .mac)
        XCTAssertTrue(swapped.contains { $0.key.hasSuffix("checksumSHA256") && $0.why.contains("mac") }, text(swapped))
    }

    /// The reports are read from each bundle's `metadata/recipe-step-artifacts/` and paired by step and position, never by name,
    /// so the adopted copy named with the emitter's stem still pairs with the Mac's. A planted count in one copy, recorded again
    /// with its new digest and size, gives one finding, and a copy that is not on disk gives one finding.
    func testReportCopiesPairByStepAndPositionNotByName() throws {
        let root = try TestTempDirectory.make(prefix: "V15ParityReport")
        defer { try? FileManager.default.removeItem(at: root) }
        let adoptedBundle = root.appendingPathComponent("adopted.lungfishfastq", isDirectory: true)
        let macBundle = root.appendingPathComponent("mac.lungfishfastq", isDirectory: true)
        for bundle in [adoptedBundle, macBundle] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("metadata/recipe-step-artifacts"), withIntermediateDirectories: true)
        }
        let adoptedName = "1-1-trim-sample_fused_fastp_report.json"
        let macName = "1-1-trim-C079876_S1_fused_fastp_report_E4179EEA-3EBC-4157-A740-94D976E7F09B.json"
        func step(_ name: String, _ bytes: Data) -> [String: Any] {
            let report: [String: Any] = [
                "role": "output", "format": "json", "checksumSHA256": PortableDigest.sha256Hex(of: bytes), "fileSize": bytes.count,
                "path": "@/Imports/C079876_S1.lungfishfastq/metadata/recipe-step-artifacts/\(name)",
            ]
            let work: [String: Any] = ["role": "output", "format": "fastq", "path": "work/x.fq.gz", "checksumSHA256": "aaaa", "fileSize": 1]
            return ["outputs": [work, report]]
        }
        let macBytes = data(fastp(command: "/mac/fastp"))
        try macBytes.write(to: macBundle.appendingPathComponent("metadata/recipe-step-artifacts/\(macName)"))
        func findings(adopted bytes: Data, write: Bool = true) -> [V15Finding] {
            if write { try? bytes.write(to: adoptedBundle.appendingPathComponent("metadata/recipe-step-artifacts/\(adoptedName)")) }
            var comparison = V15Comparison(roots: [:], payloadFileNames: [])
            comparison.compareReportCopies(
                pairs: [(label: "fastp#1", adopted: step(adoptedName, bytes), mac: step(macName, macBytes))],
                adoptedBundle: adoptedBundle, macBundle: macBundle
            )
            return comparison.findings
        }
        XCTAssertEqual(text(findings(adopted: data(fastp()))), "")
        let planted = findings(adopted: data(fastp(afterReads: 1001)))
        XCTAssertEqual(planted.count, 1, text(planted))
        XCTAssertTrue(planted.first?.key.contains("summary.after_filtering.total_reads") == true, text(planted))
        try FileManager.default.removeItem(at: adoptedBundle.appendingPathComponent("metadata/recipe-step-artifacts/\(adoptedName)"))
        let missing = findings(adopted: data(fastp()), write: false)
        XCTAssertEqual(missing.count, 1, text(missing))
    }
}
