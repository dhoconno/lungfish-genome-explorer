import Foundation
import LungfishWorkflow

struct BundleMergeProvenanceSidecarWriter: Sendable {
    let write: @Sendable (ProvenanceEnvelope, URL) throws -> Void

    static let live = BundleMergeProvenanceSidecarWriter { envelope, bundleURL in
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }
}

enum BundleMergeProvenance {
    struct Request: Sendable {
        let workflowName: String
        let toolName: String
        let sourceBundleURLs: [URL]
        let inputPayloadURLs: [URL]
        let outputBundleURL: URL
        let outputPayloadURLs: [URL]
        let requestedBundleName: String
        let bundleName: String
        let mergeMode: String
        let defaults: [String: ParameterValue]
        let resolvedDefaults: [String: ParameterValue]
        let nestedSteps: [ProvenanceStep]
        let startedAt: Date
        let completedAt: Date
        let diagnostics: String?

        init(
            workflowName: String,
            toolName: String = "lungfish-app",
            sourceBundleURLs: [URL],
            inputPayloadURLs: [URL],
            outputBundleURL: URL,
            outputPayloadURLs: [URL],
            bundleName: String,
            requestedBundleName: String? = nil,
            mergeMode: String,
            defaults: [String: ParameterValue] = [:],
            resolvedDefaults: [String: ParameterValue] = [:],
            nestedSteps: [ProvenanceStep] = [],
            startedAt: Date,
            completedAt: Date,
            diagnostics: String? = nil
        ) {
            self.workflowName = workflowName
            self.toolName = toolName
            self.sourceBundleURLs = sourceBundleURLs
            self.inputPayloadURLs = inputPayloadURLs
            self.outputBundleURL = outputBundleURL
            self.outputPayloadURLs = outputPayloadURLs
            self.requestedBundleName = requestedBundleName ?? bundleName
            self.bundleName = bundleName
            self.mergeMode = mergeMode
            self.defaults = defaults
            self.resolvedDefaults = resolvedDefaults
            self.nestedSteps = nestedSteps
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.diagnostics = diagnostics
        }
    }

    static func write(
        request: Request,
        sidecarWriter: BundleMergeProvenanceSidecarWriter = .live
    ) throws {
        let argv = reproducibleArgv(for: request)
        let command = commandLine(from: argv)
        let inputs = try uniqueExistingFiles(request.inputPayloadURLs).map {
            try ProvenanceFileDescriptor.file(url: $0, format: fileFormat(for: $0), role: .input)
        }
        let outputs = try uniqueExistingFiles(request.outputPayloadURLs).map {
            try ProvenanceFileDescriptor.file(url: $0, format: fileFormat(for: $0), role: .output)
        }
        let duration = request.completedAt.timeIntervalSince(request.startedAt)
        let normalizedDuration = max(0, duration)
        let options = ProvenanceOptions(
            explicit: [
                "sourceBundles": .array(request.sourceBundleURLs.map { .file($0.standardizedFileURL) }),
                "inputPayloads": .array(inputs.map { .file(URL(fileURLWithPath: $0.path)) }),
                "outputBundle": .file(request.outputBundleURL.standardizedFileURL),
                "outputPayloads": .array(outputs.map { .file(URL(fileURLWithPath: $0.path)) }),
                "bundleName": .string(request.bundleName),
                "requestedBundleName": .string(request.requestedBundleName),
                "resolvedBundleName": .string(request.bundleName),
                "mergeMode": .string(request.mergeMode),
            ],
            defaults: request.defaults,
            resolvedDefaults: request.resolvedDefaults
        )
        let step = ProvenanceStep(
            toolName: request.workflowName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: command,
            inputs: inputs,
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: normalizedDuration,
            stderr: request.diagnostics,
            startedAt: request.startedAt,
            completedAt: request.completedAt
        )
        let steps = request.nestedSteps + [step]
        let envelope = ProvenanceEnvelope(
            createdAt: request.startedAt,
            workflowName: request.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: request.toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: request.toolName,
                version: WorkflowRun.currentAppVersion,
                kind: "app"
            ),
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: command,
            options: options,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputs + outputs,
            output: outputs.first,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: normalizedDuration,
            exitStatus: 0,
            stderr: request.diagnostics
        )
        try sidecarWriter.write(envelope, request.outputBundleURL)
    }

    static func regularPayloadFileURLs(in bundleURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        var urls: [URL] = []
        let bundlePath = bundleURL.standardizedFileURL.path
        let bundlePrefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"

        for case let fileURL as URL in enumerator {
            let standardized = fileURL.standardizedFileURL
            let relativePath = String(standardized.path.dropFirst(bundlePrefix.count))
            if relativePath == ProvenanceWriter.provenanceFilename
                || relativePath.hasPrefix("\(ProvenanceWriter.bundleProvenanceDirectoryName)/") {
                continue
            }

            let values = try standardized.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory != true {
                urls.append(standardized)
            }
        }

        return urls.sorted { $0.path < $1.path }
    }

    static func commandLine(from argv: [String]) -> String {
        argv.map(shellQuoted(_:)).joined(separator: " ")
    }

    private static func reproducibleArgv(for request: Request) -> [String] {
        var argv = [
            request.toolName,
            request.workflowName,
            "--requested-bundle-name",
            request.requestedBundleName,
            "--resolved-bundle-name",
            request.bundleName,
            "--merge-mode",
            request.mergeMode,
            "--output-bundle",
            request.outputBundleURL.standardizedFileURL.path,
        ]
        for sourceBundleURL in request.sourceBundleURLs {
            argv.append(contentsOf: ["--source-bundle", sourceBundleURL.standardizedFileURL.path])
        }
        return argv
    }

    private static func uniqueExistingFiles(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                continue
            }
            guard seen.insert(standardized.path).inserted else {
                continue
            }
            result.append(standardized)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func fileFormat(for url: URL) -> FileFormat? {
        var candidate = url
        if candidate.pathExtension.lowercased() == "gz" {
            candidate = candidate.deletingPathExtension()
        }
        switch candidate.pathExtension.lowercased() {
        case "fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn":
            return .fasta
        case "fq", "fastq":
            return .fastq
        case "json":
            return .json
        case "csv", "tsv", "txt", "fai", "gzi":
            return .text
        default:
            return .unknown
        }
    }

    private static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,/:@%")
        if argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
