@preconcurrency import Foundation
import LungfishCore
import os

public struct CondaOfflinePackFile: Sendable, Codable, Hashable {
    public let relativePath: String
    public let sizeBytes: UInt64?
    public let sha256: String?

    public init(relativePath: String, sizeBytes: UInt64?, sha256: String?) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct CondaOfflinePackManifest: Sendable, Codable, Hashable {
    public struct Environment: Sendable, Codable, Hashable {
        public let name: String
        public let relativePath: String
        public let sourcePath: String?

        public init(name: String, relativePath: String, sourcePath: String? = nil) {
            self.name = name
            self.relativePath = relativePath
            self.sourcePath = sourcePath
        }
    }

    public let schemaVersion: Int
    public let packID: String
    public let packName: String
    public let packVersion: String?
    public let exportedAt: Date
    public let sourceCondaRoot: String
    public let environments: [Environment]
    public let files: [CondaOfflinePackFile]
    public let commandLine: [String]
    public let lungfishVersion: String

    public init(
        schemaVersion: Int = 1,
        packID: String,
        packName: String,
        packVersion: String? = WorkflowRun.currentAppVersion,
        exportedAt: Date = Date(),
        sourceCondaRoot: String,
        environments: [Environment],
        files: [CondaOfflinePackFile],
        commandLine: [String],
        lungfishVersion: String = WorkflowRun.currentAppVersion
    ) {
        self.schemaVersion = schemaVersion
        self.packID = packID
        self.packName = packName
        self.packVersion = packVersion
        self.exportedAt = exportedAt
        self.sourceCondaRoot = sourceCondaRoot
        self.environments = environments
        self.files = files
        self.commandLine = commandLine
        self.lungfishVersion = lungfishVersion
    }
}

public struct CondaOfflinePackExportResult: Sendable, Hashable {
    public let packDirectory: URL
    public let archiveURL: URL?
    public let manifestURL: URL
    public let provenanceURL: URL
}

public struct CondaOfflinePackInstallResult: Sendable, Hashable {
    public let installedEnvironments: [URL]
    public let provenanceURL: URL
}

public struct CondaOfflinePackService {
    public static let manifestFilename = "offline-pack-manifest.json"
    public static let installFailureProvenanceFilename = ".lungfish-offline-pack-install-failure.provenance.json"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exportPack(
        pack: PluginPack,
        condaRoot: URL,
        outputDirectory: URL,
        commandLine: [String]
    ) async throws -> CondaOfflinePackExportResult {
        try await exportPack(
            pack: pack,
            condaRoot: condaRoot,
            output: outputDirectory,
            commandLine: commandLine
        )
    }

    public func exportPack(
        pack: PluginPack,
        condaRoot: URL,
        output: URL,
        commandLine: [String]
    ) async throws -> CondaOfflinePackExportResult {
        let start = Date()
        let sourceCondaRoot = condaRoot.standardizedFileURL
        let mutationLock = try CondaRootMutationLock.acquire(root: sourceCondaRoot)
        defer { mutationLock.release() }

        let archiveKind = Self.archiveKind(for: output)
        let outputDirectory = archiveKind == nil
            ? output
            : output.deletingLastPathComponent()
        let packDirectory = outputDirectory
            .appendingPathComponent("\(pack.id)-conda-offline-pack", isDirectory: true)
        let envsDirectory = packDirectory.appendingPathComponent("envs", isDirectory: true)

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: packDirectory.path) {
            try fileManager.removeItem(at: packDirectory)
        }
        try fileManager.createDirectory(at: envsDirectory, withIntermediateDirectories: true)

        let environmentNames = Array(Set(pack.toolRequirements.map(\.environment))).sorted()
        var manifestEnvironments: [CondaOfflinePackManifest.Environment] = []
        var copiedFileURLs: [URL] = []

