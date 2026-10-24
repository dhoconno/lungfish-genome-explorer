// ProvenanceInspectorViewModel+StepStorage.swift - The lines a storage step's record adds to its disclosure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI
import LungfishWorkflow

/// The lines of a storage step's disclosure that say how its stored gzip was written (C4-10), in UX's words for N3's
/// record lines (tally-r2 N3-3 to N3-5, with OQ-5's source words of tally-c4).
///
/// - Compressed by names the program that wrote the gzip: a `bgzip` BBTools started, with its version, where the
///   version came from and its argv (N3-3a), BBTools' own writer (N3-3b) or the compress step itself (N3-3c).
/// - Compression level gives the level that took effect and, on a `clumpify.sh` or compress step, what became of the
///   level the import chose (N3-4a to N3-4c).
/// - Clumpify groups gives clumpify's group count, on `clumpify.sh` steps only (N3-5a to N3-5c).
///
/// A line shows only when the step's record holds its field, so a record written before C4 shows as it did, and none
/// is a warning. Clumpify's memory lines stay in the record and add no line.
struct ProvenanceStepStorageDisplay: Equatable, Sendable {
    /// One line of the step's disclosure, declared in the order the disclosure, the Copy text and VoiceOver read
    /// them. The lines follow the Environment line, which follows the Command.
    enum Line: CaseIterable, Sendable {
        case compressedBy
        case compressionLevel
        case clumpifyGroups

        var label: String {
            switch self {
            case .compressedBy: return "Compressed by"
            case .compressionLevel: return "Compression level"
            case .clumpifyGroups: return "Clumpify groups"
            }
        }

        /// The accessibility identifier of the line's value, beside `provenance-step-command`.
        var identifier: String {
            switch self {
            case .compressedBy: return "provenance-step-compressed-by"
            case .compressionLevel: return "provenance-step-compression-level"
            case .clumpifyGroups: return "provenance-step-clumpify-groups"
            }
        }
    }

    let compressedBy: String?
    let compressionLevel: String?
    let clumpifyGroups: String?

    /// The lines `step` of `envelope` adds, or nil when its record holds none of their fields.
    init?(_ step: ProvenanceStep, in envelope: ProvenanceEnvelope) {
        self.init(
            toolName: step.toolName, toolVersion: step.toolVersion, options: step.resolvedOptions,
            chosenLevel: Self.chosenLevel(of: envelope)
        )
    }

    /// The lines of a step that ran `toolName` and recorded `options`, in an import that chose `chosenLevel`.
    init?(toolName: String, toolVersion: String, options: [String: ParameterValue], chosenLevel: CompressionLevel?) {
        let writer = Self.dictionary(options["writer"])
        let level = Self.integer(options["effectiveCompressionLevel"])
        let groups = Self.integer(options["clumpifyGroups"])
        let holdsStorageFields = writer != nil || level != nil || groups != nil
            || options["clumpifyMemoryEstimateLine"] != nil || options["clumpifyMemoryAvailableLine"] != nil
        let compressedBy = writer.map { Self.writerText($0, toolName: toolName, toolVersion: toolVersion) }
        let compressionLevel = Self.levelText(level, writer: writer, toolName: toolName, chosen: chosenLevel)
        let clumpifyGroups = toolName == "clumpify.sh" && holdsStorageFields ? Self.groupsText(groups) : nil
        guard compressedBy != nil || compressionLevel != nil || clumpifyGroups != nil else { return nil }
        self.compressedBy = compressedBy
        self.compressionLevel = compressionLevel
        self.clumpifyGroups = clumpifyGroups
    }

    /// The text of `line`, or nil when the line does not show.
    func text(of line: Line) -> String? {
        switch line {
        case .compressedBy: return compressedBy
        case .compressionLevel: return compressionLevel
        case .clumpifyGroups: return clumpifyGroups
        }
    }

    /// The level the import chose, as its record states it (fast, balanced or maximum).
    static func chosenLevel(of envelope: ProvenanceEnvelope) -> CompressionLevel? {
        let options = envelope.options
        let value = options.explicit["compressionLevel"] ?? options.resolvedDefaults["compressionLevel"]
            ?? options.defaults["compressionLevel"]
        return string(value).flatMap(CompressionLevel.init(rawValue:))
    }

