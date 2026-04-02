// MetagenomicsImportService.swift - Shared import routines for metagenomics result folders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "MetagenomicsImport")

/// Supported classifier result types for CLI-backed import.
public enum MetagenomicsImportKind: String, CaseIterable, Codable, Sendable {
    case kraken2
    case esviritu
    case taxtriage
    case naomgs

    /// Directory prefix used for imported result folders.
    public var directoryPrefix: String {
        switch self {
        case .kraken2:
            return "classification-"
        case .esviritu:
            return "esviritu-"
        case .taxtriage:
            return "taxtriage-"
        case .naomgs:
            return "naomgs-"
        }
    }
}

/// Result metadata for an imported Kraken2 classification directory.
public struct Kraken2ImportResult: Sendable {
    public let resultDirectory: URL
    public let totalReads: Int
    public let speciesCount: Int

    public init(resultDirectory: URL, totalReads: Int, speciesCount: Int) {
        self.resultDirectory = resultDirectory
        self.totalReads = totalReads
        self.speciesCount = speciesCount
    }
}

/// Result metadata for an imported EsViritu result directory.
public struct EsVirituImportResult: Sendable {
    public let resultDirectory: URL
    public let importedFileCount: Int
    public let virusCount: Int

    public init(resultDirectory: URL, importedFileCount: Int, virusCount: Int) {
        self.resultDirectory = resultDirectory
        self.importedFileCount = importedFileCount
        self.virusCount = virusCount
    }
}

/// Result metadata for an imported TaxTriage result directory.
public struct TaxTriageImportResult: Sendable {
    public let resultDirectory: URL
    public let importedFileCount: Int
    public let reportEntryCount: Int

    public init(resultDirectory: URL, importedFileCount: Int, reportEntryCount: Int) {
        self.resultDirectory = resultDirectory
        self.importedFileCount = importedFileCount
        self.reportEntryCount = reportEntryCount
    }
}

/// Result metadata for an imported NAO-MGS result directory.
public struct NaoMgsImportResult: Sendable {
    public let resultDirectory: URL
    public let sampleName: String
    public let totalHitReads: Int
    public let taxonCount: Int
    public let fetchedReferenceCount: Int
    public let createdBAM: Bool

    public init(
        resultDirectory: URL,
        sampleName: String,
        totalHitReads: Int,
        taxonCount: Int,
        fetchedReferenceCount: Int,
        createdBAM: Bool
    ) {
        self.resultDirectory = resultDirectory
        self.sampleName = sampleName
        self.totalHitReads = totalHitReads
        self.taxonCount = taxonCount
        self.fetchedReferenceCount = fetchedReferenceCount
        self.createdBAM = createdBAM
    }
}

/// Errors thrown while importing classifier outputs.
public enum MetagenomicsImportError: Error, LocalizedError, Sendable {
    case inputNotFound(URL)
    case outputDirectoryCreationFailed(URL, String)
    case copyFailed(source: URL, destination: URL, reason: String)
    case parseFailed(URL, String)
    case toolUnavailable(String)
    case importAborted(resultDirectory: URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let url):
            return "Input path not found: \(url.path)"
        case .outputDirectoryCreationFailed(let url, let reason):
            return "Could not create output directory at \(url.path): \(reason)"
        case .copyFailed(let source, let destination, let reason):
            return "Failed to copy \(source.lastPathComponent) to \(destination.path): \(reason)"
        case .parseFailed(let url, let reason):
            return "Failed to parse \(url.lastPathComponent): \(reason)"
        case .toolUnavailable(let tool):
            return "Required tool is unavailable: \(tool)"
        case .importAborted(_, let underlying):
            return "Import aborted: \(underlying.localizedDescription)"
        }
    }
}

