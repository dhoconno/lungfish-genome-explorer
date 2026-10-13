// RouteParityHarness+Compare.swift - How two sides of a route parity case differ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30. Two sides compare in two ways.
//
// - How each ended, in the words of a row (`RouteParityEnd`).
// - Every file under the two side roots, through `OutputEquivalence.differences` with the
//   harness's kind and the contract's masks. That comparison decides whether a file differs.
//
// A file that differs is then explained, so a declared difference names one value or one line
// and never a whole file (panel G5). A JSON file gives one difference for each value path whose
// value differs or that one side lacks, and any other text file one difference for each line that
// one side holds more often than the other, both read under the same masks with UUIDs numbered
// within the file. A binary, compressed or SQLite file, a file whose name the comparison masked to
// more than one file, a file that differs only in order or in the numbering of UUIDs across the
// tree, or a file with more than `explainedLimit` such differences, stays one difference.
//
// Ids are stable from run to run, with UUIDs, run IDs and timestamps masked, so a declared entry
// matches the same difference in every run.

import Foundation
import LungfishTestSupport

extension RouteParityHarness {
    /// The most differences one file is explained as. A file that differs in more is one
    /// difference.
    static let explainedLimit = 50

    /// Every difference of the case, by scope. A against C, side C's missing command when it
    /// recorded none, and otherwise C against C'.
    public func differences(of runs: RouteParityRuns) throws -> [RouteParityScope: [RouteParityDifference]] {
        var found = Dictionary(uniqueKeysWithValues: RouteParityScope.all.map { ($0, [RouteParityDifference]()) })
        found[.aAgainstC] = try differences(runs.a, runs.c)
        if runs.c.outcome.recordedCommand == nil {
            found[.side(.c)] = [RouteParityDifference(id: "command: side C records no command", detail: runs.c.outcome.detail)]
        } else {
            found[.cAgainstCPrime] = try differences(runs.c, runs.cPrime)
        }
        return found
    }

    /// How `candidate` differs from `reference`. How each ended, then every file under the two
    /// side roots.
    public func differences(_ reference: RouteParitySideRun, _ candidate: RouteParitySideRun) throws -> [RouteParityDifference] {
        var found: [RouteParityDifference] = []
        if reference.outcome.end != candidate.outcome.end {
            found.append(RouteParityDifference(
                id: "end: \(reference.side) \(reference.outcome.end), \(candidate.side) \(candidate.outcome.end)",
                detail: "\(reference.side) \(reference.outcome.detail) | \(candidate.side) \(candidate.outcome.detail)"
            ))
        }
        let contentCompared = Self.contentComparedNames(reference.root, candidate.root)
        for line in try OutputEquivalence.differences(reference.root, candidate.root, kind: kind, masks: masks) {
            found += parse(line, reference, candidate, contentCompared: contentCompared)
        }
        return found
    }

    /// One `OutputEquivalence` line as differences, with A and B named as the two sides.
    func parse(
        _ line: String,
        _ reference: RouteParitySideRun,
        _ candidate: RouteParitySideRun,
        contentCompared: ContentComparedNames
    ) -> [RouteParityDifference] {
        var parts = line.components(separatedBy: "\n")
        let head = parts.removeFirst()
        let detail = parts.joined(separator: "\n        ")
        let prefixes: [(prefix: String, words: String, side: RouteParitySide)] = [
            ("only in A: ", "only in", reference.side), ("only in B: ", "only in", candidate.side),
            ("collides in A: ", "collides in", reference.side), ("collides in B: ", "collides in", candidate.side),
        ]
        for item in prefixes where head.hasPrefix(item.prefix) {
            let name = Self.maskedID(String(head.dropFirst(item.prefix.count)))
            return [RouteParityDifference(id: "\(item.words) \(item.side): \(name)", detail: detail)]
        }
        if head.hasPrefix("differs: ") {
            let name = String(head.dropFirst("differs: ".count))
            return explained(name, reference, candidate, contentCompared: contentCompared)
                ?? [RouteParityDifference(id: "differs: \(Self.maskedID(name))", detail: detail)]
        }
        return [RouteParityDifference(id: Self.maskedID(head), detail: detail)]
    }

    // MARK: - Explaining a file that differs

