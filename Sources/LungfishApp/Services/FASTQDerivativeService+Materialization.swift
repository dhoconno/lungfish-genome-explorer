// FASTQDerivativeService+Materialization.swift - Materialization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Materialization

    func materializeDatasetFASTQ(
        fromBundle bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let materializer = FASTQCLIMaterializer(runner: runner)
        return try await materializer.materialize(
            bundleURL: bundleURL,
            tempDirectory: tempDirectory,
            progress: progress
        )
    }

    /// Extracts reads from root FASTQ(s) by ID list using `seqkit grep`.
    ///
    /// Supports multi-file bundles: when the root bundle has a `source-files.json`,
    /// all constituent files are passed to seqkit grep (which natively accepts multiple inputs).
    func extractReads(
        fromRootFASTQ rootFASTQ: URL,
        readIDsFile: URL,
        outputFASTQ: URL
    ) async throws {
        // Resolve multi-file bundles: check if the root FASTQ's parent bundle
        // has a source-files.json manifest
        var inputPaths = [rootFASTQ.path]
        let parentBundle = rootFASTQ.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundle),
           let allURLs = FASTQBundle.resolveAllFASTQURLs(for: parentBundle), allURLs.count > 1 {
            inputPaths = allURLs.map(\.path)
        }

        var args = ["grep", "-f", readIDsFile.path]
        args.append(contentsOf: inputPaths)
        args.append(contentsOf: ["-o", outputFASTQ.path])

        let timeout = max(600.0, Double(inputPaths.count) * 120.0)
        let result = try await runner.run(
            .seqkit,
            arguments: args,
            timeout: timeout
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("seqkit grep failed: \(result.stderr)")
        }
    }

    func materializeVirtualFASTQSubset(
        rootFASTQURL: URL,
        readIDListURL: URL,
        trimPositionsURL: URL?,
        orientMapURL: URL?,
        outputURL: URL
    ) async throws {
        let needsOrientation = orientMapURL != nil
        let fm = FileManager.default

        let extractTarget: URL
        var orientTempDir: URL?
        if needsOrientation {
            let tempDir = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-virtual-orient-",
                contextURL: rootFASTQURL
            )
            orientTempDir = tempDir
            extractTarget = tempDir.appendingPathComponent("pre-orient.fastq")
        } else {
            extractTarget = outputURL
        }
        defer {
            if let tempDir = orientTempDir {
                try? fm.removeItem(at: tempDir)
            }
        }

        if let trimPositionsURL {
            if isAbsoluteTrimPositionsFile(trimPositionsURL) {
                let positions = try filteredTrimPositions(from: trimPositionsURL, selectedReadIDsFile: readIDListURL)
                try await extractTrimmedReads(
                    fromRootFASTQ: rootFASTQURL,
                    positions: positions,
                    outputFASTQ: extractTarget
                )
            } else if let filteredTrimContent = try filteredRelativeTrimPositionsContent(
                from: trimPositionsURL,
                selectedReadIDsFile: readIDListURL
            ) {
                let filteredTrimDir = try ProjectTempDirectory.createFromContext(
                    prefix: "lungfish-demux-trim-",
                    contextURL: rootFASTQURL
                )
                let filteredTrimURL = filteredTrimDir.appendingPathComponent("trim-positions.tsv")
                try filteredTrimContent.write(to: filteredTrimURL, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(at: filteredTrimDir) }
                try await extractAndTrimReads(
                    fromRootFASTQ: rootFASTQURL,
                    readIDsFile: readIDListURL,
                    trimPositionsFile: filteredTrimURL,
                    outputFASTQ: extractTarget
                )
            } else {
                throw FASTQDerivativeError.emptyResult
            }
        } else {
            try await extractReads(
                fromRootFASTQ: rootFASTQURL,
                readIDsFile: readIDListURL,
                outputFASTQ: extractTarget
            )
        }

        if let orientMapURL {
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            try await materializeOrientedReads(
                fromRootFASTQ: extractTarget,
                forwardReadIDs: fwdReadIDs,
                rcReadIDs: rcReadIDs,
                outputFASTQ: outputURL
            )
        }
    }

    func materializeVirtualFASTASubset(
        rootFASTAURL: URL,
        readIDListURL: URL,
        trimPositionsURL: URL?,
        orientMapURL: URL?,
        outputURL: URL
    ) async throws {
        let needsOrientation = orientMapURL != nil
        let fm = FileManager.default

        let extractTarget: URL
        var orientTempDir: URL?
        if needsOrientation {
            let tempDir = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-fasta-orient-",
                contextURL: rootFASTAURL
            )
            orientTempDir = tempDir
            extractTarget = tempDir.appendingPathComponent("pre-orient.fasta")
        } else {
            extractTarget = outputURL
        }
        defer {
            if let tempDir = orientTempDir {
                try? fm.removeItem(at: tempDir)
            }
        }

        if let trimPositionsURL {
            if isAbsoluteTrimPositionsFile(trimPositionsURL) {
                let positions = try filteredTrimPositions(from: trimPositionsURL, selectedReadIDsFile: readIDListURL)
                try await extractTrimmedFASTAReads(
                    fromRootFASTA: rootFASTAURL,
                    positions: positions,
                    outputFASTA: extractTarget
                )
            } else if let filteredTrimContent = try filteredRelativeTrimPositionsContent(
                from: trimPositionsURL,
                selectedReadIDsFile: readIDListURL
            ) {
                let filteredTrimDir = try ProjectTempDirectory.createFromContext(
                    prefix: "lungfish-fasta-demux-trim-",
                    contextURL: rootFASTAURL
                )
                let filteredTrimURL = filteredTrimDir.appendingPathComponent("trim-positions.tsv")
                try filteredTrimContent.write(to: filteredTrimURL, atomically: true, encoding: .utf8)
                defer { try? fm.removeItem(at: filteredTrimDir) }
                try await extractAndTrimFASTAReads(
                    fromRootFASTA: rootFASTAURL,
                    readIDsFile: readIDListURL,
                    trimPositionsFile: filteredTrimURL,
                    outputFASTA: extractTarget
                )
            } else {
                throw FASTQDerivativeError.emptyResult
            }
        } else if let orientMapURL {
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            let selectedReadIDs = try loadSelectedReadIDLookup(from: readIDListURL)
            try await materializeOrientedFASTAReads(
                fromRootFASTA: rootFASTAURL,
                forwardReadIDs: fwdReadIDs.filter { selectedReadIDs.contains($0) },
                rcReadIDs: rcReadIDs.filter { selectedReadIDs.contains($0) },
                outputFASTA: outputURL
            )
            return
        } else {
            try await extractReads(
                fromRootFASTQ: rootFASTAURL,
                readIDsFile: readIDListURL,
                outputFASTQ: outputURL
            )
            return
        }

        if let orientMapURL {
            let fwdReadIDs = try FASTQOrientMapFile.loadForwardReadIDs(from: orientMapURL)
            let rcReadIDs = try FASTQOrientMapFile.loadRCReadIDs(from: orientMapURL)
            try await materializeOrientedFASTAReads(
                fromRootFASTA: extractTarget,
                forwardReadIDs: fwdReadIDs,
                rcReadIDs: rcReadIDs,
                outputFASTA: outputURL
            )
        }
    }

    /// Materializes an oriented FASTQ by streaming through the root FASTQ and
    /// reverse-complementing reads marked in the RC set using seqkit.
    ///
    /// Strategy: Extract RC reads → reverse complement them → concatenate with forward reads.
    func materializeOrientedReads(
        fromRootFASTQ rootFASTQ: URL,
        forwardReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTQ: URL
    ) async throws {
        let selectedReadIDs = forwardReadIDs.union(rcReadIDs)
        guard !selectedReadIDs.isEmpty else {
            throw FASTQDerivativeError.emptyResult
        }

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.records(from: rootFASTQ) {
            let readID = normalizedIdentifier(record.identifier)
            guard selectedReadIDs.contains(readID) || selectedReadIDs.contains(record.identifier) else { continue }
            if rcReadIDs.contains(readID) || rcReadIDs.contains(record.identifier) {
                try writer.write(record.reverseComplement())
            } else {
                try writer.write(record)
            }
        }
    }

    func writeOrientedPreviewFASTQ(
        fromSourceFASTQ sourceFASTQ: URL,
        orientMapURL: URL,
        outputFASTQ: URL,
        readLimit: Int = 1_000
    ) async throws {
        let orientContent = try String(contentsOf: orientMapURL, encoding: .utf8)
        var orderedReadIDs: [String] = []
        var rcReadIDs: Set<String> = []

        for line in orientContent.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let readID = String(fields[0])
            orderedReadIDs.append(readID)
            if fields[1] == "-" {
                rcReadIDs.insert(readID)
            }
            if orderedReadIDs.count >= max(1, readLimit) {
                break
            }
        }

        guard !orderedReadIDs.isEmpty else { return }

        let selectedReadIDs = Set(orderedReadIDs)
        var previewRecords: [String: FASTQRecord] = [:]
        let reader = FASTQReader(validateSequence: false)

        for try await record in reader.records(from: sourceFASTQ) {
            let readID = normalizedIdentifier(record.identifier)
            guard selectedReadIDs.contains(readID) else { continue }

            if rcReadIDs.contains(readID) {
                previewRecords[readID] = record.reverseComplement()
            } else {
                previewRecords[readID] = record
            }

            if previewRecords.count == selectedReadIDs.count {
                break
            }
        }

        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for readID in orderedReadIDs {
            if let record = previewRecords[readID] {
                try writer.write(record)
            }
        }
    }

    /// Extracts reads from root FASTQ by ID list, then applies stored trim positions
    /// to remove adapter/barcode/primer sequences from each read.
    ///
    /// Uses a two-step approach: seqkit grep (extract by ID) → seqkit subseq (apply trims).
    /// The trim positions file is a TSV with columns: read_id, trim_5p, trim_3p
    /// where trim_5p is bases to remove from 5' end and trim_3p is bases to remove from 3' end.
    func extractAndTrimReads(
        fromRootFASTQ rootFASTQ: URL,
        readIDsFile: URL,
        trimPositionsFile: URL,
        outputFASTQ: URL
    ) async throws {
        let fm = FileManager.default
        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-trim-",
            contextURL: rootFASTQ
        )
        defer { try? fm.removeItem(at: tempDir) }

        // Step 1: Extract reads by ID into temp file
        let extractedURL = tempDir.appendingPathComponent("extracted.fastq.gz")
        try await extractReads(fromRootFASTQ: rootFASTQ, readIDsFile: readIDsFile, outputFASTQ: extractedURL)

        // Step 2: Parse trim positions (supports both 3-column legacy and 4-column mate-aware formats)
        guard let trimContent = try? String(contentsOf: trimPositionsFile, encoding: .utf8) else {
            // No trim positions — just move extracted reads to output
            try fm.moveItem(at: extractedURL, to: outputFASTQ)
            return
        }

        // Key: "readID\tmate" for PE-safe lookup (mate=0 for single-end/legacy)
        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in trimContent.split(separator: "\n") {
            // Skip format headers and column headers
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                // 4-column format: read_id, mate, trim_5p, trim_3p
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t\(mate)"] = (t5, t3)
            } else if cols.count >= 3,
                      let t5 = Int(cols[1]),
                      let t3 = Int(cols[2]) {
                // Legacy 3-column format: read_id, trim_5p, trim_3p
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t0"] = (t5, t3)
            }
        }

        guard !trimMap.isEmpty else {
            try fm.moveItem(at: extractedURL, to: outputFASTQ)
            return
        }

        // Step 3: Apply trims using native Swift FASTQ reader/writer with streaming writes
        let reader = FASTQReader(validateSequence: false)
        let plainURL = tempDir.appendingPathComponent("trimmed.fastq")
        fm.createFile(atPath: plainURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: plainURL)

        do {
            for try await record in reader.records(from: extractedURL) {
                let readID = record.identifier
                let seq = record.sequence
                let qual = record.quality.toAscii()
                let header = record.description != nil
                    ? "\(record.identifier) \(record.description!)"
                    : record.identifier

                // Detect mate for PE-safe trim lookup (also strips /1 /2 from readID)
                let (baseReadID, mate) = detectMateFromHeader(identifier: readID, description: record.description)
                // Try mate-specific key first, then fallback to mate=0 (single-end/legacy)
                let trim = trimMap["\(baseReadID)\t\(mate)"] ?? trimMap["\(baseReadID)\t0"]

                let line: String
                if let trim {
                    let startIndex = min(trim.trim5p, seq.count)
                    let endIndex = max(startIndex, seq.count - trim.trim3p)
                    let trimmedSeq = String(seq[seq.index(seq.startIndex, offsetBy: startIndex)..<seq.index(seq.startIndex, offsetBy: endIndex)])
                    let trimmedQual = String(qual[qual.index(qual.startIndex, offsetBy: startIndex)..<qual.index(qual.startIndex, offsetBy: endIndex)])
                    line = "@\(header)\n\(trimmedSeq)\n+\n\(trimmedQual)\n"
                } else {
                    line = "@\(header)\n\(seq)\n+\n\(qual)\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

        if outputFASTQ.pathExtension == "gz" {
            // Use seqkit seq to copy and gzip the output
            let gzipResult = try await runner.run(
                .seqkit,
                arguments: ["seq", plainURL.path, "-o", outputFASTQ.path],
                timeout: 300
            )
            if !gzipResult.isSuccess {
                // Fallback: copy uncompressed
                try fm.moveItem(at: plainURL, to: outputFASTQ)
            }
        } else {
            try fm.moveItem(at: plainURL, to: outputFASTQ)
        }
    }

    /// Extracts and trims reads from a FASTA file.
    /// Analogous to `extractAndTrimReads` but produces FASTA output (no quality scores).
    func extractAndTrimFASTAReads(
        fromRootFASTA rootFASTA: URL,
        readIDsFile: URL,
        trimPositionsFile: URL,
        outputFASTA: URL
    ) async throws {
        let fm = FileManager.default
        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-fasta-trim-",
            contextURL: rootFASTA
        )
        defer { try? fm.removeItem(at: tempDir) }

        // Step 1: Extract reads by ID using seqkit grep (works on FASTA too)
        let extractedURL = tempDir.appendingPathComponent("extracted.fasta")
        try await extractReads(fromRootFASTQ: rootFASTA, readIDsFile: readIDsFile, outputFASTQ: extractedURL)

        // Step 2: Parse trim positions
        guard let trimContent = try? String(contentsOf: trimPositionsFile, encoding: .utf8) else {
            try fm.moveItem(at: extractedURL, to: outputFASTA)
            return
        }

        var trimMap: [String: (trim5p: Int, trim3p: Int)] = [:]
        for line in trimContent.split(separator: "\n") {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            let cols = line.split(separator: "\t")
            if cols.count >= 4, let mate = Int(cols[1]),
               let t5 = Int(cols[2]), let t3 = Int(cols[3]) {
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t\(mate)"] = (t5, t3)
            } else if cols.count >= 3,
                      let t5 = Int(cols[1]),
                      let t3 = Int(cols[2]) {
                let readID = canonicalDemuxTrimReadID(String(cols[0]))
                trimMap["\(readID)\t0"] = (t5, t3)
            }
        }

        guard !trimMap.isEmpty else {
            try fm.moveItem(at: extractedURL, to: outputFASTA)
            return
        }

        // Step 3: Apply trims using FASTAReader streaming
        let reader = try FASTAReader(url: extractedURL)
        let plainURL = tempDir.appendingPathComponent("trimmed.fasta")
        fm.createFile(atPath: plainURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: plainURL)

        do {
            for try await record in reader.sequences() {
                let readID = record.name
                let seq = record.asString()
                let header = record.description != nil
                    ? "\(record.name) \(record.description!)"
                    : record.name

                let trim = trimMap["\(readID)\t0"]

                let outputSeq: String
                if let trim {
                    let startIndex = min(trim.trim5p, seq.count)
                    let endIndex = max(startIndex, seq.count - trim.trim3p)
                    outputSeq = String(seq[seq.index(seq.startIndex, offsetBy: startIndex)..<seq.index(seq.startIndex, offsetBy: endIndex)])
                } else {
                    outputSeq = seq
                }

                // Write FASTA record with 60-char line wrapping
                var line = ">\(header)\n"
                for i in stride(from: 0, to: outputSeq.count, by: 60) {
                    let start = outputSeq.index(outputSeq.startIndex, offsetBy: i)
                    let end = outputSeq.index(start, offsetBy: min(60, outputSeq.count - i))
                    line += String(outputSeq[start..<end]) + "\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

        try fm.moveItem(at: plainURL, to: outputFASTA)
    }

    func materializeOrientedFASTAReads(
        fromRootFASTA rootFASTA: URL,
        forwardReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTA: URL
    ) async throws {
        let selectedReadIDs = forwardReadIDs.union(rcReadIDs)
        guard !selectedReadIDs.isEmpty else {
            throw FASTQDerivativeError.emptyResult
        }

        let reader = try FASTAReader(url: rootFASTA)
        let fm = FileManager.default
        fm.createFile(atPath: outputFASTA.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: outputFASTA)

        do {
            defer { try? writeHandle.close() }
            for try await record in reader.sequences() {
                let normalizedID = normalizedIdentifier(record.name)
                let baseReadID = detectMateFromHeader(identifier: normalizedID, description: nil).readID
                guard selectedReadIDs.contains(record.name)
                        || selectedReadIDs.contains(normalizedID)
                        || selectedReadIDs.contains(baseReadID) else { continue }

                let outputSequence: String
                if rcReadIDs.contains(record.name)
                    || rcReadIDs.contains(normalizedID)
                    || rcReadIDs.contains(baseReadID) {
                    outputSequence = PlatformAdapters.reverseComplement(record.asString())
                } else {
                    outputSequence = record.asString()
                }

                var line = ">\(record.name)"
                if let description = record.description {
                    line += " \(description)"
                }
                line += "\n"
                for i in stride(from: 0, to: outputSequence.count, by: 60) {
                    let start = outputSequence.index(outputSequence.startIndex, offsetBy: i)
                    let end = outputSequence.index(start, offsetBy: min(60, outputSequence.count - i))
                    line += String(outputSequence[start..<end]) + "\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
        } catch {
            try? writeHandle.close()
            throw error
        }
    }

    /// Extracts and trims FASTA reads using absolute position-based trims.
    /// Analogous to `extractTrimmedReads` but for FASTA format (no quality scores).
    func extractTrimmedFASTAReads(
        fromRootFASTA rootFASTA: URL,
        positions: [String: (start: Int, end: Int)],
        outputFASTA: URL
    ) async throws {
        if positions.isEmpty {
            throw FASTQDerivativeError.emptyResult
        }

        let reader = try FASTAReader(url: rootFASTA)
        let fm = FileManager.default
        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-fasta-postrim-",
            contextURL: rootFASTA
        )
        defer { try? fm.removeItem(at: tempDir) }

        let plainURL = tempDir.appendingPathComponent("trimmed.fasta")
        fm.createFile(atPath: plainURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: plainURL)

        do {
            for try await record in reader.sequences() {
                let key = record.name
                guard let pos = positions[key] else { continue }
                let seq = record.asString()
                let safeStart = min(pos.start, seq.count)
                let safeEnd = min(max(safeStart, pos.end), seq.count)
                guard safeEnd > safeStart else { continue }

                let trimmedSeq = String(seq[seq.index(seq.startIndex, offsetBy: safeStart)..<seq.index(seq.startIndex, offsetBy: safeEnd)])
                let header = record.description.map { "\(record.name) \($0)" } ?? record.name

                var line = ">\(header)\n"
                for i in stride(from: 0, to: trimmedSeq.count, by: 60) {
                    let start = trimmedSeq.index(trimmedSeq.startIndex, offsetBy: i)
                    let end = trimmedSeq.index(start, offsetBy: min(60, trimmedSeq.count - i))
                    line += String(trimmedSeq[start..<end]) + "\n"
                }
                if let data = line.data(using: .utf8) {
                    writeHandle.write(data)
                }
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            throw error
        }

        try fm.moveItem(at: plainURL, to: outputFASTA)
    }

    /// Detects mate number from FASTQ record header for PE-safe trim lookup.
    /// Returns (baseReadID, mate) where mate is 0 (single), 1 (R1), or 2 (R2).
    /// Strips `/1` or `/2` suffix from identifier when present so the returned
    /// readID matches the pipeline's trim map keys.
    func detectMateFromHeader(identifier: String, description: String?) -> (readID: String, mate: Int) {
        // Check /1 or /2 suffix on identifier (legacy FASTQ format)
        if identifier.hasSuffix("/1") {
            return (String(identifier.dropLast(2)), 1)
        }
        if identifier.hasSuffix("/2") {
            return (String(identifier.dropLast(2)), 2)
        }
        // Check Illumina description format: "1:N:0:..." or "2:N:0:..."
        if let desc = description {
            if desc.hasPrefix("1:") { return (identifier, 1) }
            if desc.hasPrefix("2:") { return (identifier, 2) }
        }
        return (identifier, 0)
    }

}