/// Shared import routines used by both `lungfish-cli import` and GUI helper mode.
public enum MetagenomicsImportService {
    /// Imports a Kraken2 report/output into a canonical result directory.
    ///
    /// The imported folder always contains:
    /// - `classification.kreport`
    /// - `classification.kraken` (empty placeholder when no output file is supplied)
    /// - `classification-result.json`
    public static func importKraken2(
        kreportURL: URL,
        outputDirectory: URL,
        outputFileURL: URL? = nil,
        preferredName: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> Kraken2ImportResult {
        let fm = FileManager.default

        guard fm.fileExists(atPath: kreportURL.path) else {
            throw MetagenomicsImportError.inputNotFound(kreportURL)
        }
        if let outputFileURL, !fm.fileExists(atPath: outputFileURL.path) {
            throw MetagenomicsImportError.inputNotFound(outputFileURL)
        }

        try ensureDirectoryExists(outputDirectory)

        let baseName = normalizedBaseName(
            preferredName: preferredName,
            fallback: kreportURL.deletingPathExtension().lastPathComponent
        )
        let resultDirectory = makeUniqueResultDirectory(
            prefix: MetagenomicsImportKind.kraken2.directoryPrefix,
            baseName: baseName,
            in: outputDirectory
        )

        progress?(0.05, "Preparing output directory...")
        try ensureDirectoryExists(resultDirectory)
        OperationMarker.markInProgress(resultDirectory, detail: "Importing Kraken2 results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }

        let canonicalReportURL = resultDirectory.appendingPathComponent("classification.kreport")
        progress?(0.25, "Copying report...")
        try copyFile(kreportURL, to: canonicalReportURL)

        let canonicalOutputURL = resultDirectory.appendingPathComponent("classification.kraken")
        progress?(0.45, "Copying read classifications...")
        if let outputFileURL {
            try copyFile(outputFileURL, to: canonicalOutputURL)
        } else {
            if !fm.createFile(atPath: canonicalOutputURL.path, contents: nil) {
                throw MetagenomicsImportError.copyFailed(
                    source: kreportURL,
                    destination: canonicalOutputURL,
                    reason: "Could not create placeholder output file"
                )
            }
        }

        progress?(0.65, "Parsing kreport...")
        let tree: TaxonTree
        do {
            tree = try KreportParser.parse(url: canonicalReportURL)
        } catch {
            throw MetagenomicsImportError.parseFailed(canonicalReportURL, error.localizedDescription)
        }

        progress?(0.85, "Writing sidecar...")
        let config = ClassificationConfig(
            goal: .classify,
            inputFiles: [],
            isPairedEnd: false,
            databaseName: "imported",
            databasePath: URL(fileURLWithPath: "/imported"),
            outputDirectory: resultDirectory
        )
        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: canonicalReportURL,
            outputURL: canonicalOutputURL,
            brackenURL: nil,
            runtime: 0,
            toolVersion: "imported",
            provenanceId: nil
        )
        do {
            try result.save(to: resultDirectory)
        } catch {
            throw MetagenomicsImportError.copyFailed(
                source: canonicalReportURL,
                destination: resultDirectory.appendingPathComponent("classification-result.json"),
                reason: error.localizedDescription
            )
        }

        progress?(1.0, "Kraken2 import complete")
        return Kraken2ImportResult(
            resultDirectory: resultDirectory,
            totalReads: tree.totalReads,
            speciesCount: tree.speciesCount
        )
    }

    /// Imports EsViritu files into a canonical result directory and writes `esviritu-result.json`.
    public static func importEsViritu(
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> EsVirituImportResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputURL.path) else {
            throw MetagenomicsImportError.inputNotFound(inputURL)
        }

        try ensureDirectoryExists(outputDirectory)

        let baseName = normalizedBaseName(
            preferredName: preferredName,
            fallback: inputURL.deletingPathExtension().lastPathComponent
        )
        let resultDirectory = makeUniqueResultDirectory(
            prefix: MetagenomicsImportKind.esviritu.directoryPrefix,
            baseName: baseName,
            in: outputDirectory
        )
        try ensureDirectoryExists(resultDirectory)
        OperationMarker.markInProgress(resultDirectory, detail: "Importing EsViritu results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }
        progress?(0.05, "Copying EsViritu files...")

        let copiedFiles = try copyInputPayload(from: inputURL, into: resultDirectory)
        let copiedRegularFiles = copiedFiles.filter { isRegularFile($0) }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }

        progress?(0.45, "Discovering detection files...")
        let detected = detectEsVirituFiles(in: copiedRegularFiles)
        let sampleName = resolveEsVirituSampleName(
            preferredName: preferredName,
            inputURL: inputURL,
            detectionURL: detected.detectionURL
        )

        let detectionURL: URL
        if let discoveredDetection = detected.detectionURL {
            detectionURL = discoveredDetection
        } else {
            // Keep sidecar loadable even for partial exports lacking the primary TSV.
            detectionURL = resultDirectory.appendingPathComponent("\(sampleName).detected_virus.info.tsv")
            if !fm.fileExists(atPath: detectionURL.path) {
                if !fm.createFile(atPath: detectionURL.path, contents: Data()) {
                    throw MetagenomicsImportError.copyFailed(
                        source: inputURL,
                        destination: detectionURL,
                        reason: "Could not create fallback detection TSV"
                    )
                }
            }
        }

        progress?(0.65, "Parsing detections...")
        let virusCount: Int
        if let detections = try? EsVirituDetectionParser.parse(url: detectionURL) {
            virusCount = detections.count
        } else {
            virusCount = countDataRows(in: detectionURL)
        }

        progress?(0.85, "Writing sidecar...")
        let pipelineResult = EsVirituResult(
            config: EsVirituConfig(
                inputFiles: [inputURL],
                isPairedEnd: false,
                sampleName: sampleName,
                outputDirectory: resultDirectory,
                databasePath: URL(fileURLWithPath: "/imported"),
                qualityFilter: false
            ),
            detectionURL: detectionURL,
            assemblyURL: detected.assemblyURL,
            taxProfileURL: detected.taxProfileURL,
            coverageURL: detected.coverageURL,
            virusCount: virusCount,
            runtime: 0,
            toolVersion: "imported",
            provenanceId: nil
        )
        try pipelineResult.save(to: resultDirectory)

        progress?(1.0, "EsViritu import complete")
        return EsVirituImportResult(
            resultDirectory: resultDirectory,
            importedFileCount: copiedRegularFiles.count,
            virusCount: virusCount
        )
    }