    /// The raw names under each root of the content-compared files both trees hold. A record's
    /// mask hides the checksum and size it states for those files (docs/contracts/CLI-EQUIVALENCE.md,
    /// Masks), so the explanation hides them too.
    struct ContentComparedNames {
        let reference: Set<String>
        let candidate: Set<String>
    }

    /// The suffixes of the files `OutputEquivalence` compares by content rather than by bytes.
    static let contentComparedSuffixes = [
        ".bam", ".bai", ".csi", ".tbi", ".crai", ".gz", ".bgz", ".bgzf", ".db", ".sqlite", ".sqlite3", ".json",
    ]

    static func contentComparedNames(_ reference: URL, _ candidate: URL) -> ContentComparedNames {
        func eligible(_ root: URL) -> [String] {
            relativeFiles(under: root).filter { name in contentComparedSuffixes.contains { name.lowercased().hasSuffix($0) } }
        }
        let namesA = eligible(reference)
        let namesB = eligible(candidate)
        let blankedA = Set(namesA.map(blankedName))
        let blankedB = Set(namesB.map(blankedName))
        return ContentComparedNames(
            reference: Set(namesA.filter { blankedB.contains(blankedName($0)) }),
            candidate: Set(namesB.filter { blankedA.contains(blankedName($0)) })
        )
    }

    /// One difference for each value or line of the file `name` that differs, or nil when the
    /// file stays one difference.
    func explained(
        _ name: String,
        _ reference: RouteParitySideRun,
        _ candidate: RouteParitySideRun,
        contentCompared: ContentComparedNames
    ) -> [RouteParityDifference]? {
        guard let fileA = Self.rawFile(named: name, under: reference.root),
              let fileB = Self.rawFile(named: name, under: candidate.root),
              let textA = Self.plainText(fileA),
              let textB = Self.plainText(fileB)
        else { return nil }
        let fileMasks = masks(forFile: fileA.lastPathComponent)
        func masked(_ text: String, contentComparedPaths: Set<String>) -> String {
            let context = OutputEquivalence.MaskContext(
                rootA: reference.root, rootB: candidate.root, contentComparedPaths: contentComparedPaths
            )
            return fileMasks.reduce(text) { partial, mask in mask(partial, context: context) }
        }
        let maskedA = masked(textA, contentComparedPaths: contentCompared.reference)
        let maskedB = masked(textB, contentComparedPaths: contentCompared.candidate)
        let label = Self.maskedID(name)
        var found: [RouteParityDifference] = []
        if name.lowercased().hasSuffix(".json"), let valuesA = Self.jsonValues(maskedA), let valuesB = Self.jsonValues(maskedB) {
            for path in Set(valuesA.keys).union(valuesB.keys).sorted() where valuesA[path] != valuesB[path] {
                found.append(RouteParityDifference(
                    id: "differs: \(label) at \(Self.maskedID(path))",
                    detail: "\(reference.side) \(Self.shown(valuesA[path])), \(candidate.side) \(Self.shown(valuesB[path]))"
                ))
            }
        } else {
            let lines = Self.unmatchedLines(Self.comparedLines(maskedA, name: name), Self.comparedLines(maskedB, name: name))
            for (side, sideLines) in [(reference.side, lines.onlyA), (candidate.side, lines.onlyB)] {
                found += sideLines.map { line in
                    RouteParityDifference(id: "differs: \(label): only in \(side): \(Self.maskedID(String(line.prefix(200))))")
                }
            }
        }
        guard !found.isEmpty else { return nil }
        guard found.count <= Self.explainedLimit else {
            return [RouteParityDifference(
                id: "differs: \(label)",
                detail: "\(found.count) values or lines differ, the first \(found[0])"
            )]
        }
        return found
    }

    /// The masks `OutputEquivalence` gives a file named `name` for the harness's kind.
    func masks(forFile name: String) -> [OutputEquivalence.Mask] {
        let lowered = name.lowercased()
        guard kind != .remoteRequest, kind != .managedPlan, lowered.hasSuffix(".json") else { return masks.payloads }
        if lowered.contains("provenance") { return masks.provenance }
        if lowered.contains("manifest") { return masks.records }
        return masks.payloads
    }

    /// The file under `root` that the compared name `name` stands for. A name with a masked UUID
    /// or run ID stands for the one file whose name matches it with those blanked, and for none
    /// when several do.
    static func rawFile(named name: String, under root: URL) -> URL? {
        guard name.contains("<") else {
            let direct = root.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
        }
        let wanted = blankedName(name)
        let matches = relativeFiles(under: root).filter { blankedName($0) == wanted }
        return matches.count == 1 ? root.appendingPathComponent(matches[0]) : nil
    }

