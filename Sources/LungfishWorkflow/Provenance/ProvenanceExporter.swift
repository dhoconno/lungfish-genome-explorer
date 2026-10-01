// ProvenanceExporter.swift - Export provenance records to reproducible scripts
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - ProvenanceExportFormat

/// Supported provenance export formats.
public enum ProvenanceExportFormat: String, CaseIterable, Sendable {
    case shell = "Shell Script"
    case python = "Python Script"
    case nextflow = "Nextflow Pipeline"
    case snakemake = "Snakemake Workflow"
    case methods = "Methods Section"
    case json = "Full Provenance (JSON)"

    /// File extension for this export format.
    public var fileExtension: String {
        switch self {
        case .shell: return "sh"
        case .python: return "py"
        case .nextflow: return "nf"
        case .snakemake: return "smk"
        case .methods: return "txt"
        case .json: return "json"
        }
    }

    /// Default filename for this export format.
    public var defaultFilename: String {
        switch self {
        case .shell: return "reproduce.sh"
        case .python: return "reproduce.py"
        case .nextflow: return "main.nf"
        case .snakemake: return "Snakefile"
        case .methods: return "methods.txt"
        case .json: return "provenance.json"
        }
    }

    public var cliToken: String {
        switch self {
        case .shell: return "shell"
        case .python: return "python"
        case .nextflow: return "nextflow"
        case .snakemake: return "snakemake"
        case .methods: return "methods"
        case .json: return "json"
        }
    }

    public static func cliValue(_ value: String) throws -> ProvenanceExportFormat {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "shell", "sh", "bash", ProvenanceExportFormat.shell.rawValue.lowercased():
            return .shell
        case "python", "py", ProvenanceExportFormat.python.rawValue.lowercased():
            return .python
        case "nextflow", "nf", ProvenanceExportFormat.nextflow.rawValue.lowercased():
            return .nextflow
        case "snakemake", "snakefile", ProvenanceExportFormat.snakemake.rawValue.lowercased():
            return .snakemake
        case "methods", "methods.md", "method", ProvenanceExportFormat.methods.rawValue.lowercased():
            return .methods
        case "json", "provenance.json", ProvenanceExportFormat.json.rawValue.lowercased():
            return .json
        default:
            throw ProvenanceError.exportFailed(
                "Unsupported provenance export format '\(value)'. Supported formats: shell, python, nextflow, snakemake, methods, json."
            )
        }
    }
}

public struct ProvenanceExportBundle: Sendable, Equatable {
    public let rootURL: URL
    public let primaryArtifactURL: URL
    public let copiedSidecarURLs: [URL]
    public let signedReportArtifactURLs: [URL]

    public init(
        rootURL: URL,
        primaryArtifactURL: URL,
        copiedSidecarURLs: [URL],
        signedReportArtifactURLs: [URL] = []
    ) {
        self.rootURL = rootURL
        self.primaryArtifactURL = primaryArtifactURL
        self.copiedSidecarURLs = copiedSidecarURLs
        self.signedReportArtifactURLs = signedReportArtifactURLs
    }
}

// MARK: - ProvenanceExporter

/// Generates reproducible scripts from provenance records.
///
/// Each export method takes a `WorkflowRun` and produces a self-contained
/// script that can reproduce the analysis on any system with the same
/// tools installed (or via containers).
public struct ProvenanceExporter: Sendable {
    private let signingProvider: (any ProvenanceSigningProvider)?

