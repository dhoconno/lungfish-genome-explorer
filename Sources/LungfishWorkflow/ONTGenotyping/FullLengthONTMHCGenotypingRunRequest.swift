import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

public enum FullLengthONTPBAAClusterSourceMode: String, Sendable, Codable, Equatable, CaseIterable {
    case useCompatible = "use-compatible"
    case requireExisting = "require-existing"
    case rerunAll = "rerun-all"

    public init?(cliValue: String) {
        self.init(rawValue: cliValue)
    }
}

public struct FullLengthONTMHCGenotypingRunRequest: Sendable, Codable, Equatable {
    public static let defaultSavontQualityValueCutoff = 90
    public static let defaultSavontMinimumClusterSize = 3
    public static let savontToolVersion = "0.5.0"
    public static let savontCondaEnvironment = "savont"
    public static let savontPackageSpec = "bioconda::savont=0.5.0=ha819e4a_0"

    public let inputFASTQURLs: [URL]
    public let referenceSourceURL: URL
    public let orientReferenceURL: URL?
    public let forwardPrimerURL: URL?
    public let reversePrimerURL: URL?
    public let outputDirectory: URL
    public let outputName: String
    public let projectURL: URL?
    public let threads: Int
    public let minimumLength: Int
    public let maximumLength: Int
    public let savontQualityValueCutoff: Int
    public let savontMinimumClusterSize: Int
    public let minUnmatchedReads: Int
    public let cdnaThreshold: Int
    public let sampleJobs: Int?
    public let savontThreadsPerSample: Int?
    public let keepIntermediates: Bool
    public let reuseCompatibleCheckpoints: Bool
    public let haplotypeDropoutSampleFraction: Double?
    public let haplotypeDropoutLocusFraction: Double?
    public let haplotypeDropoutLocusFractionOverrides: [String: Double]
    public let haplotypeAssayID: String?
    public let haplotypeSpeciesCode: String?
    public let haplotypeDefinitionScope: HaplotypeDefinitionScope?
    public let haplotypeDefinitionSetID: String?

    public init(
        inputFASTQURLs: [URL],
        referenceSourceURL: URL,
        orientReferenceURL: URL? = nil,
        forwardPrimerURL: URL? = nil,
        reversePrimerURL: URL? = nil,
        outputDirectory: URL,
        outputName: String = "full-length-ont-mhc-genotyping",
        projectURL: URL? = nil,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        minimumLength: Int = 2_000,
        maximumLength: Int = 4_000,
        savontQualityValueCutoff: Int = Self.defaultSavontQualityValueCutoff,
        savontMinimumClusterSize: Int = Self.defaultSavontMinimumClusterSize,
        minUnmatchedReads: Int = 5,
        cdnaThreshold: Int = 2_000,
        sampleJobs: Int? = nil,
        savontThreadsPerSample: Int? = nil,
        keepIntermediates: Bool = false,
        reuseCompatibleCheckpoints: Bool = false,
        haplotypeDropoutSampleFraction: Double? = nil,
        haplotypeDropoutLocusFraction: Double? = nil,
        haplotypeDropoutLocusFractionOverrides: [String: Double] = [:],
        haplotypeAssayID: String? = nil,
        haplotypeSpeciesCode: String? = nil,
        haplotypeDefinitionScope: HaplotypeDefinitionScope? = nil,
        haplotypeDefinitionSetID: String? = nil
    ) {
        let normalizedOutputName = Self.sanitizedOutputName(outputName)
        self.inputFASTQURLs = inputFASTQURLs.map(\.standardizedFileURL)
        self.referenceSourceURL = referenceSourceURL.standardizedFileURL
        self.orientReferenceURL = orientReferenceURL?.standardizedFileURL
        self.forwardPrimerURL = forwardPrimerURL?.standardizedFileURL
        self.reversePrimerURL = reversePrimerURL?.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = normalizedOutputName
        self.projectURL = projectURL?.standardizedFileURL
        self.threads = max(1, threads)
        self.minimumLength = max(1, minimumLength)
        self.maximumLength = max(self.minimumLength, maximumLength)
        self.savontQualityValueCutoff = max(0, min(100, savontQualityValueCutoff))
        self.savontMinimumClusterSize = max(1, savontMinimumClusterSize)
        self.minUnmatchedReads = max(1, minUnmatchedReads)
        self.cdnaThreshold = max(1, cdnaThreshold)
        self.sampleJobs = sampleJobs.map { max(1, $0) }
        self.savontThreadsPerSample = savontThreadsPerSample.map { max(1, $0) }
        self.keepIntermediates = keepIntermediates
        self.reuseCompatibleCheckpoints = reuseCompatibleCheckpoints
        self.haplotypeDropoutSampleFraction = Self.normalizedFraction(haplotypeDropoutSampleFraction)
        self.haplotypeDropoutLocusFraction = Self.normalizedFraction(haplotypeDropoutLocusFraction)
        self.haplotypeDropoutLocusFractionOverrides = Self.normalizedFractionOverrides(
            haplotypeDropoutLocusFractionOverrides
        )
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
    }