    /// Imports TaxTriage files into a canonical result directory and writes `taxtriage-result.json`.
    public static func importTaxTriage(
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> TaxTriageImportResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputURL.path) else {
            throw MetagenomicsImportError.inputNotFound(inputURL)
        }

        try ensureDirectoryExists(outputDirectory)

        let baseName = normalizedBaseName(
            preferredName: preferredName,
            fallback: inputURL.deletingPathExtension().lastPathComponent
        )
        let resultDirectory = makeUniqueResultDirectory(
            prefix: MetagenomicsImportKind.taxtriage.directoryPrefix,
            baseName: baseName,
            in: outputDirectory
        )
        try ensureDirectoryExists(resultDirectory)
        OperationMarker.markInProgress(resultDirectory, detail: "Importing TaxTriage results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }
        progress?(0.05, "Copying TaxTriage files...")

        _ = try copyInputPayload(from: inputURL, into: resultDirectory)
        let allOutputFiles = scanRegularFilesRecursively(in: resultDirectory)

        progress?(0.55, "Detecting report files...")
        let reportFiles = allOutputFiles.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            return name.contains("report") && (ext == "txt" || ext == "tsv")
        }

        let metricsFiles = allOutputFiles.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            return name.contains("tass")
                || name.contains("metrics")
                || name.contains("confidence")
                || (ext == "tsv" && !name.contains("trace") && !name.contains("samplesheet"))
        }

        let kronaFiles = allOutputFiles.filter {
            let name = $0.lastPathComponent.lowercased()
            let ext = $0.pathExtension.lowercased()
            let path = $0.path.lowercased()
            return ext == "html" && (name.contains("krona") || path.contains("/krona/"))
        }

        let reportEntries = reportFiles.first.map(countDataRows(in:)) ?? 0

        progress?(0.85, "Writing sidecar...")
        let result = TaxTriageResult(
            config: TaxTriageConfig(
                samples: [],
                outputDirectory: resultDirectory
            ),
            runtime: 0,
            exitCode: 0,
            outputDirectory: resultDirectory,
            reportFiles: reportFiles,
            metricsFiles: metricsFiles,
            kronaFiles: kronaFiles,
            logFile: nil,
            traceFile: nil,
            allOutputFiles: allOutputFiles
        )
        try result.save()

        progress?(1.0, "TaxTriage import complete")
        return TaxTriageImportResult(
            resultDirectory: resultDirectory,
            importedFileCount: allOutputFiles.count,
            reportEntryCount: reportEntries
        )
    }

    /// Imports NAO-MGS results into a canonical result directory:
    /// - `manifest.json`
    /// - `hits.sqlite` (SQLite database with all hits and taxon summaries)
    /// - `references/*.fasta` (best-effort fetch from NCBI)
    public static func importNaoMgs(
        inputURL: URL,
        outputDirectory: URL,
        sampleName: String? = nil,
        minIdentity: Double = 0,
        fetchReferences: Bool = true,
        preferredName: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> NaoMgsImportResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputURL.path) else {
            throw MetagenomicsImportError.inputNotFound(inputURL)
        }

        try ensureDirectoryExists(outputDirectory)
        let parser = NaoMgsResultParser()

        progress?(0.05, "Parsing NAO-MGS virus hits...")
        let loaded = try await parser.loadResults(from: inputURL, sampleName: sampleName)

        let identityFloor = max(0, min(100, minIdentity))
        let filteredHits: [NaoMgsVirusHit]
        if identityFloor > 0 {
            filteredHits = loaded.virusHits.filter { $0.percentIdentity >= identityFloor }
        } else {
            filteredHits = loaded.virusHits
        }

        let normalizedSampleName = normalizeSampleName(
            explicitName: sampleName,
            fallback: loaded.sampleName
        )
        let summaries = parser.aggregateByTaxon(filteredHits)

        let result = NaoMgsResult(
            virusHits: filteredHits,
            taxonSummaries: summaries,
            totalHitReads: filteredHits.count,
            sampleName: normalizedSampleName,
            sourceDirectory: loaded.sourceDirectory,
            virusHitsFile: loaded.virusHitsFile
        )

        let baseName = normalizedBaseName(
            preferredName: preferredName ?? normalizedSampleName,
            fallback: normalizedSampleName
        )
        let resultDirectory = makeUniqueResultDirectory(
            prefix: MetagenomicsImportKind.naomgs.directoryPrefix,
            baseName: baseName,
            in: outputDirectory
        )
        try ensureDirectoryExists(resultDirectory)
        OperationMarker.markInProgress(resultDirectory, detail: "Importing NAO-MGS results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }

        do {
        progress?(0.15, "Creating NAO-MGS database\u{2026}")
        let hitsDBURL = resultDirectory.appendingPathComponent("hits.sqlite")
        try NaoMgsDatabase.create(at: hitsDBURL, hits: filteredHits) { dbProgress, dbMessage in
            progress?(0.15 + dbProgress * 0.40, dbMessage)
        }

        // Resolve taxon names from local NCBI Taxonomy database.
        progress?(0.56, "Resolving taxon names\u{2026}")
        do {
            let rwDB = try NaoMgsDatabase.openReadWrite(at: hitsDBURL)
            let unresolvedIds = try rwDB.taxonIdsNeedingNames()
            if !unresolvedIds.isEmpty {
                // Try to find installed NCBI Taxonomy database
                let registry = MetagenomicsDatabaseRegistry.shared
                if let taxonomyDB = try await registry.installedDatabase(tool: .ncbiTaxonomy),
                   let taxonomyPath = taxonomyDB.path {
                    let resolver = try TaxonomyNameResolver(taxonomyDirectory: taxonomyPath)
                    let resolvedNames = resolver.resolve(taxIds: unresolvedIds)
                    if !resolvedNames.isEmpty {
                        try rwDB.updateTaxonNames(resolvedNames)
                    }
                    logger.info("Resolved \(resolvedNames.count)/\(unresolvedIds.count) taxon names from local taxonomy DB")
                } else {
                    logger.warning("NCBI Taxonomy database not installed \u{2014} taxon names will show as IDs. Install via Plugin Manager > Databases.")
                }
            }
        } catch {
            // Best-effort: if name resolution fails, placeholder names remain.
            logger.warning("Taxon name resolution failed: \(error.localizedDescription, privacy: .public)")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var manifest = NaoMgsManifest(
            sampleName: normalizedSampleName,
            sourceFilePath: loaded.virusHitsFile.path,
            hitCount: result.totalHitReads,
            taxonCount: result.taxonSummaries.count,
            topTaxon: result.taxonSummaries.first?.name,
            topTaxonId: result.taxonSummaries.first?.taxId
        )
        try writeNaoMgsManifest(manifest, to: resultDirectory, encoder: encoder)

        var fetchedAccessions: [String] = []
        if fetchReferences {
            let referencesDirectory = resultDirectory.appendingPathComponent("references", isDirectory: true)
            try ensureDirectoryExists(referencesDirectory)
            progress?(0.70, "Fetching reference FASTA files...")
            let accessions = selectTopAccessionsPerTaxon(hits: result.virusHits, maxPerTaxon: 5)
            fetchedAccessions = await fetchNaoMgsReferences(
                accessions: accessions,
                into: referencesDirectory,
                progress: progress
            )
            manifest.fetchedAccessions = fetchedAccessions
            try writeNaoMgsManifest(manifest, to: resultDirectory, encoder: encoder)
        }

        progress?(1.0, "NAO-MGS import complete")
        return NaoMgsImportResult(
            resultDirectory: resultDirectory,
            sampleName: normalizedSampleName,
            totalHitReads: result.totalHitReads,
            taxonCount: result.taxonSummaries.count,
            fetchedReferenceCount: fetchedAccessions.count,
            createdBAM: false
        )
        } catch {
            throw MetagenomicsImportError.importAborted(
                resultDirectory: resultDirectory,
                underlying: error
            )
        }
    }

    /// Selects the top N accessions per taxon by hit count, deduplicated across taxa.
    public static func selectTopAccessionsPerTaxon(
        hits: [NaoMgsVirusHit],
        maxPerTaxon: Int = 5
    ) -> [String] {
        var taxonHits: [Int: [NaoMgsVirusHit]] = [:]
        for hit in hits where !hit.subjectSeqId.isEmpty {
            taxonHits[hit.taxId, default: []].append(hit)
        }

        var selectedAccessions: Set<String> = []

        for (_, hitsForTaxon) in taxonHits {
            var accessionCounts: [String: Int] = [:]
            for hit in hitsForTaxon {
                accessionCounts[hit.subjectSeqId, default: 0] += 1
            }

            let sorted = accessionCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }

            for entry in sorted.prefix(maxPerTaxon) {
                selectedAccessions.insert(entry.key)
            }
        }

        return selectedAccessions.sorted()
    }

    /// Splits a concatenated multi-record FASTA string into individual records.
    ///
    /// - Parameter fasta: Concatenated FASTA text (multiple `>` headers).
    /// - Returns: Dictionary mapping accession (first token after `>`) to full FASTA record text.
    public static func splitMultiRecordFASTA(_ fasta: String) -> [String: String] {
        guard !fasta.isEmpty else { return [:] }

        var records: [String: String] = [:]
        var currentAccession: String?
        var currentLines: [String] = []

        for line in fasta.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(">") {
                if let acc = currentAccession, !currentLines.isEmpty {
                    records[acc] = currentLines.joined(separator: "\n")
                }
                let header = line.dropFirst()
                let accession = header.split(separator: " ", maxSplits: 1).first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                currentAccession = accession.isEmpty ? nil : accession
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        if let acc = currentAccession, !currentLines.isEmpty {
            records[acc] = currentLines.joined(separator: "\n")
        }

        return records
    }
}

