import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Pins what `lungfish-cli ops stats` makes of every case of the provenance compatibility
/// corpus, as the command behaves today.
///
/// `ops stats` looks only at files named exactly `.lungfish-provenance.json`, decodes each
/// one with a plain ISO 8601 decoder as a `WorkflowRun`, and drops what does not decode
/// without a word. So a run-bearing envelope or a bare run is counted, an envelope without
/// the eight compat keys or a primitive record is dropped, and a file sidecar such as
/// `<file>.lungfish-provenance.json` is never seen. A later lane that removes the compat
/// keys, or moves `ops stats` to the envelope reader, changes these numbers on purpose and
/// updates the pins in the same commit.
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
        // Counted, because the encoder writes the eight compat keys.
        "s1-canonical-envelope-run": Pin(sidecars: 1, completed: 1),
        "s1-db-receipt-kraken2-viral": Pin(sidecars: 1, completed: 1),
        "s1-recorder-readsetplan": Pin(sidecars: 1, completed: 1),
        // Seen but dropped, because an envelope without the compat keys does not decode as a run.
        "s2-analysis-kraken2-fixture": Pin(sidecars: 1, completed: 0),
        // A bare run counts when it has the directory sidecar name.
        "s3-gatk-container-bare-run": Pin(sidecars: 1, completed: 1),
        // Never seen. The file is named <file>.lungfish-provenance.json, which the aggregator skips.
        "s3-ncbi-fetch-alpha11": Pin(sidecars: 0, completed: 0),
        // A bare run counts when it has the directory sidecar name.
        "s3-write-sidecar-bare-run": Pin(sidecars: 1, completed: 1),
        // Seen but dropped, because a primitive record does not decode as a run.
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
