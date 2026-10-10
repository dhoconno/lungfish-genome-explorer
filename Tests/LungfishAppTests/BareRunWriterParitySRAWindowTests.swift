import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

/// Runs the window's SRA import provenance writer in a temporary `.lungfish` project and compares
/// the facts of what it wrote with the facts captured from the same run on unchanged code
/// (Phase 2.4, finding R8, lane W2B). The expected facts are in
/// Tests/Fixtures/provenance-writer-parity. Every date is injected, so the times compare exactly.
final class BareRunWriterParitySRAWindowTests: XCTestCase {
    typealias Parity = BareRunWriterParity

    /// Prefer NCBI's toolkit failed after prefetch, and ENA served the run. The failed attempt stays
    /// recorded and marked, and the import step depends only on the transfer that served the run.
    func testToolkitFailureThenENA() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let start = Date(timeIntervalSince1970: 1_000)
        let enaStep = StepExecution(
            id: UUID(uuidString: "5E0A0000-0000-4000-8000-000000000001")!,
            toolName: "https-download",
            toolVersion: "URLSession",
            command: ["curl"],
            inputs: [],
            exitCode: 0,
            wallTime: 1,
            startTime: start.addingTimeInterval(10),
            endTime: start.addingTimeInterval(11)
        )
        let bundle = try Self.makeBundle(in: project)

        try Self.write(
            into: bundle,
            preference: .ncbi,
            source: .enaAfterFailedToolkit,
            fallbackMessage: "The SRA Toolkit failed for SRR1, so ENA serves it instead. disk full",
            enaSteps: [enaStep],
            toolkitTraces: [
                Self.trace("prefetch", exitCode: 0, at: start),
                Self.trace("fasterq-dump", exitCode: 3, at: start.addingTimeInterval(5)),
            ]
        )

        try expectAfterConversion(
            bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            scenario: Parity.Scenarios.sraWindowToolkitAfterFailedENA,
            // prefetch and fasterq-dump take the accession as their input, which is no file.
            knownGaps: ["Missing checksum or size for 1 file descriptor: SRR1."]
        )
    }

    /// The import CLI already wrote the bundle's record, and the window keeps its steps.
    func testWindowKeepsTheCLIImportRecord() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundle = try Self.makeBundle(in: project)
        // What `lungfish-cli import fastq` writes into the bundle first: an envelope with one step.
        let importStart = Date(timeIntervalSince1970: 2_000)
        let importRun = WorkflowRun(
            id: UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A0")!,
            name: "fastq-import",
            startTime: importStart,
            endTime: importStart.addingTimeInterval(1),
            status: .completed,
            appVersion: "lungfish-cli test",
            steps: [
                StepExecution(
                    id: UUID(uuidString: "5E0A0000-0000-4000-8000-0000000000A1")!,
                    toolName: "lungfish-cli",
                    toolVersion: "test",
                    command: ["lungfish-cli", "import", "fastq", "reads.fastq.gz"],
                    inputs: [],
                    exitCode: 0,
                    wallTime: 1,
                    startTime: importStart,
                    endTime: importStart.addingTimeInterval(1)
                )
            ],
            parameters: ["platform": .string("illumina")]
        )
        try ProvenanceWriter(signingProvider: nil).write(
            importRun.canonicalEnvelope(),
            toSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        )

        try Self.write(
            into: bundle,
            preference: .ena,
            source: .ena,
            fallbackMessage: nil,
            enaSteps: [],
            toolkitTraces: []
        )

        try expectAfterConversion(
            bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            scenario: Parity.Scenarios.sraWindowKeepsCLIRecord,
            // The import record this test plants has one step and names no files, and the window keeps the
            // steps it finds as they are, so the combined record names none either.
            knownGaps: ["Input/reference/output file descriptors are missing.", "Output descriptors are missing."]
        )
    }

    // MARK: Comparison

    /// The converted writer must say what it said before, apart from the declared shape change, and
    /// its record must pass the strict reader, decode as a `WorkflowRun` and be complete.
    ///
    /// - Parameter knownGaps: The sentences `ProvenanceCompleteness` reports for a record that is
    ///   complete in every way the writer can make it. A test names each one and says why.
    private func expectAfterConversion(
        _ sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        scenario: Parity.Scenario,
        knownGaps: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let problems = try Parity.problemsAfterConversion(of: sidecar, in: project, scenario: scenario)
        XCTAssertTrue(problems.isEmpty, "\(scenario.id) changed: \(problems)", file: file, line: line)
        let findings = try Parity.strictFindings(sidecar: sidecar, knownGaps: knownGaps)
        XCTAssertTrue(findings.isEmpty, "\(scenario.id) record: \(findings)", file: file, line: line)
    }

    // MARK: Fixtures

    private static func makeBundle(in project: ProvenanceCompatScenarios.Project) throws -> URL {
        let bundle = project.root.appendingPathComponent("Imports/SRR1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("reads.fastq.gz"))
        return bundle
    }

    private static func trace(_ tool: String, exitCode: Int32, at start: Date) -> SRAService.FASTQDownloadStepTrace {
        SRAService.FASTQDownloadStepTrace(
            toolName: tool,
            toolVersion: "sra-tools",
            command: [tool, "SRR1"],
            inputs: ["SRR1"],
            outputs: [],
            exitCode: exitCode,
            wallTime: 1,
            stderr: exitCode == 0 ? "" : "disk full",
            startedAt: start,
            completedAt: start.addingTimeInterval(1)
        )
    }

    private static func write(
        into bundle: URL,
        preference: SRADownloadSourcePreference,
        source: SRAFASTQDownloadSource,
        fallbackMessage: String?,
        enaSteps: [StepExecution],
        toolkitTraces: [SRAService.FASTQDownloadStepTrace]
    ) throws {
        try writeGUISRAFASTQImportProvenance(
            accession: "SRR1",
            readRecord: nil,
            downloadSource: source.rawValue,
            preferredSource: preference,
            fallbackMessage: fallbackMessage,
            enaDownloadSteps: enaSteps,
            toolkitDownloadTraces: toolkitTraces,
            cliArguments: ["import", "fastq"],
            cliStartedAt: Date(timeIntervalSince1970: 2_000),
            cliCompletedAt: Date(timeIntervalSince1970: 2_001),
            stagedFASTQFiles: [],
            finalFASTQURL: bundle.appendingPathComponent("reads.fastq.gz"),
            bundleURL: bundle,
            platform: "illumina",
            recipeName: nil,
            qualityBinning: "none",
            optimizeStorage: false,
            compressionLevel: "fast",
            cliBinaryPath: { URL(fileURLWithPath: "/injected/lungfish-cli") }
        )
    }
}
