// RNASeqQuantParityMasks.swift - The masks of the quantify row's parity case, and what they hide (RS-DIALOG-M1 C2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.4, lane RS-DIALOG. The result of `rnaseq quant` is a bundle, so the parity case in
// RNASeqQuantDialogConformanceTests compares the whole tree of each side root as a `.bundle` through `OutputEquivalence`, with the
// standard policy and the four masks below, the way the parity cases of `import rnaseq` do with theirs (FastqIngestCancelReplayTests,
// RS-GLUE C1). Each mask hides one kind of value that the Masks row of docs/contracts/CLI-EQUIVALENCE.md names, which is a wall-clock
// time, an identifier derived from a UUID, or the checksum and size that a manifest states for a file that is compared on its own, in
// one file of this family. The contract gets no row and `MaskPolicy.standard` does not change. Any other difference stays a difference.
// The tests at the end hold what each mask hides and what it leaves as written.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO

/// JSON in and out of a mask. Text that is no JSON object comes back as written, so a mask never hides what it cannot read.
private enum QuantMaskJSON {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func encoded(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isDateTime(_ text: String) -> Bool {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) != nil || fractional.date(from: text) != nil
    }
}

extension OutputEquivalence.Masks {
    /// The second `rnaseq quant` wrote its record, set to `<TIMESTAMP>` in the top-level `createdAt` of a `rnaseq-result.json` whose
    /// `kind` is `rnaseq-result`, and only when the value is an ISO 8601 date-time. The three sides run the command at three seconds. It
    /// is a wall-clock time, which the Masks row already masks, and RS-GLUE C1 masks the same key for `import rnaseq`.
    static let quantResultCreatedAt = OutputEquivalence.Mask(name: "quantResultCreatedAt") { text, context in
        guard context.recordName == RNASeqResultManifest.filename,
              var record = QuantMaskJSON.object(text),
              record["kind"] as? String == RNASeqResultManifest.kindName,
              let stamp = record["createdAt"] as? String, QuantMaskJSON.isDateTime(stamp)
        else { return text }
        record["createdAt"] = "<TIMESTAMP>"
        return QuantMaskJSON.encoded(record) ?? text
    }

    /// In a `rnaseq-result.json` of kind `rnaseq-result`, the `sha256` and `size` of each `sourceFiles` entry whose path names a file
    /// that both trees hold and that the comparison reads by content (`context.contentComparedPaths`, a `.json` file among them), set
    /// to `<CONTENT-SHA256>` and `<SIZE>`. That is the Masks row's rule for the checksum and size a manifest states for such a file,
    /// which `Masks.contentComparedDigests` applies to a record whose name holds `manifest` and reads no `size` key. The file itself is
    /// still compared on its own, so only the record's copy of its digest is hidden. A file compared by its bytes, such as `quant.sf`,
    /// keeps both values.
    static let quantResultSourceDigests = OutputEquivalence.Mask(name: "quantResultSourceDigests") { text, context in
        guard context.recordName == RNASeqResultManifest.filename,
              var record = QuantMaskJSON.object(text),
              record["kind"] as? String == RNASeqResultManifest.kindName,
              var files = record["sourceFiles"] as? [[String: Any]]
        else { return text }
        let folder = context.recordFolder.isEmpty ? "" : context.recordFolder + "/"
        var changed = false
        for index in files.indices {
            guard let path = files[index]["path"] as? String, context.contentComparedPaths.contains(folder + path) else { continue }
            for (key, token) in [("sha256", "<CONTENT-SHA256>"), ("size", "<SIZE>")] where files[index][key] != nil {
                files[index][key] = token
                changed = true
            }
        }
        guard changed else { return text }
        record["sourceFiles"] = files
        return QuantMaskJSON.encoded(record) ?? text
    }

