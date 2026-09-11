@preconcurrency import Foundation
import CryptoKit
import LungfishCore

public enum ManagedPythonRuntimeInstallerError: Error, LocalizedError, Sendable, Equatable {
    case invalidEnvironment
    case requirementsChecksumMismatch(expected: String, actual: String)
    case processFailed([String], Int32, String)
    case invalidInventory
    case runtimeIdentityMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironment: return "Managed Python environment is missing its isolated Python executable."
        case .requirementsChecksumMismatch: return "Bundled Python requirements did not match the manifest checksum."
        case .processFailed(let argv, let status, _): return "Managed Python command \(argv.first ?? "process") failed with exit status \(status)."
        case .invalidInventory: return "Managed Python installation did not return a valid installed-file inventory."
        case .runtimeIdentityMismatch(let expected, let actual): return "Managed Python distribution is \(actual), but Lungfish requires \(expected)."
        }
    }
}

public struct ManagedPythonRuntimeCommandResult: Sendable, Hashable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String
    public let wallTimeSeconds: Double

    public init(exitStatus: Int32, stdout: String, stderr: String, wallTimeSeconds: Double) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.wallTimeSeconds = wallTimeSeconds
    }
}

public struct ManagedPythonRuntimeReceipt: Sendable, Codable, Hashable {
    public static let schemaVersion = 1
    public static let maximumStderrLength = 16_384

    public struct FileRecord: Sendable, Codable, Hashable {
        public let relativePath: String
        public let sha256: String
        public let sizeBytes: UInt64
        public init(relativePath: String, sha256: String, sizeBytes: UInt64) {
            self.relativePath = relativePath
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }
    }

    public struct CondaRecord: Sendable, Codable, Hashable {
        public let name: String
        public let version: String
        public let build: String
        public let subdir: String
    }

    public struct CommandRecord: Sendable, Codable, Hashable {
        public let argv: [String]
        public let reproducibleCommand: String
        public let exitStatus: Int32
        public let wallTimeSeconds: Double
        public let stderr: String
    }

    public struct DistributionRecord: Sendable, Codable, Hashable {
        public let name: String
        public let version: String
    }

    public struct Probe: Sendable, Codable, Hashable {
        public let argv: [String]
        public let exitStatus: Int32
        public let output: String
    }

    public let schemaVersion: Int
    public let requested: ManagedPythonRuntimeSpec
    public let environmentPath: String
    public let pythonVersion: String
    public let condaPackages: [CondaRecord]
    public let requirements: FileRecord
    public let downloadedWheels: [FileRecord]
    public let installedDistributions: [DistributionRecord]
    public let installedFiles: [FileRecord]
    public let commands: [CommandRecord]
    public let versionProbe: Probe
    public let helpProbe: Probe
    public let startedAt: Date
    public let completedAt: Date
    public let wallTimeSeconds: Double
    public let exitStatus: Int32
    public let stderr: String

    public init(
        requested: ManagedPythonRuntimeSpec, environmentPath: String, pythonVersion: String,
        condaPackages: [CondaRecord], requirements: FileRecord,
        downloadedWheels: [FileRecord], installedDistributions: [DistributionRecord],
        installedFiles: [FileRecord],
        commands: [CommandRecord], versionProbe: Probe, helpProbe: Probe,
        startedAt: Date, completedAt: Date, wallTimeSeconds: Double,
        exitStatus: Int32 = 0, stderr: String = ""
    ) {
        self.schemaVersion = Self.schemaVersion
        self.requested = requested
        self.environmentPath = environmentPath
        self.pythonVersion = pythonVersion
        self.condaPackages = condaPackages
        self.requirements = requirements
        self.downloadedWheels = downloadedWheels
        self.installedDistributions = installedDistributions
        self.installedFiles = installedFiles
        self.commands = commands
        self.versionProbe = versionProbe
        self.helpProbe = helpProbe
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wallTimeSeconds = wallTimeSeconds
        self.exitStatus = exitStatus
        self.stderr = String(stderr.prefix(Self.maximumStderrLength))
    }

