@preconcurrency import Foundation
import CryptoKit
import Darwin

/// Persistent reproducibility receipt for a source-backed managed tool.
public struct ManagedToolSourceInstallationRecord: Sendable, Codable, Hashable {
    public static let maximumStderrLength = 16_384

    public struct Command: Sendable, Codable, Hashable {
        public let argv: [String]
        public let reproducibleCommand: String

        public init(argv: [String], reproducibleCommand: String) {
            self.argv = argv
            self.reproducibleCommand = reproducibleCommand
        }
    }

    public struct Runtime: Sendable, Codable, Hashable {
        /// Exact package records that supplied the compiler, Python, and OpenMP runtime.
        /// Keeping conda's build and platform fields makes a source build reproducible
        /// even when a version is republished with a different build string.
        public struct CondaPackage: Sendable, Codable, Hashable {
            public let name: String
            public let version: String
            public let build: String
            public let subdir: String

            public init(name: String, version: String, build: String, subdir: String) {
                self.name = name
                self.version = version
                self.build = build
                self.subdir = subdir
            }
        }

        public let environmentPath: String
        public let compilerPath: String
        public let openMPRuntimePath: String
        public let condaPackages: [CondaPackage]

        public init(
            environmentPath: String,
            compilerPath: String,
            openMPRuntimePath: String,
            condaPackages: [CondaPackage] = []
        ) {
            self.environmentPath = environmentPath
            self.compilerPath = compilerPath
            self.openMPRuntimePath = openMPRuntimePath
            self.condaPackages = condaPackages
        }
    }

    public struct InstalledFile: Sendable, Codable, Hashable {
        public let relativePath: String
        public let sha256: String
        public let sizeBytes: UInt64

        public init(relativePath: String, sha256: String, sizeBytes: UInt64) {
            self.relativePath = relativePath
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }
    }

    public let source: PackToolSourceOverlay
    public let workflowName: String
    public let workflowVersion: String
    public let sourceArchiveSizeBytes: UInt64
    public let commands: [Command]
    public let runtime: Runtime
    public let installedFiles: [InstalledFile]
    public let startedAt: Date
    public let completedAt: Date
    public let wallTimeSeconds: Double?
    public let exitStatus: Int32
    public let stderr: String

    public init(
        source: PackToolSourceOverlay,
        workflowName: String = "ManagedToolSourceInstaller",
        workflowVersion: String = WorkflowRun.currentAppVersion,
        sourceArchiveSizeBytes: UInt64 = 0,
        commands: [Command],
        runtime: Runtime,
        installedFiles: [InstalledFile],
        startedAt: Date,
        completedAt: Date,
        wallTimeSeconds: Double?,
        exitStatus: Int32,
        stderr: String
    ) {
        self.source = source
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.sourceArchiveSizeBytes = sourceArchiveSizeBytes
        self.commands = commands
        self.runtime = runtime
        self.installedFiles = installedFiles
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wallTimeSeconds = wallTimeSeconds
        self.exitStatus = exitStatus
        self.stderr = String(stderr.prefix(Self.maximumStderrLength))
    }

    public static func load(from url: URL) throws -> ManagedToolSourceInstallationRecord {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func validates(sourceOverlay: PackToolSourceOverlay, environmentURL: URL) -> Bool {
        guard source == sourceOverlay else { return false }
        return validatesIntegrity(environmentURL: environmentURL)
    }

    public func validatesIntegrity(environmentURL: URL) -> Bool {
        guard workflowName == "ManagedToolSourceInstaller",
              !workflowVersion.isEmpty,
              source.sourceURL.scheme?.lowercased() == "https",
              source.sha256.count == 64,
              source.sha256.allSatisfy({ $0.isHexDigit }),
              exitStatus == 0,
              !commands.isEmpty,
              !installedFiles.isEmpty else { return false }
        if source.kind == .bracken {
            let paths = Set(installedFiles.map(\.relativePath))
            guard ["bin/bracken", "bin/bracken-build", "bin/src/kmer2read_distr"].allSatisfy(paths.contains) else {
                return false
            }
            let runtimePackageNames = Set(runtime.condaPackages.map(\.name))
            guard ["python", "cxx-compiler", "llvm-openmp"].allSatisfy(runtimePackageNames.contains),
                  runtime.condaPackages.allSatisfy({
                      !$0.name.isEmpty && !$0.version.isEmpty && !$0.build.isEmpty && !$0.subdir.isEmpty
                  }) else {
                return false
            }
            guard validatesCurrentRuntime(environmentURL: environmentURL) else {
                return false
            }
        }
        for file in installedFiles {
            let url = environmentURL.appendingPathComponent(file.relativePath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.uint64Value == file.sizeBytes,
                  Self.sha256(of: url) == file.sha256 else {
                return false
            }
        }
        return true
    }

    /// Bind a durable receipt to the runtime that exists now, rather than only
    /// to the runtime fields captured when the overlay was originally built.
    /// Runtime paths are rebased from the historical environment root so an
    /// offline-imported environment remains portable while still being checked.
    private func validatesCurrentRuntime(environmentURL: URL) -> Bool {
        guard let compiler = rebasedRuntimePath(runtime.compilerPath, environmentURL: environmentURL),
              let openMP = rebasedRuntimePath(runtime.openMPRuntimePath, environmentURL: environmentURL),
              FileManager.default.isExecutableFile(atPath: compiler.path),
              Self.nonEmptyFileExists(at: openMP) else {
            return false
        }

        let currentPackages = Self.runtimePackages(in: environmentURL)
        return Set(runtime.condaPackages).isSubset(of: currentPackages)
    }

    private func rebasedRuntimePath(_ recordedPath: String, environmentURL: URL) -> URL? {
        let recordedEnvironment = URL(fileURLWithPath: runtime.environmentPath).standardizedFileURL
        let recorded = URL(fileURLWithPath: recordedPath).standardizedFileURL
        let rootPath = recordedEnvironment.path.hasSuffix("/")
            ? String(recordedEnvironment.path.dropLast())
            : recordedEnvironment.path
        guard recorded.path.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(recorded.path.dropFirst(rootPath.count + 1))
        guard !relativePath.isEmpty,
              !relativePath.split(separator: "/").contains("..") else {
            return nil
        }
        return environmentURL.standardizedFileURL.appendingPathComponent(relativePath)
    }

    private static func runtimePackages(
        in environmentURL: URL
    ) -> Set<Runtime.CondaPackage> {
        struct CondaMetaRecord: Decodable {
            let name: String?
            let version: String?
            let build: String?
            let subdir: String?
        }

        let metadataDirectory = environmentURL.appendingPathComponent("conda-meta", isDirectory: true)
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return Set(records.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(CondaMetaRecord.self, from: data),
                  let name = record.name, !name.isEmpty,
                  let version = record.version, !version.isEmpty,
                  let build = record.build, !build.isEmpty,
                  let subdir = record.subdir, !subdir.isEmpty else {
                return nil
            }
            return Runtime.CondaPackage(name: name, version: version, build: build, subdir: subdir)
        })
    }

    private static func nonEmptyFileExists(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.uint64Value > 0
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
