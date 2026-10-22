// BBToolsRunTimeMaskTests.swift - Mask M-6 hides the BBTools clock in a provenance stderr and nothing beside it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport

/// A chunked ONT import keeps the stderr of each reformat.sh step, whose read and base counts are provenance, and
/// BBTools prints its run time and rates beside them, so two runs never print the same figures. Mask M-6 of
/// docs/contracts/CLI-EQUIVALENCE.md masks the seconds of the `Time:` line and the rate of each processed line in a
/// provenance `stderr`. Every count, the command, a line added or lost and the same text anywhere else are still
/// compared (lane C2-ONTBIN, the manager's option (b)).
final class BBToolsRunTimeMaskTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbtools-run-time-mask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// reformat.sh 40.02's stderr for two reads, as it prints it, with the clock figures of run 0 or of run 1.
    private func lines(_ run: Int) -> [String] {
        let figures = run == 0 ? ("0.120", "0.02k", "0.00m") : ("0.087", "0.03k", "0.01m")
        return [
            "java -ea   -Xmx300m -Xms300m -cp /opt/bbmap/current/ jgi.ReformatReads in=chunk.fastq out=stored.fastq.gz quantize=0,14,21,27,32,36 interleaved=f",
            "Executing jgi.ReformatReads [in=chunk.fastq, out=stored.fastq.gz, quantize=0,14,21,27,32,36, interleaved=f]",
            "",
            "Input is being processed as unpaired",
            "Input:                  \t2 reads          \t20 bases",
            "Output:                 \t2 reads (100.00%) \t20 bases (100.00%)",
            "",
            "Time:                         \t\(figures.0) seconds.",
            "Reads Processed:           2 \t\(figures.1) reads/sec",
            "Bases Processed:          20 \t\(figures.2) bases/sec",
        ]
    }

    private func text(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func found(_ a: URL, _ b: URL) throws -> [String] {
        try OutputEquivalence.differences(a, b, kind: .files)
    }

    func testTheRunTimeAndRatesAreMaskedAndEveryCountIsKept() throws {
        let (a, b) = try makeRoots()
        let record = "x.lungfish-provenance.json"

        try write(try json(["stderr": text(lines(0))]), to: a, record)
        try write(try json(["stderr": text(lines(1))]), to: b, record)
        XCTAssertEqual(try found(a, b), [], "only the clock figures differ")

        // A step's stderr, where the ONT import's envelope keeps it.
        let step = { (run: Int) throws in try self.json(["steps": [["tool": "reformat.sh", "stderr": self.text(self.lines(run))]]]) }
        try write(try step(0), to: a, record)
        try write(try step(1), to: b, record)
        XCTAssertEqual(try found(a, b), [], "a step's stderr")

        // A count line keeps its count, and everything else in the text is compared, with the clock masked on both sides.
        let edits: [(name: String, apply: ([String]) -> [String])] = [
            ("the reads processed", { $0.map { $0.replacingOccurrences(of: "Processed:           2 ", with: "Processed:           3 ") } }),
            ("the bases processed", { $0.map { $0.replacingOccurrences(of: "Processed:          20 ", with: "Processed:          21 ") } }),
            ("the input count", { $0.map { $0.replacingOccurrences(of: "\t2 reads          ", with: "\t3 reads          ") } }),
            ("the output bases", { $0.map { $0.replacingOccurrences(of: "\t20 bases (100.00%)", with: "\t19 bases (95.00%)") } }),
            ("the quantize argument", { $0.map { $0.replacingOccurrences(of: "quantize=0,14,21,27,32,36", with: "quantize=0,8,13,22,27,32,37") } }),
            ("the rate unit", { $0.map { $0.replacingOccurrences(of: "reads/sec", with: "pairs/sec") } }),
            ("a line added", { $0 + ["Pairs Processed:           1 \t0.01k pairs/sec"] }),
            ("a line lost", { Array($0.dropLast()) }),
        ]
        for edit in edits {
            try write(try json(["stderr": text(lines(0))]), to: a, record)
            try write(try json(["stderr": text(edit.apply(lines(1)))]), to: b, record)
            XCTAssertEqual(try found(a, b).count, 1, edit.name)
        }

        // A time that does not start its line is not BBTools' run time line.
        let shifted = { (run: Int) in self.lines(run).map { $0.hasPrefix("Time:") ? "Clump " + $0 : $0 } }
        try write(try json(["stderr": text(shifted(0))]), to: a, record)
        try write(try json(["stderr": text(shifted(1))]), to: b, record)
        XCTAssertEqual(try found(a, b).count, 1, "a time inside a line")
    }

    func testTheSameTextOutsideAProvenanceStderrIsComparedAsWritten() throws {
        let (a, b) = try makeRoots()
        let record = "x.lungfish-provenance.json"
        for key in ["stdout", "message"] {
            try write(try json([key: text(lines(0))]), to: a, record)
            try write(try json([key: text(lines(1))]), to: b, record)
            XCTAssertEqual(try found(a, b).count, 1, "under \(key)")
        }
        try empty(a, b)
        try write(text(lines(0)), to: a, "reformat.log")
        try write(text(lines(1)), to: b, "reformat.log")
        XCTAssertEqual(try found(a, b).count, 1, "reformat.log")
        try empty(a, b)
        try write(try json(["stderr": text(lines(0))]), to: a, "result.json")
        try write(try json(["stderr": text(lines(1))]), to: b, "result.json")
        XCTAssertEqual(try found(a, b).count, 1, "a payload that holds a stderr")
    }

    private func makeRoots() throws -> (URL, URL) {
        let a = scratch.appendingPathComponent("A", isDirectory: true)
        let b = scratch.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return (a, b)
    }

    private func write(_ text: String, to root: URL, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func empty(_ roots: URL...) throws {
        for root in roots {
            for item in try FileManager.default.contentsOfDirectory(atPath: root.path) {
                try FileManager.default.removeItem(at: root.appendingPathComponent(item))
            }
        }
    }
}
