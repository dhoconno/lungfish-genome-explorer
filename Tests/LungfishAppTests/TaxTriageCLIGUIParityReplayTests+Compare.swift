// TaxTriageCLIGUIParityReplayTests+Compare.swift - What two sides of a TaxTriage parity case must share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The comparison classes of the classifier parity (ClassifierCLIGUIParityReplayTests+Compare.swift,
// 2.7 T2), applied to two TaxTriage side runs.
//
// - The analysis folder, through `OutputEquivalence.differences(kind: .bundle)` with the classifier
//   parity's masks (`ClassifierParityComparison.maskPolicy(sideRoots:)`), so `taxtriage.sqlite`
//   compares as a sorted dump and the side roots, UUIDs and times are masked.
// - The source bundles' analyses-manifest.json, under the same masks.
// - The input bundles under `Imports/`, byte for byte but for the case's own source manifests.
// - The rest of the project outside `Imports/` and the analysis folders, so a stray write shows.
// - Every provenance record found on both sides, by its facts. Each fact of the reference side
//   must appear with an equal value on the other side, and facts the other side adds pass.
// - The terminal state, in the words of a row.
//
// The masks and the fact rules are the classifier parity's own static helpers, so a change to
// them moves the counts of both classes. The A against C mask of each side's own LGE version
// (ruling R1 of Phase 2.8) is left to lane Q1b, which adds side C.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// One way two sides of a case differ, or one fixed fact a side does not hold.
struct TaxTriageParityDifference: Hashable, Sendable, CustomStringConvertible {
    /// The class of the difference, then the masked path of the file or fact.
    let id: String
    /// What differs, with the values, for the failure message.
    let detail: String

    var description: String { detail.isEmpty ? id : "\(id)\n        \(detail)" }
}

enum TaxTriageParityComparison {
    typealias Value = ProvenanceCompatFacts.Value
    /// The classifier parity's masks and fact rules, shared so both parities mask alike.
    typealias Rules = ClassifierParityComparison

    /// How `candidate` differs from `reference`.
    static func differences(
        reference: TaxTriageParitySideRun,
        candidate: TaxTriageParitySideRun,
        bundlePaths: [String]
    ) throws -> [TaxTriageParityDifference] {
        if case .notRun(let reason) = candidate.terminal {
            return [TaxTriageParityDifference(id: "command: \(candidate.side) has no command to run", detail: reason)]
        }
        var found: [TaxTriageParityDifference] = []
        let outcomes = (outcome(of: reference), outcome(of: candidate))
        if outcomes.0 != outcomes.1 {
            found.append(TaxTriageParityDifference(
                id: "terminal: \(reference.side) and \(candidate.side) end differently",
                detail: "\(reference.side) \(reference.terminal) (\(outcomes.0)), \(candidate.side) \(candidate.terminal) (\(outcomes.1))"
            ))
        }
        found += try folderDifferences(reference, candidate, bundlePaths: bundlePaths)
        found += try recordDifferences(reference, candidate)
        return found
    }

    /// A run's end in the words of a row. Exit 0 reads Completed, or Completed with Warnings when
    /// its result holds an ignored task failure or a failed sample, exit 125 reads Cancelled, and
    /// any other end Failed.
    static func outcome(of run: TaxTriageParitySideRun) -> String {
        switch run.terminal {
        case .row(let label):
            return label
        case .exit(0):
            let result = run.analysisFolder.flatMap { try? TaxTriageResult.load(from: $0) }
            let warns = result.map { $0.hasIgnoredFailures || $0.hasSampleFailures } ?? false
            return warns ? "Completed with Warnings" : "Completed"
        case .exit(125):
            return "Cancelled"
        case .exit, .error:
            return "Failed"
        case .notRun(let reason):
            return "Not run, \(reason)"
        }
    }

    // MARK: - Folders

    static func folderDifferences(
        _ reference: TaxTriageParitySideRun,
        _ candidate: TaxTriageParitySideRun,
        bundlePaths: [String]
    ) throws -> [TaxTriageParityDifference] {
        let policy = Rules.maskPolicy(sideRoots: [reference.root, candidate.root])
        let fileManager = FileManager.default
        var found: [TaxTriageParityDifference] = []

        func existing(_ folder: URL?) -> URL? { folder.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil } }
        switch (existing(reference.analysisFolder), existing(candidate.analysisFolder)) {
        case let (folderA?, folderB?):
            let lines = try OutputEquivalence.differences(folderA, folderB, kind: .bundle, masks: policy)
            found += lines.compactMap { parse($0, as: "analysis", reference: reference.side, candidate: candidate.side) }
        case (_?, nil):
            found.append(TaxTriageParityDifference(id: "analysis: only \(reference.side) keeps its analysis folder", detail: ""))
        case (nil, let folder?):
            found.append(TaxTriageParityDifference(id: "analysis: only \(candidate.side) keeps its analysis folder", detail: folder.lastPathComponent))
        case (nil, nil):
            break
        }

