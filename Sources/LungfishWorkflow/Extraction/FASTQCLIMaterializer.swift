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
    /// This is the one-file resolution of a bundle every single-input tool
    /// shares: a single-file bundle is its file in place, a bundle that holds
    /// several files (an ONT import or a merged bundle, listed in
    /// `source-files.json`) is every file joined in manifest order, a
    /// `fullPaired` bundle is R1 and R2 interleaved, a `fullMixed` bundle is
    /// its files joined, and a virtual derivative is its recipe applied to
    /// every file of its root (`FASTQBundle.rootSequenceURLs`).
    ///
    /// - Parameters:
    ///   - bundleURL: The bundle to materialize.
    ///   - tempDirectory: Directory for intermediate/output files.
    ///   - progress: Optional progress message callback.
    /// - Returns: URL of the materialized FASTQ (inside `tempDirectory` for virtual
    ///   and multi-file bundles, or a physical file URL for single-file root bundles).
    public func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        if !FASTQBundle.isDerivedBundle(bundleURL) {
            // A physical bundle that holds several files is every file it
            // holds, joined in `source-files.json` order with the sidecar
            // that records the join, as the FASTQ operations dialog,
            // `fastq materialize` and `assemble` read it. It used to be the
            // first file alone (R3, lane 1x).
            if let concatenation = try ResolvedSequenceInputs.concatenateMultiFileBundle(bundleURL, into: tempDirectory) {
                progress?("Joined \(concatenation.memberURLs.count) files of \(bundleURL.lastPathComponent)")
                return concatenation.outputURL
            }
            // Single-file bundles: return their primary sequence directly (no copy needed)
            if let physicalURL = FASTQBundle.resolvePrimarySequenceURL(for: bundleURL) {
                return physicalURL
            }
        }

        guard let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            if let physicalURL = FASTQBundle.resolvePrimarySequenceURL(for: bundleURL) {
                return physicalURL
            }
            throw FASTQCLIMaterializerError.derivedManifestMissing
        }

        let outputExtension = Self.materializedOutputExtension(for: manifest)
        let outputURL = tempDirectory.appendingPathComponent(
            "materialized-\(UUID().uuidString).\(outputExtension)"
        )
        progress?("Materializing pointer dataset...")

        switch manifest.payload {
        case .full(let fastqFilename):
            let fullFASTQURL = try payloadMemberURL(
                fastqFilename,
                in: bundleURL,
                field: "payload.full.fastqFilename"
            )
            guard FileManager.default.fileExists(atPath: fullFASTQURL.path) else {
                throw FASTQCLIMaterializerError.sourceFASTQMissing
            }
            try FileManager.default.copyItem(at: fullFASTQURL, to: outputURL)
            try? repairSelfRootedMaterializedManifestIfNeeded(
                manifest,
                in: bundleURL,
                payloadFilename: fastqFilename
            )
            return outputURL

        case .fullFASTA(let fastaFilename):
            let fullFASTAURL = try payloadMemberURL(
                fastaFilename,
                in: bundleURL,
                field: "payload.fullFASTA.fastaFilename"
            )
            guard FileManager.default.fileExists(atPath: fullFASTAURL.path) else {
                throw FASTQCLIMaterializerError.sourceFASTQMissing
            }
            try FileManager.default.copyItem(at: fullFASTAURL, to: outputURL)
            try? repairSelfRootedMaterializedManifestIfNeeded(
                manifest,
                in: bundleURL,
                payloadFilename: fastaFilename
            )
            return outputURL

        case .fullPaired(let r1Filename, let r2Filename):
            let r1URL = try payloadMemberURL(
                r1Filename,
                in: bundleURL,
                field: "payload.fullPaired.r1Filename"
            )
            let r2URL = try payloadMemberURL(
                r2Filename,
                in: bundleURL,
                field: "payload.fullPaired.r2Filename"
            )
            guard FileManager.default.fileExists(atPath: r1URL.path),
                  FileManager.default.fileExists(atPath: r2URL.path) else {
                throw FASTQCLIMaterializerError.sourceFASTQMissing
            }
            try await interleaveWithReformat(r1URL: r1URL, r2URL: r2URL, outputURL: outputURL)
            return outputURL

        case .fullMixed(let classification):
            try await materializeFullMixed(
                classification: classification,
                bundleURL: bundleURL,
                tempDirectory: tempDirectory,
                outputURL: outputURL
            )
            return outputURL

        case .subset, .trim, .demuxedVirtual, .orientMap, .demuxGroup:
            break
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

        // Every file of the root the recipe applies to: the members of a
        // multi-file root in manifest order, else the one recorded file, or
        // the paired or mixed bundle the reads come from, materialized (D1).
        let rootRead = try await virtualRootRead(
            of: bundleURL, manifest: manifest, recordedRoot: rootBundleURL, tempDirectory: tempDirectory
        )
        defer { rootRead.cleanup() }
        let rootFASTQURLs = rootRead.urls

        switch manifest.payload {
        case .full, .fullFASTA, .fullPaired, .fullMixed:
            throw FASTQCLIMaterializerError.sourceFASTQMissing

        case .subset(let readIDFilename):
            let readIDListURL = try payloadMemberURL(
                readIDFilename,
                in: bundleURL,
                field: "payload.subset.readIDListFilename"
            )
            let trimURL = bundleTrimPositionsURL(bundleURL)
            let orientURL = bundleOrientMapURL(bundleURL)
            if manifest.sequenceFormat == .fasta {
                try await materializeFASTASubset(
                    rootFASTAURLs: rootFASTQURLs,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            } else {
                try await materializeFASTQSubset(
                    rootFASTQURLs: rootFASTQURLs,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            }

        case .trim(let trimFilename):
            let trimURL = try payloadMemberURL(
                trimFilename,
                in: bundleURL,
                field: "payload.trim.trimPositionFilename"
            )
            guard isAbsoluteTrimPositionsFile(trimURL) else {
                throw FASTQCLIMaterializerError.unsupportedTrimFormat(
                    "Legacy relative trim format not supported by CLI materializer"
                )
            }
            let positions = try FASTQTrimPositionFile.load(from: trimURL)
            if manifest.sequenceFormat == .fasta {
                try await extractTrimmedFASTAReads(
                    fromRootFASTAs: rootFASTQURLs,
                    positions: positions,
                    outputFASTA: outputURL
                )
            } else {
                try await extractTrimmedReads(
                    fromRootFASTQs: rootFASTQURLs,
                    positions: positions,
                    outputFASTQ: outputURL
                )
            }

        case .demuxedVirtual(_, let readIDFilename, _, let trimPositionsFilename, let orientMapFilename):
            let readIDListURL = try payloadMemberURL(
                readIDFilename,
                in: bundleURL,
                field: "payload.demuxedVirtual.readIDListFilename"
            )
            let trimURL = try optionalPayloadMemberURL(
                trimPositionsFilename,
                in: bundleURL,
                field: "payload.demuxedVirtual.trimPositionsFilename"
            )
            let orientURL = try optionalPayloadMemberURL(
                orientMapFilename,
                in: bundleURL,
                field: "payload.demuxedVirtual.orientMapFilename"
            )
            if manifest.sequenceFormat == .fasta {
                try await materializeFASTASubset(
                    rootFASTAURLs: rootFASTQURLs,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            } else {
                try await materializeFASTQSubset(
                    rootFASTQURLs: rootFASTQURLs,
                    readIDListURL: readIDListURL,
                    trimPositionsURL: trimURL,
                    orientMapURL: orientURL,
                    outputURL: outputURL
                )
            }

        case .orientMap(let orientMapFilename, _):
            let mapURL = try payloadMemberURL(
                orientMapFilename,
                in: bundleURL,
                field: "payload.orientMap.orientMapFilename"
            )
            let orientSets = try FASTQOrientMapFile.loadOrientationSets(from: mapURL)
            if manifest.sequenceFormat == .fasta {
                try await materializeOrientedFASTAReads(
                    fromRootFASTAs: rootFASTQURLs,
                    allReadIDs: orientSets.allReadIDs,
                    rcReadIDs: orientSets.rcReadIDs,
                    outputFASTA: outputURL
                )
            } else {
                try await materializeOrientedReads(
                    fromRootFASTQs: rootFASTQURLs,
                    allReadIDs: orientSets.allReadIDs,
                    rcReadIDs: orientSets.rcReadIDs,
                    outputFASTQ: outputURL
                )
            }

        case .demuxGroup:
            // demuxGroup bundles are container-only (no physical FASTQ of their own);
            // materialization at this level is not supported — callers should
            // iterate the child bundles instead.
            throw FASTQCLIMaterializerError.unsupportedPayload("demuxGroup")
        }

        return outputURL
    }

    private func repairSelfRootedMaterializedManifestIfNeeded(
        _ manifest: FASTQDerivedBundleManifest,
        in bundleURL: URL,
        payloadFilename: String
    ) throws {
        guard manifest.rootBundleRelativePath != "." || manifest.rootFASTQFilename != payloadFilename else {
            return
        }

        let repairedManifest = FASTQDerivedBundleManifest(
            id: manifest.id,
            name: manifest.name,
            createdAt: manifest.createdAt,
            parentBundleRelativePath: manifest.parentBundleRelativePath,
            rootBundleRelativePath: ".",
            rootFASTQFilename: payloadFilename,
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
        try FASTQBundle.saveDerivedManifest(repairedManifest, in: bundleURL)
    }

    private static func materializedOutputExtension(for manifest: FASTQDerivedBundleManifest) -> String {
        switch manifest.payload {
        case .full(let filename), .fullFASTA(let filename):
            return sequenceFileExtensionPreservingCompression(from: filename)
                ?? (manifest.sequenceFormat ?? .fastq).fileExtension
        default:
            return (manifest.sequenceFormat ?? .fastq).fileExtension
        }
    }

    private static func sequenceFileExtensionPreservingCompression(from filename: String) -> String? {
        let url = URL(fileURLWithPath: filename)
        let extensionPart = url.pathExtension.lowercased()
        guard !extensionPart.isEmpty else { return nil }

        if extensionPart == "gz" {
            let baseExtension = url.deletingPathExtension().pathExtension.lowercased()
            return baseExtension.isEmpty ? extensionPart : "\(baseExtension).\(extensionPart)"
        }

        return extensionPart
    }

    // MARK: - Subset Materialization

    private func materializeFASTQSubset(
        rootFASTQURLs: [URL],
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
            let filtered = positions.filter { self.selectedReadIDsMatch($0.key, in: selectedIDs) }
            try await extractTrimmedReads(
                fromRootFASTQs: rootFASTQURLs,
                positions: filtered,
                outputFASTQ: extractTarget
            )
        } else {
            // Extract subset by read ID list using seqkit grep
            try await extractReadsByIDList(
                rootFASTQURLs: rootFASTQURLs,
                readIDListURL: readIDListURL,
                outputFASTQ: extractTarget
            )
            // Apply trim in a second pass if needed.
            // For legacy demux trim files (e.g. #format lungfish-demux-trim-v1) that store
            // relative 5'/3' offset amounts rather than absolute slice positions, use the
            // legacy trim path which interprets them correctly.
            if let trimURL = trimPositionsURL, fm.fileExists(atPath: trimURL.path) {
                let tempTrimmed = extractTarget.deletingLastPathComponent()
                    .appendingPathComponent("trimmed-\(UUID().uuidString).fastq")
                if isLegacyRelativeTrimFile(trimURL) {
                    try await applyLegacyRelativeTrim(
                        from: extractTarget,
                        trimPositionsURL: trimURL,
                        outputFASTQ: tempTrimmed
                    )
                } else {
                    let positions = try FASTQTrimPositionFile.load(from: trimURL)
                    try await extractTrimmedReads(
                        fromRootFASTQs: [extractTarget],
                        positions: positions,
                        outputFASTQ: tempTrimmed
                    )
                }
                try fm.removeItem(at: extractTarget)
                try fm.moveItem(at: tempTrimmed, to: extractTarget)
            }
        }

        if let orientMapURL, fm.fileExists(atPath: orientMapURL.path) {
            let orientSets = try FASTQOrientMapFile.loadOrientationSets(from: orientMapURL)
            try await materializeOrientedReads(
                fromRootFASTQs: [extractTarget],
                allReadIDs: orientSets.allReadIDs,
                rcReadIDs: orientSets.rcReadIDs,
                outputFASTQ: outputURL
            )
        }
    }

    private func materializeFASTASubset(
        rootFASTAURLs: [URL],
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
            let filtered = positions.filter { self.selectedReadIDsMatch($0.key, in: selectedIDs) }
            try await extractTrimmedFASTAReads(
                fromRootFASTAs: rootFASTAURLs,
                positions: filtered,
                outputFASTA: extractTarget
            )
        } else {
            // Use seqkit for FASTA subset extraction too
            try await extractReadsByIDList(
                rootFASTQURLs: rootFASTAURLs,
                readIDListURL: readIDListURL,
                outputFASTQ: extractTarget
            )
        }

        if let orientMapURL, fm.fileExists(atPath: orientMapURL.path) {
            let orientSets = try FASTQOrientMapFile.loadOrientationSets(from: orientMapURL)
            try await materializeOrientedFASTAReads(
                fromRootFASTAs: [extractTarget],
                allReadIDs: orientSets.allReadIDs,
                rcReadIDs: orientSets.rcReadIDs,
                outputFASTA: outputURL
            )
        }
    }

    // MARK: - seqkit grep extraction

    /// `seqkit grep -f` over every root file in order, so the selected
    /// records come out in root order whichever file holds them.
    private func extractReadsByIDList(
        rootFASTQURLs: [URL],
        readIDListURL: URL,
        outputFASTQ: URL
    ) async throws {
        let inputPaths = rootFASTQURLs.map(\.path)

        var args = ["grep", "-f", readIDListURL.path]
        args.append(contentsOf: inputPaths)
        args.append(contentsOf: ["-o", outputFASTQ.path])

        let timeout = max(600.0, Double(inputPaths.count) * 120.0)
        let result = try await runner.run(.seqkit, arguments: args, timeout: timeout)
        guard result.isSuccess else {
            throw FASTQCLIMaterializerError.toolFailed("seqkit grep", result.stderr)
        }
    }

    // MARK: - fullPaired interleave

    func interleaveWithReformat(r1URL: URL, r2URL: URL, outputURL: URL) async throws {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
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

    // MARK: - Utilities

    func payloadMemberURL(_ relativePath: String, in bundleURL: URL, field: String) throws -> URL {
        do {
            return try FASTQBundle.validatedBundleMemberURL(
                for: relativePath,
                in: bundleURL,
                field: field
            )
        } catch {
            throw FASTQCLIMaterializerError.sourceFASTQMissing
        }
    }

    private func optionalPayloadMemberURL(_ relativePath: String?, in bundleURL: URL, field: String) throws -> URL? {
        guard let relativePath else { return nil }
        return try payloadMemberURL(relativePath, in: bundleURL, field: field)
    }

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

    /// Returns true if the file is a legacy demux-trim format that stores relative
    /// 5'/3' trim offsets (e.g. `#format lungfish-demux-trim-v1`) rather than the
    /// absolute slice positions of the v2 format.
    private func isLegacyRelativeTrimFile(_ url: URL) -> Bool {
        guard let header = try? String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first else {
            return false
        }
        return String(header).hasPrefix("#format lungfish-demux-trim-v")
    }

    /// Applies a legacy relative-offset trim file to an already-extracted FASTQ.
    ///
    /// The legacy format stores per-read 5' and 3' trim amounts (`trim_5p`, `trim_3p`)
    /// rather than absolute (start, end) positions. The read ID in the trim file may
    /// include an ` rc` suffix (cutadapt demux convention); this suffix is stripped
    /// before lookup so it matches the extracted FASTQ header.
    private func applyLegacyRelativeTrim(
        from sourceFASTQ: URL,
        trimPositionsURL: URL,
        outputFASTQ: URL
    ) async throws {
        let content = try String(contentsOf: trimPositionsURL, encoding: .utf8)

        // Build trim map keyed by canonical (bare) read ID.
        // Supports 4-column (read_id, mate, trim_5p, trim_3p) and
        // 3-column legacy (read_id, trim_5p, trim_3p) layouts.
        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in content.split(separator: "\n") {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let cols = line.split(separator: "\t")
            let readID: String
            let t5: Int
            let t3: Int
            if cols.count >= 4, let mate = Int(cols[1]),
               let a = Int(cols[2]), let b = Int(cols[3]) {
                readID = canonicalLegacyReadID(String(cols[0]))
                _ = mate  // mate column present but we key by bare ID for single-end
                t5 = a
                t3 = b
            } else if cols.count >= 3,
                      let a = Int(cols[1]), let b = Int(cols[2]) {
                readID = canonicalLegacyReadID(String(cols[0]))
                t5 = a
                t3 = b
            } else {
                continue
            }
            trimMap[readID] = (t5, t3)
        }

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: sourceFASTQ) {
            let bareID = normalizedIdentifier(record.identifier)
            if let trim = trimMap[bareID] {
                let seq = record.sequence
                let startIdx = min(trim.trim5p, seq.count)
                let endIdx = max(startIdx, seq.count - trim.trim3p)
                let trimmed = record.trimmed(from: startIdx, to: endIdx)
                if trimmed.length > 0 { try writer.write(trimmed) }
            } else {
                try writer.write(record)
            }
        }
    }

    /// Strips the ` rc` suffix added by cutadapt demux convention and normalizes
    /// the remaining identifier (strips mate suffixes and description).
    private func canonicalLegacyReadID(_ rawValue: String) -> String {
        var id = rawValue
        // Strip trailing " rc" added by cutadapt to denote reverse-complemented reads
        if id.hasSuffix(" rc") {
            id = String(id.dropLast(3))
        }
        return normalizedIdentifier(id)
    }

    private func loadSelectedReadIDSet(from url: URL) throws -> Set<String> {
        let content = try String(contentsOf: url, encoding: .utf8)
        return Set(content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    private func selectedReadIDsMatch(_ trimPositionKey: String, in selectedIDs: Set<String>) -> Bool {
        selectedIDs.contains(trimPositionKey) || selectedIDs.contains(baseReadID(forTrimPositionKey: trimPositionKey))
    }

    private func baseReadID(forTrimPositionKey key: String) -> String {
        guard let hashIndex = key.lastIndex(of: "#") else {
            return key
        }

        let suffix = key[key.index(after: hashIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
            return key
        }

        return String(key[..<hashIndex])
    }

    /// Strips mate suffixes and trailing description from a FASTQ/FASTA read identifier.
    func normalizedIdentifier(_ identifier: String) -> String {
        var id = identifier
        if id.hasSuffix("/1") || id.hasSuffix("/2") {
            id = String(id.dropLast(2))
        }
        if let spaceIdx = id.firstIndex(of: " ") {
            id = String(id[id.startIndex..<spaceIdx])
        }
        return id
    }

    func concatenateFiles(_ sources: [URL], to destination: URL) throws {
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
    case roleFileMissing(String)

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
        case .roleFileMissing(let detail):
            return "The mixed bundle cannot be read whole: \(detail)"
        }
    }
}
