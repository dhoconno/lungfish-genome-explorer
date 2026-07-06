// VariantSampleMetadataImportService.swift - Provenanced variant sample metadata imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

struct VariantSampleMetadataImportTarget: Sendable, Equatable {
    let databaseURL: URL
    let trackName: String?

    init(databaseURL: URL, trackName: String? = nil) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.trackName = trackName
    }
}

struct VariantSampleMetadataImportResult: Sendable, Equatable {
    let updatedCountsByDatabase: [String: Int]
    let provenanceURL: URL

    var totalUpdated: Int {
        updatedCountsByDatabase.values.reduce(0, +)
    }

    var updatedDatabaseCount: Int {
        updatedCountsByDatabase.count
    }
}

struct VariantSampleMetadataImportService {
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

    func importMetadata(
        from metadataURL: URL,
        format: MetadataFormat,
        bundleURL: URL,
        targets rawTargets: [VariantSampleMetadataImportTarget]
    ) throws -> VariantSampleMetadataImportResult {
        let metadataURL = metadataURL.standardizedFileURL
        let bundleURL = bundleURL.standardizedFileURL
        let targets = uniqueTargets(rawTargets)
        guard !targets.isEmpty else {
            throw NSError(
                domain: "VariantSampleMetadataImportService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No variant databases were available for sample metadata import."]
            )
        }

        let startedAt = Date()
        let backupDirectory = try makeBackupDirectory()
        defer { try? fileManager.removeItem(at: backupDirectory) }
        let backups = try targets.map { try backupDatabase($0.databaseURL, in: backupDirectory) }

        let metadataInput = try ProvenanceFileDescriptor.file(url: metadataURL, format: .text, role: .input)
        let contextInputs = try contextInputDescriptors(bundleURL: bundleURL, targets: targets)
        let databaseInputs = try targets.map {
            try ProvenanceFileDescriptor.file(url: $0.databaseURL, format: .unknown, role: .input)
        }

        do {
            var updatedCounts: [String: Int] = [:]
            for target in targets {
                let database = try VariantDatabase(url: target.databaseURL, readWrite: true)
                let count = try database.importSampleMetadata(from: metadataURL, format: format)
                updatedCounts[target.databaseURL.path] = count
            }

            let databaseOutputs = try targets.map {
                try ProvenanceFileDescriptor.file(url: $0.databaseURL, format: .unknown, role: .output)
            }
            let completedAt = Date()
            let envelope = try provenanceEnvelope(
                metadataURL: metadataURL,
                format: format,
                bundleURL: bundleURL,
                targets: targets,
                metadataInput: metadataInput,
                contextInputs: contextInputs,
                databaseInputs: databaseInputs,
                databaseOutputs: databaseOutputs,
                updatedCounts: updatedCounts,
                startedAt: startedAt,
                completedAt: completedAt
            )
            let provenanceURL = try writeProvenance(envelope, bundleURL)
            return VariantSampleMetadataImportResult(
                updatedCountsByDatabase: updatedCounts,
                provenanceURL: provenanceURL
            )
        } catch {
            restore(backups)
            throw error
        }
    }

    private func provenanceEnvelope(
        metadataURL: URL,
        format: MetadataFormat,
        bundleURL: URL,
        targets: [VariantSampleMetadataImportTarget],
        metadataInput: ProvenanceFileDescriptor,
        contextInputs: [ProvenanceFileDescriptor],
        databaseInputs: [ProvenanceFileDescriptor],
        databaseOutputs: [ProvenanceFileDescriptor],
        updatedCounts: [String: Int],
        startedAt: Date,
        completedAt: Date
    ) throws -> ProvenanceEnvelope {
        let argv = [
            "lungfish-gui",
            "variant-sample-metadata",
            "import",
            "--metadata", metadataURL.path,
            "--bundle", bundleURL.path,
            "--format", format.rawValue
        ]
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
            inputs: [metadataInput] + contextInputs + databaseInputs,
            outputs: databaseOutputs,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )

        var builder = ProvenanceRunBuilder(
            workflowName: "Variant sample metadata import",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(argv.map(shellEscape).joined(separator: " "))
        .options(
            explicit: [
                "metadata": .file(metadataURL),
                "bundle": .file(bundleURL),
                "format": .string(format.rawValue),
                "targets": .dictionary(targetOptions)
            ],
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

        builder = try builder.input(metadataURL, format: .text, role: .input)
        for contextURL in contextURLs(bundleURL: bundleURL, targets: targets) {
            builder = try builder.input(contextURL, format: formatForContextURL(contextURL), role: .input)
        }
        for target in targets {
            builder = try builder.output(target.databaseURL, format: .unknown, role: .output)
        }

        return try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: completedAt
        )
    }

    private func contextInputDescriptors(
        bundleURL: URL,
        targets: [VariantSampleMetadataImportTarget]
    ) throws -> [ProvenanceFileDescriptor] {
        try contextURLs(bundleURL: bundleURL, targets: targets).map {
            try ProvenanceFileDescriptor.file(url: $0, format: formatForContextURL($0), role: .input)
        }
    }

    private func contextURLs(bundleURL: URL, targets: [VariantSampleMetadataImportTarget]) -> [URL] {
        var urls: [URL] = []
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        if fileManager.fileExists(atPath: manifestURL.path) {
            urls.append(manifestURL)
        }
        for target in targets {
            let indexURL = URL(fileURLWithPath: target.databaseURL.path + "-shm")
            if fileManager.fileExists(atPath: indexURL.path) {
                urls.append(indexURL)
            }
        }
        return uniqueURLs(urls)
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
            let key = target.databaseURL.path
            guard seen.insert(key).inserted else { continue }
            result.append(target)
        }
        return result
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            guard seen.insert(url.path).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private func makeBackupDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("variant-sample-metadata-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func backupDatabase(_ databaseURL: URL, in backupDirectory: URL) throws -> DatabaseBackup {
        let backupURL = backupDirectory.appendingPathComponent(UUID().uuidString + "-" + databaseURL.lastPathComponent)
        try fileManager.copyItem(at: databaseURL, to: backupURL)
        let sidecarBackups = try databaseSidecarSuffixes.compactMap { suffix -> DatabaseSidecarBackup? in
            let sourceURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                return nil
            }
            let copiedURL = backupDirectory.appendingPathComponent(UUID().uuidString + "-" + databaseURL.lastPathComponent + suffix)
            try fileManager.copyItem(at: sourceURL, to: copiedURL)
            return DatabaseSidecarBackup(originalURL: sourceURL, backupURL: copiedURL)
        }
        return DatabaseBackup(originalURL: databaseURL, backupURL: backupURL, sidecars: sidecarBackups)
    }

    private func restore(_ backups: [DatabaseBackup]) {
        for backup in backups {
            try? fileManager.removeItem(at: backup.originalURL)
            try? fileManager.copyItem(at: backup.backupURL, to: backup.originalURL)
            for suffix in databaseSidecarSuffixes {
                try? fileManager.removeItem(at: URL(fileURLWithPath: backup.originalURL.path + suffix))
            }
            for sidecar in backup.sidecars {
                try? fileManager.copyItem(at: sidecar.backupURL, to: sidecar.originalURL)
            }
        }
    }

    private var databaseSidecarSuffixes: [String] {
        ["-wal", "-shm"]
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

private struct DatabaseBackup {
    let originalURL: URL
    let backupURL: URL
    let sidecars: [DatabaseSidecarBackup]
}

private struct DatabaseSidecarBackup {
    let originalURL: URL
    let backupURL: URL
}
