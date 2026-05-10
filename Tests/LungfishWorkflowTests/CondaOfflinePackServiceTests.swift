import XCTest
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
}
