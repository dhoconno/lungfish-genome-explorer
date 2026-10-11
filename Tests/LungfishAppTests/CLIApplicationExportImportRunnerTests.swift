import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

final class CLIApplicationExportImportRunnerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try super.tearDownWithError()
    }

    func testBuildApplicationExportArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/tmp/CLC Export.zip")
        let project = URL(fileURLWithPath: "/tmp/Project.lungfish")

        let args = CLIApplicationExportImportRunner.buildApplicationExportArguments(
            sourceURL: source,
            projectURL: project,
            kind: .clcWorkbench
        )

        XCTAssertEqual(args, [
            "import", "application-export", "clc-workbench", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testBuildGeneiousArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/tmp/MCM_MHC_haplotypes-annotated.geneious")
        let project = URL(fileURLWithPath: "/tmp/Project.lungfish")

        let args = CLIApplicationExportImportRunner.buildGeneiousArguments(
            sourceURL: source,
            projectURL: project
        )

        XCTAssertEqual(args, [
            "import", "geneious", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testParseApplicationExportProgressEvent() throws {
        let json = """
        {"event":"applicationExportProgress","progress":0.42,"message":"Processing refs/reference.fa"}
        """

        let event = try XCTUnwrap(CLIApplicationExportImportRunner.parseEvent(from: json))

        guard case let .progress(progress, message) = event else {
            return XCTFail("Expected progress event, got \(event)")
        }
        XCTAssertEqual(progress, 0.42, accuracy: 0.0001)
        XCTAssertEqual(message, "Processing refs/reference.fa")
    }

    func testParseApplicationExportCompleteEvent() throws {
        let json = """
        {"event":"applicationExportImportComplete","collection":"/tmp/Project.lungfish/Application Exports/Example CLC Workbench Import","warningCount":2}
        """

        let event = try XCTUnwrap(CLIApplicationExportImportRunner.parseEvent(from: json))

        guard case let .complete(collection, warningCount) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(collection, "/tmp/Project.lungfish/Application Exports/Example CLC Workbench Import")
        XCTAssertEqual(warningCount, 2)
    }

    func testRunStreamsProgressEventsIntoOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let collection = tempDir.appendingPathComponent("Imported Collection", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"applicationExportImportStart","kind":"clc-workbench","source":"/tmp/source.zip"}'
        printf '%s\\n' '{"event":"applicationExportProgress","progress":0.5,"message":"Processing refs/reference.fa"}'
        printf '%s\\n' '{"event":"applicationExportWarning","message":"reports/summary.tsv was preserved"}'
        printf '%s\\n' '{"event":"applicationExportImportComplete","collection":"\(collection.path)","warningCount":1}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "CLC Workbench Import",
                detail: "Launching...",
                operationType: .applicationExportImport,
                cliCommand: nil
            ).rowID
        }

        let result = try await CLIApplicationExportImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        // The event glue hops to the main queue; wait for the row to catch up
        // instead of sleeping a fixed 50 ms.
        await waitUntil {
            await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }?.logEntries.contains { $0.message == "reports/summary.tsv was preserved" } == true
            }
        }
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.collectionURL.path, collection.path)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Processing refs/reference.fa")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "reports/summary.tsv was preserved" } == true)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    // MARK: - Phase 2.6 lane C5, what the runner shows for each stream an older CLI prints

    /// Pins of what the Operations Panel row and the sidebar import get from the runner today. Each
    /// stream is a checked-in transcript of the private events that `import geneious` and
    /// `import application-export` printed before version 2, played back by a stand-in `lungfish-cli`.
    /// The runner moves onto `CLISubprocessTransport` in a later step of the lane, and these pins
    /// must pass unchanged on the other side, which is how an older CLI is shown to give the same
    /// label, log and imported collection. `ImportRunnerReplay` is declared in
    /// `CLINativeBundleImportRunnerTests.swift`.
    private func replay(
        _ name: String,
        exitCode: Int32 = 0,
        standardError: [String] = []
    ) async throws -> ImportRunnerShown {
        try await ImportRunnerReplay.replay(
            ImportRunnerReplay.legacyTranscript(name),
            title: "Geneious Import",
            operationType: .applicationExportImport,
            exitCode: exitCode,
            standardError: standardError,
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLIApplicationExportImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.collectionURL.path, result.warningCount)
        }
    }

    func testAnOlderCLIsCleanGeneiousImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-geneious")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Geneious Imports/Representative Geneious Import",
            warningCount: 0,
            failure: nil,
            progress: 1,
            detail: "Geneious import complete.",
            log: ["info: Started geneious-export import via lungfish-cli"],
            hasWarnings: false,
            label: "Completed"
        ))
    }

    func testAnOlderCLIsGeneiousImportWithWarningsShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-geneious-with-warning")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Geneious Imports/Representative Geneious Import",
            warningCount: 5,
            failure: nil,
            progress: 1,
            detail: "Geneious import complete.",
            log: [
                "info: Started geneious-export import via lungfish-cli",
                "warning: Native Geneious data is preserved but not decoded in the no-Geneious baseline.",
                "warning: document.geneious contains native Geneious data that is preserved but not decoded in the no-Geneious baseline.",
                "warning: fileData.1 contains native Geneious data that is preserved but not decoded in the no-Geneious baseline.",
                "warning: refs/reference.fa is a standalone reference sequence but reference import was disabled; preserved as a binary artifact.",
                "warning: reports/summary.tsv is recognized as report but is not auto-routed in the no-Geneious baseline; preserved as a binary artifact.",
            ],
            hasWarnings: true,
            label: "Completed with Warnings"
        ))
    }

    func testAnOlderCLIsRefusedGeneiousImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-geneious-failed", exitCode: 3)

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: nil,
            warningCount: nil,
            failure: "Input file not found: /work/inputs/missing.geneious",
            progress: 0.01,
            detail: "Launching lungfish-cli...",
            log: [
                "info: Started geneious-export import via lungfish-cli",
                "error: Input file not found: /work/inputs/missing.geneious",
            ],
            hasWarnings: false,
            label: "Failed"
        ))
    }

    func testAnOlderCLIsCleanApplicationExportImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-application-export")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Application Exports/Alignment Tree Export Alignment Tree Import",
            warningCount: 0,
            failure: nil,
            progress: 1,
            detail: "Alignment Tree import complete.",
            log: ["info: Started alignment-tree import via lungfish-cli"],
            hasWarnings: false,
            label: "Completed"
        ))
    }

    func testAnOlderCLIsApplicationExportImportWithAWarningShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-application-export-with-warning")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Application Exports/Alignment Tree Export Alignment Tree Import",
            warningCount: 1,
            failure: nil,
            progress: 1,
            detail: "Alignment Tree import complete.",
            log: [
                "info: Started alignment-tree import via lungfish-cli",
                "warning: reports/summary.tsv is recognized as report but is not imported by this native-only operation.",
            ],
            hasWarnings: true,
            label: "Completed with Warnings"
        ))
    }

    func testAnOlderCLIsRefusedApplicationExportImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-application-export-failed", exitCode: 3)

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: nil,
            warningCount: nil,
            failure: "Input file not found: /work/inputs/missing",
            progress: 0.01,
            detail: "Launching lungfish-cli...",
            log: [
                "info: Started alignment-tree import via lungfish-cli",
                "error: Input file not found: /work/inputs/missing",
            ],
            hasWarnings: false,
            label: "Failed"
        ))
    }

    func testTheWarningCountIsTheNumberOfWarningLinesOfTheStream() async throws {
        let transcript = try ImportRunnerReplay.writeTranscript([
            #"{"event":"applicationExportImportStart","kind":"clc-workbench","source":"/work/inputs/e.zip"}"#,
            #"{"event":"applicationExportWarning","message":"first"}"#,
            #"{"event":"applicationExportWarning","message":"second"}"#,
            #"{"collection":"/work/Project.lungfish/Application Exports/e CLC Workbench Import","event":"applicationExportImportComplete","warningCount":2}"#,
        ], in: try makeTemporaryDirectory())
        let shown = try await ImportRunnerReplay.replay(
            transcript,
            title: "CLC Workbench Import",
            operationType: .applicationExportImport,
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLIApplicationExportImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.collectionURL.path, result.warningCount)
        }

        XCTAssertEqual(shown.warningCount, 2)
        XCTAssertEqual(shown.log.filter { $0.hasPrefix("warning: ") }, ["warning: first", "warning: second"])
        XCTAssertEqual(shown.label, "Completed with Warnings")
    }

    /// A line that is not an event, and an event the runner does not know, change nothing.
    func testChatterAndUnknownEventsInTheStreamAreIgnored() async throws {
        let transcript = try ImportRunnerReplay.writeTranscript([
            "Importing e.zip",
            #"{"event":"applicationExportImportStart","kind":"clc-workbench","source":"/work/inputs/e.zip"}"#,
            #"{"event":"applicationExportImportPaused","message":"waiting"}"#,
            #"{"note":"a line with no event name"}"#,
            #"{"collection":"/work/Project.lungfish/Application Exports/e CLC Workbench Import","event":"applicationExportImportComplete","warningCount":0}"#,
        ], in: try makeTemporaryDirectory())
        let shown = try await ImportRunnerReplay.replay(
            transcript,
            title: "CLC Workbench Import",
            operationType: .applicationExportImport,
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLIApplicationExportImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.collectionURL.path, result.warningCount)
        }

        XCTAssertEqual(shown.importedPath, "/work/Project.lungfish/Application Exports/e CLC Workbench Import")
        XCTAssertEqual(shown.log, ["info: Started clc-workbench import via lungfish-cli"])
        XCTAssertEqual(shown.label, "Completed")
    }

    func testAStreamThatNamesNoCollectionEndsWithTheMissingCollectionMessage() async throws {
        for lines in [
            [#"{"event":"applicationExportImportStart","kind":"clc-workbench","source":"/work/inputs/e.zip"}"#],
            [#"{"event":"applicationExportImportComplete","collection":"  ","warningCount":0}"#],
            [#"{"event":"applicationExportImportComplete","warningCount":0}"#],
        ] {
            let transcript = try ImportRunnerReplay.writeTranscript(lines, in: try makeTemporaryDirectory())
            let shown = try await ImportRunnerReplay.replay(
                transcript,
                title: "CLC Workbench Import",
                operationType: .applicationExportImport,
                directory: try makeTemporaryDirectory()
            ) { cli, operationID in
                let result = try await CLIApplicationExportImportRunner(cliURLOverride: cli)
                    .run(arguments: [], operationID: operationID)
                return (result.collectionURL.path, result.warningCount)
            }

            XCTAssertNil(shown.importedPath, "\(lines)")
            XCTAssertEqual(shown.failure, "lungfish-cli finished without reporting an imported collection.", "\(lines)")
        }
    }

    func testAFailedEventWinsEvenWhenTheCLIExitsCleanly() async throws {
        let shown = try await replay("import-application-export-failed", exitCode: 0)

        XCTAssertEqual(shown.failure, "Input file not found: /work/inputs/missing")
        XCTAssertNil(shown.importedPath)
    }

    func testANonzeroExitWithNoFailedEventShowsTheExitStatusAndStandardError() async throws {
        let transcript = try ImportRunnerReplay.writeTranscript(
            [#"{"event":"applicationExportImportStart","kind":"clc-workbench","source":"/work/inputs/e.zip"}"#],
            in: try makeTemporaryDirectory()
        )
        let shown = try await ImportRunnerReplay.replay(
            transcript,
            title: "CLC Workbench Import",
            operationType: .applicationExportImport,
            exitCode: 7,
            standardError: ["conda lock wait expired"],
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLIApplicationExportImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.collectionURL.path, result.warningCount)
        }

        XCTAssertEqual(shown.failure, "lungfish-cli exited with status 7: conda lock wait expired")
        XCTAssertNil(shown.importedPath)
    }

    func testALaunchThatFailsMarksTheRowFailedBeforeTheRunnerThrows() async throws {
        let missing = try makeTemporaryDirectory().appendingPathComponent("no-such-cli")
        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "Geneious Import",
                detail: "Launching...",
                operationType: .applicationExportImport,
                cliCommand: nil
            ).rowID
        }

        var thrown: Error?
        do {
            _ = try await CLIApplicationExportImportRunner(cliURLOverride: missing).run(arguments: [], operationID: opID)
        } catch {
            thrown = error
        }
        let item = await MainActor.run { OperationCenter.shared.items.first { $0.id == opID } }

        XCTAssertTrue(
            (thrown as? CLIApplicationExportImportRunner.RunError)?.localizedDescription.hasPrefix("Failed to launch lungfish-cli: ") == true,
            "\(String(describing: thrown))"
        )
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(item?.displayStateLabel, "Failed")
        await MainActor.run { OperationCenter.shared.clearItem(id: opID) }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-application-export-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }
}