// MARK: - Internal Helpers

private struct EsVirituDetectedFiles {
    let detectionURL: URL?
    let assemblyURL: URL?
    let taxProfileURL: URL?
    let coverageURL: URL?
}

private func ensureDirectoryExists(_ directory: URL) throws {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw MetagenomicsImportError.outputDirectoryCreationFailed(
            directory,
            error.localizedDescription
        )
    }
}

private func copyFile(_ source: URL, to destination: URL) throws {
    let fm = FileManager.default
    do {
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    } catch {
        throw MetagenomicsImportError.copyFailed(
            source: source,
            destination: destination,
            reason: error.localizedDescription
        )
    }
}

private func normalizedBaseName(preferredName: String?, fallback: String) -> String {
    let raw = (preferredName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        ? preferredName!
        : fallback
    return sanitizePathComponent(raw)
}

private func sanitizePathComponent(_ raw: String) -> String {
    let scalars = raw.unicodeScalars.map { scalar -> UnicodeScalar in
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return allowed.contains(scalar) ? scalar : "_"
    }
    let collapsed = String(String.UnicodeScalarView(scalars))
        .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return collapsed.isEmpty ? "imported" : collapsed
}

private func makeUniqueResultDirectory(prefix: String, baseName: String, in parent: URL) -> URL {
    let fm = FileManager.default
    let base = "\(prefix)\(baseName)"
    let firstCandidate = parent.appendingPathComponent(base, isDirectory: true)
    if !fm.fileExists(atPath: firstCandidate.path) {
        return firstCandidate
    }

    var index = 2
    while true {
        let candidate = parent.appendingPathComponent("\(base)-\(index)", isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        index += 1
    }
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

private func isRegularFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true
}

private func copyInputPayload(from source: URL, into destinationRoot: URL) throws -> [URL] {
    if isDirectory(source) {
        return try copyDirectoryContents(from: source, into: destinationRoot)
    }
    let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
    try copyFile(source, to: destination)
    return [destination]
}

private func copyDirectoryContents(from sourceDirectory: URL, into destinationDirectory: URL) throws -> [URL] {
    let fm = FileManager.default
    let sourcePath = sourceDirectory.standardizedFileURL.path

    guard let enumerator = fm.enumerator(
        at: sourceDirectory,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var copiedURLs: [URL] = []
    for case let sourceURL as URL in enumerator {
        let relativePath = sourceURL.standardizedFileURL.path
            .replacingOccurrences(of: sourcePath + "/", with: "")
        guard !relativePath.isEmpty else { continue }
        let destinationURL = destinationDirectory.appendingPathComponent(relativePath)

        if isDirectory(sourceURL) {
            try ensureDirectoryExists(destinationURL)
            copiedURLs.append(destinationURL)
            continue
        }

        try copyFile(sourceURL, to: destinationURL)
        copiedURLs.append(destinationURL)
    }

    return copiedURLs
}

private func scanRegularFilesRecursively(in directory: URL) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    return enumerator
        .compactMap { $0 as? URL }
        .filter { isRegularFile($0) }
        .sorted { $0.path < $1.path }
}

private func detectEsVirituFiles(in files: [URL]) -> EsVirituDetectedFiles {
    let detectionURL = files.first { url in
        let lower = url.lastPathComponent.lowercased()
        return lower.contains("detected_virus.info")
            || lower.contains("detection")
            || (lower.contains("virus") && lower.hasSuffix(".tsv"))
    }

    let assemblyURL = files.first { url in
        url.lastPathComponent.lowercased().contains("assembly_summary")
    }

    let taxProfileURL = files.first { url in
        url.lastPathComponent.lowercased().contains("tax_profile")
    }

    let coverageURL = files.first { url in
        let lower = url.lastPathComponent.lowercased()
        return lower.contains("coverage_windows") || lower.contains("coverage")
    }

    return EsVirituDetectedFiles(
        detectionURL: detectionURL,
        assemblyURL: assemblyURL,
        taxProfileURL: taxProfileURL,
        coverageURL: coverageURL
    )
}

private func resolveEsVirituSampleName(preferredName: String?, inputURL: URL, detectionURL: URL?) -> String {
    if let preferredName, !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return preferredName
    }

    if let detectionURL {
        let filename = detectionURL.lastPathComponent
        if let range = filename.range(of: ".detected_virus.info", options: [.caseInsensitive]) {
            let prefix = String(filename[..<range.lowerBound])
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    return inputURL.deletingPathExtension().lastPathComponent
}

private func countDataRows(in fileURL: URL) -> Int {
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
    let lines = text.split(separator: "\n")
    return max(0, lines.count - 1)
}

private func normalizeSampleName(explicitName: String?, fallback: String) -> String {
    let trimmed = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
        return trimmed
    }
    let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    return fallbackTrimmed.isEmpty ? "naomgs-sample" : fallbackTrimmed
}

private func writeNaoMgsManifest(
    _ manifest: NaoMgsManifest,
    to resultDirectory: URL,
    encoder: JSONEncoder
) throws {
    do {
        let data = try encoder.encode(manifest)
        try data.write(
            to: resultDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    } catch {
        throw MetagenomicsImportError.copyFailed(
            source: resultDirectory,
            destination: resultDirectory.appendingPathComponent("manifest.json"),
            reason: error.localizedDescription
        )
    }
}

private func fetchNaoMgsReferences(
    accessions: [String],
    into referencesDirectory: URL,
    progress: (@Sendable (Double, String) -> Void)?
) async -> [String] {
    guard !accessions.isEmpty else { return [] }

    let chunkSize = 200
    let chunks = stride(from: 0, to: accessions.count, by: chunkSize).map {
        Array(accessions[$0..<min($0 + chunkSize, accessions.count)])
    }

    let ncbi = NCBIService()
    var fetched: [String] = []

    for (chunkIndex, chunk) in chunks.enumerated() {
        let chunkLabel = "Fetching references batch \(chunkIndex + 1)/\(chunks.count) (\(chunk.count) accessions)"
        let baseFraction = Double(chunkIndex) / Double(chunks.count)
        progress?(0.70 + (0.28 * baseFraction), chunkLabel)

        do {
            let data = try await ncbi.efetch(
                database: .nucleotide,
                ids: chunk,
                format: .fasta
            )
            guard let fastaText = String(data: data, encoding: .utf8) else { continue }

            let records = MetagenomicsImportService.splitMultiRecordFASTA(fastaText)
            for (accession, recordText) in records {
                let fastaURL = referencesDirectory.appendingPathComponent("\(accession).fasta")
                try? recordText.data(using: .utf8)?.write(to: fastaURL, options: .atomic)
                fetched.append(accession)
            }
        } catch {
            // Fallback: try individual accessions in this chunk (best-effort)
            for (i, accession) in chunk.enumerated() {
                let individualFraction = baseFraction + (Double(i) / Double(accessions.count)) * (1.0 / Double(chunks.count))
                progress?(0.70 + (0.28 * individualFraction), "Fetching \(accession) (fallback)")
                do {
                    let data = try await ncbi.efetch(
                        database: .nucleotide,
                        ids: [accession],
                        format: .fasta
                    )
                    let fastaURL = referencesDirectory.appendingPathComponent("\(accession).fasta")
                    try data.write(to: fastaURL, options: .atomic)
                    fetched.append(accession)
                } catch {
                    // Best effort: skip failed accessions
                }
            }
        }
    }

    let fraction = 1.0
    progress?(0.70 + (0.28 * fraction), "Fetched \(fetched.count)/\(accessions.count) references")
    return fetched
}

