// ClassifierCLIGUIParityReplayTests+Compare.swift - What two sides of a classifier parity case must share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The comparison classes of the BIO inventory (section 2.2) as the panel adopted them (T2).
//
// - The analysis folder, through `OutputEquivalence.differences(kind: .bundle)` with the
//   contract's masks, where the root mask also covers the two side roots, so a path into the
//   project outside the folder compares too. SQLite files are compared as sorted dumps under the
//   record masks, which hide their build metadata (`created_at` by the timestamp mask and
//   `source_dir` by the root mask). A provenance record is compared by its facts instead.
// - The source bundle's analyses-manifest.json, under the same masks.
// - The input bundles. Both sides start from one copy, so every other byte of `Imports/` must
//   stay the same on both, the analyses-manifest.json of any bundle outside the case included.
// - The rest of the project outside `Imports/` and the analysis folders, so a stray write, such
//   as a scratch file left in `.tmp/` or a second analysis folder, shows.
// - Every provenance record found on both sides, projected with `ProvenanceCompatFacts`. Each
//   fact of the reference side must appear with an equal value on the other side, and facts
//   the other side adds pass. Values compare equal when they differ only in UUIDs or in the
//   wall times and rates a tool prints (golden rules R6, R7 and the tool log durations). Facts a
//   real run measures (wall times, peak memory, the host values under `recorded`) are left out,
//   and so are the checksum and size of a file both trees hold, whose content the folder
//   comparison owns.
// - The terminal state. A row that completed, with or without warnings, matches exit 0.
//
// A difference has a stable id, its class and the masked path of its file or fact, and a detail
// with the values. ClassifierParityKnownDifferences matches the ids.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// One way two sides of a case differ, or one fixed fact a side does not hold.
struct ClassifierParityDifference: Hashable, Sendable, CustomStringConvertible {
    /// The class of the difference, then the masked path of the file or fact.
    let id: String
    /// What differs, with the values, for the failure message.
    let detail: String

    var description: String { detail.isEmpty ? id : "\(id)\n        \(detail)" }
}

enum ClassifierParityComparison {
    typealias Value = ProvenanceCompatFacts.Value

    /// How `candidate` differs from `reference`.
    static func differences(
        reference: ClassifierParitySideRun,
        candidate: ClassifierParitySideRun,
        bundlePaths: [String]
    ) throws -> [ClassifierParityDifference] {
        if case .notRun(let reason) = candidate.terminal {
            return [ClassifierParityDifference(id: "command: \(candidate.side) has no command to run", detail: reason)]
        }
        var found: [ClassifierParityDifference] = []
        if reference.terminal.succeeded != candidate.terminal.succeeded {
            found.append(ClassifierParityDifference(
                id: "terminal: \(reference.side) and \(candidate.side) end differently",
                detail: "\(reference.side) \(reference.terminal), \(candidate.side) \(candidate.terminal)"
            ))
        }
        found += try folderDifferences(reference, candidate, bundlePaths: bundlePaths)
        found += try recordDifferences(reference, candidate)
        return found
    }

    // MARK: - Folders

    static func folderDifferences(
        _ reference: ClassifierParitySideRun,
        _ candidate: ClassifierParitySideRun,
        bundlePaths: [String]
    ) throws -> [ClassifierParityDifference] {
        let policy = maskPolicy(sideRoots: [reference.root, candidate.root])
        let fileManager = FileManager.default
        var found: [ClassifierParityDifference] = []

        func existing(_ folder: URL?) -> URL? { folder.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil } }
        switch (existing(reference.analysisFolder), existing(candidate.analysisFolder)) {
        case let (folderA?, folderB?):
            let lines = try OutputEquivalence.differences(folderA, folderB, kind: .bundle, masks: policy)
            found += lines.compactMap { parse($0, as: "analysis", reference: reference.side, candidate: candidate.side) }
        case (_?, nil):
            found.append(ClassifierParityDifference(id: "analysis: only \(reference.side) keeps its analysis folder", detail: ""))
        case (nil, let folder?):
            found.append(ClassifierParityDifference(id: "analysis: only \(candidate.side) keeps its analysis folder", detail: folder.lastPathComponent))
        case (nil, nil):
            break
        }

