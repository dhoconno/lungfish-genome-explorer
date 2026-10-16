// TaxTriageParityLiveConformanceTests+Evidence.swift - The evidence folder of a live TaxTriage parity pass
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32, decision B8. A live pass writes into `<LUNGFISH_PARITY_EVIDENCE>/<case>/`:
//
// - `records/<side>/<path>`, the raw bytes of every provenance record and source manifest below each side root,
// - `payload-hashes.tsv`, each sample's payload files by side, sample, kind, key, the SHA-256 a compare reads (the
//   canonical digest of a BAM and its index on the real engine, +Payloads.swift), size, path and the file's own
//   SHA-256,
// - `payloads/<side>/<sample>/<key>`, a copy of each payload file of the asserted kinds up to 64 MB,
// - `odr/<side>/all.odr.json`, a copy of each side's combined report,
// - `payload-compare.txt`, every payload difference of every pair, the recorded kinds included,
// - `all-odr-json.txt`, the keys in which `all.odr.json` differs, folded and in full (BIO R3),
// - `found.txt`, every fixed fact a side does not hold and every folder and record difference of every pair,
// - `findings.txt`, what failed the test, and `run.txt`, the engine, the variables, the cores, the load and each
//   side's end and command.
//
// A later pass reads `payload-hashes.tsv` back as its baseline and compares hashes only, so no record is read
// again through `PortablePath` (B8). This folder is the one write outside TestTempDirectory (QA 6).

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

enum TaxTriageParityEvidence {
    static let folderVariable = "LUNGFISH_PARITY_EVIDENCE"
    static let baselineVariable = "LUNGFISH_PARITY_BASELINE"
    static let payloadFileName = "payload-hashes.tsv"
    /// The largest payload file the evidence keeps a copy of. Its hash is kept whatever its size.
    static let largestCopiedPayload: Int64 = 64 * 1024 * 1024

    // MARK: - The folders