    // MARK: - Compressed by

    private static func writerText(_ writer: [String: ParameterValue], toolName: String, toolVersion: String) -> String {
        let name = string(writer["name"]) ?? ""
        if name == "BBTools native BGZF" {
            return "BBTools built-in BGZF writer, because no bgzip answered on the step's PATH"
        }
        if let tool = dictionary(writer["tool"]) {
            let version = nonEmpty(string(tool["version"]))
            let head: String
            if let version {
                let detail = [nonEmpty(string(tool["build"])).map { "build \($0)" }, sourceWords(string(tool["versionSource"]))]
                    .compactMap { $0 }.joined(separator: ", ")
                head = "\(name) \(version)" + (detail.isEmpty ? "" : " (\(detail))")
            } else {
                head = "\(name), version Not recorded"
            }
            let arguments = (array(writer["arguments"]) ?? []).compactMap { string($0) }
            let launch = arguments.isEmpty ? "" : " as " + ([name] + arguments).joined(separator: " ")
            return "\(head), started by \(toolName)\(launch)"
        }
        if name == toolName {
            let version = toolVersion.trimmingCharacters(in: .whitespaces)
            return "This step (\(name)\(version.isEmpty ? "" : " \(version)"))"
        }
        return name
    }

    /// The words after "from" for where a writer's version came from (OQ-5), nil for `unknown` or no source.
    static func sourceWords(_ source: String?) -> String? {
        switch source {
        case "imageManifest": return "from the tool image's manifest"
        case "planPin": return "from the plan's pin"
        case "observed": return "read on the Mac that ran the import"
        case "lockPin": return "from Lungfish's tool lock, not read from the tool"
        case "sourceBuild": return "from the source build in Lungfish's tool lock"
        default: return nil
        }
    }

    // MARK: - Compression level

    private static func levelText(
        _ level: Int?, writer: [String: ParameterValue]?, toolName: String, chosen: CompressionLevel?
    ) -> String? {
        if let level {
            guard toolName == "clumpify.sh", let chosen, chosen.zlValue != level else { return "\(level)" }
            return "\(level). clumpify.sh always compresses at level \(level), so the chosen level "
                + "(\(chosen.rawValue), \(chosen.zlValue)) did not apply."
        }
        guard let name = writer.flatMap({ string($0["name"]) }), name == toolName, name == "bgzip" || name == "pigz"
        else { return nil }
        return "\(name)'s default."
            + (chosen.map { " The chosen level (\($0.rawValue), \($0.zlValue)) is not passed to \(name)." } ?? "")
    }

    // MARK: - Clumpify groups

    private static func groupsText(_ groups: Int?) -> String {
        guard let groups else { return "Not recorded" }
        guard groups > 1 else { return "\(groups)" }
        return "\(groups). clumpify.sh split the input into \(groups) groups to fit its memory, so its reorder option "
            + "had no effect."
    }

    // MARK: - Record values

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func string(_ value: ParameterValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private static func integer(_ value: ParameterValue?) -> Int? {
        if case .integer(let number)? = value { return number }
        return nil
    }

    private static func dictionary(_ value: ParameterValue?) -> [String: ParameterValue]? {
        if case .dictionary(let entries)? = value { return entries }
        return nil
    }

    private static func array(_ value: ParameterValue?) -> [ParameterValue]? {
        if case .array(let items)? = value { return items }
        return nil
    }
}

extension ProvenanceSection {
    /// One storage row of a step's disclosure, or nothing when the step's record holds no field for it. The rows
    /// follow the Environment row, in the order the Copy text lists them (`appendStepLines(of:to:)`), and each value
    /// carries its own accessibility identifier.
    @ViewBuilder
    func stepStorageRow(_ line: ProvenanceStepStorageDisplay.Line, of step: ProvenanceLineageStep) -> some View {
        if let text = step.storage?.text(of: line) {
            summaryRow(line.label, value: text, accessibilityIdentifier: line.identifier)
        }
    }
}
