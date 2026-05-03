// AnalysesFolder.swift - Manage project-level Analyses/ directory
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.io, category: "AnalysesFolder")

/// Manages the `Analyses/` directory within a project directory.
///
/// Analysis results (classification, assembly, alignment) are stored as
/// timestamped subdirectories: `{tool}-{yyyy-MM-dd'T'HH-mm-ss}/` or
/// `{tool}-batch-{yyyy-MM-dd'T'HH-mm-ss}/` for batch runs.
public enum AnalysesFolder {

    /// The directory name within the project directory.
    public static let directoryName = "Analyses"

    /// Filename for the analysis metadata sidecar written at directory creation time.
    public static let metadataFilename = "analysis-metadata.json"

    /// The set of recognised tool names used to parse directory entries.
    public static let knownTools: Set<String> = [
        "esviritu", "kraken2", "taxtriage", "minimap2", "bwa-mem2", "bowtie2", "bbmap",
        "spades", "megahit", "skesa", "flye", "hifiasm", "naomgs", "nvd",
        "mafft",
    ]

    /// Tools whose imported results use `{tool}-{sampleName}` naming
    /// instead of the standard `{tool}-{timestamp}` convention.
    private static let importedResultTools: Set<String> = ["naomgs", "nvd"]

    // MARK: - Analysis Metadata

    /// Metadata persisted as `analysis-metadata.json` inside each analysis directory.
    ///
    /// Written at creation time by ``createAnalysisDirectory(tool:in:isBatch:date:)``
    /// and read back by ``listAnalyses(in:)`` to identify the analysis type even
    /// after the user renames the directory.
    public struct AnalysisMetadata: Codable, Sendable {
        /// The tool identifier (e.g. `"kraken2"`, `"naomgs"`).
        public let tool: String
        /// Whether this was a batch run.
        public let isBatch: Bool
        /// When the analysis directory was created (ISO 8601).
        public let created: Date

        public init(tool: String, isBatch: Bool, created: Date = Date()) {
            self.tool = tool
            self.isBatch = isBatch
            self.created = created
        }
    }