    /// The evidence folder a live pass writes into. Without it a live run would leave nothing for M3, so the test
    /// skips, or fails under LUNGFISH_REQUIRE_TOOLS=1.
    static func requireFolder(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        guard let path = value(of: folderVariable, in: environment) else {
            try ToolAvailability.skipOrFail(
                "Set \(folderVariable) to the folder that keeps a live parity run's records and hashes (B8).", file: file, line: line
            )
        }
        guard path.hasPrefix("/") else {
            throw LiveNextflowError.misconfigured("\(folderVariable) must be an absolute path, not \"\(path)\".")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The evidence folder of an earlier pass whose hashes this pass must equal, or nil when none is named.
    static func baselineFolder(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        guard let path = value(of: baselineVariable, in: environment) else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: folder.path) else {
            throw LiveNextflowError.misconfigured("\(baselineVariable) must name the evidence folder of an earlier pass, not \"\(path)\".")
        }
        return folder
    }

    /// Run first in a live test, before any side runs. A live pass takes up to 45 minutes and writes last, so a case
    /// folder that exists, an evidence folder that cannot be written and a baseline without this case's hashes must fail
    /// in seconds.
    static func prepare(_ parityCase: TaxTriageParityCase, in evidence: URL, baseline: URL?) throws {
        let folder = evidence.appendingPathComponent(parityCase.rawValue, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw LiveNextflowError.misconfigured("\(folder.path) holds the evidence of another run. Name a fresh \(folderVariable).")
        }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let probe = evidence.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        try Data().write(to: probe)
        try FileManager.default.removeItem(at: probe)
        if let baseline { _ = try payloadRows(in: baseline.appendingPathComponent(parityCase.rawValue, isDirectory: true)) }
    }

    private static func value(of key: String, in environment: [String: String]) -> String? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - Comparisons

    /// One payload comparison of a pass, two of its sides or a side of the baseline against one of its own.
    struct Comparison {
        let title: String
        let scope: TaxTriageParityScope
        let differences: [TaxTriageParityDifference]
    }

    /// A against C and C against C' both ways, then with a baseline the baseline's A against this pass's A and C, and
    /// the baseline's C and C' against this pass's C and C'. The baseline's A against C carries A against C's
    /// declarations, and every other pair declares nothing.
    static func comparisons(_ pass: TaxTriageParityLivePass, baseline: URL?) throws -> [Comparison] {
        var result = TaxTriageParityLivePass.pairs.map { reference, candidate in
            Comparison(
                title: "\(reference) against \(candidate)",
                scope: .pair(reference, candidate),
                differences: TaxTriageParityPayloads.differences(
                    reference: pass.payloads[reference] ?? [], reference, candidate: pass.payloads[candidate] ?? [], candidate
                )
            )
        }
        guard let baseline else { return result }
        let rows = try payloadRows(
            in: baseline.appendingPathComponent(pass.parityCase.rawValue, isDirectory: true), samtools: pass.samtools
        )
        for (saved, side) in [(TaxTriageParitySide.a, TaxTriageParitySide.a), (.a, .c), (.c, .c), (.cPrime, .cPrime)] {
            result.append(Comparison(
                title: "baseline \(saved) against \(side)",
                scope: .pair(saved, side),
                differences: TaxTriageParityPayloads.differences(
                    reference: rows.filter { $0.side == saved.rawValue }.map(\.payload), saved,
                    candidate: pass.payloads[side] ?? [], side
                )
            ))
        }
        return result
    }

    // MARK: - Writing

    /// Writes the pass's evidence into a new `<case>` folder of `evidence` and returns it. A folder that exists holds
    /// another run's evidence and is never written again.
    @discardableResult
    static func write(
        _ pass: TaxTriageParityLivePass,
        to evidence: URL,
        findings: [String: [String]],
        comparisons: [Comparison] = [],
        notes: [String]
    ) throws -> URL {
        let folder = evidence.appendingPathComponent(pass.parityCase.rawValue, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw LiveNextflowError.misconfigured("\(folder.path) holds the evidence of another run. Name a fresh \(folderVariable).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for run in pass.runs {
            let side = run.side.folderName
            let manifests = pass.parityCase.bundlePaths.map { "\(ClassifierParityFixtures.projectName)/\($0)/\(AnalysisManifest.filename)" }
            for relative in Set(TaxTriageParityComparison.Rules.recordPaths(under: run.root) + manifests).sorted() {
                try copy(run.root.appendingPathComponent(relative), to: folder.appendingPathComponent("records/\(side)/\(relative)"))
            }
            if let odr = TaxTriageParityODRJSON.file(of: run) {
                try copy(odr, to: folder.appendingPathComponent("odr/\(side)/\(TaxTriageParityODRJSON.fileName)"))
            }
            for payload in pass.payloads[run.side] ?? [] where payload.kind.isAsserted && payload.size <= largestCopiedPayload {
                try copy(run.root.appendingPathComponent(payload.path), to: folder.appendingPathComponent("payloads/\(side)/\(payload.sample)/\(payload.key)"))
            }
        }
        // Field 4 is the digest a compare reads and the last field the file's own SHA-256 (Q32 X1 ruling F2).
        let header = "side\tsample\tkind\tkey\tsha256\tsize\tpath\traw sha256"
        let rows = TaxTriageParityLivePass.sides.flatMap { side in
            (pass.payloads[side] ?? []).map {
                [side.rawValue, $0.sample, $0.kind.rawValue, $0.key, $0.sha256, String($0.size), $0.path, $0.rawSHA256].joined(separator: "\t")
            }
        }
        try text([header] + rows, to: folder.appendingPathComponent(payloadFileName))
        try text(comparisons.flatMap { ["\($0.title): \($0.differences.count)"] + $0.differences.map { "  \($0)" } }, to: folder.appendingPathComponent("payload-compare.txt"))
        try text(TaxTriageParityODRJSON.report(pass), to: folder.appendingPathComponent("all-odr-json.txt"))
        try text(
            pass.found.sorted { $0.key.description < $1.key.description }.flatMap { ["\($0.key): \($0.value.count)"] + $0.value.map { "  \($0)" } },
            to: folder.appendingPathComponent("found.txt")
        )
        try text(
            findings.sorted { $0.key < $1.key }.flatMap { ["\($0.key): \($0.value.isEmpty ? "none" : "\($0.value.count)")"] + $0.value.map { "  \($0)" } },
            to: folder.appendingPathComponent("findings.txt")
        )
        try text(runLines(pass, notes: notes), to: folder.appendingPathComponent("run.txt"))
        return folder
    }

    /// The engine, the variables, the cores and the load, then each side's end, folder and commands.
    static func runLines(_ pass: TaxTriageParityLivePass, notes: [String]) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let variables = [
            folderVariable, baselineVariable, LiveNextflowSwitch.liveRootVariable, LiveNextflowSwitch.storageRootVariable,
            LiveNextflowSwitch.requireToolsVariable, LiveNextflowSwitch.archiveFolderVariable, "LUNGFISH_CLI_PATH",
        ]
        var lines = ["case \(pass.parityCase.rawValue), written \(ISO8601DateFormatter().string(from: Date()))"] + notes
        lines.append(machineLine())
        lines += variables.map { "\($0)=\(environment[$0] ?? "")" }
        for run in pass.runs {
            lines.append("side \(run.side): \(run.terminal), analysis \(run.analysisPath ?? "none")")
            if let command = run.recordedCommand { lines.append("  recorded command: \(command)") }
            lines += run.replayedCommands.map { "  ran: \($0.argv.joined(separator: " "))" }
            if let row = run.row { lines.append("  row: \(row.title) | \(row.stateLabel) | \(row.completionDetail)") }
        }
        return lines
    }

    /// The lines the test log shows: each side's payloads and each pair's counts.
    static func summary(_ pass: TaxTriageParityLivePass) -> [String] {
        var lines = TaxTriageParityLivePass.sides.flatMap { side in
            (pass.payloads[side] ?? []).map { "\(side) \($0.sample) \($0.kind.rawValue) \($0.key) \($0.sha256.prefix(16)) \($0.size)" }
        }
        for (reference, candidate) in TaxTriageParityLivePass.pairs {
            lines.append("\(reference) against \(candidate): \(pass.found[.pair(reference, candidate)]?.count ?? 0) folder and record differences")
        }
        return lines + TaxTriageParityODRJSON.report(pass).prefix(40)
    }

    /// The cores and the load average over 1, 5 and 15 minutes, which show a run with every core busy.
    static func machineLine() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let sampled = getloadavg(&loads, 3)
        let load = sampled == 3 ? loads.map { String(format: "%.2f", $0) }.joined(separator: " ") : "unread"
        return "cores \(ProcessInfo.processInfo.activeProcessorCount), load average \(load)"
    }

