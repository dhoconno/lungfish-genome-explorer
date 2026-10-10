// ProvenanceCompatSweep.swift - Reader-only sweep of the provenance sidecars under folders the caller names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The corpus freezes a few dozen records. A sweep applies the same reader calls to every sidecar
// found under folders the caller names, such as a managed storage root, a cache of demo projects
// or a copy of a research project, and writes one report. Running it at the base commit and again
// at the final commit and comparing the two reports shows that no real record reads differently.
//
// A sweep only reads. It never audits, rehydrates, repairs or writes inside a swept folder, and the
// report folder must lie outside every git work tree and outside every swept folder. The report holds
// paths relative to each root, so it does not depend on where the roots are mounted, and it holds no
// date, so two sweeps of unchanged data produce identical bytes.

import CryptoKit
import Foundation
import LungfishCore

public struct ProvenanceCompatSweepReport: Codable, Equatable, Sendable {
    /// One provenance sidecar found under a root.
    public struct Entry: Codable, Equatable, Sendable {
        /// Position of the root in the list the sweep was given.
        public var root: Int
        /// The sidecar's path relative to its root, or its file name when the root is the sidecar itself.
        public var path: String
        /// `folder` for a `.lungfish-provenance.json` file, `file` for `<name>.lungfish-provenance.json`.
        public var kind: String
        public var bytes: Int
        /// SHA-256 of the file's bytes, so a change to the swept data shows apart from a change to a reader.
        public var sha256: String
        /// `read` when the production readers accepted the file, `unreadable` when none did.
        public var outcome: String
        public var decodedBy: String?
        public var strictAccepts: Bool?
        public var readStatus: String?
        public var workflowName: String?
        public var toolName: String?
        public var stepCount: Int?
        /// SHA-256 of the canonical facts JSON, which covers everything the readers say about the file.
        public var factsSHA256: String?
        /// For an unreadable file, the kind of failure and the JSON keys involved, never a path.
        public var error: String?
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var total: Int
        public var read: Int
        public var unreadable: Int
        public var strictAccepted: Int
        public var byDecoder: [String: Int]
    }

    public static let currentReportVersion = 1

    public var reportVersion: Int
    public var factsVersion: Int
    /// The roots as the caller named them, in order.
    public var roots: [String]
    public var entries: [Entry]
    public var summary: Summary

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

public enum ProvenanceCompatSweep {
    /// Colon-separated folders (or single sidecars) to sweep. A leading `~` is the home folder.
    public static let rootsVariable = "LUNGFISH_PROVENANCE_SWEEP_ROOTS"
    /// The folder that receives the report. It must lie outside every git work tree and every root.
    public static let outputVariable = "LUNGFISH_PROVENANCE_SWEEP_OUT"
    public static let reportFilename = "provenance-sweep-report.json"
    /// Folder names the walk does not enter, because they hold version control or build output.
    public static let skippedFolderNames: Set<String> = [".git", ".build", "node_modules"]

    /// True when both variables name something, which is what enables the sweep test.
    public static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return !(environment[rootsVariable] ?? "").isEmpty && !(environment[outputVariable] ?? "").isEmpty
    }

    public struct Configuration: Sendable, Equatable {
        /// The roots as the caller named them.
        public var labels: [String]
        public var roots: [URL]
        public var outputFolder: URL
    }

    public enum SweepError: Error, LocalizedError, Equatable {
        case noRoots
        case missingRoot(String)
        case outputInsideRepository(String)
        case outputInsideRoot(String)

        public var errorDescription: String? {
            switch self {
            case .noRoots:
                return "No sweep root is named in \(ProvenanceCompatSweep.rootsVariable)"
            case .missingRoot(let label):
                return "The sweep root does not exist: \(label)"
            case .outputInsideRepository(let path):
                return "The report folder must lie outside every git work tree, and this one does not: \(path)"
            case .outputInsideRoot(let path):
                return "The report folder must lie outside every swept folder, and this one does not: \(path)"
            }
        }
    }

    // MARK: Configuration

