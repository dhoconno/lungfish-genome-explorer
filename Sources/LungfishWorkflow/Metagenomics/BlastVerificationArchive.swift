// BlastVerificationArchive.swift - BLAST verifications saved beside a classifier result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let archiveLogger = Logger(subsystem: LogSubsystem.workflow, category: "BlastVerificationArchive")

/// Saves and restores BLAST verifications inside a classifier result folder.
///
/// ## Layout
///
/// ```
/// <result>/blast-verifications/<taxid>-<yyyyMMddTHHmmssSSSZ>.json
/// <result>/blast-verifications/<taxid>-<yyyyMMddTHHmmssSSSZ>.json.lungfish-provenance.json
/// ```
///
/// Each JSON file is a ``Record``: the ``BlastVerificationResult`` as the
/// drawer showed it plus the request settings that produced it. The
/// timestamp is the completion time in UTC and sorts lexically, so the newest
/// verification of a taxon is the last file with that taxid prefix.
///
/// ## Adopting it in another viewport
///
/// A viewport that knows its result folder calls ``save(_:in:sourceURLs:argv:startedAt:)``
/// after `BlastService.verify` returns, and ``latest(forTaxId:in:)`` (or
/// ``entries(in:taxId:)`` to offer a list) when a row is selected. Viewports
/// keyed by something other than an NCBI taxid (a contig or accession) can
/// use the `taxId` the result already carries, or a synthetic key in
/// `BlastVerificationResult.taxId`, since the file name only needs a stable
/// integer per row.
public enum BlastVerificationArchive {

    /// Folder inside a result directory that holds saved verifications.
    public static let directoryName = "blast-verifications"

    /// Schema version written into every record.
    public static let schemaVersion = 1

    // MARK: - Models

    /// The request settings saved with a verification.
    public struct RequestSummary: Codable, Sendable, Equatable {
        public var program: String
        public var database: String
        public var entrezQuery: String?
        public var eValueThreshold: Double
        public var maxTargetSeqs: Int
        public var extraArgs: String
        public var submittedReadCount: Int
        public var taxonomy: BlastTaxonomyContext

        public init(
            program: String,
            database: String,
            entrezQuery: String?,
            eValueThreshold: Double,
            maxTargetSeqs: Int,
            extraArgs: String,
            submittedReadCount: Int,
            taxonomy: BlastTaxonomyContext
        ) {
            self.program = program
            self.database = database
            self.entrezQuery = entrezQuery
            self.eValueThreshold = eValueThreshold
            self.maxTargetSeqs = maxTargetSeqs
            self.extraArgs = extraArgs
            self.submittedReadCount = submittedReadCount
            self.taxonomy = taxonomy
        }

        public init(_ request: BlastVerificationRequest) {
            self.init(
                program: request.program,
                database: request.database,
                entrezQuery: request.entrezQuery,
                eValueThreshold: request.eValueThreshold,
                maxTargetSeqs: request.maxTargetSeqs,
                extraArgs: request.extraArgs,
                submittedReadCount: request.sequences.count,
                taxonomy: request.taxonomyContext
            )
        }
    }

    /// One saved verification.
    public struct Record: Codable, Sendable {
        public var schemaVersion: Int
        public var savedAt: Date
        public var request: RequestSummary?
        public var result: BlastVerificationResult

        public init(
            schemaVersion: Int = BlastVerificationArchive.schemaVersion,
            savedAt: Date,
            request: RequestSummary?,
            result: BlastVerificationResult
        ) {
            self.schemaVersion = schemaVersion
            self.savedAt = savedAt
            self.request = request
            self.result = result
        }
    }

