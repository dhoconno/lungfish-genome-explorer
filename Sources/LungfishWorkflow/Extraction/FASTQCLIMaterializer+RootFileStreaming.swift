// FASTQCLIMaterializer+RootFileStreaming.swift - Streaming a derivative's recipe over every file of its root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - Root file streaming

extension FASTQCLIMaterializer {
    // MARK: - Trim extraction (pure Swift I/O)

    /// Streams the root files in order as one record stream. A positional
    /// key (`id#ordinal`) counts occurrences of a base ID across the whole
    /// stream, so a table made over the first file alone still names the
    /// same records when the later files are read after it.
    func extractTrimmedReads(
        fromRootFASTQs rootFASTQs: [URL],
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
            for rootFASTQ in rootFASTQs {
                for try await record in reader.records(from: rootFASTQ) {
                    let baseID = normalizedIdentifier(record.identifier)
                    let ordinal = occurrencePerBaseID[baseID] ?? 0
                    occurrencePerBaseID[baseID] = ordinal + 1
                    let key = "\(baseID)#\(ordinal)"
                    guard let pos = positions[key] else { continue }
                    let trimmed = record.trimmed(from: pos.start, to: pos.end)
                    if trimmed.length > 0 { try writer.write(trimmed) }
                }
            }
        } else {
            for rootFASTQ in rootFASTQs {
                for try await record in reader.records(from: rootFASTQ) {
                    let key = normalizedIdentifier(record.identifier)
                    guard let pos = positions[key] else { continue }
                    let trimmed = record.trimmed(from: pos.start, to: pos.end)
                    if trimmed.length > 0 { try writer.write(trimmed) }
                }
            }
        }
    }

    func extractTrimmedFASTAReads(
        fromRootFASTAs rootFASTAs: [URL],
        positions: [String: (start: Int, end: Int)],
        outputFASTA: URL
    ) async throws {
        guard !positions.isEmpty else {
            throw FASTQCLIMaterializerError.emptyResult
        }

        let usesPositionalKeys = positions.keys.contains(where: { $0.contains("#") })
        FileManager.default.createFile(atPath: outputFASTA.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFASTA)
        defer { try? handle.close() }

        if usesPositionalKeys {
            var occurrencePerBaseID: [String: Int] = [:]
            for rootFASTA in rootFASTAs {
                let reader = try FASTAReader(url: rootFASTA)
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
            }
        } else {
            for rootFASTA in rootFASTAs {
                let reader = try FASTAReader(url: rootFASTA)
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
    }

    // MARK: - Orient materialization

    func materializeOrientedReads(
        fromRootFASTQs rootFASTQs: [URL],
        allReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTQ: URL
    ) async throws {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for rootFASTQ in rootFASTQs {
            for try await record in reader.records(from: rootFASTQ) {
                let id = normalizedIdentifier(record.identifier)
                if rcReadIDs.contains(id) {
                    try writer.write(record.reverseComplement())
                } else if allReadIDs.contains(id) {
                    try writer.write(record)
                }
            }
        }
    }

    func materializeOrientedFASTAReads(
        fromRootFASTAs rootFASTAs: [URL],
        allReadIDs: Set<String>,
        rcReadIDs: Set<String>,
        outputFASTA: URL
    ) async throws {
        FileManager.default.createFile(atPath: outputFASTA.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFASTA)
        defer { try? handle.close() }

        for rootFASTA in rootFASTAs {
            let reader = try FASTAReader(url: rootFASTA)
            for try await seq in reader.sequences() {
                let id = normalizedIdentifier(seq.name)
                if rcReadIDs.contains(id) {
                    if let rc = seq.reverseComplement() {
                        writeFASTARecord(name: seq.name, sequence: rc.asString(), to: handle)
                    }
                } else if allReadIDs.contains(id) {
                    writeFASTARecord(name: seq.name, sequence: seq.asString(), to: handle)
                }
            }
        }
    }

    /// The root files a derivative's recipe applies to, each of which exists:
    /// every member of a multi-file root in manifest order, else the one
    /// recorded file (`FASTQBundle.rootSequenceURLs`).
    func rootSequenceURLs(_ rootFASTQFilename: String, in rootBundleURL: URL) throws -> [URL] {
        let urls: [URL]
        do {
            urls = try FASTQBundle.rootSequenceURLs(rootFASTQFilename: rootFASTQFilename, in: rootBundleURL)
        } catch let error as FASTQBundlePathError {
            if case .missingMember = error { throw error }
            throw FASTQCLIMaterializerError.rootFASTQMissing
        } catch {
            throw FASTQCLIMaterializerError.rootFASTQMissing
        }
        guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FASTQCLIMaterializerError.rootFASTQMissing
        }
        return urls
    }

    private func writeFASTARecord(name: String, sequence: String, to handle: FileHandle) {
        let line = ">\(name)\n\(sequence)\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }
}
