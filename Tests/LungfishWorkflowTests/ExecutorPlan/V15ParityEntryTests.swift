// V15ParityEntryTests.swift - C4-4 D-2: the envelope's files and outputs matched by role and digest, never by index
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation

/// C4-4 D-2 (SWIFT SW4-4 and SW4-5, ARCH A-D2-1 to A-D2-3, BIO B-D2-1 and B-D2-2, QA Q4-4, UX U4-2). Each test plants a difference
/// in a small pair of `files` arrays and reads the findings and the reported lines. The strip is the harness's own, so a path
/// that differs by route (an input, a work file, a report copy) still pairs.
final class V15ParityEntryTests: XCTestCase {
    private let published = "@/Imports/C079876_S1.lungfishfastq/C079876_S1.fastq.gz"
    private let sidecar = "@/Imports/C079876_S1.lungfishfastq/C079876_S1.fastq.gz.lungfish-meta.json"
    private let artifacts = "@/Imports/C079876_S1.lungfishfastq/metadata/recipe-step-artifacts"
    private let scratch = "@/.tmp/fastq-import-1F2A0176-2D6D-419F-A6C5-7B3B358C6A1B"
    private let reportUUID = "E4179EEA-3EBC-4157-A740-94D976E7F09B"

    private func entry(_ role: String, _ path: String, _ digest: String, size: Int = 10, format: String = "fastq") -> [String: Any] {
        ["role": role, "path": path, "checksumSHA256": digest, "fileSize": size, "format": format]
    }

    /// The adopted route: two inputs, the payload and its sidecar, a work file, a fastp report and the input of a V15-S5 step.
    private var adopted: [[String: Any]] {
        [entry("input", "inputs/R1.fastq.gz", "aaaa"), entry("input", "inputs/R2.fastq.gz", "bbbb"),
         entry("output", published, "cccc", size: 30), entry("output", sidecar, "1111", size: 50_000, format: "json"),
         entry("output", "work/sample_fused_R1.fq.gz", "dddd"),
         entry("output", "\(artifacts)/1-1-trim-C079876_S1_fused_fastp_report.json", "2222", size: 130_929, format: "json"),
         entry("input", "work/sample_lengthfilter_merged.fq.gz", "eeee")]
    }

    /// The Mac route: the same entries with its own paths, sidecar and report bytes, and without the V15-S5 step's input.
    private var mac: [[String: Any]] {
        [entry("input", "<external>/C079876_S1_1M_R1.fastq.gz", "aaaa"), entry("input", "<external>/C079876_S1_1M_R2.fastq.gz", "bbbb"),
         entry("output", published, "cccc", size: 30), entry("output", sidecar, "3333", size: 72_021, format: "json"),
         entry("output", "\(scratch)/C079876_S1_fused_R1.fq.gz", "dddd"),
         entry("output", "\(artifacts)/1-1-trim-C079876_S1_fused_fastp_report_\(reportUUID).json", "4444", size: 131_678, format: "json")]
    }

    private var decompressorInput: V15AdoptOnlyInput {
        V15AdoptOnlyInput(step: "decompressor#1", entry: entry("input", "work/sample_lengthfilter_merged.fq.gz", "eeee"))
    }

    private func compare(
        _ adopted: [[String: Any]], _ mac: [[String: Any]], adoptOnly: [V15AdoptOnlyInput]? = nil, key: String = "files"
    ) -> V15Comparison {
        let mates = ["aaaa", "bbbb"]
        var comparison = V15Comparison(
            roots: [.adopted: ["/node"], .mac: [scratch]],
            payloadFileNames: ["C079876_S1.fastq.gz", "C079876_S1.fastq.gz.lungfish-meta.json"]
        )
        comparison.names = [
            .adopted: V15RouteNames(stem: "sample", workFolder: "work", inputs: V15RouteNames.mates(
                ["inputs/R1.fastq.gz": "aaaa", "inputs/R2.fastq.gz": "bbbb"], plan: mates)),
            .mac: V15RouteNames(stem: "C079876_S1", reportUUID: true, inputs: V15RouteNames.mates(
                ["<external>/C079876_S1_1M_R1.fastq.gz": "aaaa", "<external>/C079876_S1_1M_R2.fastq.gz": "bbbb"], plan: mates)),
        ]
        comparison.adoptOnlyInputs = adoptOnly ?? [decompressorInput]
        comparison.walk([key: adopted], [key: mac], path: ["envelope"])
        return comparison
    }

