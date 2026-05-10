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

        public init(name: String, relativePath: String) {
            self.name = name
            self.relativePath = relativePath
        }
    }

    public let schemaVersion: Int
    public let packID: String
    public let packName: String
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
        let start = Date()
        let sourceCondaRoot = condaRoot.standardizedFileURL
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
            manifestEnvironments.append(.init(name: environmentName, relativePath: "envs/\(environmentName)"))
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
                "sourceCondaRoot": .string(sourceCondaRoot.path),
                "outputDirectory": .string(packDirectory.path),
                "environments": .array(environmentNames.map { .string($0) }),
            ],
            outputDirectory: packDirectory,
            start: start,
            exitCode: 0,
            stderr: nil
        )

        return CondaOfflinePackExportResult(
            packDirectory: packDirectory,
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
        let manifestURL = packDirectory.appendingPathComponent(Self.manifestFilename)
        let manifest = try readManifest(from: manifestURL)
        let destinationEnvsRoot = condaRoot.standardizedFileURL.appendingPathComponent("envs", isDirectory: true)
        try fileManager.createDirectory(at: destinationEnvsRoot, withIntermediateDirectories: true)

        var installedEnvironments: [URL] = []
        for environment in manifest.environments {
            let source = packDirectory.appendingPathComponent(environment.relativePath, isDirectory: true)
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
        let provenanceURL = try writeProvenance(
            name: "Conda Offline Pack Install",
            toolName: "lungfish-cli",
            commandLine: sanitizedCommandLine,
            inputs: [ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .input)]
                + manifest.files.map {
                    FileRecord(path: packDirectory.appendingPathComponent($0.relativePath).path, sha256: $0.sha256, sizeBytes: $0.sizeBytes, role: .input)
                },
            outputs: copiedFiles.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
            parameters: [
                "packID": .string(manifest.packID),
                "packName": .string(manifest.packName),
                "sourcePackDirectory": .string(packDirectory.standardizedFileURL.path),
                "destinationCondaRoot": .string(condaRoot.standardizedFileURL.path),
                "overwrite": .boolean(overwrite),
                "environments": .array(manifest.environments.map { .string($0.name) }),
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
        let sensitiveFlags = Set(["--ncbi-api-key", "--api-key", "--token", "--secret"])

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
