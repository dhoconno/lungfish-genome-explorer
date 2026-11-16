// UMIPlanReport.swift - The per-sample report of the UMI branch, one row a sample read from its `home` files (Phase 5.3
// lane EX-UMI, milestone 2, gate G4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// One sample's row: the check's verdict and shares, the share of reads that extraction kept, STAR's too-short share
/// and the UMI count totals (reproduction plan gate G4). A step that did not run, as after a failed check, reads
/// ``UMIPlanReport/notRun``. Each share is cut down to one decimal, as the check's are.
package struct UMIPlanReportRow: Sendable, Equatable {
    package var sample: String
    package var check: String
    package var pairsRead: String
    package var withinOneMismatch: String
    package var exact: String
    package var distinctUMIs: String
    package var extractionKept: String
    package var starTooShort: String
    package var umiCounts: String
    package var genesCounted: String

    package var fields: [String] {
        [sample, check, pairsRead, withinOneMismatch, exact, distinctUMIs, extractionKept, starTooShort, umiCounts, genesCounted]
    }
}

package enum UMIPlanReport {
    package static let notRun = "not run"
    package static let header = [
        "sample", "check", "pairs read", "within one mismatch %", "exact %", "distinct UMIs %", "extraction kept %",
        "STAR too short %", "UMI counts", "genes counted",
    ]

    /// The table, a header and one row a sample, tab-separated.
    package static func tsv(_ rows: [UMIPlanReportRow]) -> String {
        ([header] + rows.map(\.fields)).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// The row of `sample`, whose `home` files sit below `result` at their plan paths, as the batch returns them into
    /// `<batch>/<sample>/result/`. Several pairs give each check share pair by pair, joined by " / ", and the worst
    /// verdict. A result with no check file is refused, since every plan of the branch runs one.
    package static func row(sample: String, result: URL) throws -> UMIPlanReportRow {
        func file(_ path: String) -> URL? {
            let url = result.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        var checks: [UMILayoutCheck.Report] = []
        var logs: [URL] = []
        var pair = 1
        while let url = file(UMIPlan.checkOutput(pair: pair)) {
            checks.append(try JSONDecoder().decode(UMILayoutCheck.Report.self, from: Data(contentsOf: url)))
            if let log = file(UMIPlan.extractLog(pair: pair)) { logs.append(log) }
            pair += 1
        }
        guard !checks.isEmpty else {
            throw SalmonPlanError("The result of \(sample) holds no \(UMIPlan.checkOutput(pair: 1)), the UMI layout check every "
                + "sample of the UMI branch runs first, so the report has no row for it. Copy the sample's result folder whole.")
        }
        func share(_ id: String) -> String {
            checks.map { $0.shares.first { $0.id == id }?.percent ?? notRun }.joined(separator: " / ")
        }
        let verdicts = Set(checks.map(\.verdict))
        let verdict: UMILayoutCheck.Verdict = verdicts.contains(.failed) ? .failed : verdicts.contains(.warned) ? .warned : .passed
        var row = UMIPlanReportRow(
            sample: sample, check: verdict.rawValue, pairsRead: checks.map { String($0.counts.pairsRead) }.joined(separator: " / "),
            withinOneMismatch: share("withinOneMismatch"), exact: share("exact"), distinctUMIs: share("distinctUMIs"),
            extractionKept: notRun, starTooShort: notRun, umiCounts: notRun, genesCounted: notRun)
        if !logs.isEmpty {
            let read = try logs.map { try extractCounts(String(decoding: Data(contentsOf: $0), as: UTF8.self)) }
            row.extractionKept = percent(read.map(\.output).reduce(0, +), of: read.map(\.input).reduce(0, +))
        }
        if let url = file(UMIPlan.starLog) {
            let values = starValues(String(decoding: try Data(contentsOf: url), as: UTF8.self))
            if let input = values["Number of input reads"].flatMap(Int.init),
               let short = values["Number of reads unmapped: too short"].flatMap(Int.init) {
                row.starTooShort = percent(short, of: input)
            }
        }
        if let url = file(UMIPlan.countTable) {
            let counts = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(whereSeparator: \.isNewline).dropFirst()
                .compactMap { $0.split(separator: "\t").last.flatMap { Int($0) } }
            row.umiCounts = String(counts.reduce(0, +))
            row.genesCounted = String(counts.filter { $0 > 0 }.count)
        }
        return row
    }

    /// `umi_tools extract`'s `Input Reads` and `Reads output` lines, which every run of it logs.
    static func extractCounts(_ log: String) throws -> (input: Int, output: Int) {
        func value(_ name: String) -> Int? {
            guard let range = log.range(of: name + ": ") else { return nil }
            return Int(log[range.upperBound...].prefix { $0.isNumber })
        }
        guard let input = value("Input Reads"), let output = value("Reads output") else {
            throw SalmonPlanError("An extract log of the UMI branch holds no Input Reads or Reads output line, so the report "
                + "cannot give the share extraction kept. Copy the sample's result folder whole.")
        }
        return (input, output)
    }

    /// The `name | value` lines of STAR's `Log.final.out`, each side trimmed.
    static func starValues(_ log: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in log.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// `count` of `total` cut down to one decimal, so a share under a bar never reads as the bar, or `not run` of none.
    static func percent(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return notRun }
        let tenths = count * 1000 / total
        return "\(tenths / 10).\(tenths % 10)"
    }
}