    static func copy(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func text(_ lines: [String], to file: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Reading

    /// One row of `payload-hashes.tsv`.
    struct Row {
        let side: String
        let payload: TaxTriageParityPayload
        var sample: String { payload.sample }
        var key: String { payload.key }
        var kind: TaxTriageParityPayloadKind { payload.kind }
    }

    /// The rows of the `payload-hashes.tsv` in `caseFolder`, in file order. A row of the 7-field form, written before
    /// the raw column, holds the file's own SHA-256 in field 4. With `samtools`, such a row of a BAM or an index gets
    /// the canonical digest of the copy that the evidence kept under `payloads/` (Q32 X1 ruling F2), so a baseline of
    /// an earlier run compares as a run of this one does. A copy that is not there gives the row a digest that no
    /// file holds, so the compare reports the file as a finding.
    static func payloadRows(in caseFolder: URL, samtools: URL? = nil) throws -> [Row] {
        let lines = try String(contentsOf: caseFolder.appendingPathComponent(payloadFileName), encoding: .utf8)
            .split(separator: "\n").dropFirst()
        return try lines.map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 || fields.count == 8, let kind = TaxTriageParityPayloadKind(rawValue: fields[2]),
                  let size = Int64(fields[5]) else {
                throw LiveNextflowError.misconfigured("\(caseFolder.path)/\(payloadFileName) holds a row that is not a payload: \(line)")
            }
            var payload = TaxTriageParityPayload(
                sample: fields[1], key: fields[3], path: fields[6], kind: kind, sha256: fields[4],
                rawSHA256: fields.count == 8 ? fields[7] : fields[4], size: size
            )
            let key = fields[3].lowercased()
            if fields.count == 7, let samtools, kind == .keptReads, [".bam", ".bai", ".csi"].contains(where: { key.hasSuffix($0) }) {
                let side = TaxTriageParitySide(rawValue: fields[0])?.folderName ?? fields[0]
                let copy = caseFolder.appendingPathComponent("payloads/\(side)/\(fields[1])/\(fields[3])")
                if FileManager.default.fileExists(atPath: copy.path) {
                    payload = payload.withSHA256(try TaxTriageParityPayloads.canonicalDigest(of: copy, samtools: samtools))
                } else {
                    payload = payload.withSHA256("no copy of this file in the baseline, \(copy.path)")
                }
            }
            return Row(side: fields[0], payload: payload)
        }
    }

    /// The paths of the saved records, relative to the `records` folder of `caseFolder`.
    static func savedRecords(in caseFolder: URL) throws -> [String] {
        TaxTriageParityComparison.Rules.relativeFiles(under: caseFolder.appendingPathComponent("records", isDirectory: true))
    }
}

/// The keys in which two sides' `all.odr.json` differ (BIO R3). They are named, never masked and never asserted.
enum TaxTriageParityODRJSON {
    static let fileName = "all.odr.json"

