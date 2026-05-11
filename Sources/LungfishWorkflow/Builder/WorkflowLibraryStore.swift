// WorkflowLibraryStore.swift - Project workflow library persistence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public struct WorkflowLibraryEntry: Sendable, Equatable, Identifiable {
    public let bundleURL: URL
    public let graphID: UUID
    public let name: String
    public let description: String?
    public let version: String
    public let modifiedAt: Date

    public var id: String { bundleURL.standardizedFileURL.path }

    public init(bundleURL: URL, graph: WorkflowGraph) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.graphID = graph.id
        self.name = graph.name
        self.description = graph.description
        self.version = graph.version
        self.modifiedAt = graph.modifiedAt
    }
}

public struct WorkflowLibraryProvenance: Codable, Sendable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let workflowName: String
    public let graphID: UUID
    public let savedAt: Date
    public let argv: [String]
    public let command: String
    public let outputPath: String
    public let files: [WorkflowLibraryFileProvenance]
    public let exitStatus: Int
}

public struct WorkflowLibraryFileProvenance: Codable, Sendable, Equatable {
    public let path: String
    public let size: UInt64
    public let sha256: String
}

public enum WorkflowLibraryStore {
    public static let workflowsDirectoryName = "Workflows"
    public static let workflowBundleExtension = "lungfishflow"
    public static let graphFilename = "graph.json"
    public static let workflowFilename = "workflow.json"
    public static let provenanceFilename = "provenance.json"

    public static func libraryDirectory(in projectURL: URL) -> URL {
        projectURL.standardizedFileURL.appendingPathComponent(workflowsDirectoryName, isDirectory: true)
    }

