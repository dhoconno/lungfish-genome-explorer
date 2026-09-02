import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class NFCoreResourceLimitsTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nfcore-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeRequest(params: [String: String]) throws -> NFCoreRunRequest {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        return NFCoreRunRequest(
            workflow: workflow,
            version: "3.0.0",
            executor: .docker,
            inputURLs: [tempRoot.appendingPathComponent("samplesheet.csv")],
            outputDirectory: tempRoot.appendingPathComponent("results", isDirectory: true),
            params: params
        )
    }

    func testWritesResourceLimitsConfigAndDropsUnsupportedMaxParameters() throws {
        // viralrecon 3.0.0 removed --max_memory/--max_cpus in favour of Nextflow's
        // own `process.resourceLimits`. Passing the old flags leaves every process
        // asking for its unclamped default (BOWTIE2_BUILD wants 72 GB), which
        // Nextflow refuses on a laptop with "Process requirement exceeds available memory".
        let request = try makeRequest(params: [
            "platform": "illumina",
            "max_cpus": "8",
            "max_memory": "8.GB",
        ])

        let plan = try NFCoreResourceLimits.plan(for: request, in: tempRoot)

        let configURL = try XCTUnwrap(plan.configURL)
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("resourceLimits"), contents)
        XCTAssertTrue(contents.contains("cpus: 8"), contents)
        XCTAssertTrue(contents.contains("memory: 8.GB"), contents)

        XCTAssertNil(plan.request.params["max_cpus"], "3.0.0 rejects unknown parameters")
        XCTAssertNil(plan.request.params["max_memory"])
        XCTAssertEqual(plan.request.params["platform"], "illumina")

        XCTAssertEqual(plan.nextflowArguments(base: ["run", "x"]), ["run", "x", "-c", configURL.path])
    }

    func testConfigCarriesRetryPolicyWithoutResourceLimitsWhenNoCapsRequested() throws {
        // The config is no longer conditional on the caps: even with none, the
        // run needs the retry policy for emulated containers.
        let request = try makeRequest(params: ["platform": "illumina"])

        let plan = try NFCoreResourceLimits.plan(for: request, in: tempRoot)

        let contents = try String(contentsOf: XCTUnwrap(plan.configURL), encoding: .utf8)
        XCTAssertFalse(contents.contains("resourceLimits = ["), contents)
        XCTAssertTrue(contents.contains("maxRetries"), contents)
        XCTAssertEqual(plan.request, request)
    }

    func testCPUOnlyLimitStillProducesConfig() throws {
        let request = try makeRequest(params: ["platform": "illumina", "max_cpus": "4"])

        let plan = try NFCoreResourceLimits.plan(for: request, in: tempRoot)

        let contents = try String(contentsOf: XCTUnwrap(plan.configURL), encoding: .utf8)
        XCTAssertTrue(contents.contains("cpus: 4"), contents)
        XCTAssertFalse(contents.contains("memory:"), contents)
    }

    func testLimitsAreLeftAsParametersForReleasesThatSupportThem() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "2.6.0",
            executor: .docker,
            inputURLs: [tempRoot.appendingPathComponent("samplesheet.csv")],
            outputDirectory: tempRoot.appendingPathComponent("results", isDirectory: true),
            params: ["max_cpus": "8", "max_memory": "8.GB"]
        )

        let plan = try NFCoreResourceLimits.plan(for: request, in: tempRoot)

        XCTAssertNil(plan.configURL, "2.6.0 still understands --max_cpus/--max_memory")
        XCTAssertEqual(plan.request.params["max_cpus"], "8")
        XCTAssertEqual(plan.request.params["max_memory"], "8.GB")
    }

    func testViralReconConfigRetriesTransientContainerFailures() throws {
        // Under Rosetta emulation an amd64-only task container occasionally dies
        // on startup with a non-zero status that the nf-core base config does not
        // consider retryable (its list is 130...145, 104 and 175). QUAST has been
        // seen failing this way with exit 3 in seconds, on inputs that succeed on
        // a rerun, which ends the whole pipeline after the science is done.
        let request = try makeRequest(params: ["max_cpus": "8", "max_memory": "8.GB"])

        let plan = try NFCoreResourceLimits.plan(for: request, in: tempRoot)

        let configURL = try XCTUnwrap(plan.configURL)
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("errorStrategy"), contents)
        XCTAssertTrue(contents.contains("maxRetries"), contents)
    }

    func testRetryPolicyIsWrittenEvenWithoutResourceCaps() throws {
        // The retry policy is not conditional on the caps: a run with neither
        // cap still needs it.
        let request = try makeRequest(params: [:])

        let plan = try NFCoreResourceLimits.plan(for: request, in: tempRoot)

        let configURL = try XCTUnwrap(plan.configURL)
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("errorStrategy"))
    }
}