    /// The three clock keys of salmon's `aux_info/meta_info.json`, `start_time`, `end_time` and `total_time_seconds`, set to `<TIME>`
    /// where each is present. They are the wall-clock times and the wall time of the run. Every other key, such as the counts of
    /// fragments, and every other file are compared as written.
    static let salmonRunClock = OutputEquivalence.Mask(name: "salmonRunClock") { text, context in
        guard context.recordName == "meta_info.json", context.recordFolder.hasSuffix("/aux_info"),
              var meta = QuantMaskJSON.object(text)
        else { return text }
        var changed = false
        for key in ["start_time", "end_time", "total_time_seconds"] where meta[key] != nil {
            meta[key] = "<TIME>"
            changed = true
        }
        guard changed else { return text }
        return QuantMaskJSON.encoded(meta) ?? text
    }

    /// The UUID of the run's stage folder, `.tmp/rnaseq-quant-<UUID>`, set to `<UUID>` in salmon's `cmd_info.json` and
    /// `lib_format_counts.json` under `source/`, which record the command line and the read files salmon ran on. It is an identifier
    /// derived from a UUID, which the Masks row already masks. A UUID that does not follow `rnaseq-quant-` and every other file stay.
    static let quantStageFolder = OutputEquivalence.Mask(name: "quantStageFolder") { text, context in
        guard ["cmd_info.json", "lib_format_counts.json"].contains(context.recordName), context.recordFolder.contains("/source/")
        else { return text }
        let stage = try! NSRegularExpression(
            pattern: "(rnaseq-quant-)[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )
        return stage.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1<UUID>")
    }
}

extension OutputEquivalence.MaskPolicy {
    /// The standard masks and the four masks above in payload text, which only the parity case of `rnaseq quant` asks for. A declared
    /// difference is never the answer to a clock.
    static var rnaSeqQuant: OutputEquivalence.MaskPolicy {
        var policy = OutputEquivalence.MaskPolicy.standard
        policy.payloads.append(contentsOf: [
            OutputEquivalence.Masks.quantResultCreatedAt, OutputEquivalence.Masks.quantResultSourceDigests,
            OutputEquivalence.Masks.salmonRunClock, OutputEquivalence.Masks.quantStageFolder,
        ])
        return policy
    }
}

// MARK: - What the masks hide

final class RNASeqQuantParityMaskTests: XCTestCase {
    private func context(_ name: String, folder: String = "", compared: Set<String> = []) -> OutputEquivalence.MaskContext {
        OutputEquivalence.MaskContext(
            rootA: URL(fileURLWithPath: "/a", isDirectory: true), rootB: URL(fileURLWithPath: "/b", isDirectory: true),
            contentComparedPaths: compared, recordFolder: folder, recordName: name)
    }

    private func result(
        createdAt: String = "2026-11-18T19:00:00Z", name: String = "pair", kind: String = RNASeqResultManifest.kindName,
        files: String = "[]"
    ) -> String {
        "{\"schemaVersion\":1,\"kind\":\"\(kind)\",\"name\":\"\(name)\",\"createdAt\":\"\(createdAt)\",\"sourceFiles\":\(files)}"
    }

    func testTheCreatedAtMaskHidesTheClockOfTheResultRecordAndNothingElse() {
        let mask = OutputEquivalence.Masks.quantResultCreatedAt
        let named = context(RNASeqResultManifest.filename)
        let first = mask(result(), context: named)
        XCTAssertEqual(first, mask(result(createdAt: "2026-11-18T19:00:01Z"), context: named), "two seconds of one run read the same")
        XCTAssertTrue(first.contains("<TIMESTAMP>"), first)
        XCTAssertNotEqual(first, mask(result(name: "another"), context: named), "every other value is compared as written")
        for text in [result(createdAt: "yesterday"), result(createdAt: ""), result(kind: "other-result"), "not json"] {
            XCTAssertEqual(mask(text, context: named), text, "no date-time, another kind of record or no JSON")
        }
        XCTAssertEqual(mask(result(), context: context("rnaseq-result.json.bak")), result(), "another file")
    }

