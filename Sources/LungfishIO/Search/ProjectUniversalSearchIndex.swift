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

    // MARK: - Types

    private struct EntityRow {
        let id: String
        let kind: String
        let title: String
        let subtitle: String?
        let format: String?
        let relPath: String
        let url: URL
        let mtime: Double?
        let sizeBytes: Int64?
    }

    // MARK: - Properties

    public let projectURL: URL
    public let databaseURL: URL

    private var db: OpaquePointer?

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
            var manifestFiles: [URL] = []

            collectProjectArtifacts(
                fastqBundles: &fastqBundles,
                referenceBundles: &referenceBundles,
                classificationDirs: &classificationDirs,
                esVirituDirs: &esVirituDirs,
                taxTriageDirs: &taxTriageDirs,
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
            whereClauses.append("LOWER(e.search_text) LIKE ?")
            bindings.append("%\(term)%")
        }

        for filter in query.attributeFilters {
            switch filter.match {
            case .contains:
                whereClauses.append("EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.key = ? AND LOWER(a.value) LIKE ?)")
                bindings.append(filter.key)
                bindings.append("%\(filter.value)%")
            case .exact:
                whereClauses.append("EXISTS (SELECT 1 FROM us_attributes a WHERE a.entity_id = e.id AND a.key = ? AND LOWER(a.value) = ?)")
                bindings.append(filter.key)
                bindings.append(filter.value)
            }
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

                continue
            }

            guard url.pathExtension.lowercased() == "json" else { continue }
            if fileName == "manifest.json" || fileName.hasSuffix("-result.json") {
                manifestFiles.append(url)
            }
        }
    }

    // MARK: - Indexers

    private func indexFASTQBundle(
        at bundleURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let title = String(bundleURL.deletingPathExtension().lastPathComponent)
        let relPath = relativePath(for: bundleURL)

        let row = entityRow(
            id: "fastq_dataset:\(relPath)",
            kind: "fastq_dataset",
            title: title,
            subtitle: nil,
            format: "fastq",
            url: bundleURL
        )

        var attributes: [String: Any] = [
            "dataset_name": title,
            "bundle_extension": FASTQBundle.directoryExtension,
        ]

        if let csvMetadata = FASTQBundleCSVMetadata.load(from: bundleURL) {
            let sample = FASTQSampleMetadata(from: csvMetadata, fallbackName: title)
            appendFASTQSampleAttributes(sample, to: &attributes)
        }

        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL),
           let sidecar = FASTQMetadataStore.load(for: fastqURL) {
            if let stats = sidecar.computedStatistics {
                attributes["read_count"] = stats.readCount
                attributes["base_count"] = stats.baseCount
                attributes["mean_read_length"] = stats.meanReadLength
                attributes["median_read_length"] = stats.medianReadLength
                attributes["n50_read_length"] = stats.n50ReadLength
                attributes["mean_quality"] = stats.meanQuality
                attributes["q20_percentage"] = stats.q20Percentage
                attributes["q30_percentage"] = stats.q30Percentage
                attributes["gc_content"] = stats.gcContent * 100.0
                attributes["min_read_length"] = stats.minReadLength
                attributes["max_read_length"] = stats.maxReadLength
            }

            if let seqkit = sidecar.seqkitStats {
                attributes["seqkit_num_seqs"] = seqkit.numSeqs
                attributes["seqkit_sum_len"] = seqkit.sumLen
                attributes["seqkit_min_len"] = seqkit.minLen
                attributes["seqkit_avg_len"] = seqkit.avgLen
                attributes["seqkit_max_len"] = seqkit.maxLen
                attributes["seqkit_q20_percentage"] = seqkit.q20Percentage
                attributes["seqkit_q30_percentage"] = seqkit.q30Percentage
                attributes["seqkit_average_quality"] = seqkit.averageQuality
                attributes["seqkit_gc_percentage"] = seqkit.gcPercentage
            }

            if let ingestion = sidecar.ingestion {
                attributes["is_clumpified"] = ingestion.isClumpified
                attributes["is_compressed"] = ingestion.isCompressed
                attributes["pairing_mode"] = ingestion.pairingMode.rawValue
                attributes["quality_binning"] = ingestion.qualityBinning
                attributes["ingestion_date"] = ingestion.ingestionDate
                attributes["original_size_bytes"] = ingestion.originalSizeBytes
            }

            if let source = sidecar.downloadSource {
                attributes["download_source"] = source
            }
            if let downloadDate = sidecar.downloadDate {
                attributes["download_date"] = downloadDate
            }

            if let platform = sidecar.sequencingPlatform {
                attributes["sequencing_platform"] = platform.rawValue
            }

            if let sra = sidecar.sraRunInfo {
                attributes["sra_accession"] = sra.accession
                attributes["sra_experiment"] = sra.experiment
                attributes["sra_sample"] = sra.sample
                attributes["sra_study"] = sra.study
                attributes["sra_bioproject"] = sra.bioproject
                attributes["sra_biosample"] = sra.biosample
                attributes["sra_organism"] = sra.organism
                attributes["sra_platform"] = sra.platform
                attributes["sra_library_strategy"] = sra.libraryStrategy
                attributes["sra_library_layout"] = sra.libraryLayout
                attributes["sra_spots"] = sra.spots
                attributes["sra_bases"] = sra.bases
                attributes["sra_release_date"] = sra.releaseDate
            }

            if let ena = sidecar.enaReadRecord {
                attributes["ena_run_accession"] = ena.runAccession
                attributes["ena_experiment_accession"] = ena.experimentAccession
                attributes["ena_sample_accession"] = ena.sampleAccession
                attributes["ena_study_accession"] = ena.studyAccession
                attributes["ena_experiment_title"] = ena.experimentTitle
                attributes["ena_library_layout"] = ena.libraryLayout
                attributes["ena_library_source"] = ena.librarySource
                attributes["ena_library_strategy"] = ena.libraryStrategy
                attributes["ena_platform"] = ena.instrumentPlatform
                attributes["ena_base_count"] = ena.baseCount
                attributes["ena_read_count"] = ena.readCount
                attributes["ena_first_public"] = ena.firstPublic
            }
        }

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    private func indexReferenceBundle(
        at bundleURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)

        var attributes: [String: Any] = [:]
        if let flattened = flattenJSONFile(at: manifestURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        let bundleTitle: String = {
            if let title = attributes["name"] as? String, !title.isEmpty {
                return title
            }
            return bundleURL.deletingPathExtension().lastPathComponent
        }()

        let row = entityRow(
            id: "reference_bundle:\(relPath)",
            kind: "reference_bundle",
            title: bundleTitle,
            subtitle: nil,
            format: "reference",
            url: bundleURL
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        guard let manifest = try? BundleManifest.load(from: bundleURL) else { return }

        for track in manifest.variants {
            let trackID = track.id
            let trackTitle = track.name
            let trackEntityID = "vcf_track:\(relPath):\(trackID)"
            var trackAttributes: [String: Any] = [
                "track_id": trackID,
                "track_name": trackTitle,
                "path": track.path,
                "index_path": track.indexPath,
                "variant_type": track.variantType.rawValue,
            ]
            if let variantCount = track.variantCount { trackAttributes["variant_count"] = variantCount }
            if let source = track.source { trackAttributes["source"] = source }
            if let description = track.description { trackAttributes["description"] = description }
            if let version = track.version { trackAttributes["version"] = version }
            if let dbPath = track.databasePath { trackAttributes["database_path"] = dbPath }

            let trackRow = entityRow(
                id: trackEntityID,
                kind: "vcf_track",
                title: trackTitle,
                subtitle: track.description ?? track.path,
                format: "vcf",
                url: bundleURL
            )

            try insertEntity(
                trackRow,
                attributes: trackAttributes,
                entityCount: &entityCount,
                attributeCount: &attributeCount,
                perKindCounts: &perKindCounts
            )

            guard let dbPath = track.databasePath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            guard let variantDB = try? VariantDatabase(url: dbURL) else { continue }

            let sampleMetadata = variantDB.allSampleMetadata()
            for entry in sampleMetadata {
                let sampleName = entry.name
                let sampleEntityID = "vcf_sample:\(relPath):\(trackID):\(sampleName)"
                var sampleAttributes: [String: Any] = [
                    "sample_name": sampleName,
                    "track_id": trackID,
                    "track_name": trackTitle,
                ]
                for (key, value) in entry.metadata {
                    sampleAttributes[key] = value
                }

                let sampleRow = entityRow(
                    id: sampleEntityID,
                    kind: "vcf_sample",
                    title: sampleName,
                    subtitle: trackTitle,
                    format: "vcf",
                    url: bundleURL
                )

                try insertEntity(
                    sampleRow,
                    attributes: sampleAttributes,
                    entityCount: &entityCount,
                    attributeCount: &attributeCount,
                    perKindCounts: &perKindCounts
                )
            }
        }
    }

    private func indexClassificationResult(
        at resultDirectory: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultDirectory)
        let sidecarURL = resultDirectory.appendingPathComponent("classification-result.json")
        var attributes: [String: Any] = [
            "result_directory": resultDirectory.lastPathComponent,
        ]
        var deferredTaxonNames: [String] = []
        if let flattened = flattenJSONFile(at: sidecarURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        if let reportPath = attributes["reportpath"] as? String {
            let reportURL = resultDirectory.appendingPathComponent(reportPath)
            if FileManager.default.fileExists(atPath: reportURL.path),
               let tree = try? KreportParser.parse(url: reportURL) {
                attributes["classified_reads"] = tree.classifiedReads
                attributes["unclassified_reads"] = tree.unclassifiedReads
                attributes["classified_fraction"] = tree.classifiedFraction
                attributes["species_count"] = tree.speciesCount
                if let dominant = tree.dominantSpecies {
                    attributes["dominant_species"] = dominant.name
                }

                let topTaxa = tree.allNodes()
                    .filter { $0.readsClade > 0 }
                    .sorted { $0.readsClade > $1.readsClade }
                    .prefix(400)
                deferredTaxonNames = topTaxa.map(\.name)
                if !deferredTaxonNames.isEmpty {
                    attributes["top_taxa"] = deferredTaxonNames.prefix(120).joined(separator: " | ")
                }
            }
        }

        let title: String = {
            if let value = attributes["config.databasename"] as? String, !value.isEmpty {
                return "Classification: \(value)"
            }
            return resultDirectory.lastPathComponent
        }()

        let row = entityRow(
            id: "classification_result:\(relPath)",
            kind: "classification_result",
            title: title,
            subtitle: resultDirectory.lastPathComponent,
            format: "classification",
            url: resultDirectory
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        for taxonName in deferredTaxonNames {
            try insertAttribute(entityID: row.id, key: "taxon", value: taxonName)
            try insertAttribute(entityID: row.id, key: "virus_name", value: taxonName)
            attributeCount += 1
            attributeCount += 1
        }
    }

    private func indexEsVirituResult(
        at resultDirectory: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultDirectory)
        let parentEntityID = "esviritu_result:\(relPath)"
        let sidecarURL = resultDirectory.appendingPathComponent("esviritu-result.json")

        var attributes: [String: Any] = [
            "result_directory": resultDirectory.lastPathComponent,
        ]
        var deferredVirusNames: [String] = []

        if let flattened = flattenJSONFile(at: sidecarURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        if let detectionPath = attributes["detectionpath"] as? String {
            let detectionURL = resultDirectory.appendingPathComponent(detectionPath)
            if FileManager.default.fileExists(atPath: detectionURL.path),
               let detections = try? EsVirituDetectionParser.parse(url: detectionURL) {
                attributes["detection_count"] = detections.count

                let topDetections = detections
                    .sorted { $0.readCount > $1.readCount }
                    .prefix(300)

                for detection in topDetections {
                    let hitEntityID = "virus_hit:\(relPath):\(detection.accession)"
                    var hitAttributes: [String: Any] = [
                        "virus_name": detection.name,
                        "sample_id": detection.sampleId,
                        "accession": detection.accession,
                        "assembly": detection.assembly,
                        "read_count": detection.readCount,
                        "rpkmf": detection.rpkmf,
                        "covered_bases": detection.coveredBases,
                        "mean_coverage": detection.meanCoverage,
                        "avg_read_identity": detection.avgReadIdentity,
                    ]

                    if let species = detection.species { hitAttributes["species"] = species }
                    if let genus = detection.genus { hitAttributes["genus"] = genus }
                    if let family = detection.family { hitAttributes["family"] = family }
                    if let order = detection.order { hitAttributes["order"] = order }
                    if let segment = detection.segment { hitAttributes["segment"] = segment }

                    let hitRow = entityRow(
                        id: hitEntityID,
                        kind: "virus_hit",
                        title: detection.name,
                        subtitle: detection.sampleId,
                        format: "esviritu",
                        url: resultDirectory
                    )

                    try insertEntity(
                        hitRow,
                        attributes: hitAttributes,
                        entityCount: &entityCount,
                        attributeCount: &attributeCount,
                        perKindCounts: &perKindCounts
                    )

                    deferredVirusNames.append(detection.name)
                }
                if !deferredVirusNames.isEmpty {
                    attributes["detected_viruses"] = deferredVirusNames.prefix(200).joined(separator: " | ")
                }
            }
        }

        let title: String = {
            if let sampleName = attributes["config.samplename"] as? String, !sampleName.isEmpty {
                return "EsViritu: \(sampleName)"
            }
            return resultDirectory.lastPathComponent
        }()

        let row = entityRow(
            id: parentEntityID,
            kind: "esviritu_result",
            title: title,
            subtitle: resultDirectory.lastPathComponent,
            format: "esviritu",
            url: resultDirectory
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )

        for virusName in deferredVirusNames {
            try insertAttribute(entityID: parentEntityID, key: "virus_name", value: virusName)
            attributeCount += 1
        }
    }

    private func indexTaxTriageResult(
        at resultDirectory: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let relPath = relativePath(for: resultDirectory)
        let sidecarURL = resultDirectory.appendingPathComponent("taxtriage-result.json")

        var attributes: [String: Any] = [
            "result_directory": resultDirectory.lastPathComponent,
        ]

        if let flattened = flattenJSONFile(at: sidecarURL) {
            for (key, value) in flattened {
                attributes[key] = value
            }
        }

        let row = entityRow(
            id: "taxtriage_result:\(relPath)",
            kind: "taxtriage_result",
            title: resultDirectory.lastPathComponent,
            subtitle: "TaxTriage",
            format: "taxtriage",
            url: resultDirectory
        )

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    private func indexManifestDocument(
        at fileURL: URL,
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        guard let flattened = flattenJSONFile(at: fileURL), !flattened.isEmpty else { return }

        let relPath = relativePath(for: fileURL)
        let row = entityRow(
            id: "manifest_document:\(relPath)",
            kind: "manifest_document",
            title: fileURL.lastPathComponent,
            subtitle: relPath,
            format: "json",
            url: fileURL
        )

        var attributes: [String: Any] = [
            "filename": fileURL.lastPathComponent,
            "relative_path": relPath,
        ]

        for (key, value) in flattened {
            attributes[key] = value
        }

        try insertEntity(
            row,
            attributes: attributes,
            entityCount: &entityCount,
            attributeCount: &attributeCount,
            perKindCounts: &perKindCounts
        )
    }

    // MARK: - Insert Helpers

    private func insertEntity(
        _ row: EntityRow,
        attributes: [String: Any],
        entityCount: inout Int,
        attributeCount: inout Int,
        perKindCounts: inout [String: Int]
    ) throws {
        let now = Int(Date().timeIntervalSince1970)

        var searchTerms: [String] = [row.title, row.kind, row.format ?? "", row.subtitle ?? ""]
        for (_, value) in attributes {
            if let text = valueAsString(value) {
                searchTerms.append(text)
            }
        }
        let searchText = searchTerms
            .joined(separator: " ")
            .lowercased()

        try execute(
            """
            INSERT OR REPLACE INTO us_entities (
                id, kind, title, subtitle, format, rel_path, url, mtime, size_bytes, indexed_at, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                row.id,
                row.kind,
                row.title,
                row.subtitle as Any,
                row.format as Any,
                row.relPath,
                row.url.path,
                row.mtime as Any,
                row.sizeBytes as Any,
                now,
                searchText,
            ]
        )

        entityCount += 1
        perKindCounts[row.kind, default: 0] += 1

        for (key, value) in attributes {
            try insertAttribute(entityID: row.id, key: key, value: value)
            attributeCount += 1
        }
    }

    private func insertAttribute(entityID: String, key: String, value: Any) throws {
        guard let stringValue = valueAsString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stringValue.isEmpty else {
            return
        }

        let normalizedKey = normalizeKey(key)
        let normalizedValue = stringValue.lowercased()

        let numberValue: Double?
        if let directNumber = value as? NSNumber {
            numberValue = directNumber.doubleValue
        } else {
            numberValue = Double(normalizedValue)
        }

        let boolValue: Int?
        if let bool = value as? Bool {
            boolValue = bool ? 1 : 0
        } else if normalizedValue == "true" || normalizedValue == "yes" || normalizedValue == "1" {
            boolValue = 1
        } else if normalizedValue == "false" || normalizedValue == "no" || normalizedValue == "0" {
            boolValue = 0
        } else {
            boolValue = nil
        }

        let dateEpoch = parseDateEpochSeconds(value)

        let valueType: String
        if dateEpoch != nil {
            valueType = "date"
        } else if numberValue != nil {
            valueType = "number"
        } else if boolValue != nil {
            valueType = "bool"
        } else {
            valueType = "text"
        }

        try execute(
            """
            INSERT OR REPLACE INTO us_attributes (
                entity_id, key, value, number_value, date_value, bool_value, value_type
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [
                entityID,
                normalizedKey,
                normalizedValue,
                numberValue as Any,
                dateEpoch as Any,
                boolValue as Any,
                valueType,
            ]
        )
    }

    // MARK: - Attribute Extraction

    private func appendFASTQSampleAttributes(_ metadata: FASTQSampleMetadata, to attrs: inout [String: Any]) {
        attrs["sample_name"] = metadata.sampleName
        attrs["sample_type"] = metadata.sampleType
        attrs["collection_date"] = metadata.collectionDate
        attrs["geo_loc_name"] = metadata.geoLocName
        attrs["host"] = metadata.host
        attrs["host_disease"] = metadata.hostDisease
        attrs["purpose_of_sequencing"] = metadata.purposeOfSequencing
        attrs["sequencing_instrument"] = metadata.sequencingInstrument
        attrs["library_strategy"] = metadata.libraryStrategy
        attrs["sample_collected_by"] = metadata.sampleCollectedBy
        attrs["organism"] = metadata.organism
        attrs["sample_role"] = metadata.sampleRole.rawValue
        attrs["patient_id"] = metadata.patientId
        attrs["run_id"] = metadata.runId
        attrs["batch_id"] = metadata.batchId
        attrs["plate_position"] = metadata.platePosition
        attrs["metadata_template"] = metadata.metadataTemplate?.rawValue
        attrs["notes"] = metadata.notes

        for (key, value) in metadata.customFields {
            attrs[normalizeKey(key)] = value
        }
    }

    private func flattenJSONFile(at fileURL: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var flattened: [String: String] = [:]
        flattenJSONObject(object, prefix: "", depth: 0, into: &flattened)
        return flattened
    }

    private func flattenJSONObject(_ object: Any, prefix: String, depth: Int, into flattened: inout [String: String]) {
        guard depth <= 8, flattened.count < 2000 else { return }

        switch object {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                guard let value = dict[key] else { continue }
                let fullKey = prefix.isEmpty ? normalizeKey(key) : "\(prefix).\(normalizeKey(key))"
                flattenJSONObject(value, prefix: fullKey, depth: depth + 1, into: &flattened)
            }

        case let array as [Any]:
            if array.allSatisfy({ $0 is String || $0 is NSNumber }) {
                let values = array.compactMap { valueAsString($0) }.joined(separator: ", ")
                if !values.isEmpty {
                    flattened[prefix] = values
                }
            } else {
                for (index, value) in array.enumerated() {
                    let fullKey = "\(prefix)[\(index)]"
                    flattenJSONObject(value, prefix: fullKey, depth: depth + 1, into: &flattened)
                }
            }

        case let number as NSNumber:
            flattened[prefix] = number.stringValue

        case let text as String:
            if !text.isEmpty {
                flattened[prefix] = text
            }

        default:
            if let text = valueAsString(object), !text.isEmpty {
                flattened[prefix] = text
            }
        }
    }

    // MARK: - SQL

    private func createSchemaIfNeeded() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS us_entities (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT,
                format TEXT,
                rel_path TEXT NOT NULL,
                url TEXT NOT NULL,
                mtime REAL,
                size_bytes INTEGER,
                indexed_at INTEGER NOT NULL,
                search_text TEXT NOT NULL
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS us_attributes (
                entity_id TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                number_value REAL,
                date_value INTEGER,
                bool_value INTEGER,
                value_type TEXT NOT NULL,
                PRIMARY KEY(entity_id, key, value),
                FOREIGN KEY(entity_id) REFERENCES us_entities(id) ON DELETE CASCADE
            )
            """
        )

        try execute(
            """
            CREATE TABLE IF NOT EXISTS us_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )

        try execute("CREATE INDEX IF NOT EXISTS idx_us_entities_kind ON us_entities(kind)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_entities_format ON us_entities(format)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_entities_rel_path ON us_entities(rel_path)")

        try execute("CREATE INDEX IF NOT EXISTS idx_us_attributes_key_value ON us_attributes(key, value)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_attributes_key_number ON us_attributes(key, number_value)")
        try execute("CREATE INDEX IF NOT EXISTS idx_us_attributes_key_date ON us_attributes(key, date_value)")
    }

    private func execute(_ sql: String, parameters: [Any] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }

        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            try bind(statement, index: Int32(index + 1), value: parameter)
        }

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }

        guard result == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func queryRows(
        _ sql: String,
        parameters: [Any] = [],
        _ body: (OpaquePointer?) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            try bind(statement, index: Int32(index + 1), value: parameter)
        }

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try body(statement)
                continue
            }
            if result == SQLITE_DONE {
                return
            }
            throw databaseError()
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try queryRows(sql) { stmt in
            value = Int(sqlite3_column_int64(stmt, 0))
        }
        return value
    }

    private func setMetadata(key: String, value: String) throws {
        try execute(
            "INSERT OR REPLACE INTO us_metadata (key, value) VALUES (?, ?)",
            parameters: [key, value]
        )
    }

    private func metadataValue(for key: String) throws -> String? {
        var value: String?
        try queryRows("SELECT value FROM us_metadata WHERE key = ? LIMIT 1", parameters: [key]) { stmt in
            if let text = sqlite3_column_text(stmt, 0) {
                value = String(cString: text)
            }
        }
        return value
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, value: Any) throws {
        let boundValue = unwrapOptional(value)
        let result: Int32
        switch boundValue {
        case nil, is NSNull:
            result = sqlite3_bind_null(statement, index)

        case let text as String:
            result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)

        case let int as Int:
            result = sqlite3_bind_int64(statement, index, Int64(int))

        case let int64 as Int64:
            result = sqlite3_bind_int64(statement, index, int64)

        case let double as Double:
            result = sqlite3_bind_double(statement, index, double)

        case let bool as Bool:
            result = sqlite3_bind_int(statement, index, bool ? 1 : 0)

        case let date as Date:
            result = sqlite3_bind_int64(statement, index, Int64(date.timeIntervalSince1970))

        default:
            result = sqlite3_bind_null(statement, index)
        }

        guard result == SQLITE_OK else {
            throw databaseError()
        }
    }

    private var SQLITE_TRANSIENT: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        return mirror.children.first?.value
    }

    private func databaseError() -> ProjectUniversalSearchError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .databaseQueryFailed(message)
    }

    // MARK: - Utility Helpers

    private func pathCompare(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    private func entityRow(
        id: String,
        kind: String,
        title: String,
        subtitle: String?,
        format: String?,
        url: URL
    ) -> EntityRow {
        let values = resourceValues(for: url)
        return EntityRow(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            format: format,
            relPath: relativePath(for: url),
            url: url,
            mtime: values.mtime,
            sizeBytes: values.size
        )
    }

    private func resourceValues(for url: URL) -> (mtime: Double?, size: Int64?) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return (nil, nil)
        }
        let mtime = values.contentModificationDate?.timeIntervalSince1970
        let size = values.fileSize.map(Int64.init)
        return (mtime, size)
    }

    private func relativePath(for url: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let absolutePath = url.standardizedFileURL.path
        let rootPrefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"

        if absolutePath == projectPath {
            return "."
        }

        if absolutePath.hasPrefix(rootPrefix) {
            return String(absolutePath.dropFirst(rootPrefix.count))
        }

        return absolutePath
    }

    private func hasFile(_ filename: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path)
    }

    private func valueAsString(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return String(int)
        case let int64 as Int64:
            return String(int64)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date)
        default:
            return nil
        }
    }

    private func parseDateEpochSeconds(_ value: Any) -> Int64? {
        if let date = value as? Date {
            return Int64(date.timeIntervalSince1970)
        }

        guard let text = valueAsString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) {
            return Int64(date.timeIntervalSince1970)
        }

        let dateFormats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
        }

        return nil
    }

    private func normalizeKey(_ key: String) -> String {
        key
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