    public static func receiptURL(for spec: ManagedPythonRuntimeSpec, environmentURL: URL) -> URL {
        environmentURL.appendingPathComponent(
            "share/lungfish/managed-tools/python-runtime-\(spec.distributionName).json")
    }

    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func validates(spec: ManagedPythonRuntimeSpec, environmentURL: URL) -> Bool {
        guard schemaVersion == Self.schemaVersion, requested == spec, exitStatus == 0,
              versionProbe.exitStatus == 0, helpProbe.exitStatus == 0,
              versionProbe.output.localizedCaseInsensitiveContains(spec.distributionName),
              versionProbe.output.contains(spec.version), !helpProbe.output.isEmpty,
              spec.matches(pythonVersion: pythonVersion), commands.allSatisfy({ $0.exitStatus == 0 }),
              !commands.isEmpty, !downloadedWheels.isEmpty,
              !installedDistributions.isEmpty, !installedFiles.isEmpty,
              requirements.sha256 == spec.requirementsSHA256 else { return false }
        let currentConda = Set(Self.condaRecords(in: environmentURL))
        guard Set(condaPackages).isSubset(of: currentConda),
              spec.basePackageSpecs.allSatisfy({ packageSpec in
                  Self.condaRecord(in: currentConda, matches: packageSpec)
              }) else { return false }
        guard Self.validRelativePath(requirements.relativePath),
              Self.fileMatches(requirements, environmentURL: environmentURL),
              let requirementsData = try? Data(
            contentsOf: environmentURL.appendingPathComponent(requirements.relativePath)),
              Self.lockedDistributions(in: requirementsData) == Set(installedDistributions)
        else { return false }
        return ([requirements] + downloadedWheels + installedFiles).allSatisfy {
            Self.validRelativePath($0.relativePath)
                && Self.fileMatches($0, environmentURL: environmentURL)
        }
    }

    static func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func fileRecord(for url: URL, relativeTo root: URL) throws -> FileRecord {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { throw ManagedPythonRuntimeInstallerError.invalidInventory }
        let relative = String(path.dropFirst(rootPath.count))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard validRelativePath(relative), values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else {
            throw ManagedPythonRuntimeInstallerError.invalidInventory
        }
        return FileRecord(relativePath: relative, sha256: sha256(url), sizeBytes: size)
    }

