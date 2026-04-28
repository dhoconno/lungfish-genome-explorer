import XCTest
@testable import LungfishWorkflow

final class NFCoreRunBundleManifestTests: XCTestCase {
    func testManifestRoundTripPreservesNFCoreIdentityAndResultSurfaces() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfcore-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let bundleURL = tempDirectory.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let manifest = NFCoreRunBundleManifest(
            workflow: workflow,
            version: "2.7.0",
            executor: .docker,
            params: [
                "input": "samplesheet.csv",
                "outdir": "results",
            ],
            outputDirectoryName: "results"
        )

        try NFCoreRunBundleStore.write(manifest, to: bundleURL)
        let roundTrip = try NFCoreRunBundleStore.read(from: bundleURL)

        XCTAssertEqual(roundTrip.workflowName, "viralrecon")
        XCTAssertEqual(roundTrip.workflowDisplayName, "nf-core/viralrecon")
        XCTAssertEqual(roundTrip.version, "2.7.0")
        XCTAssertEqual(roundTrip.workflowPinnedVersion, workflow.pinnedVersion)
        XCTAssertEqual(roundTrip.executor, .docker)
        XCTAssertEqual(roundTrip.resultSurfaces, workflow.resultSurfaces)
        XCTAssertTrue(roundTrip.commandPreview.contains("nextflow run nf-core/viralrecon"))
        XCTAssertTrue(roundTrip.commandPreview.contains("-profile docker"))
    }

    func testManifestWritesArtifactFilesExpectedByViralReconResultImport() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfcore-artifact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let bundleURL = tempDirectory.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let manifest = NFCoreRunBundleManifest(
            workflow: workflow,
            version: "1.0.0",
            executor: .conda,
            params: ["input": "samplesheet.csv"],
            outputDirectoryName: "results"
        )

        try NFCoreRunBundleStore.write(manifest, to: bundleURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("reports").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("outputs").path))
    }
}
