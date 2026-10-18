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
        try compareTrees([relative: textA], [relative: textB])
    }

    /// The differences of two trees that hold the given files, under the primer analysis policy and the standard one.
    private func compareTrees(_ filesA: [String: String], _ filesB: [String: String]) throws -> (primer: [String], standard: [String]) {
        pairs += 1
        let a = scratch.appendingPathComponent("\(pairs)/A", isDirectory: true)
        let b = scratch.appendingPathComponent("\(pairs)/B", isDirectory: true)
        for (root, files) in [(a, filesA), (b, filesB)] {
            for (relative, text) in files {
                let file = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
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

    // MARK: - The PrimalScheme3 bundle (lane 12.16 M1 (3))

    func testAnUndashedInputUUIDIsNumberedAsItsDashedFormAndABaseOrAnMD5StillDiffers() throws {
        func tree(_ id: UUID, base: Character = "T", md5: Character = "a") -> [String: String] {
            let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
            return [
                "inputs/\(id.uuidString).fasta": ">input_\(hex)_row_0\nACG\(base)\n",
                "native/input_\(hex)_row_0.txt": "input_\(hex)_row_0\t2\t22\t\(String(repeating: md5, count: 32))\n",
            ]
        }
        let one = UUID(), two = UUID()
        let hidden = try compareTrees(tree(one), tree(two))
        XCTAssertEqual(hidden.primer, [])
        XCTAssertFalse(hidden.standard.isEmpty)
        let base = try compareTrees(tree(one), tree(two, base: "A"))
        XCTAssertEqual(base.primer.count, 1, "\(base.primer)")
        XCTAssertTrue(base.primer.first?.hasPrefix("differs: inputs/<UUID-1>.fasta") == true, "\(base.primer)")
        // A 32-digit value that is no UUID the side numbers, such as an MD5, is compared as written.
        let md5 = try compareTrees(tree(one), tree(two, md5: "b"))
        XCTAssertEqual(md5.primer.count, 1, "\(md5.primer)")
        XCTAssertTrue(md5.primer.first?.hasPrefix("differs: native/input_<UUID-1>_row_0.txt") == true, "\(md5.primer)")
    }

    func testTheSchemeIDPrimalScheme3DrawsIsHiddenAndAnAmpliconNumberStillDiffers() throws {
        func bed(_ id: String, amplicon: Int) -> String {
            "row\t2\t22\t\(id)_\(amplicon)_LEFT_1\t1\t+\nrow\t22\t404\t\(id)_\(amplicon)\t1\n"
                + #"{"hovertemplate":"%{y:.2f} <br>\#(id)_\#(amplicon)_RIGHT_1"}"# + "\n"
        }
        try assertHides("native/primer.bed", bed("5b5fa432", amplicon: 1), bed("c1124487", amplicon: 1), butNot: bed("5b5fa432", amplicon: 2))
        func config(_ id: String, size: Int) -> String {
            #"{"amplicon_size":\#(size),"msa_data":{"0":{"msa_uuid":{"type":"string","value":"\#(id)"}}}}"#
        }
        try assertHides("native/config.json", config("5b5fa432", size: 400), config("c1124487", size: 400), butNot: config("5b5fa432", size: 420))
    }

    func testANativeDigestIsHiddenAndANativeOptionStillDiffers() throws {
        func execution(_ digest: Character, size: Int) -> String {
            let md5 = String(repeating: digest, count: 32), sha = String(repeating: digest, count: 64)
            return #"{"nativeConfiguration":{"amplicon.bed.md5":{"type":"string","value":"\#(md5)"},"amplicon_size":\#(size),"#
                + #""msa_checksum":"\#(md5)"},"sourceInputs":[{"consumedSHA256":{"type":"string","value":"\#(sha)"}}]}"#
        }
        try assertHides("logs/execution.json", execution("a", size: 400), execution("b", size: 400), butNot: execution("a", size: 420))
    }

    func testTheConsoleClockAndProgressAreHiddenAndALoggedCountStillDiffers() throws {
        func log(_ first: String, _ second: String, amplicons: Int, pairs: Int, rate: String) -> String {
            "\(first) INFO     Read in MSA: row\n\(second) INFO     Generated \(amplicons) amplicons\n"
                + "Pairs:   0%|          | 0/\(pairs) [00:00<?, ?it/s]\rPairs:  55%|#####     | 431/\(pairs) [00:00<00:00, \(rate)it/s]"
                + "\rPairs: 100%|##########| \(pairs)/\(pairs) [00:00<00:00, \(rate)it/s]\n"
        }
        let blank = String(repeating: " ", count: 10)
        try assertHides(
            "logs/stdout.txt", log("[13:11:20]", blank, amplicons: 3, pairs: 781, rate: "4305.26"),
            log("[13:12:21]", "[13:12:22]", amplicons: 3, pairs: 781, rate: "4295.93"),
            butNot: log("[13:11:20]", blank, amplicons: 4, pairs: 781, rate: "4305.26")
        )
        func record(_ time: String, exit: Int) -> String {
            let stderr = "\(time) INFO     Completed\\nPairs: 100%|##########| 781/781 [00:00<00:00, 4305.26it/s]\\n"
            return #"{"exitStatus":\#(exit),"stderr":"\#(stderr)"}"#
        }
        try assertHides("logs/run.json", record("[13:11:20]", exit: 0), record("[13:12:21]", exit: 0), butNot: record("[13:11:20]", exit: 1))
    }

    // MARK: - A PNG (comparesPNGByPresence, the manager's grant to lane 12.16 c2)

    /// A PNG signature followed by `count` bytes of `fill`. The signature's first byte is no UTF-8 lead byte, so the
    /// standard compare reads the file as binary.
    private static func png(_ fill: UInt8, count: Int = 16) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: fill, count: count))
    }

    /// The differences of two trees that hold the given binary files, under the primer analysis policy and the standard one.
    private func compareData(_ filesA: [String: Data], _ filesB: [String: Data]) throws -> (primer: [String], standard: [String]) {
        pairs += 1
        let a = scratch.appendingPathComponent("\(pairs)/A", isDirectory: true)
        let b = scratch.appendingPathComponent("\(pairs)/B", isDirectory: true)
        for (root, files) in [(a, filesA), (b, filesB)] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (relative, data) in files {
                let file = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
        }
        return (
            try OutputEquivalence.differences(a, b, kind: .bundle, masks: .primerAnalysis),
            try OutputEquivalence.differences(a, b, kind: .bundle)
        )
    }

    func testOnlyThePrimerAnalysisPolicyComparesAPNGByPresence() {
        XCTAssertTrue(OutputEquivalence.MaskPolicy.primerAnalysis.comparesPNGByPresence)
        XCTAssertFalse(OutputEquivalence.MaskPolicy.standard.comparesPNGByPresence)
        XCTAssertFalse(OutputEquivalence.MaskPolicy.gatk.comparesPNGByPresence)
    }

    func testAPNGsPixelsAreHiddenAndAPNGOnOneSideOrUnderAnotherNameStillDiffers() throws {
        let plot = "native/run/input_row_0.png"
        let pixels = try compareData([plot: Self.png(1)], [plot: Self.png(2)])
        XCTAssertEqual(pixels.primer, [], "the policy compares the PNG by name and presence")
        XCTAssertEqual(pixels.standard.count, 1, "\(pixels.standard)")
        XCTAssertTrue(pixels.standard.first?.hasPrefix("differs: \(plot)") == true, "\(pixels.standard)")
        XCTAssertTrue(pixels.standard.first?.contains("binary sha256") == true, "the standard policy compares it by digest")
        let oneSided = try compareData([plot: Self.png(1)], ["native/run/input_row_0.bed": Data("row\t0\t10\n".utf8)])
        XCTAssertTrue(oneSided.primer.contains("only in A: \(plot)"), "\(oneSided.primer)")
        let renamed = try compareData([plot: Self.png(1)], ["native/run/input_row_1.png": Self.png(1)])
        XCTAssertTrue(renamed.primer.contains("only in A: \(plot)"), "\(renamed.primer)")
        XCTAssertTrue(renamed.primer.contains("only in B: native/run/input_row_1.png"), "\(renamed.primer)")
    }

    func testAFileThatIsNoPNGKeepsItsCompareUnderThePolicy() throws {
        let fake = try compareData(["plot.png": Data([0xFF, 0xFE, 0x00, 0x01])], ["plot.png": Data([0xFF, 0xFE, 0x00, 0x02])])
        XCTAssertEqual(fake.primer.count, 1, "a .png without the signature is compared by digest: \(fake.primer)")
        XCTAssertTrue(fake.primer.first?.hasPrefix("differs: plot.png") == true, "\(fake.primer)")
        let other = try compareData(["plot.bin": Self.png(1)], ["plot.bin": Self.png(2)])
        XCTAssertEqual(other.primer.count, 1, "a PNG under another name is compared by digest: \(other.primer)")
        XCTAssertTrue(other.primer.first?.hasPrefix("differs: plot.bin") == true, "\(other.primer)")
    }
}
