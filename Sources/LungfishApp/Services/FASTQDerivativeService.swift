// FASTQDerivativeService.swift - Pointer-based FASTQ derivative creation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import os.log

private let derivativeLogger = Logger(subsystem: "com.lungfish.browser", category: "FASTQDerivativeService")

public enum FASTQDerivativeRequest: Sendable {
    case subsampleProportion(Double)
    case subsampleCount(Int)
    case lengthFilter(min: Int?, max: Int?)
    case searchText(query: String, field: FASTQSearchField, regex: Bool)
    case searchMotif(pattern: String, regex: Bool)
    case deduplicate(mode: FASTQDeduplicateMode, pairedAware: Bool)
}

public enum FASTQDerivativeError: Error, LocalizedError {
    case sourceMustBeBundle
    case sourceFASTQMissing
    case derivedManifestMissing
    case parentBundleMissing(String)
    case rootBundleMissing(String)
    case rootFASTQMissing
    case invalidOperation(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .sourceMustBeBundle:
            return "FASTQ operations require a .lungfishfastq bundle."
        case .sourceFASTQMissing:
            return "The source FASTQ file is missing from the bundle."
        case .derivedManifestMissing:
            return "Derived FASTQ manifest is missing."
        case .parentBundleMissing(let path):
            return "Parent FASTQ bundle not found: \(path)"
        case .rootBundleMissing(let path):
            return "Root FASTQ bundle not found: \(path)"
        case .rootFASTQMissing:
            return "Root FASTQ payload is missing."
        case .invalidOperation(let reason):
            return "Invalid FASTQ operation: \(reason)"
        case .emptyResult:
            return "Operation produced no reads."
        }
    }
}

