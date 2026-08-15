import XCTest
import os
@testable import LungfishWorkflow

final class CondaOfflinePackServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CondaOfflinePackServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testCommandLineRedactionCoversCommonSecretFlags() {
        let redacted = CondaOfflinePackService.redactedCommandLine([
            "lungfish",
            "conda",
            "export-pack",
            "--password", "plain-password",
            "--access-token=inline-token",
            "--client-secret", "client-secret-value",
            "--from-bundle", "/offline/read-mapping.tgz",
        ])

        XCTAssertEqual(redacted[4], "<redacted>")
        XCTAssertTrue(redacted.contains("--access-token=<redacted>"))
        XCTAssertEqual(redacted[6], "--client-secret")
        XCTAssertEqual(redacted[7], "<redacted>")
        XCTAssertTrue(redacted.contains("/offline/read-mapping.tgz"))

        let joined = redacted.joined(separator: " ")
        XCTAssertFalse(joined.contains("plain-password"))
        XCTAssertFalse(joined.contains("inline-token"))
        XCTAssertFalse(joined.contains("client-secret-value"))
    }

    func testExportWritesManifestAndProvenanceWithoutSecrets() async throws {
        let condaRoot = tempRoot.appendingPathComponent("source-conda", isDirectory: true)
        let envURL = condaRoot.appendingPathComponent("envs/samtools", isDirectory: true)
        try FileManager.default.createDirectory(at: envURL, withIntermediateDirectories: true)
        try Data("samtools binary\n".utf8).write(to: envURL.appendingPathComponent("samtools"))

        let outputDirectory = tempRoot.appendingPathComponent("exports", isDirectory: true)
        let pack = PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Read mapping tools",
            sfSymbol: "map",
            packages: ["samtools"],
            category: "Analysis"
        )

        let result = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: condaRoot,
            outputDirectory: outputDirectory,
            commandLine: [
                "lungfish-cli", "conda", "offline-export",
                "--pack", "read-mapping",
                "--ncbi-api-key", "SECRET_SHOULD_NOT_APPEAR",
            ]
        )

        let manifestURL = result.packDirectory.appendingPathComponent(CondaOfflinePackService.manifestFilename)
        let provenanceURL = result.packDirectory.appendingPathComponent(".lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            CondaOfflinePackManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.packID, "read-mapping")
        XCTAssertEqual(manifest.packVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(manifest.environments.map(\.name), ["samtools"])
        XCTAssertEqual(manifest.environments.first?.sourcePath, envURL.standardizedFileURL.path)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertNotNil(manifest.files.first?.sha256)
        XCTAssertEqual(manifest.files.first?.sizeBytes, UInt64(Data("samtools binary\n".utf8).count))

        let provenance = try decoder.decode(
            WorkflowRun.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.name, "Conda Offline Pack Export")
        XCTAssertEqual(provenance.parameters["packID"], .string("read-mapping"))
        XCTAssertEqual(provenance.parameters["packVersion"], .string(WorkflowRun.currentAppVersion))
        XCTAssertEqual(provenance.parameters["runtimeUser"], .string(WorkflowRun.currentUser))
        XCTAssertNotNil(provenance.parameters["runtimeHostName"]?.stringValue)
        XCTAssertFalse(provenance.hostOS.isEmpty)
        XCTAssertEqual(provenance.runtime.user, WorkflowRun.currentUser)

        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolName, "lungfish-cli")
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertNotNil(step.wallTime)
        XCTAssertTrue(step.command.contains("offline-export"))
        XCTAssertTrue(step.outputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })

        let provenanceText = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertFalse(provenanceText.contains("SECRET_SHOULD_NOT_APPEAR"))
    }

    func testInstallCopiesPackEnvironmentsAndWritesInstallProvenance() async throws {
        let sourceCondaRoot = tempRoot.appendingPathComponent("source-conda", isDirectory: true)
        let envURL = sourceCondaRoot.appendingPathComponent("envs/samtools", isDirectory: true)
        try FileManager.default.createDirectory(at: envURL, withIntermediateDirectories: true)
        try Data("samtools binary\n".utf8).write(to: envURL.appendingPathComponent("samtools"))

        let pack = PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Read mapping tools",
            sfSymbol: "map",
            packages: ["samtools"],
            category: "Analysis"
        )
        let export = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: sourceCondaRoot,
            outputDirectory: tempRoot.appendingPathComponent("exports", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "offline-export", "--pack", "read-mapping"]
        )

        let destinationCondaRoot = tempRoot.appendingPathComponent("destination-conda", isDirectory: true)
        let install = try await CondaOfflinePackService().installPack(
            from: export.packDirectory,
            condaRoot: destinationCondaRoot,
            overwrite: false,
            commandLine: ["lungfish-cli", "conda", "offline-install", export.packDirectory.path]
        )

        XCTAssertEqual(install.installedEnvironments.map(\.lastPathComponent), ["samtools"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationCondaRoot.appendingPathComponent("envs/samtools/samtools").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: install.provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: install.provenanceURL))
        XCTAssertEqual(provenance.parameters["destinationCondaRoot"], .string(destinationCondaRoot.path))
        XCTAssertEqual(provenance.parameters["packID"], .string("read-mapping"))
        XCTAssertEqual(provenance.parameters["packVersion"], .string(WorkflowRun.currentAppVersion))
        XCTAssertEqual(provenance.parameters["runtimeUser"], .string(WorkflowRun.currentUser))
        XCTAssertNotNil(provenance.parameters["runtimeHostName"]?.stringValue)

        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertTrue(step.command.contains("offline-install"))
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertNotNil(step.wallTime)
        XCTAssertTrue(step.inputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(step.outputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
    }

    func testOfflinePackPreservesManagedBrackenOverlayRecordAndPayload() async throws {
        let sourceCondaRoot = tempRoot.appendingPathComponent("source-bracken", isDirectory: true)
        let environmentURL = sourceCondaRoot.appendingPathComponent("envs/bracken", isDirectory: true)
        let probeLog = tempRoot.appendingPathComponent("bracken-offline-probes.log")
        let managedFiles = ["bin/bracken", "bin/bracken-build", "bin/src/kmer2read_distr"]
        let installedFiles = try managedFiles.map { relativePath in
            let url = environmentURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nprintf '%s %s\\n' '\(url.lastPathComponent)' \"$1\" >> '\(probeLog.path)'\nexit 0\n".write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ManagedToolSourceInstallationRecord.InstalledFile(
                relativePath: relativePath,
                sha256: try XCTUnwrap(ManagedToolSourceInstallationRecord.sha256(of: url)),
                sizeBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            )
        }
        let compiler = environmentURL.appendingPathComponent("bin/c++")
        try FileManager.default.createDirectory(at: compiler.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
        let openMP = environmentURL.appendingPathComponent("lib/libomp.dylib")
        try FileManager.default.createDirectory(at: openMP.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("OpenMP runtime\n".utf8).write(to: openMP)
        let condaMeta = environmentURL.appendingPathComponent("conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: condaMeta, withIntermediateDirectories: true)
        for package in managedBrackenRuntimePackages {
            let metadata = "{\"name\":\"\(package.name)\",\"version\":\"\(package.version)\",\"build\":\"\(package.build)\",\"subdir\":\"\(package.subdir)\"}"
            try metadata.write(
                to: condaMeta.appendingPathComponent("\(package.name)-\(package.version)-\(package.build).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        let overlay = PackToolSourceOverlay(
            kind: .bracken,
            version: "3.1",
            sourceURL: URL(string: "https://example.test/Bracken-v3.1.tar.gz")!,
            sha256: String(repeating: "a", count: 64)
        )
        let record = ManagedToolSourceInstallationRecord(
            source: overlay,
            commands: [.init(argv: ["bracken-build", "-v"], reproducibleCommand: "bracken-build -v")],
            runtime: .init(
                environmentPath: environmentURL.path,
                compilerPath: compiler.path,
                openMPRuntimePath: openMP.path,
                condaPackages: managedBrackenRuntimePackages
            ),
            installedFiles: installedFiles,
            startedAt: .now,
            completedAt: .now,
            wallTimeSeconds: 0,
            exitStatus: 0,
            stderr: ""
        )
        let recordURL = environmentURL.appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        try record.write(to: recordURL)
        let pack = PluginPack(
            id: "bracken-overlay",
            name: "Bracken Overlay",
            description: "source-backed fixture",
            sfSymbol: "wrench",
            packages: ["bracken"],
            category: "Tests",
            requirements: [
                .init(id: "bracken", displayName: "Bracken", environment: "bracken", installPackages: [], executables: ["bracken-build"], sourceOverlay: overlay),
            ]
        )

        let exported = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: sourceCondaRoot,
            outputDirectory: tempRoot.appendingPathComponent("exports", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "offline-export", "--pack", pack.id]
        )
        let destinationCondaRoot = tempRoot.appendingPathComponent("destination-bracken", isDirectory: true)
        _ = try await CondaOfflinePackService().installPack(
            from: exported.packDirectory,
            condaRoot: destinationCondaRoot,
            overwrite: false,
            commandLine: ["lungfish-cli", "conda", "offline-install", exported.packDirectory.path]
        )

        let installedEnvironment = destinationCondaRoot.appendingPathComponent("envs/bracken", isDirectory: true)
        let importedProbes = (try? String(contentsOf: probeLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(importedProbes.contains("bracken --help"))
        XCTAssertTrue(importedProbes.contains("bracken-build -v"))
        XCTAssertTrue(importedProbes.contains("kmer2read_distr --help"))
        let importedRecord = try ManagedToolSourceInstallationRecord.load(
            from: installedEnvironment.appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        )
        XCTAssertEqual(importedRecord, record)
        XCTAssertTrue(importedRecord.validates(sourceOverlay: overlay, environmentURL: installedEnvironment))
        for executable in ["bin/bracken", "bin/bracken-build", "bin/src/kmer2read_distr"] {
            XCTAssertEqual(try runExecutable(installedEnvironment.appendingPathComponent(executable), arguments: ["--help"]), 0)
        }
    }

    func testExportAndInstallSupportTarAndTgzArchiveDestinations() async throws {
        for archiveExtension in ["tar", "tgz"] {
            let condaRoot = tempRoot.appendingPathComponent("source-\(archiveExtension)", isDirectory: true)
            let envURL = condaRoot.appendingPathComponent("envs/samtools", isDirectory: true)
            try FileManager.default.createDirectory(at: envURL, withIntermediateDirectories: true)
            try Data("samtools binary \(archiveExtension)\n".utf8).write(to: envURL.appendingPathComponent("samtools"))

            let pack = PluginPack(
                id: "read-mapping",
                name: "Read Mapping",
                description: "Read mapping tools",
                sfSymbol: "map",
                packages: ["samtools"],
                category: "Analysis"
            )
            let archiveURL = tempRoot.appendingPathComponent("read-mapping-offline.\(archiveExtension)")
            let export = try await CondaOfflinePackService().exportPack(
                pack: pack,
                condaRoot: condaRoot,
                output: archiveURL,
                commandLine: ["lungfish-cli", "conda", "export-pack", "--pack", "read-mapping", "--output", archiveURL.path]
            )

            XCTAssertEqual(export.archiveURL, archiveURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: export.manifestURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: export.provenanceURL.path))

            let destinationCondaRoot = tempRoot.appendingPathComponent("destination-\(archiveExtension)", isDirectory: true)
            let install = try await CondaOfflinePackService().installPack(
                from: archiveURL,
                condaRoot: destinationCondaRoot,
                overwrite: false,
                commandLine: ["lungfish-cli", "conda", "install", "--offline", "--from-bundle", archiveURL.path]
            )

            XCTAssertEqual(install.installedEnvironments.map(\.lastPathComponent), ["samtools"])
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destinationCondaRoot.appendingPathComponent("envs/samtools/samtools").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath: install.provenanceURL.path))
        }
    }

    /// R3-R3H-4 regression: runTar must drain stderr concurrently with the
    /// child process rather than after `waitUntilExit()`. macOS pipe buffers
    /// are ~64KB; a real `tar` invocation over a large conda environment can
    /// exceed that in warning lines. Uses a fake "tar" (a shell script) that
    /// deliberately writes well over 64KB to stderr before exiting, so a
    /// wait-before-drain implementation would deadlock forever with nobody
    /// reading the full pipe. Runs the call on a background thread and
    /// bounds the wait with a timeout so a regression fails the test instead
    /// of hanging the suite.
    func testRunTarDrainsLargeStderrWithoutDeadlock() throws {
        let fakeTarURL = tempRoot.appendingPathComponent("fake-tar.sh")
        // Write ~200KB to stderr (well over the ~64KB pipe buffer), then exit 0.
        let script = """
        #!/bin/sh
        i=0
        while [ "$i" -lt 4000 ]; do
            echo "tar: simulated warning line $i padding padding padding padding" >&2
            i=$((i + 1))
        done
        exit 0
        """
        try script.write(to: fakeTarURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTarURL.path)

        let completed = expectation(description: "runTar completes without deadlocking")
        let resultLock = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CondaOfflinePackService.runTar(
                    executableURL: fakeTarURL,
                    arguments: [],
                    operation: "test"
                )
                resultLock.withLock { $0 = .success(()) }
            } catch {
                resultLock.withLock { $0 = .failure(error) }
            }
            completed.fulfill()
        }

        // A deadlocked implementation would never fulfill this expectation;
        // bound the wait so the regression fails fast instead of hanging CI.
        wait(for: [completed], timeout: 10)

        let result = resultLock.withLock { $0 }
        switch result {
        case .success:
            break
        case .failure(let error):
            XCTFail("runTar threw unexpectedly: \(error)")
        case nil:
            XCTFail("runTar did not complete within the timeout -- likely deadlocked on stderr pipe drain")
        }
    }
}

private func runExecutable(_ executable: URL, arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private let managedBrackenRuntimePackages: [ManagedToolSourceInstallationRecord.Runtime.CondaPackage] = [
    .init(name: "cxx-compiler", version: "1.9.0", build: "h1", subdir: "osx-arm64"),
    .init(name: "llvm-openmp", version: "21.1.8", build: "h2", subdir: "osx-arm64"),
    .init(name: "python", version: "3.11.13", build: "h3", subdir: "osx-arm64"),
]