    /// A saved verification file, found without decoding it.
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let taxId: Int
        public let timestamp: String
    }

    // MARK: - Paths

    /// `<result>/blast-verifications`.
    public static func directoryURL(for resultDirectory: URL) -> URL {
        resultDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `<taxid>-<yyyyMMddTHHmmssSSSZ>.json` for a verification completed at `date`.
    public static func fileName(taxId: Int, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return "\(taxId)-\(formatter.string(from: date)).json"
    }

    // MARK: - Save

    /// Writes `result` into `<resultDirectory>/blast-verifications/` with a
    /// provenance sidecar, and returns the record's URL.
    ///
    /// - Parameters:
    ///   - result: The verification to save.
    ///   - request: The request that produced it.
    ///   - resultDirectory: The classifier result folder.
    ///   - sourceURLs: Small inputs to fingerprint in the provenance sidecar,
    ///     such as the classification report. Pass large read files through
    ///     `argv` only, because every source is hashed.
    ///   - argv: The equivalent `lungfish blast verify` command line.
    ///   - startedAt: When the verification started.
    @discardableResult
    public static func save(
        _ result: BlastVerificationResult,
        request: BlastVerificationRequest?,
        in resultDirectory: URL,
        sourceURLs: [URL] = [],
        argv: [String] = [],
        startedAt: Date? = nil
    ) throws -> URL {
        // The provenance transaction compares paths, so a relative URL (a
        // CLI `--result-dir kraken2-...`) must become absolute first.
        let resultDirectory = resultDirectory.absoluteURL.standardizedFileURL
        let directory = directoryURL(for: resultDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let completedAt = result.completedAt ?? Date()
        var outputURL = directory.appendingPathComponent(fileName(taxId: result.taxId, date: completedAt))
        var suffix = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent(
                fileName(taxId: result.taxId, date: completedAt.addingTimeInterval(Double(suffix) / 1000))
            )
            suffix += 1
        }

        let record = Record(
            savedAt: Date(),
            request: request.map(RequestSummary.init),
            result: result
        )
        let data = try encoder.encode(record)
        let existingSources = sourceURLs.filter { FileManager.default.fileExists(atPath: $0.path) }

        var explicit: [String: ParameterValue] = [
            "taxId": .integer(result.taxId),
            "taxonName": .string(result.taxonName),
            "rid": .string(result.rid),
            "program": .string(result.blastProgram),
            "database": .string(result.database),
            "outputPath": .file(outputURL),
        ]
        if let request {
            explicit["readCount"] = .integer(request.sequences.count)
            explicit["eValueThreshold"] = .number(request.eValueThreshold)
            explicit["maxTargetSeqs"] = .integer(request.maxTargetSeqs)
            if !request.extraArgs.isEmpty { explicit["extraArgs"] = .string(request.extraArgs) }
        }

        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish blast verify",
            sourceURLs: existingSources,
            outputURL: outputURL,
            outputFormat: .json,
            argv: argv.isEmpty ? [CLICommandIdentity.executableName, "blast", "verify", "--taxid", "\(result.taxId)"] : argv,
            explicitOptions: explicit,
            resolved: [
                "supportingCount": .integer(result.supportingCount),
                "contradictingCount": .integer(result.contradictingCount),
                "errorCount": .integer(result.errorCount),
                "totalReads": .integer(result.totalReads),
            ],
            startedAt: startedAt ?? result.submittedAt,
            completedAt: completedAt
        )) { staged in
            try data.write(to: staged, options: .atomic)
        }
        archiveLogger.info("Saved BLAST verification for txid\(result.taxId, privacy: .public) to \(outputURL.path, privacy: .public)")
        return outputURL
    }

    // MARK: - Read

    /// Saved verifications in `resultDirectory`, newest first, optionally
    /// only those for `taxId`.
    public static func entries(in resultDirectory: URL, taxId: Int? = nil) -> [Entry] {
        let directory = directoryURL(for: resultDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let entries: [Entry] = names.compactMap { name in
            guard name.hasSuffix(".json"), !name.hasSuffix(".lungfish-provenance.json") else { return nil }
            let stem = String(name.dropLast(".json".count))
            guard let dash = stem.firstIndex(of: "-"),
                  let id = Int(stem[stem.startIndex..<dash]) else { return nil }
            if let taxId, id != taxId { return nil }
            return Entry(
                url: directory.appendingPathComponent(name),
                taxId: id,
                timestamp: String(stem[stem.index(after: dash)...])
            )
        }
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Decodes a saved verification.
    public static func load(_ url: URL) throws -> Record {
        try decoder.decode(Record.self, from: Data(contentsOf: url))
    }

    /// The newest readable verification of `taxId` in `resultDirectory`.
    public static func latest(forTaxId taxId: Int, in resultDirectory: URL) -> Record? {
        for entry in entries(in: resultDirectory, taxId: taxId) {
            do {
                return try load(entry.url)
            } catch {
                archiveLogger.warning("Skipping unreadable BLAST verification \(entry.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Coding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
