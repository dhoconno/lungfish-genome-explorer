// SalmonQuantRouteAdapterTests.swift - The Mac route's trim step states the adapter Trim Galore trimmed, read from its
// JSON reports and console line before the trim folder is removed (Phase 5.3 lane EX-ADOPT M4, Fix RS-QUANT-ADAPTER,
// ruling BIO-PLAN-ADAPTER items 4, 5 and 8)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// These rows run the Mac route of `SalmonQuantRouteTests` with its stand-ins, so they extend that class.
extension SalmonQuantRouteTests {
    static let illuminaDetection = "Using Illumina adapter for trimming (count: 365). Second best hit was Nextera (count: 0)."

    /// Trim Galore's stand-in, which also writes each input's JSON report and prints a console to standard error, as
    /// 2.3.0 does: the saved C7 report with the Docker run's console, and on the second call, when `nexteraSecond`, the
    /// same report naming Nextera with the Linux host's Nextera line.
    func installAdapterTrimGalore(nexteraSecond: Bool) throws {
        let fixtures = RNASeqFixtures.root.appendingPathComponent("trim-galore-adapter", isDirectory: true)
        let report = try String(contentsOf: fixtures.appendingPathComponent("c7_1.fq.gz_trimming_report.json"), encoding: .utf8)
        let illumina = #"{"name": "Illumina", "sequence": "AGATCGGAAGAGC"}"#
        XCTAssertTrue(report.contains(illumina), "the saved report names Illumina")
        let files = capture.appendingPathComponent("adapter", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(report.utf8).write(to: files.appendingPathComponent("illumina.json"))
        try Data(report.replacingOccurrences(of: illumina, with: #"{"name": "Nextera", "sequence": "CTGTCTCTTATA"}"#).utf8)
            .write(to: files.appendingPathComponent("nextera.json"))
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("trim-pair1.stderr"), to: files.appendingPathComponent("illumina.console"))
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("cy0721_01-detection.txt"), to: files.appendingPathComponent("nextera.console"))
        let script = """
            #!/bin/sh
            echo "$*" >> "\(capture.path)/trimlog"
            k=illumina
            [ -f "\(files.path)/once" ] && [ \(nexteraSecond ? 1 : 0) = 1 ] && k=nextera
            /usr/bin/touch "\(files.path)/once"
            o=""; paired=0; files=""
            while [ $# -gt 0 ]; do
              case "$1" in -o) o="$2"; shift 2 ;; --paired) paired=1; shift ;; -*) shift ;; *) files="$files $1"; shift ;; esac
            done
            /bin/mkdir -p "$o"; n=0
            for f in $files; do
              n=$((n + 1)); name=$(/usr/bin/basename "$f"); stem=${name%.fastq}; stem=${stem%.fq}
              if [ $paired = 1 ]; then /bin/cp "$f" "$o/${stem}_val_${n}.fq"; else /bin/cp "$f" "$o/${stem}_trimmed.fq"; fi
              /bin/cp "\(files.path)/$k.json" "$o/${name}_trimming_report.json"
            done
            /bin/cat "\(files.path)/$k.console" >&2
            exit 0
            """
        try stand.install("trim_galore", script: script)
    }

    /// The trim step states, from the call's JSON reports and its console line, the adapter's name and sequence, the
    /// read 2 adapter, the length cutoff and the line, in the adopt's words. A result of one adapter has no sentence.
    func testTheMacTrimStepStatesTheAdapterFromItsReportsAndConsoleLine() async throws {
        try installAdapterTrimGalore(nexteraSecond: false)
        let set = try await makeSetAndIndex()
        let envelope = try record(try await quant([try pairBundle("A")], set: set, trim: .trimGalore(polyG: false)).resultURL)
        let trim = try XCTUnwrap(envelope.steps.first { $0.toolName == "trim_galore" }, "the trim call has a step")
        XCTAssertEqual(text(trim, "adapter"), "Trim Galore 2.3.0 auto-detected the Illumina adapter AGATCGGAAGAGC in read 1.")
        XCTAssertEqual(text(trim, "adapterName"), "Illumina")
        XCTAssertEqual(text(trim, "adapterSequence"), "AGATCGGAAGAGC")
        XCTAssertEqual(text(trim, "adapterRead2"), "none")
        XCTAssertEqual(trim.resolvedOptions["lengthCutoff"], .integer(20))
        XCTAssertEqual(text(trim, "adapterDetection"), Self.illuminaDetection)
        XCTAssertEqual(text(trim, "polyG"), "Poly-G trimming: off (LGE default)")
        XCTAssertNil(envelope.options.resolvedDefaults["adapters"])
    }

    /// A Mac result whose samples got different adapters says so in one sentence of its record, in the adopt's words.
    func testAMacResultWhoseSamplesGotDifferentAdaptersSaysSoInOneSentence() async throws {
        try installAdapterTrimGalore(nexteraSecond: true)
        let set = try await makeSetAndIndex()
        let bundles = [try pairBundle("A"), try pairBundle("B")]
        let envelope = try record(try await quant(bundles, set: set, trim: .trimGalore(polyG: false)).resultURL)
        XCTAssertEqual(
            envelope.options.resolvedDefaults["adapters"],
            .string("Trim Galore chose different adapters for the samples of this result, the Illumina adapter AGATCGGAAGAGC "
                + "for A and the Nextera adapter CTGTCTCTTATA for B."))
        let second = try XCTUnwrap(envelope.steps.last { $0.toolName == "trim_galore" })
        XCTAssertEqual(text(second, "adapter"), "Trim Galore 2.3.0 auto-detected the Nextera adapter CTGTCTCTTATA in read 1.")
        XCTAssertEqual(text(second, "sample"), "B")
    }
}
