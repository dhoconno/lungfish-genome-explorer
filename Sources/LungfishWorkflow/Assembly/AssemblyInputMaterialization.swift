// AssemblyInputMaterialization.swift - assembly-safe FASTQ input materialization helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishIO

/// Detects derived FASTQ bundles that must be materialized before assembly.
public enum AssemblyInputMaterialization {
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

    public static func unsupportedAssemblyInputMessage(for inputURL: URL) -> String? {
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL.standardizedFileURL),
              let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            return nil
        }

        switch manifest.payload {
        case .demuxGroup:
            return "Demultiplexed group bundles are container-only; select an individual demultiplexed FASTQ bundle for assembly."
        default:
            return nil
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
    ) -> [InputFileRecord] {
        var records: [InputFileRecord] = []
        for (index, originalURL) in originalInputURLs.enumerated() {
            records.append(contentsOf: originalInputRecords(for: originalURL))
            guard executionInputURLs.indices.contains(index) else { continue }
            let executionURL = executionInputURLs[index].standardizedFileURL
            if executionURL != originalURL.standardizedFileURL {
                records.append(inputRecord(forFile: executionURL, originPath: executionURL.path))
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

    private static func originalInputRecords(for inputURL: URL) -> [InputFileRecord] {
        let standardizedURL = inputURL.standardizedFileURL
        if let bundleURL = bundleRequiringMaterialization(for: standardizedURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            var records = [bundleAggregateRecord(for: bundleURL)]
            let rootBundleURL = FASTQBundle.resolveBundle(
                relativePath: manifest.rootBundleRelativePath,
                from: bundleURL
            )
            let rootPayloadURL = rootBundleURL
                .appendingPathComponent(manifest.rootFASTQFilename)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: rootPayloadURL.path) {
                records.append(inputRecord(forFile: rootPayloadURL, originPath: rootPayloadURL.path))
            }
            return records
        }

        guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: standardizedURL) else {
            return []
        }
        return [inputRecord(forFile: resolvedURL, originPath: resolvedURL.path)]
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

    private static func bundleAggregateRecord(for bundleURL: URL) -> InputFileRecord {
        guard let manifest = try? ProvenanceFileHasher.directoryManifest(for: bundleURL, role: .input) else {
            return InputFileRecord(
                filename: bundleURL.lastPathComponent,
                originalPath: bundleURL.standardizedFileURL.path,
                sha256: nil,
                sizeBytes: 0
            )
        }
        return InputFileRecord(
            filename: bundleURL.lastPathComponent,
            originalPath: bundleURL.standardizedFileURL.path,
            sha256: directoryChecksum(from: manifest),
            sizeBytes: Int64(clamping: directorySize(from: manifest))
        )
    }

    private static func inputRecord(forFile url: URL, originPath: String?) -> InputFileRecord {
        let standardizedURL = url.standardizedFileURL
        let size = (try? ProvenanceFileHasher.fileSize(of: standardizedURL)).map(Int64.init(clamping:)) ?? 0
        let checksum = try? ProvenanceFileHasher.sha256(of: standardizedURL)
        return InputFileRecord(
            filename: standardizedURL.lastPathComponent,
            originalPath: originPath,
            sha256: checksum,
            sizeBytes: size
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

    private static func deduplicated(_ records: [InputFileRecord]) -> [InputFileRecord] {
        var seen = Set<String>()
        var result: [InputFileRecord] = []
        for record in records {
            let key = record.originalPath ?? record.filename
            if seen.insert(key).inserted {
                result.append(record)
            }
        }
        return result
    }
}