        for bundle in bundlePaths {
            let name = "\(bundle)/\(AnalysisManifest.filename)"
            let fileA = reference.project.appendingPathComponent(name)
            let fileB = candidate.project.appendingPathComponent(name)
            switch (fileManager.fileExists(atPath: fileA.path), fileManager.fileExists(atPath: fileB.path)) {
            case (true, false):
                found.append(ClassifierParityDifference(id: "source manifest: only in \(reference.side): \(name)", detail: ""))
            case (false, true):
                found.append(ClassifierParityDifference(id: "source manifest: only in \(candidate.side): \(name)", detail: ""))
            case (true, true):
                let lines = try OutputEquivalence.differences(fileA, fileB, kind: .bundle, masks: policy)
                found += lines.map { ClassifierParityDifference(id: "source manifest: differs: \(name)", detail: $0) }
            case (false, false):
                break
            }
        }

        // Both sides start from one copy, so the inputs compare byte for byte, UUIDs included.
        // Only the source manifests of the case's own bundles are left out, compared above, so a
        // write to another bundle's manifest shows.
        var inputPolicy = policy
        for unmasked in ["uuids", "runIDs"] {
            inputPolicy.records.removeAll { $0.name == unmasked }
            inputPolicy.provenance.removeAll { $0.name == unmasked }
            inputPolicy.names.removeAll { $0.name == unmasked }
        }
        let importsA = reference.project.appendingPathComponent("Imports", isDirectory: true)
        let importsB = candidate.project.appendingPathComponent("Imports", isDirectory: true)
        let sourceManifests = Set(bundlePaths.map { "\($0.dropFirst("Imports/".count))/\(AnalysisManifest.filename)" })
        let inputLines = try OutputEquivalence.differences(importsA, importsB, kind: .bundle, masks: inputPolicy)
        found += inputLines
            .filter { !sourceManifests.contains(comparedPath(of: $0)) }
            .compactMap { parse($0, as: "inputs", reference: reference.side, candidate: candidate.side) }

