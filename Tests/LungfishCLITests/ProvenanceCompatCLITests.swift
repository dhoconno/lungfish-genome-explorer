import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Pins what `lungfish-cli ops stats` makes of every case of the provenance compatibility
/// corpus.
///
/// `ops stats` looks only at files named exactly `.lungfish-provenance.json` and reads each
/// through `ProvenanceEnvelopeReader`. A record counts as a completed run when it decodes as an
/// envelope or a bare run and states that its run completed. So a run-bearing envelope or a bare
/// run is counted, an envelope that states no status and a primitive record are seen but not
/// counted, and a file sidecar such as `<file>.lungfish-provenance.json` is never seen. Phase 2.6
/// moved the command off its `WorkflowRun` decoder with every pin unchanged, and a record
/// without the compat keys of version 1 counts as its version 1 source does.
final class ProvenanceCompatCLITests: XCTestCase {
    struct Pin {
        /// The "Provenance sidecars" line.
        let sidecars: Int
        /// The "Completed runs" line.
        let completed: Int
    }

    /// Pinned by hand from the bytes and the file names. A case missing here fails the suite.
    static let pins: [String: Pin] = [
        // Counted, but the run is cancelled, so it is not a completed run.
        "s1-cancelled-single-step": Pin(sidecars: 1, completed: 0),
        // Counted, because the record states that its run completed.
        "s1-canonical-envelope-run": Pin(sidecars: 1, completed: 1),
        "s1-db-receipt-kraken2-viral": Pin(sidecars: 1, completed: 1),
        "s1-recorder-readsetplan": Pin(sidecars: 1, completed: 1),
        // Seen but not counted, because the envelope states no status, and an exit status of 0
        // alone does not tell a completed run from a cancelled one.
        "s2-analysis-kraken2-fixture": Pin(sidecars: 1, completed: 0),
        // A bare run counts when it has the directory sidecar name.
        "s3-gatk-container-bare-run": Pin(sidecars: 1, completed: 1),
        // Never seen. The file is named <file>.lungfish-provenance.json, which the aggregator skips.
        "s3-ncbi-fetch-alpha11": Pin(sidecars: 0, completed: 0),
        // A bare run counts when it has the directory sidecar name.
        "s3-write-sidecar-bare-run": Pin(sidecars: 1, completed: 1),
        // Seen but not counted, because only the primitive adapter reads it and it states no status.
        "s4-mcm-mhcref-shipped": Pin(sidecars: 1, completed: 0),
        "s4-msa-mafft-2026-05": Pin(sidecars: 1, completed: 0),
    ]

    func testEveryCaseHasAnOpsStatsPin() throws {
        let ids = Set(try ProvenanceCompatCorpus.cases().map(\.id))
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(ids, Set(Self.pins.keys), "every corpus case needs an ops stats pin, and every pin a case")
    }

