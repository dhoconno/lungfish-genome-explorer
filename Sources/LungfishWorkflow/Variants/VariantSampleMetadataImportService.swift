// VariantSampleMetadataImportService.swift - Provenanced variant sample metadata imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

package struct VariantSampleMetadataImportTarget: Sendable, Equatable {
    package let databaseURL: URL
    package let trackName: String?

    package init(databaseURL: URL, trackName: String? = nil) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.trackName = trackName
    }
}

package struct VariantSampleMetadataImportResult: Sendable, Equatable {
    let updatedCountsByDatabase: [String: Int]
    let provenanceURL: URL

    package var totalUpdated: Int {
        updatedCountsByDatabase.values.reduce(0, +)
    }

    package var updatedDatabaseCount: Int {
        updatedCountsByDatabase.count
    }
}

package struct VariantSampleMetadataImportService {
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

    /// The `lungfish-cli` argv, from the `variants import-sample-metadata` words on, that imports
    /// `metadataURL` as ``importMetadata(from:format:bundleURL:targets:invocationArgv:shouldCancel:)``
    /// does. The drawer's row records it and launches it, and the command records it when it runs
    /// inside another process. The format is always named, so the command reads the file as the
    /// drawer did whatever its extension. The builder touches no state, so any isolation can call it.
    package static func importMetadataArguments(metadataURL: URL, format: MetadataFormat, bundleURL: URL) -> [String] {
        ["variants", "import-sample-metadata", bundleURL.path, metadataURL.path, "--metadata-format", format.rawValue]
    }

    /// Imports the sample metadata of `metadataURL` into every target database and records the
    /// step. `invocationArgv` is the command that made the edit, such as `lungfish-cli variants
    /// import-sample-metadata`. With none it starts the argv with the caller's tool name.
    ///
    /// `shouldCancel` is asked after the publication is built, before each chunk of the copy's
    /// hash, before each target's import and before the record is written. A true answer throws
    /// `CancellationError` there, and the rollback leaves every database and record as it was.
    package func importMetadata(
        from metadataURL: URL,
        format: MetadataFormat,
        bundleURL: URL,
        targets rawTargets: [VariantSampleMetadataImportTarget],
        invocationArgv: [String]? = nil,
        shouldCancel: () -> Bool = { false }
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

        let runClock = ProvenanceRunClock()
        let publication = try VariantMutationPublication(databaseURLs: targets.map(\.databaseURL),
            bundleURL: bundleURL, fileManager: fileManager)

        do {
            try Self.throwIfCancelled(shouldCancel)
            let retainedMetadataURL = publication.inputDirectory.appendingPathComponent("metadata-" + metadataURL.lastPathComponent)
            try fileManager.copyItem(at: metadataURL, to: retainedMetadataURL)
            let metadataInput = ProvenanceFileDescriptor(
                path: retainedMetadataURL.path,
                checksumSHA256: try ProvenanceFileHasher.sha256(
                    of: retainedMetadataURL, cancellationCheck: { try Self.throwIfCancelled(shouldCancel) }
                ),
                fileSize: try ProvenanceFileHasher.fileSize(of: retainedMetadataURL),
                format: .text, role: .input, originPath: metadataURL.path
            )
            let contextInputs = try contextInputDescriptors(bundleURL: bundleURL, targets: targets)
            let databaseInputs = try targets.map { try publication.inputDescriptor(for: $0.databaseURL) }
            var updatedCounts: [String: Int] = [:]
            for target in targets {
                try Self.throwIfCancelled(shouldCancel)
                let database = publication.database(at: target.databaseURL)
                let count = try database.importSampleMetadata(from: retainedMetadataURL, format: format)
                updatedCounts[target.databaseURL.path] = count
            }

            try publication.checkpoint()
            let databaseOutputs = try targets.map {
                try ProvenanceFileDescriptor.file(url: $0.databaseURL, format: .unknown, role: .output)
            }
            let completedAt = runClock.now
            let envelope = try provenanceEnvelope(
                metadataURL: metadataURL,
                format: format,
                invocationArgv: invocationArgv,
                bundleURL: bundleURL,
                targets: targets,
                metadataInput: metadataInput,
                contextInputs: contextInputs,
                databaseInputs: databaseInputs,
                databaseOutputs: databaseOutputs,
                updatedCounts: updatedCounts,
                startedAt: runClock.startedAt,
                completedAt: completedAt
            )
            try Self.throwIfCancelled(shouldCancel)
            let provenanceURL = try writeProvenance(envelope, bundleURL, publication)
            publication.commit()
            return VariantSampleMetadataImportResult(
                updatedCountsByDatabase: updatedCounts,
                provenanceURL: provenanceURL
            )
        } catch {
            try publication.rollback(after: error)
        }
    }

    private static func throwIfCancelled(_ shouldCancel: () -> Bool) throws {
        if shouldCancel() { throw CancellationError() }
    }

    private func provenanceEnvelope(
        metadataURL: URL,
        format: MetadataFormat,
        invocationArgv: [String]?,
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
        let argv = invocationArgv ?? [
            toolName,
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
            toolName: toolName,
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
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            toolKind: toolKind
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

        builder = try builder.consumedInputSnapshot(metadataInput)
        for input in databaseInputs { builder = try builder.consumedInputSnapshot(input) }
        for input in contextInputs { builder = try builder.consumedInputSnapshot(input) }
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

    private func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-:=,+"))
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
