// SequenceExtractionBundleBuilder.swift - Shared .lungfishref bundle output for extracted sequences
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public struct SequenceExtractionBundleCommandContext: Sendable {
    public let workflowName: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let explicitOptions: [String: ParameterValue]
    public let defaultOptions: [String: ParameterValue]
    public let resolvedOptions: [String: ParameterValue]
    public let inputURLs: [URL]
    public let startedAt: Date?

    public init(
        workflowName: String,
        toolName: String,
        toolVersion: String = WorkflowRun.currentAppVersion,
        argv: [String],
        explicitOptions: [String: ParameterValue],
        defaultOptions: [String: ParameterValue],
        resolvedOptions: [String: ParameterValue],
        inputURLs: [URL],
        startedAt: Date? = nil
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
        self.inputURLs = inputURLs
        self.startedAt = startedAt
    }
}

public struct SequenceExtractionBundleBuildRequest: Sendable {
    public let result: LungfishCore.ExtractionResult
    public let outputDirectory: URL
    public let outputBundleURL: URL?
    public let sourceBundleURL: URL?
    public let sourceBundleName: String?
    public let desiredBundleName: String?
    public let commandContext: SequenceExtractionBundleCommandContext

    public init(
        result: LungfishCore.ExtractionResult,
        outputDirectory: URL,
        outputBundleURL: URL? = nil,
        sourceBundleURL: URL? = nil,
        sourceBundleName: String? = nil,
        desiredBundleName: String? = nil,
        commandContext: SequenceExtractionBundleCommandContext
    ) {
        self.result = result
        self.outputDirectory = outputDirectory
        self.outputBundleURL = outputBundleURL
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleName = sourceBundleName
        self.desiredBundleName = desiredBundleName
        self.commandContext = commandContext
    }
}

public final class SequenceExtractionBundleBuilder: @unchecked Sendable {
    public init() {}