    public static func listWorkflows(in projectURL: URL) throws -> [WorkflowLibraryEntry] {
        let directory = libraryDirectory(in: projectURL)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { $0.pathExtension.lowercased() == workflowBundleExtension }
            .map { url in
                WorkflowLibraryEntry(bundleURL: url, graph: try loadWorkflow(from: url))
            }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.bundleURL.path.localizedStandardCompare(rhs.bundleURL.path) == .orderedAscending
            }
    }

    public static func loadWorkflow(from url: URL) throws -> WorkflowGraph {
        let data = try Data(contentsOf: workflowJSONURL(for: url))
        let decoder = JSONDecoder()
        return try decoder.decode(WorkflowGraph.self, from: data)
    }

    @discardableResult
    public static func createWorkflow(_ graph: WorkflowGraph, in projectURL: URL) throws -> URL {
        try saveWorkflow(graph, to: uniqueBundleURL(named: graph.name, in: projectURL))
    }

    @discardableResult
    public static func saveWorkflow(_ graph: WorkflowGraph, to requestedURL: URL) throws -> URL {
        let bundleURL = normalizedWorkflowBundleURL(for: requestedURL)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let graphData = try encoder.encode(graph)
        let graphURL = bundleURL.appendingPathComponent(graphFilename)
        try graphData.write(to: graphURL, options: .atomic)
        let workflowURL = bundleURL.appendingPathComponent(workflowFilename)
        try graphData.write(to: workflowURL, options: .atomic)

        let historyURL = try appendWorkflowVersionHistory(for: graph, in: bundleURL)
        let historyData = try Data(contentsOf: historyURL)
        let provenance = WorkflowLibraryProvenance(
            toolName: "Workflow Builder",
            toolVersion: WorkflowRun.currentAppVersion,
            workflowName: graph.name,
            graphID: graph.id,
            savedAt: Date(),
            argv: ["Lungfish", "Tools > Workflow Builder", "Save"],
            command: ["Lungfish", "Tools > Workflow Builder", "save", bundleURL.path].map(shellEscape).joined(separator: " "),
            outputPath: bundleURL.path,
            files: [
                WorkflowLibraryFileProvenance(
                    path: graphFilename,
                    size: fileSize(at: graphURL, fallback: UInt64(graphData.count)),
                    sha256: sha256Hex(graphData)
                ),
                WorkflowLibraryFileProvenance(
                    path: workflowFilename,
                    size: fileSize(at: workflowURL, fallback: UInt64(graphData.count)),
                    sha256: sha256Hex(graphData)
                ),
                WorkflowLibraryFileProvenance(
                    path: "versions/history.json",
                    size: fileSize(at: historyURL, fallback: UInt64(historyData.count)),
                    sha256: sha256Hex(historyData)
                ),
            ],
            exitStatus: 0
        )
        try encoder.encode(provenance).write(to: bundleURL.appendingPathComponent(provenanceFilename), options: .atomic)
        return bundleURL
    }

    @discardableResult
    public static func duplicateWorkflow(at sourceURL: URL, in projectURL: URL) throws -> URL {
        let source = try loadWorkflow(from: sourceURL)
        let duplicate = source.copying(name: "\(source.name) Copy")
        return try saveWorkflow(duplicate, to: uniqueBundleURL(named: duplicate.name, in: projectURL))
    }

    @discardableResult
    public static func renameWorkflow(at sourceURL: URL, to name: String, in projectURL: URL) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "Workflow names cannot be empty."])
        }

        let sourceBundleURL = normalizedWorkflowBundleURL(for: sourceURL)
        var graph = try loadWorkflow(from: sourceBundleURL)
        graph.name = trimmedName

        let destinationURL = uniqueBundleURL(
            named: trimmedName,
            in: projectURL,
            excluding: sourceBundleURL
        )

        if destinationURL.standardizedFileURL.path != sourceBundleURL.standardizedFileURL.path {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: sourceBundleURL, to: destinationURL)
        }

        return try saveWorkflow(graph, to: destinationURL)
    }

    public static func deleteWorkflow(at url: URL) throws {
        let bundleURL = normalizedWorkflowBundleURL(for: url)
        guard bundleURL.pathExtension.lowercased() == workflowBundleExtension else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: bundleURL.path])
        }
        try FileManager.default.removeItem(at: bundleURL)
    }

    public static func normalizedWorkflowBundleURL(for url: URL) -> URL {
        if url.pathExtension.lowercased() == workflowBundleExtension {
            return url.standardizedFileURL
        }
        return url.deletingPathExtension().appendingPathExtension(workflowBundleExtension).standardizedFileURL
    }

    public static func workflowJSONURL(for url: URL) throws -> URL {
        let normalizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: normalizedURL.path])
        }
        guard isDirectory.boolValue else { return normalizedURL }
        let candidates = [
            normalizedURL.appendingPathComponent(graphFilename),
            normalizedURL.appendingPathComponent(workflowFilename),
        ]
        if let candidate = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return candidate
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: normalizedURL.appendingPathComponent(graphFilename).path])
    }

    private static func uniqueBundleURL(named name: String, in projectURL: URL, excluding excludedURL: URL? = nil) -> URL {
        let directory = libraryDirectory(in: projectURL)
        let base = sanitizedWorkflowFilename(name)
        var candidate = directory.appendingPathComponent("\(base).\(workflowBundleExtension)", isDirectory: true)
        var suffix = 2
        let excludedPath = excludedURL?.standardizedFileURL.path
        while FileManager.default.fileExists(atPath: candidate.path)
            && candidate.standardizedFileURL.path != excludedPath {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(workflowBundleExtension)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func appendWorkflowVersionHistory(for graph: WorkflowGraph, in bundleURL: URL) throws -> URL {
        let historyDirectory = bundleURL.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var history = (try? decoder.decode([WorkflowVersionHistoryEntry].self, from: Data(contentsOf: historyURL))) ?? []
        history.append(WorkflowVersionHistoryEntry(version: graph.version, savedAt: Date(), workflowName: graph.name))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: historyURL, options: .atomic)
        return historyURL
    }

    private static func sanitizedWorkflowFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "workflow" : collapsed.replacingOccurrences(of: " ", with: "-")
    }

    private static func fileSize(at url: URL, fallback: UInt64) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? fallback
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func shellEscape(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct WorkflowVersionHistoryEntry: Codable {
    let version: String
    let savedAt: Date
    let workflowName: String
}
