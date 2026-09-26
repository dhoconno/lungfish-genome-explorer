// AnalysisTemplateExtractor.swift - Builds a workflow template from a Kraken2 analysis folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - AnalysisTemplateExtractionError

/// Why an analysis cannot become a template. Every case names the reason;
/// the extractor never guesses a setting it did not find.
public enum AnalysisTemplateExtractionError: Error, LocalizedError, Equatable, Sendable {
    case analysisNotFound(URL)
    case classificationResultMissing(URL)
    case classificationResultUnreadable(URL, String)
    case projectNotFound(URL)
    case batchAnalysis(URL)
    case unsupportedGoal(String)
    case missingOriginalInputFiles
    case separatePairedInputs
    case unexpectedInputCount(expected: Int, found: Int)
    case inputNotFound(String)
    case inputOutsideBundle(String)
    case multipleInputBundles([String])
    case derivedInput(URL)
    case missingImportRecord(URL)
    case unsupportedImportRecord(workflowName: String)
    case missingImportField(String)
    case invalidImportField(name: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .analysisNotFound(let url):
            return "No analysis folder at \(url.path)."
        case .classificationResultMissing(let url):
            return "\(url.lastPathComponent) has no classification-result.json, so LGE cannot read its Kraken2 settings."
        case .classificationResultUnreadable(let url, let reason):
            return "classification-result.json in \(url.lastPathComponent) could not be read: \(reason)"
        case .projectNotFound(let url):
            return "\(url.path) is not inside a project's Analyses folder. Pass the project explicitly."
        case .batchAnalysis(let url):
            return "\(url.lastPathComponent) is a classification batch. Templates in this version repeat steps for one sample at a time."
        case .unsupportedGoal(let goal):
            return "The '\(goal)' goal cannot be repeated from the command line. Only classify and profile analyses can become templates."
        case .separatePairedInputs:
            return "Kraken2 classified this sample as two separate read files. A template classifies the bundle its import step creates, so this analysis cannot become a template in this version."
        case .missingOriginalInputFiles:
            return "The analysis record does not name its original input files, so LGE cannot tell which import it came from."
        case .unexpectedInputCount(let expected, let found):
            return "Expected \(expected) input file\(expected == 1 ? "" : "s") for this read layout but the record lists \(found)."
        case .inputNotFound(let path):
            return "The recorded input \(path) no longer exists, and no matching bundle was found in the project."
        case .inputOutsideBundle(let path):
            return "The input \(path) is not inside a .lungfishfastq bundle, so its import settings are not recorded."
        case .multipleInputBundles(let paths):
            return "The inputs come from more than one bundle (\(paths.joined(separator: ", "))). Templates repeat steps for one sample at a time."
        case .derivedInput(let url):
            return "\(url.lastPathComponent) is a derived bundle. Templates in this version start from a root FASTQ import."
        case .missingImportRecord(let url):
            return "\(url.lastPathComponent) has no import provenance record, so its import settings are not known."
        case .unsupportedImportRecord(let workflowName):
            return "\(workflowName) is not a FASTQ import record. Templates in this version start from 'lungfish import fastq'."
        case .missingImportField(let name):
            return "The import record does not record '\(name)', so that setting cannot be pinned."
        case .invalidImportField(let name, let value):
            return "The import record has an unrecognized value for '\(name)': \(value)."
        }
    }
}

// MARK: - AnalysisTemplateExtractor

/// Builds an ``AnalysisTemplate`` from a Kraken2 analysis directory.
///
/// Source of truth for the Kraken2 settings is `classification-result.json`;
/// for the import settings it is the root FASTQ bundle's provenance sidecar
/// written by `lungfish import fastq`, corroborated by the bundle metadata's
/// `recipeApplied` record.
public struct AnalysisTemplateExtractor: Sendable {

    /// Result of an extraction: the template and its default file name.
    public struct Extraction: Sendable, Equatable {
        public let template: AnalysisTemplate
        public let sourceBundleURL: URL
    }

    /// Looks up an installed recipe by id (injectable for tests).
    public typealias RecipeResolver = @Sendable (String) -> Recipe?

    private let recipeResolver: RecipeResolver
    private let appVersion: String

    public init(
        recipeResolver: @escaping RecipeResolver = { RecipeRegistryV2.recipe(id: $0) },
        appVersion: String = WorkflowRun.currentAppVersion
    ) {
        self.recipeResolver = recipeResolver
        self.appVersion = appVersion
    }

