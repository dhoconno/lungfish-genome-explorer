import XCTest
@testable import LungfishWorkflow

final class NFCoreRunRequestTests: XCTestCase {
    func testRequestBuildsNextflowArgumentsAndManifestForViralRecon() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "3.0.1",
            executor: .docker,
            inputURLs: [URL(fileURLWithPath: "/tmp/samples ids.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/results"),
            params: ["platform": "illumina"]
        )

        XCTAssertEqual(request.displayTitle, "Run nf-core/viralrecon")
        XCTAssertEqual(
            request.nextflowArguments,
            [
                "run", "nf-core/viralrecon",
                "-r", "3.0.1",
                "-profile", "docker",
                "--input", "/tmp/samples ids.csv",
                "--outdir", "/tmp/results",
                "--platform", "illumina",
            ]
        )

        let manifest = request.manifest(createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(manifest.workflowName, "viralrecon")
        XCTAssertEqual(manifest.workflowPinnedVersion, workflow.pinnedVersion)
        XCTAssertEqual(manifest.params["input"], "/tmp/samples ids.csv")
        XCTAssertEqual(manifest.params["outdir"], "/tmp/results")
        XCTAssertEqual(manifest.params["platform"], "illumina")
        XCTAssertEqual(manifest.outputDirectoryName, "results")
        XCTAssertTrue(manifest.commandPreview.contains("nextflow run nf-core/viralrecon"))
    }

    func testRequestCanRepresentViralReconCustomAdapterPresentation() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "",
            executor: .conda,
            inputURLs: [URL(fileURLWithPath: "/tmp/samplesheet.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/viralrecon"),
            presentationMode: .customAdapter("viralrecon")
        )

        XCTAssertEqual(request.presentationMode, .customAdapter("viralrecon"))
        XCTAssertEqual(Array(request.nextflowArguments.prefix(4)), ["run", "nf-core/viralrecon", "-r", workflow.pinnedVersion])
        XCTAssertTrue(request.nextflowArguments.contains("-profile"))
        XCTAssertTrue(request.nextflowArguments.contains("conda"))
        XCTAssertTrue(request.nextflowArguments.contains("--input"))
        XCTAssertTrue(request.nextflowArguments.contains(workflow.pinnedVersion))
    }

    func testCLICommandPreviewQuotesEmptyExecutableAndShellMetacharacters() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "3.0.1",
            executor: .docker,
            inputURLs: [URL(fileURLWithPath: "/tmp/samples&ids.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/results"),
            params: ["primer": "/tmp/O'Hara.bed"]
        )

        let preview = request.cliCommandPreview(
            bundlePath: URL(fileURLWithPath: "/tmp/run;bundle.lungfishrun"),
            executableName: ""
        )

        XCTAssertTrue(preview.hasPrefix("'' workflow run nf-core/viralrecon"))
        XCTAssertTrue(preview.contains("--bundle-path '/tmp/run;bundle.lungfishrun'"))
        XCTAssertTrue(preview.contains("--input '/tmp/samples&ids.csv'"))
        XCTAssertTrue(preview.contains("--param 'primer=/tmp/O'\\''Hara.bed'"))
        XCTAssertFalse(preview.contains("--input /tmp/samples&ids.csv"))
    }
}
