// BlastSubmitRoute.swift - A viewer's BLAST action on `lungfish-cli blast submit`, and its hidden key
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The route of the viewers' BLAST read actions (Phase 2.11 lane A65 M2, plan decision C1, decisions C4
/// and C5 of Phase 2.10).
enum BlastReadActionRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A65, `BlastService.verify` in this process, kept for one release as the
    /// escape the hidden key names (C4), since the CLI route also saves the result and the query. It
    /// leaves in 2.12 with its key (K3).
    case legacy
    /// `lungfish-cli blast submit` on `CLIBlastSubmitRunner`.
    case cli
}

/// Reads the route from the defaults it is given, so a test passes its own suite and never touches the
/// user's defaults.
struct BlastReadActionRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for
    /// example `defaults write <app id> BlastReadActionRoute legacy`.
    static let defaultsKey = "BlastReadActionRoute"
    /// The route of a key that is unset or holds a value this reader does not know. Lane A65 M2 set it
    /// to `.cli` once side A against side C of each site's parity class held only declared differences.
    static let defaultRoute: BlastReadActionRoute = .cli

    let defaults: UserDefaults

    var route: BlastReadActionRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return BlastReadActionRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }

    /// The route a viewer's BLAST action takes now, read from the app's defaults.
    static var currentRoute: BlastReadActionRoute {
        BlastReadActionRouteSettings(defaults: .standard).route
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
    /// a source that is a file or a bundle.
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
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        guard !sequences.isEmpty else { throw BlastServiceError.noSequences }
        let multiFASTA = BlastVerificationRequest(
            taxonName: label, taxId: taxId ?? 0, sequences: sequences, database: BlastDatabaseID.coreNT.rawValue
        ).toMultiFASTA()
        let stage = try ProjectTempDirectory.create(prefix: "blast-submit-", in: projectURL)
        let parent = outputParentURL ?? sourceResultURL ?? projectURL ?? stage
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
            entrezQuery: entrezQuery
        )
        return BlastSubmitPlan(request: request, queryData: Data((multiFASTA + "\n").utf8))
    }

    /// Writes the query through `DurableReplace`, hashing its bytes once (SWIFT 4, 5), runs the leaf
    /// through `runner` with each event handed to `onEvent`, and returns the verdicts its record holds
    /// once the record names that digest, so the drawer shows what the leaf searched.
    @concurrent func run(
        runner: CLIBlastSubmitRunner,
        onEvent: @escaping @Sendable (CLIEvent) -> Void
    ) async throws -> BlastVerificationResult {
        let stage = request.queryURL.deletingLastPathComponent()
        try DurableReplace.replace(queryData, named: request.queryURL.lastPathComponent, in: stage)
        let digest = SHA256.hash(data: queryData).map { String(format: "%02x", $0) }.joined()
        let completed = try await runner.run(arguments: arguments, onEvent: onEvent)
        let record = try BlastSubmissionRecord.load(URL(fileURLWithPath: completed.recordPath))
        guard record.query.sha256 == digest else {
            throw CLIBlastSubmitRunnerError.queryDigestMismatch(expected: digest, found: record.query.sha256)
        }
        return record.result
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
