// AnalysisTemplateTestFixture.swift - Synthetic project for workflow template tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// Builds a throwaway project with one imported FASTQ bundle (with import
/// provenance and bundle metadata) and one Kraken2 analysis folder whose
/// `classification-result.json` is modelled on
/// `Tests/Fixtures/kraken2-bracken-reopen/`. No tools run.
public struct AnalysisTemplateTestFixture: Sendable {
    public let rootURL: URL
    public let projectURL: URL
    public let bundleURL: URL
    public let fastqURL: URL
    public let analysisURL: URL

    public struct ImportOptions: Sendable {
        public init() {}
        public var platform = "illumina"
        public var recipe = "vsp2-target-enrichment"
        public var qualityBinning = "illumina4"
        public var optimizeStorage = true
        public var clumpingTool = "auto"
        public var compressionLevel = "balanced"
        /// The requested `--pairing`.
        public var pairing = "auto"
        public var pairedEndInput = true
        public var outputPairingMode = "interleaved"
        public var recipeApplied: (id: String, name: String)? = ("vsp2-target-enrichment", "VSP2 Target Enrichment")
        public var includeGUIImportStep = false
        public var workflowName = "lungfish import fastq"
        public var writeProvenance = true
    }

    public struct ClassificationOptions: Sendable {
        public init() {}
        public var goal = "profile"
        public var databaseName = "Viral"
        public var databaseVersion = "20260626"
        public var databaseCatalogID: String? = "kraken2-viral"
        public var databaseDigest: String? = nil
        public var confidence = 0.2
        public var minimumHitGroups = 2
        public var interleavedInput = true
        public var isPairedEnd = false
        public var memoryMapping = false
        public var quickMode = false
        public var extraArguments: [String] = []
        public var threads = 4
        public var includeOriginalInputFiles = true
        /// Overrides the recorded original input paths (absolute). Nil records the fixture's FASTQ.
        public var originalInputFiles: [String]? = nil
        public var includeBracken = true
        public var toolVersion = "2.17.1"
        public var brackenVersion: String? = "3.0.1"
        public var isBatch = false
    }

    /// A small recipe in the built-in VSP2 shape, decoded from JSON so no
    /// internal initializer is needed.
    public static let sampleRecipe: Recipe = {
        let json = """
        {"formatVersion": 1, "id": "vsp2-target-enrichment", "name": "VSP2 Target Enrichment",
         "platforms": ["illumina"], "requiredInput": "paired", "qualityBinning": "illumina4",
         "steps": [{"type": "fastp-dedup", "label": "Remove PCR duplicates"}]}
        """
        // A literal that fails to decode is a programming error in the fixture itself.
        return try! JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }()

    /// `sampleRecipe` with one more step, for hash-mismatch tests.
    public static let changedRecipe: Recipe = {
        let json = """
        {"formatVersion": 1, "id": "vsp2-target-enrichment", "name": "VSP2 Target Enrichment",
         "platforms": ["illumina"], "requiredInput": "paired", "qualityBinning": "illumina4",
         "steps": [{"type": "fastp-dedup", "label": "Remove PCR duplicates"}, {"type": "fastp-trim", "label": "Trim"}]}
        """
        return try! JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
    }()

    public static func make(
        sampleName: String = "SRRTEST1",
        importOptions: ImportOptions = ImportOptions(),
        classification: ClassificationOptions = ClassificationOptions()
    ) throws -> AnalysisTemplateTestFixture {
        let root = try TestTempDirectory.make(prefix: "analysis-template")
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundleURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("\(sampleName).lungfishfastq", isDirectory: true)
        let fastqURL = bundleURL.appendingPathComponent("\(sampleName).fastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("@r1/1\nACGT\n+\n!!!!\n@r1/2\nTTGA\n+\n!!!!\n".utf8).write(to: fastqURL)

        if importOptions.writeProvenance {
            try writeImportProvenance(bundleURL: bundleURL, fastqURL: fastqURL, projectURL: projectURL, options: importOptions)
        }
        if let applied = importOptions.recipeApplied {
            var metadata = PersistedFASTQMetadata()
            metadata.ingestion = IngestionMetadata(
                isClumpified: true,
                isCompressed: true,
                pairingMode: .interleaved,
                pairingSource: .detected,
                qualityBinning: importOptions.qualityBinning,
                originalFilenames: ["\(sampleName)_R1.fastq.gz", "\(sampleName)_R2.fastq.gz"],
                recipeApplied: RecipeAppliedInfo(recipeID: applied.id, recipeName: applied.name, stepResults: [])
            )
            FASTQMetadataStore.save(metadata, for: fastqURL)
        }

        let analysesURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let analysisName = classification.isBatch ? "kraken2-batch-2026-09-25T04-36-28" : "kraken2-2026-09-25T04-36-28"
        let analysisURL = analysesURL.appendingPathComponent(analysisName, isDirectory: true)
        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: classification.isBatch),
            to: analysisURL
        )
        try writeClassificationResult(analysisURL: analysisURL, fastqURL: fastqURL, sampleName: sampleName, options: classification)
        try Data("100.00\t2\t2\tU\t0\tunclassified\n".utf8).write(to: analysisURL.appendingPathComponent("classification.kreport"))