    /// Reads the two variables, expands `~`, and checks that every root exists and the report folder
    /// is acceptable. Nothing is created.
    public static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) throws -> Configuration {
        let labels = splitRoots(environment[rootsVariable] ?? "")
        guard !labels.isEmpty else { throw SweepError.noRoots }
        var roots: [URL] = []
        for label in labels {
            let url = URL(fileURLWithPath: expandingTilde(label, homeDirectory: homeDirectory))
            guard FileManager.default.fileExists(atPath: url.path) else { throw SweepError.missingRoot(label) }
            roots.append(url)
        }
        let output = URL(
            fileURLWithPath: expandingTilde(environment[outputVariable] ?? "", homeDirectory: homeDirectory),
            isDirectory: true
        )
        try validateOutputFolder(output, roots: roots)
        return Configuration(labels: labels, roots: roots, outputFolder: output)
    }

    /// The non-empty, trimmed, colon-separated entries of a roots value.
    public static func splitRoots(_ value: String) -> [String] {
        value.split(separator: ":", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func expandingTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory + String(path.dropFirst(1)) }
        return path
    }

    /// Refuses a report folder inside a git work tree, inside the checkout that holds this corpus,
    /// or inside a swept root. A folder that does not exist yet is judged by its nearest existing parent.
    public static func validateOutputFolder(_ folder: URL, roots: [URL]) throws {
        let path = CanonicalFilePath.path(for: folder)
        if CanonicalFilePath.isPath(folder, within: ProvenanceCompatCorpus.repositoryRoot)
            || hasGitAncestor(ofCanonicalPath: path) {
            throw SweepError.outputInsideRepository(path)
        }
        for root in roots where CanonicalFilePath.isPath(folder, within: root) {
            throw SweepError.outputInsideRoot(path)
        }
    }

    private static func hasGitAncestor(ofCanonicalPath path: String) -> Bool {
        var candidate = URL(fileURLWithPath: path)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) { return true }
            if candidate.path == "/" || candidate.pathComponents.count <= 1 { return false }
            candidate = candidate.deletingLastPathComponent()
        }
    }

    // MARK: Sweep

    /// Sweeps `roots` with the production readers and returns the report. It never throws and never
    /// writes. A file no reader accepts becomes an `unreadable` entry.
    public static func run(roots: [URL], labels: [String]) -> ProvenanceCompatSweepReport {
        var entries: [ProvenanceCompatSweepReport.Entry] = []
        for (index, root) in roots.enumerated() {
            let resolvedRoot = CanonicalFilePath.url(for: root)
            for sidecar in sidecars(under: resolvedRoot) {
                entries.append(entry(for: sidecar, rootIndex: index, root: resolvedRoot))
            }
        }
        entries.sort { ($0.root, $0.path) < ($1.root, $1.path) }
        return ProvenanceCompatSweepReport(
            reportVersion: ProvenanceCompatSweepReport.currentReportVersion,
            factsVersion: ProvenanceCompatFacts.currentFactsVersion,
            roots: labels,
            entries: entries,
            summary: summary(of: entries)
        )
    }

    /// Writes the report as `provenance-sweep-report.json` in `folder` and returns its URL. An earlier
    /// report in the same folder is replaced.
    @discardableResult
    public static func write(_ report: ProvenanceCompatSweepReport, to folder: URL, roots: [URL]) throws -> URL {
        try validateOutputFolder(folder, roots: roots)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(reportFilename)
        try report.canonicalJSON().write(to: url, options: .atomic)
        return url
    }

    // MARK: Discovery

    static func isSidecarName(_ name: String) -> Bool {
        name.hasSuffix(ProvenanceCompatCorpus.sidecarFilename)
    }

    /// Regular files named `.lungfish-provenance.json` or `<name>.lungfish-provenance.json` under
    /// `root`, which may itself be one sidecar. Symbolic links are not followed.
    static func sidecars(under root: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return isSidecarName(root.lastPathComponent) ? [root] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skippedFolderNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true, isSidecarName(url.lastPathComponent) { found.append(url) }
        }
        return found
    }

    // MARK: Entries

    private static func entry(for url: URL, rootIndex: Int, root: URL) -> ProvenanceCompatSweepReport.Entry {
        let relative = CanonicalFilePath.relativePath(of: url, within: root) ?? ""
        var entry = ProvenanceCompatSweepReport.Entry(
            root: rootIndex,
            path: relative.isEmpty ? url.lastPathComponent : relative,
            kind: url.lastPathComponent == ProvenanceCompatCorpus.sidecarFilename ? "folder" : "file",
            bytes: 0,
            sha256: "",
            outcome: "unreadable"
        )
        guard let data = try? Data(contentsOf: url) else {
            entry.error = "file could not be read"
            return entry
        }
        entry.bytes = data.count
        entry.sha256 = ProvenanceCompatCorpus.sha256Hex(data)
        do {
            let facts = try ProvenanceCompatFacts.project(sidecar: url, projectRoot: projectRoot(for: url))
            entry.outcome = "read"
            entry.decodedBy = facts.decodedBy.rawValue
            entry.strictAccepts = facts.strictAccepts
            entry.readStatus = facts.readStatus
            entry.workflowName = facts.workflowName
            entry.toolName = facts.toolName
            entry.stepCount = facts.steps.count
            entry.factsSHA256 = ProvenanceCompatCorpus.sha256Hex(try facts.canonicalJSON())
        } catch {
            entry.error = describe(error)
        }
        return entry
    }

    /// The `.lungfish` project that holds `url`, or its own folder when no project holds it.
    private static func projectRoot(for url: URL) -> URL {
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "lungfish" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    /// A failure as the kind of error and the JSON keys involved. It never carries a file path.
    static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            let name: String
            let context: DecodingError.Context
            switch decoding {
            case .keyNotFound(_, let value): (name, context) = ("keyNotFound", value)
            case .typeMismatch(_, let value): (name, context) = ("typeMismatch", value)
            case .valueNotFound(_, let value): (name, context) = ("valueNotFound", value)
            case .dataCorrupted(let value): (name, context) = ("dataCorrupted", value)
            @unknown default: return "DecodingError"
            }
            let keys = context.codingPath
                .map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
                .joined()
            return "DecodingError.\(name)\(keys)"
        }
        if let projection = error as? ProvenanceCompatFacts.ProjectionError {
            switch projection {
            case .missingSidecar: return "ProjectionError.missingSidecar"
            case .notJSONObject: return "ProjectionError.notJSONObject"
            }
        }
        return String(describing: type(of: error))
    }

    private static func summary(of entries: [ProvenanceCompatSweepReport.Entry]) -> ProvenanceCompatSweepReport.Summary {
        var byDecoder: [String: Int] = [:]
        for decoder in entries.compactMap(\.decodedBy) { byDecoder[decoder, default: 0] += 1 }
        return ProvenanceCompatSweepReport.Summary(
            total: entries.count,
            read: entries.filter { $0.outcome == "read" }.count,
            unreadable: entries.filter { $0.outcome == "unreadable" }.count,
            strictAccepted: entries.filter { $0.strictAccepts == true }.count,
            byDecoder: byDecoder
        )
    }
}
