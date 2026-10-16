// OutputEquivalenceTests+Masks.swift - Self-tests for the masks that reviewed contract changes added
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// OutputEquivalenceTests.swift is over the size baseline and may not grow, so a mask added after it holds
// its test here, as an extension of the same class. Each test builds its own two roots.

import Foundation
import XCTest
import LungfishTestSupport

extension OutputEquivalenceTests {
    /// A demo project's install record (`.lgedemo.json`) holds the time `DemoProjectInstaller` installed the
    /// project, to the second. Two installs never take the same second, so the contract masks the value of
    /// the record's top-level `installedAt` in a JSON payload. The mask reads a document that holds the
    /// record's four keys and no other, so the same key in any other document, a key one level down, a record
    /// with another key, a missing `installedAt` and the record's other three values are still compared (manager
    /// answer to lane A45 M4's question 1, by the rule of BIO's ruling on M3c section b).
    func testTheDemoInstallClockIsMaskedAndNothingBesideIt() throws {
        let top = try TestTempDirectory.make(prefix: "demo-install-clock")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let name = "Installed/Demo Fixture.lungfish/.lgedemo.json"
        let found = { try OutputEquivalence.differences(a, b, kind: .files) }
        let clockA = "2026-10-14T18:19:48Z"
        let clockB = "2026-10-14T18:19:49Z"

        // The record as DemoProjectInstaller writes it, with an edit applied to the document first.
        let record = { (clock: String, edit: (inout [String: Any]) -> Void) throws -> Data in
            var document: [String: Any] = [
                "id": "demo-fixture", "installedAt": clock, "sha256": String(repeating: "a", count: 64), "version": "2026.9.44",
            ]
            edit(&document)
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        }
        let write = { (data: Data, root: URL) throws in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        try write(record(clockA) { _ in }, a)
        try write(record(clockB) { _ in }, b)
        XCTAssertEqual(try found(), [], "only the install time differs")

        // Each change differs in the one file on top of the clocks. The last four leave the clock to be
        // compared as written, with each side's own time.
        let cases: [(label: String, both: Bool, edit: (inout [String: Any]) -> Void)] = [
            ("version", false, { $0["version"] = "2026.9.45" }),
            ("sha256", false, { $0["sha256"] = String(repeating: "b", count: 64) }),
            ("id", false, { $0["id"] = "demo-other" }),
            ("no installedAt", false, { $0["installedAt"] = nil }),
            ("another key", true, { $0["note"] = "x" }),
            ("only installedAt", true, { $0 = ["installedAt": $0["installedAt"] as Any] }),
            ("installedAt one level down", true, { $0 = ["record": $0] }),
            ("one key missing besides installedAt", true, { $0["version"] = nil }),
        ]
        for (label, both, edit) in cases {
            try write(record(clockA, both ? edit : { _ in }), a)
            try write(record(clockB, edit), b)
            let result = try found()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }

    /// G5 (Phase 2.10, lane A50 M2, BR7). GATK writes the run's date into the VCF header line
    /// `##GATKCommandLine`, so two runs of one command never agree on it. The GATK compare masks the value of that
    /// line's trailing `Date=` and nothing else. A changed `CommandLine=` value, `Version=` or ID, the same key
    /// on another header line and a changed record still differ, and the standard compare still reports the date.
    func testTheGATKCompareMasksOnlyTheDateOfTheGATKCommandLineHeader() throws {
        let top = try TestTempDirectory.make(prefix: "gatk-header-date")
        addTeardownBlock { TestTempDirectory.cleanup(top) }
        let a = top.appendingPathComponent("a", isDirectory: true)
        let b = top.appendingPathComponent("b", isDirectory: true)
        let name = "variants/gatk/vc-1.vcf"
        let dateA = "October 16, 2026, 1:41:26\u{202F}PM CDT"
        let dateB = "October 16, 2026, 2:02:09\u{202F}PM CDT"
        let vcf = { (id: String, commandLine: String, version: String, date: String, source: String, record: String) -> Data in
            let header = "##GATKCommandLine=<ID=\(id),CommandLine=\"\(commandLine)\",Version=\"\(version)\",Date=\"\(date)\">"
            return Data(
                ["##fileformat=VCFv4.2", header, source, "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO", record, ""]
                    .joined(separator: "\n").utf8
            )
        }
        let write = { (data: Data, root: URL) throws in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let gatk = { try OutputEquivalence.differences(a, b, kind: .files, masks: .gatk) }
        let call = "HaplotypeCaller --sample-ploidy 2"
        let source = "##source=Lungfish,Date=\"Monday\""
        let record = "chr1\t4\t.\tT\tG\t60\tPASS\tDP=18"

        try write(vcf("HaplotypeCaller", call, "4.6.2.0", dateA, source, record), a)
        try write(vcf("HaplotypeCaller", call, "4.6.2.0", dateB, source, record), b)
        XCTAssertEqual(try gatk(), [], "only the run's date differs")
        XCTAssertEqual(
            try OutputEquivalence.differences(a, b, kind: .files), [],
            "the standard VCF compare drops every command header line, so it sees neither the date nor the command (BR7)"
        )

        // Each change differs in the one file, on top of the two dates.
        let cases: [(label: String, side: Data)] = [
            ("CommandLine value", vcf("HaplotypeCaller", "HaplotypeCaller --sample-ploidy 1", "4.6.2.0", dateB, source, record)),
            ("Version", vcf("HaplotypeCaller", call, "4.6.1.0", dateB, source, record)),
            ("ID", vcf("SelectVariants", call, "4.6.2.0", dateB, source, record)),
            ("Date= on another header line", vcf("HaplotypeCaller", call, "4.6.2.0", dateB, "##source=Lungfish,Date=\"Tuesday\"", record)),
            ("record", vcf("HaplotypeCaller", call, "4.6.2.0", dateB, source, record.replacingOccurrences(of: "\tG\t", with: "\tC\t"))),
        ]
        for (label, side) in cases {
            try write(side, b)
            let result = try gatk()
            XCTAssertEqual(result.count, 1, "\(label): \(result)")
            XCTAssertTrue(result.first?.hasPrefix("differs: \(name)") == true, "\(label): \(result)")
        }
    }
}