    /// Reads the `analysis-metadata.json` sidecar from an analysis directory.
    ///
    /// Returns `nil` if the file is missing or cannot be decoded (e.g. legacy
    /// directories created before this sidecar was introduced).
    public static func readAnalysisMetadata(from directoryURL: URL) -> AnalysisMetadata? {
        let metadataURL = directoryURL.appendingPathComponent(metadataFilename)
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnalysisMetadata.self, from: data)
    }

    /// Writes an `analysis-metadata.json` sidecar into an analysis directory.
    public static func writeAnalysisMetadata(_ metadata: AnalysisMetadata, to directoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: directoryURL.appendingPathComponent(metadataFilename), options: .atomic)
    }

    // MARK: - Tool Metadata

    /// Human-readable display name for a tool identifier.
    public static func displayName(for tool: String) -> String {
        switch tool {
        case "esviritu": return "EsViritu"
        case "kraken2": return "Kraken2"
        case "taxtriage": return "TaxTriage"
        case "spades": return "SPAdes"
        case "megahit": return "MEGAHIT"
        case "skesa": return "SKESA"
        case "flye": return "Flye"
        case "hifiasm": return "Hifiasm"
        case "minimap2": return "Minimap2"
        case "bwa-mem2": return "BWA-MEM2"
        case "bowtie2": return "Bowtie2"
        case "bbmap": return "BBMap"
        case "naomgs": return "NAO-MGS"
        case "nvd": return "NVD"
        case "mafft": return "MAFFT"
        default: return tool.capitalized
        }
    }

    // MARK: - Directory Management

    /// Returns the `Analyses/` URL for a project, creating the directory if it doesn't exist.
    public static func url(for projectURL: URL) throws -> URL {
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            logger.info("Created Analyses directory at \(dir.path)")
        }
        return dir
    }

    // MARK: - Creating Analysis Directories

    /// Creates a new timestamped analysis subdirectory.
    ///
    /// - Single run:  `Analyses/{tool}-{yyyy-MM-dd'T'HH-mm-ss}/`
    /// - Batch run:   `Analyses/{tool}-batch-{yyyy-MM-dd'T'HH-mm-ss}/`
    ///
    /// - Parameters:
    ///   - tool: The tool identifier (e.g. `"kraken2"`).
    ///   - projectURL: Path to the project directory.
    ///   - isBatch: Whether this is a batch run.
    ///   - date: The date to embed in the directory name (defaults to now).
    /// - Returns: URL of the newly created analysis directory.
    @discardableResult
    public static func createAnalysisDirectory(
        tool: String,
        in projectURL: URL,
        isBatch: Bool = false,
        date: Date = Date()
    ) throws -> URL {
        let analysesDir = try url(for: projectURL)
        let timestamp = formatTimestamp(date)
        let name = isBatch ? "\(tool)-batch-\(timestamp)" : "\(tool)-\(timestamp)"
        let analysisURL = analysesDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)

        // Write analysis-metadata.json so the directory is identifiable even if renamed.
        let metadata = AnalysisMetadata(tool: tool, isBatch: isBatch, created: date)
        try writeAnalysisMetadata(metadata, to: analysisURL)

        logger.info("Created analysis directory: \(name)")
        return analysisURL
    }

    // MARK: - Listing

    /// Lists all analysis directories in `Analyses/`, sorted newest first.
    ///
    /// User-created folders inside `Analyses/` are traversed recursively so
    /// grouped analysis runs remain discoverable. Directories whose names and
    /// contents cannot be recognized as analyses are ignored. Returns an empty
    /// array if `Analyses/` does not exist.
    public static func listAnalyses(in projectURL: URL) throws -> [AnalysisDirectoryInfo] {
        let dir = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        var results: [AnalysisDirectoryInfo] = []
        try collectAnalyses(in: dir, into: &results)
        return results.sorted { $0.timestamp > $1.timestamp }
    }

    /// Returns analysis metadata for a single directory, if it is recognized as
    /// an analysis result.
    public static func analysisInfo(for directoryURL: URL) -> AnalysisDirectoryInfo? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return parseDirectoryName(directoryURL.lastPathComponent, url: directoryURL)
    }

    private static func collectAnalyses(in directoryURL: URL, into results: inout [AnalysisDirectoryInfo]) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            if let info = analysisInfo(for: url) {
                results.append(info)
                continue
            }

            try collectAnalyses(in: url, into: &results)
        }
    }

    // MARK: - Timestamp Formatting

    /// Formats a date as `yyyy-MM-dd'T'HH-mm-ss` (filesystem-safe ISO 8601).
    public static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Parses a `yyyy-MM-dd'T'HH-mm-ss` string back to a `Date`.
    public static func parseTimestamp(_ string: String) -> Date? {
        timestampFormatter.date(from: string)
    }

    // MARK: - AnalysisDirectoryInfo

    /// Metadata about a discovered analysis directory.
    public struct AnalysisDirectoryInfo: Sendable {
        /// The URL of the analysis directory.
        public let url: URL
        /// The tool that produced this analysis (e.g. `"kraken2"`).
        public let tool: String
        /// When the analysis was created (parsed from the directory name).
        public let timestamp: Date
        /// Whether this was a batch run.
        public let isBatch: Bool
    }

    // MARK: - Private Helpers

    /// Identifies an analysis directory by its metadata sidecar, directory name,
    /// or (as a last resort) its content.
    ///
    /// Resolution order:
    /// 1. `analysis-metadata.json` — authoritative, survives renames.
    /// 2. Directory name prefix — `{tool}[-batch]-{timestamp}` pattern.
    /// 3. Imported-result prefix — `{tool}-{sampleName}` for naomgs/nvd.
    /// 4. Content probing — signature sidecar files (legacy fallback).
    private static func parseDirectoryName(_ name: String, url: URL) -> AnalysisDirectoryInfo? {
        // 1. Authoritative: read analysis-metadata.json written at creation time.
        if let metadata = readAnalysisMetadata(from: url) {
            return AnalysisDirectoryInfo(
                url: url,
                tool: metadata.tool,
                timestamp: metadata.created,
                isBatch: metadata.isBatch
            )
        }

        // 2. Try batch pattern first: {tool}-batch-{timestamp}
        for tool in knownTools {
            let batchPrefix = "\(tool)-batch-"
            if name.hasPrefix(batchPrefix) {
                let timestampPart = String(name.dropFirst(batchPrefix.count))
                if let date = parseTimestamp(timestampPart) {
                    return AnalysisDirectoryInfo(url: url, tool: tool, timestamp: date, isBatch: true)
                }
            }
        }

        // Try single pattern: {tool}-{timestamp}
        for tool in knownTools {
            let prefix = "\(tool)-"
            if name.hasPrefix(prefix) {
                let timestampPart = String(name.dropFirst(prefix.count))
                if let date = parseTimestamp(timestampPart) {
                    return AnalysisDirectoryInfo(url: url, tool: tool, timestamp: date, isBatch: false)
                }
            }
        }

        // Fallback for imported results that use {tool}-{sampleName} naming
        // (e.g. naomgs-MU-CASPER-2026-03-31-a-..., nvd-SampleName).
        // Uses the directory's filesystem creation date as the timestamp.
        for tool in importedResultTools {
            let prefix = "\(tool)-"
            if name.hasPrefix(prefix), !String(name.dropFirst(prefix.count)).isEmpty {
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                return AnalysisDirectoryInfo(url: url, tool: tool, timestamp: date, isBatch: false)
            }
        }

        // Content-based detection: the directory was renamed by the user.
        // Probe for signature sidecar files to infer the tool type.
        if let tool = probeToolType(in: url) {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            return AnalysisDirectoryInfo(url: url, tool: tool, timestamp: date, isBatch: false)
        }

        return nil
    }

    /// Probes the contents of a directory to infer the analysis tool type.
    ///
    /// This enables discovery of analysis directories that the user has renamed
    /// to something that no longer carries a recognised tool prefix.  Checked
    /// only after all prefix-based patterns fail.
    private static func probeToolType(in url: URL) -> String? {
        let fm = FileManager.default
        let manifest = url.appendingPathComponent("manifest.json")
        let hitsSqlite = url.appendingPathComponent("hits.sqlite")
        let classificationResult = url.appendingPathComponent("classification-result.json")
        let assemblyResult = url.appendingPathComponent("assembly-result.json")
        let mappingResult = url.appendingPathComponent("mapping-result.json")
        let msaManifest = url.appendingPathComponent("manifest.json")
        let alignedFASTA = url.appendingPathComponent("alignment/primary.aligned.fasta")

        // Kraken2: has classification-result.json
        if fm.fileExists(atPath: classificationResult.path) {
            return "kraken2"
        }

        // Assembly tools: managed sidecars store `tool`; legacy schema v1 implies SPAdes.
        if fm.fileExists(atPath: assemblyResult.path),
           let data = fm.contents(atPath: assemblyResult.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let tool = json["tool"] as? String, knownTools.contains(tool) {
                return tool
            }
            if let schemaVersion = json["schemaVersion"] as? Int, schemaVersion == 1 {
                return "spades"
            }
            if json["spadesVersion"] != nil || json["contigsPath"] != nil {
                return "spades"
            }
        }

        // Mapping tools: infer from the persisted mapping sidecar.
        if fm.fileExists(atPath: mappingResult.path),
           let data = fm.contents(atPath: mappingResult.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mapper = json["mapper"] as? String,
           knownTools.contains(mapper) {
            return mapper
        }

        // MAFFT/native MSA bundle: manifest declares the bundle kind and
        // alignment/primary.aligned.fasta provides the native payload.
        if fm.fileExists(atPath: msaManifest.path),
           fm.fileExists(atPath: alignedFASTA.path),
           let data = fm.contents(atPath: msaManifest.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["bundleKind"] as? String == "multiple-sequence-alignment" {
            return "mafft"
        }

        // NAO-MGS vs NVD: both have manifest.json + hits.sqlite.
        // Distinguish by manifest content: NVD has "experiment", NAO-MGS has "taxonCount".
        if fm.fileExists(atPath: manifest.path), fm.fileExists(atPath: hitsSqlite.path) {
            if let data = fm.contents(atPath: manifest.path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["experiment"] != nil {
                    return "nvd"
                }
                if json["taxonCount"] != nil || json["hitCount"] != nil {
                    return "naomgs"
                }
            }
            // Ambiguous manifest — default to naomgs (more common).
            return "naomgs"
        }

        // EsViritu: look for detected_virus.info.tsv or the EsViritu database pattern
        if let contents = try? fm.contentsOfDirectory(atPath: url.path) {
            for file in contents {
                if file.hasSuffix(".detected_virus.info.tsv") || file == "detected_virus.info.tsv" {
                    return "esviritu"
                }
            }
        }

        // TaxTriage: has hits.sqlite but no manifest.json (manifest is optional for taxtriage)
        if fm.fileExists(atPath: hitsSqlite.path) {
            return "taxtriage"
        }

        return nil
    }

    /// Shared `DateFormatter` for `yyyy-MM-dd'T'HH-mm-ss`.
    private static let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        return df
    }()
}
