// SalmonIndexCache+Uses.swift - Uses, removal, the stage sweep and the stage hold (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import Foundation
import LungfishCore
import Synchronization

extension SalmonIndexCache {
    public static let usesFolderName = "uses"
    static let resultRecordName = ProvenanceRecorder.provenanceFilename

    /// One use of an index: the result folder that names it and the sha256 of that folder's record when the use was made.
    public struct Use: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var resultPath: String
        public var recordSHA256: String
    }

    /// Records that `resultFolder` used the index, as `uses/<sha256 of the result path>.json`. The file is written once
    /// and never rewritten, so a later call for the same result returns it as it is.
    @discardableResult
    public func recordUse(of outcome: SalmonIndexOutcome, resultFolder: URL) throws -> URL {
        let uses = outcome.url.appendingPathComponent(Self.usesFolderName, isDirectory: true)
        let path = resultFolder.standardizedFileURL.path
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        let url = uses.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: uses, withIntermediateDirectories: true)
        let record = try ProvenanceFileHasher.sha256(of: resultFolder.appendingPathComponent(Self.resultRecordName))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try DurableReplace.replace(
            try encoder.encode(Use(schemaVersion: 1, resultPath: path, recordSHA256: record)), named: name, in: uses)
        return url
    }

    /// The result paths of the uses that hold the index: the result folder is there and its record names every hash.
    public func liveUses(of url: URL, hashes: SalmonIndexHashes) -> [String] {
        let uses = url.appendingPathComponent(Self.usesFolderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: uses.path)) ?? []
        var live: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: uses.appendingPathComponent(name)),
                  let use = try? JSONDecoder().decode(Use.self, from: data) else { continue }
            let record = URL(fileURLWithPath: use.resultPath).appendingPathComponent(Self.resultRecordName)
            guard let text = try? String(contentsOf: record, encoding: .utf8) else { continue }
            if hashes.all.allSatisfy(text.contains) { live.append(use.resultPath) }
        }
        return live
    }

    /// Removes the index of `key`, then its set's folder when nothing else is in it. A use that holds the index refuses the
    /// removal in words that name each result.
    public func remove(_ key: SalmonIndexKey) throws {
        let url = folder(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SalmonIndexError.notFound(path: url.path) }
        let outcome = try settled(url, key: key)
        let live = liveUses(of: url, hashes: outcome.hashes)
        guard live.isEmpty else { throw SalmonIndexError.inUse(index: url.path, results: live) }
        try FileManager.default.removeItem(at: url)
        rmdir(url.deletingLastPathComponent().path)
    }

    /// Removes each `.salmon-*.creating-<UUID>` folder under every set's folder whose flock no running build holds, and
    /// nothing else.
    func removeAbandonedStages() {
        let sets = (try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)) ?? []
        for set in sets where !set.hasPrefix(".") {
            let folder = cacheFolder.appendingPathComponent(set, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix(".salmon-") && name.contains(".creating-") {
                let stage = folder.appendingPathComponent(name, isDirectory: true)
                let descriptor = open(stage.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
                try? FileManager.default.removeItem(at: stage)
            }
        }
    }
}

/// A build's stage `.<key folder>.creating-<UUID>` and the exclusive flock that marks it as held while the build runs, on
/// the pattern of ``ReferenceSetStageHold``.
final class SalmonIndexStageHold: Sendable {
    let url: URL
    private let descriptor: Mutex<Int32>

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = Mutex(descriptor)
    }

    static func make(in folder: URL, name: String) throws -> SalmonIndexStageHold {
        // A sweep of another build can take a stage between its mkdir and its flock, so a lost stage is made again.
        for _ in 0..<3 {
            let url = folder.appendingPathComponent(".\(name).creating-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return SalmonIndexStageHold(url: url, descriptor: descriptor)
            }
            if descriptor >= 0 { close(descriptor) }
        }
        throw SalmonIndexError.invalidRequest("Lungfish could not hold a staging folder in \(folder.path).")
    }

    func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}

/// The names of a FASTA's records, each header up to its first space, tab or carriage return, read chunk by chunk.
struct FASTAHeaderNames {
    private var header: [UInt8]?
    private var atLineStart = true
    private var names: [String] = []

    mutating func feed(_ chunk: Data) {
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var index = 0
            while index < raw.count {
                let end = memchr(base + index, 0x0A, raw.count - index).map { base.distance(to: UnsafeRawPointer($0)) }
                if header != nil {
                    header?.append(contentsOf: raw[index..<(end ?? raw.count)])
                    if let end {
                        finishHeader()
                        index = end + 1
                        atLineStart = true
                    } else {
                        index = raw.count
                    }
                } else if atLineStart, raw[index] == 0x3E {
                    header = []
                    atLineStart = false
                    index += 1
                } else if let end {
                    index = end + 1
                    atLineStart = true
                } else {
                    index = raw.count
                    atLineStart = false
                }
            }
        }
    }

    mutating func finish() -> [String] {
        finishHeader()
        return names
    }

    private mutating func finishHeader() {
        guard let bytes = header else { return }
        header = nil
        let name = bytes.prefix { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }
        if !name.isEmpty { names.append(String(decoding: name, as: UTF8.self)) }
    }
}
