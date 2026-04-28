import Foundation

public enum NFCoreWorkflowDifficulty: String, Codable, Sendable, Equatable {
    case easy
    case moderate
    case hard

    public var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        }
    }
}

public enum NFCoreResultSurface: String, Codable, Sendable, Equatable, CaseIterable {
    case fastqDatasets
    case referenceBundles
    case mappingBundles
    case variantTracks
    case reports
    case taxonomy
    case intervals
    case expression
    case singleCell
    case imaging
    case proteomics
    case graph
    case custom
}

public struct NFCoreSupportedWorkflow: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let description: String
    public let pinnedVersion: String
    public let whenToUse: String
    public let notFor: String
    public let requiredInputs: String
    public let expectedOutputs: String
    public let exampleUseCase: String
    public let runButtonTitle: String
    public let acceptedInputSuffixes: [String]
    public let primaryInputParameter: String
    public let defaultParams: [String: String]
    public let keyParameters: [NFCoreWorkflowParameter]
    public let difficulty: NFCoreWorkflowDifficulty
    public let resultSurfaces: [NFCoreResultSurface]
    public let supportedAdapterIDs: [String]
    public let isLegacy: Bool

    public var fullName: String { "nf-core/\(name)" }
    public var documentationURL: URL { URL(string: "https://nf-co.re/\(name)")! }
    public var defaultParameterValues: [String: String] {
        Dictionary(uniqueKeysWithValues: keyParameters.map { ($0.name, $0.defaultValue) })
            .merging(defaultParams) { _, override in override }
    }

    public init(
        name: String,
        displayName: String,
        description: String,
        pinnedVersion: String,
        whenToUse: String,
        notFor: String,
        requiredInputs: String,
        expectedOutputs: String,
        exampleUseCase: String,
        runButtonTitle: String,
        acceptedInputSuffixes: [String],
        primaryInputParameter: String = "input",
        defaultParams: [String: String] = [:],
        keyParameters: [NFCoreWorkflowParameter] = [],
        difficulty: NFCoreWorkflowDifficulty,
        resultSurfaces: [NFCoreResultSurface],
        supportedAdapterIDs: [String] = ["generic-report"],
        isLegacy: Bool = false
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.pinnedVersion = pinnedVersion
        self.whenToUse = whenToUse
        self.notFor = notFor
        self.requiredInputs = requiredInputs
        self.expectedOutputs = expectedOutputs
        self.exampleUseCase = exampleUseCase
        self.runButtonTitle = runButtonTitle
        self.acceptedInputSuffixes = acceptedInputSuffixes
        self.primaryInputParameter = primaryInputParameter
        self.defaultParams = defaultParams
        self.keyParameters = keyParameters
        self.difficulty = difficulty
        self.resultSurfaces = resultSurfaces
        self.supportedAdapterIDs = supportedAdapterIDs
        self.isLegacy = isLegacy
    }
}

public struct NFCoreWorkflowParameter: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let defaultValue: String
    public let help: String

    public init(name: String, displayName: String, defaultValue: String = "", help: String) {
        self.name = name
        self.displayName = displayName
        self.defaultValue = defaultValue
        self.help = help
    }
}

public enum NFCoreSupportedWorkflowCatalog {
    public static let supportedWorkflows: [NFCoreSupportedWorkflow] = [
        NFCoreSupportedWorkflow(
            name: "viralrecon",
            displayName: "Analyze viral amplicon samples",
            description: "Generate viral consensus sequences, coverage summaries, alignments, and mutation tables.",
            pinnedVersion: "3.0.0",
            whenToUse: "Use this for viral sequencing reads, especially SARS-CoV-2-style amplicon samples, when you want consensus genomes, coverage, and variants.",
            notFor: "Do not use this for whole-organism genomes, RNA-seq, non-viral samples, or generic nanopore QC.",
            requiredInputs: "Choose viral FASTQ reads. A matching viral reference and primer scheme may be required for final analysis.",
            expectedOutputs: "Consensus viral sequences, mapped reads, coverage summaries, variant tables, and QC reports.",
            exampleUseCase: "Example: analyze SARS-CoV-2 amplicon reads to produce a consensus FASTA and variant table for each sample.",
            runButtonTitle: "Run Viral Analysis",
            acceptedInputSuffixes: [".fastq", ".fq", ".fastq.gz", ".fq.gz", ".csv", ".tsv", ".fasta", ".fa", ".fna"],
            difficulty: .easy,
            resultSurfaces: [.referenceBundles, .mappingBundles, .variantTracks, .reports],
            supportedAdapterIDs: ["viralrecon"]
        ),
    ]

    public static let firstWave: [NFCoreSupportedWorkflow] = supportedWorkflows
    public static let legacyWorkflows: [NFCoreSupportedWorkflow] = []
    public static let futureCustomInterfaceWorkflows: [NFCoreSupportedWorkflow] = []

    public static var allCurated: [NFCoreSupportedWorkflow] {
        supportedWorkflows
    }

    public static func workflow(named rawName: String) -> NFCoreSupportedWorkflow? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "nf-core/", with: "")
            .lowercased()
        return supportedWorkflows.first { $0.name == name }
    }
}
