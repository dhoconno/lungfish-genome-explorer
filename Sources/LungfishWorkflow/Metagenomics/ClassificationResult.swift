// ClassificationResult.swift - Result of a Kraken2 classification pipeline run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let persistLogger = Logger(subsystem: "com.lungfish.workflow", category: "ClassificationPersist")

// MARK: - ClassificationResult

/// The result of a completed classification pipeline run.
///
/// Contains the parsed taxonomy tree, paths to all output files, runtime
/// metadata, and the provenance record ID for traceability.
///
/// ## Output Files
///
/// Every run produces at least two files:
/// - ``reportURL``: The Kraken2 kreport (6-column TSV with clade counts)
/// - ``outputURL``: The per-read classification output
///
/// If Bracken profiling was requested, ``brackenURL`` will be non-nil.
///
/// ## Persistence
///
/// Use ``save(to:)`` to write a JSON sidecar (`classification-result.json`)
/// into the output directory. The tree is NOT serialized -- it is rebuilt from
/// the `.kreport` file on ``load(from:)``.
///
/// ## Thread Safety
///
/// `ClassificationResult` is `Sendable` because ``tree`` contains only
/// `@unchecked Sendable` nodes that are immutable after construction.
public struct ClassificationResult: Sendable {

    /// The configuration that produced this result.
    public let config: ClassificationConfig

    /// The parsed taxonomy tree from the Kraken2 report.
    public let tree: TaxonTree

    /// Path to the Kraken2 report file (.kreport).
    public let reportURL: URL

    /// Path to the per-read Kraken2 output file (.kraken).
    public let outputURL: URL

    /// Path to the Bracken output file, if profiling was performed.
    public let brackenURL: URL?

    /// Whether Bracken was not requested, completed, or degraded after a valid
    /// Kraken2 classification.
    public let profileOutcome: BrackenProfileOutcome

    /// Total wall-clock time for the pipeline run, in seconds.
    public let runtime: TimeInterval

    /// Version string of the kraken2 tool that was executed.
    public let toolVersion: String

    /// The provenance run ID, if provenance recording was enabled.
    public let provenanceId: UUID?

    /// Creates a classification result.
    ///
    /// - Parameters:
    ///   - config: The configuration used for this run.
    ///   - tree: The parsed taxonomy tree.
    ///   - reportURL: Path to the kreport file.
    ///   - outputURL: Path to the per-read output.
    ///   - brackenURL: Path to the Bracken output, or `nil`.
    ///   - runtime: Wall-clock time in seconds.
    ///   - toolVersion: Kraken2 version string.
    ///   - provenanceId: Provenance run ID, or `nil`.
    public init(
        config: ClassificationConfig,
        tree: TaxonTree,
        reportURL: URL,
        outputURL: URL,
        brackenURL: URL?,
        profileOutcome: BrackenProfileOutcome = .notRequested,
        runtime: TimeInterval,
        toolVersion: String,
        provenanceId: UUID?
    ) {
        self.config = config
        self.tree = tree
        self.reportURL = reportURL
        self.outputURL = outputURL
        self.brackenURL = brackenURL
        self.profileOutcome = profileOutcome
        self.runtime = runtime
        self.toolVersion = toolVersion
        self.provenanceId = provenanceId
    }

    // MARK: - Convenience

