// VariantDeletionMutationService.swift - Provenanced variant row deletion
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

struct VariantDeletionMutationTarget: Sendable, Equatable {
    let trackId: String
    let databaseURL: URL
    let trackName: String?

    init(trackId: String, databaseURL: URL, trackName: String? = nil) {
        self.trackId = trackId
        self.databaseURL = databaseURL.standardizedFileURL
        self.trackName = trackName
    }
}

struct VariantDeletionMutationResult: Sendable, Equatable {
    let deletedCountsByTrack: [String: Int]
    let deletedCountsByDatabase: [String: Int]
    let provenanceURL: URL?

    var totalDeleted: Int {
        deletedCountsByTrack.values.reduce(0, +)
    }
}

struct VariantDeletionMutationService {
    private let fileManager: FileManager
    private let writeProvenance: (ProvenanceEnvelope, URL, VariantMutationPublication) throws -> URL

    init(
        fileManager: FileManager = .default,
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(signingProvider: nil)
    ) {
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL, publication in
            try provenanceWriter.observingPublications { try publication.observeProvenance($0) }
                .write(envelope, to: bundleURL)
        }
    }

    init(
        fileManager: FileManager = .default,
        writeProvenance: @escaping (ProvenanceEnvelope, URL) throws -> URL
    ) {
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL, _ in try writeProvenance(envelope, bundleURL) }
    }

    func deleteVariants(
        idsByTrack rawIDsByTrack: [String: [Int64]],
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantDeletionMutationTarget]
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
            targets: targets
        ) { database, target in
            try database.deleteVariants(ids: idsByTrack[target.trackId] ?? [])
        }
    }

    func deleteAllVariants(
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantDeletionMutationTarget]
    ) throws -> VariantDeletionMutationResult {
        try performMutation(
            kind: .all,
            bundleURL: rawBundleURL,
            targets: uniqueTargets(rawTargets)
        ) { database, _ in
            try database.deleteAllVariants()
        }
    }

    private func performMutation(
        kind: DeletionKind,
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantDeletionMutationTarget],
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

        let startedAt = Date()
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
            let completedAt = Date()
            let envelope = try provenanceEnvelope(
                kind: kind,
                bundleURL: bundleURL,
                targets: updatedTargets,
                contextInputs: contextInputs,
                databaseInputs: databaseInputs.filter { deletedCountsByDatabase[$0.originPath ?? $0.path] != nil },
                databaseOutputs: databaseOutputs,
                deletedCountsByTrack: deletedCountsByTrack,
                deletedCountsByDatabase: deletedCountsByDatabase,
                startedAt: startedAt,
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
        let argv = kind.argv(bundleURL: bundleURL)
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
            toolName: "Lungfish Genome Explorer",
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
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion
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
