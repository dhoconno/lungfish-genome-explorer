import Foundation
import LungfishCore
import LungfishIO

public struct ONTBarcodeDemuxGenotypingRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let referenceSourceURL: URL
    public let barcodeDefinitionsURL: URL
    public let outputDirectory: URL
    public let outputName: String
    public let demuxManifestURL: URL?
    public let analysisName: String
    public let comparisonWorkbookURL: URL?
    public let comparisonName: String?
    public let projectURL: URL?
    public let threads: Int
    public let sortThreads: Int
    public let minSupport: Int
    public let haplotypeAssayID: String?
    public let haplotypeDefinitionSetID: String?
    public let extraArguments: [String]

    public init(
        inputFASTQURL: URL,
        referenceSourceURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        outputName: String = "ont-barcode-genotyping",
        demuxManifestURL: URL? = nil,
        analysisName: String? = nil,
        comparisonWorkbookURL: URL? = nil,
        comparisonName: String? = "Illumina-31262",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        sortThreads: Int = 4,
        minSupport: Int = 1,
        haplotypeAssayID: String? = nil,
        haplotypeDefinitionSetID: String? = nil,
        extraArguments: [String] = []
    ) {
        let normalizedOutputName = Self.sanitizedOutputName(outputName)
        self.inputFASTQURL = inputFASTQURL.standardizedFileURL
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        self.barcodeDefinitionsURL = barcodeDefinitionsURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = normalizedOutputName
        self.demuxManifestURL = demuxManifestURL?.standardizedFileURL
        self.analysisName = Self.sanitizedReportLabel(
            analysisName ?? normalizedOutputName,
            fallback: normalizedOutputName
        )
        self.comparisonWorkbookURL = comparisonWorkbookURL?.standardizedFileURL
        self.comparisonName = comparisonWorkbookURL == nil
            ? nil
            : Self.sanitizedReportLabel(comparisonName ?? "Illumina-31262", fallback: "Illumina-31262")
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.sortThreads = max(1, sortThreads)
        self.minSupport = max(1, minSupport)
        let trimmedHaplotypeAssayID = haplotypeAssayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeAssayID = trimmedHaplotypeAssayID?.isEmpty == true
            ? nil
            : trimmedHaplotypeAssayID
        let trimmedHaplotypeDefinitionSetID = haplotypeDefinitionSetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeDefinitionSetID = trimmedHaplotypeDefinitionSetID?.isEmpty == true
            ? nil
            : trimmedHaplotypeDefinitionSetID
        self.extraArguments = extraArguments
    }

    public var mappingBAMURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).md.sorted.bam")
    }

    public var mappingBAIURL: URL {
        mappingBAMURL.appendingPathExtension("bai")
    }

    public var retainedBAMURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained.demuxed.bam")
    }

    public var retainedBAIURL: URL {
        retainedBAMURL.appendingPathExtension("bai")
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained-demux-genotypes.csv")
    }

    public var sampleSummaryCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained-demux-samples.csv")
    }

    public var statsJSONURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).retained-demux-stats.json")
    }

    public var haplotypeAnalysisURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).haplotype-analysis.json")
    }

    public var reportProvenanceURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).report-workbook-provenance.json")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json")
    }

    public var workbookURL: URL {
        let comparisonSuffix = comparisonName.map { "_vs_\($0)" } ?? ""
        let analysisSuffix = analysisName == outputName ? "" : "_\(analysisName)"
        return outputDirectory.appendingPathComponent("\(outputName)\(analysisSuffix)\(comparisonSuffix).xlsx")
    }

    public var argv: [String] {
        var values = [
            "lungfish",
            "fastq",
            "ont-barcode-genotype",
            inputFASTQURL.path,
            "--reference", referenceSourceURL.path,
            "--barcodes", barcodeDefinitionsURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--sort-threads", String(sortThreads),
            "--min-support", String(minSupport),
            "--analysis-name", analysisName,
        ]
        if let haplotypeDefinitionSetID {
            if let haplotypeAssayID {
                values += ["--haplotype-assay", haplotypeAssayID]
            }
            values += ["--haplotype-definition", haplotypeDefinitionSetID]
        }
        if let demuxManifestURL {
            values += ["--demux-manifest", demuxManifestURL.path]
        }
        if let comparisonWorkbookURL {
            values += ["--comparison-workbook", comparisonWorkbookURL.path]
        }
        if let comparisonName {
            values += ["--comparison-name", comparisonName]
        }
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if !extraArguments.isEmpty {
            values += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        return values
    }

    private static func sanitizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "ont-barcode-genotyping" : collapsed
    }

    private static func sanitizedReportLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            if character.isWhitespace {
                return nil
            }
            return "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? fallback : collapsed
    }
}

public struct ONTBarcodeDemuxGenotypingResult: Sendable, Codable, Equatable {
    public let outputDirectory: URL
    public let mappingBAMURL: URL
    public let mappingBAIURL: URL
    public let retainedBAMURL: URL
    public let retainedBAIURL: URL
    public let reportCSVURL: URL
    public let sampleSummaryCSVURL: URL
    public let statsJSONURL: URL
    public let haplotypeAnalysisURL: URL?
    public let workbookURL: URL
    public let reportProvenanceURL: URL
    public let provenanceURL: URL
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let totalInputReads: Int
    public let retainedUniqueReads: Int
    public let retainedUniquePercentOfTotalReads: Double
    public let assignedUniqueRetainedReads: Int
    public let unassignedUniqueRetainedReads: Int
}

public enum ONTBarcodeDemuxGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case missingDemuxManifest(URL)
    case missingComparisonWorkbook(URL)
    case invalidReference(URL)
    case noFASTQSources(URL)
    case processFailed(tool: String, status: Int32, stderr: String)
    case filterFailed(status: Int32, stderr: String)
    case invalidFilterOutput(String)
    case invalidHaplotypeDefinition(String)
    case ambiguousHaplotypeDefinition(definitionID: String)
    case invalidHaplotypeDefinitionForAssay(definitionID: String, assayID: String)
    case reportFailed(status: Int32, stderr: String)
    case invalidReportOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let url):
            return "Input FASTQ bundle or file does not exist: \(url.path)"
        case .missingBarcodeDefinitions(let url):
            return "Barcode definitions file does not exist: \(url.path)"
        case .missingDemuxManifest(let url):
            return "Demultiplex manifest does not exist: \(url.path)"
        case .missingComparisonWorkbook(let url):
            return "Comparison workbook does not exist: \(url.path)"
        case .invalidReference(let url):
            return "Reference source does not contain a readable FASTA payload: \(url.path)"
        case .noFASTQSources(let url):
            return "No constituent FASTQ files could be resolved from: \(url.path)"
        case .processFailed(let tool, let status, let stderr):
            return "\(tool) failed with status \(status): \(stderr)"
        case .filterFailed(let status, let stderr):
            return "Retained-read demultiplex filter failed with status \(status): \(stderr)"
        case .invalidFilterOutput(let text):
            return "Retained-read demultiplex filter did not return valid JSON: \(text)"
        case .invalidHaplotypeDefinition(let id):
            return "Unknown haplotype definition set: \(id)"
        case .ambiguousHaplotypeDefinition(let definitionID):
            return "Haplotype definition set \(definitionID) exists in more than one assay; specify --haplotype-assay."
        case .invalidHaplotypeDefinitionForAssay(let definitionID, let assayID):
            return "Haplotype definition set \(definitionID) is not available for assay \(assayID)"
        case .reportFailed(let status, let stderr):
            return "ONT barcode genotype workbook report failed with status \(status): \(stderr)"
        case .invalidReportOutput(let text):
            return "ONT barcode genotype workbook report did not return valid JSON: \(text)"
        }
    }
}

public struct ONTBarcodeDemuxGenotypingPipeline: Sendable {
    private let condaManager: CondaManager
    private let referenceImporter: ReferenceBundleImportService

    public init(
        condaManager: CondaManager = .shared,
        referenceImporter: ReferenceBundleImportService = .shared
    ) {
        self.condaManager = condaManager
        self.referenceImporter = referenceImporter
    }

