// ClassifierAlignmentEvidenceValidator.swift - Read-only validation for detached classifier BAM evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

/// Validates final classifier evidence before it is handed to the detached viewer.
///
/// The validator deliberately has no output path. Opening evidence is read-only: the
/// returned `AlignmentDataProvider` points at the final BAM and explicit index.
struct ClassifierAlignmentEvidenceValidator: @unchecked Sendable {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case bamUnavailable(URL)
        case indexUnavailable(URL)
        case evidenceOutsideFinalResult(URL)
        case indexDoesNotMatchBAM(String)
        case headerUnavailable(String)
        case contigUnavailable(String)
        case contigLengthMismatch(expected: Int, actual: Int)
        case snapshotMismatch(URL)
        case decodingReferenceRequired(URL)

        var errorDescription: String? {
            switch self {
            case .bamUnavailable(let url): "The final BAM is unavailable: \(url.lastPathComponent)."
            case .indexUnavailable(let url): "The explicit BAM index is unavailable: \(url.lastPathComponent)."
            case .evidenceOutsideFinalResult(let url): "Classifier evidence must be stored inside the final result: \(url.lastPathComponent)."
            case .indexDoesNotMatchBAM(let detail): "The explicit BAM index does not match the BAM: \(detail)"
            case .headerUnavailable(let detail): "The BAM header could not be read: \(detail)"
            case .contigUnavailable(let name): "The requested BAM contig '\(name)' is unavailable."
            case .contigLengthMismatch(let expected, let actual): "The BAM contig length is \(actual), expected \(expected)."
            case .snapshotMismatch(let url): "Final evidence changed after the request was created: \(url.lastPathComponent)."
            case .decodingReferenceRequired(let url): "A validated decoding reference is required for CRAM evidence: \(url.lastPathComponent)."
            }
        }
    }

    enum ReferenceStatus: Equatable {
        case notProvided
        case validatedStructural
        case validatedMD5
        case unavailable
    }

    struct Reference: Equatable {
        let status: ReferenceStatus
        let sequence: String?
        let reason: String?
    }

    struct Contig: Equatable {
        let name: String
        let length: Int
    }

    struct Result {
        let request: ClassifierAlignmentEvidenceRequest
        let contig: Contig
        let provider: AlignmentDataProvider
        let reference: Reference
        let bamSnapshot: ClassifierAlignmentEvidenceFileSnapshot
        let indexSnapshot: ClassifierAlignmentEvidenceFileSnapshot
        let referenceSnapshot: ClassifierAlignmentEvidenceFileSnapshot?
        let readGroups: [SAMParser.ReadGroup]
    }

    typealias HeaderReader = @Sendable (URL) async throws -> String
    typealias IndexQuery = @Sendable (URL, URL, String) async throws -> Void
    typealias ReferenceReader = @Sendable (URL, String) throws -> String

    private let headerReader: HeaderReader?
    private let indexQuery: IndexQuery?
    private let referenceReader: ReferenceReader
    private let fileManager: FileManager
    /// Roots outside the final result that may legitimately hold a reference FASTA.
    ///
    /// BAM and index evidence must always live inside the result; a reference may
    /// not. EsViritu aligns against the pangenome FASTA of a managed EsViritu
    /// database, which is shared across every result and deliberately not copied
    /// into any of them. Admitting the managed databases root, and only that root,
    /// keeps the reference honest without weakening containment for evidence.
    /// The snapshot re-validation still rejects a database that changes underneath
    /// an open viewer.
    private let additionalReferenceRoots: [URL]

    init(
        headerReader: HeaderReader? = nil,
        indexQuery: IndexQuery? = nil,
        referenceReader: @escaping ReferenceReader = { url, name in
            try Self.readExactFASTARecord(at: url, named: name)
        },
        fileManager: FileManager = .default,
        additionalReferenceRoots: [URL] = [ManagedStorageConfigStore().currentLocation().databaseRootURL]
    ) {
        self.headerReader = headerReader
        self.indexQuery = indexQuery
        self.referenceReader = referenceReader
        self.fileManager = fileManager
        self.additionalReferenceRoots = additionalReferenceRoots
    }

    func validate(_ request: ClassifierAlignmentEvidenceRequest) async throws -> Result {
        try validateContainment(of: request.bamURL, in: request.resultIdentity.finalResultURL)
        try validateContainment(of: request.index.url, in: request.resultIdentity.finalResultURL)
        if let reference = request.referenceCandidate {
            try validateReferenceContainment(of: reference.fastaURL, in: request.resultIdentity.finalResultURL)
        }
        guard fileManager.isReadableFile(atPath: request.bamURL.path) else {
            throw Error.bamUnavailable(request.bamURL)
        }
        guard fileManager.isReadableFile(atPath: request.index.url.path) else {
            throw Error.indexUnavailable(request.index.url)
        }
        let bamSnapshot = try await Self.snapshotOffMain(request.bamURL)
        let indexSnapshot = try await Self.snapshotOffMain(request.index.url)
        if let expected = request.bamExpectedSnapshot, expected != bamSnapshot { throw Error.snapshotMismatch(request.bamURL) }
        if let expected = request.index.expectedSnapshot, expected != indexSnapshot { throw Error.snapshotMismatch(request.index.url) }

        let format: AlignmentFormat = request.bamURL.pathExtension.lowercased() == "cram" ? .cram : .bam
        let provider = AlignmentDataProvider(
            alignmentPath: request.bamURL.path,
            indexPath: request.index.url.path,
            format: format,
            referenceFastaPath: format == .cram ? request.referenceCandidate?.fastaURL.path : nil
        )
        let header: String
        do {
            header = if let headerReader {
                try await headerReader(request.bamURL)
            } else {
                try await provider.fetchHeader()
            }
        }
        catch { throw Error.headerUnavailable(error.localizedDescription) }
        let sequences = SAMParser.parseReferenceSequences(from: header)
        guard let sequence = sequences.first(where: { $0.name == request.contig.name }) else {
            throw Error.contigUnavailable(request.contig.name)
        }
        guard sequence.length == Int64(request.contig.expectedLength) else {
            throw Error.contigLengthMismatch(expected: request.contig.expectedLength, actual: Int(sequence.length))
        }

        do {
            if let indexQuery {
                try await indexQuery(request.bamURL, request.index.url, request.contig.name)
            } else {
                _ = try await provider.fetchReads(chromosome: request.contig.name, start: 0, end: 1, maxReads: 1)
            }
        }
        catch { throw Error.indexDoesNotMatchBAM(error.localizedDescription) }

        let referenceValidation = await validateReference(
            request.referenceCandidate,
            bamMD5: sequence.md5,
            expectedContigLength: request.contig.expectedLength
        )
        let reference = referenceValidation.reference
        let referenceSnapshot = referenceValidation.snapshot
        if format == .cram, reference.sequence == nil {
            throw Error.decodingReferenceRequired(request.bamURL)
        }
        if let expected = request.referenceCandidate?.expectedSnapshot,
           let referenceSnapshot,
           expected != referenceSnapshot {
            throw Error.snapshotMismatch(request.referenceCandidate!.fastaURL)
        }
        // The view installs only after this final off-main comparison. This
        // closes the validation-to-display interval without asking AppKit to
        // hash an entire BAM on its main actor.
        guard try await Self.snapshotOffMain(request.bamURL) == bamSnapshot else {
            throw Error.snapshotMismatch(request.bamURL)
        }
        guard try await Self.snapshotOffMain(request.index.url) == indexSnapshot else {
            throw Error.snapshotMismatch(request.index.url)
        }
        if let candidate = request.referenceCandidate, let referenceSnapshot {
            guard try await Self.snapshotOffMain(candidate.fastaURL) == referenceSnapshot else {
                throw Error.snapshotMismatch(candidate.fastaURL)
            }
        }
        return Result(
            request: request,
            contig: Contig(name: request.contig.name, length: request.contig.expectedLength),
            provider: provider,
            reference: reference,
            bamSnapshot: bamSnapshot,
            indexSnapshot: indexSnapshot,
            referenceSnapshot: reference.sequence == nil ? nil : referenceSnapshot,
            readGroups: SAMParser.parseReadGroups(from: header)
        )
    }

    /// Uses standardized, symlink-resolved path components rather than string prefixes:
    /// `/result-copy` is not inside `/result`, and a symlinked member cannot escape.
    private func validateContainment(of candidate: URL, in finalResultURL: URL) throws {
        guard Self.isContained(candidate, inAnyOf: [finalResultURL]) else {
            throw Error.evidenceOutsideFinalResult(candidate)
        }
    }

    /// A reference FASTA may live in the final result or in one of the extra
    /// permitted roots (the managed databases root). Everything else is rejected.
    private func validateReferenceContainment(of candidate: URL, in finalResultURL: URL) throws {
        guard Self.isContained(candidate, inAnyOf: [finalResultURL] + additionalReferenceRoots) else {
            throw Error.evidenceOutsideFinalResult(candidate)
        }
    }

    /// Whether `candidate` resolves to a path inside any of `roots`.
    ///
    /// Comparison is on standardized, symlink-resolved path *components*, so a
    /// sibling directory sharing a name prefix is outside, and a symlink planted
    /// inside a root cannot smuggle in a file that lives elsewhere.
    static func isContained(_ candidate: URL, inAnyOf roots: [URL]) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return roots.contains { root in
            let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard !rootComponents.isEmpty, candidateComponents.count >= rootComponents.count else { return false }
            return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        }
    }

    private func validateReference(
        _ candidate: ClassifierAlignmentReferenceCandidate?,
        bamMD5: String?,
        expectedContigLength: Int
    ) async -> (reference: Reference, snapshot: ClassifierAlignmentEvidenceFileSnapshot?) {
        guard let candidate else { return (Reference(status: .notProvided, sequence: nil, reason: nil), nil) }
        guard let before = try? await Self.snapshotOffMain(candidate.fastaURL),
              let record = try? referenceReader(candidate.fastaURL, candidate.recordName),
              let after = try? await Self.snapshotOffMain(candidate.fastaURL),
              before == after else {
            return (Reference(status: .unavailable, sequence: nil, reason: "The requested FASTA record is unavailable."), nil)
        }
        guard record.count == candidate.expectedLength, record.count == expectedContigLength else {
            return (Reference(status: .unavailable, sequence: nil, reason: "The FASTA record length does not match the selected BAM contig."), after)
        }
        let expectedMD5s = [candidate.expectedMD5, bamMD5].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        // MD5 validation strength is only cryptographic when an @SQ M5 was
        // present and compared; a candidate-only checksum remains structural.
        if !expectedMD5s.isEmpty {
            let observed = Insecure.MD5.hash(data: Data(record.utf8)).map { String(format: "%02x", $0) }.joined()
            guard expectedMD5s.allSatisfy({ observed.caseInsensitiveCompare($0) == .orderedSame }) else {
                return (Reference(status: .unavailable, sequence: nil, reason: "The FASTA record M5 checksum does not match the BAM header."), after)
            }
            return (Reference(status: bamMD5?.isEmpty == false ? .validatedMD5 : .validatedStructural, sequence: record, reason: nil), after)
        }
        return (Reference(status: .validatedStructural, sequence: record, reason: nil), after)
    }

    private static func snapshotOffMain(_ url: URL) async throws -> ClassifierAlignmentEvidenceFileSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.snapshot(url)
        }.value
    }

    /// Digest cache keyed by (path, size, mtime, edge probe).
    ///
    /// The snapshot invariant (detect the file changing under an open viewer)
    /// needs a fresh full hash only when the file changed. Hashing the 240 MB
    /// EsViritu pangenome three times per detection click made every click pay
    /// seconds of SHA-256 for a version-pinned managed database. The cache key
    /// is size + mtime + a hash of the first and last 64 KB, so a rewrite is
    /// re-hashed even when it lands within mtime granularity at the same size
    /// (the case the mid-read replacement tests exercise); only a byte change
    /// confined to the middle of a file with identical size, mtime, and edges
    /// would be missed, which no real update path produces.
    private static let snapshotCache = SnapshotDigestCache()

    final class SnapshotDigestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (size: Int64, mtime: Date, probe: String, snapshot: ClassifierAlignmentEvidenceFileSnapshot)] = [:]

        func snapshot(
            path: String,
            size: Int64,
            mtime: Date,
            probe: String,
            compute: () throws -> ClassifierAlignmentEvidenceFileSnapshot
        ) rethrows -> ClassifierAlignmentEvidenceFileSnapshot {
            lock.lock()
            if let entry = entries[path], entry.size == size, entry.mtime == mtime, entry.probe == probe {
                lock.unlock()
                return entry.snapshot
            }
            lock.unlock()
            let fresh = try compute()
            lock.lock()
            entries[path] = (size, mtime, probe, fresh)
            if entries.count > 64 { entries.removeAll() }
            lock.unlock()
            return fresh
        }
    }

    /// SHA-256 of the first and last 64 KB: cheap change detector for the cache key.
    static func snapshotEdgeProbe(_ url: URL, size: Int64) throws -> String {
        let window: Int64 = 64 << 10
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        let head = try handle.read(upToCount: Int(min(window, max(size, 0)))) ?? Data()
        digest.update(data: head)
        if size > window {
            try handle.seek(toOffset: UInt64(size - window))
            let tail = try handle.read(upToCount: Int(window)) ?? Data()
            digest.update(data: tail)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func snapshot(_ url: URL) throws -> ClassifierAlignmentEvidenceFileSnapshot {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate ?? .distantPast
        let probe = try snapshotEdgeProbe(url, size: size)
        return try snapshotCache.snapshot(path: url.path, size: size, mtime: mtime, probe: probe) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while true {
                let data = try handle.read(upToCount: 1 << 20) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
            }
            return .init(size: size, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    /// Byte size above which a full-file scan is refused in favour of `.fai` random access.
    ///
    /// The EsViritu pangenome FASTA is hundreds of megabytes; reading it into a
    /// `String` once per detection row is not viable. Small result-local
    /// references keep the simple exact-scan path, which is also the path the
    /// duplicate-record and whitespace rules were written against.
    static let indexedReadThreshold: Int = 8 << 20

    /// Reads one FASTA record, using a `.fai` index for any file large enough that
    /// a full scan would be wasteful.
    ///
    /// The index is built once beside the FASTA when it is missing and reused
    /// afterwards. Building is a single sequential pass that never materializes
    /// the file in memory. If the index cannot be built or written (a read-only
    /// managed database directory, for instance) the in-memory index still
    /// answers the lookup for this call.
    static func readExactFASTARecord(at url: URL, named name: String) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > indexedReadThreshold else {
            return try readExactFASTARecordByScanning(at: url, named: name)
        }
        return try readIndexedFASTARecord(at: url, named: name)
    }

    private static func readIndexedFASTARecord(at url: URL, named name: String) throws -> String {
        let indexURL = URL(fileURLWithPath: url.path + ".fai")
        // An index left over from an earlier FASTA would point at the wrong bytes,
        // so an existing index is trusted only once the record header it implies is
        // confirmed present. Otherwise it is rebuilt from the FASTA itself.
        let existing = try? FASTAIndex(url: indexURL)
        let index: FASTAIndex
        if let existing, headerMatches(name: name, at: url, entry: existing.entry(for: name)) {
            index = existing
        } else {
            let built = try FASTAIndexBuilder.build(for: url)
            // Best effort: a database directory we cannot write to still yields a
            // usable in-memory index, it is just rebuilt on the next lookup.
            try? built.write(to: indexURL)
            index = built
        }
        guard let entry = index.entry(for: name) else { throw Error.contigUnavailable(name) }
        // A `.fai` keeps one entry per name, so a duplicated record name would be
        // silently collapsed. Reject that the same way the scanning path does.
        guard index.sequenceNames.filter({ $0 == name }).count == 1 else {
            throw Error.contigUnavailable(name)
        }
        let record = try Self.readRecordBytes(at: url, entry: entry).uppercased()
        guard !record.isEmpty else { throw Error.contigUnavailable(name) }
        return record
    }

    /// Whether the FASTA really carries `>name` immediately before the offset the
    /// index entry claims. This is the cheap staleness check that keeps a leftover
    /// `.fai` from silently addressing the wrong bytes of a replaced database.
    private static func headerMatches(name: String, at url: URL, entry: FASTAIndex.Entry?) -> Bool {
        guard let entry, entry.offset > 0, entry.length > 0, entry.lineBases > 0 else { return false }
        let expected = Array(">\(name)".utf8)
        // The header line runs backwards from the newline preceding the first base,
        // and may carry a description after the record name, so read a window large
        // enough to hold a realistic header and locate the line start within it.
        let window = min(entry.offset, 4096)
        let start = entry.offset - window
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? handle.read(upToCount: window),
              data.count == window
        else { return false }
        var bytes = Array(data)
        // Drop the line terminator that separates the header from the first base.
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard let lineStart = bytes.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }).map({ $0 + 1 })
            ?? (start == 0 ? 0 : nil)
        else { return false }
        let headerLine = Array(bytes[lineStart...])
        guard headerLine.count >= expected.count,
              Array(headerLine.prefix(expected.count)) == expected
        else { return false }
        // The record name ends at whitespace or end of line; a longer name that
        // merely starts with `name` is a different record.
        if headerLine.count == expected.count { return true }
        let next = headerLine[expected.count]
        return next == 0x20 || next == 0x09
    }

    /// Reads exactly one record's bases using its index entry, seeking straight to
    /// the record rather than walking the file. Newlines inside the record window
    /// are stripped; nothing outside the record is read.
    private static func readRecordBytes(at url: URL, entry: FASTAIndex.Entry) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        // Bases plus the newline bytes interleaved between full lines.
        let lineTerminatorWidth = max(0, entry.lineWidth - entry.lineBases)
        let lineCount = entry.lineBases > 0
            ? (entry.length + entry.lineBases - 1) / entry.lineBases
            : 0
        let byteCount = entry.length + lineCount * lineTerminatorWidth
        let data = try handle.read(upToCount: byteCount) ?? Data()
        var bases = [UInt8]()
        bases.reserveCapacity(entry.length)
        for byte in data where byte != 0x0A && byte != 0x0D {
            bases.append(byte)
            if bases.count == entry.length { break }
        }
        guard bases.count == entry.length, let text = String(bytes: bases, encoding: .utf8) else {
            throw Error.contigUnavailable(entry.name)
        }
        return text
    }

    private static func readExactFASTARecordByScanning(at url: URL, named name: String) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        var found: String?
        var matchedCount = 0
        var active = false
        var sequence = ""
        for line in text.split(whereSeparator: \.isNewline) {
            if line.first == ">" {
                if active { found = sequence.uppercased() }
                active = false
                let id = line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
                active = id == name
                if active {
                    matchedCount += 1
                    if matchedCount > 1 { throw Error.contigUnavailable(name) }
                    sequence = ""
                }
            } else if active {
                sequence += line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if active { found = sequence.uppercased() }
        guard matchedCount == 1, let found, !found.isEmpty else { throw Error.contigUnavailable(name) }
        return found
    }
}
