// CLISequenceInputMaterialization.swift - CLI-safe sequence input materialization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishIO

public protocol CLISequenceInputMaterializing {
    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL
}

extension FASTQCLIMaterializer: CLISequenceInputMaterializing {}

public enum CLISequenceInputMaterializationError: LocalizedError, Sendable, Equatable {
    case unreadableSequenceInput(String)
    case unsupportedSequenceInput(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableSequenceInput(let path):
            return "Sequence input does not contain a readable FASTQ or FASTA payload: \(path)"
        case .unsupportedSequenceInput(let message):
            return message
        }
    }
}

public struct CLISequenceInputMaterializationPair: Sendable, Codable, Equatable {
    public let originalURL: URL
    public let executionURL: URL

    public init(originalURL: URL, executionURL: URL) {
        self.originalURL = originalURL.standardizedFileURL
        self.executionURL = executionURL.standardizedFileURL
    }
}

public struct CLISequenceInputMaterializationResult: Sendable, Equatable {
    public let inputURLs: [URL]
    public let originalInputURLs: [URL]
    public let materializedPairs: [CLISequenceInputMaterializationPair]
    public let materializationStartedAt: Date?
    public let materializationEndedAt: Date?

    public init(
        inputURLs: [URL],
        originalInputURLs: [URL],
        materializedPairs: [CLISequenceInputMaterializationPair],
        materializationStartedAt: Date?,
        materializationEndedAt: Date?
    ) {
        self.inputURLs = inputURLs.map(\.standardizedFileURL)
        self.originalInputURLs = originalInputURLs.map(\.standardizedFileURL)
        self.materializedPairs = materializedPairs
        self.materializationStartedAt = materializationStartedAt
        self.materializationEndedAt = materializationEndedAt
    }

    public var didMaterialize: Bool {
        !materializedPairs.isEmpty
    }
}

/// Detects virtual FASTQ bundles that CLI tools must materialize before running.
public enum CLISequenceInputMaterialization {
    private enum PreflightInput {
        case materialized(bundleURL: URL)
        case resolved(resolvedURL: URL)
    }