    static func condaRecords(in environmentURL: URL) -> [CondaRecord] {
        let directory = environmentURL.appendingPathComponent("conda-meta")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        struct Raw: Decodable { let name: String; let version: String; let build: String; let subdir: String? }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url), let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
            return CondaRecord(name: raw.name, version: raw.version, build: raw.build, subdir: raw.subdir ?? "")
        }.sorted { $0.name < $1.name }
    }

    private static func condaRecord(in records: Set<CondaRecord>, matches spec: String) -> Bool {
        let unchanneled = spec.split(separator: ":").last.map(String.init) ?? spec
        let fields = unchanneled.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else { return false }
        return records.contains { $0.name == fields[0] && $0.version == fields[1] && $0.build == fields[2] }
    }

    private static func lockedDistributions(in data: Data) -> Set<DistributionRecord> {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("#"), let marker = value.range(of: "==") else { return nil }
            let name = String(value[..<marker.lowerBound]).lowercased().replacingOccurrences(of: "_", with: "-")
            let tail = value[marker.upperBound...]
            let version = tail.prefix { !$0.isWhitespace && $0 != "\\" }
            guard !name.isEmpty, !version.isEmpty else { return nil }
            return DistributionRecord(name: name, version: String(version))
        })
    }

    private static func fileMatches(_ record: FileRecord, environmentURL: URL) -> Bool {
        guard validRelativePath(record.relativePath),
              !hasSymbolicLinkAncestor(
                relativePath: record.relativePath, environmentURL: environmentURL) else { return false }
        let url = environmentURL.appendingPathComponent(record.relativePath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value == record.sizeBytes else { return false }
        return sha256(url) == record.sha256
    }

    private static func hasSymbolicLinkAncestor(
        relativePath: String,
        environmentURL: URL
    ) -> Bool {
        let components = relativePath.split(separator: "/").dropLast()
        var current = environmentURL
        for component in components {
            current.appendPathComponent(String(component))
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                return true
            }
            if values.isSymbolicLink == true { return true }
        }
        return false
    }

    private static func sha256(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ManagedPythonRuntimeInstaller: Sendable {
    public typealias RequirementsProvider = @Sendable (String) throws -> Data
    public typealias CommandRunner = @Sendable ([String], URL) async throws -> ManagedPythonRuntimeCommandResult

    private let requirementsProvider: RequirementsProvider
    private let commandRunner: CommandRunner
    private let now: @Sendable () -> Date

    private static let inventoryScript = """
        import hashlib
        import importlib.metadata
        import json
        import pathlib
        import re
        import sys

        root = pathlib.Path(sys.argv[1]).resolve()
        requirements = pathlib.Path(sys.argv[2])
        pins = []
        for line in requirements.read_text().splitlines():
            match = re.match(r"^([A-Za-z0-9_.-]+)==([^ \\\\]+)", line)
            if match:
                pins.append((match.group(1), match.group(2)))

        distributions = []
        files = {}
        for name, expected_version in pins:
            distribution = importlib.metadata.distribution(name)
            distributions.append({
                "name": name.lower().replace("_", "-"),
                "version": distribution.version,
            })
            for entry in distribution.files or []:
                path = pathlib.Path(distribution.locate_file(entry))
                if not path.is_file():
                    continue
                relative_path = str(path.resolve().relative_to(root))
                files[relative_path] = {
                    "relativePath": relative_path,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "sizeBytes": path.stat().st_size,
                }

        print(json.dumps({
            "distributions": distributions,
            "files": list(files.values()),
        }, sort_keys=True))
        """

    public init(
        requirementsProvider: RequirementsProvider? = nil,
        commandRunner: CommandRunner? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.requirementsProvider = requirementsProvider ?? { name in
            guard let url = RuntimeResourceLocator.path("ManagedTools/\(name)", in: .workflow) else {
                throw ManagedPythonRuntimeInstallerError.invalidInventory
            }
            return try Data(contentsOf: url)
        }
        self.commandRunner = commandRunner ?? Self.run
        self.now = now
    }

    public func install(
        spec: ManagedPythonRuntimeSpec,
        environmentURL: URL,
        executableName: String
    ) async throws -> ManagedPythonRuntimeReceipt {
        try spec.validateRequestedIdentity()
        let safeExecutableCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !executableName.isEmpty, executableName != ".", executableName != "..",
              executableName.unicodeScalars.allSatisfy(safeExecutableCharacters.contains) else {
            throw ManagedPythonRuntimeInstallerError.invalidEnvironment
        }
        let root = environmentURL.standardizedFileURL
        let python = root.appendingPathComponent("bin/python")
        guard python.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python.path) else {
            throw ManagedPythonRuntimeInstallerError.invalidEnvironment
        }
        let receiptURL = ManagedPythonRuntimeReceipt.receiptURL(for: spec, environmentURL: root)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try FileManager.default.removeItem(at: receiptURL)
        }
        let started = now()
        let managed = root.appendingPathComponent("share/lungfish/managed-tools", isDirectory: true)
        let wheelhouse = managed.appendingPathComponent("wheels-\(spec.distributionName)", isDirectory: true)
        if FileManager.default.fileExists(atPath: wheelhouse.path) {
            try FileManager.default.removeItem(at: wheelhouse)
        }
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        let requirementsURL = managed.appendingPathComponent(spec.requirementsResource)
        let requirementsData = try requirementsProvider(spec.requirementsResource)
        let requirementsHash = SHA256.hash(data: requirementsData).map { String(format: "%02x", $0) }.joined()
        guard requirementsHash == spec.requirementsSHA256 else {
            throw ManagedPythonRuntimeInstallerError.requirementsChecksumMismatch(
                expected: spec.requirementsSHA256, actual: requirementsHash)
        }
        try requirementsData.write(to: requirementsURL, options: .atomic)

        var records: [ManagedPythonRuntimeReceipt.CommandRecord] = []
        var stderr = ""
        func execute(_ argv: [String]) async throws -> ManagedPythonRuntimeCommandResult {
            try Task.checkCancellation()
            let result = try await commandRunner(argv, root)
            stderr += result.stderr
            records.append(.init(
                argv: argv, reproducibleCommand: argv.map(Self.shellEscape).joined(separator: " "),
                exitStatus: result.exitStatus, wallTimeSeconds: result.wallTimeSeconds,
                stderr: String(result.stderr.prefix(ManagedPythonRuntimeReceipt.maximumStderrLength))))
            guard result.exitStatus == 0 else {
                throw ManagedPythonRuntimeInstallerError.processFailed(argv, result.exitStatus, result.stderr)
            }
            return result
        }

        let pip = [python.path, "-I", "-m", "pip", "--isolated"]
        _ = try await execute(pip + ["download", "--require-hashes", "--only-binary=:all:", "--no-deps", "--dest", wheelhouse.path, "-r", requirementsURL.path])
        _ = try await execute(pip + ["install", "--require-hashes", "--no-index", "--no-deps", "--force-reinstall", "--find-links", wheelhouse.path, "-r", requirementsURL.path])
        _ = try await execute(pip + ["check"])
        let inventoryResult = try await execute([
            python.path, "-I", "-c", Self.inventoryScript, root.path, requirementsURL.path,
        ])
        struct Inventory: Decodable {
            let distributions: [ManagedPythonRuntimeReceipt.DistributionRecord]
            let files: [ManagedPythonRuntimeReceipt.FileRecord]
        }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: Data(inventoryResult.stdout.utf8)),
              inventory.files.allSatisfy({ ManagedPythonRuntimeReceipt.validRelativePath($0.relativePath) }) else {
            throw ManagedPythonRuntimeInstallerError.invalidInventory
        }
        let actualVersion = inventory.distributions.first {
            $0.name == spec.distributionName.lowercased().replacingOccurrences(of: "_", with: "-")
        }?.version ?? "missing"
        guard actualVersion == spec.version else {
            throw ManagedPythonRuntimeInstallerError.runtimeIdentityMismatch(expected: spec.version, actual: actualVersion)
        }
        let executable = root.appendingPathComponent("bin/\(executableName)")
        let versionArgv = [executable.path, "--version"]
        let version = try await execute(versionArgv)
        let helpArgv = [executable.path, "--help"]
        let help = try await execute(helpArgv)
        let wheels = try FileManager.default.contentsOfDirectory(at: wheelhouse, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "whl" }.sorted { $0.path < $1.path }
            .map { try ManagedPythonRuntimeReceipt.fileRecord(for: $0, relativeTo: root) }
        guard !wheels.isEmpty else { throw ManagedPythonRuntimeInstallerError.invalidInventory }
        let completed = now()
        try Task.checkCancellation()
        let receipt = ManagedPythonRuntimeReceipt(
            requested: spec, environmentPath: root.path,
            pythonVersion: Self.pythonVersion(from: ManagedPythonRuntimeReceipt.condaRecords(in: root)),
            condaPackages: ManagedPythonRuntimeReceipt.condaRecords(in: root),
            requirements: try ManagedPythonRuntimeReceipt.fileRecord(for: requirementsURL, relativeTo: root),
            downloadedWheels: wheels, installedDistributions: inventory.distributions,
            installedFiles: inventory.files, commands: records,
            versionProbe: .init(argv: versionArgv, exitStatus: version.exitStatus, output: version.stdout + version.stderr),
            helpProbe: .init(argv: helpArgv, exitStatus: help.exitStatus, output: help.stdout + help.stderr),
            startedAt: started, completedAt: completed,
            wallTimeSeconds: max(0, completed.timeIntervalSince(started)), stderr: stderr)
        guard receipt.validates(spec: spec, environmentURL: root) else {
            throw ManagedPythonRuntimeInstallerError.invalidInventory
        }
        try receipt.write(to: receiptURL)
        return receipt
    }

    private static func pythonVersion(from records: [ManagedPythonRuntimeReceipt.CondaRecord]) -> String {
        records.first { $0.name == "python" }?.version ?? "unknown"
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ argv: [String], workingDirectory: URL) async throws -> ManagedPythonRuntimeCommandResult {
        let started = Date()
        let result = try await ManagedToolSourceInstaller.run(.init(
            executable: URL(fileURLWithPath: argv[0]),
            arguments: Array(argv.dropFirst()),
            workingDirectory: workingDirectory
        ))
        return .init(
            exitStatus: result.exitStatus,
            stdout: result.stdout,
            stderr: result.stderr,
            wallTimeSeconds: Date().timeIntervalSince(started))
    }
}
