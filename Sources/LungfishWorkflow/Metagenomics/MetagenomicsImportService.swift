// MetagenomicsImportService.swift - Shared import routines for metagenomics result folders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
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

    /// Token used by the `lungfish-cli import <token>` command family.
    public var importCommandToken: String {
        switch self {
        case .naomgs:
            return "nao-mgs"
        default:
            return rawValue
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

/// Result metadata for an imported NVD result directory.
public struct NvdImportResult: Sendable {
    public let resultDirectory: URL
    public let sampleCount: Int
    public let hitCount: Int
    public let contigCount: Int
    public let copiedBAMCount: Int
    public let copiedBAMIndexCount: Int
    public let copiedFASTACount: Int
    public let markdupBAMCount: Int
    public let uniqueReadRowsUpdated: Int

    public init(
        resultDirectory: URL,
        sampleCount: Int,
        hitCount: Int,
        contigCount: Int,
        copiedBAMCount: Int,
        copiedBAMIndexCount: Int,
        copiedFASTACount: Int,
        markdupBAMCount: Int,
        uniqueReadRowsUpdated: Int
    ) {
        self.resultDirectory = resultDirectory
        self.sampleCount = sampleCount
        self.hitCount = hitCount
        self.contigCount = contigCount
        self.copiedBAMCount = copiedBAMCount
        self.copiedBAMIndexCount = copiedBAMIndexCount
        self.copiedFASTACount = copiedFASTACount
        self.markdupBAMCount = markdupBAMCount
        self.uniqueReadRowsUpdated = uniqueReadRowsUpdated
    }
}

/// Intermediate result from importing a single pre-partitioned sample into staging.
private struct NaoMgsSingleSampleStageResult {
    let sampleName: String
    let hitCount: Int
    let taxonCount: Int
    let createdBAM: Bool
    let stageInput: NaoMgsStageDatabaseInput
    let materializationSteps: [NaoMgsBamMaterializationStep]
}

/// Errors thrown while importing classifier outputs.
public enum MetagenomicsImportError: Error, LocalizedError, Sendable {
    case inputNotFound(URL)
    case outputDirectoryCreationFailed(URL, String)
    case copyFailed(source: URL, destination: URL, reason: String)
    case parseFailed(URL, String)
    case toolUnavailable(String)
    case outputAlreadyExists(URL)
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
        case .outputAlreadyExists(let url):
            return "Output already exists: \(url.path)"
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
    /// - `classification.kraken.gz` and `classification.kraken.gz.idx.sqlite`
    ///   when a per-read output file is supplied
    /// - `classification.kraken` (empty placeholder when no output file is supplied)
    /// - `classification-result.json`
    public static func importKraken2(
        kreportURL: URL,
        outputDirectory: URL,
        outputFileURL: URL? = nil,
        preferredName: String? = nil,
        provenanceCommand: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> Kraken2ImportResult {
        let startedAt = Date()
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
        var importCompleted = false
        defer { finalizeImportDirectory(resultDirectory, completed: importCompleted) }

        let canonicalReportURL = resultDirectory.appendingPathComponent("classification.kreport")
        progress?(0.25, "Copying report...")
        try copyFile(kreportURL, to: canonicalReportURL)

        let canonicalOutputURL = resultDirectory.appendingPathComponent("classification.kraken")
        let retainedOutputURL: URL
        progress?(0.45, "Copying read classifications...")
        if let outputFileURL {
            try copyFile(outputFileURL, to: canonicalOutputURL)
            retainedOutputURL = compactKrakenOutput(canonicalOutputURL)
        } else {
            if !fm.createFile(atPath: canonicalOutputURL.path, contents: nil) {
                throw MetagenomicsImportError.copyFailed(
                    source: kreportURL,
                    destination: canonicalOutputURL,
                    reason: "Could not create placeholder output file"
                )
            }
            retainedOutputURL = canonicalOutputURL
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
            outputURL: retainedOutputURL,
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
        do {
            try writeMetagenomicsImportProvenance(
                kind: .kraken2,
                sourceURLs: [kreportURL] + (outputFileURL.map { [$0] } ?? []),
                resultDirectory: resultDirectory,
                command: provenanceCommand,
                explicitOptions: [
                    "kreport": .file(kreportURL),
                    "outputFile": outputFileURL.map(ParameterValue.file) ?? .null,
                    "preferredName": preferredName.map(ParameterValue.string) ?? .null,
                    "outputRoot": .file(outputDirectory),
                ],
                resolvedDefaults: [
                    "classificationReport": .file(canonicalReportURL),
                    "classificationOutput": .file(retainedOutputURL),
                    "outputDirectory": .file(resultDirectory),
                    "totalReads": .integer(tree.totalReads),
                    "speciesCount": .integer(tree.speciesCount),
                ],
                startedAt: startedAt
            )
        } catch {
            try? fm.removeItem(at: resultDirectory)
            throw error
        }

        progress?(1.0, "Kraken2 import complete")
        importCompleted = true
        return Kraken2ImportResult(
            resultDirectory: resultDirectory,
            totalReads: tree.totalReads,
            speciesCount: tree.speciesCount
        )
    }

    private static func compactKrakenOutput(_ rawURL: URL) -> URL {
        do {
            return try KrakenOutputCompactor.compact(
                rawURL: rawURL,
                includeUnclassifiedInIndex: false,
                removeRawOnSuccess: true
            )
        } catch {
            logger.warning("Failed to compact imported Kraken2 output; retaining raw output: \(error.localizedDescription, privacy: .public)")
            return rawURL
        }
    }

    /// Imports EsViritu files into a canonical result directory and writes `esviritu-result.json`.
    public static func importEsViritu(
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String? = nil,
        provenanceCommand: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> EsVirituImportResult {
        let startedAt = Date()
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
        var importCompleted = false
        defer { finalizeImportDirectory(resultDirectory, completed: importCompleted) }
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
        do {
            try writeMetagenomicsImportProvenance(
                kind: .esviritu,
                sourceURLs: sourcePayloadURLs(
                    inputURL: inputURL,
                    copiedRegularFiles: copiedRegularFiles,
                    resultDirectory: resultDirectory
                ),
                resultDirectory: resultDirectory,
                command: provenanceCommand,
                explicitOptions: [
                    "input": .file(inputURL),
                    "preferredName": preferredName.map(ParameterValue.string) ?? .null,
                    "outputRoot": .file(outputDirectory),
                ],
                resolvedDefaults: [
                    "detectionFile": .file(detectionURL),
                    "outputDirectory": .file(resultDirectory),
                    "importedFileCount": .integer(copiedRegularFiles.count),
                    "virusCount": .integer(virusCount),
                    "sampleName": .string(sampleName),
                ],
                startedAt: startedAt
            )
        } catch {
            try? fm.removeItem(at: resultDirectory)
            throw error
        }

        progress?(1.0, "EsViritu import complete")
        importCompleted = true
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
        provenanceCommand: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> TaxTriageImportResult {
        let startedAt = Date()
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
        var importCompleted = false
        defer { finalizeImportDirectory(resultDirectory, completed: importCompleted) }
        progress?(0.05, "Copying TaxTriage files...")

        let copiedFiles = try copyInputPayload(from: inputURL, into: resultDirectory)
        let copiedRegularFiles = copiedFiles.filter { isRegularFile($0) }
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
            ignoredFailures = TaxTriageResult.sanitizeIgnoredFailures(
                TaxTriageResult.parseIgnoredFailures(fromNextflowLogText: logText),
                outputDirectory: resultDirectory
            )
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
        do {
            try writeMetagenomicsImportProvenance(
                kind: .taxtriage,
                sourceURLs: sourcePayloadURLs(
                    inputURL: inputURL,
                    copiedRegularFiles: copiedRegularFiles,
                    resultDirectory: resultDirectory
                ),
                resultDirectory: resultDirectory,
                command: provenanceCommand,
                explicitOptions: [
                    "input": .file(inputURL),
                    "preferredName": preferredName.map(ParameterValue.string) ?? .null,
                    "outputRoot": .file(outputDirectory),
                ],
                resolvedDefaults: [
                    "outputDirectory": .file(resultDirectory),
                    "importedFileCount": .integer(allOutputFiles.count),
                    "reportEntryCount": .integer(reportEntries),
                    "ignoredFailureCount": .integer(ignoredFailures.count),
                ],
                startedAt: startedAt
            )
        } catch {
            try? fm.removeItem(at: resultDirectory)
            throw error
        }

        progress?(1.0, "TaxTriage import complete")
        importCompleted = true
        return TaxTriageImportResult(
            resultDirectory: resultDirectory,
            importedFileCount: allOutputFiles.count,
            reportEntryCount: reportEntries
        )
    }

    /// Imports an NVD run directory into a canonical app-viewable result bundle.
    ///
    /// The imported folder contains `manifest.json`, `hits.sqlite`, and any
    /// discoverable per-sample BAM/BAI/FASTA assets. The bundle is assembled in a
    /// hidden staging directory, provenance is written with final output paths,
    /// and only then is the directory promoted into place.
    public static func importNvd(
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String? = nil,
        allowUniqueSuffix: Bool = true,
        samtoolsPath: String? = nil,
        provenanceCommand: [String]? = nil,
        provenanceWorkflowName: String = "lungfish import nvd",
        provenanceToolName: String = "lungfish import",
        provenanceCollisionTestHook: Bool = false,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> NvdImportResult {
        let startedAt = Date()
        let fm = FileManager.default
        guard fm.fileExists(atPath: inputURL.path) else {
            throw MetagenomicsImportError.inputNotFound(inputURL)
        }

        let labkeyDir = inputURL.appendingPathComponent("05_labkey_bundling", isDirectory: true)
        guard fm.fileExists(atPath: labkeyDir.path) else {
            throw MetagenomicsImportError.inputNotFound(labkeyDir)
        }

        let labkeyContents = try fm.contentsOfDirectory(at: labkeyDir, includingPropertiesForKeys: nil)
        guard let csvURL = labkeyContents.first(where: NvdResultParser.isBlastConcatenatedCSV) else {
            throw MetagenomicsImportError.parseFailed(
                labkeyDir,
                "No *_blast_concatenated.csv or *.csv.gz found in 05_labkey_bundling/"
            )
        }

        progress?(0.05, "Parsing NVD CSV...")
        let parser = NvdResultParser()
        let parseResult: NvdParseResult
        do {
            parseResult = try await parser.parse(at: csvURL) { lineCount in
                if lineCount % 5000 == 0 {
                    progress?(0.05 + min(0.25, Double(lineCount) / 100_000.0 * 0.25), "Parsing CSV... \(lineCount) rows")
                }
            }
        } catch {
            throw MetagenomicsImportError.parseFailed(csvURL, error.localizedDescription)
        }

        let defaultBundleName = "nvd-\(parseResult.experiment.isEmpty ? inputURL.lastPathComponent : parseResult.experiment)"
        let bundleName = normalizedBaseName(preferredName: preferredName, fallback: defaultBundleName)
        try ensureDirectoryExists(outputDirectory)
        let finalDirectory = try nvdResultDirectory(
            named: bundleName,
            in: outputDirectory,
            allowUniqueSuffix: allowUniqueSuffix
        )
        let stagingDirectory = outputDirectory.appendingPathComponent(
            ".lungfish-nvd-import-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            progress?(0.35, "Preparing NVD bundle...")
            try ensureDirectoryExists(stagingDirectory)
            writeAnalysisMetadataIfNeeded(tool: MetagenomicsImportKind.nvd.toolIdentifier, to: stagingDirectory)
            OperationMarker.markInProgress(stagingDirectory, detail: "Importing NVD results...")
            defer { OperationMarker.clearInProgress(stagingDirectory) }

            let bamDirectory = stagingDirectory.appendingPathComponent("bam", isDirectory: true)
            let fastaDirectory = stagingDirectory.appendingPathComponent("fasta", isDirectory: true)
            try ensureDirectoryExists(bamDirectory)
            try ensureDirectoryExists(fastaDirectory)

            let sampleBuild = try nvdBuildSampleMetadata(inputURL: inputURL, result: parseResult)

            progress?(0.45, "Creating NVD database...")
            let databaseURL = stagingDirectory.appendingPathComponent("hits.sqlite")
            try NvdDatabase.create(
                at: databaseURL,
                hits: parseResult.hits,
                samples: sampleBuild.samples
            ) { fraction, message in
                progress?(0.45 + fraction * 0.15, message)
            }

            progress?(0.62, "Copying NVD BAM files...")
            let copiedBAMs = try nvdCopyBAMAssets(
                sampleMetadata: sampleBuild.samples,
                assetSources: sampleBuild.assetSources,
                bundleDirectory: stagingDirectory
            )

            var markdupBAMCount = 0
            var uniqueReadRowsUpdated = 0
            var auxiliarySamtoolsSteps: [NvdAuxiliaryStep] = []
            if let samtoolsPath, !copiedBAMs.bamURLs.isEmpty {
                let samtoolsVersion = metagenomicsExternalToolVersion(executablePath: samtoolsPath)
                progress?(0.72, "Marking duplicate reads...")
                let markdupResults = try MarkdupService.markdupDirectory(
                    bamDirectory,
                    samtoolsPath: samtoolsPath
                )
                markdupBAMCount = markdupResults.filter { !$0.wasAlreadyMarkduped }.count
                auxiliarySamtoolsSteps.append(contentsOf: nvdMarkdupAuxiliarySteps(
                    from: markdupResults,
                    samtoolsPath: samtoolsPath,
                    samtoolsVersion: samtoolsVersion
                ))

                progress?(0.78, "Counting unique reads...")
                let uniqueReadResult = nvdPopulateUniqueReads(
                    dbPath: databaseURL.path,
                    bundleDir: stagingDirectory,
                    samtoolsPath: samtoolsPath,
                    samtoolsVersion: samtoolsVersion
                )
                uniqueReadRowsUpdated = uniqueReadResult.updatedRows
                auxiliarySamtoolsSteps.append(contentsOf: uniqueReadResult.steps)
            }

            progress?(0.82, "Copying NVD FASTA files...")
            let copiedFASTACount = try nvdCopyFASTAAssets(
                sampleMetadata: sampleBuild.samples,
                assetSources: sampleBuild.assetSources,
                bundleDirectory: stagingDirectory
            )

            progress?(0.90, "Writing NVD manifest...")
            let manifest = nvdManifest(
                inputURL: inputURL,
                result: parseResult,
                sampleMetadata: sampleBuild.samples
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: stagingDirectory.appendingPathComponent("manifest.json"),
                options: .atomic
            )

            if provenanceCollisionTestHook {
                try fm.createDirectory(
                    at: stagingDirectory.appendingPathComponent(
                        ProvenanceRecorder.provenanceFilename,
                        isDirectory: true
                    ),
                    withIntermediateDirectories: true
                )
            }

            progress?(0.95, "Writing NVD provenance...")
            try writeMetagenomicsImportProvenance(
                kind: .nvd,
                sourceURLs: [inputURL],
                resultDirectory: stagingDirectory,
                publishedResultDirectory: finalDirectory,
                command: provenanceCommand,
                explicitOptions: [
                    "inputPath": .string(inputURL.path),
                    "csvPath": .string(csvURL.path),
                    "name": preferredName.map(ParameterValue.string) ?? .null,
                    "outputDir": .string(outputDirectory.path),
                    "outputRoot": .file(outputDirectory),
                    "samtoolsPath": samtoolsPath.map { .file(URL(fileURLWithPath: $0)) } ?? .null,
                ],
                resolvedDefaults: [
                    "inputPath": .string(inputURL.path),
                    "csvPath": .string(csvURL.path),
                    "outputDir": .string(outputDirectory.path),
                    "outputDirectory": .file(finalDirectory),
                    "bundleName": .string(finalDirectory.lastPathComponent),
                    "experiment": .string(parseResult.experiment),
                    "sampleCount": .integer(parseResult.sampleIds.count),
                    "hitCount": .integer(parseResult.hits.count),
                    "contigCount": .integer(sampleBuild.contigCount),
                    "copiedBAMCount": .integer(copiedBAMs.bamURLs.count),
                    "copiedBAMIndexCount": .integer(copiedBAMs.indexCount),
                    "copiedFASTACount": .integer(copiedFASTACount),
                    "markdupBAMCount": .integer(markdupBAMCount),
                    "uniqueReadRowsUpdated": .integer(uniqueReadRowsUpdated),
                ],
                startedAt: startedAt,
                workflowName: provenanceWorkflowName,
                toolName: provenanceToolName,
                additionalSteps: try nvdAuxiliaryProvenanceSteps(
                    from: auxiliarySamtoolsSteps,
                    stagingRoot: stagingDirectory,
                    publishedRoot: finalDirectory
                )
            )

            guard !fm.fileExists(atPath: finalDirectory.path) else {
                throw MetagenomicsImportError.outputAlreadyExists(finalDirectory)
            }
            OperationMarker.clearInProgress(stagingDirectory)
            try fm.moveItem(at: stagingDirectory, to: finalDirectory)

            progress?(1.0, "NVD import complete")
            return NvdImportResult(
                resultDirectory: finalDirectory,
                sampleCount: parseResult.sampleIds.count,
                hitCount: parseResult.hits.count,
                contigCount: sampleBuild.contigCount,
                copiedBAMCount: copiedBAMs.bamURLs.count,
                copiedBAMIndexCount: copiedBAMs.indexCount,
                copiedFASTACount: copiedFASTACount,
                markdupBAMCount: markdupBAMCount,
                uniqueReadRowsUpdated: uniqueReadRowsUpdated
            )
        } catch {
            try? fm.removeItem(at: stagingDirectory)
            throw MetagenomicsImportError.importAborted(
                resultDirectory: stagingDirectory,
                underlying: error
            )
        }
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
        provenanceCommand: [String]? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> NaoMgsImportResult {
        let startedAt = Date()
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
        var importCompleted = false
        defer { finalizeImportDirectory(resultDirectory, completed: importCompleted) }

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
        var materializationSteps: [NaoMgsBamMaterializationStep] = []
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
            materializationSteps.append(contentsOf: stageResult.materializationSteps)
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
        var bamStageOutputRelocations: [String: URL] = [:]
        var copiedBAMCount = 0
        for stageInput in stageInputs {
            let stageBamsDir = stageInput.databaseURL.deletingLastPathComponent()
                .appendingPathComponent("bams", isDirectory: true)
            if fm.fileExists(atPath: stageBamsDir.path),
               let bamFiles = try? fm.contentsOfDirectory(at: stageBamsDir, includingPropertiesForKeys: nil) {
                for src in bamFiles {
                    let dst = finalBamsDir.appendingPathComponent(src.lastPathComponent)
                    try? fm.removeItem(at: dst)
                    try fm.copyItem(at: src, to: dst)
                    recordNaoMgsOutputRelocation(from: src, to: dst, in: &bamStageOutputRelocations)
                    if src.pathExtension.lowercased() == "bam" {
                        copiedBAMCount += 1
                    }
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

        do {
            try writeMetagenomicsImportProvenance(
                kind: .naomgs,
                sourceURLs: [inputURL] + virusHitsFiles,
                resultDirectory: resultDirectory,
                command: provenanceCommand,
                explicitOptions: [
                    "input": .file(inputURL),
                    "sampleName": sampleName.map(ParameterValue.string) ?? .null,
                    "preferredName": preferredName.map(ParameterValue.string) ?? .null,
                    "outputRoot": .file(outputDirectory),
                    "minIdentity": .number(minIdentity),
                    "fetchReferences": .boolean(fetchReferences),
                ],
                resolvedDefaults: [
                    "outputDirectory": .file(resultDirectory),
                    "sampleName": .string(normalizedSampleName),
                    "sourceFileCount": .integer(virusHitsFiles.count),
                    "totalHitReads": .integer(totalHitCount),
                    "taxonCount": .integer(mergedTaxonCount),
                    "fetchedReferenceCount": .integer(fetchedAccessions.count),
                    "createdBAM": .boolean(copiedBAMCount > 0),
                    "copiedBAMCount": .integer(copiedBAMCount),
                ],
                startedAt: startedAt,
                additionalSteps: try naoMgsMaterializationProvenanceSteps(
                    from: materializationSteps,
                    sourceURLs: [inputURL] + virusHitsFiles,
                    relocatedOutputs: bamStageOutputRelocations
                )
            )
        } catch {
            try? fm.removeItem(at: resultDirectory)
            throw error
        }

        progress?(1.0, "NAO-MGS import complete")
        importCompleted = true
        return NaoMgsImportResult(
            resultDirectory: resultDirectory,
            sampleName: normalizedSampleName,
            totalHitReads: totalHitCount,
            taxonCount: mergedTaxonCount,
            fetchedReferenceCount: fetchedAccessions.count,
            createdBAM: copiedBAMCount > 0
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
        var materializationSteps: [NaoMgsBamMaterializationStep] = []
        if let samtoolsPath = managedSamtoolsExecutableURL()?.path {
            let materialized = try NaoMgsBamMaterializer.materializeAllWithProvenance(
                dbPath: hitsDBURL.path,
                resultURL: stageDir,
                samtoolsPath: samtoolsPath,
                lungfishVersion: WorkflowRun.currentAppVersion
            )
            let generated = materialized.bamURLs
            materializationSteps.append(contentsOf: materialized.steps)
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
            ),
            materializationSteps: materializationSteps
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

private struct NvdSampleBuildResult {
    let samples: [NvdSampleMetadata]
    let assetSources: [String: NvdSampleAssetSources]
    let contigCount: Int
}

private struct NvdSampleAssetSources {
    let bam: URL?
    let bamIndex: URL?
    let fasta: URL?
}

private struct NvdBAMCopyResult {
    let bamURLs: [URL]
    let indexCount: Int
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

private func finalizeImportDirectory(_ directory: URL, completed: Bool) {
    if completed {
        OperationMarker.clearInProgress(directory)
    } else {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Writes `analysis-metadata.json` into a result directory so that it remains
/// identifiable by ``AnalysesFolder`` even after the user renames it.
private func writeAnalysisMetadataIfNeeded(tool: String, to directory: URL) {
    let metadata = AnalysesFolder.AnalysisMetadata(tool: tool, isBatch: false)
    try? AnalysesFolder.writeAnalysisMetadata(metadata, to: directory)
}

private func writeMetagenomicsImportProvenance(
    kind: MetagenomicsImportKind,
    sourceURLs: [URL],
    resultDirectory: URL,
    publishedResultDirectory: URL? = nil,
    command: [String]?,
    explicitOptions: [String: ParameterValue],
    resolvedDefaults: [String: ParameterValue],
    startedAt: Date,
    workflowName: String? = nil,
    toolName: String = "lungfish import",
    additionalSteps: [ProvenanceStep] = []
) throws {
    let completedAt = Date()
    let reportedResultDirectory = publishedResultDirectory ?? resultDirectory
    let argv = command ?? defaultMetagenomicsImportCommand(
        kind: kind,
        sourceURLs: sourceURLs,
        resultDirectory: reportedResultDirectory,
        explicitOptions: explicitOptions
    )
    let inputDescriptors = try metagenomicsInputDescriptors(for: sourceURLs)
    let resultDirectoryDescriptor = ProvenanceFileDescriptor(
        path: reportedResultDirectory.path,
        format: .unknown,
        role: .output
    )
    let outputDescriptors = try metagenomicsOutputDescriptors(
        in: resultDirectory,
        publishedRoot: reportedResultDirectory
    )
    let outputs = [resultDirectoryDescriptor] + outputDescriptors
    let wallTime = completedAt.timeIntervalSince(startedAt)
    let toolVersion = WorkflowRun.currentAppVersion
    let step = ProvenanceStep(
        toolName: toolName,
        toolVersion: toolVersion,
        argv: argv,
        durableReplayArgv: argv,
        inputs: inputDescriptors,
        outputs: outputs,
        exitStatus: 0,
        wallTimeSeconds: wallTime,
        startedAt: startedAt,
        completedAt: completedAt
    )
    let envelope = ProvenanceEnvelope(
        createdAt: startedAt,
        workflowName: workflowName ?? "lungfish import \(kind.importCommandToken)",
        workflowVersion: toolVersion,
        toolName: toolName,
        toolVersion: toolVersion,
        tool: ProvenanceToolIdentity(name: toolName, version: toolVersion, kind: "cli"),
        argv: argv,
        durableReplayArgv: argv,
        options: ProvenanceOptions(
            explicit: explicitOptions,
            defaults: defaultMetagenomicsImportOptions(kind: kind),
            resolvedDefaults: resolvedDefaults.merging([
                "outputDirectory": .file(reportedResultDirectory),
                "resultBundle": .file(reportedResultDirectory),
            ]) { existing, _ in existing }
        ),
        files: uniqueProvenanceDescriptors(
            inputDescriptors
                + outputs
                + additionalSteps.flatMap(\.inputs)
                + additionalSteps.flatMap(\.outputs)
        ),
        output: resultDirectoryDescriptor,
        outputs: outputs,
        steps: [step] + additionalSteps,
        wallTimeSeconds: wallTime,
        exitStatus: 0
    )

    try ProvenanceWriter(signingProvider: nil).write(envelope, to: resultDirectory)
}

private func naoMgsMaterializationProvenanceSteps(
    from materializationSteps: [NaoMgsBamMaterializationStep],
    sourceURLs: [URL],
    relocatedOutputs: [String: URL]
) throws -> [ProvenanceStep] {
    guard !materializationSteps.isEmpty else { return [] }
    let sourceInputDescriptors = try metagenomicsInputDescriptors(for: sourceURLs)
    return try materializationSteps.map { step in
        let inputDescriptors: [ProvenanceFileDescriptor]
        if step.toolName == "lungfish nao-mgs materialize-bam" {
            inputDescriptors = sourceInputDescriptors
        } else {
            let directInputs = try uniqueProvenanceDescriptors(step.inputURLs.compactMap { inputURL in
                try naoMgsRelocatedDescriptor(
                    for: inputURL,
                    role: .input,
                    relocatedOutputs: relocatedOutputs
                )
            })
            inputDescriptors = directInputs.isEmpty ? sourceInputDescriptors : directInputs
        }
        let outputDescriptors = try uniqueProvenanceDescriptors(step.outputURLs.compactMap { outputURL in
            try naoMgsRelocatedDescriptor(
                for: outputURL,
                role: metagenomicsOutputRole(for: relocatedNaoMgsOutputURL(for: outputURL, relocatedOutputs: relocatedOutputs)),
                relocatedOutputs: relocatedOutputs
            )
        })
        return ProvenanceStep(
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            argv: step.argv,
            durableReplayArgv: step.argv,
            reproducibleCommand: step.reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            stderr: step.stderr,
            startedAt: step.startedAt,
            completedAt: step.completedAt
        )
    }
}

private func naoMgsRelocatedDescriptor(
    for url: URL,
    role: FileRole,
    relocatedOutputs: [String: URL]
) throws -> ProvenanceFileDescriptor? {
    let finalURL = relocatedNaoMgsOutputURL(for: url, relocatedOutputs: relocatedOutputs)
    guard FileManager.default.fileExists(atPath: finalURL.path) else { return nil }
    return try ProvenanceFileDescriptor.file(
        url: finalURL,
        format: metagenomicsFileFormat(for: finalURL),
        role: role,
        originPath: finalURL.path == url.path ? nil : url.path
    )
}

private func recordNaoMgsOutputRelocation(from sourceURL: URL, to destinationURL: URL, in relocations: inout [String: URL]) {
    for path in naoMgsPathCandidates(for: sourceURL) {
        relocations[path] = destinationURL
    }
}

private func relocatedNaoMgsOutputURL(for outputURL: URL, relocatedOutputs: [String: URL]) -> URL {
    for path in naoMgsPathCandidates(for: outputURL) {
        if let relocated = relocatedOutputs[path] {
            return relocated
        }
    }
    return outputURL
}

private func naoMgsPathCandidates(for url: URL) -> Set<String> {
    var candidates = Set([
        url.path,
        url.standardizedFileURL.path,
        url.resolvingSymlinksInPath().path,
    ])
    for candidate in candidates {
        if candidate.hasPrefix("/var/") {
            candidates.insert("/private" + candidate)
        } else if candidate.hasPrefix("/private/var/") {
            candidates.insert(String(candidate.dropFirst("/private".count)))
        }
    }
    return candidates
}

private func defaultMetagenomicsImportCommand(
    kind: MetagenomicsImportKind,
    sourceURLs: [URL],
    resultDirectory: URL,
    explicitOptions: [String: ParameterValue]
) -> [String] {
    let source = sourceURLs.first?.path ?? "<input>"
    var argv = [
        "lungfish-cli",
        "import",
        kind.importCommandToken,
        source,
        "--output-dir",
        resultDirectory.deletingLastPathComponent().path,
    ]

    switch kind {
    case .kraken2:
        if let preferredName = explicitOptions["preferredName"]?.stringValue, !preferredName.isEmpty {
            argv += ["--name", preferredName]
        }
        if let outputFile = explicitOptions["outputFile"]?.fileValue {
            argv += ["--output", outputFile.path]
        }
    case .esviritu, .taxtriage:
        if let preferredName = explicitOptions["preferredName"]?.stringValue, !preferredName.isEmpty {
            argv += ["--name", preferredName]
        }
    case .naomgs:
        if let sampleName = explicitOptions["sampleName"]?.stringValue, !sampleName.isEmpty {
            argv += ["--sample-name", sampleName]
        }
        if explicitOptions["fetchReferences"]?.booleanValue == false {
            argv.append("--no-fetch-references")
        }
    case .nvd:
        if let name = explicitOptions["name"]?.stringValue, !name.isEmpty {
            argv += ["--name", name]
        }
    }

    return argv
}

private func defaultMetagenomicsImportOptions(kind: MetagenomicsImportKind) -> [String: ParameterValue] {
    switch kind {
    case .kraken2:
        return [
            "outputFile": .null,
            "preferredName": .null,
        ]
    case .esviritu, .taxtriage:
        return [
            "preferredName": .null,
        ]
    case .naomgs:
        return [
            "sampleName": .null,
            "preferredName": .null,
            "minIdentity": .number(0),
            "fetchReferences": .boolean(true),
        ]
    case .nvd:
        return [
            "name": .null,
            "samtoolsPath": .null,
        ]
    }
}

private func metagenomicsInputDescriptors(for sourceURLs: [URL]) throws -> [ProvenanceFileDescriptor] {
    var descriptors: [ProvenanceFileDescriptor] = []
    for sourceURL in uniqueURLs(sourceURLs) {
        if isDirectory(sourceURL) {
            descriptors.append(ProvenanceFileDescriptor(
                path: sourceURL.path,
                format: .unknown,
                role: .input
            ))
            descriptors.append(contentsOf: try scanRegularFilesRecursively(in: sourceURL).map {
                try metagenomicsFileDescriptor(url: $0, role: .input)
            })
        } else {
            descriptors.append(try metagenomicsFileDescriptor(url: sourceURL, role: .input))
        }
    }
    return uniqueProvenanceDescriptors(descriptors)
}

private func sourcePayloadURLs(
    inputURL: URL,
    copiedRegularFiles: [URL],
    resultDirectory: URL
) -> [URL] {
    guard isDirectory(inputURL) else {
        return [inputURL]
    }

    let originalFiles = copiedRegularFiles.map { copiedURL in
        inputURL.appendingPathComponent(relativePath(from: resultDirectory, to: copiedURL))
    }
    return [inputURL] + originalFiles
}

private func metagenomicsOutputDescriptors(
    in resultDirectory: URL,
    publishedRoot: URL? = nil
) throws -> [ProvenanceFileDescriptor] {
    try scanRegularFilesRecursively(in: resultDirectory)
        .filter { !isGeneratedProvenanceArtifact($0, root: resultDirectory) }
        .map { outputURL in
            let descriptor = try metagenomicsFileDescriptor(
                url: outputURL,
                role: metagenomicsOutputRole(for: outputURL)
            )
            guard let publishedRoot else { return descriptor }
            let publishedURL = publishedRoot.appendingPathComponent(
                relativePath(from: resultDirectory, to: outputURL)
            )
            return ProvenanceFileDescriptor(
                path: publishedURL.path,
                checksumSHA256: descriptor.checksumSHA256,
                fileSize: descriptor.fileSize,
                format: descriptor.format,
                role: descriptor.role,
                originPath: descriptor.originPath,
                sourceProvenancePath: descriptor.sourceProvenancePath
            )
        }
}

private func metagenomicsFileDescriptor(url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
    try ProvenanceFileDescriptor.file(
        url: url,
        format: metagenomicsFileFormat(for: url),
        role: role
    )
}

private func metagenomicsOutputRole(for url: URL) -> FileRole {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".bai") || name.hasSuffix(".csi") || name.hasSuffix(".fai") || name.hasSuffix(".idx.sqlite") {
        return .index
    }
    if name.contains("report") || name.hasSuffix(".kreport") || name == "manifest.json" {
        return .report
    }
    if name.contains("log") || name.hasSuffix(".trace") || name == "trace.txt" {
        return .log
    }
    return .output
}

private func metagenomicsFileFormat(for url: URL) -> FileFormat {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".fa") || name.hasSuffix(".fasta") || name.hasSuffix(".fna") {
        return .fasta
    }
    if name.hasSuffix(".fastq") || name.hasSuffix(".fq") || name.hasSuffix(".fastq.gz") || name.hasSuffix(".fq.gz") {
        return .fastq
    }
    if name.hasSuffix(".bam") {
        return .bam
    }
    if name.hasSuffix(".sam") {
        return .sam
    }
    if name.hasSuffix(".json") || name.hasSuffix(".json.gz") {
        return .json
    }
    if name.hasSuffix(".html") || name.hasSuffix(".htm") {
        return .html
    }
    if name.hasSuffix(".tsv") || name.hasSuffix(".tsv.gz") || name.hasSuffix(".txt") || name.hasSuffix(".log") || name.hasSuffix(".kreport") {
        return .text
    }
    return .unknown
}

private func isGeneratedProvenanceArtifact(_ url: URL, root: URL) -> Bool {
    let relativePath = relativePath(from: root, to: url)
    return url.lastPathComponent == ProvenanceRecorder.provenanceFilename
        || relativePath == ProvenanceWriter.bundleRollupFilename
        || relativePath.hasPrefix("\(ProvenanceWriter.bundleProvenanceDirectoryName)/")
        || url.lastPathComponent.hasSuffix(".sig")
}

private func uniqueURLs(_ urls: [URL]) -> [URL] {
    var seen: Set<String> = []
    var result: [URL] = []
    for url in urls {
        let key = url.standardizedFileURL.path
        guard seen.insert(key).inserted else { continue }
        result.append(url)
    }
    return result
}

private func uniqueProvenanceDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
    var seen: Set<String> = []
    var result: [ProvenanceFileDescriptor] = []
    for descriptor in descriptors {
        guard seen.insert("\(descriptor.role.rawValue):\(descriptor.path)").inserted else { continue }
        result.append(descriptor)
    }
    return result
}

private func relativePath(from root: URL, to url: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
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

private func nvdResultDirectory(named bundleName: String, in outputDirectory: URL, allowUniqueSuffix: Bool) throws -> URL {
    let fm = FileManager.default
    let firstCandidate = outputDirectory.appendingPathComponent(bundleName, isDirectory: true)
    if !fm.fileExists(atPath: firstCandidate.path) {
        return firstCandidate
    }
    guard allowUniqueSuffix else {
        throw MetagenomicsImportError.outputAlreadyExists(firstCandidate)
    }

    var index = 2
    while true {
        let candidate = outputDirectory.appendingPathComponent("\(bundleName)-\(index)", isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        index += 1
    }
}

private func nvdBuildSampleMetadata(inputURL: URL, result: NvdParseResult) throws -> NvdSampleBuildResult {
    let fm = FileManager.default
    let humanVirusDir = inputURL
        .appendingPathComponent("02_human_viruses", isDirectory: true)
        .appendingPathComponent("03_human_virus_results", isDirectory: true)
    let bamSourceDir = humanVirusDir.appendingPathComponent("mapped_reads", isDirectory: true)
    let sourceBamFiles = (try? fm.contentsOfDirectory(at: bamSourceDir, includingPropertiesForKeys: nil)) ?? []
    let sourceFastaFiles = (try? fm.contentsOfDirectory(at: humanVirusDir, includingPropertiesForKeys: nil)) ?? []

    var perSampleHits: [String: Int] = [:]
    var perSampleContigs: [String: Set<String>] = [:]
    var perSampleTotalReads: [String: Int] = [:]
    for hit in result.hits {
        perSampleHits[hit.sampleId, default: 0] += 1
        perSampleContigs[hit.sampleId, default: []].insert(hit.qseqid)
        if perSampleTotalReads[hit.sampleId] == nil {
            perSampleTotalReads[hit.sampleId] = hit.totalReads
        }
    }

    var samples: [NvdSampleMetadata] = []
    var assetSources: [String: NvdSampleAssetSources] = [:]
    for sampleId in result.sampleIds.sorted() {
        let bamSource = sourceBamFiles.first { url in
            let name = url.lastPathComponent
            return url.pathExtension.lowercased() == "bam"
                && name.localizedCaseInsensitiveContains(sampleId)
        }
        let bamIndexSource: URL? = {
            guard let bamSource else { return nil }
            let bai = URL(fileURLWithPath: bamSource.path + ".bai")
            let csi = URL(fileURLWithPath: bamSource.path + ".csi")
            if fm.fileExists(atPath: bai.path) { return bai }
            if fm.fileExists(atPath: csi.path) { return csi }
            let bamBai = sourceBamFiles.first { $0.lastPathComponent == bamSource.lastPathComponent + ".bai" }
            let bamCsi = sourceBamFiles.first { $0.lastPathComponent == bamSource.lastPathComponent + ".csi" }
            return bamBai ?? bamCsi
        }()
        let fastaSource = sourceFastaFiles.first { url in
            let name = url.lastPathComponent
            return name.hasSuffix(".human_virus.fasta")
                && name.localizedCaseInsensitiveContains(sampleId)
        }

        let canonicalBamName = "\(sampleId).bam"
        let bamRelPath = "bam/\(canonicalBamName)"
        let bamIndexRelPath: String? = {
            guard let bamIndexSource else { return nil }
            if bamIndexSource.pathExtension.lowercased() == "csi" {
                return "bam/\(canonicalBamName).csi"
            }
            return "bam/\(canonicalBamName).bai"
        }()
        let fastaRelPath = "fasta/\(sampleId).human_virus.fasta"

        samples.append(NvdSampleMetadata(
            sampleId: sampleId,
            bamPath: bamRelPath,
            bamIndexPath: bamIndexRelPath,
            fastaPath: fastaRelPath,
            totalReads: perSampleTotalReads[sampleId] ?? 0,
            contigCount: perSampleContigs[sampleId]?.count ?? 0,
            hitCount: perSampleHits[sampleId] ?? 0
        ))
        assetSources[sampleId] = NvdSampleAssetSources(
            bam: bamSource,
            bamIndex: bamIndexSource,
            fasta: fastaSource
        )
    }

    let contigCount = Set(result.hits.map { "\($0.sampleId)\u{1F}\($0.qseqid)" }).count
    return NvdSampleBuildResult(
        samples: samples,
        assetSources: assetSources,
        contigCount: contigCount
    )
}

private func nvdCopyBAMAssets(
    sampleMetadata: [NvdSampleMetadata],
    assetSources: [String: NvdSampleAssetSources],
    bundleDirectory: URL
) throws -> NvdBAMCopyResult {
    var copiedBAMs: [URL] = []
    var copiedIndexes = 0
    for sample in sampleMetadata {
        guard let sources = assetSources[sample.sampleId] else { continue }
        if let bamSource = sources.bam {
            let bamDestination = bundleDirectory.appendingPathComponent(sample.bamPath)
            try copyFile(bamSource, to: bamDestination)
            copiedBAMs.append(bamDestination)
        }
        if let bamIndexSource = sources.bamIndex,
           let bamIndexPath = sample.bamIndexPath {
            try copyFile(bamIndexSource, to: bundleDirectory.appendingPathComponent(bamIndexPath))
            copiedIndexes += 1
        }
    }
    return NvdBAMCopyResult(bamURLs: copiedBAMs, indexCount: copiedIndexes)
}

private func nvdCopyFASTAAssets(
    sampleMetadata: [NvdSampleMetadata],
    assetSources: [String: NvdSampleAssetSources],
    bundleDirectory: URL
) throws -> Int {
    var copied = 0
    for sample in sampleMetadata {
        guard let fastaSource = assetSources[sample.sampleId]?.fasta else { continue }
        try copyFile(fastaSource, to: bundleDirectory.appendingPathComponent(sample.fastaPath))
        copied += 1
    }
    return copied
}

private func nvdManifest(
    inputURL: URL,
    result: NvdParseResult,
    sampleMetadata: [NvdSampleMetadata]
) -> NvdManifest {
    let topContigs: [NvdContigRow] = result.hits
        .filter { $0.hitRank == 1 }
        .prefix(200)
        .map { hit in
            NvdContigRow(
                sampleId: hit.sampleId,
                qseqid: hit.qseqid,
                qlen: hit.qlen,
                adjustedTaxidName: hit.adjustedTaxidName,
                adjustedTaxidRank: hit.adjustedTaxidRank,
                sseqid: hit.sseqid,
                stitle: hit.stitle,
                pident: hit.pident,
                evalue: hit.evalue,
                bitscore: hit.bitscore,
                mappedReads: hit.mappedReads,
                readsPerBillion: hit.readsPerBillion
            )
        }

    let sampleSummaries = sampleMetadata.map { sample in
        NvdSampleSummary(
            sampleId: sample.sampleId,
            contigCount: sample.contigCount,
            hitCount: sample.hitCount,
            totalReads: sample.totalReads,
            bamRelativePath: sample.bamPath,
            fastaRelativePath: sample.fastaPath
        )
    }

    return NvdManifest(
        experiment: result.experiment,
        sampleCount: result.sampleIds.count,
        contigCount: Set(result.hits.map { "\($0.sampleId)\u{1F}\($0.qseqid)" }).count,
        hitCount: result.hits.count,
        blastDbVersion: result.hits.first?.blastDbVersion,
        snakemakeRunId: result.hits.first?.snakemakeRunId,
        sourceDirectoryPath: inputURL.path,
        samples: sampleSummaries,
        cachedTopContigs: topContigs
    )
}

private struct NvdAuxiliaryStep {
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let reproducibleCommand: String
    let inputURLs: [URL]
    let outputURLs: [URL]
    let exitStatus: Int?
    let wallTimeSeconds: TimeInterval?
    let stderr: String?
    let startedAt: Date?
    let completedAt: Date?
}

private struct NvdUniqueReadPopulationResult {
    let updatedRows: Int
    let steps: [NvdAuxiliaryStep]
}

private func nvdMarkdupAuxiliarySteps(
    from results: [MarkdupResult],
    samtoolsPath: String,
    samtoolsVersion: String
) -> [NvdAuxiliaryStep] {
    results.map { result in
        let baiURL = URL(fileURLWithPath: result.bamURL.path + ".bai")
        var outputURLs = [result.bamURL]
        if FileManager.default.fileExists(atPath: baiURL.path) {
            outputURLs.append(baiURL)
        }
        let argv: [String]
        let command: String
        if result.wasAlreadyMarkduped {
            argv = [samtoolsPath, "view", "-H", result.bamURL.path]
            command = argv.map(metagenomicsShellEscape).joined(separator: " ")
        } else {
            command = nvdMarkdupReplayCommand(
                bamURL: result.bamURL,
                samtoolsPath: samtoolsPath,
                threads: 4
            )
            argv = ["/bin/sh", "-c", command]
        }
        return NvdAuxiliaryStep(
            toolName: "samtools",
            toolVersion: samtoolsVersion,
            argv: argv,
            reproducibleCommand: command,
            inputURLs: [result.bamURL],
            outputURLs: outputURLs,
            exitStatus: 0,
            wallTimeSeconds: result.durationSeconds,
            stderr: nil,
            startedAt: nil,
            completedAt: nil
        )
    }
}

private func nvdMarkdupReplayCommand(bamURL: URL, samtoolsPath: String, threads: Int) -> String {
    let tempBamPath = bamURL.path + ".markdup.tmp"
    let tempBaiPath = tempBamPath + ".bai"
    let baiPath = bamURL.path + ".bai"
    let csiPath = bamURL.path + ".csi"
    let escapedSamtoolsPath = metagenomicsShellEscape(samtoolsPath)
    return [
        "\(escapedSamtoolsPath) sort -n -@ \(threads) \(metagenomicsShellEscape(bamURL.path))",
        "\(escapedSamtoolsPath) fixmate -m - -",
        "\(escapedSamtoolsPath) sort -@ \(threads) -",
        "\(escapedSamtoolsPath) markdup - \(metagenomicsShellEscape(tempBamPath))",
    ].joined(separator: " | ")
        + " && \(escapedSamtoolsPath) index \(metagenomicsShellEscape(tempBamPath))"
        + " && rm -f \(metagenomicsShellEscape(baiPath)) \(metagenomicsShellEscape(csiPath))"
        + " && mv \(metagenomicsShellEscape(tempBamPath)) \(metagenomicsShellEscape(bamURL.path))"
        + " && mv \(metagenomicsShellEscape(tempBaiPath)) \(metagenomicsShellEscape(baiPath))"
}

private func nvdPopulateUniqueReads(
    dbPath: String,
    bundleDir: URL,
    samtoolsPath: String,
    samtoolsVersion: String
) -> NvdUniqueReadPopulationResult {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
        sqlite3_close(db)
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }
    defer { sqlite3_close(db) }

    let selectSQL = "SELECT rowid, sample_id, sseqid FROM blast_hits"
    var selectStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }
    defer { sqlite3_finalize(selectStmt) }

    struct Row { let rowid: Int64; let sampleId: String; let sseqid: String }
    var rows: [Row] = []
    var step = sqlite3_step(selectStmt)
    while step == SQLITE_ROW {
        guard let samplePtr = sqlite3_column_text(selectStmt, 1),
              let accessionPtr = sqlite3_column_text(selectStmt, 2) else {
            step = sqlite3_step(selectStmt)
            continue
        }
        rows.append(Row(
            rowid: sqlite3_column_int64(selectStmt, 0),
            sampleId: String(cString: samplePtr),
            sseqid: String(cString: accessionPtr)
        ))
        step = sqlite3_step(selectStmt)
    }
    guard step == SQLITE_DONE, !rows.isEmpty else {
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }

    let sampleSQL = "SELECT sample_id, bam_path FROM samples"
    var sampleStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sampleSQL, -1, &sampleStmt, nil) == SQLITE_OK else {
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }
    defer { sqlite3_finalize(sampleStmt) }

    var bamBySample: [String: URL] = [:]
    step = sqlite3_step(sampleStmt)
    while step == SQLITE_ROW {
        guard let samplePtr = sqlite3_column_text(sampleStmt, 0),
              let bamPtr = sqlite3_column_text(sampleStmt, 1) else {
            step = sqlite3_step(sampleStmt)
            continue
        }
        bamBySample[String(cString: samplePtr)] = bundleDir.appendingPathComponent(String(cString: bamPtr))
        step = sqlite3_step(sampleStmt)
    }
    guard step == SQLITE_DONE, !bamBySample.isEmpty else {
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }

    let updateSQL = "UPDATE blast_hits SET unique_reads = ? WHERE rowid = ?"
    var updateStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }
    defer { sqlite3_finalize(updateStmt) }

    guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: [])
    }
    var cache: [String: Int] = [:]
    var updated = 0
    var steps: [NvdAuxiliaryStep] = []
    let databaseURL = URL(fileURLWithPath: dbPath)
    for row in rows {
        guard let bamURL = bamBySample[row.sampleId],
              FileManager.default.fileExists(atPath: bamURL.path) else { continue }

        let cacheKey = "\(bamURL.path)\t\(row.sseqid)"
        let unique: Int
        if let cached = cache[cacheKey] {
            unique = cached
        } else {
            let countResult = nvdCountReadsWithTelemetry(
                bamURL: bamURL,
                accession: row.sseqid,
                flagFilter: 0x404,
                samtoolsPath: samtoolsPath,
                samtoolsVersion: samtoolsVersion,
                databaseURL: databaseURL
            )
            steps.append(countResult.step)
            guard let counted = countResult.count else {
                continue
            }
            cache[cacheKey] = counted
            unique = counted
        }

        sqlite3_reset(updateStmt)
        sqlite3_clear_bindings(updateStmt)
        sqlite3_bind_int64(updateStmt, 1, Int64(unique))
        sqlite3_bind_int64(updateStmt, 2, row.rowid)
        guard sqlite3_step(updateStmt) == SQLITE_DONE else { continue }
        updated += 1
    }

    if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        return NvdUniqueReadPopulationResult(updatedRows: 0, steps: steps)
    }
    return NvdUniqueReadPopulationResult(updatedRows: updated, steps: steps)
}

private func nvdCountReadsWithTelemetry(
    bamURL: URL,
    accession: String,
    flagFilter: Int,
    samtoolsPath: String,
    samtoolsVersion: String,
    databaseURL: URL
) -> (count: Int?, step: NvdAuxiliaryStep) {
    let startedAt = Date()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: samtoolsPath)
    let argv = [samtoolsPath, "view", "-c", "-F", String(flagFilter), bamURL.path, accession]
    process.arguments = Array(argv.dropFirst())
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        let completedAt = Date()
        return (
            nil,
            NvdAuxiliaryStep(
                toolName: "samtools",
                toolVersion: samtoolsVersion,
                argv: argv,
                reproducibleCommand: argv.map(metagenomicsShellEscape).joined(separator: " "),
                inputURLs: [bamURL],
                outputURLs: [],
                exitStatus: 1,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: error.localizedDescription,
                startedAt: startedAt,
                completedAt: completedAt
            )
        )
    }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let completedAt = Date()
    let stderrText = String(data: stderrData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let output = String(data: outputData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    let count = process.terminationStatus == 0 ? Int(output) : nil
    return (
        count,
        NvdAuxiliaryStep(
            toolName: "samtools",
            toolVersion: samtoolsVersion,
            argv: argv,
            reproducibleCommand: argv.map(metagenomicsShellEscape).joined(separator: " "),
            inputURLs: [bamURL],
            outputURLs: count == nil ? [] : [databaseURL],
            exitStatus: Int(process.terminationStatus),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderrText.isEmpty ? nil : stderrText,
            startedAt: startedAt,
            completedAt: completedAt
        )
    )
}

private func nvdAuxiliaryProvenanceSteps(
    from auxiliarySteps: [NvdAuxiliaryStep],
    stagingRoot: URL,
    publishedRoot: URL
) throws -> [ProvenanceStep] {
    try auxiliarySteps.map { step in
        let inputs = try uniqueProvenanceDescriptors(step.inputURLs.compactMap { inputURL in
            try nvdReportedDescriptor(
                for: inputURL,
                role: .input,
                stagingRoot: stagingRoot,
                publishedRoot: publishedRoot
            )
        })
        let outputs = try uniqueProvenanceDescriptors(step.outputURLs.compactMap { outputURL in
            try nvdReportedDescriptor(
                for: outputURL,
                role: metagenomicsOutputRole(for: outputURL),
                stagingRoot: stagingRoot,
                publishedRoot: publishedRoot
            )
        })
        return ProvenanceStep(
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            argv: step.argv,
            durableReplayArgv: step.argv,
            reproducibleCommand: step.reproducibleCommand,
            inputs: inputs,
            outputs: outputs,
            exitStatus: step.exitStatus,
            wallTimeSeconds: step.wallTimeSeconds,
            stderr: step.stderr,
            startedAt: step.startedAt,
            completedAt: step.completedAt
        )
    }
}

private func nvdReportedDescriptor(
    for url: URL,
    role: FileRole,
    stagingRoot: URL,
    publishedRoot: URL
) throws -> ProvenanceFileDescriptor? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let reportedURL = nvdPublishedURL(for: url, stagingRoot: stagingRoot, publishedRoot: publishedRoot)
    return ProvenanceFileDescriptor(
        path: reportedURL.path,
        checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
        fileSize: try ProvenanceFileHasher.fileSize(of: url),
        format: metagenomicsFileFormat(for: reportedURL),
        role: role,
        originPath: reportedURL.path == url.path ? nil : url.path
    )
}

private func nvdPublishedURL(for url: URL, stagingRoot: URL, publishedRoot: URL) -> URL {
    let stagingPath = stagingRoot.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path == stagingPath || path.hasPrefix(stagingPath + "/") else {
        return url
    }
    let relativePath = String(path.dropFirst(stagingPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !relativePath.isEmpty else { return publishedRoot }
    return publishedRoot.appendingPathComponent(relativePath)
}

private func metagenomicsExternalToolVersion(executablePath: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if let firstLine = output.split(separator: "\n").first {
            return String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    } catch {
        logger.warning("Could not detect external tool version for \(executablePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
    return "unknown"
}

private func metagenomicsShellEscape(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./:=@+,"))
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
