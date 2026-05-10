@preconcurrency import Foundation
import LungfishCore

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
            toolName: "lungfish-cli",
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
        let mutationLock = try CondaRootMutationLock.acquire(root: destinationCondaRoot)
        defer { mutationLock.release() }

        let prepared = try preparePackDirectory(from: packDirectory)
        defer { prepared.cleanup?() }

        let resolvedPackDirectory = prepared.directory
        let manifestURL = resolvedPackDirectory.appendingPathComponent(Self.manifestFilename)
        let manifest = try readManifest(from: manifestURL)
        try validate(manifest: manifest, in: resolvedPackDirectory)
        let destinationEnvsRoot = destinationCondaRoot.appendingPathComponent("envs", isDirectory: true)
        try fileManager.createDirectory(at: destinationEnvsRoot, withIntermediateDirectories: true)

        var installedEnvironments: [URL] = []
        for environment in manifest.environments {
            let source = resolvedPackDirectory.appendingPathComponent(environment.relativePath, isDirectory: true)
            let destination = destinationEnvsRoot.appendingPathComponent(environment.name, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                guard overwrite else {
                    throw CondaError.environmentCreationFailed(
                        "Environment '\(environment.name)' already exists. Re-run with --overwrite to replace it."
                    )
                }
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            installedEnvironments.append(destination)
        }

        let copiedFiles = installedEnvironments.flatMap { regularFiles(under: $0) }
        let sanitizedCommandLine = Self.redactedCommandLine(commandLine)
        var inputRecords = [ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .input)]
        if resolvedPackDirectory.standardizedFileURL != packDirectory.standardizedFileURL {
            inputRecords.append(ProvenanceRecorder.fileRecord(url: packDirectory, role: .input))
        }
        inputRecords.append(contentsOf: manifest.files.map {
            FileRecord(
                path: resolvedPackDirectory.appendingPathComponent($0.relativePath).path,
                sha256: $0.sha256,
                sizeBytes: $0.sizeBytes,
                role: .input
            )
        })
        let provenanceURL = try writeProvenance(
            name: "Conda Offline Pack Install",
            toolName: "lungfish-cli",
            commandLine: sanitizedCommandLine,
            inputs: inputRecords,
            outputs: copiedFiles.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
            parameters: [
                "packID": .string(manifest.packID),
                "packName": .string(manifest.packName),
                "packVersion": .string(manifest.packVersion ?? "unknown"),
                "sourceBundle": .string(packDirectory.standardizedFileURL.path),
                "sourcePackDirectory": .string(resolvedPackDirectory.standardizedFileURL.path),
                "destinationCondaRoot": .string(condaRoot.standardizedFileURL.path),
                "overwrite": .boolean(overwrite),
                "environments": .array(manifest.environments.map { .string($0.name) }),
                "runtimeUser": .string(WorkflowRun.currentUser),
                "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
            ],
            outputDirectory: condaRoot.standardizedFileURL,
            start: start,
            exitCode: 0,
            stderr: nil
        )

        return CondaOfflinePackInstallResult(
            installedEnvironments: installedEnvironments,
            provenanceURL: provenanceURL
        )
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
        stderr: String?
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
        let provenanceURL = outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
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
        }
    }
}