        return AnalysisTemplateTestFixture(
            rootURL: root,
            projectURL: projectURL,
            bundleURL: bundleURL,
            fastqURL: fastqURL,
            analysisURL: analysisURL
        )
    }

    public func cleanup() {
        TestTempDirectory.cleanup(rootURL)
    }

    // MARK: - Import provenance

    private static func writeImportProvenance(
        bundleURL: URL,
        fastqURL: URL,
        projectURL: URL,
        options: ImportOptions
    ) throws {
        let r1 = URL(fileURLWithPath: "/data/reads/\(fastqURL.deletingPathExtension().lastPathComponent)_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/reads/\(fastqURL.deletingPathExtension().lastPathComponent)_R2.fastq.gz")
        let argv = ["lungfish", "import", "fastq", r1.path, r2.path, "--project", projectURL.path]
        var explicit: [String: ParameterValue] = [
            "platform": .string(options.platform),
            "recipe": .string(options.recipe),
            "qualityBinning": .string(options.qualityBinning),
            "optimizeStorage": .boolean(options.optimizeStorage),
            "clumpingTool": .string(options.clumpingTool),
            "compressionLevel": .string(options.compressionLevel),
            "threads": .integer(4),
            "r1": .file(r1),
            "r2": options.pairedEndInput ? .file(r2) : .null,
        ]
        if !options.pairedEndInput {
            explicit["r2"] = .null
        }
        var resolved = explicit
        resolved["pairing"] = .string(options.pairing)
        resolved["pairedEndInput"] = .boolean(options.pairedEndInput)
        resolved["outputPairingMode"] = .string(options.outputPairingMode)

        var builder = ProvenanceRunBuilder(
            workflowName: options.workflowName,
            workflowVersion: "Lungfish test",
            toolName: options.workflowName,
            toolVersion: "Lungfish test"
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(explicit: explicit, defaults: [:], resolved: resolved)
        .runtime(ProvenanceRuntimeIdentity())
        builder = try builder.output(fastqURL, format: .fastq, role: .output)
        if options.includeGUIImportStep {
            builder = builder.step(ProvenanceStep(
                toolName: "lungfish-app",
                toolVersion: "Lungfish test",
                argv: ["lungfish-app", "gui-import", "/Users/someone/Desktop/reads.fastq.gz", bundleURL.path],
                exitStatus: 0
            ))
        }
        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    // MARK: - Classification sidecar

    private static func writeClassificationResult(
        analysisURL: URL,
        fastqURL: URL,
        sampleName: String,
        options: ClassificationOptions
    ) throws {
        var config: [String: Any] = [
            "confidence": options.confidence,
            "databaseName": options.databaseName,
            "databasePath": "database",
            "databaseVersion": options.databaseVersion,
            "goal": options.goal,
            "inputFiles": [fastqURL.absoluteString],
            "interleavedInput": options.interleavedInput,
            "isPairedEnd": options.isPairedEnd,
            "memoryMapping": options.memoryMapping,
            "minimumHitGroups": options.minimumHitGroups,
            "outputDirectory": ".",
            "quickMode": options.quickMode,
            "sampleDisplayName": sampleName,
            "threads": options.threads,
        ]
        if let catalogID = options.databaseCatalogID { config["databaseCatalogID"] = catalogID }
        if let digest = options.databaseDigest { config["databaseDigest"] = digest }
        if !options.extraArguments.isEmpty { config["extraArguments"] = options.extraArguments }
        if options.includeOriginalInputFiles {
            // Absolute paths are stored the way Codable stores a URL: as file URLs.
            config["originalInputFiles"] = (options.originalInputFiles ?? [fastqURL.path]).map {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0).absoluteString : $0
            }
        }
        if options.includeBracken {
            config["brackenProfileRequest"] = ["rank": ["automatic": [:]], "readLength": 150, "threshold": 10]
        }

        var sidecar: [String: Any] = [
            "config": config,
            "outputPath": "classification.kraken",
            "reportPath": "classification.kreport",
            "provenanceId": "34EB0DCF-6C3D-4074-9785-16A316741465",
            "runtime": 18.0,
            "savedAt": "2026-09-25T04:36:47Z",
            "toolVersion": options.toolVersion,
        ]
        if options.includeBracken {
            sidecar["brackenPath"] = "classification.bracken"
            var outcome: [String: Any] = [
                "state": "completed",
                "resolution": [
                    "rank": "S", "readLength": 150, "request": ["automatic": [:]],
                    "source": "catalogIdentity", "threshold": 10,
                ],
            ]
            if let brackenVersion = options.brackenVersion {
                outcome["toolVersion"] = brackenVersion
            }
            sidecar["profileOutcome"] = outcome
        }
        let data = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: analysisURL.appendingPathComponent("classification-result.json"))
    }
}
