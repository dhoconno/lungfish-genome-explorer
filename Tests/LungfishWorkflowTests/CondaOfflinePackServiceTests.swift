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
        XCTAssertEqual(manifest.environments.map(\.name), ["samtools"])
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertNotNil(manifest.files.first?.sha256)

        let provenanceText = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenanceText.contains("\"toolName\" : \"lungfish-cli\""))
        XCTAssertTrue(provenanceText.contains("offline-export"))
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

        let provenanceText = try String(contentsOf: install.provenanceURL, encoding: .utf8)
        XCTAssertTrue(provenanceText.contains("offline-install"))
        let provenance = ProvenanceRecorder.load(from: destinationCondaRoot)
        XCTAssertEqual(provenance?.parameters["destinationCondaRoot"], .string(destinationCondaRoot.path))
    }
}