    public func run(
        _ request: ONTBarcodeDemuxGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ONTBarcodeDemuxGenotypingResult {
        let startedAt = Date()
        progressHandler?(0.01, "Validating ONT genotyping inputs.")
        guard FileManager.default.fileExists(atPath: request.inputFASTQURL.path) else {
            throw ONTBarcodeDemuxGenotypingError.missingInput(request.inputFASTQURL)
        }
        guard FileManager.default.fileExists(atPath: request.barcodeDefinitionsURL.path) else {
            throw ONTBarcodeDemuxGenotypingError.missingBarcodeDefinitions(request.barcodeDefinitionsURL)
        }
        if let comparisonWorkbookURL = request.comparisonWorkbookURL,
           !FileManager.default.fileExists(atPath: comparisonWorkbookURL.path) {
            throw ONTBarcodeDemuxGenotypingError.missingComparisonWorkbook(comparisonWorkbookURL)
        }
        _ = try resolveHaplotypeDefinitionSet(for: request)
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        progressHandler?(0.04, "Preparing ONT genotyping output workspace.")
        let supportDirectory = request.outputDirectory
            .appendingPathComponent(".ont-barcode-genotyping", isDirectory: true)
        let scriptURL = supportDirectory.appendingPathComponent("filter-demux-retained-bam.py")
        try Self.writeFilterScript(to: scriptURL)
        let reportScriptURL = supportDirectory.appendingPathComponent("write-retained-demux-workbook.py")
        try Self.writeReportScript(to: reportScriptURL)

        progressHandler?(0.08, "Resolving demultiplex manifest and input snapshots.")
        let demuxManifestURL = try resolveDemuxManifest(for: request)
        guard FileManager.default.fileExists(atPath: demuxManifestURL.path) else {
            throw ONTBarcodeDemuxGenotypingError.missingDemuxManifest(demuxManifestURL)
        }
        let inputSnapshot = try snapshotSmallInputs(
            for: request,
            demuxManifestURL: demuxManifestURL,
            supportDirectory: supportDirectory
        )

        progressHandler?(0.12, "Resolving reference and FASTQ inputs.")
        let reference = try await resolveReference(for: request)
        let inputFASTQURLs = try Self.resolveInputFASTQURLs(for: request.inputFASTQURL)
        guard !inputFASTQURLs.isEmpty else {
            throw ONTBarcodeDemuxGenotypingError.noFASTQSources(request.inputFASTQURL)
        }

        progressHandler?(0.18, "Resolving managed minimap2, samtools, pysam, and openpyxl tools.")
        let minimap2URL = try await condaManager.toolPath(name: "minimap2", environment: "minimap2")
        let samtoolsURL = try await condaManager.toolPath(name: "samtools", environment: "samtools")
        let pythonURL = try await condaManager.toolPath(name: "python", environment: "pysam")
        let reportPythonURL = try await condaManager.toolPath(name: "python", environment: "openpyxl")

        progressHandler?(0.25, "Mapping ONT reads with minimap2.")
        let mapping = try runMapping(
            request: request,
            referenceFASTAURL: reference.referenceFASTAURL,
            inputFASTQURLs: inputFASTQURLs,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL
        )

        progressHandler?(0.58, "Filtering retained full-reference alignments and demultiplexing by barcode.")
        let filter = try await runFilter(
            request: request,
            referenceFASTAURL: reference.referenceFASTAURL,
            barcodeDefinitionsURL: inputSnapshot.barcodeDefinitionsURL,
            demuxManifestURL: inputSnapshot.demuxManifestURL,
            scriptURL: scriptURL,
            pythonURL: pythonURL
        )

        progressHandler?(0.76, "Writing retained-demux genotype summaries.")
        try copyFilterOutput(
            from: request.outputDirectory.appendingPathComponent("\(request.outputName).retained_demux_genotypes.csv"),
            to: request.reportCSVURL
        )
        try copyFilterOutput(
            from: request.outputDirectory.appendingPathComponent("\(request.outputName).retained_demux_samples.csv"),
            to: request.sampleSummaryCSVURL
        )
        try copyFilterOutput(
            from: request.outputDirectory.appendingPathComponent("\(request.outputName).retained_demux_stats.json"),
            to: request.statsJSONURL
        )

        progressHandler?(0.80, "Applying selected haplotype definition.")
        let haplotypeAnalysis = try writeHaplotypeAnalysisIfRequested(
            request: request,
            supportDirectory: supportDirectory,
            generatedAt: Date()
        )

        progressHandler?(0.84, "Writing Excel genotype workbook.")
        let report = try await runReport(
            request: request,
            referenceFASTAURL: reference.referenceFASTAURL,
            barcodeDefinitionsURL: inputSnapshot.barcodeDefinitionsURL,
            comparisonWorkbookURL: inputSnapshot.comparisonWorkbookURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL,
            reportScriptURL: reportScriptURL,
            pythonURL: reportPythonURL
        )

        let completedAt = Date()
        progressHandler?(0.93, "Writing reproducibility provenance and bundle manifest.")
        let provenanceURL = try writeProvenance(
            request: request,
            reference: reference,
            inputFASTQURLs: inputFASTQURLs,
            demuxManifestURL: demuxManifestURL,
            inputSnapshot: inputSnapshot,
            scriptURL: scriptURL,
            reportScriptURL: reportScriptURL,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL,
            pythonURL: pythonURL,
            reportPythonURL: reportPythonURL,
            mapping: mapping,
            filter: filter,
            report: report,
            haplotypeAnalysis: haplotypeAnalysis,
            startedAt: startedAt,
            completedAt: completedAt
        )
        try writeBundleManifest(
            request: request,
            provenanceURL: provenanceURL,
            completedAt: completedAt
        )
        progressHandler?(0.98, "Finalizing ONT genotyping outputs.")

        return ONTBarcodeDemuxGenotypingResult(
            outputDirectory: request.outputDirectory,
            mappingBAMURL: request.mappingBAMURL,
            mappingBAIURL: request.mappingBAIURL,
            retainedBAMURL: request.retainedBAMURL,
            retainedBAIURL: request.retainedBAIURL,
            reportCSVURL: request.reportCSVURL,
            sampleSummaryCSVURL: request.sampleSummaryCSVURL,
            statsJSONURL: request.statsJSONURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL,
            workbookURL: request.workbookURL,
            reportProvenanceURL: request.reportProvenanceURL,
            provenanceURL: provenanceURL,
            referenceFASTAURL: reference.referenceFASTAURL,
            sourceReferenceBundleURL: reference.sourceReferenceBundleURL,
            totalInputReads: filter.stats.totalInputReads,
            retainedUniqueReads: filter.stats.retainedUniqueReads,
            retainedUniquePercentOfTotalReads: filter.stats.retainedUniquePercentOfTotalReads,
            assignedUniqueRetainedReads: filter.stats.assignedUniqueRetainedReads,
            unassignedUniqueRetainedReads: filter.stats.unassignedUniqueRetainedReads
        )
    }

    public static func resolveInputFASTQURLs(for inputURL: URL) throws -> [URL] {
        let standardized = inputURL.standardizedFileURL
        if FASTQBundle.isFASTQFileURL(standardized) {
            return [standardized]
        }
        guard FASTQBundle.isBundleURL(standardized) else {
            if Self.urlIsDirectory(standardized) {
                return Self.resolveRawFASTQDirectoryURLs(for: standardized)
            }
            return FASTQBundle.resolveAllFASTQURLs(for: standardized)?.map(\.standardizedFileURL) ?? []
        }
        if FASTQSourceFileManifest.exists(in: standardized) {
            let manifest = try FASTQSourceFileManifest.load(from: standardized)
            return manifest.files.map { entry in
                let bundleRelativeURL = standardized.appendingPathComponent(entry.filename).standardizedFileURL
                if FileManager.default.fileExists(atPath: bundleRelativeURL.path) {
                    return bundleRelativeURL
                }
                let originalURL = URL(fileURLWithPath: entry.originalPath).standardizedFileURL
                if FileManager.default.fileExists(atPath: originalURL.path) {
                    return originalURL
                }
                return bundleRelativeURL
            }
        }
        return FASTQBundle.resolveAllFASTQURLs(for: standardized)?.map(\.standardizedFileURL) ?? []
    }

    private static func urlIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func resolveRawFASTQDirectoryURLs(for directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("._") {
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if url.pathExtension.lowercased() == FASTQBundle.directoryExtension {
                    enumerator.skipDescendants()
                }
                continue
            }
            if FASTQBundle.isFASTQFileURL(url) {
                urls.append(url.standardizedFileURL)
            }
        }
        return urls.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private struct ReferenceResolution {
        let referenceFASTAURL: URL
        let sourceReferenceBundleURL: URL?
    }

    private struct SmallInputSnapshot {
        let barcodeDefinitionsURL: URL
        let demuxManifestURL: URL
        let comparisonWorkbookURL: URL?
        let stagedInputURLs: [URL]
    }

    private struct MappingStepResult {
        let minimap2Arguments: [String]
        let samtoolsSortArguments: [String]
        let samtoolsIndexArguments: [String]
        let minimap2Stderr: String
        let samtoolsSortStderr: String
        let samtoolsIndexStderr: String
        let wallClockSeconds: TimeInterval
    }

    private struct FilterStepResult {
        let arguments: [String]
        let stdout: String
        let stderr: String
        let wallClockSeconds: TimeInterval
        let stats: RetainedDemuxStats
    }

    private struct ReportStepResult {
        let arguments: [String]
        let stdout: String
        let stderr: String
        let wallClockSeconds: TimeInterval
        let summary: ReportSummary
    }

    private struct RetainedDemuxStats: Decodable {
        let totalInputReads: Int
        let totalAlignments: Int
        let passedAlignments: Int
        let retainedQueryNamesBeforeDemux: Int?
        let retainedUniqueReads: Int
        let retainedUniquePercentOfTotalReads: Double
        let assignedUniqueRetainedReads: Int
        let unassignedUniqueRetainedReads: Int
    }

    private struct ReportSummary: Decodable {
        let outputXLSX: String
        let provenanceJSON: String
        let openpyxlVersion: String
        let sheetNames: [String]
        let auditRows: Int
    }

    private func resolveDemuxManifest(for request: ONTBarcodeDemuxGenotypingRunRequest) throws -> URL {
        if let demuxManifestURL = request.demuxManifestURL {
            return demuxManifestURL
        }
        if FASTQBundle.isBundleURL(request.inputFASTQURL) {
            let candidate = request.inputFASTQURL.appendingPathComponent("demux-manifest.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let sibling = request.inputFASTQURL
            .deletingLastPathComponent()
            .appendingPathComponent("demux-manifest.json")
        return sibling
    }

    private func snapshotSmallInputs(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        demuxManifestURL: URL,
        supportDirectory: URL
    ) throws -> SmallInputSnapshot {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)

        let barcodeSnapshotURL = try copyInputSnapshot(
            sourceURL: request.barcodeDefinitionsURL,
            destinationURL: inputsDirectory.appendingPathComponent(
                "barcode-definitions.\(request.barcodeDefinitionsURL.pathExtension.isEmpty ? "txt" : request.barcodeDefinitionsURL.pathExtension)"
            )
        )
        let demuxManifestSnapshotURL = try copyInputSnapshot(
            sourceURL: demuxManifestURL,
            destinationURL: inputsDirectory.appendingPathComponent("demux-manifest.json")
        )
        let comparisonSnapshotURL = try request.comparisonWorkbookURL.map { comparisonURL in
            try copyInputSnapshot(
                sourceURL: comparisonURL,
                destinationURL: inputsDirectory.appendingPathComponent(
                    "comparison-workbook.\(comparisonURL.pathExtension.isEmpty ? "xlsx" : comparisonURL.pathExtension)"
                )
            )
        }
        return SmallInputSnapshot(
            barcodeDefinitionsURL: barcodeSnapshotURL,
            demuxManifestURL: demuxManifestSnapshotURL,
            comparisonWorkbookURL: comparisonSnapshotURL,
            stagedInputURLs: [barcodeSnapshotURL, demuxManifestSnapshotURL] + (comparisonSnapshotURL.map { [$0] } ?? [])
        )
    }

    private func copyInputSnapshot(sourceURL: URL, destinationURL: URL) throws -> URL {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        if source == destination {
            return destination
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func resolveReference(for request: ONTBarcodeDemuxGenotypingRunRequest) async throws -> ReferenceResolution {
        let sourceURL = request.referenceSourceURL
        if sourceURL.pathExtension.lowercased() == "lungfishref" {
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
                  SequenceInputResolver.inputSequenceFormat(for: sourceURL) == .fasta else {
                throw ONTBarcodeDemuxGenotypingError.invalidReference(sourceURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: sourceURL)
        }

        if let projectURL = request.projectURL,
           ReferenceBundleImportService.isStandaloneReferenceSource(sourceURL),
           !Self.url(sourceURL, isContainedIn: projectURL) {
            let referenceDirectory = projectURL.appendingPathComponent("Reference Sequences", isDirectory: true)
            let importResult = try await referenceImporter.importAsReferenceBundle(
                sourceURL: sourceURL,
                outputDirectory: referenceDirectory,
                preferredBundleName: sourceURL.deletingPathExtension().lastPathComponent
            )
            guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: importResult.bundleURL) else {
                throw ONTBarcodeDemuxGenotypingError.invalidReference(importResult.bundleURL)
            }
            return ReferenceResolution(referenceFASTAURL: fastaURL.standardizedFileURL, sourceReferenceBundleURL: importResult.bundleURL)
        }

        guard let fastaURL = SequenceInputResolver.resolvePrimarySequenceURL(for: sourceURL),
              (SequenceInputResolver.inputSequenceFormat(for: sourceURL) ?? SequenceFormat.from(url: fastaURL)) == .fasta else {
            throw ONTBarcodeDemuxGenotypingError.invalidReference(sourceURL)
        }
        return ReferenceResolution(
            referenceFASTAURL: fastaURL.standardizedFileURL,
            sourceReferenceBundleURL: MappingReferenceStager.enclosingReferenceBundleURL(for: sourceURL)
        )
    }

    private func runMapping(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        referenceFASTAURL: URL,
        inputFASTQURLs: [URL],
        minimap2URL: URL,
        samtoolsURL: URL
    ) throws -> MappingStepResult {
        let minimap2StderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).minimap2.stderr.log")
        let sortStderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).samtools-sort.stderr.log")
        let indexStderrURL = request.outputDirectory.appendingPathComponent("\(request.outputName).samtools-index.stderr.log")
        let readGroup = "@RG\\tID:\(request.outputName)\\tSM:\(request.outputName)\\tLB:\(request.outputName)\\tPL:ONT\\tPU:\(request.outputName)"
        let minimap2Arguments = [
            "-a",
            "-x", "map-ont",
            "--MD",
            "-t", String(request.threads),
            "-R", readGroup,
        ] + request.extraArguments + [referenceFASTAURL.path] + inputFASTQURLs.map(\.path)
        let sortArguments = [
            "sort",
            "-@", String(request.sortThreads),
            "-o", request.mappingBAMURL.path,
            "-",
        ]
        let indexArguments = ["index", request.mappingBAMURL.path]
        let startedAt = Date()

        let pipe = Pipe()
        let minimap2 = Process()
        minimap2.executableURL = minimap2URL
        minimap2.arguments = minimap2Arguments
        minimap2.standardOutput = pipe
        minimap2.standardError = try fileHandleForWriting(to: minimap2StderrURL)

        let sort = Process()
        sort.executableURL = samtoolsURL
        sort.arguments = sortArguments
        sort.standardInput = pipe
        sort.standardError = try fileHandleForWriting(to: sortStderrURL)

        try sort.run()
        try minimap2.run()
        minimap2.waitUntilExit()
        try? (minimap2.standardError as? FileHandle)?.close()
        pipe.fileHandleForWriting.closeFile()
        sort.waitUntilExit()
        try? (sort.standardError as? FileHandle)?.close()

        let minimap2Stderr = (try? String(contentsOf: minimap2StderrURL, encoding: .utf8)) ?? ""
        let sortStderr = (try? String(contentsOf: sortStderrURL, encoding: .utf8)) ?? ""
        guard minimap2.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "minimap2",
                status: minimap2.terminationStatus,
                stderr: minimap2Stderr
            )
        }
        guard sort.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "samtools sort",
                status: sort.terminationStatus,
                stderr: sortStderr
            )
        }

        let index = Process()
        index.executableURL = samtoolsURL
        index.arguments = indexArguments
        index.standardError = try fileHandleForWriting(to: indexStderrURL)
        try index.run()
        index.waitUntilExit()
        try? (index.standardError as? FileHandle)?.close()
        let indexStderr = (try? String(contentsOf: indexStderrURL, encoding: .utf8)) ?? ""
        guard index.terminationStatus == 0 else {
            throw ONTBarcodeDemuxGenotypingError.processFailed(
                tool: "samtools index",
                status: index.terminationStatus,
                stderr: indexStderr
            )
        }

        return MappingStepResult(
            minimap2Arguments: minimap2Arguments,
            samtoolsSortArguments: sortArguments,
            samtoolsIndexArguments: indexArguments,
            minimap2Stderr: minimap2Stderr,
            samtoolsSortStderr: sortStderr,
            samtoolsIndexStderr: indexStderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func runFilter(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        referenceFASTAURL: URL,
        barcodeDefinitionsURL: URL,
        demuxManifestURL: URL,
        scriptURL: URL,
        pythonURL: URL
    ) async throws -> FilterStepResult {
        let arguments = [
            scriptURL.path,
            "--input-bam", request.mappingBAMURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--barcodes", barcodeDefinitionsURL.path,
            "--demux-manifest", demuxManifestURL.path,
            "--output-dir", request.outputDirectory.path,
            "--prefix", request.outputName,
            "--require-both-end-softclips",
            "--max-mismatches", "0",
            "--min-support", String(request.minSupport),
            "--provenance-command", request.argv.map(shellEscape).joined(separator: " "),
        ]
        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: pythonURL.lastPathComponent,
            arguments: arguments,
            environment: "pysam",
            workingDirectory: request.outputDirectory,
            timeout: 86_400
        )
        guard result.exitCode == 0 else {
            throw ONTBarcodeDemuxGenotypingError.filterFailed(status: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8),
              let stats = try? JSONDecoder().decode(RetainedDemuxStats.self, from: data) else {
            throw ONTBarcodeDemuxGenotypingError.invalidFilterOutput(result.stdout)
        }
        return FilterStepResult(
            arguments: arguments,
            stdout: result.stdout,
            stderr: result.stderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt),
            stats: stats
        )
    }

    private func runReport(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        referenceFASTAURL: URL,
        barcodeDefinitionsURL: URL,
        comparisonWorkbookURL: URL?,
        haplotypeAnalysisURL: URL?,
        reportScriptURL: URL,
        pythonURL: URL
    ) async throws -> ReportStepResult {
        var arguments = [
            reportScriptURL.path,
            "--genotypes-csv", request.reportCSVURL.path,
            "--samples-csv", request.sampleSummaryCSVURL.path,
            "--stats-json", request.statsJSONURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--barcode-definitions", barcodeDefinitionsURL.path,
            "--output-xlsx", request.workbookURL.path,
            "--provenance-json", request.reportProvenanceURL.path,
            "--analysis-name", request.analysisName,
            "--run-name", request.outputName,
            "--provenance-command", request.argv.map(shellEscape).joined(separator: " "),
        ]
        if let comparisonWorkbookURL {
            arguments += ["--comparison-workbook", comparisonWorkbookURL.path]
        }
        if let comparisonName = request.comparisonName {
            arguments += ["--comparison-name", comparisonName]
        }
        if let haplotypeAnalysisURL {
            arguments += ["--haplotype-analysis-json", haplotypeAnalysisURL.path]
        }

        let startedAt = Date()
        let result = try await condaManager.runTool(
            name: pythonURL.lastPathComponent,
            arguments: arguments,
            environment: "openpyxl",
            workingDirectory: request.outputDirectory,
            timeout: 3_600
        )
        guard result.exitCode == 0 else {
            throw ONTBarcodeDemuxGenotypingError.reportFailed(status: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8),
              let summary = try? JSONDecoder().decode(ReportSummary.self, from: data) else {
            throw ONTBarcodeDemuxGenotypingError.invalidReportOutput(result.stdout)
        }
        return ReportStepResult(
            arguments: arguments,
            stdout: result.stdout,
            stderr: result.stderr,
            wallClockSeconds: Date().timeIntervalSince(startedAt),
            summary: summary
        )
    }

    private func writeHaplotypeAnalysisIfRequested(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        supportDirectory: URL,
        generatedAt: Date
    ) throws -> GenotypeHaplotypeAnalysis? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        guard let definitionSet = try resolveHaplotypeDefinitionSet(for: request) else {
            throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        let assayID = definitionSet.assayID
        try writeHaplotypeDefinitionSnapshot(definitionSet, supportDirectory: supportDirectory)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: request.outputName,
            analysisName: request.analysisName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            haplotypeDefinitionSetID: definitionSetID,
            haplotypeAssayID: assayID
        )
        let result = try ONTGenotypeResultBundle.loadResult(from: request.outputDirectory, manifest: manifest)
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: result.calls,
            definitionSet: definitionSet,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(analysis)
        try data.write(to: request.haplotypeAnalysisURL, options: .atomic)
        return analysis
    }

    private func resolveHaplotypeDefinitionSet(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        guard let definitionSetID = request.haplotypeDefinitionSetID else {
            return nil
        }
        let registry = haplotypeDefinitionRegistry(for: request)
        if let assayID = request.haplotypeAssayID {
            guard registry.assay(id: assayID) != nil else {
                throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            guard let definitionSet = registry.definitionSet(id: definitionSetID, assayID: assayID) else {
                if registry.definitionSet(id: definitionSetID) == nil {
                    throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
                }
                throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinitionForAssay(
                    definitionID: definitionSetID,
                    assayID: assayID
                )
            }
            return definitionSet
        }

        let matchingSets = registry.definitionSets(id: definitionSetID)
        if matchingSets.count == 1 {
            return matchingSets[0]
        }
        if matchingSets.isEmpty {
            throw ONTBarcodeDemuxGenotypingError.invalidHaplotypeDefinition(definitionSetID)
        }
        throw ONTBarcodeDemuxGenotypingError.ambiguousHaplotypeDefinition(definitionID: definitionSetID)
    }

    private func haplotypeDefinitionRegistry(
        for request: ONTBarcodeDemuxGenotypingRunRequest
    ) -> GenotypeHaplotypeDefinitionRegistry {
        guard let projectURL = request.projectURL else {
            return .builtIn
        }
        return HaplotypeDefinitionStore(projectRoot: projectURL).mergedRegistry()
    }

    private func haplotypeDefinitionSnapshotURL(for request: ONTBarcodeDemuxGenotypingRunRequest) -> URL {
        request.outputDirectory
            .appendingPathComponent(".ont-barcode-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
            .appendingPathComponent("haplotype-definition.json")
    }

    private func writeHaplotypeDefinitionSnapshot(
        _ definitionSet: GenotypeHaplotypeDefinitionSet,
        supportDirectory: URL
    ) throws {
        let inputsDirectory = supportDirectory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
        let url = inputsDirectory.appendingPathComponent("haplotype-definition.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(definitionSet)
        try data.write(to: url, options: .atomic)
    }

    private func copyFilterOutput(from source: URL, to destination: URL) throws {
        guard source != destination else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func writeProvenance(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        reference: ReferenceResolution,
        inputFASTQURLs: [URL],
        demuxManifestURL: URL,
        inputSnapshot: SmallInputSnapshot,
        scriptURL: URL,
        reportScriptURL: URL,
        minimap2URL: URL,
        samtoolsURL: URL,
        pythonURL: URL,
        reportPythonURL: URL,
        mapping: MappingStepResult,
        filter: FilterStepResult,
        report: ReportStepResult,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        startedAt: Date,
        completedAt: Date
    ) throws -> URL {
        let provenanceURL = request.outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json")
        let inputs = inputFASTQURLs
            .map { fileDescriptorDictionary(url: $0, role: "input-fastq") }
        let comparisonInputs = request.comparisonWorkbookURL
            .map { [fileDescriptorDictionary(url: $0, role: "comparison")] } ?? []
        let stagedInputs = inputSnapshot.stagedInputURLs
            .map { fileDescriptorDictionary(url: $0, role: "staged-input") }
        let haplotypeOutputs = haplotypeAnalysis == nil
            ? []
            : [fileDescriptorDictionary(url: request.haplotypeAnalysisURL, role: "analysis")]
        let resolvedHaplotypeDefinitionSet = try? resolveHaplotypeDefinitionSet(for: request)
        let haplotypeDefinitionSnapshotURL = self.haplotypeDefinitionSnapshotURL(for: request)
        let haplotypeDefinitionInputs = haplotypeAnalysis == nil
            ? []
            : [fileDescriptorDictionary(url: haplotypeDefinitionSnapshotURL, role: "haplotype-definition")]
        let haplotypeDefinitionSHA256 = (try? ProvenanceFileHasher.sha256(of: haplotypeDefinitionSnapshotURL)) as Any? ?? NSNull()
        let haplotypeSteps: [[String: Any]] = haplotypeAnalysis.map { analysis in
            [[
                "toolName": "deterministic genotype haplotype assignment",
                "argv": haplotypeAssignmentArgv(for: request, resolvedAssayID: analysis.assayID),
                "definitionSetID": analysis.definitionSetID,
                "definitionSetName": analysis.definitionSetName,
                "assayID": analysis.assayID,
                "speciesName": analysis.speciesName,
                "definitionInput": haplotypeDefinitionSnapshotURL.path,
                "definitionSHA256": haplotypeDefinitionSHA256,
                "output": request.haplotypeAnalysisURL.path,
                "sampleCount": analysis.samples.count,
                "exitStatus": 0,
                "wallTimeSeconds": 0,
            ]]
        } ?? []
        let options: [String: Any] = [
            "inputFASTQ": request.inputFASTQURL.path,
            "reference": request.referenceSourceURL.path,
            "barcodes": request.barcodeDefinitionsURL.path,
            "demuxManifest": demuxManifestURL.path,
            "outputDirectory": request.outputDirectory.path,
            "outputName": request.outputName,
            "analysisName": request.analysisName,
            "comparisonWorkbook": request.comparisonWorkbookURL?.path as Any? ?? NSNull(),
            "comparisonName": request.comparisonName as Any? ?? NSNull(),
            "haplotypeAssayID": resolvedHaplotypeDefinitionSet?.assayID as Any? ?? NSNull(),
            "haplotypeDefinitionSetID": request.haplotypeDefinitionSetID as Any? ?? NSNull(),
            "haplotypeDefinitionSHA256": haplotypeDefinitionSHA256,
            "threads": request.threads,
            "sortThreads": request.sortThreads,
            "minSupport": request.minSupport,
            "mappingPreset": "map-ont",
            "requireBothEndSoftclips": true,
            "requireFullReferenceSpan": true,
            "allowIndels": true,
            "maxMismatches": 0,
            "demuxRetainedReadsOnly": true,
            "extraArguments": request.extraArguments,
        ]
        let resolvedDefaults: [String: Any] = [
            "analysisName": request.outputName,
            "comparisonName": "Illumina-31262",
            "haplotypeAssayID": NSNull(),
            "haplotypeDefinitionSetID": NSNull(),
            "sortThreads": 4,
            "minSupport": 1,
            "mappingPreset": "map-ont",
            "requireBothEndSoftclips": true,
            "requireFullReferenceSpan": true,
            "allowIndels": true,
            "maxMismatches": 0,
            "demuxRetainedReadsOnly": true,
            "extraArguments": [],
        ]
        let runtimeIdentity: [String: Any] = [
            "minimap2": minimap2URL.path,
            "samtools": samtoolsURL.path,
            "python": pythonURL.path,
            "reportPython": reportPythonURL.path,
            "openpyxl": report.summary.openpyxlVersion,
            "condaRoot": condaManager.rootPrefix.path,
        ]
        let provenanceInputs: [[String: Any]] = inputs + [
            fileDescriptorDictionary(url: reference.referenceFASTAURL, role: "reference"),
            fileDescriptorDictionary(url: request.barcodeDefinitionsURL, role: "input"),
            fileDescriptorDictionary(url: demuxManifestURL, role: "input"),
            fileDescriptorDictionary(url: scriptURL, role: "input"),
            fileDescriptorDictionary(url: reportScriptURL, role: "input"),
        ] + comparisonInputs + stagedInputs + haplotypeDefinitionInputs
        let provenanceOutputs: [[String: Any]] = [
            fileDescriptorDictionary(url: request.mappingBAMURL, role: "output"),
            fileDescriptorDictionary(url: request.mappingBAIURL, role: "index"),
            fileDescriptorDictionary(url: request.retainedBAMURL, role: "output"),
            fileDescriptorDictionary(url: request.retainedBAIURL, role: "index"),
            fileDescriptorDictionary(url: request.reportCSVURL, role: "report"),
            fileDescriptorDictionary(url: request.sampleSummaryCSVURL, role: "report"),
            fileDescriptorDictionary(url: request.statsJSONURL, role: "output"),
        ] + haplotypeOutputs + [
            fileDescriptorDictionary(url: request.workbookURL, role: "report"),
            fileDescriptorDictionary(url: request.reportProvenanceURL, role: "provenance"),
        ]
        let primaryOutput = fileDescriptorDictionary(url: request.outputDirectory, role: "output")
        let provenanceFiles = provenanceInputs + provenanceOutputs
        let statistics: [String: Any] = [
            "totalInputReads": filter.stats.totalInputReads,
            "totalAlignments": filter.stats.totalAlignments,
            "passedAlignments": filter.stats.passedAlignments,
            "retainedUniqueReads": filter.stats.retainedUniqueReads,
            "retainedUniquePercentOfTotalReads": filter.stats.retainedUniquePercentOfTotalReads,
            "assignedUniqueRetainedReads": filter.stats.assignedUniqueRetainedReads,
            "unassignedUniqueRetainedReads": filter.stats.unassignedUniqueRetainedReads,
        ]
        let steps: [[String: Any]] = [
            [
                "toolName": "minimap2",
                "argv": [minimap2URL.path] + mapping.minimap2Arguments,
                "exitStatus": 0,
                "wallClockSeconds": mapping.wallClockSeconds,
                "wallTimeSeconds": mapping.wallClockSeconds,
                "stderr": mapping.minimap2Stderr,
            ],
            [
                "toolName": "samtools sort",
                "argv": [samtoolsURL.path] + mapping.samtoolsSortArguments,
                "exitStatus": 0,
                "wallClockSeconds": mapping.wallClockSeconds,
                "wallTimeSeconds": mapping.wallClockSeconds,
                "stderr": mapping.samtoolsSortStderr,
            ],
            [
                "toolName": "samtools index",
                "argv": [samtoolsURL.path] + mapping.samtoolsIndexArguments,
                "exitStatus": 0,
                "wallTimeSeconds": mapping.wallClockSeconds,
                "stderr": mapping.samtoolsIndexStderr,
            ],
            [
                "toolName": "pysam retained-read demux filter",
                "argv": [pythonURL.path] + filter.arguments,
                "exitStatus": 0,
                "wallClockSeconds": filter.wallClockSeconds,
                "wallTimeSeconds": filter.wallClockSeconds,
                "stderr": filter.stderr,
            ],
        ] + haplotypeSteps + [
            [
                "toolName": "openpyxl ONT genotype workbook report",
                "argv": [reportPythonURL.path] + report.arguments,
                "exitStatus": 0,
                "wallClockSeconds": report.wallClockSeconds,
                "wallTimeSeconds": report.wallClockSeconds,
                "stderr": report.stderr,
                "summary": [
                    "outputXLSX": report.summary.outputXLSX,
                    "provenanceJSON": report.summary.provenanceJSON,
                    "sheetNames": report.summary.sheetNames,
                    "auditRows": report.summary.auditRows,
                ],
            ],
        ]
        let payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: completedAt),
            "toolName": "lungfish fastq ont-barcode-genotype",
            "toolVersion": WorkflowRun.currentAppVersion,
            "workflowName": "ONT Barcode Demux Genotyping",
            "workflowVersion": "1",
            "argv": request.argv,
            "durableReplayArgv": request.argv,
            "reproducibleCommand": request.argv.map(shellEscape).joined(separator: " "),
            "options": options,
            "resolvedDefaults": resolvedDefaults,
            "runtimeIdentity": runtimeIdentity,
            "managedTools": managedToolDescriptors(ids: ["minimap2", "samtools", "pysam", "openpyxl"]),
            "inputs": provenanceInputs,
            "files": provenanceFiles,
            "stagedInputs": [
                "barcodeDefinitions": inputSnapshot.barcodeDefinitionsURL.path,
                "demuxManifest": inputSnapshot.demuxManifestURL.path,
                "comparisonWorkbook": inputSnapshot.comparisonWorkbookURL?.path as Any? ?? NSNull(),
            ],
            "output": primaryOutput,
            "outputs": provenanceOutputs,
            "inputFileCount": inputFASTQURLs.count,
            "sourceReferenceBundle": reference.sourceReferenceBundleURL?.path ?? NSNull(),
            "statistics": statistics,
            "steps": steps,
            "exitStatus": 0,
            "wallClockSeconds": completedAt.timeIntervalSince(startedAt),
            "wallTimeSeconds": completedAt.timeIntervalSince(startedAt),
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "completedAt": ISO8601DateFormatter().string(from: completedAt),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: provenanceURL, options: .atomic)

        let canonicalEnvelope = try canonicalProvenanceEnvelope(
            request: request,
            reference: reference,
            inputFASTQURLs: inputFASTQURLs,
            demuxManifestURL: demuxManifestURL,
            inputSnapshot: inputSnapshot,
            scriptURL: scriptURL,
            reportScriptURL: reportScriptURL,
            minimap2URL: minimap2URL,
            samtoolsURL: samtoolsURL,
            pythonURL: pythonURL,
            reportPythonURL: reportPythonURL,
            mapping: mapping,
            filter: filter,
            report: report,
            haplotypeAnalysis: haplotypeAnalysis,
            legacyProvenanceURL: provenanceURL,
            options: options,
            resolvedDefaults: resolvedDefaults,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return try ProvenanceWriter().write(canonicalEnvelope, to: request.outputDirectory)
    }

    private func canonicalProvenanceEnvelope(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        reference: ReferenceResolution,
        inputFASTQURLs: [URL],
        demuxManifestURL: URL,
        inputSnapshot: SmallInputSnapshot,
        scriptURL: URL,
        reportScriptURL: URL,
        minimap2URL: URL,
        samtoolsURL: URL,
        pythonURL: URL,
        reportPythonURL: URL,
        mapping: MappingStepResult,
        filter: FilterStepResult,
        report: ReportStepResult,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        legacyProvenanceURL: URL,
        options: [String: Any],
        resolvedDefaults: [String: Any],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let fastqInputs = try inputFASTQURLs.map { try canonicalFileDescriptor(url: $0, role: .input) }
        let referenceInput = try canonicalFileDescriptor(url: reference.referenceFASTAURL, role: .reference)
        let barcodeInput = try canonicalFileDescriptor(url: request.barcodeDefinitionsURL, role: .input)
        let demuxInput = try canonicalFileDescriptor(url: demuxManifestURL, role: .input)
        let filterScriptInput = try canonicalFileDescriptor(url: scriptURL, role: .input)
        let reportScriptInput = try canonicalFileDescriptor(url: reportScriptURL, role: .input)
        let comparisonInputs = try request.comparisonWorkbookURL
            .map { [try canonicalFileDescriptor(url: $0, role: .input)] } ?? []
        let stagedInputs = try inputSnapshot.stagedInputURLs
            .map { try canonicalFileDescriptor(url: $0, role: .input) }
        let haplotypeDefinitionInput = try haplotypeAnalysis.map { _ in
            try canonicalFileDescriptor(url: haplotypeDefinitionSnapshotURL(for: request), role: .input)
        }
        let canonicalInputs = deduplicated(
            fastqInputs
                + [referenceInput, barcodeInput, demuxInput, filterScriptInput, reportScriptInput]
                + comparisonInputs
                + stagedInputs
                + (haplotypeDefinitionInput.map { [$0] } ?? [])
        )

        let mappingBAM = try canonicalFileDescriptor(url: request.mappingBAMURL, role: .output)
        let mappingBAI = try canonicalFileDescriptor(url: request.mappingBAIURL, role: .index)
        let retainedBAM = try canonicalFileDescriptor(url: request.retainedBAMURL, role: .output)
        let retainedBAI = try canonicalFileDescriptor(url: request.retainedBAIURL, role: .index)
        let genotypeCSV = try canonicalFileDescriptor(url: request.reportCSVURL, role: .report)
        let sampleCSV = try canonicalFileDescriptor(url: request.sampleSummaryCSVURL, role: .report)
        let statsJSON = try canonicalFileDescriptor(url: request.statsJSONURL, role: .output)
        let haplotypeOutput = try haplotypeAnalysis.map { _ in
            try canonicalFileDescriptor(url: request.haplotypeAnalysisURL, role: .report)
        }
        let workbook = try canonicalFileDescriptor(url: request.workbookURL, role: .report)
        let reportProvenance = try canonicalFileDescriptor(url: request.reportProvenanceURL, role: .log)
        let legacyProvenance = try canonicalFileDescriptor(url: legacyProvenanceURL, role: .log)
        let canonicalOutputs = deduplicated(
            [
                mappingBAM,
                mappingBAI,
                retainedBAM,
                retainedBAI,
                genotypeCSV,
                sampleCSV,
                statsJSON,
            ]
                + (haplotypeOutput.map { [$0] } ?? [])
                + [workbook, reportProvenance, legacyProvenance]
        )
        let outputDirectory = ProvenanceFileDescriptor(
            path: request.outputDirectory.standardizedFileURL.path,
            role: .output
        )

        var canonicalSteps = [
            ProvenanceStep(
                toolName: "minimap2",
                toolVersion: "unknown",
                argv: [minimap2URL.path] + mapping.minimap2Arguments,
                inputs: fastqInputs + [referenceInput],
                outputs: [mappingBAM],
                exitStatus: 0,
                wallTimeSeconds: mapping.wallClockSeconds,
                stderr: mapping.minimap2Stderr
            ),
            ProvenanceStep(
                toolName: "samtools sort",
                toolVersion: "unknown",
                argv: [samtoolsURL.path] + mapping.samtoolsSortArguments,
                inputs: fastqInputs + [referenceInput],
                outputs: [mappingBAM],
                exitStatus: 0,
                wallTimeSeconds: mapping.wallClockSeconds,
                stderr: mapping.samtoolsSortStderr
            ),
            ProvenanceStep(
                toolName: "samtools index",
                toolVersion: "unknown",
                argv: [samtoolsURL.path] + mapping.samtoolsIndexArguments,
                inputs: [mappingBAM],
                outputs: [mappingBAI],
                exitStatus: 0,
                wallTimeSeconds: mapping.wallClockSeconds,
                stderr: mapping.samtoolsIndexStderr
            ),
            ProvenanceStep(
                toolName: "pysam retained-read demux filter",
                toolVersion: "unknown",
                argv: [pythonURL.path] + filter.arguments,
                inputs: [mappingBAM, barcodeInput, demuxInput, filterScriptInput],
                outputs: [retainedBAM, retainedBAI, genotypeCSV, sampleCSV, statsJSON, legacyProvenance],
                exitStatus: 0,
                wallTimeSeconds: filter.wallClockSeconds,
                stderr: filter.stderr
            ),
        ]
        if let haplotypeOutput {
            canonicalSteps.append(
                ProvenanceStep(
                    toolName: "deterministic genotype haplotype assignment",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: haplotypeAssignmentArgv(for: request, resolvedAssayID: haplotypeAnalysis?.assayID),
                    inputs: [genotypeCSV] + (haplotypeDefinitionInput.map { [$0] } ?? []),
                    outputs: [haplotypeOutput],
                    exitStatus: 0,
                    wallTimeSeconds: 0
                )
            )
        }
        canonicalSteps.append(
            ProvenanceStep(
                toolName: "openpyxl ONT genotype workbook report",
                toolVersion: report.summary.openpyxlVersion,
                argv: [reportPythonURL.path] + report.arguments,
                inputs: [genotypeCSV, sampleCSV, statsJSON, reportScriptInput]
                    + comparisonInputs
                    + (haplotypeOutput.map { [$0] } ?? []),
                outputs: [workbook, reportProvenance],
                exitStatus: 0,
                wallTimeSeconds: report.wallClockSeconds,
                stderr: report.stderr
            )
        )

        return ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: "ONT Barcode Demux Genotyping",
            workflowVersion: "1",
            toolName: "lungfish fastq ont-barcode-genotype",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: "lungfish fastq ont-barcode-genotype",
                version: WorkflowRun.currentAppVersion,
                kind: "cli"
            ),
            argv: request.argv,
            durableReplayArgv: request.argv,
            reproducibleCommand: request.argv.map(shellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: parameterValues(from: options),
                resolvedDefaults: parameterValues(from: resolvedDefaults)
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: WorkflowRun.currentAppVersion,
                executablePath: CommandLine.arguments.first ?? ProvenanceRuntimeIdentity.currentExecutablePath,
                operatingSystemVersion: WorkflowRun.currentHostOS,
                user: NSUserName(),
                condaEnvironment: "lungfish-managed-tools",
                condaPrefix: condaManager.rootPrefix.path
            ),
            files: deduplicated(canonicalInputs + canonicalOutputs),
            output: outputDirectory,
            outputs: [outputDirectory] + canonicalOutputs,
            steps: canonicalSteps,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
    }

    private func writeBundleManifest(
        request: ONTBarcodeDemuxGenotypingRunRequest,
        provenanceURL: URL,
        completedAt: Date
    ) throws {
        let resolvedHaplotypeDefinitionSet = try resolveHaplotypeDefinitionSet(for: request)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: request.outputName,
            analysisName: request.analysisName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: provenanceURL),
            haplotypeAnalysisPath: request.haplotypeDefinitionSetID == nil
                ? nil
                : relativePath(from: request.outputDirectory, to: request.haplotypeAnalysisURL),
            haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
            haplotypeAssayID: resolvedHaplotypeDefinitionSet?.assayID,
            createdAt: ISO8601DateFormatter().string(from: completedAt)
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: request.outputDirectory)

        if let projectURL = request.projectURL,
           request.outputDirectory.standardizedFileURL.path.hasPrefix(projectURL.standardizedFileURL.path) {
            try? AnalysesFolder.writeAnalysisMetadata(
                AnalysesFolder.AnalysisMetadata(tool: "ont-genotyping", isBatch: false, created: completedAt),
                to: request.outputDirectory
            )
        }
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }

    private func haplotypeAssignmentArgv(
        for request: ONTBarcodeDemuxGenotypingRunRequest,
        resolvedAssayID: String? = nil
    ) -> [String] {
        guard let definitionSetID = request.haplotypeDefinitionSetID else { return [] }
        var argv: [String] = []
        if let assayID = request.haplotypeAssayID ?? resolvedAssayID {
            argv += ["--haplotype-assay", assayID]
        }
        argv += ["--haplotype-definition", definitionSetID]
        return argv
    }

    private func canonicalFileDescriptor(url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        try ProvenanceFileDescriptor.file(url: url.standardizedFileURL, role: role)
    }

    private func parameterValues(from values: [String: Any]) -> [String: ParameterValue] {
        values.mapValues(parameterValue(from:))
    }

    private func parameterValue(from value: Any) -> ParameterValue {
        if value is NSNull {
            return .null
        }
        if let boolValue = value as? Bool {
            return .boolean(boolValue)
        }
        if let intValue = value as? Int {
            return .integer(intValue)
        }
        if let doubleValue = value as? Double {
            return .number(doubleValue)
        }
        if let numberValue = value as? NSNumber {
            let doubleValue = numberValue.doubleValue
            if doubleValue.rounded() == doubleValue {
                return .integer(numberValue.intValue)
            }
            return .number(doubleValue)
        }
        if let stringValue = value as? String {
            return .string(stringValue)
        }
        if let arrayValue = value as? [Any] {
            return .array(arrayValue.map(parameterValue(from:)))
        }
        if let dictionaryValue = value as? [String: Any] {
            return .dictionary(parameterValues(from: dictionaryValue))
        }
        return .string(String(describing: value))
    }

    private func deduplicated(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    private func fileDescriptorDictionary(url: URL, role: String) -> [String: Any] {
        var values: [String: Any] = [
            "path": url.path,
            "role": role,
        ]
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            values["exists"] = false
            return values
        }
        values["exists"] = true
        if let size = attributes[.size] as? NSNumber {
            values["sizeBytes"] = size.int64Value
        }
        if let digest = try? ProvenanceFileHasher.sha256(of: url) {
            values["sha256"] = digest
        }
        return values
    }

    private func managedToolDescriptors(ids: [String]) -> [[String: Any]] {
        let lock = try? ManagedToolLock.loadFromBundle()
        return ids.compactMap { id in
            if let tool = lock?.tool(named: id) {
                return [
                    "id": tool.id,
                    "environment": tool.environment,
                    "packageSpec": tool.packageSpec,
                    "executables": tool.executables,
                    "version": tool.version as Any? ?? NSNull(),
                    "license": tool.license as Any? ?? NSNull(),
                    "sourceUrl": tool.sourceUrl as Any? ?? NSNull(),
                ]
            }
            if id == "minimap2" {
                return [
                    "id": "minimap2",
                    "environment": "minimap2",
                    "packageSpec": "bioconda::minimap2=2.30",
                    "executables": ["minimap2"],
                    "version": "2.30",
                    "license": "MIT",
                    "sourceUrl": "https://github.com/lh3/minimap2",
                ]
            }
            return nil
        }
    }

    private func fileHandleForWriting(to url: URL) throws -> FileHandle {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private static func url(_ child: URL, isContainedIn parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(prefix)
    }

    public static func writeFilterScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try filterScript.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeReportScript(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try reportScript.write(to: url, atomically: true, encoding: .utf8)
    }
}

