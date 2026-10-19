// BlastSubmitRoute.swift - A viewer's BLAST action on `lungfish-cli blast submit`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Why a viewer's BLAST action planned no search.
enum BlastSubmitPlanError: Error, LocalizedError, Equatable {
    /// No project is open, so the search has no project to keep its query and result in (2.12 lane 12.08,
    /// A65-NOPROJECT, DEC Q-U8). The action shows the `No Project Open` refusal and starts nothing.
    case noProject

    /// The title of the refusal, the one the classifier launch and import refusals show.
    static let noProjectTitle = "No Project Open"

    var errorDescription: String? {
        switch self {
        case .noProject: return "Open or create a project before running BLAST."
        }
    }
}

/// One viewer BLAST action planned onto `blast submit` (plan decision C1). The query file the viewer
/// writes under `<project>/.tmp/`, the result folder the leaf creates and the lineage the record
/// names are fixed before the row begins, so the row records the command the run executes.
///
/// The result folder sits under `blast-verifications/` of the result the sequences came from, as
/// `blast verify --result-dir` keeps its output (BIO 1), or of the project when the viewer has no
/// result folder. The query stays in `.tmp` for the project's sweep, and the leaf keeps its own copy
/// beside the record, so a copied command replays while the `.tmp` file is kept.
struct BlastSubmitPlan: Sendable {
    /// The folder under a result or project that holds the BLAST results of the viewers.
    static let resultsFolderName = "blast-verifications"

    let request: BlastSubmitRequest
    /// The query's bytes, the in-process request's `toMultiFASTA()` and a newline, so the leaf sends
    /// the bytes the in-process route sent (`BlastSiteRequestBytesPinTests`).
    let queryData: Data

    /// The argv after `lungfish-cli` that the run executes.
    var arguments: [String] { CLIBlastSubmitRunner.arguments(for: request) }

    /// The command the row records, the argv the run executes.
    var cliCommand: String {
        OperationCenter.buildCLICommand(subcommand: "blast submit", args: Array(arguments.dropFirst(2)))
    }

    /// Plans the search of `sequences`. `sourceResultURL` is the result folder they came from, and
    /// `projectURL` the project whose `.tmp` takes the query. Each lineage value is recorded only when
    /// the viewer has it. `outputParentURL` holds the result folder in place of the source result, for
    /// a source that is a file or a bundle. With no project it throws ``BlastSubmitPlanError/noProject``
    /// before it writes anything (DEC Q-U8), so no search lands where no row names it.
    static func make(
        sequences: [(id: String, sequence: String)],
        label: String,
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        outputParentURL: URL? = nil,
        taxId: Int? = nil,
        contig: String? = nil,
        sample: String? = nil,
        subsampleCount: Int? = nil,
        subsampleSeed: UInt64? = nil,
        entrezQuery: String? = nil,
        acceptedTaxIds: [Int] = [],
        acceptedNames: [String] = [],
        relatedTaxIds: [Int] = [],
        relatedNames: [String] = [],
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        guard !sequences.isEmpty else { throw BlastServiceError.noSequences }
        guard let projectURL else { throw BlastSubmitPlanError.noProject }
        let multiFASTA = BlastVerificationRequest(
            taxonName: label, taxId: taxId ?? 0, sequences: sequences, database: BlastDatabaseID.coreNT.rawValue
        ).toMultiFASTA()
        let stage = try ProjectTempDirectory.create(prefix: "blast-submit-", in: projectURL)
        let parent = outputParentURL ?? sourceResultURL ?? projectURL
        let output = parent.appendingPathComponent(resultsFolderName, isDirectory: true)
            .appendingPathComponent("\(folderStem(label))-\(stamp(date))-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let request = BlastSubmitRequest(
            queryURL: stage.appendingPathComponent(BlastSubmissionRecord.queryFileName),
            outputURL: output,
            label: label,
            taxId: taxId,
            contig: contig,
            sourceResultURL: sourceResultURL,
            sample: sample,
            subsampleCount: subsampleCount,
            subsampleSeed: subsampleSeed,
            entrezQuery: entrezQuery,
            acceptedTaxIds: acceptedTaxIds,
            acceptedNames: acceptedNames,
            relatedTaxIds: relatedTaxIds,
            relatedNames: relatedNames
        )
        return BlastSubmitPlan(request: request, queryData: Data((multiFASTA + "\n").utf8))
    }

    /// Plans the search the in-process route sent as `search`, with its sequences, label, taxon, Entrez
    /// filter and the clade and relatives its verdicts are judged against, so the leaf searches and judges
    /// as the site did (2.12 lane 12.08). The request's tax ID of 0, its "none", records no taxon.
    static func make(
        request search: BlastVerificationRequest,
        projectURL: URL?,
        sourceResultURL: URL? = nil,
        outputParentURL: URL? = nil,
        contig: String? = nil,
        sample: String? = nil,
        subsampleCount: Int? = nil,
        subsampleSeed: UInt64? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        try make(
            sequences: search.sequences, label: search.taxonName, projectURL: projectURL,
            sourceResultURL: sourceResultURL, outputParentURL: outputParentURL,
            taxId: search.taxId == 0 ? nil : search.taxId, contig: contig, sample: sample,
            subsampleCount: subsampleCount, subsampleSeed: subsampleSeed, entrezQuery: search.entrezQuery,
            acceptedTaxIds: search.acceptedTaxIds.sorted(), acceptedNames: search.acceptedTaxonNames,
            relatedTaxIds: search.relatedTaxIds.sorted(), relatedNames: search.relatedTaxonNames, date: date
        )
    }

    /// Writes the query through `DurableReplace`, hashing its bytes once (SWIFT 4, 5), runs the leaf
    /// through `runner` with each event handed to `onEvent`, and returns the verdicts its record holds
    /// once the record names that digest, so the drawer shows what the leaf searched. The record's URL comes with
    /// them, since the drawer keeps it for its table export (ARCH ruling T5 of lane 12.33).
    @concurrent func run(
        runner: CLIBlastSubmitRunner,
        onEvent: @escaping @Sendable (CLIEvent) -> Void
    ) async throws -> (result: BlastVerificationResult, recordURL: URL) {
        let stage = request.queryURL.deletingLastPathComponent()
        try DurableReplace.replace(queryData, named: request.queryURL.lastPathComponent, in: stage)
        let digest = SHA256.hash(data: queryData).map { String(format: "%02x", $0) }.joined()
        let completed = try await runner.run(arguments: arguments, onEvent: onEvent)
        let recordURL = URL(fileURLWithPath: completed.recordPath)
        let record = try BlastSubmissionRecord.load(recordURL)
        guard record.query.sha256 == digest else {
            throw CLIBlastSubmitRunnerError.queryDigestMismatch(expected: digest, found: record.query.sha256)
        }
        return (record.result, recordURL)
    }

    /// The phase a BLAST drawer shows for a progress message of the search.
    static func phase(forProgressMessage message: String) -> BlastJobPhase {
        let lowercased = message.lowercased()
        if lowercased.contains("waiting") { return .waiting }
        if lowercased.contains("parsing") { return .parsing }
        return .submitting
    }

    /// `label` as one folder-name word.
    static func folderStem(_ label: String) -> String {
        let stem = label
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return stem.isEmpty ? "blast" : String(stem.prefix(60))
    }

    /// `date` as the analyses folders write it, `yyyy-MM-dd'T'HH-mm-ss` in UTC.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: date)
    }
}
