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
        XCTAssertEqual(roundTrip.workflowGithubReleaseVersion, "2.7.0")
        XCTAssertEqual(roundTrip.executor, .docker)
        XCTAssertEqual(roundTrip.resultSurfaces, workflow.resultSurfaces)
        XCTAssertTrue(roundTrip.commandPreview.contains("nextflow run nf-core/viralrecon"))
        XCTAssertTrue(roundTrip.commandPreview.contains("-profile docker"))
    }

    /// Phase 2.10 B31, the A30 seam ruling. The engine's own log round-trips, and a manifest written before the key
    /// existed, or by a run whose engine never launched, has none and still reads.
    func testTheEnginesLogPathRoundTripsAndAManifestWithoutItStillReads() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        func manifest(_ nextflowLogPath: String?) -> NFCoreRunBundleManifest {
            NFCoreRunBundleManifest(
                workflow: workflow, version: "3.0.0", executor: .docker, params: [:], outputDirectoryName: "results",
                stdoutLogPath: "logs/stdout.log", stderrLogPath: "logs/stderr.log", nextflowLogPath: nextflowLogPath)
        }
        let encoder = JSONEncoder()
        let launched = try JSONDecoder().decode(
            NFCoreRunBundleManifest.self, from: encoder.encode(manifest("logs/nextflow.log")))
        XCTAssertEqual(launched.nextflowLogPath, "logs/nextflow.log")
        XCTAssertEqual([launched.stdoutLogPath, launched.stderrLogPath], ["logs/stdout.log", "logs/stderr.log"])

        let older = try encoder.encode(manifest(nil))
        XCTAssertFalse(String(decoding: older, as: UTF8.self).contains("nextflowLogPath"), "no key when no engine ran")
        XCTAssertNil(try JSONDecoder().decode(NFCoreRunBundleManifest.self, from: older).nextflowLogPath)
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

    func testCommandPreviewQuotesShellMetacharactersWithoutWhitespace() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let manifest = NFCoreRunBundleManifest(
            workflow: workflow,
            version: "2.7.0",
            executor: .docker,
            params: [
                "input": "/tmp/samples&ids.csv",
                "outdir": "/tmp/results;rm",
                "primer": "/tmp/O'Hara.bed",
            ],
            outputDirectoryName: "results",
            workDirectory: URL(fileURLWithPath: "/tmp/work&cache")
        )

        XCTAssertTrue(manifest.commandPreview.contains("-work-dir '/tmp/work&cache'"))
        XCTAssertTrue(manifest.commandPreview.contains("--input '/tmp/samples&ids.csv'"))
        XCTAssertTrue(manifest.commandPreview.contains("--outdir '/tmp/results;rm'"))
        XCTAssertTrue(manifest.commandPreview.contains("--primer '/tmp/O'\\''Hara.bed'"))
        XCTAssertFalse(manifest.commandPreview.contains("--input /tmp/samples&ids.csv"))
    }
}