        for bundle in bundlePaths {
            let name = "\(bundle)/\(AnalysisManifest.filename)"
            let fileA = reference.project.appendingPathComponent(name)
            let fileB = candidate.project.appendingPathComponent(name)
            switch (fileManager.fileExists(atPath: fileA.path), fileManager.fileExists(atPath: fileB.path)) {
            case (true, false):
                found.append(TaxTriageParityDifference(id: "source manifest: only in \(reference.side): \(name)", detail: ""))
            case (false, true):
                found.append(TaxTriageParityDifference(id: "source manifest: only in \(candidate.side): \(name)", detail: ""))
            case (true, true):
                let lines = try OutputEquivalence.differences(fileA, fileB, kind: .bundle, masks: policy)
                found += lines.map { TaxTriageParityDifference(id: "source manifest: differs: \(name)", detail: $0) }
            case (false, false):
                break
            }
        }

        // Both sides start from one copy, so the inputs compare byte for byte, UUIDs included.
        // Only the source manifests of the case's own bundles are left out, compared above, so a
        // write to another bundle or folder of `Imports/` shows.
        var inputPolicy = policy
        for unmasked in ["uuids", "runIDs"] {
            inputPolicy.records.removeAll { $0.name == unmasked }
            inputPolicy.provenance.removeAll { $0.name == unmasked }
            inputPolicy.names.removeAll { $0.name == unmasked }
            inputPolicy.payloads.removeAll { $0.name == unmasked }
        }
        let importsA = reference.project.appendingPathComponent("Imports", isDirectory: true)
        let importsB = candidate.project.appendingPathComponent("Imports", isDirectory: true)
        let sourceManifests = Set(bundlePaths.map { "\($0.dropFirst("Imports/".count))/\(AnalysisManifest.filename)" })
        let inputLines = try OutputEquivalence.differences(importsA, importsB, kind: .bundle, masks: inputPolicy)
        found += inputLines
            .filter { !sourceManifests.contains(Rules.comparedPath(of: $0)) }
            .compactMap { parse($0, as: "inputs", reference: reference.side, candidate: candidate.side) }