    public init(signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider()) {
        self.signingProvider = signingProvider
    }
    public func exportBundle(
        _ envelope: ProvenanceEnvelope,
        format: ProvenanceExportFormat,
        to outputDirectory: URL,
        sourceSidecarURL: URL?,
        sourceRootURL: URL? = nil,
        exportArgv: [String] = []
    ) throws -> ProvenanceExportBundle {
        let startedAt = Date()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let chainExpansion = expandProvenanceChain(
            startingWith: envelope,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL
        )
        let expandedEnvelope = chainExpansion.envelope
        let run = expandedEnvelope.legacyWorkflowRun(preferCanonicalSteps: true)
        let plan = exportPlan(run)
        let primaryArtifactURL: URL
        var generatedArtifactURLs: [URL] = []
        switch format {
        case .shell:
            primaryArtifactURL = outputDirectory.appendingPathComponent("run.sh")
            try exportShell(run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
            try makeExecutable(primaryArtifactURL)
        case .python:
            primaryArtifactURL = outputDirectory.appendingPathComponent("reproduce.py")
            try exportPython(run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
            try makeExecutable(primaryArtifactURL)
        case .nextflow:
            primaryArtifactURL = outputDirectory.appendingPathComponent("main.nf")
            try exportNextflow(run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
            let nextflowConfigURL = outputDirectory.appendingPathComponent("nextflow.config")
            try exportNextflowConfig(run).write(
                to: nextflowConfigURL,
                atomically: true,
                encoding: .utf8
            )
            let containersDirectory = outputDirectory.appendingPathComponent("containers", isDirectory: true)
            try fileManager.createDirectory(at: containersDirectory, withIntermediateDirectories: true)
            let containerManifestURL = containersDirectory.appendingPathComponent("manifest.json")
            try exportContainerManifest(run).write(
                to: containerManifestURL,
                atomically: true,
                encoding: .utf8
            )
            generatedArtifactURLs.append(contentsOf: [nextflowConfigURL, containerManifestURL])
        case .snakemake:
            primaryArtifactURL = outputDirectory.appendingPathComponent("Snakefile")
            try exportSnakemake(run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
            let configURL = outputDirectory.appendingPathComponent("config.yaml")
            try exportSnakemakeConfig(run).write(
                to: configURL,
                atomically: true,
                encoding: .utf8
            )
            generatedArtifactURLs.append(configURL)
            generatedArtifactURLs.append(contentsOf: try writeEnvironmentFiles(plan, in: outputDirectory))
        case .methods:
            primaryArtifactURL = outputDirectory.appendingPathComponent("methods.md")
            try exportMethods(run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
        case .json:
            primaryArtifactURL = outputDirectory.appendingPathComponent("provenance.json")
            let data = try ProvenanceJSON.encoder.encode(expandedEnvelope)
            try data.write(to: primaryArtifactURL, options: .atomic)
        }
        generatedArtifactURLs.insert(primaryArtifactURL, at: 0)
        let signedReportArtifactURLs = try signReportArtifacts(generatedArtifactURLs)

        let provenanceDirectory = outputDirectory.appendingPathComponent("provenance", isDirectory: true)
        try fileManager.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)
        let copiedSourceArtifacts = try copySourceArtifacts(
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL,
            outputDirectory: outputDirectory,
            provenanceDirectory: provenanceDirectory,
            additionalSourceURLs: chainExpansion.sourceArtifactURLs
        )
        let exportSidecarURL = try writeExportProvenanceSidecar(
            format: format,
            outputDirectory: outputDirectory,
            provenanceDirectory: provenanceDirectory,
            sourceInputURL: sourceRootURL ?? sourceSidecarURL,
            sourceArtifacts: copiedSourceArtifacts,
            generatedArtifactURLs: generatedArtifactURLs + signedReportArtifactURLs,
            argv: exportArgv,
            startedAt: startedAt,
            endedAt: Date()
        )
        return ProvenanceExportBundle(
            rootURL: outputDirectory,
            primaryArtifactURL: primaryArtifactURL,
            copiedSidecarURLs: [exportSidecarURL] + copiedSourceArtifacts
                .map(\.destinationURL)
                .filter(isProvenanceOrSignatureArtifact),
            signedReportArtifactURLs: signedReportArtifactURLs
        )
    }

    /// One conda environment file per managed tool the export runs, for
    /// the Snakefile's `conda:` directives.
    private func writeEnvironmentFiles(_ plan: ProvenanceExportPlan, in outputDirectory: URL) throws -> [URL] {
        var urls: [URL] = []
        for environment in plan.environments {
            let url = outputDirectory.appendingPathComponent(environment.environmentFileName)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try environment.environmentFileContents.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        return urls
    }

    private struct ProvenanceChainExpansion {
        let envelope: ProvenanceEnvelope
        let sourceArtifactURLs: [URL]
    }

    /// The record with every record that fed it merged in, upstream first,
    /// and the sidecars and manifests that back the merged record.
    private func expandProvenanceChain(
        startingWith envelope: ProvenanceEnvelope,
        sourceSidecarURL: URL?,
        sourceRootURL: URL?
    ) -> ProvenanceChainExpansion {
        let runs = ProvenanceLineageResolver().resolve(
            envelope: envelope,
            sidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL
        )
        var sourceArtifactURLs: [URL] = []
        for run in runs {
            if let sidecarURL = run.sidecarURL {
                let standardized = sidecarURL.standardizedFileURL
                sourceArtifactURLs.append(standardized)
                sourceArtifactURLs.append(contentsOf: pairedSigningArtifacts(for: standardized))
            }
            sourceArtifactURLs.append(contentsOf: run.supportingURLs)
        }
        return ProvenanceChainExpansion(
            envelope: mergeProvenanceChain(runs.map(\.envelope), fallback: envelope),
            sourceArtifactURLs: uniqueExistingURLs(sourceArtifactURLs)
        )
    }

    private func mergeProvenanceChain(
        _ envelopes: [ProvenanceEnvelope],
        fallback: ProvenanceEnvelope
    ) -> ProvenanceEnvelope {
        guard envelopes.count > 1 else { return fallback }

        let mergedFiles = uniqueFileDescriptors(envelopes.flatMap(\.files))
        let mergedSteps = uniqueSteps(envelopes.flatMap { envelope -> [ProvenanceStep] in
            envelope.steps.isEmpty
                ? envelope.legacyWorkflowRun(preferCanonicalSteps: true).steps.map { ProvenanceStep(stepExecution: $0) }
                : envelope.steps
        })

        return ProvenanceEnvelope(
            schemaVersion: fallback.schemaVersion,
            id: fallback.id,
            createdAt: envelopes.first?.createdAt ?? fallback.createdAt,
            workflowName: fallback.workflowName,
            workflowVersion: fallback.workflowVersion,
            toolName: fallback.toolName,
            toolVersion: fallback.toolVersion,
            tool: fallback.tool,
            argv: fallback.argv,
            durableReplayArgv: fallback.durableReplayArgv,
            reproducibleCommand: fallback.reproducibleCommand,
            options: fallback.options,
            runtimeIdentity: fallback.runtimeIdentity,
            files: mergedFiles,
            output: fallback.output,
            outputs: fallback.outputs,
            steps: mergedSteps,
            wallTimeSeconds: fallback.wallTimeSeconds,
            exitStatus: fallback.exitStatus,
            stderr: fallback.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private func uniqueFileDescriptors(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue):\(descriptor.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(descriptor)
        }
        return result
    }

    /// Steps once each: by id, and by shape for the copies of one record
    /// that were loaded with fresh ids.
    private func uniqueSteps(_ steps: [ProvenanceStep]) -> [ProvenanceStep] {
        var seenIDs = Set<UUID>()
        var seenShapes = Set<String>()
        var result: [ProvenanceStep] = []
        for step in steps where seenIDs.insert(step.id).inserted {
            let shape = step.toolName + "\u{1}" + step.argv.joined(separator: "\u{2}") + "\u{1}"
                + step.outputs.map { $0.checksumSHA256 ?? $0.path }.joined(separator: "\u{2}")
            guard seenShapes.insert(shape).inserted else { continue }
            result.append(step)
        }
        return result
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Exports a workflow run in the specified format.
    public func export(_ run: WorkflowRun, format: ProvenanceExportFormat) throws -> String {
        switch format {
        case .shell: return exportShell(run)
        case .python: return exportPython(run)
        case .nextflow: return exportNextflow(run)
        case .snakemake: return exportSnakemake(run)
        case .methods: return exportMethods(run)
        case .json: return try exportJSON(run)
        }
    }

    private func exportShell(_ envelope: ProvenanceEnvelope, fallbackRun: WorkflowRun) -> String {
        exportShell(fallbackRun)
    }

    private func signReportArtifacts(_ urls: [URL]) throws -> [URL] {
        guard let signingProvider else {
            return []
        }

        var artifacts: [URL] = []
        for url in urls {
            let artifact = try signingProvider.sign(provenanceURL: url)
            artifacts.append(artifact.signatureURL)
            artifacts.append(artifact.publicKeyURL)
            if signingProvider.providerIdentifier == ProvenanceSigningConfiguration.localProviderID {
                _ = try ProvenanceSignatureVerifier.verify(provenanceURL: url)
            }
        }
        return artifacts
    }

    private struct CopiedSourceArtifact {
        let sourceURL: URL
        let destinationURL: URL
    }

    private func writeExportProvenanceSidecar(
        format: ProvenanceExportFormat,
        outputDirectory: URL,
        provenanceDirectory: URL,
        sourceInputURL: URL?,
        sourceArtifacts: [CopiedSourceArtifact],
        generatedArtifactURLs: [URL],
        argv: [String],
        startedAt: Date,
        endedAt: Date
    ) throws -> URL {
        var builder = ProvenanceRunBuilder(
            workflowName: "provenance.export.\(format.cliToken)",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish provenance export",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(
            exportArgv(
                provided: argv,
                sourceInputURL: sourceInputURL,
                format: format,
                outputDirectory: outputDirectory
            )
        )
        .options(
            explicit: exportOptions(
                sourceInputURL: sourceInputURL,
                format: format,
                outputDirectory: outputDirectory
            ),
            defaults: [
                "preserveSourceProvenance": .boolean(true)
            ],
            resolved: [
                "preserveSourceProvenance": .boolean(true)
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())

        for artifact in sourceArtifacts {
            builder = try builder.input(artifact.sourceURL)
        }
        for outputURL in generatedArtifactURLs + sourceArtifacts.map(\.destinationURL) {
            builder = try builder.output(outputURL)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return try ProvenanceWriter(signingProvider: signingProvider).write(envelope, to: provenanceDirectory)
    }

    private func exportArgv(
        provided argv: [String],
        sourceInputURL: URL?,
        format: ProvenanceExportFormat,
        outputDirectory: URL
    ) -> [String] {
        if !argv.isEmpty { return argv }
        var arguments = [CLICommandIdentity.executableName, "provenance", "export"]
        if let sourceInputURL {
            arguments.append(sourceInputURL.path)
        }
        arguments.append(contentsOf: ["--export-format", format.cliToken, "--output", outputDirectory.path])
        return arguments
    }

    private func exportOptions(
        sourceInputURL: URL?,
        format: ProvenanceExportFormat,
        outputDirectory: URL
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "exportFormat": .string(format.cliToken),
            "output": .file(outputDirectory)
        ]
        if let sourceInputURL {
            options["input"] = .file(sourceInputURL)
        }
        return options
    }

    private func copySourceArtifacts(
        sourceSidecarURL: URL?,
        sourceRootURL: URL?,
        outputDirectory: URL,
        provenanceDirectory: URL,
        additionalSourceURLs: [URL] = []
    ) throws -> [CopiedSourceArtifact] {
        let fileManager = FileManager.default
        let sourceDestinationRoot = provenanceDirectory.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceDestinationRoot, withIntermediateDirectories: true)

        let sourceURLs = try sourceArtifactURLs(
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL,
            outputDirectory: outputDirectory
        ) + additionalSourceURLs

        return try uniqueExistingURLs(sourceURLs).map { sourceURL in
            let destinationURL = sourceArtifactDestination(
                for: sourceURL,
                sourceRootURL: sourceRootURL,
                sourceDestinationRoot: sourceDestinationRoot
            )
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            return CopiedSourceArtifact(sourceURL: sourceURL, destinationURL: destinationURL)
        }
    }

    private func sourceArtifactURLs(
        sourceSidecarURL: URL?,
        sourceRootURL: URL?,
        outputDirectory: URL
    ) throws -> [URL] {
        let fileManager = FileManager.default
        var sidecars: [URL] = []
        var manifests: [URL] = []

        if let sourceRootURL, isDirectory(sourceRootURL) {
            let root = sourceRootURL.standardizedFileURL
            if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in enumerator {
                    let standardizedURL = url.standardizedFileURL
                    guard !isDescendant(standardizedURL, of: outputDirectory.standardizedFileURL),
                          try isRegularFile(standardizedURL) else {
                        continue
                    }
                    if isProvenanceSidecar(standardizedURL) {
                        sidecars.append(standardizedURL)
                    } else if isSourceManifest(standardizedURL) {
                        manifests.append(standardizedURL)
                    }
                }
            }
        }

        if let sourceSidecarURL {
            sidecars.append(sourceSidecarURL.standardizedFileURL)
        }

        var artifacts = sidecars.flatMap { sidecar -> [URL] in
            [sidecar] + pairedSigningArtifacts(for: sidecar)
        }
        artifacts.append(contentsOf: manifests)
        return uniqueExistingURLs(artifacts)
    }

    private func pairedSigningArtifacts(for sidecarURL: URL) -> [URL] {
        [
            ProvenanceSigningConfiguration.signatureURL(for: sidecarURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: sidecarURL)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func sourceArtifactDestination(
        for sourceURL: URL,
        sourceRootURL: URL?,
        sourceDestinationRoot: URL
    ) -> URL {
        if let sourceRootURL {
            if !isDirectory(sourceRootURL),
               shouldPreserveFileRootArtifactByName(sourceURL, sourceRootURL: sourceRootURL) {
                return sourceDestinationRoot.appendingPathComponent(sourceURL.lastPathComponent)
            }
            if let relativePath = relativePath(for: sourceURL, relativeTo: sourceRootURL) {
                return sourceDestinationRoot.appendingPathComponent(relativePath)
            }
        }
        let components = sourceURL.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else {
            return sourceDestinationRoot.appendingPathComponent(sourceURL.lastPathComponent)
        }
        return components.reduce(
            sourceDestinationRoot.appendingPathComponent("external", isDirectory: true)
        ) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
    }

    private func shouldPreserveFileRootArtifactByName(_ sourceURL: URL, sourceRootURL: URL) -> Bool {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedRootURL = sourceRootURL.standardizedFileURL
        if standardizedSourceURL == standardizedRootURL {
            return true
        }
        return standardizedSourceURL == ProvenanceRecorder.fileSidecarURL(for: standardizedRootURL).standardizedFileURL
    }

    private func relativePath(for url: URL, relativeTo root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents),
              urlComponents.count > rootComponents.count else {
            return nil
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func uniqueExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true
    }

    private func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        return urlComponents.starts(with: rootComponents) && urlComponents.count > rootComponents.count
    }

    private func isProvenanceSidecar(_ url: URL) -> Bool {
        let filename = url.lastPathComponent
        return filename == ProvenanceRecorder.provenanceFilename
            || filename == MappingProvenance.filename
            || filename == "annotation-edit-provenance.json"
            || filename == "manual-annotation-provenance.json"
            || filename == "extraction-metadata.json"
            || (filename == "provenance.json"
                && url.deletingLastPathComponent().lastPathComponent == "assembly")
            || filename.hasSuffix(".lungfish-provenance.json")
            || filename.hasSuffix("-provenance.json")
    }

    private func isSourceManifest(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        return filename == "manifest.json"
            || filename.hasSuffix(".manifest.json")
            || filename.hasSuffix("-manifest.json")
    }

    private func isProvenanceOrSignatureArtifact(_ url: URL) -> Bool {
        isProvenanceSidecar(url)
            || url.lastPathComponent.hasSuffix(".signature.json")
            || url.lastPathComponent.hasSuffix(".pub")
    }
    // MARK: - Plan

    /// The export-ready shape of `run`: staging collapsed, pipes joined,
    /// executables bare, paths portable. See `ProvenanceExportPlan`.
    func exportPlan(_ run: WorkflowRun) -> ProvenanceExportPlan {
        ProvenanceExportPlan(run: run, replayArguments: replayArguments)
    }

    private func exportNextflowConfig(_ run: WorkflowRun) -> String {
        let plan = exportPlan(run)
        var s = ""
        s += "process {\n"
        s += "    errorStrategy = 'terminate'\n"
        s += "}\n\n"
        s += "// Managed tools are recreated from their recorded package pins.\n"
        s += "conda.enabled = true\n"
        if plan.steps.contains(where: { $0.containerImage != nil }) {
            s += "docker.enabled = true\n"
        }
        return s
    }

    private func exportContainerManifest(_ run: WorkflowRun) throws -> String {
        struct ContainerEntry: Encodable {
            let toolName: String
            let toolVersion: String
            let image: String
            let digest: String?
        }
        let entries = exportPlan(run).steps.compactMap { step -> ContainerEntry? in
            guard let image = step.containerImage else { return nil }
            return ContainerEntry(
                toolName: step.toolName,
                toolVersion: step.identity.version,
                image: image,
                digest: step.containerDigest
            )
        }
        let data = try ProvenanceJSON.encoder.encode(entries)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProvenanceError.exportFailed("Failed to encode container manifest as UTF-8")
        }
        return string
    }

    private func exportSnakemakeConfig(_ run: WorkflowRun) -> String {
        let plan = exportPlan(run)
        let graph = WorkflowExportGraph(plan: plan)
        var s = ""
        s += "# The .lungfish project the recorded inputs live in. Run snakemake from\n"
        s += "# inside the project, pass --directory, or set this to the project's path.\n"
        s += "project: \".\"\n"
        s += "outdir: results\n"
        for name in graph.parameterFilenames {
            guard let path = graph.parameterPath(for: name) else { continue }
            s += "\(graph.parameterName(for: name)): \(pythonDoubleQuoted(snakemakeConfigValue(path)))\n"
        }
        return s
    }

    /// A parameter's default in `config.yaml`: relative to the project, or
    /// the recorded path when the file lay outside it.
    private func snakemakeConfigValue(_ path: ProvenanceExportPlan.MappedPath) -> String {
        switch path {
        case .project(let tail): return tail
        case .result(let relative): return relative
        case .external(let recorded), .verbatim(let recorded): return recorded
        }
    }

    // MARK: - Header notes

    /// The lines every executable export opens with after the run's name:
    /// unresolved paths, collapsed staging, in-app steps.
    private func headerNotes(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        var s = unresolvedPathNote(plan, prefix: prefix)
        s += externalInputNote(plan, prefix: prefix)
        s += collapsedStepNote(plan, prefix: prefix)
        s += inAppStepNote(plan, prefix: prefix)
        return s
    }

    /// The environment block for the script exports: how to recreate each
    /// managed tool from its recorded pin.
    private func environmentNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        guard !plan.environments.isEmpty else { return "" }
        var s = "\(prefix)\n"
        s += "\(prefix)Tools. Each managed tool ran from a conda environment with the package\n"
        s += "\(prefix)pinned below. Create the environments once and put them on PATH\n"
        s += "\(prefix)(for example, activate them) before running this script:\n"
        for environment in plan.environments {
            s += "\(prefix)  \(environment.micromambaCreateCommand)\n"
        }
        return s
    }

    // MARK: - Shell Script Export

    /// Generates a Bash script that reproduces the workflow.
    public func exportShell(_ run: WorkflowRun) -> String {
        if let unavailable = unavailableReplayReason(run) { return unavailableReplayScript(unavailable, format: .shell) }
        let plan = exportPlan(run)
        var s = ""
        s += "#!/usr/bin/env bash\n"
        s += "#\n"
        s += "# \(run.name)\n"
        s += "# Generated by \(run.appVersion)\n"
        s += "# Original run: \(iso8601(run.startTime))\n"
        s += "# Host: \(run.hostOS)\n"
        if let user = run.runtime.user {
            s += "# User: \(user)\n"
        }
        s += headerNotes(plan, prefix: "# ")
        s += environmentNote(plan, prefix: "# ")
        s += "#\n"
        s += "# This script reproduces the analysis performed in Lungfish. Paths are\n"
        s += "# relative to the .lungfish project; run it from inside the project or\n"
        s += "# set LUNGFISH_PROJECT to the project's location.\n"
        s += "#\n"
        s += "set -euo pipefail\n\n"
        s += "PROJECT=\"${LUNGFISH_PROJECT:-.}\"\n"
        s += "OUTDIR=\"${OUTDIR:-results}\"\n"
        s += "mkdir -p \"$OUTDIR\"\n\n"

        let inputs = plan.primaryInputs
        if !inputs.isEmpty {
            s += "# Input files\n"
            for (i, input) in inputs.enumerated() {
                s += "INPUT_\(i + 1)=\(shellToken(shellSpelling(plan.map(input.path))))"
                if let sha = input.sha256 {
                    s += "  # sha256: \(sha)"
                }
                s += "\n"
            }
            s += "\n"
        }

        for step in plan.replayableSteps {
            s += "# Step \(stepNumbers(step)): \(step.identity.displayLabel)"
            if let environment = step.environment {
                s += " (conda environment \(environment.name))"
            }
            s += "\n"
            if let image = step.containerImage {
                s += "# Container: \(image)\n"
                if let digest = step.containerDigest {
                    s += "# Digest: \(digest)\n"
                }
            }
            if let wallTime = step.wallTime {
                s += "# Wall time: \(formatDuration(wallTime))\n"
            }
            s += plan.commandLine(for: step, spell: shellSpelling, escape: shellToken)
            s += "\n\n"
        }

        s += "echo \"Pipeline complete.\"\n"
        return s
    }

    /// `$PROJECT/...` and `$OUTDIR/...` for the shell script.
    private func shellSpelling(_ path: ProvenanceExportPlan.MappedPath) -> String {
        switch path {
        case .project(let tail): return tail.isEmpty ? "$PROJECT" : "$PROJECT/\(tail)"
        case .result(let relative):
            return "$OUTDIR/" + relative.dropFirst("results/".count)
        case .external(let recorded), .verbatim(let recorded): return recorded
        }
    }

    /// A shell token that keeps `$PROJECT` and `$OUTDIR` expandable.
    private func shellToken(_ value: String) -> String {
        guard value.contains("$PROJECT") || value.contains("$OUTDIR") else { return shellEscape(value) }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@+,$"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    private func stepNumbers(_ step: ProvenanceExportPlan.Step) -> String {
        step.numbers.count == 1
            ? "\(step.number)"
            : step.numbers.map(String.init).joined(separator: " and ")
    }

    // MARK: - Python Script Export

    /// Generates a Python script using subprocess to reproduce the workflow.
    public func exportPython(_ run: WorkflowRun) -> String {
        if let unavailable = unavailableReplayReason(run) { return unavailableReplayScript(unavailable, format: .python) }
        let plan = exportPlan(run)
        var s = ""
        s += "#!/usr/bin/env python3\n"
        s += "\"\"\"\n"
        s += "\(run.name)\n"
        s += "Generated by \(run.appVersion)\n"
        s += "Original run: \(iso8601(run.startTime))\n"
        s += "Host: \(run.hostOS)\n"
        if let user = run.runtime.user {
            s += "User: \(user)\n"
        }
        s += unresolvedPathNote(plan, prefix: "")
        s += environmentNote(plan, prefix: "")
        s += "\n"
        s += "This script reproduces the analysis performed in Lungfish. Paths are\n"
        s += "relative to the .lungfish project; run it from inside the project or\n"
        s += "set LUNGFISH_PROJECT to the project's location.\n"
        s += "\"\"\"\n"
        s += collapsedStepNote(plan, prefix: "# ")
        s += inAppStepNote(plan, prefix: "# ")
        s += "\n"
        s += "import os\n"
        s += "import shlex\n"
        s += "import subprocess\n"
        s += "import sys\n"
        s += "from pathlib import Path\n\n"
        s += "PROJECT = Path(os.environ.get(\"LUNGFISH_PROJECT\", \".\"))\n"
        s += "OUTDIR = Path(os.environ.get(\"OUTDIR\", \"results\"))\n"
        s += "OUTDIR.mkdir(parents=True, exist_ok=True)\n\n"

        let inputs = plan.primaryInputs
        if !inputs.isEmpty {
            s += "# Input files\n"
            s += "INPUTS = {\n"
            for input in inputs {
                s += "    \(pythonDoubleQuoted(input.filename)): \(pythonDoubleQuoted(input.sha256 ?? "unknown")),  # sha256\n"
            }
            s += "}\n\n"
        }

        s += "def run_step(name: str, command: str) -> None:\n"
        s += "    \"\"\"Run one pipeline step through the shell and stop on failure.\"\"\"\n"
        s += "    print(f\"Running: {name}\")\n"
        s += "    result = subprocess.run(command, shell=True, capture_output=True, text=True)\n"
        s += "    if result.returncode != 0:\n"
        s += "        print(f\"ERROR in {name}: {result.stderr}\", file=sys.stderr)\n"
        s += "        sys.exit(result.returncode)\n"
        s += "    print(f\"  Done ({name})\")\n\n\n"

        for step in plan.replayableSteps {
            let stepName = "step_\(step.number)_\(sanitize(step.toolName))"
            s += "def \(stepName)():\n"
            s += "    \"\"\"\(step.identity.displayLabel)"
            if let environment = step.environment {
                s += " (conda environment \(environment.name))"
            }
            if let image = step.containerImage {
                s += " (container: \(image))"
            }
            s += "\"\"\"\n"
            s += "    run_step(\(pythonDoubleQuoted(step.toolName)), \" \".join([\n"
            for (index, command) in step.commands.enumerated() {
                if index > 0 {
                    s += "        \"|\",\n"
                }
                for token in command.argv {
                    s += "        \(pythonShellToken(plan.rewrite(token: token, spell: pythonSpelling))),\n"
                }
                if let stdoutPath = command.stdoutPath {
                    s += "        \">\",\n"
                    s += "        \(pythonShellToken(pythonSpelling(plan.map(stdoutPath)))),\n"
                }
            }
            s += "    ]))\n\n\n"
        }

        s += "if __name__ == \"__main__\":\n"
        s += "    print(\(pythonDoubleQuoted("Reproducing: " + run.name)))\n"
        for step in plan.replayableSteps {
            s += "    step_\(step.number)_\(sanitize(step.toolName))()\n"
        }
        s += "    print(\"Pipeline complete.\")\n"

        return s
    }

    private static let pythonProjectMarker = "\u{1}P:"
    private static let pythonResultMarker = "\u{1}R:"

    /// Marks a portable path inside a token so `pythonShellToken` can turn it
    /// into a `PROJECT / ...` or `OUTDIR / ...` expression.
    private func pythonSpelling(_ path: ProvenanceExportPlan.MappedPath) -> String {
        switch path {
        case .project(let tail): return Self.pythonProjectMarker + tail + "\u{1}"
        case .result(let relative): return Self.pythonResultMarker + relative.dropFirst("results/".count) + "\u{1}"
        case .external(let recorded), .verbatim(let recorded): return recorded
        }
    }

    /// A Python expression for one shell token: a plain quoted literal
    /// (already shell-escaped), or `shlex.quote(...)` of a path expression.
    private func pythonShellToken(_ token: String) -> String {
        guard token.contains("\u{1}") else { return pythonDoubleQuoted(shellEscape(token)) }
        var parts: [String] = []
        var remaining = Substring(token)
        while let start = remaining.firstIndex(of: "\u{1}") {
            let literal = String(remaining[..<start])
            if !literal.isEmpty { parts.append(pythonDoubleQuoted(literal)) }
            let afterMarker = remaining[remaining.index(after: start)...]
            guard let kindEnd = afterMarker.firstIndex(of: ":"),
                  let end = afterMarker[afterMarker.index(after: kindEnd)...].firstIndex(of: "\u{1}") else { break }
            let kind = afterMarker[..<kindEnd]
            let value = String(afterMarker[afterMarker.index(after: kindEnd) ..< end])
            let root = kind == "P" ? "PROJECT" : "OUTDIR"
            parts.append(value.isEmpty ? "str(\(root))" : "str(\(root) / \(pythonDoubleQuoted(value)))")
            remaining = afterMarker[afterMarker.index(after: end)...]
        }
        if !remaining.isEmpty { parts.append(pythonDoubleQuoted(String(remaining))) }
        return "shlex.quote(" + parts.joined(separator: " + ") + ")"
    }

    // MARK: - Nextflow Export

    /// Generates a Nextflow DSL2 pipeline from the provenance record.
    public func exportNextflow(_ run: WorkflowRun) -> String {
        if let unavailable = unavailableReplayReason(run) { return unavailableReplayScript(unavailable, format: .nextflow) }
        let plan = exportPlan(run)
        let replayable = plan.replayableSteps.flatMap(\.sourceSteps)
        if !replayable.isEmpty, replayable.allSatisfy(isRetainedSelectionReplay) {
            // These receipts authorize exact byte copies to recorded paths, not
            // reconstruction of an analytical DAG in Nextflow's scratch space.
            let command = replayable.map(portableCommand).joined(separator: "\n")
            return """
            #!/usr/bin/env nextflow
            // Retained-selection snapshot byte replay; does not rerun upstream analysis.
            \(inAppStepNote(plan, prefix: "// "))nextflow.enable.dsl = 2
            process REPLAY_RETAINED_SELECTION {
                cache false
                script:
                \(groovyDoubleQuoted(command))
            }
            workflow {
                REPLAY_RETAINED_SELECTION()
            }

            """
        }
        var s = ""
        s += "#!/usr/bin/env nextflow\n"
        s += "/*\n"
        s += " * \(run.name)\n"
        s += " * Generated by \(run.appVersion)\n"
        s += " * Original run: \(iso8601(run.startTime))\n"
        s += " * Host: \(run.hostOS)\n"
        if let user = run.runtime.user {
            s += " * User: \(user)\n"
        }
        s += headerNotes(plan, prefix: " * ")
        s += " *\n"
        s += " * Each process stages its inputs by file name and runs the recorded\n"
        s += " * command on them. Managed tools carry their recorded conda pin; run\n"
        s += " * with `nextflow run main.nf` (conda.enabled is set in nextflow.config).\n"
        s += " */\n\n"
        s += "nextflow.enable.dsl = 2\n\n"

        // The DAG is wired by file name: a process reads each input from the
        // most recent earlier process that wrote a file of that name, and
        // from a params channel when no earlier process wrote it.
        let graph = WorkflowExportGraph(plan: plan)

        s += "// Pipeline parameters. Relative paths are resolved against the\n"
        s += "// .lungfish project named by params.project.\n"
        s += "params.project = '.'\n"
        for name in graph.parameterFilenames {
            let value = graph.parameterPath(for: name).map(snakemakeConfigValue) ?? name
            s += "params.\(graph.parameterName(for: name)) = \(groovySingleQuoted(value))\n"
        }
        s += "params.outdir = './results'\n\n"
        s += "def projectFile(path) {\n"
        s += "    path.startsWith('/') ? path : \"${params.project}/${path}\"\n"
        s += "}\n\n"

        for node in graph.nodes {
            let step = node.step
            s += "/*\n"
            s += " * Step \(stepNumbers(step)): \(step.identity.displayLabel)\n"
            if let wallTime = step.wallTime {
                s += " * Original wall time: \(formatDuration(wallTime))\n"
            }
            s += " */\n"
            s += "process \(node.nextflowProcessName) {\n"

            if let image = step.containerImage {
                s += "    container '\(image)'\n"
            } else if let environment = step.environment {
                s += "    conda \(groovySingleQuoted(environment.packageSpec ?? environment.name))\n"
            }

            s += "    publishDir params.outdir, mode: 'copy'\n\n"

            if !node.inputFilenames.isEmpty {
                s += "    input:\n"
                for input in node.inputFilenames {
                    s += "    path \(groovySingleQuoted(input))\n"
                }
                s += "\n"
            }

            if !node.outputFilenames.isEmpty {
                s += "    output:\n"
                for output in node.outputFilenames {
                    s += "    path \(groovySingleQuoted(output))\n"
                }
                s += "\n"
            }

            s += "    script:\n"
            let command = plan.commandLine(for: step, spell: { $0.filename }, escape: shellEscape)
            s += "    \(groovyDoubleQuoted(command))\n\n"

            // A stub lets `nextflow run -stub-run` walk the whole DAG without
            // the tools or the data, which is how an export is checked
            // before it is sent.
            s += "    stub:\n"
            if node.outputFilenames.isEmpty {
                s += "    \"true\"\n"
            } else {
                let touch = "touch " + node.outputFilenames.map(shellEscape).joined(separator: " ")
                s += "    \(groovyDoubleQuoted(touch))\n"
            }
            s += "}\n\n"
        }

        s += "// Main workflow\n"
        s += "workflow {\n"
        for name in graph.parameterFilenames {
            let paramName = graph.parameterName(for: name)
            s += "    \(paramName)_ch = channel.fromPath(projectFile(params.\(paramName)))\n"
        }
        if !graph.parameterFilenames.isEmpty {
            s += "\n"
        }
        for node in graph.nodes {
            let arguments = node.inputFilenames.map { input -> String in
                switch graph.source(of: input, before: node) {
                case .process(let producer, let outputIndex):
                    return "\(producer.nextflowProcessName).out[\(outputIndex)]"
                case .parameter:
                    return "\(graph.parameterName(for: input))_ch"
                }
            }
            s += "    \(node.nextflowProcessName)(\(arguments.joined(separator: ", ")))\n"
        }
        s += "}\n"
        return s
    }

    // MARK: - Snakemake Export

    /// Generates a Snakefile from the provenance record.
    public func exportSnakemake(_ run: WorkflowRun) -> String {
        if let unavailable = unavailableReplayReason(run) { return unavailableReplayScript(unavailable, format: .snakemake) }
        let plan = exportPlan(run)
        let replayable = plan.replayableSteps.flatMap(\.sourceSteps)
        if !replayable.isEmpty, replayable.allSatisfy(isRetainedSelectionReplay) {
            // No wildcard declarations: braces and newlines are literal argv.
            // This first rule has no outputs, so replay runs on every invocation.
            var script = "# Retained-selection snapshot byte replay; does not rerun upstream analysis.\n"
            script += inAppStepNote(plan, prefix: "# ")
            script += "import subprocess\n\nrule replay_retained_selection:\n    run:\n"
            for step in replayable {
                let arguments = (replayArguments(step) ?? []).map(pythonDoubleQuoted).joined(separator: ", ")
                script += "        subprocess.run([\(arguments)], check=True)\n"
            }
            return script
        }
        var s = ""
        s += "# \(run.name)\n"
        s += "# Generated by \(run.appVersion)\n"
        s += "# Original run: \(iso8601(run.startTime))\n"
        s += "# Host: \(run.hostOS)\n"
        if let user = run.runtime.user {
            s += "# User: \(user)\n"
        }
        s += headerNotes(plan, prefix: "# ")
        s += "#\n"
        s += "# Inputs are read from the .lungfish project named by config['project']\n"
        s += "# (default: the working directory). Managed tools are recreated from\n"
        s += "# the recorded package pins in envs/.\n"
        s += "#\n"
        s += "# Usage: snakemake --cores 8 --software-deployment-method conda \\\n"
        s += "#            --directory \"/path/to/Project.lungfish\"\n\n"

        s += "import os\n\n"
        s += "configfile: os.path.join(workflow.basedir, \"config.yaml\")\n\n\n"
        s += "def project(relative):\n"
        s += "    \"\"\"A file inside the .lungfish project, or an absolute path as given.\"\"\"\n"
        s += "    return os.path.normpath(os.path.join(config.get(\"project\", \".\"), relative))\n\n\n"

        let graph = WorkflowExportGraph(plan: plan)
        let parameterNames = Dictionary(
            graph.parameterFilenames.map { ($0, graph.parameterName(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )

        s += "rule all:\n"
        s += "    input:\n"
        for output in graph.finalOutputPaths {
            s += "        \(snakemakeExpression(output, parameterNames: [:])),\n"
        }
        s += "\n\n"

        for node in graph.nodes {
            let step = node.step
            let ruleName = node.snakemakeRuleName

            s += "# Step \(stepNumbers(step)): \(step.identity.displayLabel)"
            if let environment = step.environment, let spec = environment.packageSpec {
                s += " (\(spec))"
            }
            s += "\n"
            if let wallTime = step.wallTime {
                s += "# Original wall time: \(formatDuration(wallTime))\n"
            }

            s += "rule \(ruleName):\n"

            if !node.inAppInputPaths.isEmpty {
                let names = node.inAppInputPaths.map { snakemakeConfigValue($0) }.joined(separator: ", ")
                s += "    # Also reads \(names), made by an in-app step this workflow does not replay.\n"
            }
            // Files a parameter provides are read through config so a
            // collaborator can point one elsewhere with --config.
            let inputKeys = snakemakeKeys(for: node.inputPaths)
            if !node.inputPaths.isEmpty {
                s += "    input:\n"
                for (path, key) in zip(node.inputPaths, inputKeys) {
                    let isParameter = graph.source(of: path.filename, before: node).isParameter
                    let expression = snakemakeExpression(path, parameterNames: isParameter ? parameterNames : [:])
                    s += "        \(key)=\(expression),\n"
                }
            }

            // A step never produces its own input, and a file several steps
            // record as their output belongs to the earliest rule only.
            let outputKeys = snakemakeKeys(for: node.uniqueOutputPaths)
            if !node.uniqueOutputPaths.isEmpty {
                s += "    output:\n"
                for (path, key) in zip(node.uniqueOutputPaths, outputKeys) {
                    s += "        \(key)=\(snakemakeExpression(path, parameterNames: [:])),\n"
                }
            }

            s += "    log:\n"
            s += "        \"logs/\(ruleName).log\"\n"

            if let image = step.containerImage {
                s += "    container:\n"
                s += "        \"docker://\(image)\"\n"
            } else if let environment = step.environment {
                s += "    conda:\n"
                s += "        \(pythonDoubleQuoted(environment.environmentFileName))\n"
            }

            s += "    shell:\n"
            var placeholders: [ProvenanceExportPlan.MappedPath: String] = [:]
            for (path, key) in zip(node.inputPaths, inputKeys) { placeholders[path] = "{input.\(key)}" }
            for (path, key) in zip(node.uniqueOutputPaths, outputKeys) { placeholders[path] = "{output.\(key)}" }
            let command = plan.commandLine(
                for: step,
                spell: { path in
                    if let placeholder = placeholders[path] { return Self.snakemakePlaceholderMarker + placeholder + Self.snakemakePlaceholderMarker }
                    switch path {
                    case .project(let tail):
                        let root = Self.snakemakePlaceholderMarker + "{config[project]}" + Self.snakemakePlaceholderMarker
                        return tail.isEmpty ? root : root + "/" + tail
                    case .result(let relative): return relative
                    case .external(let recorded), .verbatim(let recorded): return recorded
                    }
                },
                escape: snakemakeShellToken
            )
            let shell = "mkdir -p \"$(dirname {log:q})\"\n" + command + " 2> {log:q}"
            s += "        \(pythonDoubleQuoted(shell))\n\n"
        }

        return s
    }

    private static let snakemakePlaceholderMarker = "\u{2}"

    /// A shell token for a Snakemake rule: literal braces doubled, Snakemake
    /// placeholders kept, and a token that expands the project path quoted
    /// so a folder name with spaces survives.
    private func snakemakeShellToken(_ value: String) -> String {
        let marker = Self.snakemakePlaceholderMarker
        guard value.contains(marker) else {
            return shellEscape(value)
                .replacingOccurrences(of: "{", with: "{{")
                .replacingOccurrences(of: "}", with: "}}")
        }
        var result = ""
        var isPlaceholder = false
        for part in value.components(separatedBy: marker) {
            if isPlaceholder {
                result += part
            } else {
                result += part
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "$", with: "\\$")
                    .replacingOccurrences(of: "{", with: "{{")
                    .replacingOccurrences(of: "}", with: "}}")
            }
            isPlaceholder.toggle()
        }
        // {input.x} is quoted by Snakemake only with :q; the project path may
        // hold spaces, so every expanded token is double-quoted.
        return "\"\(result)\""
    }

    /// The Python expression naming a portable path in a rule.
    private func snakemakeExpression(
        _ path: ProvenanceExportPlan.MappedPath,
        parameterNames: [String: String]
    ) -> String {
        if let parameter = parameterNames[path.filename] {
            return "project(config[\(pythonDoubleQuoted(parameter))])"
        }
        switch path {
        case .project(let tail): return tail.isEmpty ? "config.get(\"project\", \".\")" : "project(\(pythonDoubleQuoted(tail)))"
        case .result(let relative): return pythonDoubleQuoted(relative)
        case .external(let recorded), .verbatim(let recorded): return pythonDoubleQuoted(recorded)
        }
    }

    /// Keyword names for a rule's inputs or outputs, from the file names,
    /// made unique.
    private func snakemakeKeys(for paths: [ProvenanceExportPlan.MappedPath]) -> [String] {
        var used = Set<String>()
        return paths.map { path in
            var key = WorkflowExportGraph.sanitize(path.filename.replacingOccurrences(of: ".", with: "_"))
            if key.isEmpty { key = "file" }
            var candidate = key
            var counter = 2
            while !used.insert(candidate).inserted {
                candidate = "\(key)_\(counter)"
                counter += 1
            }
            return candidate
        }
    }

    // MARK: - Methods Section Export

    /// Generates publication-ready methods text from the provenance record.
    public func exportMethods(_ run: WorkflowRun) -> String {
        let plan = exportPlan(run)
        var s = ""
        s += "<!-- This is an automatically-generated draft. Read it before submitting. -->\n\n"
        s += "Methods\n"
        s += "=======\n\n"
        s += "Computational Analysis\n"
        s += "----------------------\n\n"

        var sentences: [String] = []
        if plan.steps.contains(where: { $0.sourceSteps.contains(where: isRetainedSelectionReplay) }) {
            sentences.append("The selected export bytes were retained with checksummed selection metadata. Reproduction uses retained-selection snapshot byte replay and does not rerun upstream analysis.")
        }
        for group in methodsToolGroups(plan) {
            sentences.append(methodsSentence(for: group))
        }
        s += sentences.joined(separator: " ") + "\n\n"

        s += "Tool Versions\n"
        s += "-------------\n\n"
        s += "| Tool | Version | Package | Environment |\n"
        s += "|------|---------|---------|-------------|\n"
        for group in methodsToolGroups(plan) {
            let identity = methodsIdentity(for: group)
            let package = identity.environment?.packageSpec ?? ""
            let environment: String
            if let image = group.steps[0].containerImage {
                environment = "container \(image)"
            } else if let managed = identity.environment {
                environment = "conda environment \(managed.name)"
            } else {
                environment = "native"
            }
            s += "| \(group.toolName) | \(identity.version) | \(package) | \(environment) |\n"
        }
        s += "\n"

        s += "Input Files\n"
        s += "-----------\n\n"
        for input in plan.primaryInputs {
            s += "- \(input.filename)"
            if let sha = input.sha256 {
                s += " (SHA-256: \(sha))"
            }
            s += "\n"
        }
        s += "\n"

        s += "Reproducibility\n"
        s += "---------------\n\n"
        if plan.steps.contains(where: { $0.sourceSteps.contains(where: isRetainedSelectionReplay) }) {
            s += "Retained-selection replay copies the recorded export bytes; the original GUI action remains audit history. "
        }
        s += "This recorded workflow used \(run.appVersion) on \(run.hostOS). "
        let inAppSteps = plan.inAppSteps
        if let unavailable = unavailableReplayReason(run) {
            s += "\(unavailable) A machine-readable audit record is available; no executable reproduction is claimed.\n"
        } else {
            s += "A machine-readable provenance record is available in the supplementary materials. "
            s += "The tool steps are available as executable pipeline scripts (Nextflow, Snakemake, and shell). "
            if !plan.collapsed.isEmpty {
                s += "Lungfish staged its inputs into a scratch folder before running the tools; "
                s += "those internal copies are omitted here and the scripts read the sources directly. "
            }
            for step in inAppSteps {
                s += "Step \(stepNumbers(step)) (\(inAppStepLabel(step))) is an in-app action recorded for audit only; "
                s += "the scripts do not reproduce its outputs. "
            }
            s += "\n"
        }

        return s
    }

    private struct MethodsToolGroup {
        let toolName: String
        let steps: [ProvenanceExportPlan.Step]
    }

    /// Successful tool steps grouped by tool, in first-appearance order.
    /// Plumbing (a decompression) and Lungfish's own steps are left out. A
    /// pipe of two different tools counts once for each tool.
    private func methodsToolGroups(_ plan: ProvenanceExportPlan) -> [MethodsToolGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var groups: [String: [ProvenanceExportPlan.Step]] = [:]
        for step in plan.steps where step.kind == .tool && step.isSuccess && !step.isPlumbing {
            for tool in Self.toolNames(of: step) {
                let key = tool.lowercased()
                if groups[key] == nil {
                    order.append(key)
                    names[key] = tool
                }
                if groups[key]?.contains(where: { $0.number == step.number }) != true {
                    groups[key, default: []].append(step)
                }
            }
        }
        return order.map { MethodsToolGroup(toolName: names[$0] ?? $0, steps: groups[$0] ?? []) }
    }

    /// The recorded tool name of each command in a step: the step's own name
    /// for one command, the names on either side of the pipe otherwise.
    private static func toolNames(of step: ProvenanceExportPlan.Step) -> [String] {
        guard step.commands.count > 1 else { return [step.toolName] }
        let parts = step.toolName.components(separatedBy: " | ")
        if parts.count == step.commands.count { return parts }
        return step.commands.map { URL(fileURLWithPath: $0.argv.first ?? step.toolName).lastPathComponent }
    }

    /// One sentence per tool: what it did, which subcommands ran, the
    /// version and pin, and the parameters worth reporting.
    private func methodsSentence(for group: MethodsToolGroup) -> String {
        let identity = methodsIdentity(for: group)
        let tool = group.toolName
        var verbs: [String] = []
        for step in group.steps {
            let names = Self.toolNames(of: step)
            for (command, name) in zip(step.commands, names) where name.lowercased() == tool.lowercased() {
                if command.argv.count >= 2, !command.argv[1].hasPrefix("-"), !command.argv[1].contains("/"),
                   !command.argv[1].contains("=") {
                    let verb = "\(tool) \(command.argv[1])"
                    if !verbs.contains(verb) { verbs.append(verb) }
                }
            }
        }
        var sentence = "\(methodsOperation(tool: tool, subcommands: verbs)) with \(tool) \(identity.displayVersion)"
        var identityNotes: [String] = []
        if let spec = identity.environment?.packageSpec { identityNotes.append(spec) }
        if let environment = identity.environment { identityNotes.append("conda environment \(environment.name)") }
        if let image = group.steps[0].containerImage {
            identityNotes.append("container \(image)" + (group.steps[0].containerDigest.map { ", digest \($0)" } ?? ""))
        }
        if !identityNotes.isEmpty {
            sentence += " (\(identityNotes.joined(separator: "; ")))"
        }
        if verbs.count > 1 || (verbs.count == 1 && !sentence.contains(verbs[0])) {
            sentence += ", using \(listed(verbs))"
        }
        let parameters = uniqueValues(group.steps.flatMap { step in
            step.commands.flatMap { extractKeyParameters(tool: tool, argv: $0.argv) }
        })
        if !parameters.isEmpty {
            sentence += ", with \(listed(parameters))"
        }
        return sentence + "."
    }

    /// The group's identity, preferring a step that recorded the package
    /// pin over one that recorded the version alone.
    private func methodsIdentity(for group: MethodsToolGroup) -> ProvenanceToolIdentityText {
        group.steps.first { $0.identity.environment?.packageSpec != nil }?.identity
            ?? group.steps.first { $0.identity.environment != nil }?.identity
            ?? group.steps[0].identity
    }

    private func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// The subject of a tool's methods sentence.
    private func methodsOperation(tool: String, subcommands: [String]) -> String {
        let verbs = Set(subcommands.map { $0.split(separator: " ").last.map(String.init) ?? "" })
        switch tool.lowercased() {
        case "bcftools":
            if verbs.contains("mpileup") || verbs.contains("call") {
                return verbs.contains("view") || verbs.contains("filter")
                    ? "Variants were called and filtered"
                    : "Variants were called"
            }
            return "Variant files were processed"
        case "samtools":
            if verbs.contains("sort") || verbs.contains("index") { return "Alignments were filtered, sorted and indexed" }
            if verbs.contains("faidx") { return "The reference was indexed" }
            return "Alignments were processed"
        case "bgzip": return "Files were block-compressed"
        case "tabix": return "Compressed files were indexed"
        case "bedtobigbed": return "BED files were converted to BigBed"
        case "bedgraphtobigwig": return "Signal tracks were converted to BigWig"
        case "fastp": return "Reads were quality-filtered and trimmed"
        case "fastqc": return "Read quality was assessed"
        case "multiqc": return "Quality reports were aggregated"
        case "bwa", "bwa-mem2": return "Reads were aligned"
        case "minimap2": return "Reads were mapped to the reference"
        case "spades", "spades.py": return "Reads were assembled de novo"
        case "seqkit": return "Sequences were summarized"
        case "vsearch": return "Sequences were clustered"
        case "cutadapt": return "Adapters were trimmed"
        case "bbduk.sh", "bbduk": return "Reads were quality-filtered and adapters removed"
        case "bbmerge.sh", "bbmerge": return "Paired reads were merged"
        case "clumpify.sh", "clumpify": return "Reads were clumped and deduplicated"
        case "pigz", "gzip": return "Files were compressed"
        default: return "Processing was performed"
        }
    }

    // MARK: - JSON Export

    /// Exports the full provenance record as formatted JSON.
    public func exportJSON(_ run: WorkflowRun) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProvenanceError.exportFailed("Failed to encode JSON as UTF-8")
        }
        return string
    }

    // MARK: - Helpers

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return "\(hours)h \(mins)m"
        }
    }

    private func sanitize(_ name: String) -> String {
        WorkflowExportGraph.sanitize(name)
    }

    private func groovySingleQuoted(_ value: String) -> String {
        "'" + escapedControlCharacters(value)
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func groovyDoubleQuoted(_ value: String) -> String {
        "\"" + escapedControlCharacters(value)
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$") + "\""
    }

    private func pythonDoubleQuoted(_ value: String) -> String {
        "\"" + escapedControlCharacters(value).replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func escapedControlCharacters(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func isRetainedSelectionReplay(_ step: StepExecution) -> Bool {
        step.resolvedOptions?["replayScope"]?.stringValue == "retained-selection snapshot byte replay"
            && step.durableReplayArgv?.count == 3
            && step.durableReplayArgv?.first == "/bin/cp"
    }

    /// Audit command fields remain unchanged. Renderers share this replay selection.
    private func replayArguments(_ step: StepExecution) -> [String]? {
        let args = step.durableReplayArgv ?? step.command
        guard let executable = args.first, !executable.isEmpty else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        let guiNames = ["lungfish.app", "lungfish-app", "lungfish-gui", "lungfish genome explorer"]
        guard !guiNames.contains(name) else { return nil }
        if ["sh", "bash", "zsh"].contains(name), args.count >= 3,
           ["-c", "-lc"].contains(args[1]),
           let first = try? AdvancedCommandLineOptions.parse(args[2]).first,
           guiNames.contains(URL(fileURLWithPath: first).lastPathComponent.lowercased()) {
            return nil
        }
        return args
    }

    /// Comment lines naming the recorded paths that could not be resolved
    /// on this machine: `<external>/...` files lay outside the project when
    /// the run was recorded, and `<workspace>/...` scratch files are gone.
    private func unresolvedPathNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        guard !plan.unresolvedPaths.isEmpty else { return "" }
        var lines = "\(prefix)\n"
        lines += "\(prefix)Some recorded paths were outside the project or in a deleted scratch\n"
        lines += "\(prefix)folder, so only their file names were kept. Replace each <external>/...\n"
        lines += "\(prefix)or <workspace>/... path with the file's location before running.\n"
        return lines
    }

    /// Comment lines naming the inputs that lay outside the project when the
    /// run was recorded, which a recipient must point at their own copies.
    private func externalInputNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        let external = plan.parameters.compactMap { parameter -> String? in
            guard case .external(let recorded) = parameter.path,
                  !PortablePath.containsUnresolvedPlaceholder(recorded) else { return nil }
            return recorded
        }
        guard !external.isEmpty else { return "" }
        var lines = "\(prefix)\n"
        lines += "\(prefix)These inputs were outside the project when the run was recorded, so\n"
        lines += "\(prefix)their paths are the recording machine's. Point each at your own copy:\n"
        for path in external {
            lines += "\(prefix)  \(path)\n"
        }
        return lines
    }

    /// One comment line for the staging steps folded away.
    private func collapsedStepNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        guard !plan.collapsed.isEmpty else { return "" }
        let numbers = plan.collapsed.map { String($0.number) }
        let label = numbers.count == 1 ? "Step \(numbers[0])" : "Steps \(listed(numbers))"
        return "\(prefix)\(label) staged inputs into a scratch folder (an internal Lungfish action); "
            + "the commands below read the sources directly.\n"
    }

    /// Names an in-app step by its tool and recorded action, such as
    /// `Lungfish.app prepare-mapping-viewer-bundle`.
    private func inAppStepLabel(_ step: ProvenanceExportPlan.Step) -> String {
        var args = step.commands.first?.argv ?? step.recordedArgv
        if let first = args.first, ["sh", "bash", "zsh"].contains(URL(fileURLWithPath: first).lastPathComponent.lowercased()),
           args.count >= 3, ["-c", "-lc"].contains(args[1]),
           let parsed = try? AdvancedCommandLineOptions.parse(args[2]) {
            args = parsed
        }
        guard args.count >= 2, !args[1].hasPrefix("-") else { return step.toolName }
        if args[0] == "lungfish-internal" {
            return "lungfish-internal \(args[1])"
        }
        return "\(step.toolName) \(args[1])"
    }

    /// One comment line per in-app step an executable export leaves out.
    private func inAppStepNote(_ plan: ProvenanceExportPlan, prefix: String) -> String {
        plan.inAppSteps.map {
            "\(prefix)Step \(stepNumbers($0)) (\(inAppStepLabel($0))) is an in-app action and is not replayed; "
                + "its outputs are not produced by this script.\n"
        }.joined()
    }

    /// Replay is refused only when no recorded step is executable. A run that
    /// mixes tool steps with in-app actions exports the tool steps and names
    /// the in-app ones.
    private func unavailableReplayReason(_ run: WorkflowRun) -> String? {
        guard let step = run.steps.first, exportPlan(run).replayableSteps.isEmpty else { return nil }
        return "Replay unavailable: \(step.toolName) records a historical GUI action or has no executable argv."
    }

    private func unavailableReplayScript(_ reason: String, format: ProvenanceExportFormat) -> String {
        switch format {
        case .shell:
            return "#!/usr/bin/env bash\nprintf '%s\\n' \(shellEscape(reason)) >&2\nexit 1\n"
        case .python, .snakemake:
            return "raise RuntimeError(\(pythonDoubleQuoted(reason)))\n"
        case .nextflow:
            return "nextflow.enable.dsl = 2\nerror \(groovySingleQuoted(reason))\n"
        default:
            return reason + "\n"
        }
    }

    private func portableCommand(_ step: StepExecution) -> String {
        (replayArguments(step) ?? []).map(shellEscape).joined(separator: " ")
    }

    /// Human-readable parameters worth a methods sentence, from one command.
    private func extractKeyParameters(tool: String, argv: [String]) -> [String] {
        var params: [String] = []
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            let next: String? = index + 1 < argv.count ? argv[index + 1] : nil
            defer { index += 1 }
            guard arg.hasPrefix("-") else { continue }
            switch arg {
            case "-q", "--qualified_quality_phred":
                if tool.lowercased() == "samtools", let next { params.append("minimum mapping quality of \(next)") }
                else if let next { params.append("minimum quality score of \(next)") }
            case "-l", "--length_required":
                if let next { params.append("minimum length of \(next) bp") }
            case "--memory":
                if let next { params.append("\(next) GB memory") }
            case "--ploidy":
                if let next { params.append("ploidy \(next)") }
            case "-x":
                if tool.lowercased() == "minimap2", let next { params.append("preset \(next)") }
            case "-F":
                if tool.lowercased() == "samtools", let next { params.append("excluding flag \(next)") }
            case "-i", "--include":
                if tool.lowercased() == "bcftools", let next { params.append(contentsOf: bcftoolsFilterParameters(next)) }
            case "--isolate", "--meta", "--plasmid", "--rna":
                params.append("\(arg.dropFirst(2)) mode")
            default:
                break
            }
        }
        return params
    }

    /// `(FORMAT/AD[0:1])/(FORMAT/AD[0:0]+FORMAT/AD[0:1])>=0.05 && FORMAT/DP>=10`
    /// as the thresholds a reader wants.
    private func bcftoolsFilterParameters(_ expression: String) -> [String] {
        var params: [String] = []
        let clauses = expression.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        for clause in clauses {
            guard let range = clause.range(of: ">=") else { continue }
            let value = String(clause[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let subject = String(clause[..<range.lowerBound])
            if subject.contains("AD[0:1]") && subject.contains("/") {
                params.append("minimum allele frequency \(value)")
            } else if subject.contains("DP") {
                params.append("minimum depth \(value)")
            }
        }
        return params.isEmpty ? ["filter expression \(expression)"] : params
    }
}
