import XCTest
@testable import LungfishWorkflow

final class NFCoreRunRequestTests: XCTestCase {
    func testRequestBuildsNextflowArgumentsAndManifestForCuratedWorkflow() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "fetchngs"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "1.13.0",
            executor: .docker,
            inputURLs: [URL(fileURLWithPath: "/tmp/samples ids.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/results"),
            params: ["genome": "GRCh38"]
        )

        XCTAssertEqual(request.displayTitle, "Run nf-core/fetchngs")
        XCTAssertEqual(
            request.nextflowArguments,
            [
                "run", "nf-core/fetchngs",
                "-r", "1.13.0",
                "-profile", "docker",
                "--genome", "GRCh38",
                "--input", "/tmp/samples ids.csv",
                "--outdir", "/tmp/results",
            ]
        )

        let manifest = request.manifest(createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(manifest.workflowName, "fetchngs")
        XCTAssertEqual(manifest.params["input"], "/tmp/samples ids.csv")
        XCTAssertEqual(manifest.params["outdir"], "/tmp/results")
        XCTAssertEqual(manifest.outputDirectoryName, "results")
        XCTAssertTrue(manifest.commandPreview.contains("nextflow run nf-core/fetchngs"))
    }

    func testRequestCanRepresentHardFutureWorkflowWithoutGenericDialogAssumptions() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "scrnaseq"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "",
            executor: .conda,
            inputURLs: [],
            outputDirectory: URL(fileURLWithPath: "/tmp/scrna"),
            params: ["input": "/tmp/samplesheet.csv"],
            presentationMode: .customAdapter("single-cell-matrix")
        )

        XCTAssertEqual(request.presentationMode, .customAdapter("single-cell-matrix"))
        XCTAssertEqual(Array(request.nextflowArguments.prefix(4)), ["run", "nf-core/scrnaseq", "-profile", "conda"])
        XCTAssertTrue(request.nextflowArguments.contains("--input"))
        XCTAssertFalse(request.nextflowArguments.contains("-r"))
    }
}