        // The rest of the project. Side A leaves an empty .tmp/ today, which holds no file.
        let analysisFolders = [reference, candidate].compactMap(\.analysisPath).map {
            String($0.dropFirst(ClassifierParityFixtures.projectName.count + 1)) + "/"
        }
        let projectLines = try OutputEquivalence.differences(reference.project, candidate.project, kind: .bundle, masks: policy)
        found += projectLines
            .filter { line in
                let path = comparedPath(of: line)
                return !path.hasPrefix("Imports/") && !analysisFolders.contains { path.hasPrefix($0) }
            }
            .compactMap { parse($0, as: "project", reference: reference.side, candidate: candidate.side) }
        return found
    }

    /// The relative path an `OutputEquivalence` line names, after its kind.
    static func comparedPath(of line: String) -> String {
        let head = line.components(separatedBy: "\n")[0]
        for prefix in ["only in A: ", "only in B: ", "differs: ", "collides in A: ", "collides in B: "] where head.hasPrefix(prefix) {
            return String(head.dropFirst(prefix.count))
        }
        return head
    }

    /// One `OutputEquivalence` line as a difference of class `kind`, or nil for a provenance
    /// record's bytes, which the record comparison covers.
    static func parse(
        _ line: String,
        as kind: String,
        reference: ClassifierParitySide,
        candidate: ClassifierParitySide
    ) -> ClassifierParityDifference? {
        var parts = line.components(separatedBy: "\n")
        let head = parts.removeFirst()
        let detail = parts.joined(separator: "\n        ")
        for (prefix, side) in [("only in A: ", reference), ("only in B: ", candidate)] where head.hasPrefix(prefix) {
            return ClassifierParityDifference(id: "\(kind): only in \(side): \(maskedID(String(head.dropFirst(prefix.count))))", detail: "")
        }
        if head.hasPrefix("differs: ") {
            let name = String(head.dropFirst("differs: ".count))
            if isRecordName(name) { return nil }
            // The EsViritu and fastp HTML reports embed run times and script bundles, so they
            // are compared for existence only (QA inventory 2.2).
            if name.lowercased().hasSuffix(".html") { return nil }
            let what = isSQLiteName(name) ? "SQLite dump differs" : "differs"
            return ClassifierParityDifference(id: "\(kind): \(what): \(maskedID(name))", detail: detail)
        }
        return ClassifierParityDifference(id: "\(kind): \(maskedID(head))", detail: detail)
    }

    /// The contract's masks, with the root mask also covering the side roots, which hold the
    /// compared folders. It runs right after the contract's root mask, before the UUID masks,
    /// because a temporary root's own name can hold a UUID.
    static func maskPolicy(sideRoots: [URL]) -> OutputEquivalence.MaskPolicy {
        let spellings = sideRoots.flatMap(rootSpellings).sorted { $0.count > $1.count }
        let sideRootMask = OutputEquivalence.Mask(name: "sideRoots") { text, _ in
            spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: "<SIDE-ROOT>") }
        }
        func inserted(_ masks: [OutputEquivalence.Mask]) -> [OutputEquivalence.Mask] {
            var result = masks
            let index = (result.firstIndex { $0.name == "roots" }).map { $0 + 1 } ?? 0
            result.insert(sideRootMask, at: index)
            return result
        }
        var policy = OutputEquivalence.MaskPolicy.standard
        policy.provenance = inserted(policy.provenance)
        policy.records = inserted(policy.records)
        policy.payloads = inserted(policy.payloads)
        return policy
    }

    /// Every spelling of a root: as given, standardized, resolved, with or without `/private`,
    /// and with its slashes escaped as JSON writes them.
    static func rootSpellings(_ root: URL) -> [String] {
        var forms: Set<String> = [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        for form in forms {
            if form.hasPrefix("/private/") {
                forms.insert(String(form.dropFirst("/private".count)))
            } else if form.hasPrefix("/var/") || form.hasPrefix("/tmp/") {
                forms.insert("/private" + form)
            }
        }
        let plain = forms.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { $0.count > 1 }
        return Array(Set(plain + plain.map { $0.replacingOccurrences(of: "/", with: "\\/") }))
    }

    /// A provenance record, by the name rule `OutputEquivalence` gives its provenance role.
    static func isRecordName(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasSuffix(".json") && name.contains("provenance")
    }

    static func isSQLiteName(_ path: String) -> Bool {
        let name = path.lowercased()
        return [".sqlite", ".sqlite3", ".db"].contains { name.hasSuffix($0) }
    }

    // MARK: - Records

    static func recordDifferences(
        _ reference: ClassifierParitySideRun,
        _ candidate: ClassifierParitySideRun
    ) throws -> [ClassifierParityDifference] {
        let candidateRecords = Set(recordPaths(under: candidate.root))
        let context = FactContext(reference: reference, candidate: candidate)
        var found: [ClassifierParityDifference] = []
        for path in recordPaths(under: reference.root) where candidateRecords.contains(path) {
            var missing: [(path: String, detail: String)] = []
            collectMissing(
                try factsTree(of: reference, record: path),
                try factsTree(of: candidate, record: path),
                path: "",
                into: &missing,
                context: context
            )
            found += missing.map {
                ClassifierParityDifference(id: "record \(maskedID(path)): \(maskedID($0.path))", detail: $0.detail)
            }
        }
        return found
    }

    /// The relative paths of every provenance record under `root`, sorted.
    static func recordPaths(under root: URL) -> [String] {
        relativeFiles(under: root).filter(isRecordName)
    }

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

    /// The facts of one record as a value tree.
    ///
    /// A replay runs the command in this process, so its records hold the test process's argv
    /// where the shipped binary holds its own (Swift 6 makes `CommandLine.arguments` read only).
    /// The argv of the line that wrote the record replaces it, after both pass through what the
    /// writer and the reader do to an argv (`PortablePath.sanitize`, `PortablePath.resolve`,
    /// then the facts' `PathNormalizer`), as an array and in the joined form of
    /// `reproducibleCommand`.
    static func factsTree(of run: ClassifierParitySideRun, record relativePath: String) throws -> Value {
        let sidecar = run.root.appendingPathComponent(relativePath)
        let facts = try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: run.project)
        let tree = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(facts))
        guard let argv = replayedArgv(of: run, writing: sidecar),
              let context = PortablePath.Context.forWriting(at: sidecar) else { return tree }
        let normalize = ProvenanceCompatFacts.PathNormalizer(projectRoot: run.project)
        func recorded(_ words: [String]) -> (argv: [Value], command: String) {
            let read = PortablePath.resolve(argv: PortablePath.sanitize(argv: words, context: context), context: context)
            let command = PortablePath.resolve(
                text: PortablePath.sanitize(text: words.map(shellEscape).joined(separator: " "), context: context),
                context: context
            )
            return (read.map { .string(normalize($0)) }, normalize(command))
        }
        return replacing(recorded(CommandLine.arguments), with: recorded(argv), in: tree)
    }

    /// The argv of the replayed line whose output folder holds `file`, the longest match.
    static func replayedArgv(of run: ClassifierParitySideRun, writing file: URL) -> [String]? {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return run.replayedCommands
            .map { (folder: URL(fileURLWithPath: $0.outputFolder).resolvingSymlinksInPath().standardizedFileURL.path, argv: $0.argv) }
            .filter { !$0.folder.isEmpty && path.hasPrefix($0.folder + "/") }
            .max { $0.folder.count < $1.folder.count }?
            .argv
    }

    static func replacing(
        _ process: (argv: [Value], command: String),
        with replay: (argv: [Value], command: String),
        in value: Value
    ) -> Value {
        switch value {
        case .array(let items):
            if items == process.argv { return .array(replay.argv) }
            return .array(items.map { replacing(process, with: replay, in: $0) })
        case .object(let members):
            return .object(members.mapValues { replacing(process, with: replay, in: $0) })
        case .string(let text) where text.contains(process.command):
            return .string(text.replacingOccurrences(of: process.command, with: replay.command))
        default:
            return value
        }
    }

    /// What the containment walk knows about the two sides.
    struct FactContext {
        let reference: ClassifierParitySideRun
        let candidate: ClassifierParitySideRun

        /// Whether a recorded path names a file both projects hold, whose content the folder
        /// comparison owns.
        func namesFileInBothTrees(_ recordedPath: String) -> Bool {
            let token = "<project>/"
            guard recordedPath.hasPrefix(token) else { return false }
            let relative = String(recordedPath.dropFirst(token.count))
            return [reference.project, candidate.project].allSatisfy {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(relative).path)
            }
        }
    }

    /// Fact names a real run measures, which no two runs share.
    static let measuredFacts: Set<String> = ["wallTimeSeconds", "wallTime", "totalWallTimeSeconds", "peakMemoryBytes"]

    /// Arrays whose elements are matched by identity rather than by position.
    static func elementKey(forArrayAt path: String) -> ((Value, Int) -> String)? {
        let last = path.split(separator: ".").last.map(String.init) ?? path
        if ["files", "outputs", "inputs"].contains(last) {
            return { element, _ in
                guard case .object(let members) = element else { return "?" }
                return "\(members["path"].map(text) ?? "?")|\(members["role"].map(text) ?? "?")"
            }
        }
        if ["steps", "legacyRunSteps", "canonicalRunSteps"].contains(last) {
            return { element, occurrence in
                guard case .object(let members) = element else { return "?" }
                return "\(members["toolName"].map(text) ?? "?")#\(occurrence)"
            }
        }
        return nil
    }

    /// Adds to `found` every leaf of `reference` that `candidate` lacks or holds with another
    /// value, by its path.
    static func collectMissing(
        _ reference: Value,
        _ candidate: Value?,
        path: String,
        into found: inout [(path: String, detail: String)],
        context: FactContext
    ) {
        let last = path.split(separator: ".").last.map(String.init) ?? path
        if path == "recorded" || measuredFacts.contains(last) { return }
        guard let candidate else {
            found.append((path, "absent from \(context.candidate.side), \(context.reference.side) holds \(describe(reference))"))
            return
        }
        switch (reference, candidate) {
        case (.object(var members), .object(let candidateMembers)):
            if case .string(let filePath)? = members["path"], members["role"] != nil,
               context.namesFileInBothTrees(filePath) {
                members["sha256"] = nil
                members["size"] = nil
            }
            for key in members.keys.sorted() {
                collectMissing(members[key]!, candidateMembers[key], path: path.isEmpty ? key : "\(path).\(key)", into: &found, context: context)
            }
        case (.array(let items), .array(let candidateItems)):
            guard let key = elementKey(forArrayAt: path) else {
                if !sameFact(reference, candidate) { found.append((path, "\(describe(reference)) became \(describe(candidate))")) }
                return
            }
            let candidateByKey = Dictionary(keyedElements(candidateItems, key), uniquingKeysWith: { first, _ in first })
            for (elementKey, element) in keyedElements(items, key) {
                collectMissing(element, candidateByKey[elementKey], path: "\(path)[\(elementKey)]", into: &found, context: context)
            }
        case (.string(let textA), .string(let textB)) where !sameFact(reference, candidate):
            // Long texts such as a tool's log, shown from the first character that differs
            // once masked.
            guard case .string(let maskedA) = maskingVariance(.string(textA)),
                  case .string(let maskedB) = maskingVariance(.string(textB)) else { return }
            let common = zip(maskedA, maskedB).prefix { $0 == $1 }.count
            let start = max(0, common - 60)
            func excerpt(_ text: String) -> String { String(text.dropFirst(start).prefix(200)).debugDescription }
            found.append((path, "differs at masked character \(common): \(excerpt(maskedA)) became \(excerpt(maskedB))"))
        default:
            if !sameFact(reference, candidate) { found.append((path, "\(describe(reference)) became \(describe(candidate))")) }
        }
    }

    /// Each element under its key, the n-th element of one identity numbered n.
    static func keyedElements(_ items: [Value], _ key: (Value, Int) -> String) -> [(String, Value)] {
        var occurrences: [String: Int] = [:]
        return items.map { item in
            let base = key(item, 0)
            occurrences[base, default: 0] += 1
            return (key(item, occurrences[base]!), item)
        }
    }

    /// Whether two values are the same fact: equal, or equal once UUIDs and measured times and
    /// rates are masked in every string.
    static func sameFact(_ reference: Value, _ candidate: Value) -> Bool {
        reference == candidate || maskingVariance(reference) == maskingVariance(candidate)
    }

    static func maskingVariance(_ value: Value) -> Value {
        switch value {
        case .string(let text):
            // EsViritu wraps long log lines, which can split a path, so the writer sanitizes
            // only the part before the break and each side's own root stays in the text. The
            // comparison joins the lines and masks everything up to the project folder.
            let joined = text.replacingOccurrences(of: "\n", with: "")
            let rootless = joined.replacingOccurrences(
                of: "[^\\s\"']*\(NSRegularExpression.escapedPattern(for: ClassifierParityFixtures.projectName))",
                with: "<PROJECT>",
                options: .regularExpression
            )
            return .string(maskedMeasurements(maskedID(rootless)))
        case .array(let items): return .array(items.map(maskingVariance))
        case .object(let members): return .object(members.mapValues(maskingVariance))
        default: return value
        }
    }

    /// Wall times and rates tools print, after scripts/golden/normalize.py (the tool log
    /// durations and rules R6 and R7).
    static func maskedMeasurements(_ text: String) -> String {
        measuredText.reduce(text) { result, rule in
            rule.pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: rule.template
            )
        }
    }

    private static let number = "[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"
    private static let measuredText: [(pattern: NSRegularExpression, template: String)] = [
        // The contract's ISO timestamp mask, which also covers a log line's "2026-10-11 10:08:20,307".
        ("(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9]{2}[:\\-][0-9]{2}(?:[:\\-][0-9]{2}(?:[.,][0-9]+)?)?(?:Z|[+\\-][0-9]{2}:?[0-9]{2})?)?(?![0-9])", "<TIMESTAMP>"),
        ("(Completed [A-Za-z0-9_]+ in )\(number)( seconds)", "$1<DURATION>$2"),
        ("(finished in )\(number)( seconds)", "$1<DURATION>$2"),
        ("(EsViritu run for [^\\n]+ finished in )[0-9]{2}:[0-9]{2}:[0-9]{2}", "$1<DURATION>"),
        ("(time used: )[0-9]+( seconds)", "$1<DURATION>$2"),
        ("(Real time: )\(number)( sec)", "$1<DURATION>$2"),
        ("(processed in )\(number)(s )", "$1<DURATION>$2"),
        ("(completed in )\(number)(s\\b)", "$1<DURATION>$2"),
        ("(Runtime: )\(number)(s\\b)", "$1<DURATION>$2"),
        ("(\\[M::[A-Za-z0-9_]+::)\(number)\\*\(number)(\\])", "$1<DURATION>*<RATIO>$2"),
        ("(; CPU: )\(number)( sec; Peak RSS: )\(number)( GB)", "$1<CPU>$2<RSS>$3"),
        ("\\(\(number) Kseq(\\\\?/)m, \(number) Mbp(\\\\?/)m\\)", "(<RATE> Kseq$1m, <RATE> Mbp$2m)"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func text(_ value: Value) -> String {
        switch value {
        case .string(let string): return string
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        case .bool(let flag): return String(flag)
        case .null: return "null"
        case .array, .object: return describe(value)
        }
    }

    static func describe(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<unprintable>" }
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 240 ? String(text.prefix(240)) + "..." : text
    }

    // MARK: - Ids

    /// `text` with the values that change from run to run masked, so an id names the same
    /// difference in every run: UUIDs, the analysis folder's timestamp and ISO dates.
    static func maskedID(_ text: String) -> String {
        idMasks.reduce(text) { result, mask in
            mask.0.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: mask.1
            )
        }
    }

    private static let idMasks: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"), "<UUID>"),
        (try! NSRegularExpression(pattern: "<UUID-[0-9]+>"), "<UUID>"),
        (try! NSRegularExpression(pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}[-:][0-9]{2}[-:][0-9]{2}(?:\\.[0-9]+)?Z?"), "<TS>"),
    ]
}
