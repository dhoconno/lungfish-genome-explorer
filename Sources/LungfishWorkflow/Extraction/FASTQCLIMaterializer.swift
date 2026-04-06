// FASTQCLIMaterializer.swift - CLI-native FASTQ bundle materialization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Materializes virtual `.lungfishfastq` bundles to physical FASTQ files without
/// requiring the full LungfishApp stack (AppKit, SwiftUI, UI services).
///
/// This is the CLI counterpart to `FASTQDerivativeService.materializeDatasetFASTQ`.
/// It supports all payload cases that can be performed with seqkit + pure-Swift I/O:
/// `.subset`, `.trim`, `.full`, `.fullPaired`, `.fullMixed`, `.fullFASTA`, `.orientMap`,
/// and `.demuxedVirtual`.
///
/// ## Usage
///
/// ```swift
/// let materializer = FASTQCLIMaterializer(runner: NativeToolRunner.shared)
/// let outputURL = try await materializer.materialize(
///     bundleURL: myBundleURL,
///     tempDirectory: tempDir,
///     progress: { msg in print(msg) }
/// )
/// ```
public final class FASTQCLIMaterializer: Sendable {

    private let runner: NativeToolRunner

    public init(runner: NativeToolRunner) {
        self.runner = runner
    }

    // MARK: - Public API