    private func text(_ findings: [V15Finding]) -> String { findings.map(\.description).joined(separator: "\n") }

    /// SW4-5: a reordered Mac array gives no finding, one changed digest gives exactly one finding that names the entry's path,
    /// and a field of a matched pair that differs (its format or size) is still a finding.
    func testRunFilesMatchByDigestAndRoleNotIndex() {
        XCTAssertEqual(text(compare(adopted, mac).findings), "")
        for key in ["files", "outputs"] {
            XCTAssertEqual(text(compare(adopted, Array(mac.reversed()), key: key).findings), "", "a reordered \(key) array")
        }
        var changed = mac
        changed[4]["checksumSHA256"] = "ffff"
        let planted = compare(adopted, changed).findings
        XCTAssertEqual(planted.count, 1, text(planted))
        XCTAssertTrue(text(planted).contains("fused_R1.fq.gz"), text(planted))
        var format = adopted
        format[4]["format"] = "json"
        XCTAssertEqual(compare(format, mac).findings.count, 1, "the format of a matched pair compares byte for byte")
        var size = adopted
        size[4]["fileSize"] = 11
        XCTAssertEqual(compare(size, mac).findings.count, 1, "the size of a matched pair compares")
    }

    /// SW4-5, ARCH A-D2-3, BIO B-D2-2: an adopted input that only a V15-S5 step names passes, with a reported line that names
    /// the step, and the same input with no V15-S5 step, or a step that names another digest, is one finding.
    func testRouteOnlyStepFilesListedAdoptOnly() {
        let listed = compare(adopted, mac)
        XCTAssertEqual(text(listed.findings), "")
        XCTAssertTrue(listed.reported.contains { $0.contains("V15-S5") && $0.contains("decompressor#1") && $0.contains("sample_lengthfilter_merged") },
                      listed.reported.description)
        let unlisted = compare(adopted, mac, adoptOnly: []).findings
        XCTAssertEqual(unlisted.count, 1, text(unlisted))
        XCTAssertTrue(text(unlisted).contains("sample_lengthfilter_merged"), text(unlisted))
        let other = V15AdoptOnlyInput(step: "decompressor#1", entry: entry("input", "work/sample_lengthfilter_merged.fq.gz", "9999"))
        XCTAssertEqual(compare(adopted, mac, adoptOnly: [other]).findings.count, 1, "the step must name the entry's digest")
    }

    /// UX U4-2, QA Q4-4: an entry that no entry of the other route matches and no V15-S5 step names fails with its path, role and
    /// digest, whether it is a new digest, an extra input or a Mac entry the adopted record lacks.
    func testParityFailsOnUnmatchedFileEntry() {
        let planted = compare(adopted + [entry("output", "work/sample_planted.fq.gz", "9999")], mac).findings
        XCTAssertEqual(planted.count, 1, text(planted))
        for part in ["work/sample_planted.fq.gz", "output", "9999"] {
            XCTAssertTrue(text(planted).contains(part), "\(part) in \(text(planted))")
        }
        XCTAssertEqual(compare(adopted + [entry("input", "work/sample_extra.fq.gz", "8888")], mac).findings.count, 1,
                       "an extra input that no V15-S5 step lists")
        var dropped = mac
        dropped.remove(at: 4)
        let missing = compare(adopted, dropped).findings
        XCTAssertEqual(missing.count, 1, "one Mac entry dropped: \(text(missing))")
        // The Mac's statistics step lists the payload as an input; an adopted record without it leaves that entry unmatched.
        let statistics = compare(adopted, mac + [entry("input", published, "cccc", size: 30)]).findings
        XCTAssertEqual(statistics.count, 1, text(statistics))
        XCTAssertTrue(statistics.first?.adopted == "absent", text(statistics))
    }

    /// ARCH A-D2-1: a digest listed twice on one route is matched twice, so a second adopted copy with no second Mac entry fails.
    func testDigestListedTwiceMatchesTwice() {
        let twice = adopted + [entry("output", "work/sample_fused_copy.fq.gz", "dddd")]
        XCTAssertEqual(compare(twice, mac).findings.count, 1, text(compare(twice, mac).findings))
        let both = mac + [entry("output", "\(scratch)/C079876_S1_fused_copy.fq.gz", "dddd")]
        XCTAssertEqual(text(compare(twice, both).findings), "")
    }