    /// The run's `all.odr.json`, wherever below its analysis folder the engine put it, or nil.
    static func file(of run: TaxTriageParitySideRun) -> URL? {
        guard let analysis = run.analysisFolder else { return nil }
        return TaxTriageParityComparison.Rules.relativeFiles(under: analysis)
            .first { ($0 as NSString).lastPathComponent == fileName }
            .map { analysis.appendingPathComponent($0) }
    }

    /// For each pair, the differing keys with every array place folded to `[]` and how many values differ under
    /// each, then every differing value by its full path.
    static func report(_ pass: TaxTriageParityLivePass) -> [String] {
        var lines: [String] = []
        for (reference, candidate) in TaxTriageParityLivePass.pairs {
            let files = [reference, candidate].map { side in pass.runs.first { $0.side == side }.flatMap(file(of:)) }
            guard files.contains(where: { $0 != nil }) else {
                lines.append("\(reference) against \(candidate), all.odr.json: neither side holds the file")
                continue
            }
            let paths = differingPaths(files[0], reference, files[1], candidate)
            lines.append("\(reference) against \(candidate), all.odr.json: \(paths.count) differing values")
            lines += foldedKeys(paths).map { "  key \($0)" }
            lines += paths.map { "    \($0)" }
        }
        return lines
    }

    /// Every path whose value differs, `$` for the top, `.name` for a member and `[n]` for an element.
    static func differingPaths(_ reference: URL?, _ referenceSide: TaxTriageParitySide, _ candidate: URL?, _ candidateSide: TaxTriageParitySide) -> [String] {
        switch (reference, candidate) {
        case (nil, nil):
            return []
        case (_?, nil):
            return ["$: only in \(referenceSide)"]
        case (nil, _?):
            return ["$: only in \(candidateSide)"]
        case let (referenceFile?, candidateFile?):
            func parse(_ file: URL) -> Any? {
                (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            }
            guard let a = parse(referenceFile), let c = parse(candidateFile) else { return ["$: not JSON on one side"] }
            var lines: [String] = []
            walk(a, c, path: "$", into: &lines, sides: ("\(referenceSide)", "\(candidateSide)"))
            return lines
        }
    }

    private static func walk(_ a: Any, _ c: Any, path: String, into lines: inout [String], sides: (String, String)) {
        switch (a, c) {
        case let (objectA as [String: Any], objectC as [String: Any]):
            for key in Set(objectA.keys).union(objectC.keys).sorted() {
                switch (objectA[key], objectC[key]) {
                case let (valueA?, valueC?): walk(valueA, valueC, path: "\(path).\(key)", into: &lines, sides: sides)
                case (_?, nil): lines.append("\(path).\(key): only in \(sides.0)")
                case (nil, _?): lines.append("\(path).\(key): only in \(sides.1)")
                default: break
                }
            }
        case let (arrayA as [Any], arrayC as [Any]):
            for index in 0..<max(arrayA.count, arrayC.count) {
                if index < arrayA.count, index < arrayC.count {
                    walk(arrayA[index], arrayC[index], path: "\(path)[\(index)]", into: &lines, sides: sides)
                } else {
                    lines.append("\(path)[\(index)]: only in \(index < arrayA.count ? sides.0 : sides.1)")
                }
            }
        default:
            if !(a as AnyObject).isEqual(c) {
                func short(_ value: Any) -> String { String(String(describing: value).prefix(120)).debugDescription }
                lines.append("\(path): \(short(a)) became \(short(c))")
            }
        }
    }

    /// The paths of `lines` with each `[n]` folded to `[]`, each with its count, sorted.
    static func foldedKeys(_ lines: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for line in lines {
            let path = line.components(separatedBy: ": ").first ?? line
            counts[path.replacingOccurrences(of: "\\[[0-9]+\\]", with: "[]", options: .regularExpression), default: 0] += 1
        }
        return counts.keys.sorted().map { "\($0) (\(counts[$0]!))" }
    }
}
