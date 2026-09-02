import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class FreyjaCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreyjaCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDemixDryRunWritesCommandPlanAndProvenance() async throws {
        let variants = try write("variants.tsv", contents: "site\tdepth\n", in: tempDir)
        let depths = try write("depths.tsv", contents: "site\tdepth\n", in: tempDir)
        let outputDir = tempDir.appendingPathComponent("freyja-plan", isDirectory: true)
        let command = try FreyjaCommand.DemixSubcommand.parse([
            "demix",
            "--variants", variants.path,
            "--depths", depths.path,
            "--output-dir", outputDir.path,
            "--sample", "WW-001",
            "--extra-args", "--eps 0.001",
        ])
        var lines: [String] = []

        try await command.executeForTesting { lines.append($0) }

        let planURL = outputDir.appendingPathComponent("freyja-command-plan.json")
        let provenanceURL = outputDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let planJSON = try String(contentsOf: planURL, encoding: .utf8)
        let provenance = try decodeProvenance(at: provenanceURL)

        XCTAssertTrue(lines.contains { $0.contains("freyja demix") })
        XCTAssertTrue(planJSON.contains(#""workflowName" : "lungfish freyja demix""#))
        XCTAssertTrue(planJSON.contains("--eps 0.001"))
        XCTAssertEqual(provenance.name, "lungfish freyja demix")
        XCTAssertEqual(provenance.parameters["packID"]?.stringValue, "wastewater-surveillance")
        XCTAssertEqual(provenance.steps.first?.inputs.count, 2)
        XCTAssertEqual(provenance.steps.first?.outputs.first?.path, planURL.path)
    }

    func testRootCLIRegistersFreyjaCommand() {
        let subcommands = LungfishCLI.configuration.subcommands.map { String(describing: $0) }

        XCTAssertTrue(subcommands.contains("FreyjaCommand"))
    }

    func testDemixCommandOmitsSampleFlagRemovedInFreyja2() throws {
        // Freyja 2.0.3, the version pinned in the tools lock, has no --sample
        // option: passing it aborts with "No such option '--sample'". The sample
        // identifier is still recorded in the plan and provenance, it just is not
        // handed to the tool.
        let plan = FreyjaDemixPlan(
            configuration: FreyjaDemixConfiguration(
                variantsURL: URL(fileURLWithPath: "/tmp/v.tsv"),
                depthsURL: URL(fileURLWithPath: "/tmp/d.tsv"),
                outputDirectory: URL(fileURLWithPath: "/tmp/out"),
                sampleName: "WW-001"
            ),
            toolVersion: "2.0.3",
            runtimeIdentity: "test"
        )

        XCTAssertFalse(plan.command.contains("--sample"), plan.shellCommand)
        XCTAssertFalse(plan.command.contains("WW-001"), plan.shellCommand)
        XCTAssertEqual(plan.options["sampleName"], "WW-001")
    }
}

private func write(_ name: String, contents: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func decodeProvenance(at url: URL) throws -> WorkflowRun {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRun.self, from: Data(contentsOf: url))
}
