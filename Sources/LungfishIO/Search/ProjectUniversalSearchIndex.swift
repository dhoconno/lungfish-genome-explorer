// ProjectUniversalSearchIndex.swift - SQLite-backed project-scoped universal search catalog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

/// Errors that can occur while building/querying the universal search index.
public enum ProjectUniversalSearchError: Error, LocalizedError, Sendable {
    case databaseOpenFailed(String)
    case databaseQueryFailed(String)
    case invalidProjectDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "Failed to open universal search database: \(message)"
        case .databaseQueryFailed(let message):
            return "Universal search database query failed: \(message)"
        case .invalidProjectDirectory(let url):
            return "Invalid project directory: \(url.path)"
        }
    }
}

/// SQLite-backed universal search catalog for a single project.
///
/// The catalog is scoped to one project directory and stores searchable entities
/// plus typed attributes. Rebuild is currently full-refresh for correctness.
public final class ProjectUniversalSearchIndex {

    // MARK: - Properties

    public let projectURL: URL
    public let databaseURL: URL

    var db: OpaquePointer?

    private static let logger = Logger(
        subsystem: LogSubsystem.io,
        category: "ProjectUniversalSearch"
    )

    // MARK: - Lifecycle

    public init(projectURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectUniversalSearchError.invalidProjectDirectory(projectURL)
        }

        self.projectURL = projectURL.standardizedFileURL
        self.databaseURL = projectURL.appendingPathComponent(".universal-search.db")

        var pointer: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard openResult == SQLITE_OK, let pointer else {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw ProjectUniversalSearchError.databaseOpenFailed(message)
        }