        // The rest of the project.
        let analysisFolders = [reference, candidate].compactMap(\.analysisPath).map {
            String($0.dropFirst(ClassifierParityFixtures.projectName.count + 1)) + "/"
        }
        let projectLines = try OutputEquivalence.differences(reference.project, candidate.project, kind: .bundle, masks: policy)
        found += projectLines
            .filter { line in
                let path = Rules.comparedPath(of: line)
                return !path.hasPrefix("Imports/") && !analysisFolders.contains { path.hasPrefix($0) }
            }
            .compactMap { parse($0, as: "project", reference: reference.side, candidate: candidate.side) }
        return found
    }

    /// One `OutputEquivalence` line as a difference of class `kind`, or nil for a provenance
    /// record's bytes, which the record comparison covers.
    static func parse(
        _ line: String,
        as kind: String,
        reference: TaxTriageParitySide,
        candidate: TaxTriageParitySide
    ) -> TaxTriageParityDifference? {
        var parts = line.components(separatedBy: "\n")
        let head = parts.removeFirst()
        let detail = parts.joined(separator: "\n        ")
        for (prefix, side) in [("only in A: ", reference), ("only in B: ", candidate)] where head.hasPrefix(prefix) {
            return TaxTriageParityDifference(id: "\(kind): only in \(side): \(Rules.maskedID(String(head.dropFirst(prefix.count))))", detail: "")
        }
        if head.hasPrefix("differs: ") {
            let name = String(head.dropFirst("differs: ".count))
            if Rules.isRecordName(name) { return nil }
            let what = Rules.isSQLiteName(name) ? "SQLite dump differs" : "differs"
            return TaxTriageParityDifference(id: "\(kind): \(what): \(Rules.maskedID(name))", detail: detail)
        }
        return TaxTriageParityDifference(id: "\(kind): \(Rules.maskedID(head))", detail: detail)
    }

    // MARK: - Records

    static func recordDifferences(
        _ reference: TaxTriageParitySideRun,
        _ candidate: TaxTriageParitySideRun
    ) throws -> [TaxTriageParityDifference] {
        // Records pair by their path relative to the side root.
        let candidateRecords = Set(Rules.recordPaths(under: candidate.root))
        let context = FactContext(reference: reference, candidate: candidate)
        var found: [TaxTriageParityDifference] = []
        for path in Rules.recordPaths(under: reference.root) where candidateRecords.contains(path) {
            var missing: [(path: String, detail: String)] = []
            collectMissing(
                try factsTree(of: reference, record: path),
                try factsTree(of: candidate, record: path),
                path: "",
                into: &missing,
                context: context
            )
            found += missing.map {
                TaxTriageParityDifference(id: "record \(Rules.maskedID(path)): \(Rules.maskedID($0.path))", detail: $0.detail)
            }
        }
        return found
    }

    /// The facts of one record as a value tree.
    ///
    /// Side B runs its command in this process. A record that holds the test process's argv,
    /// where the shipped binary holds its own, gets the argv of the line that wrote it instead,
    /// after both pass through what the writer and the reader do to an argv
    /// (`PortablePath.sanitize`, `PortablePath.resolve`, then the facts' `PathNormalizer`), as an
    /// array and in the joined form of `reproducibleCommand`.
    static func factsTree(of run: TaxTriageParitySideRun, record relativePath: String) throws -> Value {
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
        return Rules.replacing(recorded(CommandLine.arguments), with: recorded(argv), in: tree)
    }

    /// The argv of the replayed line whose output folder holds `file`, the longest match.
    static func replayedArgv(of run: TaxTriageParitySideRun, writing file: URL) -> [String]? {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return run.replayedCommands
            .map { (folder: URL(fileURLWithPath: $0.outputFolder).resolvingSymlinksInPath().standardizedFileURL.path, argv: $0.argv) }
            .filter { !$0.folder.isEmpty && path.hasPrefix($0.folder + "/") }
            .max { $0.folder.count < $1.folder.count }?
            .argv
    }

    /// What the containment walk knows about the two sides.
    struct FactContext {
        let reference: TaxTriageParitySideRun
        let candidate: TaxTriageParitySideRun

        /// Whether a recorded path names a file in the project that both projects hold, whose
        /// content the folder comparison owns.
        func namesFileInBothTrees(_ recordedPath: String) -> Bool {
            guard let relative = projectRelative(recordedPath) else { return false }
            return FileManager.default.fileExists(atPath: reference.project.appendingPathComponent(relative).path)
                && FileManager.default.fileExists(atPath: candidate.project.appendingPathComponent(relative).path)
        }

        /// Whether a recorded path names a file in the project that neither project holds any more.
        func namesFileInNeitherTree(_ recordedPath: String) -> Bool {
            guard let relative = projectRelative(recordedPath) else { return false }
            return !FileManager.default.fileExists(atPath: reference.project.appendingPathComponent(relative).path)
                && !FileManager.default.fileExists(atPath: candidate.project.appendingPathComponent(relative).path)
        }

        private func projectRelative(_ recordedPath: String) -> String? {
            let token = "<project>/"
            return recordedPath.hasPrefix(token) ? String(recordedPath.dropFirst(token.count)) : nil
        }
    }

    /// Adds to `found` every leaf of `reference` that `candidate` lacks or holds with another
    /// value, by its path. Measured facts and the host values under `recorded` are left out, and
    /// so are the checksum and size of a file both trees hold or neither holds any more.
    static func collectMissing(
        _ reference: Value,
        _ candidate: Value?,
        path: String,
        into found: inout [(path: String, detail: String)],
        context: FactContext
    ) {
        let last = path.split(separator: ".").last.map(String.init) ?? path
        if path == "recorded" || Rules.measuredFacts.contains(last) { return }
        guard let candidate else {
            found.append((path, "absent from \(context.candidate.side), \(context.reference.side) holds \(Rules.describe(reference))"))
            return
        }
        switch (reference, candidate) {
        case (.object(var members), .object(let candidateMembers)):
            if case .string(let filePath)? = members["path"], members["role"] != nil,
               context.namesFileInBothTrees(filePath) || context.namesFileInNeitherTree(filePath) {
                members["sha256"] = nil
                members["size"] = nil
            }
            for key in members.keys.sorted() {
                collectMissing(members[key]!, candidateMembers[key], path: path.isEmpty ? key : "\(path).\(key)", into: &found, context: context)
            }
        case (.array(let items), .array(let candidateItems)):
            guard let key = Rules.elementKey(forArrayAt: path) else {
                if !Rules.sameFact(reference, candidate) { found.append((path, "\(Rules.describe(reference)) became \(Rules.describe(candidate))")) }
                return
            }
            let candidateByKey = Dictionary(Rules.keyedElements(candidateItems, key), uniquingKeysWith: { first, _ in first })
            for (elementKey, element) in Rules.keyedElements(items, key) {
                collectMissing(element, candidateByKey[elementKey], path: "\(path)[\(elementKey)]", into: &found, context: context)
            }
        case (.string(let textA), .string(let textB)) where !Rules.sameFact(reference, candidate):
            // Long texts such as a tool's log, shown from the first character that differs once masked.
            guard case .string(let maskedA) = Rules.maskingVariance(.string(textA)),
                  case .string(let maskedB) = Rules.maskingVariance(.string(textB)) else { return }
            let common = zip(maskedA, maskedB).prefix { $0 == $1 }.count
            let start = max(0, common - 60)
            func excerpt(_ text: String) -> String { String(text.dropFirst(start).prefix(200)).debugDescription }
            found.append((path, "differs at masked character \(common): \(excerpt(maskedA)) became \(excerpt(maskedB))"))
        default:
            if !Rules.sameFact(reference, candidate) { found.append((path, "\(Rules.describe(reference)) became \(Rules.describe(candidate))")) }
        }
    }
}