/// Creates pointer-based FASTQ derivative bundles using bundled tools.
public actor FASTQDerivativeService {
    public static let shared = FASTQDerivativeService()

    private let runner = NativeToolRunner.shared

    public init() {}

    public func createDerivative(
        from sourceBundleURL: URL,
        request: FASTQDerivativeRequest,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard FASTQBundle.isBundleURL(sourceBundleURL) else {
            throw FASTQDerivativeError.sourceMustBeBundle
        }

        let tempDir = try makeTemporaryDirectory(prefix: "fastq-derive-")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        progress?("Resolving source dataset...")
        let materializedSourceFASTQ = try await materializeDatasetFASTQ(
            fromBundle: sourceBundleURL,
            tempDirectory: tempDir,
            progress: progress
        )

        progress?("Applying transformation...")
        let transformedFASTQ = tempDir.appendingPathComponent("transformed.fastq")
        let operation = try await runTransformation(
            request: request,
            sourceFASTQ: materializedSourceFASTQ,
            outputFASTQ: transformedFASTQ,
            sourceBundleURL: sourceBundleURL,
            progress: progress
        )

        progress?("Computing output statistics...")
        let reader = FASTQReader(validateSequence: false)
        let (stats, _) = try await reader.computeStatistics(from: transformedFASTQ, sampleLimit: 0)
        guard stats.readCount > 0 else {
            throw FASTQDerivativeError.emptyResult
        }

        progress?("Extracting read pointers...")
        let readIDListURL = tempDir.appendingPathComponent("read-ids.txt")
        let readCount = try await writeReadIDs(fromFASTQ: transformedFASTQ, to: readIDListURL)
        guard readCount > 0 else {
            throw FASTQDerivativeError.emptyResult
        }

        let sourceManifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL)
        let parentRelativePath = "../\(sourceBundleURL.lastPathComponent)"
        let rootRelativePath: String
        let rootFASTQFilename: String
        let pairingMode: IngestionMetadata.PairingMode?
        let lineage: [FASTQDerivativeOperation]

        if let sourceManifest {
            rootRelativePath = sourceManifest.rootBundleRelativePath
            rootFASTQFilename = sourceManifest.rootFASTQFilename
            pairingMode = sourceManifest.pairingMode
            lineage = sourceManifest.lineage + [operation]
        } else {
            guard let rootFASTQURL = FASTQBundle.resolvePrimaryFASTQURL(for: sourceBundleURL) else {
                throw FASTQDerivativeError.sourceFASTQMissing
            }
            rootRelativePath = "../\(sourceBundleURL.lastPathComponent)"
            rootFASTQFilename = rootFASTQURL.lastPathComponent
            pairingMode = FASTQMetadataStore.load(for: rootFASTQURL)?.ingestion?.pairingMode
            lineage = [operation]
        }

        let outputBundle = try createOutputBundleURL(
            sourceBundleURL: sourceBundleURL,
            operation: operation
        )
        try FileManager.default.createDirectory(at: outputBundle, withIntermediateDirectories: true)

        let destinationReadIDURL = outputBundle.appendingPathComponent("read-ids.txt")
        try FileManager.default.copyItem(at: readIDListURL, to: destinationReadIDURL)

        let manifest = FASTQDerivedBundleManifest(
            name: outputBundle.deletingPathExtension().lastPathComponent,
            parentBundleRelativePath: parentRelativePath,
            rootBundleRelativePath: rootRelativePath,
            rootFASTQFilename: rootFASTQFilename,
            readIDListFilename: destinationReadIDURL.lastPathComponent,
            lineage: lineage,
            operation: operation,
            cachedStatistics: stats,
            pairingMode: pairingMode
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: outputBundle)

        progress?("Created derived dataset: \(outputBundle.lastPathComponent)")
        derivativeLogger.info("Created FASTQ derivative bundle at \(outputBundle.path, privacy: .public)")
        return outputBundle
    }

    // MARK: - Transformations

    private func runTransformation(
        request: FASTQDerivativeRequest,
        sourceFASTQ: URL,
        outputFASTQ: URL,
        sourceBundleURL: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> FASTQDerivativeOperation {
        switch request {
        case .subsampleProportion(let proportion):
            guard proportion > 0.0, proportion <= 1.0 else {
                throw FASTQDerivativeError.invalidOperation("proportion must be in (0, 1]")
            }
            _ = try await runner.run(
                .seqkit,
                arguments: ["sample", "-p", String(proportion), sourceFASTQ.path, "-o", outputFASTQ.path]
            )
            return FASTQDerivativeOperation(
                kind: .subsampleProportion,
                proportion: proportion
            )

        case .subsampleCount(let count):
            guard count > 0 else {
                throw FASTQDerivativeError.invalidOperation("count must be > 0")
            }
            _ = try await runner.run(
                .seqkit,
                arguments: ["sample", "-n", String(count), sourceFASTQ.path, "-o", outputFASTQ.path]
            )
            return FASTQDerivativeOperation(
                kind: .subsampleCount,
                count: count
            )

        case .lengthFilter(let minLength, let maxLength):
            var args = ["seq"]
            if let minLength {
                args += ["-m", String(minLength)]
            }
            if let maxLength {
                args += ["-M", String(maxLength)]
            }
            args += [sourceFASTQ.path, "-o", outputFASTQ.path]
            _ = try await runner.run(.seqkit, arguments: args)
            return FASTQDerivativeOperation(
                kind: .lengthFilter,
                minLength: minLength,
                maxLength: maxLength
            )

        case .searchText(let query, let field, let regex):
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FASTQDerivativeError.invalidOperation("query cannot be empty")
            }
            var args = ["grep"]
            if field == .description {
                args.append("-n")
            }
            if regex {
                args.append("-r")
            }
            args += ["-p", query, sourceFASTQ.path, "-o", outputFASTQ.path]
            _ = try await runner.run(.seqkit, arguments: args)
            return FASTQDerivativeOperation(
                kind: .searchText,
                query: query,
                searchField: field,
                useRegex: regex
            )

        case .searchMotif(let pattern, let regex):
            guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FASTQDerivativeError.invalidOperation("motif cannot be empty")
            }
            var args = ["grep", "-s"]
            if regex {
                args.append("-r")
            }
            args += ["-p", pattern, sourceFASTQ.path, "-o", outputFASTQ.path]
            _ = try await runner.run(.seqkit, arguments: args)
            return FASTQDerivativeOperation(
                kind: .searchMotif,
                query: pattern,
                useRegex: regex
            )

        case .deduplicate(let mode, let pairedAware):
            if pairedAware, isInterleavedBundle(sourceBundleURL) {
                try await deduplicateInterleavedPairs(
                    mode: mode,
                    sourceFASTQ: sourceFASTQ,
                    outputFASTQ: outputFASTQ
                )
            } else {
                var args = ["rmdup"]
                switch mode {
                case .identifier, .description:
                    args.append("-n")
                case .sequence:
                    args.append("-s")
                }
                args += [sourceFASTQ.path, "-o", outputFASTQ.path]
                _ = try await runner.run(.seqkit, arguments: args)
            }
            return FASTQDerivativeOperation(
                kind: .deduplicate,
                deduplicateMode: mode,
                pairedAware: pairedAware
            )
        }
    }

    // MARK: - Materialization

    private func materializeDatasetFASTQ(
        fromBundle bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        if let payload = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return payload
        }

        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            throw FASTQDerivativeError.derivedManifestMissing
        }

        let rootBundleURL = FASTQBundle.resolveBundle(
            relativePath: manifest.rootBundleRelativePath,
            from: bundleURL
        )
        guard FASTQBundle.isBundleURL(rootBundleURL) else {
            throw FASTQDerivativeError.rootBundleMissing(manifest.rootBundleRelativePath)
        }

        let rootFASTQURL = rootBundleURL.appendingPathComponent(manifest.rootFASTQFilename)
        guard FileManager.default.fileExists(atPath: rootFASTQURL.path) else {
            throw FASTQDerivativeError.rootFASTQMissing
        }

        let readIDListURL = bundleURL.appendingPathComponent(manifest.readIDListFilename)
        let outputURL = tempDirectory.appendingPathComponent("materialized.fastq")
        progress?("Materializing pointer dataset...")
        try await extractReads(
            fromRootFASTQ: rootFASTQURL,
            readIDsFile: readIDListURL,
            outputFASTQ: outputURL
        )
        return outputURL
    }

    private func extractReads(
        fromRootFASTQ rootFASTQ: URL,
        readIDsFile: URL,
        outputFASTQ: URL
    ) async throws {
        let idCounts = try loadReadIDCounts(from: readIDsFile)
        if idCounts.isEmpty {
            throw FASTQDerivativeError.emptyResult
        }

        var mutableCounts = idCounts
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)

        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.streamRecords(from: rootFASTQ) {
            let key = normalizedIdentifier(record.identifier)
            if let remaining = mutableCounts[key], remaining > 0 {
                try writer.write(record)
                if remaining == 1 {
                    mutableCounts.removeValue(forKey: key)
                } else {
                    mutableCounts[key] = remaining - 1
                }
            }
        }
    }

    // MARK: - Helpers

    private func writeReadIDs(fromFASTQ fastqURL: URL, to outputURL: URL) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var count = 0
        for try await record in reader.streamRecords(from: fastqURL) {
            let line = normalizedIdentifier(record.identifier) + "\n"
            try handle.write(contentsOf: Data(line.utf8))
            count += 1
        }
        return count
    }

    private func loadReadIDCounts(from fileURL: URL) throws -> [String: Int] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var counts: [String: Int] = [:]
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let key = normalizedIdentifier(String(rawLine))
            counts[key, default: 0] += 1
        }
        return counts
    }

    private func createOutputBundleURL(
        sourceBundleURL: URL,
        operation: FASTQDerivativeOperation
    ) throws -> URL {
        let parent = sourceBundleURL.deletingLastPathComponent()
        let sourceName = sourceBundleURL.deletingPathExtension().lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let base = "\(sourceName)-\(operation.shortLabel)-\(timestamp)"

        var candidate = parent.appendingPathComponent("\(base).\(FASTQBundle.directoryExtension)", isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(suffix).\(FASTQBundle.directoryExtension)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isInterleavedBundle(_ bundleURL: URL) -> Bool {
        if let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) {
            return manifest.pairingMode == .interleaved
        }
        if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return FASTQMetadataStore.load(for: fastqURL)?.ingestion?.pairingMode == .interleaved
        }
        return false
    }

    private func normalizedIdentifier(_ identifier: String) -> String {
        var value = identifier
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        return value
    }

    private func deduplicateInterleavedPairs(
        mode: FASTQDeduplicateMode,
        sourceFASTQ: URL,
        outputFASTQ: URL
    ) async throws {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        var buffer: FASTQRecord?
        var seen: Set<String> = []

        for try await record in reader.streamRecords(from: sourceFASTQ) {
            if let first = buffer {
                let second = record
                let key = pairedKey(first: first, second: second, mode: mode)
                if !seen.contains(key) {
                    seen.insert(key)
                    try writer.write(first)
                    try writer.write(second)
                }
                buffer = nil
            } else {
                buffer = record
            }
        }

        // If an odd trailing record exists, preserve first appearance.
        if let trailing = buffer {
            let key = singleKey(record: trailing, mode: mode)
            if !seen.contains(key) {
                try writer.write(trailing)
            }
        }
    }

    private func pairedKey(first: FASTQRecord, second: FASTQRecord, mode: FASTQDeduplicateMode) -> String {
        switch mode {
        case .identifier:
            let left = stripPairSuffix(from: normalizedIdentifier(first.identifier))
            let right = stripPairSuffix(from: normalizedIdentifier(second.identifier))
            return "id:\(left)|\(right)"
        case .description:
            let left = (first.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let right = (second.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "desc:\(left)|\(right)"
        case .sequence:
            return "seq:\(first.sequence)|\(second.sequence)"
        }
    }

    private func singleKey(record: FASTQRecord, mode: FASTQDeduplicateMode) -> String {
        switch mode {
        case .identifier:
            return "id:\(normalizedIdentifier(record.identifier))"
        case .description:
            return "desc:\((record.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
        case .sequence:
            return "seq:\(record.sequence)"
        }
    }

    private func stripPairSuffix(from identifier: String) -> String {
        if identifier.hasSuffix("/1") || identifier.hasSuffix("/2") {
            return String(identifier.dropLast(2))
        }
        return identifier
    }
}