    /// XC-1 and D-4: the payload, its sidecar and the reports match by role and path, since their digests are never compared. A
    /// Mac without the sidecar fails, and a report copy named with the emitter's `sample` stem pairs with nothing (D-3 is the
    /// adopt's, row W1-1), so it gives one finding for each route.
    func testPayloadSidecarAndReportsMatchByRoleAndPath() {
        XCTAssertEqual(text(compare(adopted, mac).findings), "", "the sidecar's and the report's digests and sizes differ and pass")
        var noSidecar = mac
        noSidecar.remove(at: 3)
        XCTAssertEqual(compare(adopted, noSidecar).findings.count, 1)
        var oldStem = adopted
        oldStem[5]["path"] = "\(artifacts)/1-1-trim-sample_fused_fastp_report.json"
        XCTAssertEqual(compare(oldStem, mac).findings.count, 2, "the report copy named with the emitter's stem pairs with nothing")
    }

    /// QA Q4-13 and Q4-5 (XC-1, integrity inside one route): an entry of the envelope's `files`, its `outputs` or a step's
    /// `outputs` at one of the route's payload paths carries the digest of that route's own payload. `compareEntries` pairs a
    /// payload entry by role and path and never compares its digest, so this check alone fails an adopted payload entry that
    /// holds another digest. An entry outside the payload paths is not its business, and an envelope with no payload digest
    /// is one finding.
    func testPayloadIntegrityFailsOnADifferentDigest() {
        let payload = "out/sample.fastq.gz"
        func envelope(outputs: String = "cccc", step: String = "cccc", extra: [[String: Any]] = []) -> [String: Any] {
            [
                "output": ["path": payload, "checksumSHA256": "cccc"] as [String: Any],
                "files": [entry("output", payload, "cccc")] + extra,
                "outputs": [entry("output", payload, outputs)],
                "steps": [["toolName": "bgzip", "outputs": [entry("output", payload, step)]] as [String: Any]],
            ]
        }
        func findings(_ built: [String: Any], route: V15Route = .adopted) -> [V15Finding] {
            V15Comparison.payloadIntegrityFindings(envelope: built, route: route, paths: [payload])
        }
        XCTAssertEqual(text(findings(envelope())), "", "files, outputs and a step's outputs all hold the route's payload digest")

        let planted = findings(envelope(outputs: "9999"))
        XCTAssertEqual(planted.count, 1, text(planted))
        XCTAssertEqual(planted.first?.key, "envelope.outputs")
        XCTAssertEqual(planted.first?.adopted, "9999")
        XCTAssertEqual(planted.first?.mac, "-")
        XCTAssertEqual(
            planted.first?.why,
            "QA Q4-13: the adopted route's entry at its payload path \(payload) holds 9999, and the route's payload is cccc"
        )
        let inStep = findings(envelope(step: "8888"))
        XCTAssertEqual(inStep.map(\.key), ["envelope.steps[bgzip].outputs"], text(inStep))
        let onMac = findings(envelope(outputs: "9999"), route: .mac)
        XCTAssertEqual(onMac.map(\.mac), ["9999"], "the Mac route's finding carries its value on the Mac side")
        XCTAssertEqual(onMac.map(\.adopted), ["-"])

        let outside = findings(envelope(extra: [entry("output", "work/sample_other.fq.gz", "7777")]))
        XCTAssertEqual(text(outside), "", "an entry at a path outside the payload paths is not this check's")

        var undigested = envelope()
        undigested["output"] = ["path": payload] as [String: Any]
        let missing = findings(undigested)
        XCTAssertEqual(missing.map(\.key), ["envelope.output.checksumSHA256"], text(missing))
        XCTAssertEqual(missing.first?.why, "the adopted envelope names no payload digest (QA Q4-13)")
    }

    private let mixed = "work/sample_mixed.fastq"