    func testTheSourceDigestMaskHidesTheDigestAndSizeOfAFileComparedOnItsOwnAndNoOther() {
        let mask = OutputEquivalence.Masks.quantResultSourceDigests
        let folder = "P.lungfish/Analyses/r.lungfishrnaseq"
        let named = context(RNASeqResultManifest.filename, folder: folder, compared: [folder + "/source/A_1/cmd_info.json"])
        func files(_ digest: String, _ size: Int, quant: String = "q") -> String {
            "[{\"path\":\"source/A_1/quant.sf\",\"sha256\":\"\(quant)\",\"size\":9},"
                + "{\"path\":\"source/A_1/cmd_info.json\",\"sha256\":\"\(digest)\",\"size\":\(size)}]"
        }
        let first = mask(result(files: files("aa", 10)), context: named)
        XCTAssertEqual(first, mask(result(files: files("bb", 11)), context: named), "the digest and size of cmd_info.json read the same")
        XCTAssertTrue(first.contains("<CONTENT-SHA256>") && first.contains("<SIZE>"), first)
        XCTAssertNotEqual(first, mask(result(files: files("aa", 10, quant: "r")), context: named), "quant.sf keeps its digest")
        let alone = context(RNASeqResultManifest.filename, folder: folder)
        XCTAssertEqual(mask(result(files: files("aa", 10)), context: alone), result(files: files("aa", 10)), "a file one tree lacks keeps both")
        XCTAssertEqual(mask(result(files: files("aa", 10)), context: context("other.json", folder: folder)), result(files: files("aa", 10)))
    }

    func testTheSalmonClockMaskHidesTheThreeClockKeysOfMetaInfoOnly() {
        let mask = OutputEquivalence.Masks.salmonRunClock
        let meta = context("meta_info.json", folder: "P/r/source/A_1/aux_info")
        func text(_ start: String, mapped: Int = 900) -> String {
            "{\"num_mapped\":\(mapped),\"start_time\":\"\(start)\",\"end_time\":\"\(start)\",\"total_time_seconds\":1.5}"
        }
        XCTAssertEqual(mask(text("Wed Nov 18 19:00:00 2026"), context: meta), mask(text("Wed Nov 18 19:00:09 2026"), context: meta))
        XCTAssertNotEqual(mask(text("a"), context: meta), mask(text("a", mapped: 901), context: meta), "a count is compared as written")
        XCTAssertEqual(mask(text("a"), context: context("meta_info.json", folder: "P/r/source/A_1")), text("a"), "another folder")
        XCTAssertEqual(mask(text("a"), context: context("cmd_info.json", folder: "P/r/source/A_1/aux_info")), text("a"), "another file")
    }

    func testTheStageFolderMaskHidesTheUUIDOfTheStageFolderOnly() {
        let mask = OutputEquivalence.Masks.quantStageFolder
        let info = context("cmd_info.json", folder: "P/r/source/A_1")
        func text(_ stage: String, other: String = "11111111-2222-3333-4444-555555555555") -> String {
            "{\"output\":\"<ROOT>/P.lungfish/.tmp/rnaseq-quant-\(stage)/A_1\",\"id\":\"\(other)\"}"
        }
        let one = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", two = "00000000-1111-2222-3333-444444444444"
        XCTAssertEqual(mask(text(one), context: info), mask(text(two), context: info), "two stage folders read the same")
        XCTAssertNotEqual(
            mask(text(one), context: info), mask(text(one, other: "99999999-2222-3333-4444-555555555555"), context: info),
            "a UUID that names no stage folder is compared as written")
        XCTAssertEqual(mask(text(one), context: context("quant.sf", folder: "P/r/source/A_1")), text(one), "another file")
    }

    func testThePolicyIsTheStandardPolicyWithFourPayloadMasksAndNothingElse() {
        let standard = OutputEquivalence.MaskPolicy.standard
        let policy = OutputEquivalence.MaskPolicy.rnaSeqQuant
        XCTAssertEqual(
            policy.payloads.map(\.name),
            standard.payloads.map(\.name) + ["quantResultCreatedAt", "quantResultSourceDigests", "salmonRunClock", "quantStageFolder"])
        XCTAssertEqual(policy.provenance.map(\.name), standard.provenance.map(\.name))
        XCTAssertEqual(policy.records.map(\.name), standard.records.map(\.name))
        XCTAssertEqual(policy.names.map(\.name), standard.names.map(\.name))
    }
}