        self.db = pointer

        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA foreign_keys = ON")
            try createSchemaIfNeeded()
        } catch {
            sqlite3_close_v2(pointer)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Public API

    /// Performs a full rebuild of the project search catalog.
    @discardableResult
    public func rebuild() throws -> ProjectUniversalSearchBuildStats {
        let startedAt = Date()

        var entityCount = 0
        var attributeCount = 0
        var perKindCounts: [String: Int] = [:]

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM us_attributes")
            try execute("DELETE FROM us_entities")

            var fastqBundles: [URL] = []
            var referenceBundles: [URL] = []
            var classificationDirs: [URL] = []
            var esVirituDirs: [URL] = []
            var taxTriageDirs: [URL] = []
            var naoMgsDirs: [URL] = []
            var nvdDirs: [URL] = []
            var manifestFiles: [URL] = []

            collectProjectArtifacts(
                fastqBundles: &fastqBundles,
                referenceBundles: &referenceBundles,
                classificationDirs: &classificationDirs,
                esVirituDirs: &esVirituDirs,
                taxTriageDirs: &taxTriageDirs,
                naoMgsDirs: &naoMgsDirs,
                nvdDirs: &nvdDirs,
                manifestFiles: &manifestFiles
            )

            for url in fastqBundles.sorted(by: pathCompare) {
                try indexFASTQBundle(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in referenceBundles.sorted(by: pathCompare) {
                try indexReferenceBundle(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in classificationDirs.sorted(by: pathCompare) {
                try indexClassificationResult(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in esVirituDirs.sorted(by: pathCompare) {
                try indexEsVirituResult(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in taxTriageDirs.sorted(by: pathCompare) {
                try indexTaxTriageResult(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in naoMgsDirs.sorted(by: pathCompare) {
                try indexNaoMgsResult(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in nvdDirs.sorted(by: pathCompare) {
                try indexNvdResult(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            for url in manifestFiles.sorted(by: pathCompare) {
                try indexManifestDocument(
                    at: url,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }

            try setMetadata(key: "last_indexed_at", value: String(Int(Date().timeIntervalSince1970)))

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        let duration = Date().timeIntervalSince(startedAt)
        Self.logger.info("Rebuilt universal search index: \(entityCount) entities, \(attributeCount) attributes in \(String(format: "%.2f", duration))s")

        return ProjectUniversalSearchBuildStats(
            indexedEntities: entityCount,
            indexedAttributes: attributeCount,
            durationSeconds: duration,
            perKindCounts: perKindCounts
        )
    }

    /// Runs a universal search query against the indexed project catalog.
    public func search(_ query: ProjectUniversalSearchQuery) throws -> [ProjectUniversalSearchResult] {
        var sql = """
            SELECT e.id, e.kind, e.title, e.subtitle, e.format, e.url
            FROM us_entities e
        """

        var whereClauses: [String] = []
        var bindings: [Any] = []

        if !query.kinds.isEmpty {
            let placeholders = Array(repeating: "?", count: query.kinds.count).joined(separator: ",")
            whereClauses.append("e.kind IN (\(placeholders))")
            bindings.append(contentsOf: query.kinds.sorted())
        }

        if !query.formats.isEmpty {
            let placeholders = Array(repeating: "?", count: query.formats.count).joined(separator: ",")
            whereClauses.append("e.format IN (\(placeholders))")
            bindings.append(contentsOf: query.formats.sorted())
        }

        for term in query.textTerms where !term.isEmpty {
            whereClauses.append("LOWER(e.search_text) LIKE ? ESCAPE '\\'")
            bindings.append(Self.likeContainsPattern(for: term))
        }

        for filter in query.attributeFilters {
            switch filter.match {
            case .contains:
                whereClauses.append("EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.key = ? AND LOWER(a.value) LIKE ? ESCAPE '\\')")
                bindings.append(filter.key)
                bindings.append(Self.likeContainsPattern(for: filter.value))
            case .exact:
                whereClauses.append("EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.key = ? AND LOWER(a.value) = ?)")
                bindings.append(filter.key)
                bindings.append(filter.value)
            }
        }

        for filter in query.numberFilters {
            let comparatorSQL: String = {
                switch filter.comparison {
                case .greaterThan:
                    return ">"
                case .greaterThanOrEqual:
                    return ">="
                case .lessThan:
                    return "<"
                case .lessThanOrEqual:
                    return "<="
                case .equal:
                    return "="
                case .notEqual:
                    return "!="
                }
            }()

            whereClauses.append(
                "EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.key = ? AND a.number_value IS NOT NULL AND a.number_value \(comparatorSQL) ?)"
            )
            bindings.append(filter.key)
            bindings.append(filter.value)
        }

        if let dateFrom = query.dateFrom {
            whereClauses.append("EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.date_value IS NOT NULL AND a.date_value >= ?)")
            bindings.append(Int64(dateFrom.timeIntervalSince1970))
        }

        if let dateTo = query.dateTo {
            whereClauses.append("EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.date_value IS NOT NULL AND a.date_value <= ?)")
            bindings.append(Int64(dateTo.timeIntervalSince1970))
        }

        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }

        sql += " ORDER BY e.kind ASC, e.title COLLATE NOCASE ASC LIMIT ?"
        bindings.append(query.limit)

        var results: [ProjectUniversalSearchResult] = []
        try queryRows(sql, parameters: bindings) { stmt in
            guard
                let idC = sqlite3_column_text(stmt, 0),
                let kindC = sqlite3_column_text(stmt, 1),
                let titleC = sqlite3_column_text(stmt, 2),
                let urlC = sqlite3_column_text(stmt, 5)
            else {
                return
            }

            let id = String(cString: idC)
            let kind = String(cString: kindC)
            let title = String(cString: titleC)
            let subtitle = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let format = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let path = String(cString: urlC)

            results.append(
                ProjectUniversalSearchResult(
                    id: id,
                    kind: kind,
                    title: title,
                    subtitle: subtitle,
                    format: format,
                    url: URL(fileURLWithPath: path)
                )
            )
        }

        return results
    }

    /// Parses and executes a raw query string.
    public func search(rawQuery: String, limit: Int = 200) throws -> [ProjectUniversalSearchResult] {
        try search(ProjectUniversalSearchQueryParser.parse(rawQuery, limit: limit))
    }

    /// Returns current catalog stats.
    public func indexStats() throws -> ProjectUniversalSearchIndexStats {
        let entityCount = try scalarInt("SELECT COUNT(*) FROM us_entities")
        let attributeCount = try scalarInt("SELECT COUNT(*) FROM us_attributes")

        var perKindCounts: [String: Int] = [:]
        try queryRows("SELECT kind, COUNT(*) FROM us_entities GROUP BY kind") { stmt in
            guard let kindC = sqlite3_column_text(stmt, 0) else { return }
            let kind = String(cString: kindC)
            let count = Int(sqlite3_column_int64(stmt, 1))
            perKindCounts[kind] = count
        }

        let lastIndexedAt: Date?
        if let value = try metadataValue(for: "last_indexed_at"), let seconds = TimeInterval(value) {
            lastIndexedAt = Date(timeIntervalSince1970: seconds)
        } else {
            lastIndexedAt = nil
        }

        return ProjectUniversalSearchIndexStats(
            entityCount: entityCount,
            attributeCount: attributeCount,
            perKindCounts: perKindCounts,
            lastIndexedAt: lastIndexedAt
        )
    }

    // MARK: - Artifact Collection

    private func collectProjectArtifacts(
        fastqBundles: inout [URL],
        referenceBundles: inout [URL],
        classificationDirs: inout [URL],
        esVirituDirs: inout [URL],
        taxTriageDirs: inout [URL],
        naoMgsDirs: inout [URL],
        nvdDirs: inout [URL],
        manifestFiles: inout [URL]
    ) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let fileName = url.lastPathComponent
            var isDirectoryValue = ObjCBool(false)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectoryValue) else { continue }

            if isDirectoryValue.boolValue {
                if url.pathExtension == FASTQBundle.directoryExtension {
                    fastqBundles.append(url)
                    enumerator.skipDescendants()
                    // Scan derivatives/ subfolder for classifier results that live inside FASTQ bundles.
                    let derivativesURL = url.appendingPathComponent("derivatives", isDirectory: true)
                    scanDerivativesForClassifierResults(
                        derivativesURL,
                        classificationDirs: &classificationDirs,
                        esVirituDirs: &esVirituDirs,
                        taxTriageDirs: &taxTriageDirs,
                        naoMgsDirs: &naoMgsDirs,
                        nvdDirs: &nvdDirs
                    )
                    continue
                }

                if url.pathExtension == "lungfishref" {
                    referenceBundles.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                if fileName.hasPrefix("classification-") && hasFile("classification-result.json", in: url) {
                    classificationDirs.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                if fileName.hasPrefix("esviritu-") && hasFile("esviritu-result.json", in: url) {
                    esVirituDirs.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                if fileName.hasPrefix("taxtriage-") && hasFile("taxtriage-result.json", in: url) {
                    taxTriageDirs.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                if fileName.hasPrefix("naomgs-") && hasFile("manifest.json", in: url) {
                    naoMgsDirs.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                if fileName.hasPrefix("nvd-") && hasFile("hits.sqlite", in: url) {
                    nvdDirs.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                continue
            }

            guard url.pathExtension.lowercased() == "json" else { continue }
            if fileName == "manifest.json" || fileName.hasSuffix("-result.json") {
                manifestFiles.append(url)
            }
        }
    }

    /// Scans a FASTQ bundle's derivatives/ directory for classifier result bundles.
    private func scanDerivativesForClassifierResults(
        _ derivativesURL: URL,
        classificationDirs: inout [URL],
        esVirituDirs: inout [URL],
        taxTriageDirs: inout [URL],
        naoMgsDirs: inout [URL],
        nvdDirs: inout [URL]
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: derivativesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent

            if name.hasPrefix("classification-") && hasFile("classification-result.json", in: url) {
                classificationDirs.append(url)
            } else if name.hasPrefix("esviritu-") && hasFile("esviritu-result.json", in: url) {
                esVirituDirs.append(url)
            } else if name.hasPrefix("taxtriage-") && hasFile("taxtriage-result.json", in: url) {
                taxTriageDirs.append(url)
            } else if name.hasPrefix("naomgs-") && hasFile("manifest.json", in: url) {
                naoMgsDirs.append(url)
            } else if name.hasPrefix("nvd-") && hasFile("hits.sqlite", in: url) {
                nvdDirs.append(url)
            }
        }
    }

    // MARK: - Incremental Updates

    /// Deletes all entities whose `rel_path` starts with the given prefix.
    /// Also deletes associated attributes via ON DELETE CASCADE.
    @discardableResult
    public func deleteEntities(matchingPathPrefix prefix: String) throws -> Int {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute(
                "DELETE FROM us_entities WHERE rel_path LIKE ? ESCAPE '\\'",
                parameters: [Self.likePrefixPattern(for: prefix)]
            )
            let changes = sqlite3_changes(db)
            try execute("COMMIT")
            Self.logger.debug("deleteEntities: Removed \(changes) entities matching prefix '\(prefix, privacy: .public)'")
            return Int(changes)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Re-indexes a single artifact at the given URL.
    /// Determines the artifact type and calls the appropriate indexer.
    public func upsertArtifact(at url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            let relPath = relativePath(for: url)
            try deleteEntities(matchingPathPrefix: relPath)
            return
        }

        var entityCount = 0
        var attributeCount = 0
        var perKindCounts: [String: Int] = [:]

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            // Delete existing entries first (clean upsert)
            let relPath = relativePath(for: url)
            try execute(
                "DELETE FROM us_entities WHERE rel_path LIKE ? ESCAPE '\\'",
                parameters: [Self.likePrefixPattern(for: relPath)]
            )

            if isDir.boolValue {
                if url.pathExtension == FASTQBundle.directoryExtension {
                    try indexFASTQBundle(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                } else if url.pathExtension == "lungfishref" {
                    try indexReferenceBundle(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                } else if url.lastPathComponent.hasPrefix("classification-") && hasFile("classification-result.json", in: url) {
                    try indexClassificationResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                } else if url.lastPathComponent.hasPrefix("esviritu-") && hasFile("esviritu-result.json", in: url) {
                    try indexEsVirituResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                } else if url.lastPathComponent.hasPrefix("taxtriage-") && hasFile("taxtriage-result.json", in: url) {
                    try indexTaxTriageResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                } else if url.lastPathComponent.hasPrefix("naomgs-") && hasFile("manifest.json", in: url) {
                    try indexNaoMgsResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                } else if url.lastPathComponent.hasPrefix("nvd-") && hasFile("hits.sqlite", in: url) {
                    try indexNvdResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
                }
            }

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        Self.logger.debug("upsertArtifact: Indexed \(entityCount) entities for \(url.lastPathComponent, privacy: .public)")
    }

    /// Incrementally updates the index for specific changed paths.
    /// For files inside bundles, finds the parent bundle and re-indexes it.
    public func update(changedPaths: [URL]) throws {
        guard !changedPaths.isEmpty else { return }

        Self.logger.debug("update(changedPaths:): Processing \(changedPaths.count) changed paths")

        var bundlesToUpsert: Set<String> = []
        var pathsToProcess: [URL] = []

        for url in changedPaths {
            let pathString = url.standardizedFileURL.path

            if let bundlePath = extractBundlePath(from: pathString) {
                if bundlesToUpsert.insert(bundlePath).inserted {
                    pathsToProcess.append(URL(fileURLWithPath: bundlePath))
                }
            } else {
                pathsToProcess.append(url)
            }
        }

        for url in pathsToProcess {
            try upsertArtifact(at: url)
        }
    }

    /// Extracts the path to the enclosing `.lungfishfastq` or `.lungfishref` bundle.
    private func extractBundlePath(from path: String) -> String? {
        for ext in [".lungfishfastq/", ".lungfishref/"] {
            if let range = path.range(of: ext) {
                return String(path[path.startIndex..<range.upperBound].dropLast())
            }
        }
        if path.hasSuffix(".lungfishfastq") || path.hasSuffix(".lungfishref") {
            return path
        }
        return nil
    }

    private func hasFile(_ filename: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
    }
}