    /// The text of a file the explanation reads, or nil for an index, a BAM, a gzip or BGZF file,
    /// a SQLite database or bytes that are not UTF-8.
    static func plainText(_ url: URL) -> String? {
        let lowered = url.lastPathComponent.lowercased()
        guard ![".bam", ".bai", ".csi", ".tbi", ".crai", ".cram"].contains(where: { lowered.hasSuffix($0) }),
              let data = try? Data(contentsOf: url),
              !(data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b),
              !data.starts(with: Data("SQLite format 3\u{0}".utf8))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every scalar of a JSON text under its value path, such as `steps[0].argv[2]`, or nil when
    /// the text is not JSON.
    static func jsonValues(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        var values: [String: String] = [:]
        flatten(value, path: "", into: &values)
        return values
    }

    private static func flatten(_ value: Any, path: String, into values: inout [String: String]) {
        if let object = value as? [String: Any] {
            if object.isEmpty { values[path.isEmpty ? "." : path] = "{}" }
            for (key, item) in object {
                flatten(item, path: path.isEmpty ? key : "\(path).\(key)", into: &values)
            }
        } else if let array = value as? [Any] {
            if array.isEmpty { values[path.isEmpty ? "." : path] = "[]" }
            for (index, item) in array.enumerated() {
                flatten(item, path: "\(path)[\(index)]", into: &values)
            }
        } else {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            values[path.isEmpty ? "." : path] = data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
        }
    }

    /// The lines of a text file the comparison reads. A VCF loses the header lines that record
    /// when or how it was written, as `OutputEquivalence` drops them.
    static func comparedLines(_ text: String, name: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard name.lowercased().hasSuffix(".vcf") else { return lines }
        return lines.filter { line in
            guard line.hasPrefix("##") else { return true }
            let key = line.dropFirst(2).prefix { $0 != "=" }.lowercased()
            return key != "filedate" && !key.contains("command")
        }
    }

    /// The lines each side holds more often than the other, in the order each side holds them.
    static func unmatchedLines(_ linesA: [String], _ linesB: [String]) -> (onlyA: [String], onlyB: [String]) {
        func counts(_ lines: [String]) -> [String: Int] {
            lines.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        func surplus(_ lines: [String], over other: [String: Int]) -> [String] {
            var seen: [String: Int] = [:]
            return lines.filter { line in
                seen[line, default: 0] += 1
                return seen[line, default: 0] > other[line, default: 0]
            }
        }
        return (surplus(linesA, over: counts(linesB)), surplus(linesB, over: counts(linesA)))
    }

    private static func shown(_ value: String?) -> String {
        guard let value else { return "absent" }
        return value.count > 300 ? String(value.prefix(300)) + "..." : value
    }

    // MARK: - Names and ids

    /// The relative paths of every regular file under `root`, sorted.
    static func relativeFiles(under root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var paths: [String] = []
        while let item = enumerator.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            if path.hasPrefix(base + "/") { paths.append(String(path.dropFirst(base.count + 1))) }
        }
        return paths.sorted()
    }

    /// A file name with its UUIDs and run IDs blanked, raw or numbered by the comparison's masks.
    static func blankedName(_ name: String) -> String {
        [
            "<UUID-[0-9]+>", "<RUN-ID-[0-9]+>",
            "(?<![0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f])",
            "(?<![A-Za-z0-9])aln_[0-9A-Fa-f]{8}(?![0-9A-Fa-f])",
        ].reduce(name) { $0.replacingOccurrences(of: $1, with: "<ID>", options: .regularExpression) }
    }

    /// `text` with the values that change from run to run masked, so an id names the same
    /// difference in every run. UUIDs, run IDs and timestamps.
    public static func maskedID(_ text: String) -> String {
        [
            ("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "<UUID>"),
            ("<UUID-[0-9]+>", "<UUID>"),
            ("<RUN-ID-[0-9]+>", "<RUN-ID>"),
            ("aln_[0-9A-Fa-f]{8}", "<RUN-ID>"),
            ("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}[-:][0-9]{2}[-:][0-9]{2}(?:\\.[0-9]+)?Z?", "<TS>"),
        ].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
}