    /// The adopted record's three node-only decompressor steps (C4-3 C-3) as the harness reads them: the last one lists `outputs`.
    private func decompressorExcusers(outputs: [[String: Any]]) -> [V15AdoptOnlyInput] {
        let none = [[String: Any]]()
        let steps: [[String: Any]] = [
            ["id": "p1", "toolName": "pigz", "inputs": [entry("input", "work/sample_lengthfilter_merged.fq.gz", "eeee")], "outputs": none],
            ["id": "p2", "toolName": "pigz", "inputs": [entry("input", "work/sample_lengthfilter_unmerged_R1.fq.gz", "e1e1")], "outputs": none],
            ["id": "p3", "toolName": "pigz", "inputs": [entry("input", "work/sample_lengthfilter_unmerged_R2.fq.gz", "e2e2")], "outputs": outputs],
            ["id": "run", "toolName": "lungfish-executor"],
            ["id": "adopt", "toolName": "lungfish import fastq"],
        ]
        let roles = V15StepRoles.adopted(
            steps, executorToolName: "lungfish-executor", adoptToolName: "lungfish import fastq",
            nodeKinds: [V15Roles.decompressor, V15Roles.decompressor, V15Roles.decompressor])
        return V15AdoptOnlyInput.inputs(of: roles)
    }

    /// C4-5 E-1 option 1 (QA-W-lines P2, BIO B-E1-1 to B-E1-3): the adopt-only entries are the inputs and the outputs of the steps
    /// V15-S5 names. The interleave's mixed file is the last decompressor step's output and no Mac entry has it, so it passes only
    /// when that step lists it with the same role, digest and path, once for each list, and it is reported with the step's name.
    func testAdoptOnlyDecompressorOutputListedByItsStep() {
        let listing = decompressorExcusers(outputs: [entry("output", mixed, "aaaa")])
        for key in ["files", "outputs"] {
            let listed = compare(adopted + [entry("output", mixed, "aaaa")], mac, adoptOnly: listing, key: key)
            XCTAssertEqual(text(listed.findings), "", "the mixed file in \(key)")
            let lines = listed.reported.filter { $0.contains("sample_mixed") }
            XCTAssertEqual(lines.count, 1, listed.reported.description)
            for part in ["PARITY-REPORTED line=V15-S5", "step=decompressor#3", "work/sample_mixed.fastq", "output", "aaaa"] {
                XCTAssertTrue(lines.first?.contains(part) == true, "\(part) in \(lines)")
            }
        }
        // Each of these is exactly one finding.
        let wrongDigest = compare(adopted + [entry("output", mixed, "bbbb")], mac, adoptOnly: listing).findings
        XCTAssertEqual(wrongDigest.count, 1, "the step lists aaaa, the entry holds bbbb: \(text(wrongDigest))")
        let unlisted = compare(adopted + [entry("output", mixed, "aaaa")], mac, adoptOnly: decompressorExcusers(outputs: [])).findings
        XCTAssertEqual(unlisted.count, 1, "no step lists the entry: \(text(unlisted))")
        XCTAssertTrue(text(unlisted).contains("sample_mixed"), text(unlisted))
        let macOnly = compare(adopted, mac + [entry("output", "\(scratch)/C079876_S1_mixed.fastq", "aaaa")], adoptOnly: listing).findings
        XCTAssertEqual(macOnly.count, 1, "an output step excuses an adopted entry and never a Mac-only one: \(text(macOnly))")
        XCTAssertEqual(macOnly.first?.adopted, "absent", text(macOnly))
        // BIO B-E1-2: the path must be the one the step lists, and one step output excuses one entry for each list.
        let otherPath = compare(adopted + [entry("output", "work/other_mixed.fastq", "aaaa")], mac, adoptOnly: listing).findings
        XCTAssertEqual(otherPath.count, 1, "the digest alone does not excuse an output: \(text(otherPath))")
        XCTAssertTrue(text(otherPath).contains("other_mixed"), text(otherPath))
        let twice = compare(adopted + [entry("output", mixed, "aaaa"), entry("output", mixed, "aaaa")], mac, adoptOnly: listing)
        XCTAssertEqual(twice.findings.count, 1, "a second entry of the same path and digest: \(text(twice.findings))")
        XCTAssertEqual(twice.reported.filter { $0.contains("sample_mixed") }.count, 1, twice.reported.description)
        // B-E1-1 names the same SHA-256: an output with no digest on either side proves nothing.
        var undigested = entry("output", mixed, "aaaa")
        undigested["checksumSHA256"] = nil
        let noDigest = compare(adopted + [undigested], mac, adoptOnly: decompressorExcusers(outputs: [undigested])).findings
        XCTAssertEqual(noDigest.count, 1, "no digest on the step's output or the entry: \(text(noDigest))")
    }
}
