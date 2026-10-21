// VariantDeletionMutationService.swift - Provenanced variant row deletion
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

package struct VariantDeletionMutationTarget: Sendable, Equatable {
    let trackId: String
    let databaseURL: URL
    let trackName: String?

    package init(trackId: String, databaseURL: URL, trackName: String? = nil) {
        self.trackId = trackId
        self.databaseURL = databaseURL.standardizedFileURL
        self.trackName = trackName
    }
}

package struct VariantDeletionMutationResult: Sendable, Equatable {
    let deletedCountsByTrack: [String: Int]
    let deletedCountsByDatabase: [String: Int]
    let provenanceURL: URL?

    package var totalDeleted: Int {
        deletedCountsByTrack.values.reduce(0, +)
    }
}

package struct VariantDeletionMutationService {
    /// The caller's tool name and kind (BIO-Q-A2 R2). The CLI passes `lungfish-cli` and `cli`, the app the recorded name and `gui`.
    private let toolName: String, toolKind: String
    private let fileManager: FileManager
    private let writeProvenance: (ProvenanceEnvelope, URL, VariantMutationPublication) throws -> URL

    package init(
        toolName: String,
        toolKind: String,
        fileManager: FileManager = .default,
        provenanceWriter: ProvenanceWriter = ProvenanceWriter()
    ) {
        self.toolName = toolName
        self.toolKind = toolKind
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL, publication in
            try provenanceWriter.observingPublications { try publication.observeProvenance($0) }
                .write(envelope, to: bundleURL)
        }
    }

    package init(
        toolName: String,
        toolKind: String,
        fileManager: FileManager = .default,
        writeProvenance: @escaping (ProvenanceEnvelope, URL) throws -> URL
    ) {
        self.toolName = toolName
        self.toolKind = toolKind
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL, _ in try writeProvenance(envelope, bundleURL) }
    }

    /// The `lungfish-cli` argv, from the `variants delete` words on, that deletes every variant of
    /// every variant track of the bundle, as ``deleteAllVariants(bundleURL:targets:invocationArgv:)``
    /// does. The drawer's row records it and the command records it when it runs inside another
    /// process. The builder touches no state, so any isolation can call it.
    package static func deleteAllArguments(bundleURL: URL) -> [String] {
        ["variants", "delete", bundleURL.path, "--all"]
    }

    /// The `lungfish-cli` argv, from the `variants delete` words on, that deletes the selected
    /// variants, as ``deleteVariants(idsByTrack:bundleURL:targets:invocationArgv:)`` does. Each
    /// selected row travels with its track, as `--variant-id=<track-id>:<row-id>`, tracks in name
    /// order and row IDs ascending, so one command reproduces any selection. The value is joined to
    /// its option, so a hyphen-leading track ID replays.
    package static func deleteSelectedArguments(bundleURL: URL, idsByTrack: [String: [Int64]]) -> [String] {
        var arguments = ["variants", "delete", bundleURL.path]
        for trackId in idsByTrack.keys.sorted() {
            for id in Set(idsByTrack[trackId] ?? []).sorted() {
                arguments.append("--variant-id=\(trackId):\(id)")
            }
        }
        return arguments
    }

    /// The selection that `--variant-id` values name, by track. A value is `<track-id>:<row-id>`
    /// and splits on its last colon, since the row ID is an integer.
    package static func selection(fromVariantIDs values: [String]) throws -> [String: [Int64]] {
        var idsByTrack: [String: [Int64]] = [:]
        for value in values {
            guard let colon = value.lastIndex(of: ":"), colon != value.startIndex,
                  let rowID = Int64(value[value.index(after: colon)...]), rowID >= 0 else {
                throw NSError(
                    domain: "VariantDeletionMutationService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "'\(value)' is not <track-id>:<row-id>. Pass the track a variant belongs to, a colon and its row ID."]
                )
            }
            idsByTrack[String(value[..<colon]), default: []].append(rowID)
        }
        return idsByTrack.mapValues { Array(Set($0)).sorted() }
    }

    /// Deletes the variants `rawIDsByTrack` names from their tracks' databases and records the
    /// step, which names every row that went. `invocationArgv` is the command that made the edit,
    /// such as `lungfish-cli variants delete`. With none it records the `lungfish-gui` form, as it
    /// always has.
    package func deleteVariants(
        idsByTrack rawIDsByTrack: [String: [Int64]],
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantDeletionMutationTarget],
        invocationArgv: [String]? = nil
    ) throws -> VariantDeletionMutationResult {
        let idsByTrack = rawIDsByTrack.reduce(into: [String: [Int64]]()) { partialResult, entry in
            let ids = Array(Set(entry.value)).sorted()
            guard !ids.isEmpty else { return }
            partialResult[entry.key] = ids
        }
        let targets = uniqueTargets(rawTargets).filter { idsByTrack[$0.trackId]?.isEmpty == false }
        return try performMutation(
            kind: .selected(idsByTrack: idsByTrack),
            bundleURL: rawBundleURL,
            targets: targets,
            invocationArgv: invocationArgv
        ) { database, target in
            try database.deleteVariants(ids: idsByTrack[target.trackId] ?? [])
        }
    }

    /// Deletes every variant of the databases `rawTargets` name and records the step. See
    /// ``deleteVariants(idsByTrack:bundleURL:targets:invocationArgv:)`` for `invocationArgv`.
    package func deleteAllVariants(
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantDeletionMutationTarget],
        invocationArgv: [String]? = nil
    ) throws -> VariantDeletionMutationResult {
        try performMutation(
            kind: .all,
            bundleURL: rawBundleURL,
            targets: uniqueTargets(rawTargets),
            invocationArgv: invocationArgv
        ) { database, _ in
            try database.deleteAllVariants()
        }
    }

    private func performMutation(
        kind: DeletionKind,
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantDeletionMutationTarget],
        invocationArgv: [String]?,
        mutate: (VariantDatabase, VariantDeletionMutationTarget) throws -> Int
    ) throws -> VariantDeletionMutationResult {
        let bundleURL = rawBundleURL.standardizedFileURL
        let targets = uniqueTargets(rawTargets)
        guard !targets.isEmpty else {
            return VariantDeletionMutationResult(
                deletedCountsByTrack: [:],
                deletedCountsByDatabase: [:],
                provenanceURL: nil
            )
        }

        let runClock = ProvenanceRunClock()
        let publication = try VariantMutationPublication(databaseURLs: targets.map(\.databaseURL),
            bundleURL: bundleURL, fileManager: fileManager)
        do {
            let databaseInputs = try targets.map { try publication.inputDescriptor(for: $0.databaseURL) }
            let contextInputs = try contextInputDescriptors(bundleURL: bundleURL)
            var deletedCountsByTrack: [String: Int] = [:]
            var deletedCountsByDatabase: [String: Int] = [:]
            for target in targets {
                let database = publication.database(at: target.databaseURL)
                let deleted = try mutate(database, target)
                guard deleted > 0 else { continue }
                deletedCountsByTrack[target.trackId, default: 0] += deleted
                deletedCountsByDatabase[target.databaseURL.path, default: 0] += deleted
            }

            guard !deletedCountsByDatabase.isEmpty else {
                publication.commit(retainConsumedInputs: false)
                return VariantDeletionMutationResult(
                    deletedCountsByTrack: [:],
                    deletedCountsByDatabase: [:],
                    provenanceURL: nil
                )
            }

            try publication.checkpoint()
            let updatedTargets = targets.filter { deletedCountsByDatabase[$0.databaseURL.path] != nil }
            let databaseOutputs = try updatedTargets.map {
                try ProvenanceFileDescriptor.file(url: $0.databaseURL, format: .unknown, role: .output)
            }
            let completedAt = runClock.now
            let envelope = try provenanceEnvelope(
                kind: kind,
                invocationArgv: invocationArgv,
                bundleURL: bundleURL,
                targets: updatedTargets,
                contextInputs: contextInputs,
                databaseInputs: databaseInputs.filter { deletedCountsByDatabase[$0.originPath ?? $0.path] != nil },
                databaseOutputs: databaseOutputs,
                deletedCountsByTrack: deletedCountsByTrack,
                deletedCountsByDatabase: deletedCountsByDatabase,
                startedAt: runClock.startedAt,
                completedAt: completedAt
            )
            let provenanceURL = try writeProvenance(envelope, bundleURL, publication)
            publication.commit()
            return VariantDeletionMutationResult(
                deletedCountsByTrack: deletedCountsByTrack,
                deletedCountsByDatabase: deletedCountsByDatabase,
                provenanceURL: provenanceURL
            )
        } catch {
            try publication.rollback(after: error)
        }
    }

    private func provenanceEnvelope(
        kind: DeletionKind,
        invocationArgv: [String]?,
        bundleURL: URL,
        targets: [VariantDeletionMutationTarget],
        contextInputs: [ProvenanceFileDescriptor],
        databaseInputs: [ProvenanceFileDescriptor],
        databaseOutputs: [ProvenanceFileDescriptor],
        deletedCountsByTrack: [String: Int],
        deletedCountsByDatabase: [String: Int],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let argv = invocationArgv ?? kind.argv(bundleURL: bundleURL)
        let trackOptions = Dictionary(
            uniqueKeysWithValues: targets.map {
                ($0.trackId, ParameterValue.string($0.trackName ?? $0.trackId))
            }
        )
        let deletedTrackOptions = Dictionary(
            uniqueKeysWithValues: deletedCountsByTrack.map { trackId, count in
                (trackId, ParameterValue.integer(count))
            }
        )
        let deletedDatabaseOptions = Dictionary(
            uniqueKeysWithValues: deletedCountsByDatabase.map { path, count in
                (path, ParameterValue.integer(count))
            }
        )
        let step = ProvenanceStep(
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: contextInputs + databaseInputs,
            outputs: databaseOutputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )

        var builder = ProvenanceRunBuilder(
            workflowName: kind.workflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            toolKind: toolKind
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(argv.map(shellEscape).joined(separator: " "))
        .options(
            explicit: kind.explicitOptions(bundleURL: bundleURL).merging([
                "tracks": .dictionary(trackOptions)
            ]) { _, rhs in rhs },
            defaults: [
                "rollbackOnFailure": .boolean(true),
                "provenanceRequired": .boolean(true)
            ],
            resolved: [
                "targetCount": .integer(targets.count),
                "totalDeleted": .integer(deletedCountsByTrack.values.reduce(0, +)),
                "deletedCountsByTrack": .dictionary(deletedTrackOptions),
                "deletedCountsByDatabase": .dictionary(deletedDatabaseOptions)
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)

        for input in databaseInputs { builder = try builder.consumedInputSnapshot(input) }
        for input in contextInputs { builder = try builder.consumedInputSnapshot(input) }
        for target in targets {
            builder = try builder.output(target.databaseURL, format: .unknown, role: .output)
        }

        return try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
    }

    private func contextInputDescriptors(bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        try contextURLs(bundleURL: bundleURL).map {
            try ProvenanceFileDescriptor.file(url: $0, format: formatForContextURL($0), role: .input)
        }
    }

    private func contextURLs(bundleURL: URL) -> [URL] {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return []
        }
        return [manifestURL.standardizedFileURL]
    }

    private func formatForContextURL(_ url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        default:
            return .unknown
        }
    }

    private func uniqueTargets(_ targets: [VariantDeletionMutationTarget]) -> [VariantDeletionMutationTarget] {
        var seen = Set<String>()
        var result: [VariantDeletionMutationTarget] = []
        for target in targets {
            let key = "\(target.trackId)\u{0}\(target.databaseURL.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(target)
        }
        return result
    }

    private func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-:=,+"))
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum DeletionKind {
    case selected(idsByTrack: [String: [Int64]])
    case all

    var workflowName: String {
        "Variant deletion"
    }

    func argv(bundleURL: URL) -> [String] {
        var argv = [
            "lungfish-gui",
            "variant",
            "delete",
            "--bundle", bundleURL.path,
            "--scope", scope
        ]
        switch self {
        case .selected(let idsByTrack):
            for trackId in idsByTrack.keys.sorted() {
                argv.append(contentsOf: ["--track-id", trackId])
                argv.append(contentsOf: ["--variant-ids", (idsByTrack[trackId] ?? []).map(String.init).joined(separator: ",")])
            }
        case .all:
            break
        }
        return argv
    }

    func explicitOptions(bundleURL: URL) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "scope": .string(scope)
        ]
        if case .selected(let idsByTrack) = self {
            let idOptions = Dictionary(
                uniqueKeysWithValues: idsByTrack.map { trackId, ids in
                    (trackId, ParameterValue.array(ids.sorted().map { .integer(Int($0)) }))
                }
            )
            options["variantIdsByTrack"] = .dictionary(idOptions)
        }
        return options
    }

    private var scope: String {
        switch self {
        case .selected:
            return "selected"
        case .all:
            return "all"
        }
    }
}