    /// Materializes a `.lungfishfastq` bundle (physical or virtual) into a single FASTQ file.
    ///
    /// - Parameters:
    ///   - bundleURL: The bundle to materialize.
    ///   - tempDirectory: Directory for intermediate/output files.
    ///   - progress: Optional progress message callback.
    /// - Returns: URL of the materialized FASTQ (inside `tempDirectory` for virtual bundles,
    ///   or a physical file URL for root bundles).
    public func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        // Physical bundles: return their primary FASTQ directly (no copy needed)
        if !FASTQBundle.isDerivedBundle(bundleURL),
           let physicalURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return physicalURL
        }

        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            if let physicalURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
                return physicalURL
            }
            throw FASTQCLIMaterializerError.derivedManifestMissing
        }

        var rootBundleURL = FASTQBundle.resolveBundle(
            relativePath: manifest.rootBundleRelativePath,
            from: bundleURL
        )

        // Attempt legacy broken path recovery
        if !FASTQBundle.isBundleURL(rootBundleURL),
           let recovered = FASTQBundle.findBundleContaining(
               fastqFilename: manifest.rootFASTQFilename, from: bundleURL
           ) {
            rootBundleURL = recovered

            // Repair the manifest with a project-relative path for future operations
            if let projectPath = FASTQBundle.projectRelativePath(for: recovered, from: bundleURL) {
                let repairedManifest = FASTQDerivedBundleManifest(
                    id: manifest.id,
                    name: manifest.name,
                    createdAt: manifest.createdAt,
                    parentBundleRelativePath: manifest.parentBundleRelativePath,
                    rootBundleRelativePath: projectPath,
                    rootFASTQFilename: manifest.rootFASTQFilename,
                    payload: manifest.payload,
                    lineage: manifest.lineage,
                    operation: manifest.operation,
                    cachedStatistics: manifest.cachedStatistics,
                    pairingMode: manifest.pairingMode,
                    readClassification: manifest.readClassification,
                    batchOperationID: manifest.batchOperationID,
                    sequenceFormat: manifest.sequenceFormat,
                    provenance: manifest.provenance,
                    payloadChecksums: manifest.payloadChecksums,
                    materializationState: manifest.materializationState
                )
                try? FASTQBundle.saveDerivedManifest(repairedManifest, in: bundleURL)
            }
        }

        guard FASTQBundle.isBundleURL(rootBundleURL) else {
            throw FASTQCLIMaterializerError.rootBundleMissing(manifest.rootBundleRelativePath)
        }

        let rootFASTQURL = rootBundleURL.appendingPathComponent(manifest.rootFASTQFilename)
        guard FileManager.default.fileExists(atPath: rootFASTQURL.path) else {
            throw FASTQCLIMaterializerError.rootFASTQMissing
        }

        let outputExtension = (manifest.sequenceFormat ?? .fastq).fileExtension
        let outputURL = tempDirectory.appendingPathComponent("materialized.\(outputExtension)")
        progress?("Materializing pointer dataset...")

        switch manifest.payload {
        case .subset(let readIDFilename):
            let readIDListURL = bundleURL.appendingPathComponent(readIDFilename)
            let trimURL = bundleTrimPositionsURL(bundleURL)
            let orientURL = bundleOrientMapURL(bundleURL)
            if manifest.sequenceFormat == .fasta {
                try await materializeFASTASubset(
                    rootFASTAURL: rootFASTQURL,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            } else {
                try await materializeFASTQSubset(
                    rootFASTQURL: rootFASTQURL,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            }

        case .trim(let trimFilename):
            let trimURL = bundleURL.appendingPathComponent(trimFilename)
            guard isAbsoluteTrimPositionsFile(trimURL) else {
                throw FASTQCLIMaterializerError.unsupportedTrimFormat(
                    "Legacy relative trim format not supported by CLI materializer"
                )
            }
            let positions = try FASTQTrimPositionFile.load(from: trimURL)
            if manifest.sequenceFormat == .fasta {
                try await extractTrimmedFASTAReads(
                    fromRootFASTA: rootFASTQURL,
                    positions: positions,
                    outputFASTA: outputURL
                )
            } else {
                try await extractTrimmedReads(
                    fromRootFASTQ: rootFASTQURL,
                    positions: positions,
                    outputFASTQ: outputURL
                )
            }

        case .full(let fastqFilename):
            let fullFASTQURL = bundleURL.appendingPathComponent(fastqFilename)
            guard FileManager.default.fileExists(atPath: fullFASTQURL.path) else {
                throw FASTQCLIMaterializerError.sourceFASTQMissing
            }
            try FileManager.default.copyItem(at: fullFASTQURL, to: outputURL)

        case .fullFASTA(let fastaFilename):
            let fullFASTAURL = bundleURL.appendingPathComponent(fastaFilename)
            guard FileManager.default.fileExists(atPath: fullFASTAURL.path) else {
                throw FASTQCLIMaterializerError.sourceFASTQMissing
            }
            try FileManager.default.copyItem(at: fullFASTAURL, to: outputURL)

        case .fullPaired(let r1Filename, let r2Filename):
            let r1URL = bundleURL.appendingPathComponent(r1Filename)
            let r2URL = bundleURL.appendingPathComponent(r2Filename)
            guard FileManager.default.fileExists(atPath: r1URL.path),
                  FileManager.default.fileExists(atPath: r2URL.path) else {
                throw FASTQCLIMaterializerError.sourceFASTQMissing
            }
            try await interleaveWithReformat(r1URL: r1URL, r2URL: r2URL, outputURL: outputURL)

        case .fullMixed(let classification):
            try await materializeFullMixed(
                classification: classification,
                bundleURL: bundleURL,
                tempDirectory: tempDirectory,
                outputURL: outputURL
            )

        case .demuxedVirtual(_, let readIDFilename, _, let trimPositionsFilename, let orientMapFilename):
            let readIDListURL = bundleURL.appendingPathComponent(readIDFilename)
            let trimURL = trimPositionsFilename.map { bundleURL.appendingPathComponent($0) }
            let orientURL = orientMapFilename.map { bundleURL.appendingPathComponent($0) }
            try await materializeFASTQSubset(
                rootFASTQURL: rootFASTQURL,
                readIDListURL: readIDListURL,
                trimPositionsURL: trimURL,
                orientMapURL: orientURL,
                outputURL: outputURL
            )

        case .orientMap(let orientMapFilename, _):
            let mapURL = bundleURL.appendingPathComponent(orientMapFilename)
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: mapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: mapURL)
            try await materializeOrientedReads(
                fromRootFASTQ: rootFASTQURL,
                forwardReadIDs: fwdReadIDs,
                rcReadIDs: rcReadIDs,
                outputFASTQ: outputURL
            )

        case .demuxGroup:
            // demuxGroup bundles are container-only (no physical FASTQ of their own);
            // materialization at this level is not supported — callers should
            // iterate the child bundles instead.
            throw FASTQCLIMaterializerError.unsupportedPayload("demuxGroup")
        }

        return outputURL
    }

    // MARK: - Subset Materialization

    private func materializeFASTQSubset(
        rootFASTQURL: URL,
        readIDListURL: URL,
        trimPositionsURL: URL?,
        orientMapURL: URL?,
        outputURL: URL
    ) async throws {
        let fm = FileManager.default

        let extractTarget: URL
        var orientTempURL: URL?
        if orientMapURL != nil {
            let tmp = outputURL.deletingLastPathComponent()
                .appendingPathComponent("pre-orient-\(UUID().uuidString).fastq")
            orientTempURL = tmp
            extractTarget = tmp
        } else {
            extractTarget = outputURL
        }
        defer {
            if let url = orientTempURL { try? fm.removeItem(at: url) }
        }

        if let trimPositionsURL, isAbsoluteTrimPositionsFile(trimPositionsURL) {
            // Filter trim positions to only selected read IDs, then extract trimmed
            let positions = try FASTQTrimPositionFile.load(from: trimPositionsURL)
            let selectedIDs = try loadSelectedReadIDSet(from: readIDListURL)
            let filtered = positions.filter { selectedIDs.contains($0.key) }
            try await extractTrimmedReads(
                fromRootFASTQ: rootFASTQURL,
                positions: filtered,
                outputFASTQ: extractTarget
            )
        } else {
            // Extract subset by read ID list using seqkit grep
            try await extractReadsByIDList(
                rootFASTQURL: rootFASTQURL,
                readIDListURL: readIDListURL,
                outputFASTQ: extractTarget
            )
            // Apply trim in a second pass if needed
            if let trimURL = trimPositionsURL, fm.fileExists(atPath: trimURL.path) {
                let positions = try FASTQTrimPositionFile.load(from: trimURL)
                let tempTrimmed = extractTarget.deletingLastPathComponent()
                    .appendingPathComponent("trimmed-\(UUID().uuidString).fastq")
                try await extractTrimmedReads(
                    fromRootFASTQ: extractTarget,
                    positions: positions,
                    outputFASTQ: tempTrimmed
                )
                try fm.removeItem(at: extractTarget)
                try fm.moveItem(at: tempTrimmed, to: extractTarget)
            }
        }

        if let orientMapURL, fm.fileExists(atPath: orientMapURL.path) {
            let fwdIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            try await materializeOrientedReads(
                fromRootFASTQ: extractTarget,
                forwardReadIDs: fwdIDs,
                rcReadIDs: rcIDs,
                outputFASTQ: outputURL
            )
        }
    }

    private func materializeFASTASubset(
        rootFASTAURL: URL,
        readIDListURL: URL,
        trimPositionsURL: URL?,
        orientMapURL: URL?,
        outputURL: URL
    ) async throws {
        let fm = FileManager.default

        let extractTarget: URL
        var orientTempURL: URL?
        if orientMapURL != nil {
            let tmp = outputURL.deletingLastPathComponent()
                .appendingPathComponent("pre-orient-\(UUID().uuidString).fasta")
            orientTempURL = tmp
            extractTarget = tmp
        } else {
            extractTarget = outputURL
        }
        defer {
            if let url = orientTempURL { try? fm.removeItem(at: url) }
        }

        if let trimPositionsURL, isAbsoluteTrimPositionsFile(trimPositionsURL) {
            let positions = try FASTQTrimPositionFile.load(from: trimPositionsURL)
            let selectedIDs = try loadSelectedReadIDSet(from: readIDListURL)
            let filtered = positions.filter { selectedIDs.contains($0.key) }
            try await extractTrimmedFASTAReads(
                fromRootFASTA: rootFASTAURL,
                positions: filtered,
                outputFASTA: extractTarget
            )
        } else {
            // Use seqkit for FASTA subset extraction too
            try await extractReadsByIDList(
                rootFASTQURL: rootFASTAURL,
                readIDListURL: readIDListURL,
                outputFASTQ: extractTarget
            )
        }

        if let orientMapURL, fm.fileExists(atPath: orientMapURL.path) {
            let fwdIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            try await materializeOrientedFASTAReads(
                fromRootFASTA: extractTarget,
                forwardReadIDs: fwdIDs,
                rcReadIDs: rcIDs,
                outputFASTA: outputURL
            )
        }
    }

    // MARK: - seqkit grep extraction

    private func extractReadsByIDList(
        rootFASTQURL: URL,
        readIDListURL: URL,
        outputFASTQ: URL
    ) async throws {
        // Resolve multi-file bundles
        var inputPaths = [rootFASTQURL.path]
        let parentBundle = rootFASTQURL.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundle),
           let allURLs = FASTQBundle.resolveAllFASTQURLs(for: parentBundle),
           allURLs.count > 1 {
            inputPaths = allURLs.map(\.path)
        }

        var args = ["grep", "-f", readIDListURL.path]
        args.append(contentsOf: inputPaths)
        args.append(contentsOf: ["-o", outputFASTQ.path])

        let timeout = max(600.0, Double(inputPaths.count) * 120.0)
        let result = try await runner.run(.seqkit, arguments: args, timeout: timeout)
        guard result.isSuccess else {
            throw FASTQCLIMaterializerError.toolFailed("seqkit grep", result.stderr)
        }
    }

    // MARK: - Trim extraction (pure Swift I/O)

    private func extractTrimmedReads(
        fromRootFASTQ rootFASTQ: URL,
        positions: [String: (start: Int, end: Int)],
        outputFASTQ: URL
    ) async throws {
        guard !positions.isEmpty else {
            throw FASTQCLIMaterializerError.emptyResult
        }

        let usesPositionalKeys = positions.keys.contains(where: { $0.contains("#") })
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        if usesPositionalKeys {
            var occurrencePerBaseID: [String: Int] = [:]
            for try await record in reader.records(from: rootFASTQ) {
                let baseID = normalizedIdentifier(record.identifier)
                let ordinal = occurrencePerBaseID[baseID] ?? 0
                occurrencePerBaseID[baseID] = ordinal + 1
                let key = "\(baseID)#\(ordinal)"
                guard let pos = positions[key] else { continue }
                let trimmed = record.trimmed(from: pos.start, to: pos.end)
                if trimmed.length > 0 { try writer.write(trimmed) }
            }
        } else {
            for try await record in reader.records(from: rootFASTQ) {
                let key = normalizedIdentifier(record.identifier)
                guard let pos = positions[key] else { continue }
                let trimmed = record.trimmed(from: pos.start, to: pos.end)
                if trimmed.length > 0 { try writer.write(trimmed) }
            }
        }
    }

    private func extractTrimmedFASTAReads(
        fromRootFASTA rootFASTA: URL,
        positions: [String: (start: Int, end: Int)],
        outputFASTA: URL
    ) async throws {
        guard !positions.isEmpty else {
            throw FASTQCLIMaterializerError.emptyResult
        }

        let usesPositionalKeys = positions.keys.contains(where: { $0.contains("#") })
        let reader = try FASTAReader(url: rootFASTA)
        FileManager.default.createFile(atPath: outputFASTA.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFASTA)
        defer { try? handle.close() }

        if usesPositionalKeys {
            var occurrencePerBaseID: [String: Int] = [:]
            for try await seq in reader.sequences() {
                let baseID = normalizedIdentifier(seq.name)
                let ordinal = occurrencePerBaseID[baseID] ?? 0
                occurrencePerBaseID[baseID] = ordinal + 1
                let key = "\(baseID)#\(ordinal)"
                guard let pos = positions[key] else { continue }
                let full = seq.asString()
                let start = min(pos.start, full.count)
                let end = min(pos.end, full.count)
                guard end > start else { continue }
                let trimmedSeq = String(full.dropFirst(start).prefix(end - start))
                writeFASTARecord(name: seq.name, sequence: trimmedSeq, to: handle)
            }
        } else {
            for try await seq in reader.sequences() {
                let key = normalizedIdentifier(seq.name)
                guard let pos = positions[key] else { continue }
                let full = seq.asString()
                let start = min(pos.start, full.count)
                let end = min(pos.end, full.count)
                guard end > start else { continue }
                let trimmedSeq = String(full.dropFirst(start).prefix(end - start))
                writeFASTARecord(name: seq.name, sequence: trimmedSeq, to: handle)
            }
        }
    }

    // MARK: - Orient materialization

    private func materializeOrientedReads(
        fromRootFASTQ rootFASTQ: URL,
        forwardReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTQ: URL
    ) async throws {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: rootFASTQ) {
            let id = normalizedIdentifier(record.identifier)
            if rcReadIDs.contains(id) {
                try writer.write(record.reverseComplement())
            } else if forwardReadIDs.contains(id) {
                try writer.write(record)
            }
        }
    }

    private func materializeOrientedFASTAReads(
        fromRootFASTA rootFASTA: URL,
        forwardReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTA: URL
    ) async throws {
        let reader = try FASTAReader(url: rootFASTA)
        FileManager.default.createFile(atPath: outputFASTA.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFASTA)
        defer { try? handle.close() }

        for try await seq in reader.sequences() {
            let id = normalizedIdentifier(seq.name)
            if rcReadIDs.contains(id) {
                if let rc = seq.reverseComplement() {
                    writeFASTARecord(name: seq.name, sequence: rc.asString(), to: handle)
                }
            } else if forwardReadIDs.contains(id) {
                writeFASTARecord(name: seq.name, sequence: seq.asString(), to: handle)
            }
        }
    }

    // MARK: - fullPaired interleave

    private func interleaveWithReformat(r1URL: URL, r2URL: URL, outputURL: URL) async throws {
        var env: [String: String] = [:]
        if let toolsDir = await runner.getToolsDirectory() {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            let jreBin = toolsDir.appendingPathComponent("jre/bin")
            env["PATH"] = "\(toolsDir.path):\(jreBin.path):\(existingPath)"
            let javaURL = jreBin.appendingPathComponent("java")
            if FileManager.default.fileExists(atPath: javaURL.path) {
                env["JAVA_HOME"] = toolsDir.appendingPathComponent("jre").path
                env["BBMAP_JAVA"] = javaURL.path
            }
        }
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(r1URL.path)",
                "in2=\(r2URL.path)",
                "out=\(outputURL.path)",
                "interleaved=t",
            ],
            environment: env,
            timeout: 1800
        )
        guard result.isSuccess else {
            throw FASTQCLIMaterializerError.toolFailed("reformat.sh", result.stderr)
        }
    }

    // MARK: - fullMixed materialization

    private func materializeFullMixed(
        classification: ReadClassification,
        bundleURL: URL,
        tempDirectory: URL,
        outputURL: URL
    ) async throws {
        let fm = FileManager.default
        let pairedR1 = classification.files.first(where: { $0.role == .pairedR1 })
        let pairedR2 = classification.files.first(where: { $0.role == .pairedR2 })
        var fileURLsToConcat: [URL] = []
        var tempInterleavedURL: URL?

        if let r1 = pairedR1, let r2 = pairedR2 {
            let r1URL = bundleURL.appendingPathComponent(r1.filename)
            let r2URL = bundleURL.appendingPathComponent(r2.filename)
            let interleavedURL = tempDirectory
                .appendingPathComponent("interleaved-\(UUID().uuidString).fastq")
            try await interleaveWithReformat(r1URL: r1URL, r2URL: r2URL, outputURL: interleavedURL)
            tempInterleavedURL = interleavedURL
            fileURLsToConcat.append(interleavedURL)
        }
        defer {
            if let url = tempInterleavedURL { try? fm.removeItem(at: url) }
        }

        let otherRoles: [ReadClassification.FileRole] = [.merged, .unpaired]
        for role in otherRoles {
            if let fileRecord = classification.files.first(where: { $0.role == role }) {
                let url = bundleURL.appendingPathComponent(fileRecord.filename)
                if fm.fileExists(atPath: url.path) {
                    fileURLsToConcat.append(url)
                }
            }
        }

        guard !fileURLsToConcat.isEmpty else {
            throw FASTQCLIMaterializerError.sourceFASTQMissing
        }

        if fileURLsToConcat.count == 1 {
            try fm.copyItem(at: fileURLsToConcat[0], to: outputURL)
        } else {
            try concatenateFiles(fileURLsToConcat, to: outputURL)
        }
    }

    // MARK: - Utilities

    private func bundleTrimPositionsURL(_ bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func bundleOrientMapURL(_ bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent("orient-map.tsv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func isAbsoluteTrimPositionsFile(_ url: URL) -> Bool {
        guard let header = try? String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first else {
            return false
        }
        return String(header) == FASTQTrimPositionFile.formatHeader
    }

    private func loadSelectedReadIDSet(from url: URL) throws -> Set<String> {
        let content = try String(contentsOf: url, encoding: .utf8)
        return Set(content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// Strips mate suffixes and trailing description from a FASTQ/FASTA read identifier.
    private func normalizedIdentifier(_ identifier: String) -> String {
        var id = identifier
        if id.hasSuffix("/1") || id.hasSuffix("/2") {
            id = String(id.dropLast(2))
        }
        if let spaceIdx = id.firstIndex(of: " ") {
            id = String(id[id.startIndex..<spaceIdx])
        }
        return id
    }

    private func writeFASTARecord(name: String, sequence: String, to handle: FileHandle) {
        let line = ">\(name)\n\(sequence)\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func concatenateFiles(_ sources: [URL], to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer { try? outHandle.close() }
        for source in sources {
            let inHandle = try FileHandle(forReadingFrom: source)
            defer { try? inHandle.close() }
            let bufferSize = 4 * 1024 * 1024
            while true {
                let chunk = inHandle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                outHandle.write(chunk)
            }
        }
    }
}

// MARK: - Errors

public enum FASTQCLIMaterializerError: Error, LocalizedError {
    case derivedManifestMissing
    case rootBundleMissing(String)
    case rootFASTQMissing
    case sourceFASTQMissing
    case emptyResult
    case toolFailed(String, String)
    case unsupportedPayload(String)
    case unsupportedTrimFormat(String)

    public var errorDescription: String? {
        switch self {
        case .derivedManifestMissing:
            return "Bundle has no derived manifest and no primary FASTQ file"
        case .rootBundleMissing(let path):
            return "Root bundle not found at relative path: \(path)"
        case .rootFASTQMissing:
            return "Root FASTQ file referenced in manifest does not exist"
        case .sourceFASTQMissing:
            return "Source FASTQ file(s) referenced in payload do not exist"
        case .emptyResult:
            return "Materialization produced an empty result"
        case .toolFailed(let tool, let stderr):
            return "\(tool) failed: \(stderr)"
        case .unsupportedPayload(let type):
            return "Payload type '\(type)' cannot be materialized to a single FASTQ file"
        case .unsupportedTrimFormat(let reason):
            return "Unsupported trim file format: \(reason)"
        }
    }
}
