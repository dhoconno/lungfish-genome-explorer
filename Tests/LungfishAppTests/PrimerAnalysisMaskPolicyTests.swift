// PrimerAnalysisMaskPolicyTests.swift - Each mask of OutputEquivalence.MaskPolicy.primerAnalysis, with a negative control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 M1 (2), ruling 2 of the A67 review (limit 4). The primer analysis policy adds masks to the
// standard ones. Each test here writes one file into two tiny trees that differ only in what one mask hides, and
// checks that the policy finds them the same while the standard policy does not, so the mask is the thing that hides
// it. Its negative control changes a scientific value in the same file (a resolved option, a pair, a template base,
// a tool version or an exit status) and checks that the policy still reports that file. Pure, so it runs in the
// unit tier.

import Foundation
import XCTest
import LungfishTestSupport

final class PrimerAnalysisMaskPolicyTests: XCTestCase {
    private var scratch: URL!
    private var pairs = 0

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "primer-analysis-masks")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// The differences of two trees that each hold `relative` with the given text, under the primer analysis policy and
    /// under the standard one.
    private func compare(_ relative: String, _ textA: String, _ textB: String) throws -> (primer: [String], standard: [String]) {
        pairs += 1
        let a = scratch.appendingPathComponent("\(pairs)/A", isDirectory: true)
        let b = scratch.appendingPathComponent("\(pairs)/B", isDirectory: true)
        for (root, text) in [(a, textA), (b, textB)] {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return (
            try OutputEquivalence.differences(a, b, kind: .bundle, masks: .primerAnalysis),
            try OutputEquivalence.differences(a, b, kind: .bundle)
        )
    }

    /// The policy finds `textA` and `masked` the same where the standard policy does not, and still reports `changed`.
    private func assertHides(
        _ relative: String, _ textA: String, _ masked: String, butNot changed: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let hidden = try compare(relative, textA, masked)
        XCTAssertEqual(hidden.primer, [], "the policy hides it", file: file, line: line)
        XCTAssertFalse(hidden.standard.isEmpty, "the standard policy sees it, so the mask hides it", file: file, line: line)
        let control = try compare(relative, textA, changed)
        XCTAssertEqual(control.primer.count, 1, "\(control.primer)", file: file, line: line)
        XCTAssertTrue(control.primer.first?.hasPrefix("differs: \(relative)") == true, "\(control.primer)", file: file, line: line)
    }

    private static func hex(_ digit: Character) -> String { String(repeating: digit, count: 64) }

    // MARK: - Digests (primerAnalysisDigests, records and payloads)

    func testADigestOrSizeInAPayloadIsHiddenAndAResolvedOptionStillDiffers() throws {
        func result(_ sha: Character, _ size: Int, primerOptSize: Int) -> String {
            #"{"options":{"resolved":{"primerOptSize":\#(primerOptSize)}},"sha256":"\#(Self.hex(sha))","byteSize":\#(size)}"#
        }
        try assertHides(
            "results/primer3-normalized-v1.json", result("a", 100, primerOptSize: 20), result("b", 200, primerOptSize: 20),
            butNot: result("a", 100, primerOptSize: 22)
        )
    }

    func testADigestOrSizeInARecordIsHiddenAndAFileListStillDiffers() throws {
        func manifest(_ sha: Character, _ size: Int, files: [String]) -> String {
            let names = files.map { #""\#($0)""# }.joined(separator: ",")
            return #"{"files":[\#(names)],"inputs":[{"path":"/elsewhere/in.fasta","checksumSHA256":"\#(Self.hex(sha))","fileSize":\#(size)}]}"#
        }
        try assertHides(
            "manifest.json", manifest("a", 100, files: ["results.json"]), manifest("c", 300, files: ["results.json"]),
            butNot: manifest("a", 100, files: ["results.json", "extra.bed"])
        )
    }

    // MARK: - What a host says about itself (primerAnalysisHost and primerAnalysisHostNames)

    func testTheHostsArgvCommandAndNamedOptionsAreHiddenAndAResolvedOptionStillDiffers() throws {
        func wrapper(_ argv: String, _ command: String, _ explicit: String, primerOptSize: Int) -> String {
            #"{"argv":[\#(argv)],"reproducibleCommand":"\#(command)","explicit":{\#(explicit)},"#
                + #""options":{"resolved":{"primerOptSize":\#(primerOptSize)}},"steps":[{"argv":[\#(argv)]}]}"#
        }
        try assertHides(
            "provenance/wrapper.json",
            wrapper(#""/x/xctest","-XCTest""#, "lungfish-cli", #""analysisName":"p""#, primerOptSize: 20),
            wrapper(#""/y/lungfish-cli","primers","design""#, "lungfish-cli primers design primer3", #""--assay":"pcr""#, primerOptSize: 20),
            butNot: wrapper(#""/x/xctest","-XCTest""#, "lungfish-cli", #""analysisName":"p""#, primerOptSize: 22)
        )
    }

    func testTheHostsNameAndVersionAreHiddenAndAToolVersionStillDiffers() throws {
        func envelope(_ host: String, _ executable: String, tool: String) -> String {
            #"{"caller":{"name":"\#(host)","path":"\#(executable)"},"tool":{"name":"primer3_core","version":"\#(tool)"}}"#
        }
        try assertHides(
            "execution-provenance/run.json",
            envelope("Lungfish 2026.10.10 (dev)", "<external>/xctest", tool: "2.6.1"),
            envelope("lungfish-cli 2026.10.10", "<external>/lungfish-cli", tool: "2.6.1"),
            butNot: envelope("Lungfish 2026.10.10 (dev)", "<external>/xctest", tool: "2.6.2")
        )
    }

    // MARK: - Record masks on payload text (uuids, runIDs, isoTimestamps, provenanceRuntime)

    func testAUUIDInPayloadTextIsHiddenAndAPairStillDiffers() throws {
        let one = "11111111-1111-4111-8111-111111111111", two = "22222222-2222-4222-8222-222222222222"
        func bed(_ id: String, start: Int) -> String { "template-one\t\(start)\t\(start + 20)\t\(id)-left\t0\t+\n" }
        try assertHides("annotations/pairs.bed", bed(one, start: 10), bed(two, start: 10), butNot: bed(one, start: 12))
    }

    func testARunIDInPayloadTextIsHiddenAndATemplateBaseStillDiffers() throws {
        func fasta(_ id: String, _ bases: String) -> String { ">template-one \(id)\n\(bases)\n" }
        try assertHides(
            "inputs/template.fasta", fasta("aln_1a2b3c4d", "ACGTACGT"), fasta("aln_9f8e7d6c", "ACGTACGT"),
            butNot: fasta("aln_1a2b3c4d", "ACGTACGA")
        )
    }

    func testAnISOTimeInPayloadTextIsHiddenAndAPrimerStillDiffers() throws {
        func boulder(_ time: String, _ primer: String) -> String { "CREATED=\(time)\nPRIMER_LEFT_0_SEQUENCE=\(primer)\n=\n" }
        try assertHides(
            "native/run.boulder", boulder("2026-10-18T10:00:00Z", "ACGTTGCA"), boulder("2026-10-18T11:30:15Z", "ACGTTGCA"),
            butNot: boulder("2026-10-18T10:00:00Z", "ACGTTGCC")
        )
    }

    func testTheRuntimeKeysInAPayloadEnvelopeAreHiddenAndAnExitStatusStillDiffers() throws {
        func run(_ executable: String, _ host: String, _ pid: Int, _ seconds: Double, exit: Int) -> String {
            #"{"executablePath":"\#(executable)","hostName":"\#(host)","pid":\#(pid),"wallTimeSeconds":\#(seconds),"exitStatus":\#(exit)}"#
        }
        try assertHides(
            "execution-provenance/step.json", run("/a/primer3_core", "galah", 11, 1.5, exit: 0),
            run("/b/primer3_core", "other", 22, 2.5, exit: 0), butNot: run("/a/primer3_core", "galah", 11, 1.5, exit: 1)
        )
    }
}
