@preconcurrency import Foundation
import CryptoKit
import Darwin
import LungfishCore

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
        processRunner: @escaping ProcessRunner = { try await Self.run($0) },
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

    /// Runs each Bracken executable from its installed path. This is used for
    /// offline imports, which do not have to rely on a host-level PATH.
    public static func probeBrackenRuntime(
        in environmentURL: URL,
        timeout: TimeInterval = 30
    ) async throws -> [ManagedToolSourceRuntimeProbe] {
        let bin = environmentURL.appendingPathComponent("bin", isDirectory: true)
        let runtimeLibraryDirectory = environmentURL.appendingPathComponent("lib", isDirectory: true)
        let path = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        let probes: [(relativePath: String, arguments: [String])] = [
            ("bin/bracken", ["--help"]),
            ("bin/bracken-build", ["-v"]),
            ("bin/src/kmer2read_distr", ["--help"]),
        ]

        var results: [ManagedToolSourceRuntimeProbe] = []
        for probe in probes {
            let executable = environmentURL.appendingPathComponent(probe.relativePath)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ManagedToolSourceInstallerError.missingRequiredFile(probe.relativePath)
            }
            let result = try await run(
                .init(
                    executable: executable,
                    arguments: probe.arguments,
                    workingDirectory: environmentURL,
                    environment: [
                        "PATH": path,
                        "DYLD_LIBRARY_PATH": runtimeLibraryDirectory.path,
                    ]
                ),
                timeout: timeout
            )
            let runtimeProbe = ManagedToolSourceRuntimeProbe(
                executablePath: executable.path,
                arguments: probe.arguments,
                exitStatus: result.exitStatus,
                stderr: result.stderr
            )
            guard result.exitStatus == 0 else {
                throw ManagedToolSourceInstallerError.runtimeProbeFailed(runtimeProbe)
            }
            results.append(runtimeProbe)
        }
        return results
    }

    public func install(sourceOverlay: PackToolSourceOverlay, environmentURL: URL) async throws -> ManagedToolSourceInstallationRecord {
        guard sourceOverlay.kind == .bracken, sourceOverlay.sourceURL.scheme?.lowercased() == "https" else {
            throw ManagedToolSourceInstallerError.invalidSourceURL
        }
        let runClock = ProvenanceRunClock(startedAt: now())
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
        let typeListing = try await execute(tar, ["-tvzf", archive.path], workingDirectory: work, commands: &commands, stderrs: &stderrs, operation: "archive type inspection")
        try validateArchiveEntryTypes(typeListing.stdout)
        try Task.checkCancellation()

        let extracted = work.appendingPathComponent("extract", isDirectory: true)
        try fileSystem.createDirectory(extracted)
        _ = try await execute(tar, ["-xzf", archive.path, "-C", extracted.path], workingDirectory: work, commands: &commands, stderrs: &stderrs, operation: "archive extraction")
        let sourceRoot = extracted.appendingPathComponent("Bracken-3.1", isDirectory: true)
        try validateExtractedTree(sourceRoot)
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
        _ = try await execute(
            binary,
            ["--help"],
            workingDirectory: stagedSrc,
            environment: ["DYLD_LIBRARY_PATH": environmentURL.appendingPathComponent("lib").path],
            commands: &commands,
            stderrs: &stderrs,
            operation: "kmer2read_distr smoke test"
        )

        let installedFiles = try inventory(stagedEnvironment)
        let completedAt = runClock.now
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
            startedAt: runClock.startedAt,
            completedAt: completedAt,
            wallTimeSeconds: completedAt.timeIntervalSince(runClock.startedAt),
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
        environment: [String: String] = [:],
        commands: inout [ManagedToolSourceInstallationRecord.Command],
        stderrs: inout [String],
        operation: String
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let invocation = ProcessInvocation(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
        let result = try await processRunner(invocation)
        let environmentArguments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let reproducibleArguments = environmentArguments.isEmpty
            ? [executable.path] + arguments
            : ["/usr/bin/env"] + environmentArguments + [executable.path] + arguments
        commands.append(.init(
            argv: [executable.path] + arguments,
            reproducibleCommand: shellCommand(reproducibleArguments)
        ))
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

    private func validateArchiveEntryTypes(_ stdout: String) throws {
        for line in stdout.split(whereSeparator: \.isNewline) {
            guard let type = line.first, type == "-" || type == "d" else {
                throw ManagedToolSourceInstallerError.unsafeArchiveMember(String(line))
            }
        }
    }

    private func validateExtractedTree(_ root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: rootPath) else {
            throw ManagedToolSourceInstallerError.missingRequiredFile("Bracken-3.1")
        }
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            var node = stat()
            guard lstat(url.path, &node) == 0 else {
                throw ManagedToolSourceInstallerError.unsafeArchiveMember(url.path)
            }
            let nodeType = node.st_mode & S_IFMT
            guard nodeType == S_IFREG || nodeType == S_IFDIR else {
                throw ManagedToolSourceInstallerError.unsafeArchiveMember(url.path)
            }
            let resolvedPath = url.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(rootPrefix) else {
                throw ManagedToolSourceInstallerError.unsafeArchiveMember(url.path)
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
            let originalError = error
            var recoveryErrors: [String] = []
            for path in published.reversed() {
                let destination = environmentURL.appendingPathComponent(path)
                do {
                    try fileSystem.removeItem(destination)
                } catch {
                    recoveryErrors.append("Could not remove partial \(destination.path): \(error.localizedDescription)")
                }
            }
            for path in paths.reversed() {
                let prior = backup.appendingPathComponent(path)
                if fileSystem.fileExists(prior) {
                    let destination = environmentURL.appendingPathComponent(path)
                    do {
                        try fileSystem.createDirectory(destination.deletingLastPathComponent())
                        try fileSystem.moveItem(prior, destination)
                    } catch {
                        recoveryErrors.append("Could not restore \(prior.path): \(error.localizedDescription)")
                    }
                }
            }
            guard recoveryErrors.isEmpty else {
                throw ManagedToolSourceInstallerError.publicationRecoveryFailed(
                    backupPath: backup.path,
                    originalError: originalError.localizedDescription,
                    recoveryError: recoveryErrors.joined(separator: " ")
                )
            }
            try? fileSystem.removeItem(backup)
            throw originalError
        }
    }

    public static func download(source: URL, destination: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: source)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Runs one build or probe step through ``ToolProcess``, which reads both
    /// streams while it runs and stops its whole process tree on cancellation
    /// or timeout. A cancellation throws `CancellationError`, a timeout throws
    /// ``ManagedToolSourceInstallerError/processTimedOut(seconds:)``, and
    /// output that a child process still held open after the step exited
    /// throws ``CondaError/executionFailed(tool:exitCode:stderr:)``.
    public static func run(
        _ invocation: ProcessInvocation,
        timeout: TimeInterval = 3_600
    ) async throws -> ProcessResult {
        guard timeout > 0 else {
            throw ManagedToolSourceInstallerError.processTimedOut(seconds: timeout)
        }
        try Task.checkCancellation()
        let spec = ToolProcessSpec(
            executableURL: invocation.executable,
            arguments: invocation.arguments,
            environment: ToolProcessSpec.inheritedEnvironment(overriding: invocation.environment),
            workingDirectory: invocation.workingDirectory,
            timeout: CondaFamilyProcess.limit(seconds: timeout),
            terminationGracePeriod: CondaFamilyProcess.terminationGracePeriod
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch ToolProcessError.timedOut {
            throw ManagedToolSourceInstallerError.processTimedOut(seconds: timeout)
        } catch ToolProcessError.cancelled {
            throw CancellationError()
        }
        let stderr = result.stderrText
        if let reason = result.incompleteOutputReason {
            throw CondaError.executionFailed(
                tool: spec.label,
                exitCode: result.status,
                stderr: stderr.isEmpty ? reason : "\(reason)\n\(stderr)"
            )
        }
        return .init(
            exitStatus: result.status,
            stdout: result.stdoutText,
            stderr: stderr
        )
    }

    private func shellCommand(_ argv: [String]) -> String {
        argv.map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
        }.joined(separator: " ")
    }
}