    public static func bundleRequiringMaterialization(for inputURL: URL) -> URL? {
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL.standardizedFileURL),
              let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL),
              payloadRequiresMaterialization(manifest.payload) else {
            return nil
        }

        return bundleURL.standardizedFileURL
    }

    public static func requiresMaterialization(_ inputURL: URL) -> Bool {
        bundleRequiringMaterialization(for: inputURL) != nil
    }

    public static func unsupportedSequenceInputMessage(for inputURL: URL, operationName: String) -> String? {
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL.standardizedFileURL),
              let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            return nil
        }

        switch manifest.payload {
        case .demuxGroup:
            return "Demultiplexed group bundles are container-only; select an individual demultiplexed FASTQ bundle for \(operationName)."
        default:
            return nil
        }
    }

    public static func resolveExecutionInputs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: CLISequenceInputMaterializing,
        operationName: String,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLISequenceInputMaterializationResult {
        let preflightInputs = try inputURLs.map { inputURL -> PreflightInput in
            let originalURL = inputURL.standardizedFileURL
            if let unsupportedMessage = unsupportedSequenceInputMessage(for: originalURL, operationName: operationName) {
                throw CLISequenceInputMaterializationError.unsupportedSequenceInput(unsupportedMessage)
            }

            if let bundleURL = bundleRequiringMaterialization(for: originalURL) {
                return .materialized(bundleURL: bundleURL)
            }

            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: originalURL) else {
                throw CLISequenceInputMaterializationError.unreadableSequenceInput(originalURL.path)
            }
            return .resolved(resolvedURL: resolvedURL.standardizedFileURL)
        }

        var resolvedURLs: [URL] = []
        var materializedPairs: [CLISequenceInputMaterializationPair] = []
        var materializationStartedAt: Date?
        var materializationEndedAt: Date?
        let fileManager = FileManager.default
        var tempDirectoryWasDirectory = ObjCBool(false)
        let tempDirectoryExisted = fileManager.fileExists(
            atPath: tempDirectory.path,
            isDirectory: &tempDirectoryWasDirectory
        )
        let preexistingTempEntries = tempDirectoryExisted && tempDirectoryWasDirectory.boolValue
            ? (try? fileManager.contentsOfDirectory(atPath: tempDirectory.path)).map(Set.init)
            : nil

        do {
            for input in preflightInputs {
                switch input {
                case .materialized(let bundleURL):
                    if materializationStartedAt == nil {
                        materializationStartedAt = Date()
                    }
                    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                    let materializedURL = try await materializer.materialize(
                        bundleURL: bundleURL,
                        tempDirectory: tempDirectory,
                        progress: progress
                    ).standardizedFileURL
                    materializationEndedAt = Date()
                    resolvedURLs.append(materializedURL)
                    materializedPairs.append(
                        CLISequenceInputMaterializationPair(originalURL: bundleURL, executionURL: materializedURL)
                    )
                case .resolved(let resolvedURL):
                    resolvedURLs.append(resolvedURL)
                }
            }
        } catch {
            cleanupNewMaterializationOutputs(
                in: tempDirectory,
                preexistingPathExisted: tempDirectoryExisted,
                preexistingEntries: preexistingTempEntries,
                materializedPairs: materializedPairs
            )
            throw error
        }

        return CLISequenceInputMaterializationResult(
            inputURLs: resolvedURLs,
            originalInputURLs: inputURLs,
            materializedPairs: materializedPairs,
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )
    }

    public static func materializedInputPairs(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [CLISequenceInputMaterializationPair] {
        executionInputURLs.enumerated().compactMap { index, executionURL in
            let originalURL = originalInputURLs.indices.contains(index)
                ? originalInputURLs[index].standardizedFileURL
                : executionURL.standardizedFileURL
            let executionURL = executionURL.standardizedFileURL
            guard originalURL != executionURL,
                  let bundleURL = bundleRequiringMaterialization(for: originalURL) else {
                return nil
            }
            return CLISequenceInputMaterializationPair(
                originalURL: bundleURL,
                executionURL: executionURL
            )
        }
    }

    public static func materializationCommand(originalURL: URL, executionURL: URL) -> [String] {
        let bundleURL = bundleRequiringMaterialization(for: originalURL) ?? originalURL.standardizedFileURL
        return [
            "lungfish",
            "fastq",
            "materialize",
            bundleURL.standardizedFileURL.path,
            "--output",
            executionURL.standardizedFileURL.path,
        ]
    }

    public static func durableReplayArgv(
        argv: [String],
        originalInputArguments: [String] = [],
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [String]? {
        var replacements: [String: String] = [:]
        for (index, executionURL) in executionInputURLs.enumerated() {
            let originalURL = originalInputURLs.indices.contains(index)
                ? originalInputURLs[index].standardizedFileURL
                : executionURL.standardizedFileURL
            let executionURL = executionURL.standardizedFileURL
            guard originalURL != executionURL,
                  let bundleURL = bundleRequiringMaterialization(for: originalURL) else {
                continue
            }
            let durablePath = executionURL.path
            var candidates = Set([
                originalURL.path,
                originalURL.standardizedFileURL.path,
                bundleURL.path,
                bundleURL.standardizedFileURL.path,
            ])
            if originalInputArguments.indices.contains(index) {
                let rawArgument = originalInputArguments[index]
                candidates.insert(rawArgument)
                candidates.insert(URL(fileURLWithPath: rawArgument).path)
                candidates.insert(URL(fileURLWithPath: rawArgument).standardizedFileURL.path)
            }
            for candidate in candidates where !candidate.isEmpty {
                replacements[candidate] = durablePath
            }
        }

        guard !replacements.isEmpty else {
            return nil
        }

        let replayArgv = argv.map { replacements[$0] ?? $0 }
        return replayArgv == argv ? nil : replayArgv
    }

    public static func materializationProvenanceSteps(
        workflowVersion: String,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        startedAt: Date,
        endedAt: Date
    ) throws -> [ProvenanceStep] {
        let pairs = materializedInputPairs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        let stepWallTime = max(0, endedAt.timeIntervalSince(startedAt))
        return try pairs.map { pair in
            let command = materializationCommand(
                originalURL: pair.originalURL,
                executionURL: pair.executionURL
            )
            return ProvenanceStep(
                toolName: "lungfish fastq materialize",
                toolVersion: ProvenanceVersion.required(workflowVersion),
                argv: command,
                durableReplayArgv: command,
                reproducibleCommand: command.map(shellEscape).joined(separator: " "),
                inputs: try originalInputDescriptors(for: pair.originalURL),
                outputs: [
                    try executionInputDescriptor(
                        originalURL: pair.originalURL,
                        executionURL: pair.executionURL
                    )
                ],
                exitStatus: 0,
                wallTimeSeconds: stepWallTime,
                startedAt: startedAt,
                completedAt: endedAt
            )
        }
    }

    @discardableResult
    public static func writeMaterializationProvenanceOrCleanup(
        workflowName: String,
        workflowVersion: String,
        parentArgv: [String],
        parentDurableReplayArgv: [String]?,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        outputDirectory: URL,
        operationName: String,
        startedAt: Date,
        endedAt: Date,
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL? {
        do {
            return try writeMaterializationProvenance(
                workflowName: workflowName,
                workflowVersion: workflowVersion,
                parentArgv: parentArgv,
                parentDurableReplayArgv: parentDurableReplayArgv,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs,
                outputDirectory: outputDirectory,
                operationName: operationName,
                startedAt: startedAt,
                endedAt: endedAt,
                writer: writer
            )
        } catch {
            cleanupMaterializedOutputs(
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs
            )
            throw error
        }
    }

    @discardableResult
    public static func writeMaterializationProvenance(
        workflowName: String,
        workflowVersion: String,
        parentArgv: [String],
        parentDurableReplayArgv: [String]?,
        originalInputURLs: [URL],
        executionInputURLs: [URL],
        outputDirectory: URL,
        operationName: String,
        startedAt: Date,
        endedAt: Date,
        writer: ProvenanceWriter = ProvenanceWriter()
    ) throws -> URL? {
        let pairs = materializedInputPairs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        guard !pairs.isEmpty else {
            return nil
        }

        let steps = try materializationProvenanceSteps(
            workflowVersion: workflowVersion,
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let topLevelArgv = topLevelMaterializationArgv(from: steps)
        let explicitOptions: [String: ParameterValue] = [
            "operation": .string(operationName),
            "parentArgv": .array(parentArgv.map(ParameterValue.string)),
            "parentDurableReplayArgv": parentDurableReplayArgv.map {
                .array($0.map(ParameterValue.string))
            } ?? .null,
            "originalInputs": .array(originalInputURLs.map { .file($0.standardizedFileURL) }),
            "executionInputs": .array(executionInputURLs.map { .file($0.standardizedFileURL) }),
            "outputDirectory": .file(outputDirectory.standardizedFileURL),
        ]

        var builder = ProvenanceRunBuilder(
            workflowName: workflowName,
            workflowVersion: workflowVersion,
            toolName: "lungfish fastq materialize",
            toolVersion: workflowVersion
        )
        .argv(topLevelArgv)
        .durableReplayArgv(topLevelArgv)
        .reproducibleCommand(topLevelArgv.map(shellEscape).joined(separator: " "))
        .options(explicit: explicitOptions, defaults: [:], resolved: explicitOptions)
        .runtime(ProvenanceRuntimeIdentity(appVersion: workflowVersion))

        for step in steps {
            builder = builder.step(step)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
        return try writer.write(envelope, to: outputDirectory)
    }

    public static func cleanupMaterializedOutputs(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) {
        let fileManager = FileManager.default
        let pairs = materializedInputPairs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        for pair in pairs {
            try? fileManager.removeItem(at: pair.executionURL)
            let parentDirectory = pair.executionURL.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: parentDirectory.path).isEmpty) == true {
                try? fileManager.removeItem(at: parentDirectory)
            }
        }
    }

    public static func originalInputDescriptors(for inputURL: URL) throws -> [ProvenanceFileDescriptor] {
        let standardizedURL = inputURL.standardizedFileURL
        if let bundleURL = bundleRequiringMaterialization(for: standardizedURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            var descriptors = [try bundleAggregateDescriptor(for: bundleURL)]
            let rootBundleURL = FASTQBundle.resolveBundle(
                relativePath: manifest.rootBundleRelativePath,
                from: bundleURL
            )
            let rootPayloadURL = rootBundleURL
                .appendingPathComponent(manifest.rootFASTQFilename)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: rootPayloadURL.path) {
                descriptors.append(
                    try ProvenanceFileDescriptor.file(
                        url: rootPayloadURL,
                        format: provenanceFormat(for: rootPayloadURL),
                        role: .input,
                        originPath: bundleURL.path
                    )
                )
            }
            return descriptors
        }

        guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: standardizedURL) else {
            return []
        }
        return [
            try ProvenanceFileDescriptor.file(
                url: resolvedURL,
                format: provenanceFormat(for: resolvedURL),
                role: .input
            )
        ]
    }

    public static func executionInputDescriptor(
        originalURL: URL,
        executionURL: URL
    ) throws -> ProvenanceFileDescriptor {
        let originalPath = originalURL.standardizedFileURL.path
        let executionPath = executionURL.standardizedFileURL.path
        return try ProvenanceFileDescriptor.file(
            url: executionURL,
            format: provenanceFormat(for: executionURL),
            role: .input,
            originPath: originalPath == executionPath ? nil : originalPath
        )
    }

    public static func inputRecordsPreservingLineage(
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) throws -> [FileRecord] {
        var records: [FileRecord] = []
        for (index, originalURL) in originalInputURLs.enumerated() {
            let descriptors = try originalInputDescriptors(for: originalURL)
            records.append(contentsOf: descriptors.map(fileRecord))

            guard executionInputURLs.indices.contains(index) else { continue }
            let executionURL = executionInputURLs[index].standardizedFileURL
            if executionURL != originalURL.standardizedFileURL {
                records.append(
                    fileRecord(
                        try executionInputDescriptor(
                            originalURL: originalURL,
                            executionURL: executionURL
                        )
                    )
                )
            }
        }
        return deduplicated(records)
    }

    private static func payloadRequiresMaterialization(_ payload: FASTQDerivativePayload) -> Bool {
        switch payload {
        case .full, .fullFASTA, .fullPaired, .fullMixed:
            return false
        case .subset, .trim, .demuxedVirtual, .orientMap:
            return true
        case .demuxGroup:
            return false
        }
    }

    private static func bundleAggregateDescriptor(for bundleURL: URL) throws -> ProvenanceFileDescriptor {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: bundleURL, role: .input)
        return ProvenanceFileDescriptor(
            path: bundleURL.standardizedFileURL.path,
            checksumSHA256: directoryChecksum(from: manifest),
            fileSize: directorySize(from: manifest),
            format: .unknown,
            role: .input
        )
    }

    private static func fileRecord(_ descriptor: ProvenanceFileDescriptor) -> FileRecord {
        FileRecord(
            path: descriptor.path,
            sha256: descriptor.checksumSHA256,
            sizeBytes: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role
        )
    }

    private static func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    private static func provenanceFormat(for url: URL) -> FileFormat? {
        if let sequenceFormat = SequenceFormat.from(url: url) {
            switch sequenceFormat {
            case .fasta:
                return .fasta
            case .fastq:
                return .fastq
            }
        }

        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "log", "txt", "tsv":
            return .text
        case "fa", "fasta", "fna":
            return .fasta
        case "fq", "fastq":
            return .fastq
        default:
            return .unknown
        }
    }

    private static func deduplicated(_ records: [FileRecord]) -> [FileRecord] {
        var seen = Set<String>()
        var result: [FileRecord] = []
        for record in records where seen.insert(record.path).inserted {
            result.append(record)
        }
        return result
    }

    private static func cleanupNewMaterializationOutputs(
        in tempDirectory: URL,
        preexistingPathExisted: Bool,
        preexistingEntries: Set<String>?,
        materializedPairs: [CLISequenceInputMaterializationPair]
    ) {
        let fileManager = FileManager.default
        for pair in materializedPairs {
            try? fileManager.removeItem(at: pair.executionURL)
        }

        guard let preexistingEntries else {
            if !preexistingPathExisted {
                try? fileManager.removeItem(at: tempDirectory)
            }
            return
        }
        guard let currentEntries = try? fileManager.contentsOfDirectory(atPath: tempDirectory.path) else {
            return
        }
        for entry in currentEntries where !preexistingEntries.contains(entry) {
            try? fileManager.removeItem(at: tempDirectory.appendingPathComponent(entry))
        }
    }

    private static func topLevelMaterializationArgv(from steps: [ProvenanceStep]) -> [String] {
        let commands = steps.map(\.argv)
        guard commands.count > 1 else {
            return commands.first ?? []
        }
        return [
            "/bin/sh",
            "-lc",
            commands.map { $0.map(shellEscape).joined(separator: " ") }.joined(separator: " && "),
        ]
    }
}