    /// A human-readable summary of the classification result.
    public var summary: String {
        var lines: [String] = []
        lines.append("Classification Summary")
        lines.append("  Database: \(config.databaseName)")
        lines.append("  Total reads: \(tree.totalReads)")
        lines.append("  Classified: \(tree.classifiedReads) (\(String(format: "%.1f", tree.classifiedFraction * 100))%)")
        lines.append("  Unclassified: \(tree.unclassifiedReads) (\(String(format: "%.1f", tree.unclassifiedFraction * 100))%)")
        lines.append("  Species: \(tree.speciesCount)")
        lines.append("  Genera: \(tree.generaCount)")

        if let dominant = tree.dominantSpecies {
            let pct = String(format: "%.1f", dominant.fractionClade * 100)
            lines.append("  Dominant species: \(dominant.name) (\(pct)%)")
        }

        let shannonStr = String(format: "%.3f", tree.shannonDiversity)
        lines.append("  Shannon diversity (H'): \(shannonStr)")

        let runtimeStr = String(format: "%.1f", runtime)
        lines.append("  Runtime: \(runtimeStr)s")
        lines.append("  Tool: kraken2 \(toolVersion)")

        switch profileOutcome.state {
        case .notRequested:
            break
        case .completed:
            let rank = profileOutcome.resolution?.rank.displayName ?? "unknown rank"
            lines.append("  Bracken profiling: completed at \(rank)")
        case .degraded:
            let reason = profileOutcome.message
                ?? profileOutcome.reason?.rawValue
                ?? "unknown reason"
            lines.append("  Bracken profiling: degraded; Kraken2 classification retained")
            lines.append("  Profiling detail: \(reason)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Persistence

/// The filename used for the serialized classification result sidecar.
private let classificationResultFilename = "classification-result.json"

extension ClassificationResult {
    static var sidecarFilename: String {
        classificationResultFilename
    }

    /// Saves the classification result metadata to a JSON file in the given directory.
    ///
    /// The taxonomy tree is NOT serialized. On ``load(from:)``, it is rebuilt
    /// by re-parsing the `.kreport` file referenced in the saved metadata.
    ///
    /// The saved JSON contains:
    /// - The full ``ClassificationConfig`` (database, input files, parameters)
    /// - Output file paths (report, kraken output, bracken output)
    /// - Runtime and tool version
    /// - Provenance ID
    ///
    /// - Parameter directory: The directory to write `classification-result.json` into.
    /// - Throws: Encoding or file write errors.
    public func save(to directory: URL) throws {
        let sidecar = PersistedClassificationResult(
            config: config,
            reportPath: reportURL.lastPathComponent,
            outputPath: outputURL.lastPathComponent,
            brackenPath: brackenURL?.lastPathComponent,
            profileOutcome: profileOutcome,
            runtime: runtime,
            toolVersion: toolVersion,
            provenanceId: provenanceId,
            savedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)

        let fileURL = directory.appendingPathComponent(classificationResultFilename)
        try data.write(to: fileURL, options: .atomic)

        persistLogger.info("Saved classification result to \(fileURL.path, privacy: .public)")
    }

    /// Loads a classification result from a directory containing a saved sidecar.
    ///
    /// The taxonomy tree is rebuilt by parsing the `.kreport` file referenced
    /// in the sidecar. If Bracken output exists, it is merged into the tree.
    ///
    /// - Parameter directory: The directory containing `classification-result.json`
    ///   and the referenced output files.
    /// - Returns: A fully reconstituted ``ClassificationResult``.
    /// - Throws: ``ClassificationResultLoadError`` or parsing errors.
    public static func load(from directory: URL) throws -> ClassificationResult {
        let fileURL = directory.appendingPathComponent(classificationResultFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ClassificationResultLoadError.sidecarNotFound(directory)
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(PersistedClassificationResult.self, from: data)
        let config = Self.resolvingRelativeConfigURLs(sidecar.config, relativeTo: directory)

        // Resolve file paths relative to the directory.
        let reportURL = directory.appendingPathComponent(sidecar.reportPath)
        let outputURL = directory.appendingPathComponent(sidecar.outputPath)
        let storedBrackenURL = sidecar.brackenPath.map { directory.appendingPathComponent($0) }
        let brackenURL = storedBrackenURL.flatMap { candidate in
            FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }

        // Rebuild the taxonomy tree from the kreport.
        guard FileManager.default.fileExists(atPath: reportURL.path) else {
            throw ClassificationResultLoadError.kreportNotFound(reportURL)
        }

        var tree = try KreportParser.parse(url: reportURL)

        // Merge Bracken results if available.
        if let brackenURL, FileManager.default.fileExists(atPath: brackenURL.path) {
            try BrackenParser.mergeBracken(url: brackenURL, into: &tree)
        }

        let profileOutcome = resolvedProfileOutcome(
            persisted: sidecar.profileOutcome,
            config: config,
            storedBrackenPath: sidecar.brackenPath,
            existingBrackenURL: brackenURL
        )

        persistLogger.info("Loaded classification result from \(directory.path, privacy: .public)")

        return ClassificationResult(
            config: config,
            tree: tree,
            reportURL: reportURL,
            outputURL: outputURL,
            brackenURL: brackenURL,
            profileOutcome: profileOutcome,
            runtime: sidecar.runtime,
            toolVersion: sidecar.toolVersion,
            provenanceId: sidecar.provenanceId
        )
    }

    private static func resolvingRelativeConfigURLs(
        _ config: ClassificationConfig,
        relativeTo directory: URL
    ) -> ClassificationConfig {
        var resolved = ClassificationConfig(
            goal: config.goal,
            inputFiles: config.inputFiles.map { resolvePersistedURL($0, relativeTo: directory) },
            isPairedEnd: config.isPairedEnd,
            databaseName: config.databaseName,
            inputFormat: config.inputFormat,
            databaseVersion: config.databaseVersion,
            databasePath: resolvePersistedURL(config.databasePath, relativeTo: directory),
            databaseDigest: config.databaseDigest,
            databaseCatalogID: config.databaseCatalogID,
            databaseInstallationRecipe: config.databaseInstallationRecipe,
            brackenProfileRequest: config.brackenProfileRequest,
            confidence: config.confidence,
            minimumHitGroups: config.minimumHitGroups,
            threads: config.threads,
            memoryMapping: config.memoryMapping,
            quickMode: config.quickMode,
            outputDirectory: resolvePersistedURL(config.outputDirectory, relativeTo: directory),
            extraArguments: config.extraArguments
        )
        resolved.sampleDisplayName = config.sampleDisplayName
        resolved.originalInputFiles = config.originalInputFiles?.map {
            resolvePersistedURL($0, relativeTo: directory)
        }
        return resolved
    }

    private static func resolvePersistedURL(_ url: URL, relativeTo directory: URL) -> URL {
        if url.isFileURL, url.path.hasPrefix("/") {
            return url
        }
        let path = url.relativePath
        if path == "." {
            return directory
        }
        return directory
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private static func resolvedProfileOutcome(
        persisted: BrackenProfileOutcome?,
        config: ClassificationConfig,
        storedBrackenPath: String?,
        existingBrackenURL: URL?
    ) -> BrackenProfileOutcome {
        if let persisted {
            if persisted.state == .completed,
               existingBrackenURL == nil,
               let resolution = persisted.resolution {
                return .degraded(
                    resolution: resolution,
                    reason: .outputMissing,
                    message: "The persisted Bracken output is missing.",
                    toolVersion: persisted.toolVersion
                )
            }
            return persisted
        }

        // Historical sidecars did not state whether Bracken was requested. Only
        // an extant referenced output is sufficient evidence of completion.
        guard storedBrackenPath != nil, existingBrackenURL != nil else {
            return .notRequested
        }
        let request = config.brackenProfileRequest ?? .automaticDefault
        let resolution = BrackenDatabaseCapabilities.resolve(
            catalogID: config.databaseCatalogID,
            installationRecipe: config.databaseInstallationRecipe,
            request: request
        )
        return .completed(resolution: resolution)
    }

    /// Whether a saved classification result exists in the given directory.
    ///
    /// - Parameter directory: The directory to check.
    /// - Returns: `true` if `classification-result.json` exists.
    public static func exists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(classificationResultFilename).path
        )
    }

    /// Builds a copyable shell command string for a classification result directory.
    ///
    /// Attempts to load the provenance sidecar (`.lungfish-provenance.json`) first,
    /// which contains the exact `argv` arrays for both kraken2 and bracken as they
    /// were executed. If provenance is unavailable, reconstructs the kraken2 command
    /// from the saved ``ClassificationConfig``.
    ///
    /// The returned string contains one or two commands separated by a blank line:
    /// 1. The `kraken2` command (always present)
    /// 2. The `bracken` command (only if Bracken profiling was performed)
    ///
    /// - Parameter directory: The classification result directory containing
    ///   `classification-result.json` and optionally `.lungfish-provenance.json`.
    /// - Returns: A shell-ready command string, or `nil` if the sidecar cannot be read.
    public static func copyableCommandString(from directory: URL) -> String? {
        // Try provenance first -- it has exact commands as executed.
        if let provenance = ProvenanceRecorder.load(from: directory) {
            let commands = provenance.steps.map { step in
                step.command.map { shellEscape($0) }.joined(separator: " \\\n  ")
            }
            if !commands.isEmpty {
                return commands.joined(separator: "\n\n")
            }
        }

        // Fall back to reconstructing from the classification config sidecar.
        let sidecarURL = directory.appendingPathComponent(classificationResultFilename)
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sidecar = try? decoder.decode(PersistedClassificationResult.self, from: data) else {
            return nil
        }

        var result = sidecar.config.kraken2CommandString()

        // If Bracken was run, reconstruct the command from persisted resolved
        // settings, falling back to database-aware legacy defaults only when an
        // old sidecar does not contain them.
        if let brackenPath = sidecar.brackenPath {
            let reportPath = shellEscape(
                directory.appendingPathComponent(sidecar.reportPath).path
            )
            let brackenPath = shellEscape(
                directory.appendingPathComponent(brackenPath).path
            )
            let dbPath = shellEscape(sidecar.config.databasePath.path)
            let request = sidecar.config.brackenProfileRequest ?? .automaticDefault
            let resolution = sidecar.profileOutcome?.resolution
                ?? BrackenDatabaseCapabilities.resolve(
                    catalogID: sidecar.config.databaseCatalogID,
                    installationRecipe: sidecar.config.databaseInstallationRecipe,
                    request: request
                )

            result += "\n\nbracken \\\n"
            result += "  -d \(dbPath) \\\n"
            result += "  -i \(reportPath) \\\n"
            result += "  -o \(brackenPath) \\\n"
            result += "  -r \(resolution.readLength) \\\n"
            result += "  -l \(resolution.rank.code) \\\n"
            result += "  -t \(resolution.threshold)"
        }

        return result
    }
}

// MARK: - PersistedClassificationResult

/// Codable representation of a classification result for JSON serialization.
///
/// File paths are stored as relative filenames (not absolute paths) so the
/// sidecar remains valid if the output directory is moved.
struct PersistedClassificationResult: Codable, Sendable {
    let config: ClassificationConfig
    let reportPath: String
    let outputPath: String
    let brackenPath: String?
    let profileOutcome: BrackenProfileOutcome?
    let runtime: TimeInterval
    let toolVersion: String
    let provenanceId: UUID?
    let savedAt: Date
}

// MARK: - ClassificationResultLoadError

/// Errors that can occur when loading a persisted classification result.
public enum ClassificationResultLoadError: Error, LocalizedError, Sendable {

    /// The `classification-result.json` sidecar was not found.
    case sidecarNotFound(URL)

    /// The kreport file referenced by the sidecar was not found.
    case kreportNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .sidecarNotFound(let url):
            return "No saved classification result in \(url.path)"
        case .kreportNotFound(let url):
            return "Kreport file not found: \(url.path)"
        }
    }
}
