// AnalysesFolder.swift - Manage project-level Analyses/ directory
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
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
    public static let knownTools: Set<String> = Set(AnalysisToolRegistry.all.map { $0.id.rawValue })

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
        AnalysisToolRegistry.displayName(forRawID: tool)
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
    /// - Collision:   appends `-2`, `-3`, ... if another run already claimed the timestamp.
    ///
    /// The directory is created **incomplete**: it carries an
    /// ``AnalysisRunRecord`` from the moment it appears under its final name,
    /// so the sidebar and ``listAnalyses(in:)`` skip it while the run is in
    /// progress. It is assembled under a hidden staging name and renamed into
    /// place with `RENAME_EXCL`, so no listing ever sees it without its record.
    ///
    /// The run that created it must signal success with
    /// ``markAnalysisComplete(_:)`` (in the app, by tracking the directory with
    /// `OperationCenter.trackAnalysisOutput(_:for:)`), which makes it visible.
    /// A failed run removes it with ``discardFailedAnalysisDirectory(_:)``. An
    /// interrupted run keeps the record and stays hidden until the user
    /// removes it from the Operations Panel.
    ///
    /// - Parameters:
    ///   - tool: The tool identifier (e.g. `"kraken2"`).
    ///   - projectURL: Path to the project directory.
    ///   - isBatch: Whether this is a batch run.
    ///   - date: The date to embed in the directory name (defaults to now).
    ///   - command: The reproducible CLI command, recorded for interrupted-run review.
    /// - Returns: URL of the newly created analysis directory.
    @discardableResult
    public static func createAnalysisDirectory(
        tool: String,
        in projectURL: URL,
        isBatch: Bool = false,
        date: Date = Date(),
        command: String? = nil
    ) throws -> URL {
        let analysesDir = try url(for: projectURL)
        let timestamp = formatTimestamp(date)
        let baseName = isBatch ? "\(tool)-batch-\(timestamp)" : "\(tool)-\(timestamp)"
        let metadata = AnalysisMetadata(tool: tool, isBatch: isBatch, created: date)
        let fileManager = FileManager.default

        let stagingURL = analysesDir.appendingPathComponent(
            ".\(baseName).creating-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        do {
            try AnalysisRunRecord.begin(
                AnalysisRunRecord(analysisName: displayName(for: tool), command: command, startedAt: Date()),
                in: stagingURL
            )
            // Write analysis-metadata.json so the directory is identifiable even if renamed.
            try writeAnalysisMetadata(metadata, to: stagingURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        for attempt in 0..<1_000 {
            let name = attempt == 0 ? baseName : "\(baseName)-\(attempt + 1)"
            let analysisURL = analysesDir.appendingPathComponent(name, isDirectory: true)
            let status = stagingURL.path.withCString { source in
                analysisURL.path.withCString { destination in
                    // ExFAT, FAT and SMB volumes reject RENAME_EXCL with
                    // ENOTSUP, and the portable rename falls back for them.
                    PortableRename.renameatxNP(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
                }
            }
            if status == 0 {
                logger.info("Created analysis directory: \(name)")
                return analysisURL
            }
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                continue
            }
            try? fileManager.removeItem(at: stagingURL)
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: analysisURL.path,
                    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                ]
            )
        }

        try? fileManager.removeItem(at: stagingURL)
        throw CocoaError(
            .fileWriteFileExists,
            userInfo: [
                NSFilePathErrorKey: analysesDir.appendingPathComponent(baseName, isDirectory: true).path,
                NSLocalizedDescriptionKey: "Could not create a unique analysis directory for \(baseName)"
            ]
        )
    }

    // MARK: - Caller-Chosen Output Directories

    /// Claims a caller-chosen output directory (such as a `lungfish-cli
    /// --output-dir`) for a run that fills it in place, so it stays out of
    /// the sidebar and listings until the run completes.
    ///
    /// Only a directory that is, or will be, the run's own result inside a
    /// project is claimed:
    ///
    /// - it must sit inside `projectURL`, or inside the `.lungfish` project
    ///   that encloses it when `projectURL` is `nil`;
    /// - it must not be the project itself or its `Analyses` folder;
    /// - an existing directory must be empty or already carry a run record.
    ///   A directory that already holds other content is left alone, because
    ///   a record would hide that content too.
    ///
    /// - Returns: The claim (see ``AnalysisRunRecord/beginRun(in:record:processProbe:)``),
    ///   or `nil` when the directory is left alone. After a successful run
    ///   the caller passes a non-`nil` claim to
    ///   ``AnalysisRunRecord/completeRun(_:in:processProbe:)``.
    public static func beginRunInOutputDirectory(
        _ outputDirectory: URL,
        projectURL: URL? = nil,
        record: AnalysisRunRecord
    ) throws -> AnalysisRunRecord.RunClaim? {
        let directory = outputDirectory.standardizedFileURL
        guard let project = (projectURL ?? ProjectTempDirectory.findProjectRoot(directory.deletingLastPathComponent()))?
            .standardizedFileURL,
              let relative = CanonicalFilePath.relativePath(of: directory, within: project),
              !relative.isEmpty,
              relative != directoryName else {
            return nil
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return nil }
            if !AnalysisRunRecord.isIncomplete(directory) {
                let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
                guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return nil }
            }
        }
        return try AnalysisRunRecord.beginRun(in: directory, record: record)
    }

    // MARK: - Run Completion

    /// Marks an analysis directory complete, so it is listed. The producer
    /// calls this as the last step of a successful run (completed with
    /// warnings counts as successful). Safe on a directory without a record.
    @discardableResult
    public static func markAnalysisComplete(_ analysisDirectory: URL) -> Bool {
        AnalysisRunRecord.markComplete(analysisDirectory)
    }

    /// Whether the directory's run has not been marked complete.
    public static func isAnalysisIncomplete(_ analysisDirectory: URL) -> Bool {
        AnalysisRunRecord.isIncomplete(analysisDirectory)
    }

    /// The nearest directory at or above `url` that carries a run record, for
    /// example the batch root of a per-sample directory.
    public static func enclosingIncompleteAnalysisDirectory(for url: URL) -> URL? {
        AnalysisRunRecord.enclosingIncompleteDirectory(for: url)
    }

    /// An analysis directory whose run never marked it complete.
    public struct IncompleteAnalysisRun: Sendable {
        public let directory: URL
        /// `nil` when the record exists but cannot be read.
        public let record: AnalysisRunRecord?
    }

    /// Lists every incomplete analysis directory under the project's
    /// `Analyses/` tree, including inside user grouping folders. Contents of
    /// an incomplete directory are not searched further.
    public static func incompleteAnalysisRuns(in projectURL: URL) -> [IncompleteAnalysisRun] {
        let root = projectURL.appendingPathComponent(directoryName, isDirectory: true)
        var results: [IncompleteAnalysisRun] = []
        func visit(_ directory: URL, depth: Int) {
            guard depth < 8,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { return }
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if AnalysisRunRecord.isIncomplete(child) {
                    results.append(IncompleteAnalysisRun(directory: child, record: AnalysisRunRecord.load(from: child)))
                    continue
                }
                if analysisInfo(for: child) != nil || child.pathExtension.lowercased().hasPrefix("lungfish") {
                    continue
                }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return results.sorted { $0.directory.path < $1.directory.path }
    }

    // MARK: - Batch Sample Naming

    /// Returns a per-sample subdirectory inside a batch analysis directory,
    /// creating it.
    ///
    /// `sampleName` is sanitized (see ``sanitizeBatchSampleName(_:)``) and
    /// deduped against existing entries in `batchDirectory` by appending
    /// `-2`, `-3`, ... on collision, following the same collision-loop idiom
    /// as ``createAnalysisDirectory(tool:in:isBatch:date:)``.
    ///
    /// - Parameters:
    ///   - sampleName: The source bundle's display name.
    ///   - batchDirectory: The batch analysis directory (e.g. from
    ///     `createAnalysisDirectory(tool:in:isBatch: true)`).
    /// - Returns: URL of the newly created per-sample directory.
    @discardableResult
    public static func batchSampleDirectory(named sampleName: String, in batchDirectory: URL) throws -> URL {
        let baseName = sanitizeBatchSampleName(sampleName)
        let fileManager = FileManager.default

        for attempt in 0..<1_000 {
            let name = attempt == 0 ? baseName : "\(baseName)-\(attempt + 1)"
            let sampleURL = batchDirectory.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: sampleURL, withIntermediateDirectories: false)
                return sampleURL
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == CocoaError.Code.fileWriteFileExists.rawValue {
                    continue
                }
                throw error
            }
        }

        throw CocoaError(
            .fileWriteFileExists,
            userInfo: [
                NSFilePathErrorKey: batchDirectory.appendingPathComponent(baseName, isDirectory: true).path,
                NSLocalizedDescriptionKey: "Could not create a unique sample directory for \(baseName)"
            ]
        )
    }

    /// Returns a per-sample flat-file URL inside a batch analysis directory,
    /// using the same sanitize+dedup policy as
    /// ``batchSampleDirectory(named:in:)`` — does NOT create the file
    /// (callers write it).
    ///
    /// - Parameters:
    ///   - sampleName: The source bundle's display name (or input stem for
    ///     loose files).
    ///   - ext: The file extension, without a leading dot (e.g. `"fasta"`).
    ///   - batchDirectory: The batch analysis directory.
    /// - Returns: URL of the (not-yet-existing) per-sample file, unique
    ///   among `batchDirectory`'s existing entries.
    public static func batchSampleFileURL(named sampleName: String, extension ext: String, in batchDirectory: URL) -> URL {
        let baseName = sanitizeBatchSampleName(sampleName)
        let fileManager = FileManager.default

        for attempt in 0..<1_000 {
            let name = attempt == 0 ? baseName : "\(baseName)-\(attempt + 1)"
            let fileURL = batchDirectory.appendingPathComponent(name).appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }

        // Exhausted the collision range; return the last candidate rather than
        // trap — callers write the file themselves and can surface a write error.
        return batchDirectory.appendingPathComponent("\(baseName)-1000").appendingPathExtension(ext)
    }

    /// Sanitizes a source bundle's display name for use as a batch sample
    /// directory/file name.
    ///
    /// Replicates the character policy of
    /// `MetagenomicsSampleGrouper.sanitizeSampleId` in
    /// `Sources/LungfishApp/Views/Metagenomics/MetagenomicsSampleInput.swift:105-114`
    /// (LungfishIO cannot depend on LungfishApp, so this is a private copy,
    /// not a shared extraction — keep the two policies in sync if either
    /// changes). Falls back to `"sample"` for an empty/all-punctuation name.
    private static func sanitizeBatchSampleName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "sample" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return collapsed.isEmpty ? "sample" : collapsed
    }

    // MARK: - Batch Cleanup

    /// Removes `batchDirectory` if, after all of its children have reached a
    /// terminal state, it contains no sample entries beyond the
    /// `analysis-metadata.json` sidecar written at creation time (spec §6:
    /// empty-batch cleanup, run only once ALL children are terminal, never
    /// mid-flight).
    ///
    /// The emptiness check is recursive by ONE level: batch orchestrators
    /// (e.g. `precomputedMappingBatchOutputDirectories`) pre-create every
    /// child's sample directory (empty) before any child runs, so a shallow
    /// top-level listing would always see N directory entries -- even when
    /// every child failed before writing anything, or a bundle was never
    /// reached because the batch was cancelled mid-flight. A top-level entry
    /// counts as "content" (and blocks removal) iff it is EITHER a
    /// non-directory (any flat file some future producer might leave at the
    /// batch root, `analysis-metadata.json` excluded) OR a directory that
    /// itself has at least one entry. A pre-created-but-still-empty child
    /// directory does not block removal; a child directory containing
    /// partial output (from a child that failed AFTER writing something)
    /// does. This deliberately does NOT remove individual empty child
    /// directories on its own (that would be child-side cleanup, which the
    /// design rules out -- a failed child's partial output must still block
    /// the whole batch from being removed) -- it only decides whether the
    /// WHOLE batch directory, including its still-empty children, is
    /// removable as a unit.
    ///
    /// A missing directory (e.g. cleaned up by a previous call, or a
    /// caller passing an already-nonexistent URL in a test) is a silent
    /// no-op, not an error -- this is a best-effort tidy-up, not a
    /// correctness-critical step.
    public static func removeBatchDirectoryIfEffectivelyEmpty(_ batchDirectory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: batchDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        let hasContent = entries.contains { entry in
            guard entry.lastPathComponent != metadataFilename else { return false }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else {
                // A non-directory, non-metadata entry at the batch root is
                // content in its own right.
                return true
            }
            // A pre-created child sample directory only counts as content
            // if it has something inside it.
            let childEntries = (try? fileManager.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            return !childEntries.isEmpty
        }
        guard !hasContent else { return }

        try? fileManager.removeItem(at: batchDirectory)
    }

    /// Removes the result directory of an analysis run that failed or was
    /// cancelled.
    ///
    /// ``createAnalysisDirectory(tool:in:isBatch:date:)`` writes
    /// `analysis-metadata.json` before the tool runs, so a failed run left a
    /// folder the sidebar lists as an ordinary analysis even though it holds
    /// no result. The run that created the directory calls this on failure.
    ///
    /// Only a directory inside a project's `Analyses/` tree is removed (a
    /// caller-chosen `--output-dir` elsewhere is never touched). After a
    /// batch sample directory is removed, its batch directory is removed too
    /// when nothing else is left in it.
    ///
    /// - Returns: `true` when the directory was removed.
    @discardableResult
    public static func discardFailedAnalysisDirectory(_ analysisDirectory: URL) -> Bool {
        let directory = analysisDirectory.standardizedFileURL
        let ancestors = directory.deletingLastPathComponent().pathComponents
        guard ancestors.contains(directoryName),
              directory.lastPathComponent != directoryName else { return false }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.warning("Could not remove failed analysis directory \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        logger.info("Removed failed analysis directory \(directory.lastPathComponent, privacy: .public)")
        let parent = directory.deletingLastPathComponent()
        if parent.lastPathComponent != directoryName,
           readAnalysisMetadata(from: parent)?.isBatch == true {
            removeBatchDirectoryIfEffectivelyEmpty(parent)
        }
        return true
    }

    // MARK: - Listing

    /// Lists all analysis directories in `Analyses/`, sorted newest first.
    ///
    /// User-created folders inside `Analyses/` are traversed recursively so
    /// grouped analysis runs remain discoverable. Directories whose names and
    /// contents cannot be recognized as analyses are ignored, and so are
    /// incomplete runs (see ``AnalysisRunRecord``). Returns an empty array if
    /// `Analyses/` does not exist.
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

    /// Returns the nearest ancestor of `url` that is recognized as an analysis directory.
    ///
    /// This supports user-created grouping folders under `Analyses/` by walking upward
    /// until a directory has analysis metadata, a recognized analysis name, or legacy
    /// sidecar signatures.
    public static func enclosingAnalysisDirectory(for url: URL, projectURL: URL) -> URL? {
        let analysesURL = projectURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let analysesComponents = analysesURL.pathComponents
        var current = url.standardizedFileURL.resolvingSymlinksInPath()
        guard current.pathComponents.count > analysesComponents.count,
              current.pathComponents.starts(with: analysesComponents) else {
            return nil
        }

        while current.pathComponents.count > analysesComponents.count {
            if let info = analysisInfo(for: current) {
                return info.url.standardizedFileURL
            }
            current = current.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        }
        return nil
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
            // A run that has not marked its directory complete is not a result yet.
            if AnalysisRunRecord.isIncomplete(url) {
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
        for entry in AnalysisToolRegistry.directoryPrefixes {
            if name.hasPrefix(entry.batch) {
                let timestampPart = String(name.dropFirst(entry.batch.count))
                if let date = parseTimestamp(timestampPart) {
                    return AnalysisDirectoryInfo(url: url, tool: entry.id.rawValue, timestamp: date, isBatch: true)
                }
            }
        }

        // Try single pattern: {tool}-{timestamp}
        for entry in AnalysisToolRegistry.directoryPrefixes {
            if name.hasPrefix(entry.single) {
                let timestampPart = String(name.dropFirst(entry.single.count))
                if let date = parseTimestamp(timestampPart) {
                    return AnalysisDirectoryInfo(url: url, tool: entry.id.rawValue, timestamp: date, isBatch: false)
                }
            }
        }

        // Fallback for imported results that use {tool}-{sampleName} naming
        // (e.g. naomgs-MU-CASPER-2026-03-31-a-..., nvd-SampleName).
        // Uses the directory's filesystem creation date as the timestamp.
        for entry in AnalysisToolRegistry.directoryPrefixes
        where AnalysisToolRegistry.importedResultIDs.contains(entry.id.rawValue) {
            if name.hasPrefix(entry.single), !String(name.dropFirst(entry.single.count)).isEmpty {
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                return AnalysisDirectoryInfo(url: url, tool: entry.id.rawValue, timestamp: date, isBatch: false)
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
        let czIdManifest = url.appendingPathComponent("cz-id-manifest.json")
        let assemblyResult = url.appendingPathComponent("assembly-result.json")
        let mappingResult = url.appendingPathComponent("mapping-result.json")
        let viralReconResult = url.appendingPathComponent("viralrecon-result.json")
        let msaManifest = url.appendingPathComponent("manifest.json")
        let alignedFASTA = url.appendingPathComponent("alignment/primary.aligned.fasta")

        if fm.fileExists(atPath: czIdManifest.path),
           fm.fileExists(atPath: classificationResult.path) {
            return "cz-id"
        }

        // Kraken2: has classification-result.json
        if fm.fileExists(atPath: classificationResult.path) {
            return "kraken2"
        }

        // Viral Recon: has viralrecon-result.json.
        if fm.fileExists(atPath: viralReconResult.path) {
            return "viralrecon"
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