    /// Extracts a template from `analysisURL`.
    ///
    /// - Parameters:
    ///   - analysisURL: A `<project>/Analyses/kraken2-*` directory.
    ///   - projectURL: The project root. When nil it is derived from the
    ///     analysis path (the parent of its `Analyses` folder).
    ///   - name: Template name; defaults to "Kraken2 from <sample>".
    public func extract(
        analysisURL: URL,
        projectURL explicitProjectURL: URL? = nil,
        name: String? = nil
    ) throws -> Extraction {
        let analysisURL = analysisURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: analysisURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AnalysisTemplateExtractionError.analysisNotFound(analysisURL)
        }
        let projectURL = try resolveProjectURL(explicitProjectURL, analysisURL: analysisURL)

        if let metadata = AnalysesFolder.readAnalysisMetadata(from: analysisURL), metadata.isBatch {
            throw AnalysisTemplateExtractionError.batchAnalysis(analysisURL)
        }
        if analysisURL.lastPathComponent.contains("-batch-") {
            throw AnalysisTemplateExtractionError.batchAnalysis(analysisURL)
        }

        let sidecar = try loadClassificationSidecar(in: analysisURL)
        let config = ClassificationResult.resolvingRelativeConfigURLs(sidecar.config, relativeTo: analysisURL)

        let goal: Kraken2StepSpec.Goal
        switch config.goal {
        case .classify: goal = .classify
        case .profile: goal = .profile
        case .extract: throw AnalysisTemplateExtractionError.unsupportedGoal(config.goal.rawValue)
        }

        // A rerun classifies the one bundle the import step creates, which
        // cannot supply the two loose files a paired-format run needs.
        guard config.readFormat != .paired else {
            throw AnalysisTemplateExtractionError.separatePairedInputs
        }
        guard let originalInputs = config.originalInputFiles, !originalInputs.isEmpty else {
            throw AnalysisTemplateExtractionError.missingOriginalInputFiles
        }
        guard originalInputs.count == 1 else {
            throw AnalysisTemplateExtractionError.unexpectedInputCount(expected: 1, found: originalInputs.count)
        }

        var warnings: [String] = []
        let bundleURL = try resolveSourceBundle(for: originalInputs, projectURL: projectURL, warnings: &warnings)
        if FASTQBundle.isDerivedBundle(bundleURL) {
            throw AnalysisTemplateExtractionError.derivedInput(bundleURL)
        }

        guard let envelope = ProvenanceRecorder.loadEnvelope(from: bundleURL) else {
            throw AnalysisTemplateExtractionError.missingImportRecord(bundleURL)
        }
        guard envelope.workflowName == "lungfish import fastq" else {
            throw AnalysisTemplateExtractionError.unsupportedImportRecord(workflowName: envelope.workflowName)
        }
        if envelope.steps.contains(where: { $0.toolName == "lungfish-app" && $0.argv.dropFirst().first == "gui-import" }) {
            warnings.append("The source bundle was copied into the project by the app (gui-import). That copy step cannot be repeated and is not part of the template.")
        }

        let importSpec = try importStep(from: envelope, bundleURL: bundleURL, warnings: &warnings)
        let kraken2Spec = kraken2Step(goal: goal, config: config, sidecar: sidecar, warnings: &warnings)

        let importProvenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let origin = AnalysisTemplate.Origin(
            appVersion: appVersion,
            sourceAnalysisRelativePath: relativePath(of: analysisURL, in: projectURL),
            importProvenanceID: envelope.id,
            classificationProvenanceID: sidecar.provenanceId,
            importProvenanceSHA256: try? AnalysisTemplateHashing.sha256Hex(ofFileAt: importProvenanceURL),
            classificationResultSHA256: try? AnalysisTemplateHashing.sha256Hex(
                ofFileAt: analysisURL.appendingPathComponent(ClassificationResult.sidecarFilename)
            )
        )

