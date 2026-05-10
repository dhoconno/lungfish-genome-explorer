import Foundation

public protocol CondaLockInstalling: Sendable {
    func install(environment: String, packageSpecs: [String], condaRoot: URL) async throws
}

public struct CondaManagerLockInstaller: CondaLockInstalling {
    private let manager: CondaManager

    public init(manager: CondaManager = .shared) {
        self.manager = manager
    }

    public func install(environment: String, packageSpecs: [String], condaRoot: URL) async throws {
        let resolvedRoot = condaRoot.standardizedFileURL
        let installManager = manager.rootPrefix.standardizedFileURL == resolvedRoot
            ? manager
            : CondaManager(rootPrefix: resolvedRoot)
        try await installManager.install(packages: packageSpecs, environment: environment)
    }
}

public struct CondaLockfileResult: Sendable, Hashable {
    public let lockfileURL: URL
    public let provenanceURL: URL
}

public struct CondaLockInstallResult: Sendable, Hashable {
    public let installedEnvironments: [String]
    public let provenanceURL: URL
}

public struct CondaLockfileService {
    private let fileManager: FileManager
    private let platforms: [String]
    private let channels: [String]

    public init(
        platforms: [String] = ["osx-arm64", "linux-64"],
        channels: [String] = ["conda-forge", "bioconda"],
        fileManager: FileManager = .default
    ) {
        self.platforms = platforms
        self.channels = channels
        self.fileManager = fileManager
    }

    public func writeLockfile(
        for pack: PluginPack,
        to output: URL,
        commandLine: [String]
    ) throws -> CondaLockfileResult {
        let start = Date()
        try fileManager.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let yaml = lockfileYAML(for: pack)
        try yaml.write(to: output, atomically: true, encoding: .utf8)

        let provenanceURL = try writeProvenance(
            name: "Conda Lockfile Export",
            toolName: "lungfish conda lock",
            commandLine: commandLine,
            inputs: [],
            outputs: [ProvenanceRecorder.fileRecord(url: output, format: .text, role: .output)],
            parameters: [
                "packID": .string(pack.id),
                "packName": .string(pack.name),
                "outputPath": .string(output.standardizedFileURL.path),
                "platforms": .array(platforms.map { .string($0) }),
                "channels": .array(channels.map { .string($0) }),
                "runtimeUser": .string(WorkflowRun.currentUser),
                "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
            ],
            outputDirectory: output.deletingLastPathComponent(),
            start: start,
            exitCode: 0,
            stderr: nil
        )
        return CondaLockfileResult(lockfileURL: output, provenanceURL: provenanceURL)
    }

    public func install(
        fromLockfile lockfile: URL,
        condaRoot: URL,
        installer: any CondaLockInstalling = CondaManagerLockInstaller(),
        commandLine: [String]
    ) async throws -> CondaLockInstallResult {
        let start = Date()
        let packages = try parsePackages(from: lockfile)
        var installed: [String] = []
        for package in packages {
            try await installer.install(
                environment: package.name,
                packageSpecs: ["\(package.name)=\(package.version)"],
                condaRoot: condaRoot
            )
            installed.append(package.name)
        }

        let provenanceURL = try writeProvenance(
            name: "Conda Lockfile Install",
            toolName: "lungfish conda install",
            commandLine: commandLine,
            inputs: [ProvenanceRecorder.fileRecord(url: lockfile, format: .text, role: .input)],
            outputs: installed.map {
                FileRecord(
                    path: condaRoot.standardizedFileURL.appendingPathComponent("envs/\($0)", isDirectory: true).path,
                    role: .output
                )
            },
            parameters: [
                "lockfilePath": .string(lockfile.standardizedFileURL.path),
                "destinationCondaRoot": .string(condaRoot.standardizedFileURL.path),
                "environments": .array(installed.map { .string($0) }),
                "runtimeUser": .string(WorkflowRun.currentUser),
                "runtimeHostName": .string(ProcessInfo.processInfo.hostName),
            ],
            outputDirectory: condaRoot.standardizedFileURL,
            start: start,
            exitCode: 0,
            stderr: nil
        )

        return CondaLockInstallResult(installedEnvironments: installed, provenanceURL: provenanceURL)
    }

    private func lockfileYAML(for pack: PluginPack) -> String {
        let requirements = pack.toolRequirements.sorted { $0.environment < $1.environment }
        let specs = requirements.flatMap(\.installPackages).sorted()
        let contentHash = DeterministicTarWriter.sha256(Data(specs.joined(separator: "\n").utf8))
        var lines: [String] = [
            "# Generated by lungfish conda lock",
            "version: 1",
            "metadata:",
            "  pack: \(pack.id)",
            "  content_hash:",
        ]
        for platform in platforms {
            lines.append("    \(platform): \(contentHash)")
        }
        lines.append("  channels:")
        for channel in channels {
            lines.append("    - \(channel)")
        }
        lines.append("  platforms:")
        for platform in platforms {
            lines.append("    - \(platform)")
        }
        lines.append("package:")
        for requirement in requirements {
            let parsed = parsePackageSpec(requirement.installPackages.first ?? requirement.id)
            for platform in platforms {
                lines += [
                    "  - name: \(parsed.name)",
                    "    version: \"\(parsed.version ?? requirement.version ?? "0")\"",
                    "    manager: conda",
                    "    platform: \(platform)",
                    "    category: main",
                    "    optional: false",
                    "    dependencies: {}",
                ]
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private struct LockPackage {
        let name: String
        let version: String
    }

    private func parsePackages(from lockfile: URL) throws -> [LockPackage] {
        let lines = try String(contentsOf: lockfile, encoding: .utf8).components(separatedBy: .newlines)
        var packages: [LockPackage] = []
        var currentName: String?
        var currentVersion: String?

        func flush() {
            if let currentName, let currentVersion,
               !packages.contains(where: { $0.name == currentName }) {
                packages.append(.init(name: currentName, version: currentVersion))
            }
            currentName = nil
            currentVersion = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name: ") {
                flush()
                currentName = String(trimmed.dropFirst("- name: ".count))
            } else if trimmed.hasPrefix("version: ") {
                currentVersion = String(trimmed.dropFirst("version: ".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        flush()
        return packages
    }

    private func parsePackageSpec(_ spec: String) -> (name: String, version: String?) {
        let withoutChannel = spec.split(separator: "::").last.map(String.init) ?? spec
        let parts = withoutChannel.split(separator: "=", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
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
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let end = Date()
        let step = StepExecution(
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            command: CondaOfflinePackService.redactedCommandLine(commandLine),
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
        return provenanceURL
    }
}
