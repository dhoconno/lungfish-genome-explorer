import XCTest
@testable import LungfishWorkflow

final class BundleContainerExportTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleContainerExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testContainerExportIsDeterministicAndWritesOCIProvenance() async throws {
        let bundle = try makeBundle()
        let outputA = tempRoot.appendingPathComponent("bundle-a.oci.tar")
        let outputB = tempRoot.appendingPathComponent("bundle-b.oci.tar")
        let pack = PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Mapping",
            sfSymbol: "map",
            packages: ["minimap2"],
            category: "Mapping",
            requirements: [
                PackToolRequirement(
                    id: "minimap2",
                    displayName: "minimap2",
                    environment: "minimap2",
                    installPackages: ["bioconda::minimap2=2.30"],
                    executables: ["minimap2"],
                    version: "2.30",
                    license: "MIT",
                    sourceURL: "https://github.com/lh3/minimap2"
                ),
            ]
        )

        let resultA = try await BundleContainerExportService().export(
            bundle: bundle,
            output: outputA,
            pluginPacks: [pack],
            commandLine: ["lungfish", "bundle", "export", bundle.path, "--format", "container", "--output", outputA.path]
        )
        let resultB = try await BundleContainerExportService().export(
            bundle: bundle,
            output: outputB,
            pluginPacks: [pack],
            commandLine: ["lungfish", "bundle", "export", bundle.path, "--format", "container", "--output", outputB.path]
        )

        XCTAssertEqual(resultA.imageDigest, resultB.imageDigest)

        let entries = try DeterministicTarReader.entries(in: outputA)
        let entriesB = try DeterministicTarReader.entries(in: outputB)
        XCTAssertTrue(entries.keys.contains("oci-layout"))
        XCTAssertTrue(entries.keys.contains("index.json"))
        XCTAssertTrue(entries.keys.contains { $0.contains("/manifest.json") })
        XCTAssertTrue(entries.keys.contains { $0.contains("/config.json") })
        XCTAssertTrue(entries.keys.contains { $0.contains("/layer.tar") })
        XCTAssertTrue(entries.keys.contains(".lungfish-provenance.json"))

        let provenanceData = try XCTUnwrap(entries[".lungfish-provenance.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let provenance = try decoder.decode(WorkflowRun.self, from: provenanceData)
        XCTAssertEqual(provenance.name, "Bundle Container Export")
        XCTAssertEqual(provenance.parameters["format"]?.stringValue, "container")
        XCTAssertEqual(provenance.parameters["bundlePath"]?.stringValue, bundle.standardizedFileURL.path)
        XCTAssertEqual(provenance.parameters["pluginPacks"]?.arrayValue?.compactMap(\.stringValue), ["read-mapping"])
        XCTAssertEqual(provenance.parameters["imageDigest"]?.stringValue, resultA.imageDigest)

        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolName, "lungfish bundle export")
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertTrue(step.command.contains("--format"))
        XCTAssertTrue(step.command.contains("container"))
        XCTAssertTrue(step.inputs.contains { $0.path == bundle.standardizedFileURL.path })
        XCTAssertTrue(step.outputs.contains { $0.path == outputA.standardizedFileURL.path })

        let manifestEntryName = try XCTUnwrap(entries.keys.first { $0.contains("/manifest.json") })
        let manifestEntryNameB = try XCTUnwrap(entriesB.keys.first { $0.contains("/manifest.json") })
        XCTAssertEqual(entries[manifestEntryName], entriesB[manifestEntryNameB])
        let manifestText = String(decoding: try XCTUnwrap(entries[manifestEntryName]), as: UTF8.self)
        XCTAssertTrue(manifestText.contains("application/vnd.oci.image.manifest.v1+json"))
        XCTAssertTrue(manifestText.contains("org.opencontainers.image.title"))
        XCTAssertTrue(manifestText.contains("read-mapping"))
    }

    private func makeBundle() throws -> URL {
        let bundle = tempRoot.appendingPathComponent("Example.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(#"{"name":"Example","identifier":"example"}"#.utf8)
            .write(to: bundle.appendingPathComponent("manifest.json"))
        try Data(">chr1\nACGT\n".utf8)
            .write(to: bundle.appendingPathComponent("genome.fa"))
        return bundle
    }
}
