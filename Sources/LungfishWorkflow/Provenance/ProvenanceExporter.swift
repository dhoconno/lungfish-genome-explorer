// ProvenanceExporter.swift - Export provenance records to reproducible scripts
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
                "Unsupported provenance export format '\(value)'. Supported formats: shell, nextflow, snakemake, methods, json."
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

        let run = envelope.legacyWorkflowRun()
        let primaryArtifactURL: URL
        var generatedArtifactURLs: [URL] = []
        switch format {
        case .shell:
            primaryArtifactURL = outputDirectory.appendingPathComponent("run.sh")
            try exportShell(envelope, fallbackRun: run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
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
        case .methods:
            primaryArtifactURL = outputDirectory.appendingPathComponent("methods.md")
            try exportMethods(run).write(to: primaryArtifactURL, atomically: true, encoding: .utf8)
        case .json:
            primaryArtifactURL = outputDirectory.appendingPathComponent("provenance.json")
            let data = try ProvenanceJSON.encoder.encode(envelope)
            try data.write(to: primaryArtifactURL, options: .atomic)
        case .python:
            throw ProvenanceError.exportFailed(
                "Unsupported provenance export format '\(format.rawValue)' for canonical bundles. Supported formats: shell, nextflow, snakemake, methods, json."
            )
        }
        generatedArtifactURLs.insert(primaryArtifactURL, at: 0)
        let signedReportArtifactURLs = try signReportArtifacts(generatedArtifactURLs)

        let provenanceDirectory = outputDirectory.appendingPathComponent("provenance", isDirectory: true)
        try fileManager.createDirectory(at: provenanceDirectory, withIntermediateDirectories: true)
        let copiedSourceArtifacts = try copySourceArtifacts(
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL,
            outputDirectory: outputDirectory,
            provenanceDirectory: provenanceDirectory
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
        if !envelope.steps.isEmpty {
            return exportShell(fallbackRun)
        }

        var s = ""
        s += "#!/usr/bin/env bash\n"
        s += "#\n"
        s += "# \(envelope.workflowName)\n"
        s += "# Generated by \(envelope.workflowVersion)\n"
        s += "# Original run: \(iso8601(envelope.createdAt))\n"
        s += "# Host: \(envelope.runtimeIdentity.operatingSystemVersion)\n"
        if let user = envelope.runtimeIdentity.user {
            s += "# User: \(user)\n"
        }
        s += "#\n"
        s += "set -euo pipefail\n\n"

        if envelope.argv.isEmpty {
            s += exportShell(fallbackRun)
        } else {
            s += envelope.argv.map { shellEscape($0) }.joined(separator: " \\\n    ")
            s += "\n"
        }

        return s
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
        var arguments = ["lungfish", "provenance", "export"]
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
        provenanceDirectory: URL
    ) throws -> [CopiedSourceArtifact] {
        let fileManager = FileManager.default
        let sourceDestinationRoot = provenanceDirectory.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceDestinationRoot, withIntermediateDirectories: true)

        let sourceURLs = try sourceArtifactURLs(
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: sourceRootURL,
            outputDirectory: outputDirectory
        )

        return try sourceURLs.map { sourceURL in
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
        if let sourceRootURL,
           let relativePath = relativePath(for: sourceURL, relativeTo: sourceRootURL) {
            return sourceDestinationRoot.appendingPathComponent(relativePath)
        }
        return sourceDestinationRoot.appendingPathComponent(sourceURL.lastPathComponent)
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
            || filename.hasSuffix("lungfish-provenance.json")
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

    private func exportNextflowConfig(_ run: WorkflowRun) -> String {
        var s = ""
        s += "process {\n"
        s += "    errorStrategy = 'terminate'\n"
        if run.steps.contains(where: { $0.containerImage != nil }) {
            s += "    container = null\n"
        }
        s += "}\n\n"
        s += "docker.enabled = true\n"
        return s
    }

    private func exportContainerManifest(_ run: WorkflowRun) throws -> String {
        struct ContainerEntry: Encodable {
            let toolName: String
            let toolVersion: String
            let image: String
            let digest: String?
        }
        let entries = run.steps.compactMap { step -> ContainerEntry? in
            guard let image = step.containerImage else { return nil }
            return ContainerEntry(
                toolName: step.toolName,
                toolVersion: step.toolVersion,
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
        var s = ""
        s += "outdir: results\n"
        for input in run.primaryInputFiles {
            let key = sanitize(input.filename.replacingOccurrences(of: ".", with: "_"))
            s += "\(key): \(input.filename)\n"
        }
        return s
    }

    // MARK: - Shell Script Export

    /// Generates a Bash script that reproduces the workflow.
    public func exportShell(_ run: WorkflowRun) -> String {
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
        s += "#\n"
        s += "# This script reproduces the analysis performed in Lungfish.\n"
        s += "# Ensure the required tools are installed or use the container\n"
        s += "# images specified in the comments.\n"
        s += "#\n"
        s += "set -euo pipefail\n\n"

        // Input files as variables
        let inputs = run.primaryInputFiles
        if !inputs.isEmpty {
            s += "# Input files\n"
            for (i, input) in inputs.enumerated() {
                let varName = "INPUT_\(i + 1)"
                s += "\(varName)=\"\(input.filename)\""
                if let sha = input.sha256 {
                    s += "  # sha256: \(sha)"
                }
                s += "\n"
            }
            s += "\n"
        }

        // Output directory
        s += "# Output directory\n"
        s += "OUTDIR=\"results\"\n"
        s += "mkdir -p \"$OUTDIR\"\n\n"

        // Each step
        for (i, step) in run.steps.enumerated() {
            s += "# Step \(i + 1): \(step.toolName) \(step.toolVersion)\n"
            if let image = step.containerImage {
                s += "# Container: \(image)\n"
                if let digest = step.containerDigest {
                    s += "# Digest: \(digest)\n"
                }
            }
            if let wallTime = step.wallTime {
                s += "# Wall time: \(formatDuration(wallTime))\n"
            }

            // Write the actual command
            s += shellCommand(step)
            s += "\n"
        }

        s += "echo \"Pipeline complete.\"\n"
        return s
    }

    private func shellCommand(_ step: StepExecution) -> String {
        // Reconstruct the command, skipping the absolute tool path
        // and using just the tool name for portability
        var args = step.command
        if !args.isEmpty {
            // Replace absolute path with tool name
            let firstArg = args[0]
            if firstArg.contains("/") {
                args[0] = URL(fileURLWithPath: firstArg).lastPathComponent
            }
        }
        return args.map { shellEscape($0) }.joined(separator: " \\\n    ") + "\n"
    }

    // MARK: - Python Script Export

    /// Generates a Python script using subprocess to reproduce the workflow.
    public func exportPython(_ run: WorkflowRun) -> String {
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
        s += "\n"
        s += "This script reproduces the analysis performed in Lungfish.\n"
        s += "\"\"\"\n\n"
        s += "import subprocess\n"
        s += "import sys\n"
        s += "import os\n"
        s += "from pathlib import Path\n\n"

        // Input files
        let inputs = run.primaryInputFiles
        if !inputs.isEmpty {
            s += "# Input files\n"
            s += "INPUTS = {\n"
            for input in inputs {
                s += "    \"\(input.filename)\": \"\(input.sha256 ?? "unknown")\",  # sha256\n"
            }
            s += "}\n\n"
        }

        s += "OUTDIR = Path(\"results\")\n"
        s += "OUTDIR.mkdir(exist_ok=True)\n\n"

        s += "def run_step(name: str, cmd: list[str]) -> None:\n"
        s += "    \"\"\"Run a pipeline step and check for errors.\"\"\"\n"
        s += "    print(f\"Running: {name}\")\n"
        s += "    result = subprocess.run(cmd, capture_output=True, text=True)\n"
        s += "    if result.returncode != 0:\n"
        s += "        print(f\"ERROR in {name}: {result.stderr}\", file=sys.stderr)\n"
        s += "        sys.exit(result.returncode)\n"
        s += "    print(f\"  Done ({name})\")\n\n\n"

        // Steps
        for (i, step) in run.steps.enumerated() {
            let stepName = "step_\(i + 1)_\(sanitize(step.toolName))"
            s += "def \(stepName)():\n"
            s += "    \"\"\"\(step.toolName) \(step.toolVersion)"
            if let image = step.containerImage {
                s += " (container: \(image))"
            }
            s += "\"\"\"\n"

            // Build command list
            var args = step.command
            if !args.isEmpty && args[0].contains("/") {
                args[0] = URL(fileURLWithPath: args[0]).lastPathComponent
            }
            let pyArgs = args.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            s += "    run_step(\"\(step.toolName)\", [\n"
            for arg in pyArgs {
                s += "        \(arg),\n"
            }
            s += "    ])\n\n\n"
        }

        // Main
        s += "if __name__ == \"__main__\":\n"
        s += "    print(\"Reproducing: \(run.name)\")\n"
        for (i, step) in run.steps.enumerated() {
            let stepName = "step_\(i + 1)_\(sanitize(step.toolName))"
            s += "    \(stepName)()\n"
        }
        s += "    print(\"Pipeline complete.\")\n"

        return s
    }

    // MARK: - Nextflow Export

    /// Generates a Nextflow DSL2 pipeline from the provenance record.
    public func exportNextflow(_ run: WorkflowRun) -> String {
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
        s += " */\n\n"
        s += "nextflow.enable.dsl = 2\n\n"

        // Parameters from input files
        s += "// Pipeline parameters\n"
        s += "params {\n"
        let inputs = run.primaryInputFiles
        for input in inputs {
            let paramName = sanitize(input.filename.replacingOccurrences(of: ".", with: "_"))
            s += "    \(paramName) = '\(input.filename)'\n"
        }
        s += "    outdir = './results'\n"
        s += "}\n\n"

        // Process definitions
        for (i, step) in run.steps.enumerated() {
            let processName = "\(sanitize(step.toolName).uppercased())_\(i + 1)"

            s += "/*\n"
            s += " * Step \(i + 1): \(step.toolName) \(step.toolVersion)\n"
            if let wallTime = step.wallTime {
                s += " * Original wall time: \(formatDuration(wallTime))\n"
            }
            s += " */\n"
            s += "process \(processName) {\n"

            if let image = step.containerImage {
                s += "    container '\(image)'\n"
            }

            s += "    publishDir params.outdir, mode: 'copy'\n\n"

            // Input
            if !step.inputs.isEmpty {
                s += "    input:\n"
                for input in step.inputs {
                    s += "    path '\(input.filename)'\n"
                }
                s += "\n"
            }

            // Output
            if !step.outputs.isEmpty {
                s += "    output:\n"
                for output in step.outputs {
                    s += "    path '\(output.filename)'\n"
                }
                s += "\n"
            }

            // Script
            s += "    script:\n"
            s += "    \"\"\"\n"
            s += "    \(portableCommand(step))\n"
            s += "    \"\"\"\n"
            s += "}\n\n"
        }

        // Workflow block
        s += "// Main workflow\n"
        s += "workflow {\n"

        // Create input channels
        for input in inputs {
            let paramName = sanitize(input.filename.replacingOccurrences(of: ".", with: "_"))
            let chName = "\(paramName)_ch"
            s += "    \(chName) = Channel.fromPath(params.\(paramName))\n"
        }
        s += "\n"

        // Chain processes
        for (i, step) in run.steps.enumerated() {
            let processName = "\(sanitize(step.toolName).uppercased())_\(i + 1)"
            if i == 0 && !inputs.isEmpty {
                let paramName = sanitize(inputs[0].filename.replacingOccurrences(of: ".", with: "_"))
                s += "    \(processName)(\(paramName)_ch)\n"
            } else if i > 0 {
                let prevName = "\(sanitize(run.steps[i - 1].toolName).uppercased())_\(i)"
                s += "    \(processName)(\(prevName).out)\n"
            } else {
                s += "    \(processName)()\n"
            }
        }

        s += "}\n"
        return s
    }

    // MARK: - Snakemake Export

    /// Generates a Snakefile from the provenance record.
    public func exportSnakemake(_ run: WorkflowRun) -> String {
        var s = ""
        s += "# \(run.name)\n"
        s += "# Generated by \(run.appVersion)\n"
        s += "# Original run: \(iso8601(run.startTime))\n"
        s += "# Host: \(run.hostOS)\n"
        if let user = run.runtime.user {
            s += "# User: \(user)\n"
        }
        s += "#\n"
        s += "# Usage: snakemake --cores 8 --use-singularity\n\n"

        s += "configfile: \"config.yaml\"\n\n"

        // Collect all final outputs
        let finalOutputs = run.steps.last?.outputs ?? []
        s += "rule all:\n"
        s += "    input:\n"
        for output in finalOutputs {
            s += "        \"results/\(output.filename)\",\n"
        }
        s += "\n\n"

        // Rule definitions
        for (i, step) in run.steps.enumerated() {
            let ruleName = "\(sanitize(step.toolName))_\(i + 1)"

            s += "# Step \(i + 1): \(step.toolName) \(step.toolVersion)\n"
            if let wallTime = step.wallTime {
                s += "# Original wall time: \(formatDuration(wallTime))\n"
            }

            s += "rule \(ruleName):\n"

            // Input
            s += "    input:\n"
            for input in step.inputs {
                if step.dependsOn.isEmpty {
                    s += "        \"\(input.filename)\",\n"
                } else {
                    s += "        \"results/\(input.filename)\",\n"
                }
            }

            // Output
            s += "    output:\n"
            for output in step.outputs {
                s += "        \"results/\(output.filename)\",\n"
            }

            // Log
            s += "    log:\n"
            s += "        \"logs/\(ruleName).log\"\n"

            // Container
            if let image = step.containerImage {
                s += "    singularity:\n"
                s += "        \"docker://\(image)\"\n"
            }

            // Shell
            s += "    shell:\n"
            s += "        \"\"\"\n"
            s += "        \(portableCommand(step)) 2> {log}\n"
            s += "        \"\"\"\n\n"
        }

        return s
    }

    // MARK: - Methods Section Export

    /// Generates publication-ready methods text from the provenance record.
    public func exportMethods(_ run: WorkflowRun) -> String {
        var s = ""
        s += "<!-- This is an automatically-generated draft. Read it before submitting. -->\n\n"
        s += "Methods\n"
        s += "=======\n\n"
        s += "Computational Analysis\n"
        s += "----------------------\n\n"

        // Group steps by tool for cleaner prose
        var toolSentences: [String] = []

        for step in run.steps where step.isSuccess {
            var sentence = ""

            // Build a methods sentence for this step
            let toolDesc = toolDescription(step.toolName)
            sentence += "\(toolDesc) was performed using \(step.toolName) v\(step.toolVersion)"

            // Add key parameters (non-path arguments)
            let keyParams = extractKeyParameters(step)
            if !keyParams.isEmpty {
                sentence += " with \(keyParams.joined(separator: ", "))"
            }

            sentence += "."

            // Add container provenance
            if let image = step.containerImage {
                sentence += " The tool was executed in a container (\(image)"
                if let digest = step.containerDigest {
                    sentence += ", digest: \(digest)"
                }
                sentence += ")."
            }

            toolSentences.append(sentence)
        }

        s += toolSentences.joined(separator: " ") + "\n\n"

        // Tool versions table
        s += "Tool Versions\n"
        s += "-------------\n\n"
        s += "| Tool | Version | Container |\n"
        s += "|------|---------|----------|\n"
        for step in run.steps where step.isSuccess {
            let container = step.containerImage ?? "native"
            s += "| \(step.toolName) | \(step.toolVersion) | \(container) |\n"
        }
        s += "\n"

        // Input files
        s += "Input Files\n"
        s += "-----------\n\n"
        for input in run.primaryInputFiles {
            s += "- \(input.filename)"
            if let sha = input.sha256 {
                s += " (SHA-256: \(sha))"
            }
            s += "\n"
        }
        s += "\n"

        // Reproducibility note
        s += "Reproducibility\n"
        s += "---------------\n\n"
        s += "This analysis was performed using \(run.appVersion) on \(run.hostOS). "
        s += "A machine-readable provenance record and executable pipeline scripts "
        s += "(Nextflow, Snakemake, and shell) are available in the supplementary materials.\n"

        return s
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
        var s = name.replacingOccurrences(of: " ", with: "_")
        s = s.replacingOccurrences(of: "-", with: "_")
        s = s.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if let first = s.first, first.isNumber {
            s = "_" + s
        }
        return s.lowercased()
    }


    /// Builds a portable command string (tool name instead of absolute path).
    private func portableCommand(_ step: StepExecution) -> String {
        var args = step.command
        if !args.isEmpty && args[0].contains("/") {
            args[0] = URL(fileURLWithPath: args[0]).lastPathComponent
        }
        return args.map { shellEscape($0) }.joined(separator: " ")
    }

    /// Returns a human-readable description of what a tool does.
    private func toolDescription(_ toolName: String) -> String {
        switch toolName.lowercased() {
        case "samtools": return "Alignment processing"
        case "bcftools": return "Variant processing"
        case "bgzip": return "Block compression"
        case "tabix": return "Indexing"
        case "bedtobigbed": return "BED to BigBed conversion"
        case "bedgraphtobigwig": return "Signal track conversion"
        case "fastp": return "Read quality filtering and trimming"
        case "fastqc": return "Sequence quality assessment"
        case "multiqc": return "Quality report aggregation"
        case "bwa": return "Short-read alignment"
        case "minimap2": return "Sequence alignment"
        case "spades", "spades.py": return "De novo genome assembly"
        case "seqkit": return "Sequence manipulation"
        case "vsearch": return "Sequence clustering"
        case "cutadapt": return "Adapter trimming"
        case "bbduk.sh", "bbduk": return "Quality filtering and adapter removal"
        case "bbmerge.sh", "bbmerge": return "Paired-end read merging"
        case "pigz": return "Parallel compression"
        default: return "Processing"
        }
    }

    /// Extracts human-readable key parameters from a step's command.
    private func extractKeyParameters(_ step: StepExecution) -> [String] {
        var params: [String] = []
        let args = step.command

        for i in 0..<args.count {
            let arg = args[i]

            // Skip the tool path and file arguments
            if i == 0 { continue }
            if !arg.hasPrefix("-") { continue }

            // Extract commonly reported parameters
            switch arg {
            case "-q", "--qualified_quality_phred":
                if i + 1 < args.count {
                    params.append("minimum quality score of \(args[i + 1])")
                }
            case "-l", "--length_required":
                if i + 1 < args.count {
                    params.append("minimum length of \(args[i + 1]) bp")
                }
            case "-t", "-@", "--threads":
                if i + 1 < args.count {
                    params.append("\(args[i + 1]) threads")
                }
            case "--memory":
                if i + 1 < args.count {
                    params.append("\(args[i + 1]) GB memory")
                }
            case "--isolate", "--meta", "--plasmid", "--rna":
                params.append("\(arg.dropFirst(2)) mode")
            default:
                break
            }
        }

        return params
    }
}
