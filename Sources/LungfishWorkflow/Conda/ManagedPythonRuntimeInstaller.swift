@preconcurrency import Foundation
import CryptoKit
import LungfishCore

public enum ManagedPythonRuntimeInstallerError: Error, LocalizedError, Sendable, Equatable {
    case invalidEnvironment
    case requirementsChecksumMismatch(expected: String, actual: String)
    case processFailed([String], Int32, String)
    /// The installation's inventory or receipt failed a check. The reason names the check, in one or two sentences.
    case invalidInventory(String)
    case runtimeIdentityMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironment: return "Managed Python environment is missing its isolated Python executable."
        case .requirementsChecksumMismatch: return "Bundled Python requirements did not match the manifest checksum."
        case .processFailed(let argv, let status, _): return "Managed Python command \(argv.first ?? "process") failed with exit status \(status)."
        case .invalidInventory(let reason):
            return "Managed Python installation did not return a valid installed-file inventory. \(reason)"
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
        firstFailedCondition(spec: spec, environmentURL: environmentURL) == nil
    }

    /// The first condition `validates` fails, in words, or nil when the receipt validates.
    public func firstFailedCondition(spec: ManagedPythonRuntimeSpec, environmentURL: URL) -> String? {
        if schemaVersion != Self.schemaVersion { return "The receipt schema is \(schemaVersion), not \(Self.schemaVersion)." }
        if requested != spec { return "The receipt names another runtime request." }
        if exitStatus != 0 { return "The receipt exit status is \(exitStatus)." }
        if versionProbe.exitStatus != 0 { return "The --version probe exited \(versionProbe.exitStatus)." }
        if helpProbe.exitStatus != 0 { return "The --help probe exited \(helpProbe.exitStatus)." }
        if !versionProbe.output.localizedCaseInsensitiveContains(spec.distributionName) {
            return "The --version output does not name \(spec.distributionName). It reads \"\(Self.excerpt(versionProbe.output))\"."
        }
        if !versionProbe.output.contains(spec.version) {
            return "The --version output does not hold \(spec.version). It reads \"\(Self.excerpt(versionProbe.output))\"."
        }
        if helpProbe.output.isEmpty { return "The --help output is empty." }
        if !spec.matches(pythonVersion: pythonVersion) { return "Python \(pythonVersion) does not match \(spec.pythonABI)." }
        if let failed = commands.first(where: { $0.exitStatus != 0 }) {
            return "The command \(failed.argv.first ?? "process") exited \(failed.exitStatus)."
        }
        if commands.isEmpty { return "The receipt records no command." }
        if downloadedWheels.isEmpty { return "The receipt records no downloaded wheel." }
        if installedDistributions.isEmpty { return "The inventory lists no installed distribution." }
        if installedFiles.isEmpty { return "The inventory lists no installed file." }
        if requirements.sha256 != spec.requirementsSHA256 { return "The recorded requirements hash is not the manifest's." }
        if let source = spec.releaseWheelSource, !downloadedWheels.contains(where: {
            $0.relativePath.hasSuffix("/\(source.url.lastPathComponent)") && $0.sha256 == source.sha256
        }) {
            return "The downloaded wheels lack \(source.url.lastPathComponent) with its pinned hash."
        }
        let currentConda = Set(Self.condaRecords(in: environmentURL))
        if let gone = condaPackages.first(where: { !currentConda.contains($0) }) {
            return "The conda record \(gone.name)=\(gone.version)=\(gone.build) is no longer in conda-meta."
        }
        if let missing = spec.basePackageSpecs.first(where: { !Self.condaRecord(in: currentConda, matches: $0) }) {
            let name = Self.unchanneled(missing).split(separator: "=").first.map(String.init) ?? missing
            let found = currentConda.filter { $0.name == name }.map { "\($0.name)=\($0.version)=\($0.build)" }.sorted()
            return "No conda record matches \(missing). conda-meta holds \(found.isEmpty ? "none" : found.joined(separator: ", "))."
        }
        if let mismatch = Self.fileMismatch(requirements, environmentURL: environmentURL) { return "The requirements file \(mismatch)" }
        guard let requirementsData = try? Data(
            contentsOf: environmentURL.appendingPathComponent(requirements.relativePath)) else {
            return "The requirements file cannot be read."
        }
        let pinned = Self.lockedDistributions(in: requirementsData)
        let installed = Set(installedDistributions)
        if pinned != installed {
            let words = { (set: Set<DistributionRecord>) -> String in
                set.isEmpty ? "none" : set.map { "\($0.name)==\($0.version)" }.sorted().prefix(5).joined(separator: ", ")
            }
            return "The pins and the installed distributions differ. Pinned only \(words(pinned.subtracting(installed)))."
                + " Installed only \(words(installed.subtracting(pinned)))."
        }
        for record in downloadedWheels + installedFiles {
            if let mismatch = Self.fileMismatch(record, environmentURL: environmentURL) { return "The file \(mismatch)" }
        }
        return nil
    }

    private static func excerpt(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(160))
    }

    func replacingInstalledFiles(_ replacements: [FileRecord], environmentURL: URL? = nil) -> Self {
        let replacedPaths = Set(replacements.map(\.relativePath))
        return Self(
            requested: requested,
            environmentPath: environmentURL?.standardizedFileURL.path ?? environmentPath,
            pythonVersion: pythonVersion,
            condaPackages: condaPackages,
            requirements: requirements,
            downloadedWheels: downloadedWheels,
            installedDistributions: installedDistributions,
            installedFiles: installedFiles.filter { !replacedPaths.contains($0.relativePath) } + replacements,
            commands: commands,
            versionProbe: versionProbe,
            helpProbe: helpProbe,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTimeSeconds: wallTimeSeconds,
            exitStatus: exitStatus,
            stderr: stderr
        )
    }

    func tracksInstalledFile(relativePath: String) -> Bool {
        installedFiles.contains { $0.relativePath == relativePath }
    }

    static func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func fileRecord(for url: URL, relativeTo root: URL) throws -> FileRecord {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            throw ManagedPythonRuntimeInstallerError.invalidInventory("The file \(path) lies outside the environment.")
        }
        let relative = String(path.dropFirst(rootPath.count))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard validRelativePath(relative), values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else {
            throw ManagedPythonRuntimeInstallerError.invalidInventory(
                "The file \(relative) is a symbolic link, not a regular file or not a safe relative path.")
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

    private static func unchanneled(_ spec: String) -> String {
        spec.split(separator: ":").last.map(String.init) ?? spec
    }

    private static func condaRecord(in records: Set<CondaRecord>, matches spec: String) -> Bool {
        let fields = unchanneled(spec).split(separator: "=", omittingEmptySubsequences: false).map(String.init)
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

    /// Why the file on disk does not match its record, as the end of a sentence that starts with the path, or nil.
    private static func fileMismatch(_ record: FileRecord, environmentURL: URL) -> String? {
        let path = record.relativePath
        guard validRelativePath(path) else { return "\(path) is not a safe relative path." }
        if hasSymbolicLinkAncestor(relativePath: path, environmentURL: environmentURL) {
            return "\(path) has a symbolic link or a missing folder among its parents."
        }
        let url = environmentURL.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return "\(path) is missing or not a regular file." }
        if size.uint64Value != record.sizeBytes {
            return "\(path) holds \(size.uint64Value) bytes, not the recorded \(record.sizeBytes)."
        }
        return sha256(url) == record.sha256 ? nil : "\(path) does not match its recorded sha256."
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
            guard let url = Self.bundledRequirementsURL(named: name) else {
                throw ManagedPythonRuntimeInstallerError.invalidInventory(
                    "The bundled resource ManagedTools/\(name) was not found.")
            }
            return try Data(contentsOf: url)
        }
        self.commandRunner = commandRunner ?? Self.run
        self.now = now
    }

    /// The bundled requirements file. A CLI outside an app bundle, such as the `.build/debug/lungfish-cli` that
    /// `scripts/deps/verify.sh` runs, finds no resource root, so a debug build reads the source tree as
    /// `ManagedToolLock.resourceURL()` does (PF11).
    static func bundledRequirementsURL(
        named name: String,
        locate: (String) -> URL? = { RuntimeResourceLocator.path($0, in: .workflow) }
    ) -> URL? {
        if let url = locate("ManagedTools/\(name)") { return url }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ManagedTools/\(name)")
        if FileManager.default.fileExists(atPath: source.path) { return source }
        #endif
        return nil
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
        let runClock = ProvenanceRunClock(startedAt: now())
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
        if let source = spec.releaseWheelSource,
           !Self.requirementsContainPinnedWheel(
            requirementsData,
            contain: spec.distributionName,
            version: spec.version,
            sha256: source.sha256) {
            throw ManagedPythonRuntimeInstallerError.invalidInventory(
                "The bundled requirements do not pin \(spec.distributionName)==\(spec.version) with the release wheel hash.")
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
        var downloadArguments = ["download", "--require-hashes", "--only-binary=:all:", "--no-deps"]
        if let source = spec.releaseWheelSource {
            downloadArguments += ["--find-links", source.url.absoluteString]
        }
        downloadArguments += ["--dest", wheelhouse.path, "-r", requirementsURL.path]
        _ = try await execute(pip + downloadArguments)
        _ = try await execute(pip + ["install", "--require-hashes", "--no-index", "--no-deps", "--force-reinstall", "--find-links", wheelhouse.path, "-r", requirementsURL.path])
        _ = try await execute(pip + ["check"])
        if PrimerToolPortableLauncher.supports(toolID: executableName) {
            try PrimerToolPortableLauncher.prepare(toolID: executableName, environmentURL: root)
        }
        let inventoryResult = try await execute([
            python.path, "-I", "-c", Self.inventoryScript, root.path, requirementsURL.path,
        ])
        struct Inventory: Decodable {
            let distributions: [ManagedPythonRuntimeReceipt.DistributionRecord]
            let files: [ManagedPythonRuntimeReceipt.FileRecord]
        }
        let inventory: Inventory
        do {
            inventory = try JSONDecoder().decode(Inventory.self, from: Data(inventoryResult.stdout.utf8))
        } catch {
            throw ManagedPythonRuntimeInstallerError.invalidInventory(
                "The inventory output of \(inventoryResult.stdout.utf8.count) bytes does not decode. "
                    + String(String(describing: error).prefix(300)))
        }
        if let unsafe = inventory.files.first(where: { !ManagedPythonRuntimeReceipt.validRelativePath($0.relativePath) }) {
            throw ManagedPythonRuntimeInstallerError.invalidInventory(
                "The inventory lists the unsafe path \(unsafe.relativePath).")
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
        guard !wheels.isEmpty else {
            throw ManagedPythonRuntimeInstallerError.invalidInventory("The wheelhouse holds no .whl file.")
        }
        if let source = spec.releaseWheelSource {
            guard wheels.contains(where: {
                $0.relativePath.hasSuffix("/\(source.url.lastPathComponent)")
                    && $0.sha256 == source.sha256
            }) else {
                throw ManagedPythonRuntimeInstallerError.invalidInventory(
                    "The wheelhouse lacks \(source.url.lastPathComponent) with its pinned hash.")
            }
        }
        let completed = runClock.now
        try Task.checkCancellation()
        let portableArtifacts = try PrimerToolPortableLauncher.supports(toolID: executableName)
            ? PrimerToolPortableLauncher.artifacts(toolID: executableName, environmentURL: root).map {
                ManagedPythonRuntimeReceipt.FileRecord(
                    relativePath: $0.relativePath, sha256: $0.sha256, sizeBytes: $0.sizeBytes)
            }
            : []
        let receipt = ManagedPythonRuntimeReceipt(
            requested: spec, environmentPath: root.path,
            pythonVersion: Self.pythonVersion(from: ManagedPythonRuntimeReceipt.condaRecords(in: root)),
            condaPackages: ManagedPythonRuntimeReceipt.condaRecords(in: root),
            requirements: try ManagedPythonRuntimeReceipt.fileRecord(for: requirementsURL, relativeTo: root),
            downloadedWheels: wheels, installedDistributions: inventory.distributions,
            installedFiles: inventory.files.filter {
                !Set(portableArtifacts.map(\.relativePath)).contains($0.relativePath)
            } + portableArtifacts,
            commands: records,
            versionProbe: .init(argv: versionArgv, exitStatus: version.exitStatus, output: version.stdout + version.stderr),
            helpProbe: .init(argv: helpArgv, exitStatus: help.exitStatus, output: help.stdout + help.stderr),
            startedAt: runClock.startedAt, completedAt: completed,
            wallTimeSeconds: completed.timeIntervalSince(runClock.startedAt), stderr: stderr)
        if let failure = receipt.firstFailedCondition(spec: spec, environmentURL: root) {
            throw ManagedPythonRuntimeInstallerError.invalidInventory("The receipt check failed. \(failure)")
        }
        try receipt.write(to: receiptURL)
        return receipt
    }

    static func requirementsContainPinnedWheel(
        _ data: Data,
        contain distributionName: String,
        version: String,
        sha256: String
    ) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let expectedPin = "\(distributionName)==\(version)"
        let expectedHash = "--hash=sha256:\(sha256)"
        var logicalLines: [String] = []
        var current = ""
        for physicalLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = physicalLine.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            let continued = value.hasSuffix("\\")
            let segment = continued ? String(value.dropLast()).trimmingCharacters(in: .whitespaces) : value
            current += (current.isEmpty ? "" : " ") + segment
            if !continued {
                logicalLines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { logicalLines.append(current) }
        return logicalLines.contains { line in
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            return tokens.first == expectedPin && tokens.dropFirst().contains(expectedHash)
        }
    }

    private static func pythonVersion(from records: [ManagedPythonRuntimeReceipt.CondaRecord]) -> String {
        records.first { $0.name == "python" }?.version ?? "unknown"
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func run(_ argv: [String], workingDirectory: URL) async throws -> ManagedPythonRuntimeCommandResult {
        let runClock = ProvenanceRunClock()
        // Inventories can exceed 7 MB. Wait for both output streams to reach EOF;
        // a fixed post-exit delay can discard the JSON tail under load.
        let result = try await NativeToolRunner().runProcess(
            executableURL: URL(fileURLWithPath: argv[0]),
            arguments: Array(argv.dropFirst()),
            workingDirectory: workingDirectory,
            timeout: 3_600,
            toolName: "Managed Python runtime")
        return .init(
            exitStatus: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            wallTimeSeconds: runClock.elapsed)
    }
}
