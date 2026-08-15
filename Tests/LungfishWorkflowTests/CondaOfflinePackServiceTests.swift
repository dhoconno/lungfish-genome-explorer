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

    func testFailedManagedBrackenProbeRestoresExistingEnvironmentAndWritesFailureProvenance() async throws {
        let sourceCondaRoot = tempRoot.appendingPathComponent("source-failing-bracken", isDirectory: true)
        let sourceEnvironment = sourceCondaRoot.appendingPathComponent("envs/bracken", isDirectory: true)
        let managedFiles = ["bin/bracken", "bin/bracken-build", "bin/src/kmer2read_distr"]
        let installedFiles = try managedFiles.map { relativePath in
            let executable = sourceEnvironment.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let script: String
            if relativePath == "bin/src/kmer2read_distr" {
                script = "#!/bin/sh\nprintf 'kmer probe failed\\n' >&2\nexit 17\n"
            } else {
                script = "#!/bin/sh\nexit 0\n"
            }
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
            return ManagedToolSourceInstallationRecord.InstalledFile(
                relativePath: relativePath,
                sha256: try XCTUnwrap(ManagedToolSourceInstallationRecord.sha256(of: executable)),
                sizeBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            )
        }
        let compiler = sourceEnvironment.appendingPathComponent("bin/c++")
        try FileManager.default.createDirectory(at: compiler.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
        let openMP = sourceEnvironment.appendingPathComponent("lib/libomp.dylib")
        try FileManager.default.createDirectory(at: openMP.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("OpenMP runtime\n".utf8).write(to: openMP)
        let condaMeta = sourceEnvironment.appendingPathComponent("conda-meta", isDirectory: true)
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
            sha256: String(repeating: "b", count: 64)
        )
        let record = ManagedToolSourceInstallationRecord(
            source: overlay,
            commands: [.init(argv: ["bracken-build", "-v"], reproducibleCommand: "bracken-build -v")],
            runtime: .init(
                environmentPath: sourceEnvironment.path,
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
        try record.write(
            to: sourceEnvironment.appendingPathComponent("share/lungfish/managed-tools/bracken.json")
        )
        let pack = PluginPack(
            id: "failing-bracken-overlay",
            name: "Failing Bracken Overlay",
            description: "source-backed failure fixture",
            sfSymbol: "wrench",
            packages: ["bracken"],
            category: "Tests",
            requirements: [
                .init(
                    id: "bracken",
                    displayName: "Bracken",
                    environment: "bracken",
                    installPackages: [],
                    executables: ["bracken-build"],
                    sourceOverlay: overlay
                ),
            ]
        )
        let exported = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: sourceCondaRoot,
            outputDirectory: tempRoot.appendingPathComponent("exports", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "offline-export", "--pack", pack.id]
        )

        let destinationCondaRoot = tempRoot.appendingPathComponent("destination-failing-bracken", isDirectory: true)
        let existingEnvironment = destinationCondaRoot.appendingPathComponent("envs/bracken", isDirectory: true)
        try FileManager.default.createDirectory(at: existingEnvironment, withIntermediateDirectories: true)
        let knownGood = existingEnvironment.appendingPathComponent("known-good-payload")
        try Data("known-good environment\n".utf8).write(to: knownGood)

        do {
            _ = try await CondaOfflinePackService().installPack(
                from: exported.packDirectory,
                condaRoot: destinationCondaRoot,
                overwrite: true,
                commandLine: ["lungfish-cli", "conda", "offline-install", exported.packDirectory.path]
            )
            XCTFail("A nonzero managed Bracken readiness probe must fail the offline import.")
        } catch {
            // Expected: the staged imported runtime's kmer2read_distr probe exits 17.
        }

        XCTAssertEqual(
            try String(contentsOf: knownGood, encoding: .utf8),
            "known-good environment\n",
            "A failed readiness probe must restore an overwritten known-good environment."
        )
        let failureProvenanceURL = destinationCondaRoot
            .appendingPathComponent(".lungfish-offline-pack-install-failure.provenance.json")
        guard FileManager.default.fileExists(atPath: failureProvenanceURL.path) else {
            return XCTFail("A failed offline import must write a durable failure provenance receipt.")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: failureProvenanceURL))
        XCTAssertEqual(provenance.name, "Conda Offline Pack Install")
        XCTAssertEqual(provenance.status, .failed)
        XCTAssertFalse(provenance.hostOS.isEmpty)
        XCTAssertFalse(provenance.runtime.user?.isEmpty ?? true)
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.exitCode, 17)
        XCTAssertNotNil(step.wallTime)
        XCTAssertTrue(step.stderr?.contains("kmer probe failed") == true)
        XCTAssertTrue(step.inputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(step.outputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
        let resolvedKnownGoodPath = knownGood.resolvingSymlinksInPath().standardizedFileURL.path
        let restoredOutputRecord = step.outputs.first {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == resolvedKnownGoodPath
        }
        XCTAssertNotNil(restoredOutputRecord, "Failure outputs were \(step.outputs.map(\.path))")
        let restoredOutput = try XCTUnwrap(restoredOutputRecord)
        XCTAssertEqual(restoredOutput.sha256, try XCTUnwrap(ProvenanceRecorder.sha256(of: knownGood)))
        XCTAssertEqual(restoredOutput.sizeBytes, UInt64(Data("known-good environment\n".utf8).count))
        XCTAssertFalse(
            step.outputs.contains { $0.path.contains("/bin/src/kmer2read_distr") },
            "Failure provenance must describe the final restored state, not the rejected replacement payload."
        )

        let attemptedProbe = try XCTUnwrap(provenance.parameters["attemptedProbe"]?.dictionaryValue)
        XCTAssertEqual(
            attemptedProbe["argv"]?.arrayValue,
            [.string(existingEnvironment.appendingPathComponent("bin/src/kmer2read_distr").path), .string("--help")]
        )
        XCTAssertEqual(attemptedProbe["exitStatus"], .integer(17))
        XCTAssertEqual(attemptedProbe["stderr"], .string("kmer probe failed\n"))
    }

    func testManifestValidationFailurePreservesDestinationAndWritesFailureProvenance() async throws {
        let sourceCondaRoot = tempRoot.appendingPathComponent("source-invalid-manifest", isDirectory: true)
        let sourceEnvironment = sourceCondaRoot.appendingPathComponent("envs/samtools", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceEnvironment, withIntermediateDirectories: true)
        try Data("verified source payload\n".utf8).write(
            to: sourceEnvironment.appendingPathComponent("samtools")
        )
        let pack = PluginPack(
            id: "invalid-manifest",
            name: "Invalid Manifest",
            description: "checksum failure fixture",
            sfSymbol: "exclamationmark.triangle",
            packages: ["samtools"],
            category: "Tests"
        )
        let exported = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: sourceCondaRoot,
            outputDirectory: tempRoot.appendingPathComponent("exports", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "offline-export", "--pack", pack.id]
        )
        try Data("tampered source payload\n".utf8).write(
            to: exported.packDirectory.appendingPathComponent("envs/samtools/samtools")
        )

        let destinationCondaRoot = tempRoot.appendingPathComponent("destination-invalid-manifest", isDirectory: true)
        let destinationPayload = destinationCondaRoot.appendingPathComponent("envs/samtools/known-good")
        try FileManager.default.createDirectory(
            at: destinationPayload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("known-good destination\n".utf8).write(to: destinationPayload)

        do {
            _ = try await CondaOfflinePackService().installPack(
                from: exported.packDirectory,
                condaRoot: destinationCondaRoot,
                overwrite: true,
                commandLine: ["lungfish-cli", "conda", "offline-install", exported.packDirectory.path]
            )
            XCTFail("A manifest checksum mismatch must fail before any destination environment is replaced.")
        } catch {
            // Expected: the copied payload no longer matches its manifest SHA-256.
        }

        XCTAssertEqual(try String(contentsOf: destinationPayload, encoding: .utf8), "known-good destination\n")
        let failureProvenanceURL = destinationCondaRoot
            .appendingPathComponent(CondaOfflinePackService.installFailureProvenanceFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: Data(contentsOf: failureProvenanceURL))
        XCTAssertEqual(provenance.status, .failed)
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.exitCode, 1)
        XCTAssertTrue(step.stderr?.contains("Checksum mismatch") == true)
        XCTAssertTrue(step.inputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(step.outputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
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