        for environmentName in environmentNames {
            let source = sourceCondaRoot.appendingPathComponent("envs/\(environmentName)", isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else {
                throw CondaError.environmentNotFound(environmentName)
            }

            let destination = envsDirectory.appendingPathComponent(environmentName, isDirectory: true)
            try fileManager.copyItem(at: source, to: destination)
            manifestEnvironments.append(.init(
                name: environmentName,
                relativePath: "envs/\(environmentName)",
                sourcePath: source.standardizedFileURL.path
            ))
            copiedFileURLs.append(contentsOf: regularFiles(under: destination))
        }

        let fileRecords = copiedFileURLs
            .sorted { $0.path < $1.path }
            .map { url in
                CondaOfflinePackFile(
                    relativePath: relativePath(from: packDirectory, to: url),
                    sizeBytes: fileSize(url),
                    sha256: ProvenanceRecorder.sha256(of: url)
                )
            }

        let sanitizedCommandLine = Self.redactedCommandLine(commandLine)
        let manifest = CondaOfflinePackManifest(
            packID: pack.id,
            packName: pack.name,
            packVersion: Self.packDefinitionVersion(for: pack),
            sourceCondaRoot: sourceCondaRoot.path,
            environments: manifestEnvironments,
            files: fileRecords,
            commandLine: sanitizedCommandLine
        )
        let manifestURL = packDirectory.appendingPathComponent(Self.manifestFilename)
        try writeJSON(manifest, to: manifestURL)

        let provenanceURL = try writeProvenance(
            name: "Conda Offline Pack Export",
            toolName: CLICommandIdentity.executableName,
            commandLine: sanitizedCommandLine,
            inputs: environmentNames.map {
                FileRecord(path: sourceCondaRoot.appendingPathComponent("envs/\($0)", isDirectory: true).path, role: .input)
            },
            outputs: copiedFileURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) }
                + [ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output)],
            parameters: [
                "packID": .string(pack.id),
                "packName": .string(pack.name),
                "packVersion": .string(Self.packDefinitionVersion(for: pack)),
                "sourceCondaRoot": .string(sourceCondaRoot.path),
                "outputDirectory": .string(packDirectory.path),
                "outputBundle": .string((archiveKind == nil ? packDirectory : output).standardizedFileURL.path),
                "outputKind": .string(archiveKind == nil ? "directory" : "archive"),
                "environments": .array(environmentNames.map { .string($0) }),
                "runtimeUser": .string(WorkflowRun.currentUser),
                "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
            ],
            outputDirectory: packDirectory,
            start: start,
            exitCode: 0,
            stderr: nil
        )

        if let archiveKind {
            try createArchive(from: packDirectory, to: output, kind: archiveKind)
        }

        return CondaOfflinePackExportResult(
            packDirectory: packDirectory,
            archiveURL: archiveKind == nil ? nil : output,
            manifestURL: manifestURL,
            provenanceURL: provenanceURL
        )
    }

    public func installPack(
        from packDirectory: URL,
        condaRoot: URL,
        overwrite: Bool,
        commandLine: [String]
    ) async throws -> CondaOfflinePackInstallResult {
        let start = Date()
        let destinationCondaRoot = condaRoot.standardizedFileURL
        let prepared = try preparePackDirectory(from: packDirectory)
        defer { prepared.cleanup?() }

        let resolvedPackDirectory = prepared.directory
        let manifestURL = resolvedPackDirectory.appendingPathComponent(Self.manifestFilename)
        let manifest = try readManifest(from: manifestURL)
        let sanitizedCommandLine = Self.redactedCommandLine(commandLine)
        let inputRecords = installInputRecords(
            manifest: manifest,
            manifestURL: manifestURL,
            sourceBundle: packDirectory,
            resolvedPackDirectory: resolvedPackDirectory
        )

        do {
            // Complete source-side validation before this import claims any
            // destination environment lease. This resolves the targets while
            // avoiding a long-held lock for a malformed bundle.
            try validate(manifest: manifest, in: resolvedPackDirectory)
        } catch {
            try? writeFailureProvenanceWhileHoldingRootLock(
                manifest: manifest,
                sourceBundle: packDirectory,
                resolvedPackDirectory: resolvedPackDirectory,
                destinationCondaRoot: destinationCondaRoot,
                overwrite: overwrite,
                commandLine: sanitizedCommandLine,
                inputs: inputRecords,
                outputs: [],
                probes: [],
                attemptedProbe: nil,
                failure: error,
                rollbackFailures: [],
                start: start
            )
            throw error
        }

        // The common transaction implementation takes sorted per-environment
        // flock locks before the root lock. It is held through copy, probes,
        // rollback if needed, and the final provenance receipt.
        let mutationTransaction = try await CondaEnvironmentMutationTransaction.acquire(
            root: destinationCondaRoot,
            environments: manifest.environments.map(\.name)
        )
        defer { mutationTransaction.release() }

        let destinationEnvsRoot = destinationCondaRoot.appendingPathComponent("envs", isDirectory: true)
        var installedEnvironments: [URL] = []
        var managedSourceReadinessProbes: [ManagedToolSourceRuntimeProbe] = []
        var environmentMutations: [OfflineImportEnvironmentMutation] = []

        do {
            try fileManager.createDirectory(at: destinationEnvsRoot, withIntermediateDirectories: true)
            for environment in manifest.environments {
                let source = resolvedPackDirectory.appendingPathComponent(environment.relativePath, isDirectory: true)
                let destination = destinationEnvsRoot.appendingPathComponent(environment.name, isDirectory: true)
                let staging = offlineImportStagingURL(for: destination)
                environmentMutations.append(.init(destination: destination, staging: staging, backup: nil))
                let mutationIndex = environmentMutations.index(before: environmentMutations.endIndex)

                // Copy into a same-filesystem staging directory first. A copy
                // failure leaves the prior destination untouched, and final
                // publication is an atomic rename inside envs/.
                try fileManager.copyItem(at: source, to: staging)

                if fileManager.fileExists(atPath: destination.path) {
                    guard overwrite else {
                        throw CondaError.environmentCreationFailed(
                            "Environment '\(environment.name)' already exists. Re-run with --overwrite to replace it."
                        )
                    }
                    let backup = offlineImportBackupURL(for: destination)
                    try fileManager.moveItem(at: destination, to: backup)
                    environmentMutations[mutationIndex].backup = backup
                }
                try fileManager.moveItem(at: staging, to: destination)

                managedSourceReadinessProbes.append(
                    contentsOf: try await validateImportedManagedSourceOverlay(in: destination)
                )
                installedEnvironments.append(destination)
            }

            let copiedFiles = installedEnvironments.flatMap { regularFiles(under: $0) }
            let provenanceURL = try writeProvenance(
                name: "Conda Offline Pack Install",
                toolName: CLICommandIdentity.executableName,
                commandLine: sanitizedCommandLine,
                inputs: inputRecords,
                outputs: copiedFiles.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
                parameters: installProvenanceParameters(
                    manifest: manifest,
                    sourceBundle: packDirectory,
                    resolvedPackDirectory: resolvedPackDirectory,
                    destinationCondaRoot: destinationCondaRoot,
                    overwrite: overwrite,
                    probes: managedSourceReadinessProbes,
                    attemptedProbe: nil
                ),
                outputDirectory: destinationCondaRoot,
                start: start,
                exitCode: 0,
                stderr: nil
            )
            try discardOfflineImportBackups(environmentMutations)
            return CondaOfflinePackInstallResult(
                installedEnvironments: installedEnvironments,
                provenanceURL: provenanceURL
            )
        } catch {
            let rollbackFailures = rollbackOfflineImport(environmentMutations)
            let attemptedProbe = runtimeProbe(from: error)
            let restoredOutputs = manifest.environments.flatMap { environment -> [URL] in
                let destination = destinationEnvsRoot.appendingPathComponent(environment.name, isDirectory: true)
                return fileManager.fileExists(atPath: destination.path) ? regularFiles(under: destination) : []
            }
            _ = try? writeFailureProvenance(
                manifest: manifest,
                sourceBundle: packDirectory,
                resolvedPackDirectory: resolvedPackDirectory,
                destinationCondaRoot: destinationCondaRoot,
                overwrite: overwrite,
                commandLine: sanitizedCommandLine,
                inputs: inputRecords,
                outputs: restoredOutputs.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
                probes: managedSourceReadinessProbes,
                attemptedProbe: attemptedProbe,
                failure: error,
                rollbackFailures: rollbackFailures,
                start: start
            )
            throw error
        }
    }

    public static func redactedCommandLine(_ commandLine: [String]) -> [String] {
        var redacted: [String] = []
        var redactNext = false
        let sensitiveFlags = Set([
            "--access-token",
            "--api-key",
            "--aws-secret-access-key",
            "--aws-session-token",
            "--client-secret",
            "--credential",
            "--github-token",
            "--ncbi-api-key",
            "--openai-api-key",
            "--password",
            "--secret",
            "--token",
        ])

        for argument in commandLine {
            if redactNext {
                redacted.append("<redacted>")
                redactNext = false
                continue
            }

            if sensitiveFlags.contains(argument) {
                redacted.append(argument)
                redactNext = true
                continue
            }

            if let flag = sensitiveFlags.first(where: { argument.hasPrefix("\($0)=") }) {
                redacted.append("\(flag)=<redacted>")
                continue
            }

            redacted.append(NCBIAPIKeyResolver.redactSecrets(in: argument))
        }
        return redacted
    }

    private func installInputRecords(
        manifest: CondaOfflinePackManifest,
        manifestURL: URL,
        sourceBundle: URL,
        resolvedPackDirectory: URL
    ) -> [FileRecord] {
        var records = [ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .input)]
        if resolvedPackDirectory.standardizedFileURL != sourceBundle.standardizedFileURL {
            records.append(ProvenanceRecorder.fileRecord(url: sourceBundle, role: .input))
        }
        records.append(contentsOf: manifest.files.map {
            FileRecord(
                path: resolvedPackDirectory.appendingPathComponent($0.relativePath).path,
                sha256: $0.sha256,
                sizeBytes: $0.sizeBytes,
                role: .input
            )
        })
        return records
    }

    private func installProvenanceParameters(
        manifest: CondaOfflinePackManifest,
        sourceBundle: URL,
        resolvedPackDirectory: URL,
        destinationCondaRoot: URL,
        overwrite: Bool,
        probes: [ManagedToolSourceRuntimeProbe],
        attemptedProbe: ManagedToolSourceRuntimeProbe?
    ) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "packID": .string(manifest.packID),
            "packName": .string(manifest.packName),
            "packVersion": .string(manifest.packVersion ?? "unknown"),
            "sourceBundle": .string(sourceBundle.standardizedFileURL.path),
            "sourcePackDirectory": .string(resolvedPackDirectory.standardizedFileURL.path),
            "destinationCondaRoot": .string(destinationCondaRoot.standardizedFileURL.path),
            "overwrite": .boolean(overwrite),
            "environments": .array(manifest.environments.map { .string($0.name) }),
            "resolvedOptions": .dictionary([
                "overwrite": .boolean(overwrite),
                "environmentNames": .array(manifest.environments.map { .string($0.name) }),
            ]),
            "managedSourceReadinessProbes": .array(probes.map(runtimeProbeParameterValue)),
            "runtimeUser": .string(WorkflowRun.currentUser),
            "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
        ]
        if let attemptedProbe {
            parameters["attemptedProbe"] = runtimeProbeParameterValue(attemptedProbe)
        }
        return parameters
    }

    private func runtimeProbeParameterValue(
        _ probe: ManagedToolSourceRuntimeProbe
    ) -> ParameterValue {
        .dictionary([
            "argv": .array(([probe.executablePath] + probe.arguments).map(ParameterValue.string)),
            "exitStatus": .integer(Int(probe.exitStatus)),
            "stderr": .string(probe.stderr),
        ])
    }

    private func writeFailureProvenanceWhileHoldingRootLock(
        manifest: CondaOfflinePackManifest,
        sourceBundle: URL,
        resolvedPackDirectory: URL,
        destinationCondaRoot: URL,
        overwrite: Bool,
        commandLine: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        probes: [ManagedToolSourceRuntimeProbe],
        attemptedProbe: ManagedToolSourceRuntimeProbe?,
        failure: Error,
        rollbackFailures: [String],
        start: Date
    ) throws {
        // No environment locks have been acquired for a preflight validation
        // failure, so taking only the root receipt lock cannot invert the
        // environment-then-root mutation order.
        let rootLock = try CondaRootMutationLock.acquire(root: destinationCondaRoot)
        defer { rootLock.release() }
        _ = try writeFailureProvenance(
            manifest: manifest,
            sourceBundle: sourceBundle,
            resolvedPackDirectory: resolvedPackDirectory,
            destinationCondaRoot: destinationCondaRoot,
            overwrite: overwrite,
            commandLine: commandLine,
            inputs: inputs,
            outputs: outputs,
            probes: probes,
            attemptedProbe: attemptedProbe,
            failure: failure,
            rollbackFailures: rollbackFailures,
            start: start
        )
    }

    private func writeFailureProvenance(
        manifest: CondaOfflinePackManifest,
        sourceBundle: URL,
        resolvedPackDirectory: URL,
        destinationCondaRoot: URL,
        overwrite: Bool,
        commandLine: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        probes: [ManagedToolSourceRuntimeProbe],
        attemptedProbe: ManagedToolSourceRuntimeProbe?,
        failure: Error,
        rollbackFailures: [String],
        start: Date
    ) throws -> URL {
        var parameters = installProvenanceParameters(
            manifest: manifest,
            sourceBundle: sourceBundle,
            resolvedPackDirectory: resolvedPackDirectory,
            destinationCondaRoot: destinationCondaRoot,
            overwrite: overwrite,
            probes: probes,
            attemptedProbe: attemptedProbe
        )
        parameters["failureMessage"] = .string(failure.localizedDescription)
        parameters["rollbackFailures"] = .array(rollbackFailures.map(ParameterValue.string))

        let stderrParts = [attemptedProbe?.stderr, failure.localizedDescription]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            + rollbackFailures
        return try writeProvenance(
            name: "Conda Offline Pack Install",
            toolName: CLICommandIdentity.executableName,
            commandLine: commandLine,
            inputs: inputs,
            outputs: outputs,
            parameters: parameters,
            outputDirectory: destinationCondaRoot,
            start: start,
            exitCode: attemptedProbe?.exitStatus ?? 1,
            stderr: stderrParts.joined(separator: "\n"),
            filename: Self.installFailureProvenanceFilename
        )
    }

    private func runtimeProbe(from error: Error) -> ManagedToolSourceRuntimeProbe? {
        guard let offlineError = error as? CondaOfflinePackError,
              case .runtimeProbeFailed(let probe) = offlineError else {
            return nil
        }
        return probe
    }

    private func readManifest(from url: URL) throws -> CondaOfflinePackManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CondaOfflinePackManifest.self, from: Data(contentsOf: url))
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// An imported source-backed environment must be usable before the offline
    /// import is recorded as successful. Probe explicit paths so the validation
    /// does not accidentally resolve an executable from the host PATH.
    private func validateImportedManagedSourceOverlay(
        in environmentURL: URL
    ) async throws -> [ManagedToolSourceRuntimeProbe] {
        let recordURL = environmentURL
            .appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        guard fileManager.fileExists(atPath: recordURL.path) else { return [] }
        guard let record = try? ManagedToolSourceInstallationRecord.load(from: recordURL) else {
            throw CondaOfflinePackError.invalidPack(
                "Managed Bracken source receipt is unreadable in \(environmentURL.path)"
            )
        }
        guard record.source.kind == .bracken else { return [] }
        guard record.validatesIntegrity(environmentURL: environmentURL) else {
            throw CondaOfflinePackError.invalidPack(
                "Managed Bracken source receipt does not match the imported runtime in \(environmentURL.path)"
            )
        }
        do {
            return try await ManagedToolSourceInstaller.probeBrackenRuntime(in: environmentURL)
        } catch let error as ManagedToolSourceInstallerError {
            if case .runtimeProbeFailed(let probe) = error {
                throw CondaOfflinePackError.runtimeProbeFailed(probe)
            }
            throw CondaOfflinePackError.invalidPack(
                "Managed Bracken runtime probe failed after offline import: \(error.localizedDescription)"
            )
        } catch {
            throw CondaOfflinePackError.invalidPack(
                "Managed Bracken runtime probe failed after offline import: \(error.localizedDescription)"
            )
        }
    }

    private func writeProvenance(
        name: String,
        toolName: String,
        commandLine: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        parameters: [String: ParameterValue],
        outputDirectory: URL,
        start: Date,
        exitCode: Int32,
        stderr: String?,
        filename: String = ProvenanceRecorder.provenanceFilename
    ) throws -> URL {
        let end = Date()
        let step = StepExecution(
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: commandLine,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: end.timeIntervalSince(start),
            stderr: stderr,
            startTime: start,
            endTime: end
        )
        let run = WorkflowRun(
            name: name,
            startTime: start,
            endTime: end,
            status: exitCode == 0 ? .completed : .failed,
            steps: [step],
            parameters: parameters
        )
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let provenanceURL = outputDirectory.appendingPathComponent(filename)
        try writeJSON(run, to: provenanceURL)
        return provenanceURL
    }

    private func regularFiles(under directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private enum ArchiveKind {
        case tar
        case gzipTar
    }

    private struct OfflineImportEnvironmentMutation {
        let destination: URL
        let staging: URL
        var backup: URL?
    }

    private struct PreparedPackDirectory {
        let directory: URL
        let cleanup: (() -> Void)?
    }

    private static func archiveKind(for url: URL) -> ArchiveKind? {
        let filename = url.lastPathComponent.lowercased()
        if filename.hasSuffix(".tar") { return .tar }
        if filename.hasSuffix(".tgz") || filename.hasSuffix(".tar.gz") { return .gzipTar }
        return nil
    }

    private static func packDefinitionVersion(for pack: PluginPack) -> String {
        WorkflowRun.currentAppVersion
    }

    private func preparePackDirectory(from source: URL) throws -> PreparedPackDirectory {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return PreparedPackDirectory(directory: source, cleanup: nil)
        }

        guard Self.archiveKind(for: source) != nil else {
            throw CondaOfflinePackError.invalidPack("Offline pack must be a directory, .tar, .tgz, or .tar.gz archive: \(source.path)")
        }

        let extractionRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-conda-offline-pack-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

        do {
            try extractArchive(source, to: extractionRoot)
            let packDirectory = try findPackDirectory(in: extractionRoot)
            return PreparedPackDirectory(directory: packDirectory) {
                try? self.fileManager.removeItem(at: extractionRoot)
            }
        } catch {
            try? fileManager.removeItem(at: extractionRoot)
            throw error
        }
    }

    private func offlineImportStagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".lungfish-offline-import-staging-\(destination.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func offlineImportBackupURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".lungfish-offline-import-backup-\(destination.lastPathComponent)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func discardOfflineImportBackups(
        _ mutations: [OfflineImportEnvironmentMutation]
    ) throws {
        for mutation in mutations {
            if let backup = mutation.backup,
               fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            if fileManager.fileExists(atPath: mutation.staging.path) {
                try fileManager.removeItem(at: mutation.staging)
            }
        }
    }

    /// Restores all destinations touched by this import in reverse publication
    /// order. A freshly created destination is removed; an overwritten one is
    /// replaced with its same-filesystem backup. Failures are retained in the
    /// provenance receipt rather than masking the original import error.
    private func rollbackOfflineImport(
        _ mutations: [OfflineImportEnvironmentMutation]
    ) -> [String] {
        var failures: [String] = []
        for mutation in mutations.reversed() {
            if fileManager.fileExists(atPath: mutation.destination.path) {
                do {
                    try fileManager.removeItem(at: mutation.destination)
                } catch {
                    failures.append("Could not remove imported environment \(mutation.destination.path): \(error.localizedDescription)")
                }
            }
            if fileManager.fileExists(atPath: mutation.staging.path) {
                do {
                    try fileManager.removeItem(at: mutation.staging)
                } catch {
                    failures.append("Could not remove import staging \(mutation.staging.path): \(error.localizedDescription)")
                }
            }
            if let backup = mutation.backup,
               fileManager.fileExists(atPath: backup.path) {
                do {
                    try fileManager.moveItem(at: backup, to: mutation.destination)
                } catch {
                    failures.append("Could not restore known-good environment \(mutation.destination.path): \(error.localizedDescription)")
                }
            }
        }
        return failures
    }

    private func createArchive(from packDirectory: URL, to archiveURL: URL, kind: ArchiveKind) throws {
        try fileManager.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }

        var arguments = [kind == .gzipTar ? "-czf" : "-cf", archiveURL.path]
        arguments += ["-C", packDirectory.deletingLastPathComponent().path, packDirectory.lastPathComponent]
        try runTar(arguments: arguments, operation: "archive")
    }

    private func extractArchive(_ archiveURL: URL, to destination: URL) throws {
        try runTar(
            arguments: ["-xf", archiveURL.path, "-C", destination.path],
            operation: "extract"
        )
    }

    private func runTar(arguments: [String], operation: String) throws {
        try Self.runTar(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: arguments,
            operation: operation
        )
    }

    /// Runs `tar` (or, in tests, a stand-in executable) with stderr drained
    /// concurrently on a background thread rather than after `waitUntilExit()`.
    ///
    /// macOS pipe buffers are ~64KB. `tar` routinely writes more than that to
    /// stderr while archiving/extracting a conda environment (permission
    /// warnings, "Ignoring unknown extended header keyword" notices, symlink
    /// warnings -- each can be its own line across thousands of files). The
    /// previous implementation called `waitUntilExit()` before reading stderr
    /// at all, so a full pipe buffer would block `tar` writing to stderr while
    /// this thread was blocked inside `waitUntilExit()` with nobody draining
    /// it -- a deadlock with no timeout (R3-R3H-4). This mirrors the
    /// concurrent-drain-before-wait pattern used by every other
    /// process-spawning helper in this source tree (NativeToolRunner.runProcess,
    /// ManagedMappingPipeline, CondaManager.runTool, PBAAClusteringPipeline.runProcess).
    ///
    /// Internal (not private) so CondaOfflinePackServiceTests can inject a
    /// fake executable that deliberately writes more than the pipe buffer
    /// size to stderr, proving the drain no longer deadlocks.
    static func runTar(executableURL: URL, arguments: [String], operation: String) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let drainGroup = DispatchGroup()
        let stderrLock = OSAllocatedUnfairLock<Data>(initialState: Data())
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let drained = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrLock.withLock { $0 = drained }
            drainGroup.leave()
        }

        try process.run()
        // Drain concurrently with the process running, THEN wait for exit --
        // waiting first (the original bug) can deadlock once tar fills the
        // pipe buffer and blocks on a write nobody is reading.
        drainGroup.wait()
        process.waitUntilExit()

        let stderrData = stderrLock.withLock { $0 }
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CondaOfflinePackError.archiveFailed(operation: operation, stderr: stderrText)
        }
    }

    private func findPackDirectory(in root: URL) throws -> URL {
        let rootManifest = root.appendingPathComponent(Self.manifestFilename)
        if fileManager.fileExists(atPath: rootManifest.path) {
            return root
        }

        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let manifest = child.appendingPathComponent(Self.manifestFilename)
            if fileManager.fileExists(atPath: manifest.path) {
                return child
            }
        }

        throw CondaOfflinePackError.invalidPack("Archive does not contain \(Self.manifestFilename)")
    }

    private func validate(manifest: CondaOfflinePackManifest, in packDirectory: URL) throws {
        guard manifest.schemaVersion == 1 else {
            throw CondaOfflinePackError.invalidPack("Unsupported offline pack manifest schema \(manifest.schemaVersion)")
        }
        guard !manifest.packID.isEmpty else {
            throw CondaOfflinePackError.invalidPack("Offline pack manifest is missing packID")
        }
        guard !manifest.packName.isEmpty else {
            throw CondaOfflinePackError.invalidPack("Offline pack manifest is missing packName")
        }
        guard !manifest.environments.isEmpty else {
            throw CondaOfflinePackError.invalidPack("Offline pack manifest does not list any environments")
        }

        for environment in manifest.environments {
            try validateEnvironmentName(environment.name)
            try validateRelativePath(environment.relativePath, description: "environment \(environment.name)")
            let source = packDirectory.appendingPathComponent(environment.relativePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CondaOfflinePackError.invalidPack("Missing environment directory: \(environment.relativePath)")
            }
        }

        for file in manifest.files {
            try validateRelativePath(file.relativePath, description: "file")
            guard let expectedSize = file.sizeBytes, let expectedSHA = file.sha256 else {
                throw CondaOfflinePackError.invalidPack("Missing checksum or size for \(file.relativePath)")
            }
            let url = packDirectory.appendingPathComponent(file.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CondaOfflinePackError.invalidPack("Missing manifest file: \(file.relativePath)")
            }
            guard fileSize(url) == expectedSize else {
                throw CondaOfflinePackError.invalidPack("Size mismatch for \(file.relativePath)")
            }
            guard ProvenanceRecorder.sha256(of: url) == expectedSHA else {
                throw CondaOfflinePackError.invalidPack("Checksum mismatch for \(file.relativePath)")
            }
        }
    }

    private func validateRelativePath(_ relativePath: String, description: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw CondaOfflinePackError.invalidPack("Unsafe relative path for \(description): \(relativePath)")
        }
    }

    private func validateEnvironmentName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw CondaOfflinePackError.invalidPack("Unsafe environment name: \(name)")
        }
    }

    private func fileSize(_ url: URL) -> UInt64? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? UInt64
    }

    private func relativePath(from root: URL, to file: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

public enum CondaOfflinePackError: Error, LocalizedError, Sendable {
    case invalidPack(String)
    case archiveFailed(operation: String, stderr: String)
    case runtimeProbeFailed(ManagedToolSourceRuntimeProbe)

    public var errorDescription: String? {
        switch self {
        case .invalidPack(let message):
            return message
        case .archiveFailed(let operation, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Failed to \(operation) offline conda pack archive"
            }
            return "Failed to \(operation) offline conda pack archive: \(detail)"
        case .runtimeProbeFailed(let probe):
            return "Managed Bracken runtime probe failed after offline import: \(URL(fileURLWithPath: probe.executablePath).lastPathComponent) exited \(probe.exitStatus)."
        }
    }
}
