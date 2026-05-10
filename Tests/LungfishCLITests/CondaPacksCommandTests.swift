import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class CondaPacksCommandTests: XCTestCase {

    func testVisibleCLIPacksOnlyIncludeRequiredAndActivePacks() {
        XCTAssertEqual(
            CondaCommand.visiblePacksForTesting().map(\.id),
            [
                "lungfish-tools",
                "read-mapping",
                "variant-calling",
                "gatk-core",
                "assembly",
                "multiple-sequence-alignment",
                "phylogenetics",
                "metagenomics",
            ]
        )
    }

    func testExportPackAliasParsesThroughCondaRootAndExportsOfflineArchive() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let condaRoot = tempRoot.appendingPathComponent("source-conda", isDirectory: true)
        try makeInstalledEnvironments(forPackID: "read-mapping", in: condaRoot)
        let archiveURL = tempRoot.appendingPathComponent("read-mapping-offline.tgz")

        let parsed = try CondaCommand.parseAsRoot([
            "export-pack",
            "--pack", "read-mapping",
            "--output", archiveURL.path,
            "--conda-root", condaRoot.path,
        ])
        XCTAssertEqual(String(describing: type(of: parsed)), "ExportPackSubcommand")

        guard var command = parsed as? any AsyncParsableCommand else {
            XCTFail("export-pack should parse to an async conda subcommand")
            return
        }
        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testInstallOfflineFromBundleParsesThroughInstallAndInstallsArchive() async throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let condaRoot = tempRoot.appendingPathComponent("source-conda", isDirectory: true)
        try makeInstalledEnvironments(forPackID: "read-mapping", in: condaRoot)
        let archiveURL = tempRoot.appendingPathComponent("read-mapping-offline.tgz")
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "read-mapping"))
        _ = try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: condaRoot,
            output: archiveURL,
            commandLine: ["lungfish", "conda", "export-pack", "--pack", "read-mapping", "--output", archiveURL.path]
        )

        let destinationCondaRoot = tempRoot.appendingPathComponent("destination-conda", isDirectory: true)
        let preexistingEnvironment = destinationCondaRoot.appendingPathComponent("envs/minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: preexistingEnvironment, withIntermediateDirectories: true)
        try Data("stale minimap2\n".utf8).write(to: preexistingEnvironment.appendingPathComponent("tool.txt"))

        let parsed = try CondaCommand.parseAsRoot([
            "install",
            "--offline",
            "--from-bundle", archiveURL.path,
            "--conda-root", destinationCondaRoot.path,
            "--overwrite",
        ])
        XCTAssertTrue(parsed is CondaCommand.InstallSubcommand)

        guard var command = parsed as? any AsyncParsableCommand else {
            XCTFail("install --offline should parse to an async conda subcommand")
            return
        }
        try await command.run()

        let expectedEnvironment = destinationCondaRoot.appendingPathComponent("envs/minimap2/tool.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedEnvironment.path))
        let installedContents = try String(contentsOf: expectedEnvironment, encoding: .utf8)
        XCTAssertEqual(installedContents, "installed minimap2\n")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationCondaRoot.appendingPathComponent(".lungfish-provenance.json").path
        ))
    }

    func testLegacyOfflineSubcommandsRemainAvailable() throws {
        let export = try CondaCommand.parseAsRoot([
            "offline-export",
            "--pack", "read-mapping",
            "--output", "/tmp/read-mapping-offline",
        ])
        let install = try CondaCommand.parseAsRoot([
            "offline-install",
            "/tmp/read-mapping-offline/read-mapping-conda-offline-pack",
        ])

        XCTAssertTrue(export is CondaCommand.OfflineExportSubcommand)
        XCTAssertTrue(install is CondaCommand.OfflineInstallSubcommand)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CondaPacksCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeInstalledEnvironments(forPackID packID: String, in condaRoot: URL) throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: packID))
        for environmentName in Set(pack.toolRequirements.map(\.environment)) {
            let envURL = condaRoot.appendingPathComponent("envs/\(environmentName)", isDirectory: true)
            try FileManager.default.createDirectory(at: envURL, withIntermediateDirectories: true)
            try Data("installed \(environmentName)\n".utf8).write(to: envURL.appendingPathComponent("tool.txt"))
        }
    }
}
