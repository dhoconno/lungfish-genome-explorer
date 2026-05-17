// GUIImportedProvenanceRehydrator.swift - Preserves CLI provenance for GUI-imported bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum GUIImportedProvenanceRehydratorError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSourceProvenance(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSourceProvenance(let path):
            return "Source provenance does not describe a lungfish CLI-created output: \(path)"
        }
    }
}

public enum GUIImportedProvenanceRehydrator {
    @discardableResult
    public static func rehydrateImportedCopy(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> ProvenanceEnvelope {
        let sourceRoot = provenanceRoot(for: sourceURL)
        let destinationRoot = try finalProvenanceRoot(for: destinationURL)
        let sourceEnvelope = try loadSourceEnvelope(for: sourceURL, sourceRoot: sourceRoot)
        guard isLungfishCLIEnvelope(sourceEnvelope) else {
            throw GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance(sourceURL.path)
        }
        let pathMap = outputPathMap(
            from: sourceEnvelope,
            sourceURL: sourceURL,
            sourceRoot: sourceRoot,
            destinationURL: destinationURL,
            destinationRoot: destinationRoot
        )
        guard !pathMap.isEmpty else {
            throw ProvenanceRehydrationError.outputPathNotMapped(sourceURL.path)
        }

        var argumentPathMap = pathMap
        argumentPathMap[sourceURL.standardizedFileURL.path] = destinationURL.standardizedFileURL.path
        argumentPathMap[sourceRoot.standardizedFileURL.path] = destinationRoot.standardizedFileURL.path

        let rehydrated = try ProvenanceRehydrator.rehydrateSelectedOutputs(
            sourceDirectory: sourceRoot,
            finalDirectory: destinationRoot,
            pathMap: pathMap,
            argumentPathMap: argumentPathMap,
            preserveOriginMetadata: true
        )
        let withImportStep = try appendingGUIImportStep(
            to: rehydrated,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        try ProvenanceWriter(signingProvider: nil).write(withImportStep, to: destinationRoot)
        return withImportStep
    }

    public static func finalBundleRoot(containing url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if ProvenanceWriter.isBundleDirectory(standardizedURL) {
            return standardizedURL
        }

        var candidate = standardizedURL.deletingLastPathComponent()
        while !candidate.pathComponents.isEmpty, candidate.path != "/" {
            if ProvenanceWriter.isBundleDirectory(candidate) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { break }
            candidate = parent
        }
        return nil
    }

    public static func rewriteOutputDescriptors(
        in envelope: ProvenanceEnvelope,
        pathMap: [String: String],
        sourceProvenancePath: String? = nil
    ) throws -> ProvenanceEnvelope {
        let standardizedPathMap = standardized(pathMap)
        let replayArgv = rewriteArguments(
            envelope.durableReplayArgv ?? envelope.argv,
            pathMap: standardizedPathMap
        )
        let files = try deduplicated(
            envelope.files.map {
                if $0.role == .output {
                    return try rewriteOutputDescriptor(
                        $0,
                        pathMap: standardizedPathMap,
                        sourceProvenancePath: sourceProvenancePath
                    )
                }
                return $0
            }
        )
        let output = try envelope.output.map {
            try rewriteOutputDescriptor(
                $0,
                pathMap: standardizedPathMap,
                sourceProvenancePath: sourceProvenancePath
            )
        }
        let outputs = try deduplicated(
            envelope.outputs.map {
                try rewriteOutputDescriptor(
                    $0,
                    pathMap: standardizedPathMap,
                    sourceProvenancePath: sourceProvenancePath
                )
            }
        )
        let steps = try envelope.steps.map { step in
            let stepReplayArgv = rewriteArguments(step.durableReplayArgv ?? step.argv, pathMap: standardizedPathMap)
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                durableReplayArgv: stepReplayArgv,
                reproducibleCommand: commandLine(from: stepReplayArgv),
                inputs: step.inputs,
                outputs: try step.outputs.map {
                    try rewriteOutputDescriptor(
                        $0,
                        pathMap: standardizedPathMap,
                        sourceProvenancePath: sourceProvenancePath
                    )
                },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }

        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: replayArgv,
            reproducibleCommand: commandLine(from: replayArgv),
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: files,
            output: output,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private static func provenanceRoot(for sourceURL: URL) -> URL {
        finalBundleRoot(containing: sourceURL) ?? sourceURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func finalProvenanceRoot(for destinationURL: URL) throws -> URL {
        if let bundleRoot = finalBundleRoot(containing: destinationURL) {
            return bundleRoot
        }
        return destinationURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func loadSourceEnvelope(
        for sourceURL: URL,
        sourceRoot: URL
    ) throws -> ProvenanceEnvelope {
        var candidates: [URL] = [
            ProvenanceRecorder.fileSidecarURL(for: sourceURL),
            sourceRoot.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            sourceRoot
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        ]
        if let bundleSidecarURL = ProvenanceWriter.bundleOutputSidecarURL(for: sourceURL, inBundle: sourceRoot) {
            candidates.append(bundleSidecarURL)
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: candidate) else {
                continue
            }
            return envelope
        }

        throw ProvenanceRehydrationError.missingSourceProvenance(sourceURL.path)
    }

    private static func isLungfishCLIEnvelope(_ envelope: ProvenanceEnvelope) -> Bool {
        if isLungfishCLIName(envelope.toolName) {
            return true
        }
        if executableIsLungfishCLI(envelope.argv.first) {
            return true
        }
        if commandLooksLikeLungfishCLI(envelope.reproducibleCommand) {
            return true
        }
        return envelope.steps.contains { step in
            isLungfishCLIName(step.toolName)
                || executableIsLungfishCLI(step.argv.first)
                || commandLooksLikeLungfishCLI(step.reproducibleCommand)
        }
    }

    private static func isLungfishCLIName(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "lungfish-cli" || normalized == "lungfish"
    }

    private static func executableIsLungfishCLI(_ value: String?) -> Bool {
        guard let value else { return false }
        let executable = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        return executable == "lungfish-cli" || executable == "lungfish"
    }

    private static func commandLooksLikeLungfishCLI(_ command: String) -> Bool {
        guard let first = try? AdvancedCommandLineOptions.parse(command).first else {
            return command.hasPrefix("lungfish-cli ") || command.hasPrefix("lungfish ")
        }
        return executableIsLungfishCLI(first)
    }

    private static func outputPathMap(
        from envelope: ProvenanceEnvelope,
        sourceURL: URL,
        sourceRoot: URL,
        destinationURL: URL,
        destinationRoot: URL
    ) -> [String: String] {
        var pathMap: [String: String] = [:]
        let sourcePaths = outputPaths(from: envelope)
        let standardizedSourceURL = sourceURL.standardizedFileURL.path
        let standardizedSourceRoot = sourceRoot.standardizedFileURL.path
        let standardizedDestinationURL = destinationURL.standardizedFileURL.path
        let standardizedDestinationRoot = destinationRoot.standardizedFileURL.path

        if sourcePaths.isEmpty {
            pathMap[standardizedSourceURL] = standardizedDestinationURL
        }

        for path in sourcePaths {
            guard let finalPath = mappedDestinationPath(
                for: path,
                standardizedSourceURL: standardizedSourceURL,
                standardizedSourceRoot: standardizedSourceRoot,
                standardizedDestinationURL: standardizedDestinationURL,
                standardizedDestinationRoot: standardizedDestinationRoot
            ) else {
                continue
            }
            pathMap[path] = finalPath
            pathMap[URL(fileURLWithPath: path).standardizedFileURL.path] = finalPath
        }

        return pathMap
    }

    private static func outputPaths(from envelope: ProvenanceEnvelope) -> [String] {
        var paths: [String] = []
        if let output = envelope.output {
            paths.append(output.path)
        }
        paths.append(contentsOf: envelope.outputs.map(\.path))
        paths.append(contentsOf: envelope.steps.flatMap { $0.outputs.map(\.path) })
        paths.append(contentsOf: envelope.files.filter { $0.role == .output }.map(\.path))
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func mappedDestinationPath(
        for path: String,
        standardizedSourceURL: String,
        standardizedSourceRoot: String,
        standardizedDestinationURL: String,
        standardizedDestinationRoot: String
    ) -> String? {
        if path.hasPrefix("/") == false {
            return URL(fileURLWithPath: standardizedDestinationRoot)
                .appendingPathComponent(path)
                .standardizedFileURL
                .path
        }

        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardizedPath == standardizedSourceURL {
            return standardizedDestinationURL
        }
        if standardizedPath == standardizedSourceRoot {
            return standardizedDestinationRoot
        }
        let sourcePrefix = standardizedSourceRoot.hasSuffix("/")
            ? standardizedSourceRoot
            : standardizedSourceRoot + "/"
        guard standardizedPath.hasPrefix(sourcePrefix) else {
            return nil
        }
        let relativePath = String(standardizedPath.dropFirst(sourcePrefix.count))
        return URL(fileURLWithPath: standardizedDestinationRoot)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .path
    }

    private static func appendingGUIImportStep(
        to envelope: ProvenanceEnvelope,
        sourceURL: URL,
        destinationURL: URL
    ) throws -> ProvenanceEnvelope {
        let outputs = try importStepOutputs(from: envelope, destinationURL: destinationURL)
        let importStep = ProvenanceStep(
            toolName: "lungfish-app",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: ["lungfish-app", "gui-import", sourceURL.path, destinationURL.path],
            durableReplayArgv: ["lungfish-app", "gui-import", destinationURL.path],
            inputs: [try importStepInput(for: sourceURL)],
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: 0,
            startedAt: Date(),
            completedAt: Date()
        )

        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: envelope.options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: deduplicated(envelope.files + importStep.inputs + importStep.outputs),
            output: envelope.output,
            outputs: envelope.outputs,
            steps: envelope.steps + [importStep],
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private static func importStepInput(for sourceURL: URL) throws -> ProvenanceFileDescriptor {
        if isRegularFile(sourceURL) {
            return try ProvenanceFileDescriptor.file(url: sourceURL, role: .input)
        }
        return ProvenanceFileDescriptor(path: sourceURL.path, role: .input)
    }

    private static func importStepOutputs(
        from envelope: ProvenanceEnvelope,
        destinationURL: URL
    ) throws -> [ProvenanceFileDescriptor] {
        let outputs = envelope.outputs.isEmpty
            ? envelope.output.map { [$0] } ?? []
            : envelope.outputs
        if !outputs.isEmpty {
            return outputs
        }
        if isRegularFile(destinationURL) {
            return [try ProvenanceFileDescriptor.file(url: destinationURL, role: .output)]
        }
        return []
    }

    private static func rewriteOutputDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        pathMap: [String: String],
        sourceProvenancePath: String?
    ) throws -> ProvenanceFileDescriptor {
        guard let finalPath = mappedPath(for: descriptor.path, in: pathMap) else {
            return descriptor
        }
        let finalURL = URL(fileURLWithPath: finalPath)
        let originPath = descriptor.originPath ?? descriptor.path
        let provenancePath = descriptor.sourceProvenancePath ?? sourceProvenancePath
        if isRegularFile(finalURL) {
            return try ProvenanceFileDescriptor.file(
                url: finalURL,
                format: descriptor.format,
                role: descriptor.role,
                originPath: originPath,
                sourceProvenancePath: provenancePath
            )
        }
        return ProvenanceFileDescriptor(
            path: finalPath,
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: originPath,
            sourceProvenancePath: provenancePath
        )
    }

    private static func standardized(_ pathMap: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (source, destination) in pathMap {
            result[source] = destination
            result[URL(fileURLWithPath: source).standardizedFileURL.path] = destination
        }
        return result
    }

    private static func mappedPath(for path: String, in pathMap: [String: String]) -> String? {
        if let mapped = pathMap[path] {
            return mapped
        }
        return pathMap[URL(fileURLWithPath: path).standardizedFileURL.path]
    }

    private static func rewriteArguments(_ arguments: [String], pathMap: [String: String]) -> [String] {
        arguments.map { rewriteArgument($0, pathMap: pathMap) }
    }

    private static func rewriteArgument(_ argument: String, pathMap: [String: String]) -> String {
        for (source, destination) in replacementPairs(for: pathMap) where argument == source {
            return destination
        }

        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return argument
        }
        let prefix = argument[...equalsIndex]
        let value = String(argument[argument.index(after: equalsIndex)...])
        for (source, destination) in replacementPairs(for: pathMap) where value == source {
            return String(prefix) + destination
        }
        return argument
    }

    private static func replacementPairs(for pathMap: [String: String]) -> [(source: String, destination: String)] {
        var pairs: [(String, String)] = []
        var seen = Set<String>()
        for (source, destination) in pathMap {
            if seen.insert(source).inserted {
                pairs.append((source, destination))
            }
            let standardizedSource = URL(fileURLWithPath: source).standardizedFileURL.path
            if seen.insert(standardizedSource).inserted {
                pairs.append((standardizedSource, destination))
            }
        }
        return pairs.sorted {
            if $0.0.count != $1.0.count {
                return $0.0.count > $1.0.count
            }
            return $0.0 < $1.0
        }
    }

    private static func commandLine(from argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func deduplicated(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
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
}
