// FASTQDerivativeService+SubsetHelpers.swift - PE-aware subset helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - PE-Aware Subset Helpers

    /// Builds seqkit grep args for text search (ID or description).
    func buildSearchArgs(field: FASTQSearchField, regex: Bool, query: String) -> [String] {
        var args = ["grep"]
        if field == .description {
            args.append("-n")
        }
        if regex {
            args.append("-r")
        }
        args += ["-p", query]
        return args
    }

    /// Builds seqkit grep args for motif (sequence) search.
    func buildMotifSearchArgs(pattern: String, regex: Bool) -> [String] {
        var args = ["grep", "-s"]
        if regex {
            args.append("-r")
        }
        args += ["-p", pattern]
        return args
    }

    /// Pair-aware search for interleaved PE data.
    ///
    /// Strategy: run seqkit grep to find matching reads, extract their base IDs
    /// (deduplicated), then re-extract both mates from the original source FASTQ
    /// using the base ID list. This ensures both R1 and R2 are included and
    /// interleaving order is preserved.
    func runPairedAwareSearch(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        searchArgs: [String],
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "pe-search-", contextURL: sourceFASTQ)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Step 1: Run the search to find matching reads
        let matchesURL = tempDir.appendingPathComponent("matches.fastq")
        let matchArgs = searchArgs + [sourceFASTQ.path, "-o", matchesURL.path]
        let searchResult = try await runNativeTool(
            .seqkit,
            arguments: matchArgs,
            provenanceCollector: provenanceCollector
        )
        guard searchResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep failed: \(searchResult.stderr)")
        }

        // Step 2: Extract base IDs from matches (deduplicated)
        let matchedIDsURL = tempDir.appendingPathComponent("matched-ids.txt")
        let idResult = try await runner.runWithFileOutput(
            .seqkit,
            arguments: ["seq", "--name", "--only-id", matchesURL.path],
            outputFile: matchedIDsURL,
            timeout: 600
        )
        guard idResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit seq --name failed: \(idResult.stderr)")
        }

        // Deduplicate IDs (for PE, R1 and R2 may both match and share the same base ID)
        let dedupedIDsURL = tempDir.appendingPathComponent("deduped-ids.txt")
        try deduplicateIDFile(from: matchedIDsURL, to: dedupedIDsURL)

        // Step 3: Re-extract both mates from the original source using base IDs
        let reExtractResult = try await runNativeTool(
            .seqkit,
            arguments: [
                "grep", "-f", dedupedIDsURL.path,
                sourceFASTQ.path,
                "-o", outputFASTQ.path,
            ],
            timeout: 600,
            provenanceCollector: provenanceCollector
        )
        guard reExtractResult.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep (pair re-extraction) failed: \(reExtractResult.stderr)")
        }
    }

    /// Pair-aware length filtering for interleaved PE data using bbduk.
    ///
    /// bbduk with `interleaved=t` removes/keeps both mates as a pair.
    func runPairedAwareFilter(
        sourceFASTQ: URL,
        outputFASTQ: URL,
        minLength: Int?,
        maxLength: Int?,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector? = nil
    ) async throws {
        var args = [
            "in=\(sourceFASTQ.path)",
            "out=\(outputFASTQ.path)",
            "interleaved=t",
        ]
        if let minLength {
            args.append("minlen=\(minLength)")
        }
        if let maxLength {
            args.append("maxlen=\(maxLength)")
        }

        let env = await bbToolsEnvironment()
        let result = try await runNativeTool(
            .bbduk,
            arguments: args,
            environment: env,
            timeout: 1800,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("bbduk length filter failed: \(result.stderr)")
        }
    }

    /// Deduplicates lines in a text file (preserving first occurrence order).
    func deduplicateIDFile(from inputURL: URL, to outputURL: URL) throws {
        let content = try String(contentsOf: inputURL, encoding: .utf8)
        var seen = Set<String>()
        var unique: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let id = String(line)
            if !seen.contains(id) {
                seen.insert(id)
                unique.append(id)
            }
        }
        try unique.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    struct SelectedReadIDLookup {
        let rawIDs: Set<String>
        let normalizedIDs: Set<String>
        let baseReadIDs: Set<String>

        func contains(_ identifier: String) -> Bool {
            let normalized = identifier.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? identifier
            let positionalBase = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? normalized
            let mateBase: String
            if positionalBase.hasSuffix("/1") || positionalBase.hasSuffix("/2") {
                mateBase = String(positionalBase.dropLast(2))
            } else {
                mateBase = positionalBase
            }

            return rawIDs.contains(identifier)
                || rawIDs.contains(normalized)
                || rawIDs.contains(positionalBase)
                || normalizedIDs.contains(identifier)
                || normalizedIDs.contains(normalized)
                || normalizedIDs.contains(positionalBase)
                || baseReadIDs.contains(identifier)
                || baseReadIDs.contains(positionalBase)
                || baseReadIDs.contains(mateBase)
        }
    }

    func loadSelectedReadIDLookup(from url: URL) throws -> SelectedReadIDLookup {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rawIDs: Set<String> = []
        var normalizedIDs: Set<String> = []
        var baseReadIDs: Set<String> = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let rawID = String(line)
            let normalizedID = normalizedIdentifier(rawID)
            let baseReadID = detectMateFromHeader(identifier: normalizedID, description: nil).readID
            rawIDs.insert(rawID)
            normalizedIDs.insert(normalizedID)
            baseReadIDs.insert(baseReadID)
        }

        return SelectedReadIDLookup(
            rawIDs: rawIDs,
            normalizedIDs: normalizedIDs,
            baseReadIDs: baseReadIDs
        )
    }

    func propagateVirtualSubsetSidecars(
        from sourceBundleURL: URL,
        selectedReadIDsFile: URL,
        to outputBundleURL: URL
    ) throws {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)

        if let sourceTrimURL = bundleTrimPositionsURL(sourceBundleURL) {
            let outputTrimURL = outputBundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
            if isAbsoluteTrimPositionsFile(sourceTrimURL) {
                let records = try FASTQTrimPositionFile.loadRecords(from: sourceTrimURL)
                let filtered = records.filter { selectedReadIDs.contains($0.readID) }
                if !filtered.isEmpty {
                    try FASTQTrimPositionFile.write(filtered, to: outputTrimURL)
                }
            } else if let filteredTrimContent = try filteredRelativeTrimPositionsContent(
                from: sourceTrimURL,
                selectedReadIDsFile: selectedReadIDsFile
            ) {
                try filteredTrimContent.write(to: outputTrimURL, atomically: true, encoding: .utf8)
            }
        }

        if let sourceOrientURL = bundleOrientMapURL(sourceBundleURL) {
            let content = try String(contentsOf: sourceOrientURL, encoding: .utf8)
            var filteredLines: [String] = []
            filteredLines.reserveCapacity(1024)

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let firstField = fields.first else { continue }
                if selectedReadIDs.contains(String(firstField)) {
                    filteredLines.append(String(line))
                }
            }

            if !filteredLines.isEmpty {
                let outputURL = outputBundleURL.appendingPathComponent("orient-map.tsv")
                try filteredLines.joined(separator: "\n").appending("\n").write(
                    to: outputURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    func filteredTrimPositions(
        from trimPositionsURL: URL,
        selectedReadIDsFile: URL
    ) throws -> [String: (start: Int, end: Int)] {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)
        let positions = try FASTQTrimPositionFile.load(from: trimPositionsURL)
        return positions.reduce(into: [String: (start: Int, end: Int)]()) { result, entry in
            if selectedReadIDs.contains(entry.key) {
                result[entry.key] = entry.value
            }
        }
    }

    func isAbsoluteTrimPositionsFile(_ url: URL) -> Bool {
        guard let header = try? String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first else {
            return false
        }
        return String(header) == FASTQTrimPositionFile.formatHeader
    }

    func filteredRelativeTrimPositionsContent(
        from trimPositionsURL: URL,
        selectedReadIDsFile: URL
    ) throws -> String? {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)
        let content = try String(contentsOf: trimPositionsURL, encoding: .utf8)
        var headerLines: [String] = []
        var filteredLines: [String] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            if lineString.hasPrefix("#") || lineString.hasPrefix("read_id") {
                headerLines.append(lineString)
                continue
            }

            let fields = lineString.split(separator: "\t", omittingEmptySubsequences: false)
            guard let firstField = fields.first else { continue }
            let canonicalReadID = canonicalDemuxTrimReadID(String(firstField))
            if selectedReadIDs.contains(canonicalReadID) {
                if fields.count >= 2 {
                    filteredLines.append(([canonicalReadID] + fields.dropFirst().map(String.init)).joined(separator: "\t"))
                } else {
                    filteredLines.append(canonicalReadID)
                }
            }
        }

        guard !filteredLines.isEmpty else { return nil }
        let allLines = headerLines + filteredLines
        return allLines.joined(separator: "\n").appending("\n")
    }

    func writePreviewFASTQ(
        from sourceFASTQ: URL,
        to outputURL: URL,
        readLimit: Int = 1_000
    ) async throws {
        let headResult = try? await runner.run(
            .seqkit,
            arguments: ["head", "-n", String(max(1, readLimit)), sourceFASTQ.path, "-o", outputURL.path],
            timeout: 60
        )
        if headResult?.isSuccess == true, FileManager.default.fileExists(atPath: outputURL.path) {
            return
        }

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        var count = 0
        for try await record in reader.records(from: sourceFASTQ) {
            try writer.write(record)
            count += 1
            if count >= readLimit {
                break
            }
        }
    }

    func bundleTrimPositionsURL(_ bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent(FASTQBundle.trimPositionFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func bundleOrientMapURL(_ bundleURL: URL) -> URL? {
        let url = bundleURL.appendingPathComponent("orient-map.tsv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func canonicalDemuxTrimReadID(_ rawValue: String) -> String {
        let normalized = normalizedIdentifier(rawValue)
        return detectMateFromHeader(identifier: normalized, description: nil).readID
    }

}
