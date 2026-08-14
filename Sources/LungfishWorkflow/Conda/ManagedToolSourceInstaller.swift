@preconcurrency import Foundation
import CryptoKit

public enum ManagedToolSourceInstallerError: Error, LocalizedError, Sendable, Equatable {
    case invalidSourceURL
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchiveMember(String)
    case missingRequiredFile(String)
    case processFailed(operation: String, exitStatus: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return "Managed tool sources must use HTTPS URLs."
        case .checksumMismatch:
            return "Downloaded managed tool source did not match its pinned SHA-256 checksum."
        case .unsafeArchiveMember(let member):
            return "Managed tool archive contains an unsafe member path: \(member)"
        case .missingRequiredFile(let path):
            return "Managed tool archive is missing required file: \(path)"
        case .processFailed(let operation, let status, _):
            return "Managed tool \(operation) failed with exit status \(status)."
        }
    }
}

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

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Injectable filesystem operations. The live implementation intentionally uses
/// only paths supplied by the installer so failed source builds never touch a
/// prior published overlay.
public struct ManagedToolSourceFileSystem: Sendable {
    public var createDirectory: @Sendable (URL) throws -> Void
    public var copyItem: @Sendable (URL, URL) throws -> Void
    public var moveItem: @Sendable (URL, URL) throws -> Void
    public var removeItem: @Sendable (URL) throws -> Void
    public var fileExists: @Sendable (URL) -> Bool
    public var isExecutable: @Sendable (URL) -> Bool
    public var contents: @Sendable (URL) throws -> [URL]

    public init(
        createDirectory: @escaping @Sendable (URL) throws -> Void,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void,
        moveItem: @escaping @Sendable (URL, URL) throws -> Void,
        removeItem: @escaping @Sendable (URL) throws -> Void,
        fileExists: @escaping @Sendable (URL) -> Bool,
        isExecutable: @escaping @Sendable (URL) -> Bool,
        contents: @escaping @Sendable (URL) throws -> [URL]
    ) {
        self.createDirectory = createDirectory
        self.copyItem = copyItem
        self.moveItem = moveItem
        self.removeItem = removeItem
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.contents = contents
    }

    public static let live = ManagedToolSourceFileSystem(
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
        contents: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
    )
}

public struct ManagedToolSourceInstaller: Sendable {
    public struct ProcessInvocation: Sendable, Hashable {
        public let executable: URL
        public let arguments: [String]
        public let workingDirectory: URL?
        public let environment: [String: String]

