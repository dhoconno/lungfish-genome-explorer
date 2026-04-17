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
    case nvd

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
        case .nvd:
            return "nvd-"
        }
    }

    /// The canonical tool identifier used in `AnalysesFolder.knownTools`.
    public var toolIdentifier: String {
        rawValue
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

/// Intermediate result from importing a single pre-partitioned sample into staging.
private struct NaoMgsSingleSampleStageResult {
    let sampleName: String
    let hitCount: Int
    let taxonCount: Int
    let createdBAM: Bool
    let stageInput: NaoMgsStageDatabaseInput
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
        writeAnalysisMetadataIfNeeded(tool: MetagenomicsImportKind.kraken2.toolIdentifier, to: resultDirectory)
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
        writeAnalysisMetadataIfNeeded(tool: MetagenomicsImportKind.esviritu.toolIdentifier, to: resultDirectory)
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
        writeAnalysisMetadataIfNeeded(tool: MetagenomicsImportKind.taxtriage.toolIdentifier, to: resultDirectory)
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
        let logFile = allOutputFiles.first {
            $0.lastPathComponent.caseInsensitiveCompare("nextflow.log") == .orderedSame
        }
        let traceFile = allOutputFiles.first {
            $0.lastPathComponent.caseInsensitiveCompare("trace.txt") == .orderedSame
        }
        let ignoredFailures: [TaxTriageIgnoredFailure]
        if let logFile,
           let logText = try? String(contentsOf: logFile, encoding: .utf8) {
            ignoredFailures = TaxTriageResult.parseIgnoredFailures(fromNextflowLogText: logText)
        } else {
            ignoredFailures = []
        }

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
            logFile: logFile,
            traceFile: traceFile,
            allOutputFiles: allOutputFiles,
            ignoredFailures: ignoredFailures
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

        // Resolve TSV file(s) — supports single monolithic file or folder of per-lane TSVs
        let virusHitsFiles = try resolveVirusHitsTSVs(inputURL: inputURL)

        // Use a temporary sample name for directory creation; will be updated after streaming.
        let preliminarySampleName = normalizeSampleName(
            explicitName: sampleName ?? preferredName,
            fallback: inputURL.deletingPathExtension().deletingPathExtension().lastPathComponent
        )
        let baseName = normalizedBaseName(
            preferredName: preferredName ?? preliminarySampleName,
            fallback: preliminarySampleName
        )
        let resultDirectory = makeUniqueResultDirectory(
            prefix: MetagenomicsImportKind.naomgs.directoryPrefix,
            baseName: baseName,
            in: outputDirectory
        )
        try ensureDirectoryExists(resultDirectory)
        writeAnalysisMetadataIfNeeded(tool: MetagenomicsImportKind.naomgs.toolIdentifier, to: resultDirectory)
        OperationMarker.markInProgress(resultDirectory, detail: "Importing NAO-MGS results\u{2026}")
        defer { OperationMarker.clearInProgress(resultDirectory) }

        do {

        // ── Phase 1: Partition input TSVs by normalized sample ──────────
        progress?(0.02, "Partitioning input by sample\u{2026}")
        let stagingRoot = resultDirectory.appendingPathComponent(".naomgs-import-staging", isDirectory: true)
        let partitionDir = stagingRoot.appendingPathComponent("partitioned", isDirectory: true)
        let stageImportsDir = stagingRoot.appendingPathComponent("imports", isDirectory: true)

        let partition = try NaoMgsSamplePartitioner.partition(
            inputURLs: virusHitsFiles,
            outputDirectory: partitionDir
        )

        // ── Phase 2: Per-sample stage import (streaming DB + BAMs) ──────
        var stageInputs: [NaoMgsStageDatabaseInput] = []
        var totalHitCount = 0
        var totalTaxonCount = 0
        var firstSampleName: String?
        let sortedSamples = partition.sampleFiles.keys.sorted()
        let sampleCount = sortedSamples.count

        for (index, sample) in sortedSamples.enumerated() {
            try Task.checkCancellation()
            let sampleFraction = Double(index) / Double(max(1, sampleCount))
            progress?(0.05 + sampleFraction * 0.55, "Importing sample \(index + 1)/\(sampleCount): \(sample)\u{2026}")

            let sampleTSV = partition.sampleFiles[sample]!
            let stageResult = try await importNaoMgsSingleSampleStage(
                inputURL: sampleTSV,
                stagingDirectory: stageImportsDir,
                sampleName: sample,
                minIdentity: minIdentity
            )
            totalHitCount += stageResult.hitCount
            totalTaxonCount += stageResult.taxonCount
            // Skip samples where all rows were filtered out (e.g. by minIdentity).
            if stageResult.hitCount > 0 {
                stageInputs.append(stageResult.stageInput)
            }
            if firstSampleName == nil { firstSampleName = stageResult.sampleName }
        }

        let normalizedSampleName = normalizeSampleName(
            explicitName: sampleName,
            fallback: firstSampleName ?? preliminarySampleName
        )

        // ── Phase 3: Merge staged databases into final hits.sqlite ──────
        progress?(0.62, "Merging sample databases\u{2026}")
        let hitsDBURL = resultDirectory.appendingPathComponent("hits.sqlite")
        try NaoMgsDatabase.createMergedSummaryDatabase(at: hitsDBURL, from: stageInputs)

        // Copy per-sample BAMs into the final bundle's bams/ directory.
        let finalBamsDir = resultDirectory.appendingPathComponent("bams", isDirectory: true)
        try ensureDirectoryExists(finalBamsDir)
        for stageInput in stageInputs {
            let stageBamsDir = stageInput.databaseURL.deletingLastPathComponent()
                .appendingPathComponent("bams", isDirectory: true)
            if fm.fileExists(atPath: stageBamsDir.path),
               let bamFiles = try? fm.contentsOfDirectory(at: stageBamsDir, includingPropertiesForKeys: nil) {
                for src in bamFiles {
                    let dst = finalBamsDir.appendingPathComponent(src.lastPathComponent)
                    try? fm.removeItem(at: dst)
                    try fm.copyItem(at: src, to: dst)
                }
            }
        }

        let rwDB = try NaoMgsDatabase.openReadWrite(at: hitsDBURL)

        // Compute global distinct taxon count from the merged database.
        let mergedTaxonCount = (try? rwDB.fetchTaxonSummaryRows(samples: nil))
            .map { rows in Set(rows.map(\.taxId)).count } ?? totalTaxonCount

        // ── Phase 4: Resolve taxon names from local NCBI Taxonomy ───────
        progress?(0.70, "Resolving taxon names\u{2026}")
        do {
            let unresolvedIds = try rwDB.taxonIdsNeedingNames()
            if !unresolvedIds.isEmpty {
                let registry = MetagenomicsDatabaseRegistry.shared
                var taxonomyPath: URL?

                if let installed = try await registry.installedDatabase(tool: .ncbiTaxonomy),
                   let path = installed.path {
                    taxonomyPath = path
                } else {
                    logger.info("NCBI Taxonomy database not installed \u{2014} downloading automatically")
                    progress?(0.70, "Downloading NCBI Taxonomy database\u{2026}")
                    do {
                        let installedURL = try await registry.downloadDatabase(
                            name: "NCBI Taxonomy"
                        ) { dlProgress, dlMessage in
                            progress?(0.70 + dlProgress * 0.05, dlMessage)
                        }
                        taxonomyPath = installedURL
                    } catch {
                        logger.warning("Failed to download NCBI Taxonomy database: \(error.localizedDescription, privacy: .public)")
                    }
                }

                if let taxonomyPath {
                    let resolvedNames = try TaxonomyNameResolver.resolveFromFile(
                        taxonomyPath, taxIds: unresolvedIds
                    )
                    if !resolvedNames.isEmpty {
                        try rwDB.updateTaxonNames(resolvedNames)
                    }
                    logger.info("Resolved \(resolvedNames.count)/\(unresolvedIds.count) taxon names from local taxonomy DB")
                }
            }
        } catch {
            logger.warning("Taxon name resolution failed: \(error.localizedDescription, privacy: .public)")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let topTaxonInfo = try? rwDB.topTaxon()

        var manifest = NaoMgsManifest(
            sampleName: normalizedSampleName,
            sourceFilePath: virusHitsFiles[0].path,
            hitCount: totalHitCount,
            taxonCount: mergedTaxonCount,
            topTaxon: topTaxonInfo?.name,
            topTaxonId: topTaxonInfo?.taxId
        )
        try writeNaoMgsManifest(manifest, to: resultDirectory, encoder: encoder)

        try Task.checkCancellation()

        // ── Phase 5: Fetch references once from merged data ─────────────
        var fetchedAccessions: [String] = []
        if fetchReferences {
            let referencesDirectory = resultDirectory.appendingPathComponent("references", isDirectory: true)
            try ensureDirectoryExists(referencesDirectory)
            progress?(0.76, "Fetching reference FASTA files...")
            let accessions = (try? rwDB.allMiniBAMAccessions()) ?? []
            fetchedAccessions = await fetchNaoMgsReferences(
                accessions: accessions,
                into: referencesDirectory,
                progress: progress
            )
            manifest.fetchedAccessions = fetchedAccessions
            try writeNaoMgsManifest(manifest, to: resultDirectory, encoder: encoder)

            try Task.checkCancellation()

            var refLengths: [String: Int] = [:]
            let runner = NativeToolRunner.shared
            if let files = try? FileManager.default.contentsOfDirectory(
                at: referencesDirectory,
                includingPropertiesForKeys: nil
            ) {
                for file in files where file.pathExtension == "fasta" {
                    let accession = file.deletingPathExtension().lastPathComponent
                    let faiURL = URL(fileURLWithPath: file.path + ".fai")
                    do {
                        let result = try await runner.run(
                            .samtools,
                            arguments: ["faidx", file.path],
                            workingDirectory: referencesDirectory,
                            timeout: 30
                        )
                        if result.isSuccess, FileManager.default.fileExists(atPath: faiURL.path) {
                            let index = try FASTAIndex(url: faiURL)
                            if let entry = index.sequenceNames.first.flatMap({ index.entry(for: $0) }) {
                                refLengths[accession] = entry.length
                            }
                        }
                    } catch {
                        logger.warning("Failed to index \(accession).fasta: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            if !refLengths.isEmpty {
                try rwDB.updateReferenceLengths(refLengths)
                try rwDB.refreshAccessionSummaryReferenceLengths()
                logger.info("Stored \(refLengths.count) reference lengths from downloaded FASTAs")
            }
        }

        // Cache taxon summary rows in the manifest for instant display.
        do {
            let cachedRows = try rwDB.fetchTaxonSummaryRows(samples: nil)
            manifest.cachedTaxonRows = cachedRows
            try writeNaoMgsManifest(manifest, to: resultDirectory, encoder: encoder)
            logger.info("Cached \(cachedRows.count) taxon summary rows in manifest")
        } catch {
            logger.warning("Failed to cache taxon rows in manifest: \(error.localizedDescription, privacy: .public)")
        }

        // ── Phase 6: Clean up staging artifacts ─────────────────────────
        try? fm.removeItem(at: stagingRoot)

        progress?(1.0, "NAO-MGS import complete")
        return NaoMgsImportResult(
            resultDirectory: resultDirectory,
            sampleName: normalizedSampleName,
            totalHitReads: totalHitCount,
            taxonCount: mergedTaxonCount,
            fetchedReferenceCount: fetchedAccessions.count,
            createdBAM: !stageInputs.isEmpty
        )
        } catch {
            // Clean up staging on failure too.
            let stagingRoot = resultDirectory.appendingPathComponent(".naomgs-import-staging")
            try? fm.removeItem(at: stagingRoot)
            throw MetagenomicsImportError.importAborted(
                resultDirectory: resultDirectory,
                underlying: error
            )
        }
    }

    /// Imports a single pre-partitioned sample TSV into a staging directory.
    /// Produces a per-sample SQLite database and BAM files without fetching references.
    private static func importNaoMgsSingleSampleStage(
        inputURL: URL,
        stagingDirectory: URL,
        sampleName: String,
        minIdentity: Double = 0
    ) async throws -> NaoMgsSingleSampleStageResult {
        let fm = FileManager.default
        let stageDir = stagingDirectory.appendingPathComponent(sampleName, isDirectory: true)
        try ensureDirectoryExists(stageDir)

        let hitsDBURL = stageDir.appendingPathComponent("hits.sqlite")
        let streamResult = try await NaoMgsDatabase.createStreaming(
            at: hitsDBURL,
            from: [inputURL],
            sampleNameOverride: sampleName,
            minIdentity: minIdentity
        )

        // Materialize BAMs for this sample.
        var createdBAM = false
        if let samtoolsPath = managedSamtoolsExecutableURL()?.path {
            let generated = try NaoMgsBamMaterializer.materializeAll(
                dbPath: hitsDBURL.path,
                resultURL: stageDir,
                samtoolsPath: samtoolsPath
            )
            createdBAM = !generated.isEmpty

            if !generated.isEmpty {
                // Record BAM paths in the stage database so the merge can read them.
                let rwDB = try NaoMgsDatabase.openReadWrite(at: hitsDBURL)
                var bamPathsBySample: [String: (bamPath: String, bamIndexPath: String?)] = [:]
                for bamURL in generated {
                    let sample = bamURL.deletingPathExtension().lastPathComponent
                    let bamRelative = "bams/\(bamURL.lastPathComponent)"
                    let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
                    let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
                    let indexRelative: String?
                    if fm.fileExists(atPath: baiURL.path) {
                        indexRelative = bamRelative + ".bai"
                    } else if fm.fileExists(atPath: csiURL.path) {
                        indexRelative = bamRelative + ".csi"
                    } else {
                        indexRelative = nil
                    }
                    bamPathsBySample[sample] = (bamPath: bamRelative, bamIndexPath: indexRelative)
                }
                try rwDB.updateBamPaths(bamPathsBySample)

                // Purge virus_hits now that BAMs are materialized.
                try? rwDB.deleteVirusHitsAndVacuum()
            }
        }

        // Build the stage input descriptor for the merge phase.
        let bamRelative = "bams/\(sampleName).bam"
        let bamFullPath = stageDir.appendingPathComponent(bamRelative)
        let baiFullPath = URL(fileURLWithPath: bamFullPath.path + ".bai")
        let csiFullPath = URL(fileURLWithPath: bamFullPath.path + ".csi")
        let indexRelative: String?
        if fm.fileExists(atPath: baiFullPath.path) {
            indexRelative = "bams/\(sampleName).bam.bai"
        } else if fm.fileExists(atPath: csiFullPath.path) {
            indexRelative = "bams/\(sampleName).bam.csi"
        } else {
            indexRelative = nil
        }

        return NaoMgsSingleSampleStageResult(
            sampleName: streamResult.sampleName,
            hitCount: streamResult.hitCount,
            taxonCount: streamResult.taxonCount,
            createdBAM: createdBAM,
            stageInput: NaoMgsStageDatabaseInput(
                sample: sampleName,
                databaseURL: hitsDBURL,
                bamRelativePath: bamRelative,
                bamIndexRelativePath: indexRelative
            )
        )
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

    /// Selects the exact accessions needed for miniBAM display: top `maxPerRow`
    /// accessions by unique read count per (sample, taxId) pair.
    ///
    /// This mirrors the database's `top_accessions_json` logic but works from
    /// in-memory hits, avoiding an extra database open that could cause SQLite
    /// locking issues.
    public static func selectMiniBAMAccessions(
        hits: [NaoMgsVirusHit],
        maxPerRow: Int = 5
    ) -> [String] {
        // Group hits by (sample, taxId) — each pair is one taxon row in the UI.
        struct RowKey: Hashable {
            let sample: String
            let taxId: Int
        }
        var rowHits: [RowKey: [NaoMgsVirusHit]] = [:]
        for hit in hits where !hit.subjectSeqId.isEmpty {
            rowHits[RowKey(sample: hit.sample, taxId: hit.taxId), default: []].append(hit)
        }

        var allAccessions = Set<String>()

        for (_, hitsForRow) in rowHits {
            // Count unique reads per accession (same dedup key as the database).
            var accessionUniqueCounts: [String: Set<String>] = [:]
            for hit in hitsForRow {
                let dedup = "\(hit.refStart)|\(hit.isReverseComplement)|\(hit.queryLength)"
                accessionUniqueCounts[hit.subjectSeqId, default: []].insert(dedup)
            }

            // Sort by unique count descending, then alphabetically.
            let sorted = accessionUniqueCounts.sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count {
                    return lhs.value.count > rhs.value.count
                }
                return lhs.key < rhs.key
            }

            for entry in sorted.prefix(maxPerRow) {
                allAccessions.insert(entry.key)
            }
        }

        return allAccessions.sorted()
    }

    /// Splits a concatenated multi-record FASTA string into individual records.
    ///
    /// - Parameter fasta: Concatenated FASTA text (multiple `>` headers).
    /// - Returns: Dictionary mapping accession (first token after `>`) to full FASTA record text.
    public static func splitMultiRecordFASTA(_ fasta: String) -> [String: String] {
        guard !fasta.isEmpty else { return [:] }

        // Normalize line endings — NCBI efetch may return \r\n
        let normalized = fasta.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var records: [String: String] = [:]
        var currentAccession: String?
        var currentLines: [String] = []

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Skip blank lines — NCBI efetch may insert them between records,
                // and samtools faidx produces incorrect lengths when blank lines
                // appear within a FASTA sequence.
                currentLines.append(line)
            }
        }

        if let acc = currentAccession, !currentLines.isEmpty {
            records[acc] = currentLines.joined(separator: "\n")
        }

        return records
    }

    /// Normalizes a single FASTA record: strips `\r`, removes blank lines,
    /// and ensures the record ends with a newline.
    ///
    /// Use this when writing a single FASTA record to disk (e.g. fallback
    /// individual-accession fetch) to prevent `samtools faidx` from
    /// misinterpreting blank lines as record boundaries.
    public static func normalizeFASTARecord(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    /// Resolves the managed samtools binary for NAO-MGS BAM materialization.
    internal static func managedSamtoolsExecutableURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let samtoolsURL = CoreToolLocator.managedExecutableURL(
            environment: "samtools",
            executableName: "samtools",
            homeDirectory: homeDirectory
        )

        return FileManager.default.isExecutableFile(atPath: samtoolsURL.path) ? samtoolsURL : nil
    }

    /// Resolves one or more virus_hits TSV files from a user-provided input URL.
    ///
    /// Supports:
    /// - Single file (e.g. `virus_hits_final.tsv.gz`)
    /// - Directory with monolithic `virus_hits_final.tsv(.gz)` (NAO-MGS ≤3.1)
    /// - Directory with per-lane `*_virus_hits.tsv.gz` files (NAO-MGS 3.2+)
    ///
    /// - Returns: Non-empty array of TSV file URLs, sorted by name.
    private static func resolveVirusHitsTSVs(inputURL: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            throw MetagenomicsImportError.inputNotFound(inputURL)
        }

        // Single file — use directly
        if !isDir.boolValue {
            return [inputURL]
        }

        // Directory: try monolithic file first (v3.0/3.1 convention)
        let monolithicCandidates = [
            inputURL.appendingPathComponent("virus_hits_final.tsv.gz"),
            inputURL.appendingPathComponent("virus_hits_final.tsv"),
        ]
        if let found = monolithicCandidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            return [found]
        }

        // Directory: scan for per-lane TSVs (v3.2 convention)
        if let contents = try? fm.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil) {
            let tsvFiles = contents.filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.contains("virus_hits")
                    && (name.hasSuffix(".tsv") || name.hasSuffix(".tsv.gz"))
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            if !tsvFiles.isEmpty {
                return tsvFiles
            }
        }

        throw MetagenomicsImportError.inputNotFound(inputURL)
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

/// Writes `analysis-metadata.json` into a result directory so that it remains
/// identifiable by ``AnalysesFolder`` even after the user renames it.
private func writeAnalysisMetadataIfNeeded(tool: String, to directory: URL) {
    let metadata = AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: false)
    try? AnalysesFolder.writeAnalysisMetadata(metadata, to: directory)
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
    logger.info("Fetching \(accessions.count) reference FASTA files in batches of \(chunkSize)")
    var fetched: [String] = []

    for (chunkIndex, chunk) in chunks.enumerated() {
        // Check for cancellation before each batch
        if Task.isCancelled {
            logger.info("Reference fetch cancelled after \(fetched.count)/\(accessions.count) accessions")
            return fetched
        }

        let chunkLabel = "Fetching references batch \(chunkIndex + 1)/\(chunks.count) (\(chunk.count) accessions)"
        let baseFraction = Double(chunkIndex) / Double(chunks.count)
        progress?(0.70 + (0.28 * baseFraction), chunkLabel)
        logger.info("\(chunkLabel, privacy: .public)")

        do {
            let data = try await ncbi.efetch(
                database: .nucleotide,
                ids: chunk,
                format: .fasta
            )
            guard let fastaText = String(data: data, encoding: .utf8) else {
                logger.warning("Batch \(chunkIndex + 1): efetch returned non-UTF8 data, skipping")
                continue
            }

            let records = MetagenomicsImportService.splitMultiRecordFASTA(fastaText)
            logger.info("Batch \(chunkIndex + 1): received \(records.count)/\(chunk.count) records")
            for (accession, recordText) in records {
                let fastaURL = referencesDirectory.appendingPathComponent("\(accession).fasta")
                // Ensure record ends with newline for valid FASTA (required by samtools faidx)
                let normalizedRecord = recordText.hasSuffix("\n") ? recordText : recordText + "\n"
                try? normalizedRecord.data(using: .utf8)?.write(to: fastaURL, options: .atomic)
                fetched.append(accession)
            }
        } catch {
            logger.warning("Batch \(chunkIndex + 1) failed: \(error.localizedDescription, privacy: .public) — falling back to individual downloads")
            // Fallback: try individual accessions in this chunk (best-effort)
            for (i, accession) in chunk.enumerated() {
                // Check for cancellation before each individual download
                if Task.isCancelled {
                    logger.info("Reference fetch cancelled during fallback after \(fetched.count)/\(accessions.count) accessions")
                    return fetched
                }

                let individualFraction = baseFraction + (Double(i) / Double(accessions.count)) * (1.0 / Double(chunks.count))
                progress?(0.70 + (0.28 * individualFraction), "Fetching \(accession) (fallback)")
                do {
                    let data = try await ncbi.efetch(
                        database: .nucleotide,
                        ids: [accession],
                        format: .fasta
                    )
                    guard let fastaText = String(data: data, encoding: .utf8) else { continue }
                    let fastaURL = referencesDirectory.appendingPathComponent("\(accession).fasta")
                    // Normalize: strip \r, blank lines — matches batch path behavior.
                    // Raw NCBI FASTA with blank lines causes samtools faidx to report
                    // incorrect reference lengths.
                    let normalized = MetagenomicsImportService.normalizeFASTARecord(fastaText)
                    try normalized.data(using: .utf8)?.write(to: fastaURL, options: .atomic)
                    fetched.append(accession)
                    logger.debug("Fallback: fetched \(accession, privacy: .public)")
                } catch {
                    logger.warning("Fallback: failed to fetch \(accession, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    logger.info("Reference fetch complete: \(fetched.count)/\(accessions.count) accessions downloaded")

    let fraction = 1.0
    progress?(0.70 + (0.28 * fraction), "Fetched \(fetched.count)/\(accessions.count) references")
    return fetched
}
