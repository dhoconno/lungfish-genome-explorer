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
        // The last count of a progress bar is compared as written, so another final count still differs.
        let count = try compare(
            "logs/stdout.txt", log("[13:11:20]", blank, amplicons: 3, pairs: 781, rate: "4305.26"),
            log("[13:11:20]", blank, amplicons: 3, pairs: 780, rate: "4305.26")
        )
        XCTAssertEqual(count.primer.count, 1, "\(count.primer)")
        XCTAssertTrue(count.primer.first?.hasPrefix("differs: logs/stdout.txt") == true, "\(count.primer)")
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

    // MARK: - The Olivar and varVAMP bundles (lane 12.16 c4, the manager's grant of items (i) to (iii))

    /// The policy finds `textA` and `masked` the same where the standard policy does not.
    private func assertHidden(
        _ relative: String, _ textA: String, _ masked: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let hidden = try compare(relative, textA, masked)
        XCTAssertEqual(hidden.primer, [], "the policy hides it", file: file, line: line)
        XCTAssertFalse(hidden.standard.isEmpty, "the standard policy sees it, so the mask hides it", file: file, line: line)
    }

    /// The policy still reports `relative` when its text changes from `textA` to `changed`.
    private func assertStillDiffers(
        _ relative: String, _ textA: String, _ changed: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let control = try compare(relative, textA, changed)
        XCTAssertFalse(control.primer.isEmpty, "the policy still reports it", file: file, line: line)
        XCTAssertTrue(
            control.primer.allSatisfy { $0.hasPrefix("differs: \(relative)") }, "\(control.primer)", file: file, line: line
        )
    }

    func testTheAdapterStageIDIsHiddenAndAnotherFolderOrOptionStillDiffers() throws {
        func result(_ stage: String, folder: String = "design", size: Int = 400) -> String {
            #"{"amplicon_size":\#(size),"out_path":"/x/Analyses/.adapter-output.adapter-stage-\#(stage)/native/\#(folder)/a"}"#
        }
        let relative = "native/design/result.json"
        try assertHidden(relative, result("u8xqtmh5"), result("c8z9n59z"))
        try assertStillDiffers(relative, result("u8xqtmh5"), result("u8xqtmh5", size: 420))
        try assertStillDiffers(relative, result("u8xqtmh5"), result("c8z9n59z", folder: "references"))
        // The adapter's own record is a provenance envelope by its name and takes the mask too.
        func record(_ stage: String, seed: Int) -> String {
            #"{"command":{"environment":{"TMPDIR":"/x/.adapter-output.adapter-stage-\#(stage)/cache/tmp"}},"seed":\#(seed)}"#
        }
        let envelope = "native/adapter-output/provenance-v1.json"
        try assertHidden(envelope, record("u8xqtmh5", seed: 10), record("led0tqhm", seed: 10))
        try assertStillDiffers(envelope, record("u8xqtmh5", seed: 10), record("u8xqtmh5", seed: 11))
    }

    func testTheEngineTimingsAreHiddenAndALoggedCountOrVersionStillDiffers() throws {
        func log(_ times: [String], amplicons: Int = 5, version: String = "1.3.2") -> String {
            "<T> | INFO     | Finished in \(times[0])\n<T> | INFO     | Finished in \(times[1])\n"
                + "<T> | INFO     | Primer dimer optimization finished in \(times[2])\n"
                + "96.53 % total coverage with \(amplicons) amplicons\nvarVAMP \(version) finished in \(times[3]) sec!\n"
        }
        let first = ["0:00:00.004186", "2.131s", "10.748s", "1.193925"]
        let second = ["0:00:00.003630", "1.872s", "10.504s", "1.196661"]
        let relative = "native/adapter-output/logs/native-stdout.txt"
        try assertHidden(relative, log(first), log(second))
        try assertStillDiffers(relative, log(first), log(first, amplicons: 6))
        try assertStillDiffers(relative, log(first), log(second, version: "1.3.3"))
        // A time on any other line is compared as written.
        try assertStillDiffers(relative, log(first) + "<T> | INFO     | Loss 2.131s\n", log(first) + "<T> | INFO     | Loss 1.872s\n")
    }

    func testTheVarVAMPGoodbyeIsHiddenInItsPlaceAndAnyOtherLastLineStillDiffers() throws {
        func log(_ goodbye: String, seconds: String = "1.193925") -> String {
            "Job:\t\t Finalizing output.\n\nvarVAMP 1.3.2 finished in \(seconds) sec!\n2026-10-18 14:59:14.718691\n\n\(goodbye)\n"
        }
        let relative = "native/adapter-output/logs/native-stdout.txt"
        try assertHidden(relative, log(">Placeholder for your advertisement<"), log("Just try it. PCR is magic!", seconds: "1.196661"))
        try assertHidden(
            relative, log("Miau?"), log("Why was the negative-sense virus angry at the positive-sense virus?\nBecause he was left stranded!")
        )
        // A line that is no goodbye of varVAMP 1.3.2 is compared as written in that place, and a goodbye anywhere else.
        try assertStillDiffers(relative, log("Miau?"), log("Miau!"))
        try assertStillDiffers(relative, log("Miau?"), log("varVAMP_0_LEFT\t21\t39\tGCACGGGCTGTCGAATTAC"))
        try assertStillDiffers(relative, "varVAMP 1.3.2 started\nMiau?\n", "varVAMP 1.3.2 started\n42\n")
    }

    func testTheAdapterLogDigestIsHiddenAndAnotherOutputDigestOrALogPathStillDiffers() throws {
        func record(log: Character, size: Int, config: Character = "c", path: String = "logs/native-stdout.txt") -> String {
            #"{"outputs":[{"byteSize":\#(size),"kind":"log","path":"\#(path)","sha256":"\#(Self.hex(log))"},"#
                + #"{"byteSize":461,"kind":"configuration","path":"config/a/varvamp-config.py","sha256":"\#(Self.hex(config))"}]}"#
        }
        let relative = "native/adapter-output/provenance-v1.json"
        try assertHidden(relative, record(log: "a", size: 1863), record(log: "b", size: 1853))
        try assertStillDiffers(relative, record(log: "a", size: 1863), record(log: "a", size: 1863, config: "d"))
        try assertStillDiffers(relative, record(log: "a", size: 1863), record(log: "a", size: 1863, path: "logs/native-stderr.txt"))
    }

    func testTheSizeBesideAContentComparedDigestIsHiddenAndASizeBesideAnyOtherDigestStillDiffers() throws {
        func tree(snapshot: Int, other: Int, otherDigest: Character = "c") -> [String: String] {
            let record = #"{"outputs":[{"byteSize":\#(snapshot),"kind":"requestSnapshot","path":"replay/request-v1.json","#
                + #""sha256":"\#(Self.hex(snapshot == 2021 ? "a" : "b"))"},{"byteSize":\#(other),"kind":"configuration","#
                + #""path":"config/elsewhere.py","sha256":"\#(Self.hex(otherDigest))"}]}"#
            return ["native/adapter-output/provenance-v1.json": record, "native/adapter-output/replay/request-v1.json": #"{"a":1}"#]
        }
        // The snapshot is in both trees and compared on its own, so the standard mask hides its digest and this mask
        // its size. The standard policy still sees the size.
        let hidden = try compareTrees(tree(snapshot: 2021, other: 461), tree(snapshot: 2023, other: 461))
        XCTAssertEqual(hidden.primer, [], "the policy hides it")
        XCTAssertFalse(hidden.standard.isEmpty, "the standard policy sees it, so the mask hides it")
        XCTAssertTrue(hidden.standard.allSatisfy { $0.contains("byteSize") }, "\(hidden.standard)")
        // A file only the record names keeps its digest, so its size is compared as written.
        let other = try compareTrees(tree(snapshot: 2021, other: 461), tree(snapshot: 2021, other: 462))
        XCTAssertEqual(other.primer.count, 1, "\(other.primer)")
        XCTAssertTrue(other.primer.first?.contains(#""byteSize" : 462"#) == true, "\(other.primer)")
    }

    // MARK: - A PDF (comparesPDFByPresence, item (iii) of the manager's grant to lane 12.16 c4)

    /// `%PDF-1.4`, the binary comment line matplotlib writes after it, and `count` bytes of `fill`. The comment's bytes
    /// are no UTF-8, so the standard compare reads the file as binary.
    private static func pdf(_ fill: UInt8, count: Int = 16) -> Data {
        Data(Array("%PDF-1.4\n%".utf8) + [0xAC, 0xDC, 0x20, 0xAB, 0xBA, 0x0A] + [UInt8](repeating: fill, count: count))
    }

    func testOnlyThePrimerAnalysisPolicyComparesAPDFByPresence() {
        XCTAssertTrue(OutputEquivalence.MaskPolicy.primerAnalysis.comparesPDFByPresence)
        XCTAssertFalse(OutputEquivalence.MaskPolicy.standard.comparesPDFByPresence)
        XCTAssertFalse(OutputEquivalence.MaskPolicy.gatk.comparesPDFByPresence)
    }

    func testAPDFsBytesAreHiddenAndAPDFOnOneSideOrUnderAnotherNameStillDiffers() throws {
        let plot = "native/run/amplicon_plot.pdf"
        let bytes = try compareData([plot: Self.pdf(1)], [plot: Self.pdf(2)])
        XCTAssertEqual(bytes.primer, [], "the policy compares the PDF by name and presence")
        XCTAssertEqual(bytes.standard.count, 1, "\(bytes.standard)")
        XCTAssertTrue(bytes.standard.first?.contains("binary sha256") == true, "the standard policy compares it by digest")
        let oneSided = try compareData([plot: Self.pdf(1)], ["native/run/amplicons.bed": Data("row\t0\t10\n".utf8)])
        XCTAssertTrue(oneSided.primer.contains("only in A: \(plot)"), "\(oneSided.primer)")
        let renamed = try compareData([plot: Self.pdf(1)], ["native/run/per_base_mismatches.pdf": Self.pdf(1)])
        XCTAssertTrue(renamed.primer.contains("only in A: \(plot)"), "\(renamed.primer)")
        XCTAssertTrue(renamed.primer.contains("only in B: native/run/per_base_mismatches.pdf"), "\(renamed.primer)")
    }

    func testAFileThatIsNoPDFKeepsItsCompareUnderThePolicy() throws {
        let fake = try compareData(["plot.pdf": Data([0xFF, 0xFE, 0x00, 0x01])], ["plot.pdf": Data([0xFF, 0xFE, 0x00, 0x02])])
        XCTAssertEqual(fake.primer.count, 1, "a .pdf without the signature is compared by digest: \(fake.primer)")
        XCTAssertTrue(fake.primer.first?.hasPrefix("differs: plot.pdf") == true, "\(fake.primer)")
        let other = try compareData(["plot.bin": Self.pdf(1)], ["plot.bin": Self.pdf(2)])
        XCTAssertEqual(other.primer.count, 1, "a PDF under another name is compared by digest: \(other.primer)")
        XCTAssertTrue(other.primer.first?.hasPrefix("differs: plot.bin") == true, "\(other.primer)")
    }
}
