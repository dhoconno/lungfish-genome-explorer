import Foundation
import Darwin
import LungfishCore
import LungfishIO

public struct ONTBarcodeDemuxGenotypingRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let barcodeDefinitionsURL: URL?
    public let outputDirectory: URL
    public let outputName: String
    public let demuxManifestURL: URL?
    public let analysisName: String
    public let projectURL: URL?
    public let threads: Int
    public let sortThreads: Int
    public let minSupport: Int
    public let keepIntermediates: Bool
    public let haplotypeDropoutSampleFraction: Double?
    public let haplotypeDropoutLocusFraction: Double?
    public let haplotypeDropoutLocusFractionOverrides: [String: Double]
    public let haplotypeAssayID: String?
    public let haplotypeSpeciesCode: String?
    public let haplotypeDefinitionScope: HaplotypeDefinitionScope?
    public let haplotypeDefinitionSetID: String?
    public let presetID: String?
    public let presetVersion: String?
    public let lockedReferenceSHA256: String?
    public let extraArguments: [String]
    public let mode: AmpliconGenotypingMode
    public let readType: AmpliconGenotypingReadType
    public let resultWorkflowKind: GenotypeResultWorkflowKind?
    public let aiSpecialistPresetID: String?

    public init(
        inputFASTQURL: URL,
        referenceSourceURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        outputName: String = "ont-barcode-genotyping",
        demuxManifestURL: URL? = nil,
        analysisName: String? = nil,
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        sortThreads: Int = 4,
        minSupport: Int = 1,
        keepIntermediates: Bool = false,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        haplotypeAssayID: String? = nil,
        haplotypeSpeciesCode: String? = nil,
        haplotypeDefinitionScope: HaplotypeDefinitionScope? = nil,
        haplotypeDefinitionSetID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        lockedReferenceSHA256: String? = nil,
        extraArguments: [String] = [],
        resultWorkflowKind: GenotypeResultWorkflowKind? = nil,
        aiSpecialistPresetID: String? = nil
    ) {
        self.init(
            inputFASTQURLs: [inputFASTQURL],
            referenceSourceURL: referenceSourceURL,
            barcodeDefinitionsURL: barcodeDefinitionsURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            demuxManifestURL: demuxManifestURL,
            analysisName: analysisName,
            projectURL: projectURL,
            threads: threads,
            sortThreads: sortThreads,
            minSupport: minSupport,
            keepIntermediates: keepIntermediates,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            presetID: presetID,
            presetVersion: presetVersion,
            lockedReferenceSHA256: lockedReferenceSHA256,
            extraArguments: extraArguments,
            mode: .ontBarcodeDemux,
            readType: .ont,
            resultWorkflowKind: resultWorkflowKind,
            aiSpecialistPresetID: aiSpecialistPresetID
        )
    }

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        barcodeDefinitionsURL: URL? = nil,
        outputDirectory: URL,
        outputName: String = "amplicon-genotyping",
        demuxManifestURL: URL? = nil,
        analysisName: String? = nil,
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        sortThreads: Int = 4,
        minSupport: Int = 1,
        keepIntermediates: Bool = false,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        haplotypeAssayID: String? = nil,
        haplotypeSpeciesCode: String? = nil,
        haplotypeDefinitionScope: HaplotypeDefinitionScope? = nil,
        haplotypeDefinitionSetID: String? = nil,
        presetID: String? = nil,
        presetVersion: String? = nil,
        lockedReferenceSHA256: String? = nil,
        extraArguments: [String] = [],
        mode: AmpliconGenotypingMode = .auto,
        readType: AmpliconGenotypingReadType = .auto,
        resultWorkflowKind: GenotypeResultWorkflowKind? = nil,
        aiSpecialistPresetID: String? = nil
    ) {
        let normalizedOutputName = Self.sanitizedOutputName(outputName)
        let standardizedInputURLs = inputFASTQURLs.isEmpty
            ? [URL(fileURLWithPath: "").standardizedFileURL]
            : inputFASTQURLs.map(\.standardizedFileURL)
        self.inputFASTQURL = standardizedInputURLs[0]
        self.inputFASTQURLs = standardizedInputURLs
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        let standardizedBarcodeDefinitionsURL = barcodeDefinitionsURL?.standardizedFileURL
        let effectiveMode = Self.effectiveMode(
            requestedMode: mode,
            readType: readType,
            barcodeDefinitionsURL: standardizedBarcodeDefinitionsURL
        )
        let effectiveReadType = Self.effectiveReadType(
            requestedReadType: readType,
            mode: effectiveMode
        )
        self.barcodeDefinitionsURL = standardizedBarcodeDefinitionsURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = normalizedOutputName
        self.demuxManifestURL = demuxManifestURL?.standardizedFileURL
        self.analysisName = Self.sanitizedReportLabel(
            analysisName ?? normalizedOutputName,
            fallback: normalizedOutputName
        )
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.sortThreads = max(1, sortThreads)
        self.minSupport = max(1, minSupport)
        self.keepIntermediates = keepIntermediates
        self.haplotypeDropoutSampleFraction = Self.normalizedFraction(haplotypeDropoutSampleFraction)
        self.haplotypeDropoutLocusFraction = Self.normalizedFraction(haplotypeDropoutLocusFraction)
        self.haplotypeDropoutLocusFractionOverrides = Self.normalizedFractionOverrides(haplotypeDropoutLocusFractionOverrides)
        let trimmedHaplotypeAssayID = haplotypeAssayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeAssayID = trimmedHaplotypeAssayID?.isEmpty == true
            ? nil
            : trimmedHaplotypeAssayID
        let trimmedHaplotypeSpeciesCode = haplotypeSpeciesCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeSpeciesCode = trimmedHaplotypeSpeciesCode?.isEmpty == true
            ? nil
            : trimmedHaplotypeSpeciesCode
        self.haplotypeDefinitionScope = haplotypeDefinitionScope
        let trimmedHaplotypeDefinitionSetID = haplotypeDefinitionSetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.haplotypeDefinitionSetID = trimmedHaplotypeDefinitionSetID?.isEmpty == true
            ? nil
            : trimmedHaplotypeDefinitionSetID
        let trimmedPresetID = presetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.presetID = trimmedPresetID?.isEmpty == true ? nil : trimmedPresetID
        let trimmedPresetVersion = presetVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.presetVersion = trimmedPresetVersion?.isEmpty == true ? nil : trimmedPresetVersion
        let trimmedLockedReferenceSHA256 = lockedReferenceSHA256?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lockedReferenceSHA256 = trimmedLockedReferenceSHA256?.isEmpty == true
            ? nil
            : trimmedLockedReferenceSHA256
        self.extraArguments = extraArguments
        self.mode = effectiveMode
        self.readType = effectiveReadType
        self.resultWorkflowKind = resultWorkflowKind
        let trimmedAISpecialistPresetID = aiSpecialistPresetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aiSpecialistPresetID = trimmedAISpecialistPresetID?.isEmpty == true ? nil : trimmedAISpecialistPresetID
    }

    public func replacingOutput(
        outputDirectory: URL,
        outputName: String,
        analysisName: String
    ) -> ONTBarcodeDemuxGenotypingRunRequest {
        ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: inputFASTQURLs,
            referenceSourceURL: referenceSourceURL,
            barcodeDefinitionsURL: barcodeDefinitionsURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            demuxManifestURL: demuxManifestURL,
            analysisName: analysisName,
            projectURL: projectURL,
            threads: threads,
            sortThreads: sortThreads,
            minSupport: minSupport,
            keepIntermediates: keepIntermediates,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            presetID: presetID,
            presetVersion: presetVersion,
            lockedReferenceSHA256: lockedReferenceSHA256,
            extraArguments: extraArguments,
            mode: mode,
            readType: readType,
            resultWorkflowKind: resultWorkflowKind,
            aiSpecialistPresetID: aiSpecialistPresetID
        )
    }

    private static func effectiveMode(
        requestedMode: AmpliconGenotypingMode,
        readType: AmpliconGenotypingReadType,
        barcodeDefinitionsURL: URL?
    ) -> AmpliconGenotypingMode {
        if requestedMode == .ontSampleBundles {
            return .ontSampleBundles
        }
        switch readType {
        case .ont:
            return .ontBarcodeDemux
        case .illumina:
            return .illuminaPaired
        case .auto:
            if requestedMode == .auto, barcodeDefinitionsURL != nil {
                return .ontBarcodeDemux
            }
            return requestedMode
        }
    }

    private static func effectiveReadType(
        requestedReadType: AmpliconGenotypingReadType,
        mode: AmpliconGenotypingMode
    ) -> AmpliconGenotypingReadType {
        if requestedReadType != .auto {
            return requestedReadType
        }
        switch mode {
        case .ontBarcodeDemux, .ontSampleBundles:
            return .ont
        case .illuminaPaired:
            return .illumina
        case .auto:
            return .auto
        }
    }

    private static func normalizedFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(value, 1.0)
    }

    private static func normalizedFractionOverrides(_ values: [String: Double]) -> [String: Double] {
        var normalized: [String: Double] = [:]
        for (key, value) in values {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let fraction = normalizedFraction(value) else { continue }
            normalized[trimmed] = fraction
        }
        return normalized
    }

    public var haplotypeDropoutEvaluator: GenotypeDropoutEvaluator? {
        guard minSupport > 1
                || haplotypeDropoutSampleFraction != nil
                || haplotypeDropoutLocusFraction != nil
                || !haplotypeDropoutLocusFractionOverrides.isEmpty else {
            return nil
        }
        return GenotypeDropoutEvaluator(
            absolute: minSupport,
            sampleFraction: haplotypeDropoutSampleFraction,
            locusFraction: haplotypeDropoutLocusFraction,
            locusFractionOverrides: haplotypeDropoutLocusFractionOverrides
        )
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
        workbookURL.appendingPathExtension("provenance.json")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("retained-demux-genotyping-provenance.json")
    }

    public var workbookURL: URL {
        let analysisSuffix = analysisName == outputName ? "" : "_\(analysisName)"
        return outputDirectory.appendingPathComponent("\(outputName)\(analysisSuffix).xlsx")
    }

    public var specialistPromptSnapshotURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/ai-haplotyping/prompts", isDirectory: true)
            .appendingPathComponent("mcm-mhc-haplotyping-specialist-prompt.md")
    }

    public var cliSubcommand: String {
        let ontSampleBundleCohort = barcodeDefinitionsURL == nil && mode == .ontSampleBundles
        let illuminaCohort = inputFASTQURLs.count > 1
            && barcodeDefinitionsURL == nil
            && (mode == .illuminaPaired || (mode == .auto && readType == .illumina))
        return ontSampleBundleCohort || illuminaCohort ? "genotype-cohort" : "genotype"
    }

    public var argv: [String] {
        var values = [
            CLICommandIdentity.executableName,
            "fastq",
            cliSubcommand,
        ] + inputFASTQURLs.map(\.path) + [
            "--mode", mode.cliArgument,
            "--read-type", readType.cliArgument,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--sort-threads", String(sortThreads),
            "--min-support", String(minSupport),
            "--analysis-name", analysisName,
        ]
        if let presetID {
            values += ["--preset", presetID]
        } else {
            values += ["--reference", referenceSourceURL.path]
        }
        appendHaplotypeThresholdArguments(to: &values)
        if let barcodeDefinitionsURL {
            values += ["--barcodes", barcodeDefinitionsURL.path]
        }
        if let haplotypeDefinitionSetID {
            if let haplotypeAssayID {
                values += ["--haplotype-assay", haplotypeAssayID]
            }
            if let haplotypeSpeciesCode {
                values += ["--haplotype-species", haplotypeSpeciesCode]
            }
            if let haplotypeDefinitionScope {
                values += ["--haplotype-definition-scope", haplotypeDefinitionScope.rawValue]
            }
            values += ["--haplotype-definition", haplotypeDefinitionSetID]
        } else {
            // Omission lets the CLI select a reference bundle's default definition.
            // Preserve the explicit no-haplotyping intent through launch and replay.
            values += ["--genotype-only"]
        }
        if let demuxManifestURL {
            values += ["--demux-manifest", demuxManifestURL.path]
        }
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if keepIntermediates {
            values += ["--keep-intermediates"]
        }
        if !extraArguments.isEmpty {
            values += ["--extra-args", AdvancedCommandLineOptions.join(extraArguments)]
        }
        return values
    }

    public func appendHaplotypeThresholdArguments(to values: inout [String]) {
        if let haplotypeDropoutSampleFraction {
            values += [
                "--haplotype-min-sample-percent",
                Self.percentArgument(forFraction: haplotypeDropoutSampleFraction),
            ]
        }
        if let haplotypeDropoutLocusFraction {
            values += [
                "--haplotype-min-locus-percent",
                Self.percentArgument(forFraction: haplotypeDropoutLocusFraction),
            ]
        }
        for key in haplotypeDropoutLocusFractionOverrides.keys.sorted() {
            guard let fraction = haplotypeDropoutLocusFractionOverrides[key] else { continue }
            values += [
                "--haplotype-min-locus-percent-override",
                "\(key)=\(Self.percentArgument(forFraction: fraction))",
            ]
        }
    }

    private static func percentArgument(forFraction fraction: Double) -> String {
        String(format: "%g", fraction * 100.0)
    }

    private static func sanitizedOutputName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "amplicon-genotyping" : collapsed
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