    func testOpsStatsReportsThePinnedCountsForEveryCase() async throws {
        for item in try ProvenanceCompatCorpus.cases() {
            let pin = try XCTUnwrap(Self.pins[item.id], "case \(item.id) has no ops stats pin")
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }

            let report = try await runOpsStats(on: materialized.projectRoot)
            XCTAssertEqual(report.sidecars, pin.sidecars, "Provenance sidecars for \(item.id)")
            XCTAssertEqual(report.completed, pin.completed, "Completed runs for \(item.id)")
            if pin.completed == 0 {
                XCTAssertTrue(
                    report.text.contains("No completed operation provenance found."),
                    "case \(item.id) should report no completed operation"
                )
            } else {
                let facts = try ProvenanceCompatFacts.project(
                    sidecar: materialized.sidecar,
                    projectRoot: materialized.projectRoot
                )
                XCTAssertTrue(
                    report.text.contains(facts.workflowName),
                    "the operation table for \(item.id) should name the run \(facts.workflowName)"
                )
            }
        }
    }

    func testOpsStatsPinsAgreeWithTheExpectedFacts() throws {
        for item in try ProvenanceCompatCorpus.cases() {
            let pin = try XCTUnwrap(Self.pins[item.id])
            let expectedData = try XCTUnwrap(
                ProvenanceCompatCorpus.expectedFactsData(for: item.id),
                "case \(item.id) has no expected facts"
            )
            let facts = try ProvenanceCompatFacts.decode(expectedData)
            let named = (item.layoutPath as NSString).lastPathComponent == ProvenanceCompatCorpus.sidecarFilename
            // The command only counts the directory sidecar name. The facts say what the bytes
            // would do under that name.
            XCTAssertEqual(pin.sidecars, named ? 1 : 0, "sidecar name of \(item.id)")
            XCTAssertEqual(
                pin.completed,
                named ? facts.opsStats.completedRunCount : 0,
                "completed runs of \(item.id) against its expected facts"
            )
            if pin.completed > 0 {
                XCTAssertTrue(facts.opsStats.decodesAsWorkflowRun, "a counted run decodes as a run: \(item.id)")
            }
            // By shape, S1 and S3 decode as a run, S2 and S4 do not.
            let decodesByShape = item.shape == "S1" || item.shape == "S3"
            XCTAssertEqual(facts.opsStats.decodesAsWorkflowRun, decodesByShape, "decode of \(item.id) by shape \(item.shape)")
        }
    }

    func testAlpha11BytesAreCountedOnlyUnderTheDirectorySidecarName() async throws {
        let materialized = try ProvenanceCompatCorpus.materialize("s3-ncbi-fetch-alpha11")
        defer { materialized.cleanup() }
        let sidecarBytes = try Data(contentsOf: materialized.sidecar)

        // Under its real name the aggregator never looks at it.
        let underRealName = try await runOpsStats(on: materialized.projectRoot)
        XCTAssertEqual(underRealName.sidecars, 0)
        XCTAssertEqual(underRealName.completed, 0)

        // The same bytes under the directory sidecar name are a bare run that decodes, so S3 is counted.
        let renamedProject = materialized.temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Renamed.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: renamedProject, withIntermediateDirectories: true)
        try sidecarBytes.write(to: renamedProject.appendingPathComponent(ProvenanceCompatCorpus.sidecarFilename))
        let underDirectoryName = try await runOpsStats(on: renamedProject)
        XCTAssertEqual(underDirectoryName.sidecars, 1)
        XCTAssertEqual(underDirectoryName.completed, 1)
        XCTAssertTrue(underDirectoryName.text.contains("ncbi-sequence-fetch"))
    }

    /// Version 2 drops the 14 alias keys (plan decision S3). The command counts each envelope case
    /// without them exactly as its pin says.
    func testOpsStatsCountsTheVersion2FormOfEveryEnvelopeCaseAsItsPin() async throws {
        for item in try ProvenanceCompatCorpus.cases() where item.shape == "S1" {
            let pin = try XCTUnwrap(Self.pins[item.id])
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            try Self.version2(of: Data(contentsOf: materialized.sidecar)).write(to: materialized.sidecar)

            let report = try await runOpsStats(on: materialized.projectRoot)
            XCTAssertEqual(report.sidecars, pin.sidecars, "Provenance sidecars for version 2 of \(item.id)")
            XCTAssertEqual(report.completed, pin.completed, "Completed runs for version 2 of \(item.id)")
        }
    }

    /// The record without the top-level, step and descriptor alias keys, at `schemaVersion` 2.
    private static func version2(of data: Data) throws -> Data {
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func stripped(_ object: [String: Any], _ keys: [String]) -> [String: Any] {
            object.filter { !keys.contains($0.key) }
        }
        let descriptorAliases = ["sha256", "sizeBytes"]
        record = stripped(record, ["name", "startTime", "endTime", "appVersion", "hostOS", "runtime", "parameters"])
        for key in ["files", "outputs"] {
            record[key] = (record[key] as? [[String: Any]])?.map { stripped($0, descriptorAliases) }
        }
        record["output"] = (record["output"] as? [String: Any]).map { stripped($0, descriptorAliases) }
        record["steps"] = (record["steps"] as? [[String: Any]])?.map { step -> [String: Any] in
            var step = stripped(step, ["command", "exitCode", "wallTime", "startTime", "endTime"])
            for key in ["inputs", "outputs"] {
                step[key] = (step[key] as? [[String: Any]])?.map { stripped($0, descriptorAliases) }
            }
            return step
        }
        record["schemaVersion"] = 2
        return try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Running the command

    private struct OpsStatsReport {
        let text: String
        let sidecars: Int
        let completed: Int
    }

    /// Runs `lungfish-cli ops stats <project> --no-color` in this process and reads the two
    /// counts from its output.
    private func runOpsStats(on project: URL) async throws -> OpsStatsReport {
        let command = try OpsCommand.StatsSubcommand.parse([project.path, "--no-color"])
        let text = try await captureStandardOutput { try await command.run() }
        return OpsStatsReport(
            text: text,
            sidecars: try count(labeled: "Provenance sidecars", in: text),
            completed: try count(labeled: "Completed runs", in: text)
        )
    }

    private func count(labeled label: String, in text: String) throws -> Int {
        for line in text.split(separator: "\n") where line.hasPrefix(label) {
            if let colon = line.firstIndex(of: ":"),
               let value = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        XCTFail("no \(label) line in the ops stats output")
        return -1
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let thrown { throw thrown }
        return String(decoding: data, as: UTF8.self)
    }
}
