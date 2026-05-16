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
        var resolvedURLs: [URL] = []
        var materializedPairs: [CLISequenceInputMaterializationPair] = []
        var materializationStartedAt: Date?
        var materializationEndedAt: Date?

        for inputURL in inputURLs {
            let originalURL = inputURL.standardizedFileURL
            if let unsupportedMessage = unsupportedSequenceInputMessage(for: originalURL, operationName: operationName) {
                throw CLISequenceInputMaterializationError.unsupportedSequenceInput(unsupportedMessage)
            }

            if let bundleURL = bundleRequiringMaterialization(for: originalURL) {
                if materializationStartedAt == nil {
                    materializationStartedAt = Date()
                }
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
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
                continue
            }

            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: originalURL) else {
                throw CLISequenceInputMaterializationError.unreadableSequenceInput(originalURL.path)
            }
            resolvedURLs.append(resolvedURL.standardizedFileURL)
        }

        return CLISequenceInputMaterializationResult(
            inputURLs: resolvedURLs,
            originalInputURLs: inputURLs,
            materializedPairs: materializedPairs,
            materializationStartedAt: materializationStartedAt,
            materializationEndedAt: materializationEndedAt
        )
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
}