    public func buildBundle(
        request: SequenceExtractionBundleBuildRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let startedAt = request.commandContext.startedAt ?? Date()
        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "extract-bundle-",
            contextURL: request.outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        progressHandler?(0.10, "Writing FASTA...")
        let fastaURL = tempDirectory.appendingPathComponent("sequence.fa")
        try SequenceExtractor.formatFASTA(request.result)
            .write(to: fastaURL, atomically: true, encoding: .utf8)

        let bundleName = try resolvedBundleName(for: request)
        let buildOutputDirectory = request.outputBundleURL == nil
            ? request.outputDirectory
            : tempDirectory.appendingPathComponent("bundle-output", isDirectory: true)
        let configuration = BuildConfiguration(
            name: bundleName,
            identifier: "org.lungfish.extracted.\(bundleName.lowercased().replacingOccurrences(of: " ", with: "-"))",
            fastaURL: fastaURL,
            outputDirectory: buildOutputDirectory,
            source: sourceInfo(for: request),
            compressFASTA: true,
            provenanceWorkflowName: request.commandContext.workflowName,
            provenanceCommand: request.commandContext.argv,
            provenanceInputFiles: request.commandContext.inputURLs
        )

        progressHandler?(0.20, "Building reference bundle...")
        let builtBundleURL = try await NativeBundleBuilder().build(configuration: configuration) { _, progress, message in
            progressHandler?(0.20 + (progress * 0.65), message)
        }
        let bundleURL = try moveToRequestedOutputIfNeeded(
            builtBundleURL,
            request: request
        )

        do {
            progressHandler?(0.92, "Writing provenance...")
            try writeProvenance(
                request: request,
                bundleURL: bundleURL,
                startedAt: startedAt,
                completedAt: Date()
            )
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        return bundleURL
    }

    private func resolvedBundleName(for request: SequenceExtractionBundleBuildRequest) throws -> String {
        if let outputBundleURL = request.outputBundleURL {
            try FileManager.default.createDirectory(
                at: outputBundleURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return outputBundleURL.deletingPathExtension().lastPathComponent
        }

        let rawName = request.desiredBundleName?.isEmpty == false
            ? request.desiredBundleName!
            : request.result.sourceName
        return Self.makeUniqueBundleName(base: Self.sanitizedFilename(rawName), in: request.outputDirectory)
    }

    private func moveToRequestedOutputIfNeeded(
        _ builtBundleURL: URL,
        request: SequenceExtractionBundleBuildRequest
    ) throws -> URL {
        guard let outputBundleURL = request.outputBundleURL?.standardizedFileURL else {
            return builtBundleURL
        }

        let builtURL = builtBundleURL.standardizedFileURL
        if builtURL.path == outputBundleURL.path {
            return builtURL
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputBundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputBundleURL.path) {
            try fileManager.removeItem(at: outputBundleURL)
        }
        try fileManager.moveItem(at: builtURL, to: outputBundleURL)
        return outputBundleURL
    }

    private func sourceInfo(for request: SequenceExtractionBundleBuildRequest) -> SourceInfo {
        let coordinateLabel = "\(request.result.chromosome):\(request.result.effectiveStart)-\(request.result.effectiveEnd)"
        let description: String
        if let sourceBundleName = request.sourceBundleName {
            description = "Extracted from \(sourceBundleName) at \(coordinateLabel)"
        } else {
            description = "Extracted sequence at \(coordinateLabel)"
        }
        return SourceInfo(
            organism: request.sourceBundleName ?? "Unknown",
            assembly: "Extracted",
            sourceURL: request.sourceBundleURL,
            downloadDate: Date(),
            notes: description
        )
    }

    private func writeProvenance(
        request: SequenceExtractionBundleBuildRequest,
        bundleURL: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let inputDescriptors = try inputDescriptors(for: request)
        let outputDescriptors = try outputDescriptors(in: bundleURL)
        let reproducibleCommand = request.commandContext.argv.map { shellEscape($0) }.joined(separator: " ")
        let step = ProvenanceStep(
            toolName: request.commandContext.toolName,
            toolVersion: request.commandContext.toolVersion,
            argv: request.commandContext.argv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )

        let envelope = try ProvenanceRunBuilder(
            workflowName: request.commandContext.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: request.commandContext.toolName,
            toolVersion: request.commandContext.toolVersion
        )
        .argv(request.commandContext.argv)
        .reproducibleCommand(reproducibleCommand)
        .options(
            explicit: request.commandContext.explicitOptions,
            defaults: request.commandContext.defaultOptions,
            resolved: request.commandContext.resolvedOptions
                .merging(["output_bundle": .file(bundleURL)]) { current, _ in current }
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private func inputDescriptors(
        for request: SequenceExtractionBundleBuildRequest
    ) throws -> [ProvenanceFileDescriptor] {
        var inputURLs = request.commandContext.inputURLs
        if let sourceBundleURL = request.sourceBundleURL {
            inputURLs.append(contentsOf: sourceBundleInputURLs(sourceBundleURL))
        }
        return try deduplicatedExistingURLs(inputURLs).map {
            try ProvenanceFileDescriptor.file(url: $0, format: provenanceFormat(for: $0), role: .input)
        }
    }

    private func outputDescriptors(in bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        var outputURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
            guard relativePath != ProvenanceWriter.provenanceFilename,
                  relativePath != ProvenanceWriter.bundleProvenanceDirectoryName,
                  !relativePath.hasPrefix("\(ProvenanceWriter.bundleProvenanceDirectoryName)/") else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                outputURLs.append(fileURL.standardizedFileURL)
            }
        }

        return try outputURLs.sorted { $0.path < $1.path }.map {
            try ProvenanceFileDescriptor.file(
                url: $0,
                format: provenanceFormat(for: $0),
                role: provenanceOutputRole(for: $0)
            )
        }
    }

    private func sourceBundleInputURLs(_ sourceBundleURL: URL) -> [URL] {
        var urls = [sourceBundleURL.appendingPathComponent("manifest.json")]
        guard let manifest = try? BundleManifest.load(from: sourceBundleURL),
              let genome = manifest.genome else {
            return urls
        }
        urls.append(sourceBundleURL.appendingPathComponent(genome.path))
        urls.append(sourceBundleURL.appendingPathComponent(genome.indexPath))
        if let gzipIndexPath = genome.gzipIndexPath {
            urls.append(sourceBundleURL.appendingPathComponent(gzipIndexPath))
        }
        return urls
    }

    private func deduplicatedExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted else {
                continue
            }
            result.append(standardized)
        }
        return result
    }

    private func provenanceOutputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        default:
            return .output
        }
    }

    private func provenanceFormat(for url: URL) -> FileFormat {
        let filename = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "bed":
            return .bed
        case "json":
            return .json
        case "fai", "gzi", "txt":
            return .text
        case "fa", "fasta", "fna", "ffn", "faa", "fas":
            return .fasta
        case "gz" where filename.hasSuffix(".fa.gz")
            || filename.hasSuffix(".fasta.gz")
            || filename.hasSuffix(".fna.gz")
            || filename.hasSuffix(".ffn.gz")
            || filename.hasSuffix(".faa.gz")
            || filename.hasSuffix(".fas.gz"):
            return .fasta
        case "db":
            return .unknown
        default:
            return .unknown
        }
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func makeUniqueBundleName(base: String, in directory: URL) -> String {
        let safeBase = base.isEmpty ? "extracted_sequence" : base
        var candidate = safeBase
        var counter = 1
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(candidate).lungfishref", isDirectory: true).path
        ) {
            candidate = "\(safeBase)_\(counter)"
            counter += 1
        }
        return candidate
    }
}
