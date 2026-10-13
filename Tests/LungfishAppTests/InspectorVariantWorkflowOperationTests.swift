// InspectorVariantWorkflowOperationTests.swift - begin() sites in InspectorViewController+VariantWorkflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Both variant-calling launches lock the bundle (R4). A held lock must refuse
// the row and launch nothing, and the recorded row must carry its type, its
// lock and its command. The GATK run has no lungfish-cli equivalent yet, so
// its test pins today's command and fails when one is added.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class InspectorVariantWorkflowOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a1/Sample.lungfishref", isDirectory: true)
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "variant-launcher")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Primer-trimming with QIAseq Direct",
            detail: "Running",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli bam primer-trim"
        ).startedID)
        return center
    }

    // MARK: - Variant calling through lungfish-cli

    private func variantCallingArguments() -> [String] {
        CLIVariantCallingRunner.buildCLIArguments(request: BundleVariantCallingRequest(
            bundleURL: bundleURL,
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Sample 1 \u{2022} LoFreq",
            threads: 4,
            minimumAlleleFrequency: 0.05,
            minimumDepth: 10
        ))
    }

    func testVariantCallingRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginVariantCallingOperation(
            title: "Calling variants with LoFreq",
            detail: "Preparing LoFreq...",
            bundleURL: bundleURL,
            cliArguments: variantCallingArguments(),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the variant-calling row")
        }
        XCTAssertFalse(launched, "a refused row must launch no runner")
        XCTAssertEqual(refusal.blockingOperationTitle, "Primer-trimming with QIAseq Direct")
    }

    func testVariantCallingRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())
        var launchedID: UUID?

        InspectorViewController.beginVariantCallingOperation(
            title: "Calling variants with LoFreq",
            detail: "Preparing LoFreq...",
            bundleURL: bundleURL,
            cliArguments: variantCallingArguments(),
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.operationType, .variantCalling)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: VariantsCommand.CallSubcommand.self)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertEqual(command.alignmentTrackID, "aln-1")
        XCTAssertEqual(command.caller, "lofreq")
        XCTAssertEqual(command.outputTrackName, "Sample 1 \u{2022} LoFreq")
        XCTAssertEqual(command.minimumAlleleFrequency, 0.05)
        XCTAssertEqual(command.minimumDepth, 10)
    }

    // MARK: - GATK, a CLI parity gap

    private func gatkRequest() -> GATKPipelineExecutionRequest {
        let directory = URL(fileURLWithPath: "/tmp/lane 1a1/gatk", isDirectory: true)
        let reference = directory.appendingPathComponent("reference.fa")
        let bam = directory.appendingPathComponent("sample.bam")
        let output = directory.appendingPathComponent("sample.vcf.gz")
        return GATKPipelineExecutionRequest(
            workflowName: "GATK HaplotypeCaller",
            toolName: "gatk-haplotype-caller",
            toolVersion: "4.6.2.0",
            command: GATKCommand(arguments: [
                "HaplotypeCaller", "-R", reference.path, "-I", bam.path, "-O", output.path,
            ]),
            outputDirectory: directory,
            inputs: [
                GATKFileArtifact(url: reference, format: .fasta, role: .reference),
                GATKFileArtifact(url: bam, format: .bam, role: .input),
            ],
            outputs: [GATKFileArtifact(url: output, format: .vcf, role: .output)],
            options: [:],
            resolvedDefaults: [:]
        )
    }

    func testGATKVariantCallingRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = InspectorViewController.beginGATKVariantCallingOperation(
            title: "Calling variants with GATK HaplotypeCaller",
            detail: "Running GATK HaplotypeCaller...",
            bundleURL: bundleURL,
            request: gatkRequest(),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused = result else {
            return XCTFail("a held bundle lock must refuse the GATK row")
        }
        XCTAssertFalse(launched, "a refused row must start no GATK pipeline and attach nothing")
    }

    func testGATKVariantCallingRecordsNoCommandAsAParityGapAndLogsTheGATKCommands() throws {
        let reporter = RecordingOperationReporter()
        let request = gatkRequest()

        InspectorViewController.beginGATKVariantCallingOperation(
            title: "Calling variants with GATK HaplotypeCaller",
            detail: "Running GATK HaplotypeCaller...",
            bundleURL: bundleURL,
            request: request,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.operationType, .variantCalling)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        // No lungfish-cli command runs GATK and attaches the VCF to the
        // bundle. The closest is `gatk haplotype-caller --execute`. The row
        // records no command and logs the GATK commands instead.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "gatk-variant-calling")
        XCTAssertEqual(
            item.logs.map(\.message),
            request.commands.map { "GATK command: \($0.shellCommand)" }
        )
    }

    // MARK: - What the launcher does with the events of a run (Phase 2.6 lane C6)

    /// Each event kind, fed through the closure the launcher gives its runner, and what the row
    /// shows afterwards. The closure hops to the main queue, so each step waits for its log line.
    func testEachEventLandsOnTheRowTheWayTheLauncherHandlesIt() async throws {
        let id = beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = InspectorViewController.variantCallingEventHandler(operationID: id)

        handle(.start(message: "Starting LoFreq variant calling"))
        await waitForLog(of: id, count: 1)
        XCTAssertEqual(row(id)?.detail, "Starting LoFreq variant calling")
        // The hand mapper showed the start at 1 percent. The bridge shows it at 0, the value the CLI wrote.
        XCTAssertEqual(row(id)?.progress, 0)

        // The caller workflow and the SQLite import each report 0 to 1, and the bar keeps to 0.10...0.88.
        handle(.progress(fraction: 0.0, message: "Staging reference and alignment inputs"))
        await waitForLog(of: id, count: 2)
        XCTAssertEqual(row(id)?.progress, 0.10)
        handle(.progress(fraction: 0.45, message: "Running LoFreq"))
        await waitForLog(of: id, count: 3)
        XCTAssertEqual(row(id)?.progress, 0.45)
        XCTAssertEqual(row(id)?.detail, "Running LoFreq")
        handle(.progress(fraction: 1.0, message: "Done (2 variants, 0 samples)"))
        await waitForLog(of: id, count: 4)
        XCTAssertEqual(row(id)?.progress, 0.88)

        // A log event changes the history only, at its own level.
        handle(.log(level: .warning, message: "Reference contig names were matched by alias."))
        await waitForLog(of: id, count: 5)
        XCTAssertEqual(row(id)?.progress, 0.88)
        XCTAssertEqual(row(id)?.detail, "Done (2 variants, 0 samples)")

        // An output event changes nothing.
        handle(.output(path: "/work/variants.vcf.gz", role: "variants"))
        handle(.log(level: .debug, message: "After the output event"))
        await waitForLog(of: id, count: 6)

        // A failed event changes nothing on the row. The transport throws it, and the launcher ends the
        // row with `fail`, which logs the failure once. The hand mapper also set the bar to 99 percent
        // and logged the message a second time in front of it.
        handle(.failed(message: "LoFreq stopped", detail: nil))
        handle(.log(level: .debug, message: "After the failed event"))
        await waitForLog(of: id, count: 7)
        XCTAssertEqual(row(id)?.progress, 0.88)
        XCTAssertEqual(row(id)?.detail, "Done (2 variants, 0 samples)")
        XCTAssertTrue(OperationCenter.shared.fail(id: id, detail: "LoFreq stopped", errorMessage: "LoFreq stopped"))
        XCTAssertEqual(row(id)?.displayStateLabel, "Failed")

        XCTAssertEqual(loggedLines(of: id), [
            "info: Starting LoFreq variant calling",
            "info: Staging reference and alignment inputs",
            "info: Running LoFreq",
            "info: Done (2 variants, 0 samples)",
            "warning: Reference contig names were matched by alias.",
            "debug: After the output event",
            "debug: After the failed event",
            "error: Failed: LoFreq stopped",
        ])
    }

    /// The captured run of `variants call` played through a stand-in CLI, the runner and the
    /// launcher's closure, then ended the way the launcher ends a success. The row keeps every
    /// start, progress and log line, and the runner finds the three files and the track.
    func testPlayingTheCapturedRunLeavesTheRowCompletedWithItsLogAndTheRunnerWithItsFiles() async throws {
        for oldCLI in [false, true] {
            let lines = try capturedRun(asVersion1: oldCLI)
            let completion = try completion(of: lines)
            let id = beginRow()
            defer { OperationCenter.shared.clearItem(id: id) }

            let result = try await CLIVariantCallingRunner(cliURLOverride: try standInCLI(printing: lines))
                .run(arguments: [], onEvent: InspectorViewController.variantCallingEventHandler(operationID: id))

            let expectedLog = try expectedHistory(of: lines)
            await waitForLog(of: id, count: expectedLog.count)
            XCTAssertTrue(
                OperationCenter.shared.complete(id: id, detail: InspectorViewController.variantCallingCompletionDetail(for: result))
            )

            XCTAssertEqual(result.databasePath, completion.outputs[0], "oldCLI \(oldCLI)")
            XCTAssertEqual(result.vcfPath, completion.outputs[1], "oldCLI \(oldCLI)")
            XCTAssertEqual(result.tbiPath, completion.outputs[2], "oldCLI \(oldCLI)")
            XCTAssertEqual(result.trackName, completion.trackName, "oldCLI \(oldCLI)")
            XCTAssertEqual(result.trackID, completion.trackID, "oldCLI \(oldCLI)")
            XCTAssertTrue(try XCTUnwrap(result.databasePath).hasSuffix(".db"))
            XCTAssertTrue(try XCTUnwrap(result.vcfPath).hasSuffix(".vcf.gz"))
            XCTAssertTrue(try XCTUnwrap(result.tbiPath).hasSuffix(".vcf.gz.tbi"))
            let item = try XCTUnwrap(row(id))
            XCTAssertEqual(item.displayStateLabel, "Completed", "oldCLI \(oldCLI)")
            XCTAssertEqual(item.detail, "Created variant track \(completion.trackName)", "oldCLI \(oldCLI)")
            XCTAssertEqual(item.progress, 1, "oldCLI \(oldCLI)")
            XCTAssertEqual(loggedLines(of: id), expectedLog, "oldCLI \(oldCLI)")
            XCTAssertEqual(
                loggedLines(of: id).filter { $0 == "info: Parsing variants (0)..." }.count, 1,
                "oldCLI \(oldCLI): the captured run says it twice in a row and the history holds it once"
            )
            XCTAssertEqual(item.bundleURLs, [], "oldCLI \(oldCLI): the run imports no file, the track is already in the bundle")
            XCTAssertEqual(item.outputURLs, [], "oldCLI \(oldCLI)")
        }
    }

    /// The caller workflow and the SQLite import each report 0 to 1. The closure keeps both to
    /// 0.10...0.88 and the bridge holds the bar, so the import's first fractions do not pull the bar
    /// back to 0.10. A message that repeats is logged once, by the bridge alone (Phase 2.10 lane U32).
    func testTheBarHoldsAtTheTopOfItsRangeWhenTheImportRestartsAndARepeatedMessageIsLoggedOnce() async throws {
        let id = beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = InspectorViewController.variantCallingEventHandler(operationID: id)

        handle(.progress(fraction: 0.92, message: "Indexing compressed VCF"))
        await waitForLog(of: id, count: 1)
        XCTAssertEqual(row(id)?.progress, 0.88, "the caller workflow ends at the top of the range")

        handle(.progress(fraction: 0.05, message: "Parsing VCF (Ultra Low Memory profile)..."))
        handle(.progress(fraction: 0.9, message: "Parsing variants (0)..."))
        handle(.progress(fraction: 0.9, message: "Parsing variants (0)..."))
        await eventsApplied()

        XCTAssertEqual(row(id)?.progress, 0.88, "the import starts again at 0 and the bar stays")
        XCTAssertEqual(row(id)?.detail, "Parsing variants (0)...")
        XCTAssertEqual(loggedLines(of: id), [
            "info: Indexing compressed VCF",
            "info: Parsing VCF (Ultra Low Memory profile)...",
            "info: Parsing variants (0)...",
        ])
    }

    /// A warning logged during the run reads Completed with Warnings, as it does for every runner.
    func testAWarningLoggedDuringTheRunReadsCompletedWithWarnings() async throws {
        let id = beginRow()
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = InspectorViewController.variantCallingEventHandler(operationID: id)

        handle(.start(message: "Starting LoFreq variant calling"))
        handle(.log(level: .warning, message: "Reference contig names were matched by alias."))
        await waitForLog(of: id, count: 2)
        XCTAssertTrue(OperationCenter.shared.complete(id: id, detail: "Created variant track Sample LoFreq"))

        XCTAssertEqual(row(id)?.displayStateLabel, "Completed with Warnings")
    }

    // MARK: Rows, logs and the captured run

    private func beginRow() -> UUID {
        OperationCenter.shared.begin(
            title: "Calling variants with LoFreq",
            detail: "Preparing LoFreq...",
            operationType: .variantCalling,
            cliCommand: nil
        ).rowID
    }

    private func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private func loggedLines(of id: UUID) -> [String] {
        (row(id)?.logEntries ?? [])
            .filter { !$0.isElisionMarker }
            .map { "\($0.level.rawValue): \($0.message)" }
    }

    private func waitForLog(of id: UUID, count: Int) async {
        await waitUntil(timeout: .seconds(30)) { self.loggedLines(of: id).count >= count }
    }

    /// Returns once the bridge has applied every event handed to it so far. It hops each event to the
    /// main queue in arrival order, so a block queued afterwards runs after all of them.
    private func eventsApplied() async {
        await withCheckedContinuation { (applied: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { applied.resume() }
        }
    }

    /// The lines of the real run of `variants call` kept under `Tests/Fixtures/cli-events`, or
    /// the same lines as a version 1 CLI wrote them, with no version and no artifacts.
    private func capturedRun(asVersion1: Bool) throws -> [String] {
        let url = ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/cli-events/commands/variants-call/complete.ndjson")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard asVersion1 else { return lines }
        return try lines.map { line in
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            object["schemaVersion"] = nil
            object["artifacts"] = nil
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    private func completion(of lines: [String]) throws -> (outputs: [String], trackID: String, trackName: String) {
        let decoder = CLIEventLineDecoder()
        guard case let .complete(outputs, message)? = try decoder.decode(line: try XCTUnwrap(lines.last)),
              let message,
              let idRange = message.range(of: "trackID="),
              let nameRange = message.range(of: " trackName=") else {
            throw XCTSkip("The captured run does not end in a completion that names its track")
        }
        return (
            outputs,
            String(message[idRange.upperBound..<nameRange.lowerBound]),
            String(message[nameRange.upperBound...])
        )
    }

    /// What the bridge keeps in the history. Each start and log line, in order and at its own level,
    /// each progress message once when it differs from the entry before it, and nothing for the
    /// completion. The captured run repeats `Parsing variants (0)...`, which the history holds once.
    private func expectedHistory(of lines: [String]) throws -> [String] {
        let decoder = CLIEventLineDecoder()
        var history: [String] = []
        for line in lines {
            switch try decoder.decode(line: line) {
            case let .start(message)?: history.append("info: \(message)")
            case let .progress(_, message)?:
                if !message.isEmpty, history.last != "info: \(message)" { history.append("info: \(message)") }
            case let .log(level, message)?: history.append("\(level.rawValue): \(message)")
            default: break
            }
        }
        return history
    }

    /// A shell script in place of `lungfish-cli` that prints `lines` on standard output.
    private func standInCLI(printing lines: [String]) throws -> URL {
        let tag = UUID().uuidString
        let text = folder.appendingPathComponent("lines-\(tag).ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: text, atomically: true, encoding: .utf8)
        let url = folder.appendingPathComponent("lungfish-cli-\(tag)")
        try "#!/bin/sh\n/bin/cat '\(text.path)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
