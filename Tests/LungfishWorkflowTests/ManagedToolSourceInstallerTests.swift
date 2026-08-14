import XCTest
import CryptoKit
import Darwin
@testable import LungfishWorkflow

final class ManagedToolSourceInstallerTests: XCTestCase {
    func testLivePinnedBrackenOverlayAndOfflineRoundTrip() async throws {
        guard let environmentPath = ProcessInfo.processInfo.environment["LUNGFISH_LIVE_BRACKEN_ENV"],
              let proofPath = ProcessInfo.processInfo.environment["LUNGFISH_LIVE_BRACKEN_PROOF"] else {
            throw XCTSkip("Set LUNGFISH_LIVE_BRACKEN_ENV and LUNGFISH_LIVE_BRACKEN_PROOF to run the live proof")
        }
        let environmentURL = URL(fileURLWithPath: environmentPath, isDirectory: true)
        let proofRoot = URL(fileURLWithPath: proofPath, isDirectory: true)
        let metagenomicsPack = try XCTUnwrap(PluginPack.activeOptionalPacks.first { $0.id == "metagenomics" })
        let requirement = try XCTUnwrap(metagenomicsPack.toolRequirements.first { $0.id == "bracken" })
        let overlay = try XCTUnwrap(requirement.sourceOverlay)

        let record = try await ManagedToolSourceInstaller().install(
            sourceOverlay: overlay,
            environmentURL: environmentURL
        )
        XCTAssertTrue(record.validates(sourceOverlay: overlay, environmentURL: environmentURL))
        try await assertLiveBrackenProbes(in: environmentURL)

        let pack = PluginPack(
            id: "live-bracken-overlay",
            name: "Live Bracken Overlay",
            description: "Live managed-source round-trip proof",
            sfSymbol: "wrench",
            packages: ["bracken"],
            category: "Tests",
            requirements: [requirement]
        )
        let sourceCondaRoot = environmentURL.deletingLastPathComponent().deletingLastPathComponent()
        let exported = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: sourceCondaRoot,
            outputDirectory: proofRoot.appendingPathComponent("exports", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "export-pack", "--pack", pack.id]
        )
        let importedCondaRoot = proofRoot.appendingPathComponent("imported", isDirectory: true)
        _ = try await CondaOfflinePackService().installPack(
            from: exported.packDirectory,
            condaRoot: importedCondaRoot,
            overwrite: false,
            commandLine: ["lungfish-cli", "conda", "install", "--offline", "--from-bundle", exported.packDirectory.path]
        )
        let importedEnvironment = importedCondaRoot.appendingPathComponent("envs/bracken", isDirectory: true)
        let importedRecord = try ManagedToolSourceInstallationRecord.load(
            from: importedEnvironment.appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        )
        XCTAssertTrue(importedRecord.validates(sourceOverlay: overlay, environmentURL: importedEnvironment))
        try await assertLiveBrackenProbes(in: importedEnvironment)
    }

    func testSuccessfulBrackenInstallPublishesScriptsPayloadAndDurableRecord() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()

        let record = try await fixture.installer().install(
            sourceOverlay: fixture.overlay,
            environmentURL: fixture.environmentURL
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken-build").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.environmentURL.appendingPathComponent("bin/src/kmer2read_distr").path))
        XCTAssertEqual(record.source, fixture.overlay)
        XCTAssertEqual(record.exitStatus, 0)
        XCTAssertEqual(record.runtime.environmentPath, fixture.environmentURL.path)
        XCTAssertEqual(
            record.runtime.condaPackages,
            [
                .init(name: "cxx-compiler", version: "1.9.0", build: "h1", subdir: "osx-arm64"),
                .init(name: "llvm-openmp", version: "21.1.8", build: "h2", subdir: "osx-arm64"),
                .init(name: "python", version: "3.11.13", build: "h3", subdir: "osx-arm64"),
            ]
        )
        XCTAssertEqual(
            record.commands.map(\.argv),
            [
                ["URLSession.download", fixture.overlay.sourceURL.absoluteString, fixture.downloadDestinationPath],
                ["/usr/bin/tar", "-tzf", fixture.downloadDestinationPath],
                ["/usr/bin/tar", "-tvzf", fixture.downloadDestinationPath],
                ["/usr/bin/tar", "-xzf", fixture.downloadDestinationPath, "-C", fixture.extractedPath],
                [
                    fixture.environmentURL.appendingPathComponent("bin/c++").path,
                    "-O3", "-std=c++11", "-Xpreprocessor", "-fopenmp",
                    fixture.stagedSourcePath("kmer2read_distr.cpp"),
                    fixture.stagedSourcePath("ctime.cpp"),
                    fixture.stagedSourcePath("kraken_processing.cpp"),
                    fixture.stagedSourcePath("taxonomy.cpp"),
                    "-L", fixture.environmentURL.appendingPathComponent("lib").path,
                    "-lomp", "-Wl,-rpath,@loader_path/../../lib", "-o", fixture.stagedSourcePath("kmer2read_distr"),
                ],
                [fixture.stagedBinPath("bracken"), "--help"],
                [fixture.stagedBinPath("bracken-build"), "-v"],
                [fixture.stagedSourcePath("kmer2read_distr"), "--help"],
            ]
        )
        XCTAssertTrue(
            record.commands.last?.reproducibleCommand.contains(
                "DYLD_LIBRARY_PATH=\(fixture.environmentURL.appendingPathComponent("lib").path)"
            ) == true
        )
        XCTAssertTrue(record.installedFiles.allSatisfy { $0.sizeBytes > 0 && $0.sha256.count == 64 })
        XCTAssertNotNil(record.wallTimeSeconds)
        XCTAssertLessThanOrEqual(record.stderr.count, ManagedToolSourceInstallationRecord.maximumStderrLength)

        let recordURL = fixture.environmentURL
            .appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        XCTAssertEqual(try ManagedToolSourceInstallationRecord.load(from: recordURL), record)
    }

    func testChecksumMismatchPublishesNothing() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()

        let invalidOverlay = PackToolSourceOverlay(
            kind: .bracken,
            version: "3.1",
            sourceURL: fixture.overlay.sourceURL,
            sha256: String(repeating: "0", count: 64)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: invalidOverlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json").path))
    }

    func testUnsafeArchiveMemberIsRejectedBeforeExtraction() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        fixture.archiveListingOverride = "../escaped-file\n"

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escaped-file").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
    }

    func testCompileFailurePreservesPreviouslyPublishedOverlay() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()
        let priorBin = fixture.environmentURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: priorBin, withIntermediateDirectories: true)
        try Data("prior bracken\n".utf8).write(to: priorBin.appendingPathComponent("bracken"))
        fixture.compileShouldFail = true

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertEqual(try Data(contentsOf: priorBin.appendingPathComponent("bracken")), Data("prior bracken\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json").path))
    }

    func testCancellationPublishesNothing() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()
        fixture.cancelDuringCompile = true

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json").path))
    }

    func testIntegrityRejectsBrackenReceiptWithoutCompilerRuntimePackages() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()
        let record = try await fixture.installer().install(
            sourceOverlay: fixture.overlay,
            environmentURL: fixture.environmentURL
        )
        XCTAssertTrue(
            record.validatesIntegrity(environmentURL: fixture.environmentURL),
            "runtime=\(record.runtime.condaPackages) files=\(record.installedFiles) workflow=\(record.workflowVersion)"
        )
        let incompleteRuntimeRecord = ManagedToolSourceInstallationRecord(
            source: record.source,
            workflowName: record.workflowName,
            workflowVersion: record.workflowVersion,
            sourceArchiveSizeBytes: record.sourceArchiveSizeBytes,
            commands: record.commands,
            runtime: .init(
                environmentPath: record.runtime.environmentPath,
                compilerPath: record.runtime.compilerPath,
                openMPRuntimePath: record.runtime.openMPRuntimePath
            ),
            installedFiles: record.installedFiles,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            wallTimeSeconds: record.wallTimeSeconds,
            exitStatus: record.exitStatus,
            stderr: record.stderr
        )

        XCTAssertFalse(incompleteRuntimeRecord.validatesIntegrity(environmentURL: fixture.environmentURL))
    }

    func testLiveRunnerDrainsLargeStdoutAndStderrWithoutDeadlock() async throws {
        let invocation = ManagedToolSourceInstaller.ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 2048 ]; do printf 'stdout-abcdefghijklmnopqrstuvwxyz0123456789\\n'; printf 'stderr-abcdefghijklmnopqrstuvwxyz0123456789\\n' >&2; i=$((i + 1)); done"]
        )

        let result = try await ManagedToolSourceInstaller.run(invocation, timeout: 5)

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertGreaterThan(result.stdout.utf8.count, 64 * 1024)
        XCTAssertGreaterThan(result.stderr.utf8.count, 64 * 1024)
    }

    func testLiveRunnerCancellationTerminatesChildProcess() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        let childPIDFile = fixture.root.appendingPathComponent("child.pid")
        let invocation = ManagedToolSourceInstaller.ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "sleep 30 & child=$!; printf '%s' \"$child\" > \"$1\"; wait \"$child\"",
                "managed-tool-child",
                childPIDFile.path,
            ]
        )

        let task = Task { try await ManagedToolSourceInstaller.run(invocation, timeout: 30) }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await XCTAssertThrowsErrorAsync { _ = try await task.value }

        for _ in 0..<20 where kill(childPID, 0) == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotEqual(kill(childPID, 0), 0)
    }

    func testSymlinkArchiveMemberIsRejectedBeforeExtractionAndPublication() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeLinkArchive(kind: .symbolic)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
    }

    func testHardlinkArchiveMemberIsRejectedBeforeExtractionAndPublication() async throws {
        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeLinkArchive(kind: .hard)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.installer().install(sourceOverlay: fixture.overlay, environmentURL: fixture.environmentURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.environmentURL.appendingPathComponent("bin/bracken").path))
    }

    func testPublishRollbackRetainsBackupAndReportsRecoveryPathWhenRestoreFails() async throws {
        struct InjectedMoveFailure: Error {}

        let fixture = try SourceInstallerFixture()
        defer { fixture.cleanup() }
        try fixture.makeSafeArchive()
        let priorBracken = fixture.environmentURL.appendingPathComponent("bin/bracken")
        try FileManager.default.createDirectory(at: priorBracken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prior bracken\n".utf8).write(to: priorBracken)
        let backupURL = fixture.root.appendingPathComponent(".managed-bracken-backup-00000000-0000-0000-0000-000000000001")
        let fileSystem = ManagedToolSourceFileSystem(
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { source, destination in
                if source.path.contains("/publish/bin/bracken-build") {
                    throw InjectedMoveFailure()
                }
                if source == backupURL.appendingPathComponent("bin/bracken") {
                    throw InjectedMoveFailure()
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
            contents: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
        )

        do {
            _ = try await fixture.installer(fileSystem: fileSystem).install(
                sourceOverlay: fixture.overlay,
                environmentURL: fixture.environmentURL
            )
            XCTFail("Expected publication recovery failure")
        } catch let error as ManagedToolSourceInstallerError {
            guard case .publicationRecoveryFailed(let backupPath, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(backupPath, backupURL.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("bin/bracken").path))
    }
}

private final class SourceInstallerFixture: @unchecked Sendable {
    enum LinkKind { case symbolic, hard }
    let root: URL
    let environmentURL: URL
    let archiveURL: URL
    private(set) var overlay = PackToolSourceOverlay(
        kind: .bracken,
        version: "3.1",
        sourceURL: URL(string: "https://example.test/Bracken-v3.1.tar.gz")!,
        sha256: ""
    )
    var archiveListingOverride: String?
    var compileShouldFail = false
    var cancelDuringCompile = false

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedToolSourceInstallerTests-\(UUID().uuidString)", isDirectory: true)
        environmentURL = root.appendingPathComponent("env", isDirectory: true)
        archiveURL = root.appendingPathComponent("bracken-v3.1.tar.gz")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeSafeArchive() throws {
        let source = root.appendingPathComponent("Bracken-3.1", isDirectory: true)
        let src = source.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for script in ["bracken", "bracken-build"] {
            let url = source.appendingPathComponent(script)
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for script in ["est_abundance.py", "generate_kmer_distribution.py"] {
            try "#!/usr/bin/env python3\n".write(to: src.appendingPathComponent(script), atomically: true, encoding: .utf8)
        }
        for sourceFile in ["kmer2read_distr.cpp", "ctime.cpp", "kraken_processing.cpp", "taxonomy.cpp"] {
            try "int main() { return 0; }\n".write(
                to: src.appendingPathComponent(sourceFile),
                atomically: true,
                encoding: .utf8
            )
        }
        try archiveSourceTree()
        let condaMeta = environmentURL.appendingPathComponent("conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: condaMeta, withIntermediateDirectories: true)
        for package in [
            ("cxx-compiler", "1.9.0", "h1"),
            ("llvm-openmp", "21.1.8", "h2"),
            ("python", "3.11.13", "h3"),
        ] {
            let metadata = "{\"name\":\"\(package.0)\",\"version\":\"\(package.1)\",\"build\":\"\(package.2)\",\"subdir\":\"osx-arm64\"}"
            try metadata.write(
                to: condaMeta.appendingPathComponent("\(package.0)-\(package.1)-\(package.2).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        try refreshOverlayChecksum()
    }

    func makeLinkArchive(kind: LinkKind) throws {
        try makeSafeArchive()
        let linkURL = root.appendingPathComponent("Bracken-3.1/src/untrusted-link")
        switch kind {
        case .symbolic:
            try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "/tmp")
        case .hard:
            try FileManager.default.linkItem(
                at: root.appendingPathComponent("Bracken-3.1/src/ctime.cpp"),
                to: linkURL
            )
        }
        try archiveSourceTree()
        try refreshOverlayChecksum()
    }

    private func archiveSourceTree() throws {
        _ = try run(executable: "/usr/bin/tar", arguments: ["-czf", archiveURL.path, "-C", root.path, "Bracken-3.1"])
    }

    private func refreshOverlayChecksum() throws {
        overlay = PackToolSourceOverlay(
            kind: .bracken,
            version: "3.1",
            sourceURL: overlay.sourceURL,
            sha256: SHA256.hash(data: try Data(contentsOf: archiveURL)).map { String(format: "%02x", $0) }.joined()
        )
    }

    var downloadDestinationPath: String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/source.tar.gz").path
    }

    var extractedPath: String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/extract").path
    }

    func stagedBinPath(_ name: String) -> String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/publish/bin/\(name)").path
    }

    func stagedSourcePath(_ name: String) -> String {
        root.appendingPathComponent(".managed-bracken-00000000-0000-0000-0000-000000000001/publish/bin/src/\(name)").path
    }

    func installer(fileSystem: ManagedToolSourceFileSystem = .live) -> ManagedToolSourceInstaller {
        ManagedToolSourceInstaller(
            downloader: { [archiveURL] _, destination in
                try FileManager.default.copyItem(at: archiveURL, to: destination)
            },
            processRunner: { [weak self] invocation in
                guard let self else { throw CancellationError() }
                if invocation.executable.lastPathComponent == "tar", let listing = self.archiveListingOverride,
                   invocation.arguments.contains("-tzf") {
                    return .init(exitStatus: 0, stdout: listing, stderr: "")
                }
                if invocation.executable.lastPathComponent.contains("c++") {
                    if self.cancelDuringCompile { throw CancellationError() }
                    if self.compileShouldFail { return .init(exitStatus: 1, stdout: "", stderr: "compile failed") }
                    if let output = invocation.arguments.enumerated().first(where: { $0.element == "-o" }).flatMap({ index, _ in
                        invocation.arguments.dropFirst(index + 1).first
                    }) {
                        let outputURL = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try "#!/bin/sh\nexit 0\n".write(to: outputURL, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
                    }
                    return .init(exitStatus: 0, stdout: "", stderr: "")
                }
                if invocation.executable.lastPathComponent == "bracken" || invocation.executable.lastPathComponent == "bracken-build" || invocation.executable.lastPathComponent == "kmer2read_distr" {
                    return .init(exitStatus: 0, stdout: "help", stderr: "")
                }
                let result = try run(executable: invocation.executable.path, arguments: invocation.arguments, workingDirectory: invocation.workingDirectory)
                return .init(exitStatus: result.status, stdout: result.stdout, stderr: result.stderr)
            },
            fileSystem: fileSystem,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            uuid: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
    }

    private func run(executable: String, arguments: [String], workingDirectory: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}

private func assertLiveBrackenProbes(in environmentURL: URL) async throws {
    let path = environmentURL.appendingPathComponent("bin").path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
    let probes: [(String, [String])] = [
        ("bin/bracken", ["--help"]),
        ("bin/bracken-build", ["-v"]),
        ("bin/src/kmer2read_distr", ["--help"]),
    ]
    for (relativePath, arguments) in probes {
        let result = try await ManagedToolSourceInstaller.run(
            .init(
                executable: environmentURL.appendingPathComponent(relativePath),
                arguments: arguments,
                workingDirectory: environmentURL,
                environment: ["PATH": path]
            ),
            timeout: 30
        )
        XCTAssertEqual(result.exitStatus, 0, "\(relativePath) stderr: \(result.stderr)")
    }
}
