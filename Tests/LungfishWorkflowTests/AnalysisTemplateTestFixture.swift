// AnalysisTemplateTestFixture.swift - Synthetic project for workflow template tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Builds a throwaway project with one imported FASTQ bundle (with import
/// provenance and bundle metadata) and one Kraken2 analysis folder whose
/// `classification-result.json` is modelled on
/// `Tests/Fixtures/kraken2-bracken-reopen/`. No tools run.
struct AnalysisTemplateTestFixture {
    let rootURL: URL
    let projectURL: URL
    let bundleURL: URL
    let fastqURL: URL
    let analysisURL: URL

    struct ImportOptions {
        var platform = "illumina"
        var recipe = "vsp2-target-enrichment"
        var qualityBinning = "illumina4"
        var optimizeStorage = true
        var clumpingTool = "auto"
        var compressionLevel = "balanced"
        /// The requested `--pairing`.
        var pairing = "auto"
        var pairedEndInput = true
        var outputPairingMode = "interleaved"
        var recipeApplied: (id: String, name: String)? = ("vsp2-target-enrichment", "VSP2 Target Enrichment")
        var includeGUIImportStep = false
        var workflowName = "lungfish import fastq"
        var writeProvenance = true
    }

    struct ClassificationOptions {
        var goal = "profile"
        var databaseName = "Viral"
        var databaseVersion = "20260626"
        var databaseCatalogID: String? = "kraken2-viral"
        var databaseDigest: String? = nil
        var confidence = 0.2
        var minimumHitGroups = 2
        var interleavedInput = true
        var isPairedEnd = false
        var memoryMapping = false
        var quickMode = false
        var extraArguments: [String] = []
        var threads = 4
        var includeOriginalInputFiles = true
        /// Overrides the recorded original input paths (absolute). Nil records the fixture's FASTQ.
        var originalInputFiles: [String]? = nil
        var includeBracken = true
        var toolVersion = "2.17.1"
        var brackenVersion: String? = "3.0.1"
        var isBatch = false
    }

    static let sampleRecipe = Recipe(
        id: "vsp2-target-enrichment",
        name: "VSP2 Target Enrichment",
        platforms: [.illumina],
        requiredInput: .paired,
        qualityBinning: .illumina4,
        steps: [RecipeStep(type: "fastp-dedup", label: "Remove PCR duplicates", params: nil)]
    )

    static func make(
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

    func cleanup() {
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