private let filterScript = #"""
#!/usr/bin/env python3
import argparse
import csv
import gzip
import hashlib
import json
import os
import platform
import re
import sys
import time
import warnings
from collections import Counter, defaultdict
from datetime import datetime, timezone

import pysam


def parse_args():
    parser = argparse.ArgumentParser(description="Filter exact+indel/no-mismatch full-reference alignments and demultiplex retained BAM records by Fluidigm barcodes.")
    parser.add_argument("--input-bam", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--barcodes", required=True)
    parser.add_argument("--demux-manifest", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--prefix", default="barcode08")
    parser.add_argument("--require-both-end-softclips", action="store_true")
    parser.add_argument("--max-mismatches", type=int, default=0)
    parser.add_argument("--min-support", type=int, default=1)
    parser.add_argument("--provenance-command", default=None)
    return parser.parse_args()


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, role):
    try:
        stat = os.stat(path)
    except OSError:
        return {"path": path, "role": role, "exists": False}
    return {"path": path, "role": role, "exists": True, "sizeBytes": stat.st_size, "sha256": sha256(path)}


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def load_reference_lengths(path):
    lengths = {}
    name = None
    length = 0
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith(">"):
                if name is not None:
                    lengths[name] = length
                name = line[1:].split()[0]
                length = 0
            else:
                length += len(line)
    if name is not None:
        lengths[name] = length
    return lengths


def load_barcodes(path):
    entries = []
    with open(path, newline="") as handle:
        sample = handle.read(2048)
        handle.seek(0)
        delimiter = "\t" if "\t" in sample and sample.count("\t") >= sample.count(",") else ","
        reader = csv.reader(handle, delimiter=delimiter)
        for row in reader:
            if not row or len(row) < 2:
                continue
            first = row[0].strip()
            second = row[1].strip()
            if not first or not second:
                continue
            if first.lower() in {"sample", "sample_id", "id", "barcodeid"}:
                continue
            entries.append({"sample": first, "barcode": second.upper().replace("U", "T")})
    if not entries:
        raise ValueError(f"No barcodes found in {path}")
    return entries


def load_demux_manifest(path):
    with open(path) as handle:
        payload = json.load(handle)
    sample_totals = {}
    for item in payload.get("barcodes", []):
        sample = item.get("barcodeID")
        if sample:
            sample_totals[sample] = item.get("readCount")
    return {"inputReadCount": payload.get("inputReadCount"), "sampleTotals": sample_totals}


def reverse_complement(sequence):
    table = str.maketrans("ACGTNacgtn", "TGCANtgcan")
    return sequence.translate(table)[::-1].upper()


def barcode_regex(entries):
    pattern_to_sample = {}
    ordered_patterns = []
    for entry in entries:
        for pattern in (entry["barcode"], reverse_complement(entry["barcode"])):
            if pattern not in pattern_to_sample:
                pattern_to_sample[pattern] = entry
                ordered_patterns.append(pattern)
    return re.compile("|".join(re.escape(pattern) for pattern in ordered_patterns)), pattern_to_sample


def assign_barcode(sequence, regex, pattern_to_sample):
    if not sequence:
        return None
    match = regex.search(sequence.upper().replace("U", "T"))
    if match is None:
        return None
    entry = pattern_to_sample[match.group(0)]
    return entry["sample"], entry["barcode"], match.start()


def has_both_terminal_softclips(read):
    cigar = [item for item in (read.cigartuples or []) if item[0] != 5]
    return len(cigar) >= 3 and cigar[0][0] == 4 and cigar[-1][0] == 4


def reference_span_is_full(read, reference_lengths):
    ref_length = reference_lengths.get(read.reference_name)
    return ref_length is not None and read.reference_start == 0 and read.reference_end == ref_length


def md_mismatch_count(md):
    mismatches = 0
    i = 0
    while i < len(md):
        char = md[i]
        if char.isdigit():
            i += 1
            while i < len(md) and md[i].isdigit():
                i += 1
            continue
        if char == "^":
            i += 1
            while i < len(md) and md[i].isalpha():
                i += 1
            continue
        if char.isalpha():
            mismatches += 1
        i += 1
    return mismatches


def alignment_mismatch_count(read):
    try:
        return md_mismatch_count(read.get_tag("MD"))
    except KeyError:
        return None


def passes_filter(read, reference_lengths, args, counters):
    if read.is_unmapped:
        counters["unmapped"] += 1
        return False
    if not reference_span_is_full(read, reference_lengths):
        counters["not_full_reference_span"] += 1
        return False
    if args.require_both_end_softclips and not has_both_terminal_softclips(read):
        counters["missing_terminal_softclips"] += 1
        return False
    mismatches = alignment_mismatch_count(read)
    if mismatches is None:
        counters["missing_md_tag"] += 1
        return False
    if mismatches > args.max_mismatches:
        counters["too_many_mismatches"] += 1
        return False
    counters["passed"] += 1
    return True


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main():
    args = parse_args()
    start_time = time.time()
    started_at = utc_now()
    os.makedirs(args.output_dir, exist_ok=True)
    reference_lengths = load_reference_lengths(args.reference_fasta)
    barcode_entries = load_barcodes(args.barcodes)
    manifest = load_demux_manifest(args.demux_manifest)
    regex, pattern_to_sample = barcode_regex(barcode_entries)
    total_input_reads = manifest["inputReadCount"]
    output_bam = os.path.join(args.output_dir, f"{args.prefix}.retained.demuxed.bam")
    output_bai = output_bam + ".bai"
    summary_csv = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_genotypes.csv")
    sample_csv = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_samples.csv")
    stats_json = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_stats.json")
    provenance_json = os.path.join(args.output_dir, f"{args.prefix}.retained_demux_provenance.json")

    total_alignments = 0
    pass_counters = Counter()
    retained_query_names = set()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        for read in source.fetch(until_eof=True):
            total_alignments += 1
            if passes_filter(read, reference_lengths, args, pass_counters):
                retained_query_names.add(read.query_name)

    barcode_cache = {}
    barcode_cache_counts = Counter()
    sequence_records_seen = 0
    retained_sequence_records_seen = 0
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        for read in source.fetch(until_eof=True):
            sequence = read.query_sequence
            if not sequence:
                continue
            sequence_records_seen += 1
            if read.query_name not in retained_query_names:
                continue
            retained_sequence_records_seen += 1
            if read.query_name in barcode_cache:
                continue
            assignment = assign_barcode(sequence, regex, pattern_to_sample)
            if assignment is not None:
                sample, barcode, start = assignment
                barcode_cache[read.query_name] = (sample, barcode, start)
                barcode_cache_counts[sample] += 1

    genotype_alignment_counts = Counter()
    genotype_unique_reads = defaultdict(set)
    sample_alignment_counts = Counter()
    sample_unique_reads = defaultdict(set)
    retained_unique_reads = set()
    unassigned_unique_reads = set()
    write_filter_counters = Counter()
    with pysam.AlignmentFile(args.input_bam, "rb") as source:
        header = source.header.to_dict()
        comments = header.get("CO", [])
        comments.append("Filtered by lungfish fastq ont-barcode-genotype: full-reference MD-tag mismatches <= max-mismatches; indels allowed; barcode scanning limited to retained query names; Fluidigm sample in LF tag.")
        header["CO"] = comments
        with pysam.AlignmentFile(output_bam, "wb", header=header) as dest:
            for read in source.fetch(until_eof=True):
                if not passes_filter(read, reference_lengths, args, write_filter_counters):
                    continue
                assignment = barcode_cache.get(read.query_name)
                if assignment is None:
                    sample = "unassigned"
                    barcode = ""
                    unassigned_unique_reads.add(read.query_name)
                else:
                    sample, barcode, _ = assignment
                    read.set_tag("LF", sample, value_type="Z")
                    read.set_tag("BC", barcode, value_type="Z")
                    sample_unique_reads[sample].add(read.query_name)
                retained_unique_reads.add(read.query_name)
                key = (sample, read.reference_name)
                genotype_alignment_counts[key] += 1
                genotype_unique_reads[key].add(read.query_name)
                sample_alignment_counts[sample] += 1
                dest.write(read)
    pysam.index(output_bam)

    retained_unique_count = len(retained_unique_reads)
    assigned_unique_count = sum(len(values) for sample, values in sample_unique_reads.items() if sample != "unassigned")
    unassigned_unique_count = len(unassigned_unique_reads)
    retained_percent = (retained_unique_count / total_input_reads * 100.0) if total_input_reads else None

    genotype_rows = []
    for (sample, genotype), count in sorted(genotype_alignment_counts.items(), key=lambda item: (item[0][0], -item[1], item[0][1])):
        if count < args.min_support:
            continue
        sample_total = manifest["sampleTotals"].get(sample)
        sample_unique_count = len(sample_unique_reads.get(sample, set())) if sample != "unassigned" else unassigned_unique_count
        genotype_rows.append({
            "sample": sample,
            "genotype": genotype,
            "passed_alignments": count,
            "passed_unique_reads": len(genotype_unique_reads[(sample, genotype)]),
            "sample_total_reads": sample_total if sample_total is not None else "",
            "sample_unique_retained_reads": sample_unique_count,
            "sample_unique_retained_percent": f"{(sample_unique_count / sample_total * 100.0):.6f}" if sample_total else "",
            "overall_input_reads": total_input_reads,
            "overall_unique_retained_reads": retained_unique_count,
            "overall_unique_retained_percent": f"{retained_percent:.6f}" if retained_percent is not None else "",
        })
    write_csv(summary_csv, genotype_rows, ["sample", "genotype", "passed_alignments", "passed_unique_reads", "sample_total_reads", "sample_unique_retained_reads", "sample_unique_retained_percent", "overall_input_reads", "overall_unique_retained_reads", "overall_unique_retained_percent"])

    sample_rows = []
    all_samples = sorted(set(sample_alignment_counts) | set(manifest["sampleTotals"]))
    for sample in all_samples:
        sample_total = manifest["sampleTotals"].get(sample)
        unique_count = len(sample_unique_reads.get(sample, set())) if sample != "unassigned" else unassigned_unique_count
        sample_rows.append({
            "sample": sample,
            "passed_alignments": sample_alignment_counts.get(sample, 0),
            "passed_unique_reads": unique_count,
            "sample_total_reads": sample_total if sample_total is not None else "",
            "sample_unique_retained_percent": f"{(unique_count / sample_total * 100.0):.6f}" if sample_total else "",
            "overall_input_reads": total_input_reads,
            "overall_unique_retained_percent": f"{retained_percent:.6f}" if retained_percent is not None else "",
        })
    write_csv(sample_csv, sample_rows, ["sample", "passed_alignments", "passed_unique_reads", "sample_total_reads", "sample_unique_retained_percent", "overall_input_reads", "overall_unique_retained_percent"])

    completed_at = utc_now()
    stats = {
        "tool": "lungfish fastq ont-barcode-genotype retained-read filter",
        "version": "1",
        "startedAt": started_at,
        "completedAt": completed_at,
        "wallClockSeconds": time.time() - start_time,
        "inputBAM": args.input_bam,
        "referenceFasta": args.reference_fasta,
        "barcodes": args.barcodes,
        "demuxManifest": args.demux_manifest,
        "outputBAM": output_bam,
        "outputBAI": output_bai,
        "summaryCSV": summary_csv,
        "sampleCSV": sample_csv,
        "totalInputReads": total_input_reads,
        "totalAlignments": total_alignments,
        "sequenceRecordsSeen": sequence_records_seen,
        "retainedSequenceRecordsSeen": retained_sequence_records_seen,
        "retainedQueryNamesBeforeDemux": len(retained_query_names),
        "barcodeCacheReadCount": len(barcode_cache),
        "barcodeCacheCounts": dict(barcode_cache_counts),
        "passCounters": dict(pass_counters),
        "writeFilterCounters": dict(write_filter_counters),
        "passedAlignments": pass_counters["passed"],
        "retainedUniqueReads": retained_unique_count,
        "retainedUniquePercentOfTotalReads": retained_percent,
        "assignedUniqueRetainedReads": assigned_unique_count,
        "unassignedUniqueRetainedReads": unassigned_unique_count,
        "requireBothEndSoftclips": args.require_both_end_softclips,
        "requireFullReferenceSpan": True,
        "allowIndels": True,
        "maxMismatches": args.max_mismatches,
        "demuxRetainedReadsOnly": True,
        "minSupport": args.min_support,
    }
    with open(stats_json, "w") as handle:
        json.dump(stats, handle, indent=2, sort_keys=True)
        handle.write("\n")

    provenance = {
        "toolName": "lungfish fastq ont-barcode-genotype retained-read filter",
        "toolVersion": "1",
        "argv": sys.argv,
        "reproducibleCommand": args.provenance_command or " ".join(sys.argv),
        "options": vars(args),
        "resolvedDefaults": {"maxMismatches": args.max_mismatches, "requireBothEndSoftclips": args.require_both_end_softclips, "minSupport": args.min_support, "demuxRetainedReadsOnly": True},
        "runtimeIdentity": {"python": sys.version, "platform": platform.platform(), "pysam": pysam.__version__, "executable": sys.executable},
        "inputs": [file_record(args.input_bam, "input"), file_record(args.reference_fasta, "input"), file_record(args.barcodes, "input"), file_record(args.demux_manifest, "input")],
        "outputs": [file_record(output_bam, "output"), file_record(output_bai, "output"), file_record(summary_csv, "output"), file_record(sample_csv, "output"), file_record(stats_json, "output")],
        "exitStatus": 0,
        "wallClockSeconds": stats["wallClockSeconds"],
        "stderr": "",
        "startedAt": started_at,
        "completedAt": completed_at,
    }
    with open(provenance_json, "w") as handle:
        json.dump(provenance, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps(stats, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
"""#

private let reportScript = #"""
#!/usr/bin/env python3
import argparse
import csv
import gzip
import hashlib
import json
import os
import platform
import re
import sys
import time
import warnings
from collections import defaultdict
from copy import copy, deepcopy
from datetime import datetime, timezone

import openpyxl
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


GENE_PREFIXES = (
    "DQB1",
    "DQA1",
    "DPB1",
    "DPA1",
    "DRB1",
    "DRB",
    "B11L",
    "B17",
    "B20",
    "A1",
    "A2",
    "A3",
    "A4",
    "AG",
    "B",
    "E",
    "F",
    "G",
    "I",
)


def parse_args():
    parser = argparse.ArgumentParser(description="Write ONT retained-demux genotype CSVs to an Excel workbook.")
    parser.add_argument("--genotypes-csv", required=True)
    parser.add_argument("--samples-csv", required=True)
    parser.add_argument("--stats-json", required=True)
    parser.add_argument("--reference-fasta", required=True)
    parser.add_argument("--barcode-definitions", required=True)
    parser.add_argument("--output-xlsx", required=True)
    parser.add_argument("--provenance-json", required=True)
    parser.add_argument("--analysis-name")
    parser.add_argument("--run-name", default="ont-barcode-genotyping")
    parser.add_argument("--comparison-workbook")
    parser.add_argument("--comparison-name", default="Illumina-31262")
    parser.add_argument("--haplotype-analysis-json")
    parser.add_argument("--provenance-command")
    args = parser.parse_args()
    if not args.analysis_name:
        args.analysis_name = args.run_name
    return args


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, role):
    try:
        stat = os.stat(path)
    except OSError:
        return {"path": path, "role": role, "exists": False}
    return {"path": path, "role": role, "exists": True, "sizeBytes": stat.st_size, "sha256": sha256(path)}


def read_csv(path):
    with open(path, newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        return reader.fieldnames or [], rows


def as_number(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        number = float(text)
    except ValueError:
        return None
    if number.is_integer():
        return int(number)
    return number


def display_value(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return value
    text = str(value).strip()
    if text == "":
        return None
    number = as_number(text)
    return number if number is not None else text


def load_genotype_counts(rows):
    counts = defaultdict(dict)
    for row in rows:
        sample = row.get("sample", "").strip()
        genotype = row.get("genotype", "").strip()
        if not sample or not genotype:
            continue
        count = as_number(row.get("passed_alignments"))
        if count is None:
            count = 0
        counts[sample][genotype] = counts[sample].get(genotype, 0) + int(count)
    return counts


def load_sample_stats(rows):
    stats = {}
    for row in rows:
        sample = row.get("sample", "").strip()
        if sample:
            stats[sample] = row
    return stats


def has_positive_retained_reads(row):
    for key in ("passed_alignments", "passed_unique_reads", "sample_unique_retained_reads"):
        value = as_number(row.get(key))
        if value is not None and value > 0:
            return True
    return False


def report_sample_names(sample_rows, genotype_counts):
    names = []
    seen = set()

    for row in sample_rows:
        sample = row.get("sample", "").strip()
        if not is_assigned_sample_name(sample) or sample in seen:
            continue
        genotype_total = sum(int(count) for count in genotype_counts.get(sample, {}).values())
        if has_positive_retained_reads(row) or genotype_total > 0:
            names.append(sample)
            seen.add(sample)

    for sample, counts in genotype_counts.items():
        if not is_assigned_sample_name(sample) or sample in seen:
            continue
        if sum(int(count) for count in counts.values()) > 0:
            names.append(sample)
            seen.add(sample)

    return names


def rows_for_samples(rows, samples):
    sample_set = set(samples)
    return [row for row in rows if row.get("sample", "").strip() in sample_set]


def is_assigned_sample_name(sample):
    text = str(sample or "").strip()
    return bool(text) and text.lower() != "unassigned"


def assigned_sample_rows(rows):
    return [row for row in rows if is_assigned_sample_name(row.get("sample"))]


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def reference_names(path):
    names = []
    with open_text(path) as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line.startswith(">"):
                names.append(line[1:].split()[0])
    return names


def clean_expected_part(part):
    part = re.sub(r"^\d+_", "", part)
    for prefix in GENE_PREFIXES:
        marker = f"_{prefix}_"
        if marker in part:
            part = part.split(marker, 1)[1]
            part = f"{prefix}_{part}"
            break
        if part.startswith(f"{prefix}_"):
            break
    else:
        part = re.sub(r"^M[0-9A-Za-z]+_", "", part)
    part = re.sub(r"_\d+bp$", "", part)
    return part


def tokens_for_expected(label):
    if label is None:
        return []
    tokens = []
    for raw_part in str(label).split(":"):
        token = clean_expected_part(raw_part.strip())
        if token:
            tokens.append(token)

    expanded = []
    for token in tokens:
        expanded.append(token)
        if token == "G_02_0508_g48c":
            expanded.append("G_02_05/08_g48c")
        if token == "AG_g3ex":
            expanded.append("AG_03g")
        if token == "AG_g6ex":
            expanded.append("AG_06g")
        if token in {"AG_06g1", "AG_06g2_t135a"}:
            expanded.append("AG_06g")
        if token == "B11L_01g2ex":
            expanded.append("B11L_01")
        if token == "DPA1_02_02":
            expanded.append("DPA1_02g")
        if token == "I_01g":
            expanded.extend(["I_01g1", "I_01g2", "I_01g3", "I_01g4"])
        if token == "B_098g":
            expanded.extend(["B_098g1", "B_098g2", "B_098g3"])

    deduped = []
    for token in expanded:
        if token and token not in deduped:
            deduped.append(token)
    return deduped


def matched_count(tokens, sample_counts):
    if not tokens:
        return 0, []
    total = 0
    names = []
    for genotype, count in sample_counts.items():
        if any(token in genotype for token in tokens):
            total += int(count)
            names.append(genotype)
    return total, names


def safe_sheet_title(workbook, desired, fallback):
    invalid = set("[]:*?/\\")
    title = "".join("_" if char in invalid else char for char in str(desired or fallback)).strip()
    title = title or fallback
    title = title[:31].rstrip()
    existing = {sheet.title for sheet in workbook.worksheets}
    if title not in existing:
        return title
    base = title
    index = 2
    while True:
        suffix = f" {index}"
        candidate = f"{base[:31 - len(suffix)]}{suffix}".rstrip()
        if candidate not in existing:
            return candidate
        index += 1


def remove_tables(ws):
    for name in list(ws.tables.keys()):
        del ws.tables[name]


def copy_conditional_formatting(source, destination):
    destination.conditional_formatting._cf_rules = deepcopy(source.conditional_formatting._cf_rules)


def sample_columns(ws):
    columns = []
    for col in range(4, ws.max_column + 1):
        value = ws.cell(2, col).value
        if value is None or str(value).strip() == "":
            continue
        columns.append((col, str(value).strip()))
    return columns


def formula_range(sample_cols, row):
    if not sample_cols:
        return None
    first = get_column_letter(sample_cols[0][0])
    last = get_column_letter(sample_cols[-1][0])
    return f"{first}{row}:{last}{row}"


def copy_cell_style(source, destination):
    if source.has_style:
        destination.font = copy(source.font)
        destination.fill = copy(source.fill)
        destination.border = copy(source.border)
        destination.alignment = copy(source.alignment)
        destination.number_format = source.number_format
        destination.protection = copy(source.protection)


def compact_analysis_sample_columns(ws, samples):
    start_col = 4
    target_count = len(samples)
    existing_count = max(0, ws.max_column - start_col + 1)

    if existing_count > target_count:
        ws.delete_cols(start_col + target_count, existing_count - target_count)
    elif existing_count < target_count:
        style_source_col = start_col + existing_count - 1 if existing_count > 0 else 3
        for col in range(start_col + existing_count, start_col + target_count):
            source_letter = get_column_letter(style_source_col)
            target_letter = get_column_letter(col)
            ws.column_dimensions[target_letter].width = ws.column_dimensions[source_letter].width
            for row in range(1, ws.max_row + 1):
                copy_cell_style(ws.cell(row, style_source_col), ws.cell(row, col))

    for offset, sample in enumerate(samples):
        col = start_col + offset
        ws.cell(1, col).value = sample
        ws.cell(2, col).value = sample

    return sample_columns(ws)


def copied_template_workbook(path, analysis_name, comparison_name):
    wb = load_workbook(path)
    while len(wb.worksheets) > 1:
        wb.remove(wb.worksheets[-1])
    analysis_ws = wb.worksheets[0]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        comparison_ws = wb.copy_worksheet(analysis_ws)
    copy_conditional_formatting(analysis_ws, comparison_ws)
    analysis_ws.title = safe_sheet_title(wb, analysis_name, "ONT08")
    comparison_ws.title = safe_sheet_title(wb, comparison_name, "Illumina-31262")
    remove_tables(analysis_ws)
    remove_tables(comparison_ws)
    return wb, analysis_ws, comparison_ws


def row_looks_like_allele_call(ws, row):
    label = ws.cell(row, 1).value
    if row < 22 or not isinstance(label, str):
        return False
    b_value = ws.cell(row, 2).value
    c_value = ws.cell(row, 3).value
    if isinstance(b_value, str) and b_value.startswith("="):
        return True
    if isinstance(c_value, str) and c_value.startswith("="):
        return True
    if as_number(b_value) is not None or as_number(c_value) is not None:
        return True
    return False


def fill_formula_totals(ws, rows, sample_cols):
    for row in rows:
        cell_range = formula_range(sample_cols, row)
        if not cell_range:
            continue
        ws.cell(row, 2).value = f"=SUM({cell_range})"
        ws.cell(row, 3).value = f"=COUNT({cell_range})"


def sample_numbers(ws, row, sample_cols):
    values = []
    for col, _sample in sample_cols:
        number = as_number(ws.cell(row, col).value)
        if number is not None:
            values.append(number)
    return values


def fill_read_count_summary_values(ws, row, sample_cols):
    values = sample_numbers(ws, row, sample_cols)
    total = sum(values) if values else 0
    average = total / len(values) if values else 0
    ws.cell(row, 2).value = total
    ws.cell(row, 3).value = average


def fill_subtotal_observed_values(ws, rows, sample_cols):
    for row in rows:
        values = sample_numbers(ws, row, sample_cols)
        ws.cell(row, 2).value = sum(values) if values else 0
        ws.cell(row, 3).value = sum(1 for value in values if value > 0)


def clear_cells(ws, row, start_col=1):
    for col in range(start_col, ws.max_column + 1):
        ws.cell(row, col).value = None


def clear_analysis_template_sample_values(ws):
    if ws.max_row >= 5:
        ws.cell(3, 1).value = "Filtered exact-match read count"
        clear_cells(ws, 4)
        clear_cells(ws, 5)

    for row in range(6, min(ws.max_row, 19) + 1):
        clear_cells(ws, row, start_col=2)

    if ws.max_row >= 20 and ws.cell(20, 1).value == "Comments":
        ws.cell(20, 2).value = "Subtotal"
        ws.cell(20, 3).value = "# Obs."
        clear_cells(ws, 20, start_col=4)


def row_has_sample_count(ws, row, sample_cols):
    for col, _sample in sample_cols:
        count = as_number(ws.cell(row, col).value) or 0
        if count > 0:
            return True
    return False


def prune_zero_allele_rows(ws, allele_rows, sample_cols):
    for row in sorted(allele_rows, reverse=True):
        if not row_has_sample_count(ws, row, sample_cols):
            ws.delete_rows(row)


def is_locus_header_row(ws, row):
    label = ws.cell(row, 1).value
    return row >= 21 and isinstance(label, str) and not row_looks_like_allele_call(ws, row)


def prune_empty_locus_headers(ws):
    header_rows = [row for row in range(21, ws.max_row + 1) if is_locus_header_row(ws, row)]
    for index in range(len(header_rows) - 1, -1, -1):
        row = header_rows[index]
        next_header = header_rows[index + 1] if index + 1 < len(header_rows) else ws.max_row + 1
        has_allele = any(row_looks_like_allele_call(ws, candidate) for candidate in range(row + 1, next_header))
        if not has_allele:
            ws.delete_rows(row)


def fill_analysis_sheet(ws, genotype_counts, sample_stats, samples):
    cols = compact_analysis_sample_columns(ws, samples)
    clear_analysis_template_sample_values(ws)

    allele_rows = [row for row in range(1, ws.max_row + 1) if row_looks_like_allele_call(ws, row)]

    for col, sample in cols:
        stats = sample_stats.get(sample, {})
        ws.cell(3, col).value = display_value(stats.get("passed_alignments"))

    matched_by_row_sample = {}
    for row in allele_rows:
        label = ws.cell(row, 1).value
        tokens = tokens_for_expected(label)
        for col, sample in cols:
            count, names = matched_count(tokens, genotype_counts.get(sample, {}))
            ws.cell(row, col).value = count if count > 0 else None
            matched_by_row_sample[(row, sample)] = (count, names, tokens)
    prune_zero_allele_rows(ws, allele_rows, cols)
    prune_empty_locus_headers(ws)
    final_allele_rows = [row for row in range(1, ws.max_row + 1) if row_looks_like_allele_call(ws, row)]
    fill_read_count_summary_values(ws, 3, cols)
    fill_subtotal_observed_values(ws, final_allele_rows, cols)
    return cols, allele_rows, matched_by_row_sample


def style_tabular_sheet(ws):
    header_fill = PatternFill("solid", fgColor="4472C4")
    header_font = Font(color="FFFFFF", bold=True)
    thin_gray = Side(style="thin", color="D9E2F3")
    for cell in ws[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center")
        cell.border = Border(bottom=thin_gray)
    ws.freeze_panes = "A2"
    if ws.max_row and ws.max_column:
        ws.auto_filter.ref = ws.dimensions
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for row in range(1, min(ws.max_row, 200) + 1):
            value = ws.cell(row, col).value
            if value is not None:
                max_len = max(max_len, len(str(value)))
        ws.column_dimensions[letter].width = min(max(max_len + 2, 10), 48)


def write_csv_sheet(wb, title, headers, rows):
    ws = wb.create_sheet(title=safe_sheet_title(wb, title, title[:31] or "Sheet"))
    ws.append(headers)
    for row in rows:
        ws.append([display_value(row.get(header)) for header in headers])
    style_tabular_sheet(ws)
    return ws


def write_stats_sheet(wb, stats):
    ws = wb.create_sheet(title=safe_sheet_title(wb, "Run Stats", "Run Stats"))
    ws.append(["metric", "value"])
    for key in sorted(stats):
        value = stats[key]
        if isinstance(value, (dict, list)):
            value = json.dumps(value, sort_keys=True)
        ws.append([key, display_value(value)])
    style_tabular_sheet(ws)
    return ws


def load_haplotype_analysis(path):
    if not path:
        return None
    with open(path) as handle:
        return json.load(handle)


def haplotype_calls_by_sample_locus(haplotype_analysis):
    by_sample = {}
    if not haplotype_analysis:
        return by_sample
    for sample in haplotype_analysis.get("samples", []):
        sample_id = str(sample.get("sample", "")).strip()
        if not sample_id:
            continue
        locus_map = {}
        for call in sample.get("calls", []):
            locus = str(call.get("locus", "")).strip()
            if locus:
                locus_map[locus] = call
        by_sample[sample_id] = locus_map
    return by_sample


def haplotype_row_targets(ws):
    targets = []
    for row in range(1, min(ws.max_row, 40) + 1):
        value = ws.cell(row, 1).value
        if not isinstance(value, str):
            continue
        match = re.match(r"^(MHC-[A-Za-z0-9]+) Haplotype ([12])$", value.strip())
        if match:
            targets.append((row, match.group(1), int(match.group(2))))
    return targets


def noncalled_haplotype_summary(locus_calls):
    messages = []
    for locus in sorted(locus_calls):
        call = locus_calls[locus]
        status = call.get("status")
        if status in (None, "called"):
            continue
        left = call.get("haplotype1") or ""
        right = call.get("haplotype2") or ""
        label = left if left == right or not right else f"{left}/{right}"
        messages.append(f"{locus}: {label}")
    return "; ".join(messages)


def fill_haplotype_rows(ws, sample_cols, haplotype_analysis):
    by_sample = haplotype_calls_by_sample_locus(haplotype_analysis)
    if not by_sample:
        return
    for row, locus, index in haplotype_row_targets(ws):
        key = f"haplotype{index}"
        for col, sample in sample_cols:
            call = by_sample.get(sample, {}).get(locus)
            ws.cell(row, col).value = call.get(key) if call else None
    comments_row = None
    for row in range(1, min(ws.max_row, 40) + 1):
        if ws.cell(row, 1).value == "Comments":
            comments_row = row
            break
    if comments_row:
        for col, sample in sample_cols:
            summary = noncalled_haplotype_summary(by_sample.get(sample, {}))
            ws.cell(comments_row, col).value = summary or None


def haplotype_loci_for_report(haplotype_analysis):
    fallback = [
        "MHC-A",
        "MHC-B",
        "MHC-DRB",
        "MHC-DQA",
        "MHC-DQB",
        "MHC-DPA",
        "MHC-DPB",
    ]
    if not haplotype_analysis:
        return fallback
    loci = []
    seen = set()
    for sample in haplotype_analysis.get("samples", []):
        for call in sample.get("calls", []):
            locus = str(call.get("locus", "")).strip()
            if locus and locus not in seen:
                loci.append(locus)
                seen.add(locus)
    return loci if loci else fallback


def write_haplotype_sheet(wb, haplotype_analysis):
    if not haplotype_analysis:
        return None
    ws = wb.create_sheet(title=safe_sheet_title(wb, "Haplotype Calls", "Haplotype Calls"))
    headers = [
        "sample",
        "locus",
        "haplotype_1",
        "haplotype_2",
        "status",
        "observed_genotype_count",
        "matched_haplotypes",
        "observed_genotypes",
        "notes",
    ]
    ws.append(headers)
    for sample in haplotype_analysis.get("samples", []):
        sample_id = sample.get("sample")
        for call in sample.get("calls", []):
            ws.append([
                sample_id,
                call.get("locus"),
                call.get("haplotype1"),
                call.get("haplotype2"),
                call.get("status"),
                call.get("observedGenotypeCount"),
                ";".join(item.get("name", "") for item in call.get("matchedHaplotypes", [])),
                ";".join(call.get("observedGenotypes", [])),
                call.get("notes"),
            ])
    style_tabular_sheet(ws)
    return ws


def write_audit_sheet(wb, title, comparison_ws, sample_cols, allele_rows, matched_by_row_sample, comparison_name, analysis_name):
    ws = wb.create_sheet(title=safe_sheet_title(wb, title, "Audit"))
    headers = [
        "sample",
        "row",
        "expected_call",
        f"{comparison_name}_count",
        f"{analysis_name}_count",
        f"recovered_{comparison_name}_positive",
        "tokens",
        "matched_genotypes",
    ]
    ws.append(headers)
    audit_rows = 0
    comparison_sample_cols = {sample: col for col, sample in sample_columns(comparison_ws)}
    for row in allele_rows:
        expected_call = comparison_ws.cell(row, 1).value
        for col, sample in sample_cols:
            comparison_col = comparison_sample_cols.get(sample, col)
            comparison_count = as_number(comparison_ws.cell(row, comparison_col).value) or 0
            analysis_count, names, tokens = matched_by_row_sample.get((row, sample), (0, [], []))
            if analysis_count <= 0:
                continue
            recovered = None
            if comparison_count > 0:
                recovered = "yes" if analysis_count > 0 else "no"
            ws.append([
                sample,
                row,
                expected_call,
                comparison_count if comparison_count > 0 else None,
                analysis_count if analysis_count > 0 else None,
                recovered,
                ",".join(tokens),
                ";".join(names),
            ])
            audit_rows += 1
    style_tabular_sheet(ws)
    return ws, audit_rows


def build_template_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis):
    wb, analysis_ws, comparison_ws = copied_template_workbook(
        args.comparison_workbook,
        args.analysis_name,
        args.comparison_name,
    )
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    sample_cols, allele_rows, matched = fill_analysis_sheet(analysis_ws, genotype_counts, sample_stats, samples)
    fill_haplotype_rows(analysis_ws, sample_cols, haplotype_analysis)
    write_csv_sheet(wb, f"{args.analysis_name} Long Summary", genotype_headers, genotype_rows)
    write_csv_sheet(wb, f"{args.analysis_name} Sample Summary", sample_headers, sample_rows)
    write_haplotype_sheet(wb, haplotype_analysis)
    _, audit_rows = write_audit_sheet(
        wb,
        f"{args.comparison_name} Audit",
        comparison_ws,
        sample_cols,
        allele_rows,
        matched,
        args.comparison_name,
        args.analysis_name,
    )
    write_stats_sheet(wb, stats)
    wb.active = 0
    return wb, audit_rows


def build_generic_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis):
    wb = Workbook()
    ws = wb.active
    ws.title = safe_sheet_title(wb, args.analysis_name, "ONT08")
    genotype_counts = load_genotype_counts(genotype_rows)
    samples = report_sample_names(sample_rows, genotype_counts)
    genotype_rows = rows_for_samples(genotype_rows, samples)
    sample_rows = rows_for_samples(sample_rows, samples)
    genotype_counts = load_genotype_counts(genotype_rows)
    sample_stats = load_sample_stats(sample_rows)
    ordered_genotypes = []
    seen = set()
    for name in reference_names(args.reference_fasta):
        if name not in seen:
            ordered_genotypes.append(name)
            seen.add(name)
    for row in genotype_rows:
        genotype = row.get("genotype")
        if genotype and genotype not in seen:
            ordered_genotypes.append(genotype)
            seen.add(genotype)

    ws.append(["Animal ID", None, None] + samples)
    ws.append(["GS ID", "Total", "Average"] + samples)
    ws.append(["Filtered exact-match read count", None, None] + [display_value(sample_stats.get(sample, {}).get("passed_alignments")) for sample in samples])
    ws.append([])
    ws.append([])
    for locus in haplotype_loci_for_report(haplotype_analysis):
        ws.append([f"{locus} Haplotype 1", None, None] + [None for _sample in samples])
        ws.append([f"{locus} Haplotype 2", None, None] + [None for _sample in samples])
    ws.append(["Comments", "Subtotal", "# Obs."] + [None for _sample in samples])
    ws.append(["Genotype", "Total", "# Obs."] + samples)
    sample_cols = [(index + 4, sample) for index, sample in enumerate(samples)]
    fill_haplotype_rows(ws, sample_cols, haplotype_analysis)
    for genotype in ordered_genotypes:
        if not any(genotype_counts.get(sample, {}).get(genotype, 0) > 0 for sample in samples):
            continue
        row_index = ws.max_row + 1
        values = [genotype, None, None]
        for sample in samples:
            count = genotype_counts.get(sample, {}).get(genotype, 0)
            values.append(count if count > 0 else None)
        ws.append(values)
        fill_subtotal_observed_values(ws, [row_index], sample_cols)
    fill_read_count_summary_values(ws, 3, sample_cols)
    style_tabular_sheet(ws)
    write_csv_sheet(wb, f"{args.analysis_name} Long Summary", genotype_headers, genotype_rows)
    write_csv_sheet(wb, f"{args.analysis_name} Sample Summary", sample_headers, sample_rows)
    write_haplotype_sheet(wb, haplotype_analysis)
    write_stats_sheet(wb, stats)
    wb.active = 0
    return wb, 0


def write_provenance(args, start_time, started_at, completed_at, audit_rows):
    inputs = [
        file_record(args.genotypes_csv, "input"),
        file_record(args.samples_csv, "input"),
        file_record(args.stats_json, "input"),
        file_record(args.reference_fasta, "input"),
        file_record(args.barcode_definitions, "input"),
    ]
    if args.comparison_workbook:
        inputs.append(file_record(args.comparison_workbook, "comparison"))
    if args.haplotype_analysis_json:
        inputs.append(file_record(args.haplotype_analysis_json, "analysis"))
    payload = {
        "toolName": "lungfish fastq ont-barcode-genotype workbook report",
        "toolVersion": "1",
        "argv": sys.argv,
        "reproducibleCommand": args.provenance_command or " ".join(sys.argv),
        "options": vars(args),
        "resolvedDefaults": {
            "analysisName": args.run_name,
            "comparisonName": "Illumina-31262",
            "haplotypeAnalysisJSON": None,
        },
        "runtimeIdentity": {
            "python": sys.version,
            "platform": platform.platform(),
            "openpyxl": openpyxl.__version__,
            "executable": sys.executable,
        },
        "inputs": inputs,
        "outputs": [
            file_record(args.output_xlsx, "report"),
            {"path": args.provenance_json, "role": "provenance", "exists": False},
        ],
        "auditRows": audit_rows,
        "exitStatus": 0,
        "wallClockSeconds": time.time() - start_time,
        "stderr": "",
        "startedAt": started_at,
        "completedAt": completed_at,
    }
    with open(args.provenance_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    payload["outputs"] = [
        file_record(args.output_xlsx, "report"),
        file_record(args.provenance_json, "provenance"),
    ]
    with open(args.provenance_json, "w") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def main():
    args = parse_args()
    start_time = time.time()
    started_at = utc_now()
    os.makedirs(os.path.dirname(args.output_xlsx) or ".", exist_ok=True)
    genotype_headers, genotype_rows = read_csv(args.genotypes_csv)
    sample_headers, sample_rows = read_csv(args.samples_csv)
    genotype_rows = assigned_sample_rows(genotype_rows)
    sample_rows = assigned_sample_rows(sample_rows)
    with open(args.stats_json) as handle:
        stats = json.load(handle)
    haplotype_analysis = load_haplotype_analysis(args.haplotype_analysis_json)

    if args.comparison_workbook:
        wb, audit_rows = build_template_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis)
    else:
        wb, audit_rows = build_generic_workbook(args, genotype_headers, genotype_rows, sample_headers, sample_rows, stats, haplotype_analysis)

    wb.save(args.output_xlsx)
    completed_at = utc_now()
    write_provenance(args, start_time, started_at, completed_at, audit_rows)
    summary = {
        "outputXLSX": args.output_xlsx,
        "provenanceJSON": args.provenance_json,
        "openpyxlVersion": openpyxl.__version__,
        "sheetNames": wb.sheetnames,
        "auditRows": audit_rows,
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
"""#