        public init(executable: URL, arguments: [String], workingDirectory: URL? = nil, environment: [String: String] = [:]) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
        }
    }

    public struct ProcessResult: Sendable, Hashable {
        public let exitStatus: Int32
        public let stdout: String
        public let stderr: String

        public init(exitStatus: Int32, stdout: String, stderr: String) {
            self.exitStatus = exitStatus
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public typealias Downloader = @Sendable (_ source: URL, _ destination: URL) async throws -> Void
    public typealias ProcessRunner = @Sendable (_ invocation: ProcessInvocation) async throws -> ProcessResult

    private let downloader: Downloader
    private let processRunner: ProcessRunner
    private let fileSystem: ManagedToolSourceFileSystem
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    public init(
        downloader: @escaping Downloader = Self.download,
        processRunner: @escaping ProcessRunner = Self.run,
        fileSystem: ManagedToolSourceFileSystem = .live,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.downloader = downloader
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.now = now
        self.uuid = uuid
    }

    public func install(sourceOverlay: PackToolSourceOverlay, environmentURL: URL) async throws -> ManagedToolSourceInstallationRecord {
        guard sourceOverlay.kind == .bracken, sourceOverlay.sourceURL.scheme?.lowercased() == "https" else {
            throw ManagedToolSourceInstallerError.invalidSourceURL
        }
        let startedAt = now()
        let work = environmentURL.deletingLastPathComponent().appendingPathComponent(".managed-bracken-\(uuid().uuidString)", isDirectory: true)
        defer { try? fileSystem.removeItem(work) }
        try fileSystem.createDirectory(work)
        let archive = work.appendingPathComponent("source.tar.gz")
        try await downloader(sourceOverlay.sourceURL, archive)
        try Task.checkCancellation()

        let actualSHA = try checksum(of: archive)
        guard actualSHA == sourceOverlay.sha256.lowercased() else {
            throw ManagedToolSourceInstallerError.checksumMismatch(expected: sourceOverlay.sha256, actual: actualSHA)
        }

        var commands: [ManagedToolSourceInstallationRecord.Command] = [
            .init(
                argv: ["URLSession.download", sourceOverlay.sourceURL.absoluteString, archive.path],
                reproducibleCommand: "curl --fail --location \(shellCommand([sourceOverlay.sourceURL.absoluteString]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))) --output \(shellCommand([archive.path]))"
            ),
        ]
        var stderrs: [String] = []
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let listingArgs = ["-tzf", archive.path]
        let listing = try await execute(tar, listingArgs, workingDirectory: work, commands: &commands, stderrs: &stderrs, operation: "archive inspection")
        try validateArchiveMembers(listing.stdout)
        try Task.checkCancellation()

        let extracted = work.appendingPathComponent("extract", isDirectory: true)
        try fileSystem.createDirectory(extracted)
        _ = try await execute(tar, ["-xzf", archive.path, "-C", extracted.path], workingDirectory: work, commands: &commands, stderrs: &stderrs, operation: "archive extraction")
        let sourceRoot = extracted.appendingPathComponent("Bracken-3.1", isDirectory: true)
        let requiredFiles = [
            "bracken", "bracken-build", "src/kmer2read_distr.cpp", "src/ctime.cpp", "src/kraken_processing.cpp", "src/taxonomy.cpp",
            "src/est_abundance.py", "src/generate_kmer_distribution.py",
        ]
        for required in requiredFiles {
            let url = sourceRoot.appendingPathComponent(required)
            guard regularFileExists(at: url) else {
                throw ManagedToolSourceInstallerError.missingRequiredFile(required)
            }
        }

        let stagedEnvironment = work.appendingPathComponent("publish", isDirectory: true)
        let stagedBin = stagedEnvironment.appendingPathComponent("bin", isDirectory: true)
        let stagedSrc = stagedBin.appendingPathComponent("src", isDirectory: true)
        try fileSystem.createDirectory(stagedSrc)
        try fileSystem.copyItem(sourceRoot.appendingPathComponent("bracken"), stagedBin.appendingPathComponent("bracken"))
        try fileSystem.copyItem(sourceRoot.appendingPathComponent("bracken-build"), stagedBin.appendingPathComponent("bracken-build"))
        for entry in try fileSystem.contents(sourceRoot.appendingPathComponent("src", isDirectory: true)) {
            try fileSystem.copyItem(entry, stagedSrc.appendingPathComponent(entry.lastPathComponent))
        }

        let compiler = managedCompiler(in: environmentURL)
        let openMP = environmentURL.appendingPathComponent("lib/libomp.dylib")
        let binary = stagedSrc.appendingPathComponent("kmer2read_distr")
        let compileArgs = [
            "-O3", "-std=c++11", "-Xpreprocessor", "-fopenmp",
            stagedSrc.appendingPathComponent("kmer2read_distr.cpp").path,
            stagedSrc.appendingPathComponent("ctime.cpp").path,
            stagedSrc.appendingPathComponent("kraken_processing.cpp").path,
            stagedSrc.appendingPathComponent("taxonomy.cpp").path,
            "-L", environmentURL.appendingPathComponent("lib").path,
            "-lomp", "-Wl,-rpath,@loader_path/../../lib", "-o", binary.path,
        ]
        _ = try await execute(compiler, compileArgs, workingDirectory: stagedSrc, commands: &commands, stderrs: &stderrs, operation: "Bracken compiler")
        try Task.checkCancellation()

        _ = try await execute(stagedBin.appendingPathComponent("bracken"), ["--help"], workingDirectory: stagedBin, commands: &commands, stderrs: &stderrs, operation: "bracken smoke test")
        _ = try await execute(stagedBin.appendingPathComponent("bracken-build"), ["-v"], workingDirectory: stagedBin, commands: &commands, stderrs: &stderrs, operation: "bracken-build smoke test")
        _ = try await execute(binary, ["--help"], workingDirectory: stagedSrc, commands: &commands, stderrs: &stderrs, operation: "kmer2read_distr smoke test")

        let installedFiles = try inventory(stagedEnvironment)
        let completedAt = now()
        let record = ManagedToolSourceInstallationRecord(
            source: sourceOverlay,
            sourceArchiveSizeBytes: fileSize(archive),
            commands: commands,
            runtime: .init(
                environmentPath: environmentURL.path,
                compilerPath: compiler.path,
                openMPRuntimePath: openMP.path,
                condaPackages: runtimePackages(in: environmentURL)
            ),
            installedFiles: installedFiles,
            startedAt: startedAt,
            completedAt: completedAt,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            stderr: stderrs.joined(separator: "\n")
        )
        let stagedRecord = stagedEnvironment.appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        try record.write(to: stagedRecord)
        try publish(stagedEnvironment, to: environmentURL)
        return record
    }

    private func execute(
        _ executable: URL,
        _ arguments: [String],
        workingDirectory: URL,
        commands: inout [ManagedToolSourceInstallationRecord.Command],
        stderrs: inout [String],
        operation: String
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let invocation = ProcessInvocation(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        let result = try await processRunner(invocation)
        commands.append(.init(argv: [executable.path] + arguments, reproducibleCommand: shellCommand([executable.path] + arguments)))
        if !result.stderr.isEmpty { stderrs.append(result.stderr) }
        guard result.exitStatus == 0 else {
            throw ManagedToolSourceInstallerError.processFailed(operation: operation, exitStatus: result.exitStatus, stderr: String(result.stderr.prefix(ManagedToolSourceInstallationRecord.maximumStderrLength)))
        }
        return result
    }

    private func validateArchiveMembers(_ stdout: String) throws {
        for rawMember in stdout.split(whereSeparator: \.isNewline).map(String.init) where !rawMember.isEmpty {
            let member = rawMember.hasSuffix("/") ? String(rawMember.dropLast()) : rawMember
            let components = member.split(separator: "/", omittingEmptySubsequences: false)
            guard !member.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
                throw ManagedToolSourceInstallerError.unsafeArchiveMember(rawMember)
            }
        }
    }

    private func regularFileExists(at url: URL) -> Bool {
        guard fileSystem.fileExists(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    private func checksum(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func managedCompiler(in environmentURL: URL) -> URL {
        let bin = environmentURL.appendingPathComponent("bin", isDirectory: true)
        let conventional = bin.appendingPathComponent("c++")
        if fileSystem.isExecutable(conventional) { return conventional }
        let compiler = (try? fileSystem.contents(bin))?.first {
            $0.lastPathComponent.hasSuffix("-c++") || $0.lastPathComponent.hasSuffix("-clang++")
        }
        return compiler ?? conventional
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    private func runtimePackages(
        in environmentURL: URL
    ) -> [ManagedToolSourceInstallationRecord.Runtime.CondaPackage] {
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

        return records
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(CondaMetaRecord.self, from: data),
                      let name = record.name, !name.isEmpty,
                      let version = record.version, !version.isEmpty,
                      let build = record.build, !build.isEmpty,
                      let subdir = record.subdir, !subdir.isEmpty else {
                    return nil
                }
                return .init(name: name, version: version, build: build, subdir: subdir)
            }
            .sorted { lhs, rhs in
                (lhs.name, lhs.version, lhs.build, lhs.subdir) < (rhs.name, rhs.version, rhs.build, rhs.subdir)
            }
    }

    private func inventory(_ root: URL) throws -> [ManagedToolSourceInstallationRecord.InstalledFile] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        let resolvedRootPrefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        var files: [ManagedToolSourceInstallationRecord.InstalledFile] = []
        while let url = enumerator?.nextObject() as? URL {
            guard regularFileExists(at: url), let checksum = ManagedToolSourceInstallationRecord.sha256(of: url) else { continue }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(resolvedRootPrefix) else {
                throw ManagedToolSourceInstallerError.unsafeArchiveMember(url.path)
            }
            let relative = String(resolvedPath.dropFirst(resolvedRootPrefix.count))
            files.append(.init(relativePath: relative, sha256: checksum, sizeBytes: size))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func publish(_ staged: URL, to environmentURL: URL) throws {
        try fileSystem.createDirectory(environmentURL)
        let backup = environmentURL.deletingLastPathComponent().appendingPathComponent(".managed-bracken-backup-\(uuid().uuidString)", isDirectory: true)
        try fileSystem.createDirectory(backup)
        let paths = ["bin/bracken", "bin/bracken-build", "bin/src", "share/lungfish/managed-tools/bracken.json"]
        var published: [String] = []
        do {
            for path in paths {
                let destination = environmentURL.appendingPathComponent(path)
                if fileSystem.fileExists(destination) {
                    let backupDestination = backup.appendingPathComponent(path)
                    try fileSystem.createDirectory(backupDestination.deletingLastPathComponent())
                    try fileSystem.moveItem(destination, backupDestination)
                }
                let source = staged.appendingPathComponent(path)
                try fileSystem.createDirectory(destination.deletingLastPathComponent())
                try fileSystem.moveItem(source, destination)
                published.append(path)
            }
            try? fileSystem.removeItem(backup)
        } catch {
            for path in published.reversed() {
                let destination = environmentURL.appendingPathComponent(path)
                try? fileSystem.removeItem(destination)
            }
            for path in paths.reversed() {
                let prior = backup.appendingPathComponent(path)
                if fileSystem.fileExists(prior) {
                    let destination = environmentURL.appendingPathComponent(path)
                    try? fileSystem.createDirectory(destination.deletingLastPathComponent())
                    try? fileSystem.moveItem(prior, destination)
                }
            }
            try? fileSystem.removeItem(backup)
            throw error
        }
    }

    public static func download(source: URL, destination: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: source)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        try data.write(to: destination, options: .atomic)
    }

    public static func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.currentDirectoryURL = invocation.workingDirectory
            process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, replacement in replacement }
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            return ProcessResult(
                exitStatus: process.terminationStatus,
                stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }.value
    }

    private func shellCommand(_ argv: [String]) -> String {
        argv.map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
        }.joined(separator: " ")
    }
}
