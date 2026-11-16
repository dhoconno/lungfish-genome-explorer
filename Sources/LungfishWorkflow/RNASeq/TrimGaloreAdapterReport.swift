// TrimGaloreAdapterReport.swift - The adapter one Trim Galore call trimmed, from its JSON reports and its console line, in
// the words both salmon routes record (Phase 5.3 lane EX-ADOPT M4, ruling BIO-PLAN-ADAPTER items 4, 5 and 8)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What one Trim Galore call says about the adapter it trimmed. Its JSON reports hold the adapter's name and sequence,
/// the read 2 adapter and the length cutoff, and never how the adapter was chosen. Only its console says that, in the
/// line "Using <name> adapter for trimming (count: N). Second best hit was <name> (count: M)." or the fallback's "No
/// adapters detected in the first N reads. Defaulting to Illumina adapter.", so the words say auto-detected only from
/// that line (ruling BIO-PLAN-ADAPTER item 4). The adopt reads a returned call's reports and console file, and `rnaseq
/// quant` its own call's reports and standard error before it removes the trim folder (item 5).
package struct TrimGaloreAdapterReport: Sendable, Equatable {
    /// One adapter of `parameters.adapters` or `parameters.adapters_r2`.
    package struct Adapter: Sendable, Equatable {
        package let name: String?
        package let sequence: String
    }

    /// What the console says about how the adapter was chosen.
    package enum Detection: Sendable, Equatable {
        /// The detection line as written, and the adapter it names.
        case detected(line: String, name: String)
        /// The fallback's line, when the reads checked held no adapter.
        case fallback(line: String)
        /// No line that says how the adapter was chosen.
        case notFound
    }

    /// The version the report names, such as 2.3.0.
    package let version: String?
    /// `parameters.adapters` of the read 1 report, or nil when no report is a readable Trim Galore JSON report.
    package let adapters: [Adapter]?
    /// `parameters.adapters_r2`, empty when the call set none.
    package let read2: [Adapter]
    /// `parameters.length_cutoff`.
    package let lengthCutoff: Int?
    package let detection: Detection

    package static let notRecorded = "Not recorded"
    package static let unreadable = "Not recorded (Trim Galore wrote no readable JSON trimming report for this call)"

    /// Reads a call's JSON reports, the read 1 report first, and the text of its console.
    package static func read(reports: [Data], console: String) -> TrimGaloreAdapterReport {
        let parsed = reports.compactMap { data -> [String: Any]? in
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["parameters"] as? [String: Any])?["adapters"] is [Any] else { return nil }
            return json
        }
        let json = parsed.first { ($0["read_number"] as? Int ?? 1) == 1 } ?? parsed.first
        let parameters = json?["parameters"] as? [String: Any] ?? [:]
        return TrimGaloreAdapterReport(
            version: json?["trim_galore_version"] as? String, adapters: json == nil ? nil : adapterList(parameters["adapters"]),
            read2: adapterList(parameters["adapters_r2"]), lengthCutoff: parameters["length_cutoff"] as? Int,
            detection: detection(in: console))
    }

    /// Reads the JSON reports a call wrote into `folder`, its `-o` folder, and the text of its console.
    package static func read(folder: URL, console: String) -> TrimGaloreAdapterReport {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix("_trimming_report.json") }.sorted()
        return read(reports: names.compactMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }, console: console)
    }

    static func adapterList(_ value: Any?) -> [Adapter] {
        (value as? [Any] ?? []).compactMap { item in
            if let sequence = item as? String { return Adapter(name: nil, sequence: sequence) }
            guard let object = item as? [String: Any], let sequence = object["sequence"] as? String else { return nil }
            return Adapter(name: object["name"] as? String, sequence: sequence)
        }
    }

    /// The first line of the console that says how the adapter was chosen.
    static func detection(in console: String) -> Detection {
        for raw in console.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Using "), let end = line.range(of: " adapter for trimming (count: ") {
                return .detected(line: line, name: String(line[line.index(line.startIndex, offsetBy: 6)..<end.lowerBound]))
            }
            if line.contains("Defaulting to "), line.contains(" adapter") { return .fallback(line: line) }
        }
        return .notFound
    }
}