        let sampleName = config.sampleDisplayName ?? bundleURL.deletingPathExtension().lastPathComponent
        let template = AnalysisTemplate(
            name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "\(goal == .profile ? "Kraken2 + Bracken" : "Kraken2") from \(sampleName)",
            origin: origin,
            input: AnalysisTemplate.InputSpec(platform: importSpec.platform, pairing: importSpec.pairing),
            steps: [.importFASTQ(importSpec), .kraken2(kraken2Spec)],
            creationWarnings: warnings
        )
        return Extraction(template: template, sourceBundleURL: bundleURL)
    }

    // MARK: - Project resolution

    private func resolveProjectURL(_ explicit: URL?, analysisURL: URL) throws -> URL {
        if let explicit {
            return explicit.standardizedFileURL
        }
        let parent = analysisURL.deletingLastPathComponent()
        guard parent.lastPathComponent == AnalysesFolder.directoryName else {
            throw AnalysisTemplateExtractionError.projectNotFound(analysisURL)
        }
        return parent.deletingLastPathComponent()
    }

    private func relativePath(of url: URL, in projectURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    // MARK: - Classification sidecar

    private func loadClassificationSidecar(in analysisURL: URL) throws -> PersistedClassificationResult {
        let sidecarURL = analysisURL.appendingPathComponent(ClassificationResult.sidecarFilename)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            throw AnalysisTemplateExtractionError.classificationResultMissing(analysisURL)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedClassificationResult.self, from: Data(contentsOf: sidecarURL))
        } catch {
            throw AnalysisTemplateExtractionError.classificationResultUnreadable(analysisURL, error.localizedDescription)
        }
    }

    // MARK: - Source bundle

    /// Finds the single root bundle the recorded inputs live in, re-resolving
    /// the recorded absolute paths under the current project when the project
    /// moved.
    private func resolveSourceBundle(for inputs: [URL], projectURL: URL, warnings: inout [String]) throws -> URL {
        var bundles: [URL] = []
        for input in inputs {
            let resolved = try resolveInput(input, projectURL: projectURL, warnings: &warnings)
            guard let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: resolved) else {
                throw AnalysisTemplateExtractionError.inputOutsideBundle(resolved.path)
            }
            if !bundles.contains(where: { $0.path == bundle.path }) {
                bundles.append(bundle)
            }
        }
        guard bundles.count == 1, let bundle = bundles.first else {
            throw AnalysisTemplateExtractionError.multipleInputBundles(bundles.map(\.lastPathComponent))
        }
        return bundle
    }

    private func resolveInput(_ recorded: URL, projectURL: URL, warnings: inout [String]) throws -> URL {
        let recorded = recorded.standardizedFileURL
        if FileManager.default.fileExists(atPath: recorded.path) {
            return recorded
        }
        // The project may have moved: keep the path from the bundle component
        // onward and look for it under the current project, first under
        // Imports (the importer's home), then at the project root.
        let components = recorded.pathComponents
        guard let bundleIndex = components.lastIndex(where: {
            ($0 as NSString).pathExtension.lowercased() == FASTQBundle.directoryExtension
        }) else {
            throw AnalysisTemplateExtractionError.inputNotFound(recorded.path)
        }
        let tail = components[bundleIndex...].joined(separator: "/")
        let candidates: [URL]
        if let importsIndex = components[..<bundleIndex].lastIndex(of: "Imports") {
            let importsTail = components[importsIndex...].joined(separator: "/")
            candidates = [
                projectURL.appendingPathComponent(importsTail),
                projectURL.appendingPathComponent("Imports").appendingPathComponent(tail),
                projectURL.appendingPathComponent(tail),
            ]
        } else {
            candidates = [
                projectURL.appendingPathComponent("Imports").appendingPathComponent(tail),
                projectURL.appendingPathComponent(tail),
            ]
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.standardizedFileURL.path) {
            warnings.append("The recorded input \(recorded.lastPathComponent) was found at \(candidate.standardizedFileURL.path) instead of its recorded location.")
            return candidate.standardizedFileURL
        }
        throw AnalysisTemplateExtractionError.inputNotFound(recorded.path)
    }

    // MARK: - Import step

    private func importStep(
        from envelope: ProvenanceEnvelope,
        bundleURL: URL,
        warnings: inout [String]
    ) throws -> ImportFASTQStepSpec {
        let explicit = envelope.options.explicit
        let resolved = envelope.options.resolvedDefaults

        func string(_ key: String) throws -> String {
            guard let value = explicit[key]?.stringValue ?? resolved[key]?.stringValue else {
                throw AnalysisTemplateExtractionError.missingImportField(key)
            }
            return value
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = explicit[key]?.booleanValue ?? resolved[key]?.booleanValue else {
                throw AnalysisTemplateExtractionError.missingImportField(key)
            }
            return value
        }

        let platformValue = try string("platform")
        guard let platform = SequencingPlatform(rawValue: platformValue) else {
            throw AnalysisTemplateExtractionError.invalidImportField(name: "platform", value: platformValue)
        }
        let binningValue = try string("qualityBinning")
        guard let qualityBinning = QualityBinningScheme(rawValue: binningValue) else {
            throw AnalysisTemplateExtractionError.invalidImportField(name: "qualityBinning", value: binningValue)
        }
        let clumpingValue = try string("clumpingTool")
        guard let clumpingTool = ClumpingTool(rawValue: clumpingValue) else {
            throw AnalysisTemplateExtractionError.invalidImportField(name: "clumpingTool", value: clumpingValue)
        }
        let compressionValue = try string("compressionLevel")
        guard let compressionLevel = CompressionLevel(rawValue: compressionValue) else {
            throw AnalysisTemplateExtractionError.invalidImportField(name: "compressionLevel", value: compressionValue)
        }
        let optimizeStorage = try boolean("optimizeStorage")
        let pairing = try recordedPairing(resolved: resolved, explicit: explicit)

        let recipeID = try string("recipe")
        let recipe = try recipeSnapshot(
            recordedID: recipeID,
            bundleURL: bundleURL,
            warnings: &warnings
        )

        return ImportFASTQStepSpec(
            platform: platform,
            pairing: pairing,
            qualityBinning: qualityBinning,
            optimizeStorage: optimizeStorage,
            clumpingTool: clumpingTool,
            compressionLevel: compressionLevel,
            recipe: recipe
        )
    }

    /// The pairing to pin. `resolvedDefaults["pairing"]` holds the requested
    /// `--pairing`; when it was `auto`, the layout the import actually
    /// recorded (`outputPairingMode`, with `pairedEndInput` for two files)
    /// decides.
    private func recordedPairing(
        resolved: [String: ParameterValue],
        explicit: [String: ParameterValue]
    ) throws -> AnalysisTemplatePairing {
        guard let requested = resolved["pairing"]?.stringValue ?? explicit["pairing"]?.stringValue else {
            throw AnalysisTemplateExtractionError.missingImportField("pairing")
        }
        switch requested {
        case "single": return .single
        case "paired": return .paired
        case "interleaved": return .interleaved
        case "auto":
            if resolved["pairedEndInput"]?.booleanValue == true || explicit["r2"]?.fileValue != nil {
                return .paired
            }
            guard let mode = resolved["outputPairingMode"]?.stringValue else {
                throw AnalysisTemplateExtractionError.missingImportField("outputPairingMode")
            }
            switch mode {
            case IngestionMetadata.PairingMode.interleaved.rawValue: return .interleaved
            case IngestionMetadata.PairingMode.singleEnd.rawValue: return .single
            case IngestionMetadata.PairingMode.pairedEnd.rawValue: return .paired
            default:
                throw AnalysisTemplateExtractionError.invalidImportField(name: "outputPairingMode", value: mode)
            }
        default:
            throw AnalysisTemplateExtractionError.invalidImportField(name: "pairing", value: requested)
        }
    }

    private func recipeSnapshot(
        recordedID: String,
        bundleURL: URL,
        warnings: inout [String]
    ) throws -> RecipeSnapshot? {
        let applied = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)
            .flatMap { FASTQMetadataStore.load(for: $0)?.ingestion?.recipeApplied }

        var recipeID = recordedID
        var recipeName = applied?.recipeName
        if recordedID == "none" {
            guard let applied else { return nil }
            warnings.append("The import record says no recipe was applied but the bundle metadata records recipe \(applied.recipeName) (\(applied.recipeID)). The template pins that recipe.")
            recipeID = applied.recipeID
        } else if let applied, applied.recipeID != recordedID {
            warnings.append("The import record names recipe \(recordedID) while the bundle metadata records \(applied.recipeID). The template pins the import record's recipe.")
            recipeName = nil
        }

        guard let recipe = recipeResolver(recipeID) else {
            warnings.append("Recipe \(recipeID) is not installed on this Mac, so the template records its id only and cannot check its content at run time. Runs refuse until the recipe is installed, unless drift is allowed.")
            return RecipeSnapshot(id: recipeID, name: recipeName ?? recipeID)
        }
        return try RecipeSnapshot(recipe: recipe)
    }

    // MARK: - Kraken2 step

    private func kraken2Step(
        goal: Kraken2StepSpec.Goal,
        config: ClassificationConfig,
        sidecar: PersistedClassificationResult,
        warnings: inout [String]
    ) -> Kraken2StepSpec {
        let version = config.databaseVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.isEmpty || version == Kraken2StepSpec.DatabaseIdentity.unknownVersion {
            warnings.append("The Kraken2 database version was not recorded when \(config.databaseName) was used, so LGE cannot tell if it changed.")
        }
        if config.databaseDigest == nil {
            warnings.append("The Kraken2 database \(config.databaseName) has no recorded payload digest, so only its name and version are checked at run time.")
        }
        if !config.extraArguments.isEmpty {
            warnings.append("Extra Kraken2 arguments are passed to the tool unchecked: \(config.extraArguments.joined(separator: " "))")
        }
        return Kraken2StepSpec(
            goal: goal,
            database: Kraken2StepSpec.DatabaseIdentity(
                name: config.databaseName,
                version: version.isEmpty ? Kraken2StepSpec.DatabaseIdentity.unknownVersion : version,
                catalogID: config.databaseCatalogID,
                digest: config.databaseDigest
            ),
            readFormat: config.readFormat,
            confidence: config.confidence,
            minimumHitGroups: config.minimumHitGroups,
            memoryMapping: config.memoryMapping,
            quickMode: config.quickMode,
            extraArguments: config.extraArguments,
            bracken: goal == .profile ? (config.brackenProfileRequest ?? .automaticDefault) : nil,
            recordedKraken2Version: sidecar.toolVersion.nonEmpty,
            recordedBrackenVersion: sidecar.profileOutcome?.toolVersion
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
