// VariantSampleMetadataMutationService.swift - Provenanced variant sample metadata edits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

struct VariantSampleMetadataMutationResult: Sendable, Equatable {
    let updatedCountsByDatabase: [String: Int]
    let provenanceURL: URL?

    var totalUpdated: Int {
        updatedCountsByDatabase.values.reduce(0, +)
    }
}

struct VariantSampleMetadataMutationRow: Sendable, Equatable {
    let name: String
    let sourceFile: String
    let metadata: [String: String]
}

struct VariantSampleMetadataMutationService {
    private let fileManager: FileManager
    private let writeProvenance: (ProvenanceEnvelope, URL) throws -> URL

    init(
        fileManager: FileManager = .default,
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(signingProvider: nil)
    ) {
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL in
            try provenanceWriter.write(envelope, to: bundleURL)
        }
    }

    init(
        fileManager: FileManager = .default,
        writeProvenance: @escaping (ProvenanceEnvelope, URL) throws -> URL
    ) {
        self.fileManager = fileManager
        self.writeProvenance = writeProvenance
    }

    func updateSampleMetadata(
        sampleName: String,
        sourceFile: String? = nil,
        metadata: [String: String],
        bundleURL: URL,
        targets rawTargets: [VariantSampleMetadataImportTarget]
    ) throws -> VariantSampleMetadataMutationResult {
        try performMutation(
            kind: .editSample(sampleName: sampleName, sourceFile: sourceFile, metadataKeys: Array(metadata.keys).sorted()),
            bundleURL: bundleURL,
            targets: rawTargets
        ) { database, _ in
            guard try sampleMatches(database: database, sampleName: sampleName, sourceFile: sourceFile) else {
                return 0
            }
            try database.updateSampleMetadata(name: sampleName, metadata: metadata)
            return 1
        }
    }

    func deleteMetadataField(
        fieldName: String,
        sampleRows: [VariantSampleMetadataMutationRow],
        bundleURL: URL,
        targets rawTargets: [VariantSampleMetadataImportTarget]
    ) throws -> VariantSampleMetadataMutationResult {
        try performMutation(
            kind: .deleteField(fieldName: fieldName, sampleCount: sampleRows.count),
            bundleURL: bundleURL,
            targets: rawTargets
        ) { database, _ in
            let dbSourceBySample = database.allSourceFiles()
            var updatedCount = 0
            for sample in sampleRows {
                guard let dbSource = dbSourceBySample[sample.name],
                      sourceFileMatches(dbSource, sample.sourceFile) else {
                    continue
                }
                var updated = sample.metadata
                updated.removeValue(forKey: fieldName)
                try database.updateSampleMetadata(name: sample.name, metadata: updated)
                updatedCount += 1
            }
            return updatedCount
        }
    }

    private func performMutation(
        kind: MutationKind,
        bundleURL rawBundleURL: URL,
        targets rawTargets: [VariantSampleMetadataImportTarget],
        mutate: (VariantDatabase, VariantSampleMetadataImportTarget) throws -> Int
    ) throws -> VariantSampleMetadataMutationResult {
        let bundleURL = rawBundleURL.standardizedFileURL
        let targets = uniqueTargets(rawTargets)
        guard !targets.isEmpty else {
            return VariantSampleMetadataMutationResult(updatedCountsByDatabase: [:], provenanceURL: nil)
        }

        let startedAt = Date()
        let backupDirectory = try makeBackupDirectory()
        defer { try? fileManager.removeItem(at: backupDirectory) }
        let backups = try targets.map { try backupDatabase($0.databaseURL, in: backupDirectory) }
        let databaseInputs = try targets.map {
            try ProvenanceFileDescriptor.file(url: $0.databaseURL, format: .unknown, role: .input)
        }
        let contextInputs = try contextInputDescriptors(bundleURL: bundleURL)

        do {
            var updatedCounts: [String: Int] = [:]
            for target in targets {
                let database = try VariantDatabase(url: target.databaseURL, readWrite: true)
                let count = try mutate(database, target)
                if count > 0 {
                    updatedCounts[target.databaseURL.path] = count
                }
            }

            guard !updatedCounts.isEmpty else {
                return VariantSampleMetadataMutationResult(updatedCountsByDatabase: [:], provenanceURL: nil)
            }

            let updatedTargets = targets.filter { updatedCounts[$0.databaseURL.path] != nil }
            let databaseOutputs = try updatedTargets.map {
                try ProvenanceFileDescriptor.file(url: $0.databaseURL, format: .unknown, role: .output)
            }
            let completedAt = Date()
            let envelope = try provenanceEnvelope(
                kind: kind,
                bundleURL: bundleURL,
                targets: updatedTargets,
                contextInputs: contextInputs,
                databaseInputs: databaseInputs.filter { input in
                    updatedCounts[input.path] != nil
                },
                databaseOutputs: databaseOutputs,
                updatedCounts: updatedCounts,
                startedAt: startedAt,
                completedAt: completedAt
            )
            let provenanceURL = try writeProvenance(envelope, bundleURL)
            return VariantSampleMetadataMutationResult(
                updatedCountsByDatabase: updatedCounts,
                provenanceURL: provenanceURL
            )
        } catch {
            restore(backups)
            throw error
        }
    }

    private func provenanceEnvelope(
        kind: MutationKind,
        bundleURL: URL,
        targets: [VariantSampleMetadataImportTarget],
        contextInputs: [ProvenanceFileDescriptor],
        databaseInputs: [ProvenanceFileDescriptor],
        databaseOutputs: [ProvenanceFileDescriptor],
        updatedCounts: [String: Int],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let argv = kind.argv(bundleURL: bundleURL)
        let targetOptions = Dictionary(
            uniqueKeysWithValues: targets.map {
                ($0.databaseURL.path, ParameterValue.string($0.trackName ?? $0.databaseURL.lastPathComponent))
            }
        )
        let updatedOptions = Dictionary(
            uniqueKeysWithValues: updatedCounts.map { path, count in
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
                "targets": .dictionary(targetOptions)
            ]) { _, rhs in rhs },
            defaults: [
                "rollbackOnFailure": .boolean(true),
                "provenanceRequired": .boolean(true)
            ],
            resolved: [
                "targetCount": .integer(targets.count),
                "totalUpdated": .integer(updatedCounts.values.reduce(0, +)),
                "updatedCounts": .dictionary(updatedOptions)
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)

        for contextURL in contextURLs(bundleURL: bundleURL) {
            builder = try builder.input(contextURL, format: formatForContextURL(contextURL), role: .input)
        }
        for target in targets {
            builder = try builder.output(target.databaseURL, format: .unknown, role: .output)
        }

        return try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
    }

    private func sampleMatches(
        database: VariantDatabase,
        sampleName: String,
        sourceFile: String?
    ) throws -> Bool {
        guard database.sampleNames().contains(sampleName) else {
            return false
        }
        guard let sourceFile else {
            return true
        }
        guard let dbSource = database.allSourceFiles()[sampleName] else {
            return false
        }
        return sourceFileMatches(dbSource, sourceFile)
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

    private func uniqueTargets(_ targets: [VariantSampleMetadataImportTarget]) -> [VariantSampleMetadataImportTarget] {
        var seen = Set<String>()
        var result: [VariantSampleMetadataImportTarget] = []
        for target in targets {
            guard seen.insert(target.databaseURL.path).inserted else { continue }
            result.append(target)
        }
        return result
    }

    private func makeBackupDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("variant-sample-metadata-mutation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func backupDatabase(_ databaseURL: URL, in backupDirectory: URL) throws -> VariantSampleMetadataDatabaseBackup {
        let backupURL = backupDirectory.appendingPathComponent(UUID().uuidString + "-" + databaseURL.lastPathComponent)
        try fileManager.copyItem(at: databaseURL, to: backupURL)
        return VariantSampleMetadataDatabaseBackup(originalURL: databaseURL, backupURL: backupURL)
    }

    private func restore(_ backups: [VariantSampleMetadataDatabaseBackup]) {
        for backup in backups {
            try? fileManager.removeItem(at: backup.originalURL)
            try? fileManager.copyItem(at: backup.backupURL, to: backup.originalURL)
        }
    }

    private func sourceFileMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
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

private enum MutationKind {
    case editSample(sampleName: String, sourceFile: String?, metadataKeys: [String])
    case deleteField(fieldName: String, sampleCount: Int)

    var workflowName: String {
        switch self {
        case .editSample:
            return "Variant sample metadata edit"
        case .deleteField:
            return "Variant sample metadata column deletion"
        }
    }

    func argv(bundleURL: URL) -> [String] {
        switch self {
        case .editSample(let sampleName, let sourceFile, _):
            var argv = [
                "lungfish-gui",
                "variant-sample-metadata",
                "edit",
                "--bundle", bundleURL.path,
                "--sample", sampleName
            ]
            if let sourceFile {
                argv.append(contentsOf: ["--source-file", sourceFile])
            }
            return argv
        case .deleteField(let fieldName, _):
            return [
                "lungfish-gui",
                "variant-sample-metadata",
                "delete-field",
                "--bundle", bundleURL.path,
                "--field", fieldName
            ]
        }
    }

    func explicitOptions(bundleURL: URL) -> [String: ParameterValue] {
        switch self {
        case .editSample(let sampleName, let sourceFile, let metadataKeys):
            var options: [String: ParameterValue] = [
                "bundle": .file(bundleURL),
                "sampleName": .string(sampleName),
                "metadataKeys": .array(metadataKeys.map { .string($0) })
            ]
            if let sourceFile {
                options["sourceFile"] = .string(sourceFile)
            }
            return options
        case .deleteField(let fieldName, let sampleCount):
            return [
                "bundle": .file(bundleURL),
                "fieldName": .string(fieldName),
                "candidateSampleCount": .integer(sampleCount)
            ]
        }
    }
}

private struct VariantSampleMetadataDatabaseBackup {
    let originalURL: URL
    let backupURL: URL
}