extension TrimGaloreAdapterReport {
    /// The call's sentence: auto-detected only when the console's detection line names the report's adapter, the
    /// ruling's words for a fallback, and otherwise the adapter the report names with no word on how it was chosen.
    package var sentence: String {
        guard let adapters else { return Self.unreadable }
        let tool = "Trim Galore" + (version.map { " \($0)" } ?? "")
        guard !adapters.isEmpty else { return "\(tool) trimmed no adapter, since its report names none." }
        let named = Self.phrase(adapters)
        switch detection {
        case .detected(_, let name) where adapters.count == 1 && Self.sameName(name, adapters[0].name):
            return "\(tool) auto-detected \(named) in read 1."
        case .detected(let line, _):
            return "\(tool) trimmed \(named), and its console line names another adapter (\(line))."
        case .fallback:
            return "No adapter found in the reads Trim Galore checked, so its fallback, \(named), was used."
        case .notFound:
            return "\(tool) trimmed \(named), and its console output holds no line that says how it chose that adapter."
        }
    }

    /// The trim step's lines: the sentence, the adapter's name and sequence, the read 2 adapter ("none" when empty), the
    /// length cutoff and the console line as written (ruling BIO-PLAN-ADAPTER item 4).
    package var lines: [String: ParameterValue] {
        var lines: [String: ParameterValue] = ["adapter": .string(sentence)]
        if let adapters {
            lines["adapterName"] = .string(adapters.isEmpty ? "none" : adapters.map { $0.name ?? Self.notRecorded }.joined(separator: " and "))
            lines["adapterSequence"] = .string(adapters.isEmpty ? "none" : adapters.map(\.sequence).joined(separator: " and "))
            let read2Words = read2.map { adapter in adapter.name.map { "\($0) \(adapter.sequence)" } ?? adapter.sequence }
            lines["adapterRead2"] = .string(read2.isEmpty ? "none" : read2Words.joined(separator: " and "))
            lines["lengthCutoff"] = lengthCutoff.map(ParameterValue.integer) ?? .string(Self.notRecorded)
        }
        switch detection {
        case .detected(let line, _), .fallback(let line): lines["adapterDetection"] = .string(line)
        case .notFound: lines["adapterDetection"] = .string(Self.notRecorded)
        }
        return lines
    }

    static func phrase(_ adapters: [Adapter]) -> String {
        adapters.map { adapter in adapter.name.map { "the \($0) adapter \(adapter.sequence)" } ?? "the adapter \(adapter.sequence)" }
            .joined(separator: " and ")
    }

    static func sameName(_ line: String, _ report: String?) -> Bool {
        func plain(_ name: String) -> String { name.lowercased().filter { !$0.isWhitespace } }
        return report.map { plain($0) == plain(line) } ?? false
    }

    /// One sentence when the trim calls of a result's samples got different adapters, and nil when they got one
    /// (ruling BIO-PLAN-ADAPTER item 8). It reads each trim step's `sample` and adapter lines, as both routes write them,
    /// and leaves out a call whose report was not readable.
    package static func differentAdapters(in steps: [ProvenanceStep]) -> String? {
        var groups: [(adapter: String, samples: [String])] = []
        for step in steps where step.toolName == "trim_galore" {
            guard case .string(let sample)? = step.resolvedOptions["sample"],
                  case .string(let name)? = step.resolvedOptions["adapterName"],
                  case .string(let sequence)? = step.resolvedOptions["adapterSequence"] else { continue }
            var adapter = name == notRecorded ? "the adapter \(sequence)" : "the \(name) adapter \(sequence)"
            if case .string(let read2)? = step.resolvedOptions["adapterRead2"], read2 != "none" {
                adapter += " with the read 2 adapter \(read2)"
            }
            if let at = groups.firstIndex(where: { $0.adapter == adapter }) {
                if !groups[at].samples.contains(sample) { groups[at].samples.append(sample) }
            } else {
                groups.append((adapter, [sample]))
            }
        }
        guard groups.count > 1 else { return nil }
        let parts = groups.map { "\($0.adapter) for \(list($0.samples))" }
        return "Trim Galore chose different adapters for the samples of this result, \(list(parts))."
    }

    /// "a", "a and b", or "a, b and c".
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
    }
}
