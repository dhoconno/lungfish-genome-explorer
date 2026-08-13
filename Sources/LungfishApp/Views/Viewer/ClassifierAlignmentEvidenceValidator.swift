// ClassifierAlignmentEvidenceValidator.swift - Read-only validation for detached classifier BAM evidence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
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

    init(
        headerReader: HeaderReader? = nil,
        indexQuery: IndexQuery? = nil,
        referenceReader: @escaping ReferenceReader = { url, name in
            try Self.readExactFASTARecord(at: url, named: name)
        },
        fileManager: FileManager = .default
    ) {
        self.headerReader = headerReader
        self.indexQuery = indexQuery
        self.referenceReader = referenceReader
        self.fileManager = fileManager
    }

    func validate(_ request: ClassifierAlignmentEvidenceRequest) async throws -> Result {
        try validateContainment(of: request.bamURL, in: request.resultIdentity.finalResultURL)
        try validateContainment(of: request.index.url, in: request.resultIdentity.finalResultURL)
        if let reference = request.referenceCandidate {
            try validateContainment(of: reference.fastaURL, in: request.resultIdentity.finalResultURL)
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
        let root = finalResultURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = resolved.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else {
            throw Error.evidenceOutsideFinalResult(candidate)
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

    private static func snapshot(_ url: URL) throws -> ClassifierAlignmentEvidenceFileSnapshot {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        return .init(size: Int64(values.fileSize ?? 0), sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func readExactFASTARecord(at url: URL, named name: String) throws -> String {
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