    public var reportCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.csv")
    }

    public var sampleSummaryCSVURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-samples.csv")
    }

    public var statsJSONURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-stats.json")
    }

    public var workbookURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).full-length-ont-mhc-genotypes.xlsx")
    }

    public var currentWorkbookURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    public var haplotypeAnalysisURL: URL {
        outputDirectory.appendingPathComponent("\(outputName).haplotype-analysis.json")
    }

    public var unmatchedClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("unmatched_clusters.fasta")
    }

    public var deduplicatedUnmatchedClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("deduplicated_unmatched_clusters.fasta")
    }

    public var rawUnmatchedConsensusesFASTAURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/internal", isDirectory: true)
            .appendingPathComponent("raw-unmatched-consensuses.fasta")
    }

    public var rawUnmatchedConsensusDecisionsJSONURL: URL {
        outputDirectory
            .appendingPathComponent("artifacts/internal", isDirectory: true)
            .appendingPathComponent("raw-unmatched-consensus-decisions.json")
    }

    public var cdnaClustersFASTAURL: URL {
        outputDirectory.appendingPathComponent("cdna_clusters.fasta")
    }

    public var provenanceURL: URL {
        outputDirectory.appendingPathComponent("full-length-ont-mhc-genotyping-provenance.json")
    }

    public var failureProvenanceURL: URL {
        URL(fileURLWithPath: outputDirectory.standardizedFileURL.path + ".failed.lungfish-provenance.json")
    }

    var legacyPublicationFailureProvenanceURL: URL {
        outputDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(outputDirectory.lastPathComponent).publication-failure.json"
        )
    }

    public var manifestURL: URL {
        ONTGenotypeResultBundle.manifestURL(in: outputDirectory)
    }

    public var argv: [String] {
        var values = [
            CLICommandIdentity.executableName,
            "fastq",
            "full-length-ont-mhc-genotype",
        ] + inputFASTQURLs.map(\.path) + [
            "--reference", referenceSourceURL.path,
            "--output-dir", outputDirectory.path,
            "--output-name", outputName,
            "--threads", String(threads),
            "--min-length", String(minimumLength),
            "--max-length", String(maximumLength),
            "--savont-quality-value-cutoff", String(savontQualityValueCutoff),
            "--savont-min-cluster-size", String(savontMinimumClusterSize),
            "--min-unmatched-reads", String(minUnmatchedReads),
            "--cdna-threshold", String(cdnaThreshold),
        ]
        appendHaplotypeThresholdArguments(to: &values)
        if let orientReferenceURL {
            values += ["--orient-reference", orientReferenceURL.path]
        }
        if let forwardPrimerURL {
            values += ["--forward-primer", forwardPrimerURL.path]
        }
        if let reversePrimerURL {
            values += ["--reverse-primer", reversePrimerURL.path]
        }
        if let projectURL {
            values += ["--project", projectURL.path]
        }
        if let sampleJobs {
            values += ["--sample-jobs", String(sampleJobs)]
        }
        if let savontThreadsPerSample {
            values += ["--savont-threads-per-sample", String(savontThreadsPerSample)]
        }
        if keepIntermediates {
            values += ["--keep-intermediates"]
        }
        if reuseCompatibleCheckpoints {
            values += ["--reuse-compatible-checkpoints"]
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
        }
        return values
    }

    public var haplotypeDropoutEvaluator: GenotypeDropoutEvaluator? {
        guard haplotypeDropoutSampleFraction != nil
                || haplotypeDropoutLocusFraction != nil
                || !haplotypeDropoutLocusFractionOverrides.isEmpty else {
            return nil
        }
        return GenotypeDropoutEvaluator(
            absolute: 1,
            sampleFraction: haplotypeDropoutSampleFraction,
            locusFraction: haplotypeDropoutLocusFraction,
            locusFractionOverrides: haplotypeDropoutLocusFractionOverrides
        )
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

    public func replacingOutput(outputDirectory: URL, outputName: String) -> FullLengthONTMHCGenotypingRunRequest {
        FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: inputFASTQURLs,
            referenceSourceURL: referenceSourceURL,
            orientReferenceURL: orientReferenceURL,
            forwardPrimerURL: forwardPrimerURL,
            reversePrimerURL: reversePrimerURL,
            outputDirectory: outputDirectory,
            outputName: outputName,
            projectURL: projectURL,
            threads: threads,
            minimumLength: minimumLength,
            maximumLength: maximumLength,
            savontQualityValueCutoff: savontQualityValueCutoff,
            savontMinimumClusterSize: savontMinimumClusterSize,
            minUnmatchedReads: minUnmatchedReads,
            cdnaThreshold: cdnaThreshold,
            sampleJobs: sampleJobs,
            savontThreadsPerSample: savontThreadsPerSample,
            keepIntermediates: keepIntermediates,
            reuseCompatibleCheckpoints: reuseCompatibleCheckpoints,
            haplotypeDropoutSampleFraction: haplotypeDropoutSampleFraction,
            haplotypeDropoutLocusFraction: haplotypeDropoutLocusFraction,
            haplotypeDropoutLocusFractionOverrides: haplotypeDropoutLocusFractionOverrides,
            haplotypeAssayID: haplotypeAssayID,
            haplotypeSpeciesCode: haplotypeSpeciesCode,
            haplotypeDefinitionScope: haplotypeDefinitionScope,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID
        )
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
        return collapsed.isEmpty ? "full-length-ont-mhc-genotyping" : collapsed
    }
}
