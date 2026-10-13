import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

final class CLINativeBundleImportRunnerTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        try super.tearDownWithError()
    }

    func testBuildMSAArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/project/aligned.fasta")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")

        let args = CLINativeBundleImportRunner.buildArguments(
            sourceURL: source,
            projectURL: project,
            kind: .msa
        )

        XCTAssertEqual(args, [
            "import", "msa", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    func testBuildTreeArgumentsUseJSONProgressFormat() {
        let source = URL(fileURLWithPath: "/project/tree.nwk")
        let project = URL(fileURLWithPath: "/project/Project.lungfish")

        let args = CLINativeBundleImportRunner.buildArguments(
            sourceURL: source,
            projectURL: project,
            kind: .tree
        )

        XCTAssertEqual(args, [
            "import", "tree", source.path,
            "--project", project.path,
            "--format", "json",
        ])
    }

    /// The runner has no parser of its own. A complete line of an older CLI reads through the legacy
    /// table to the bundle the runner imports, with one typed artifact for it. The `warningCount` key is
    /// not read, because the runner counts the warning lines in front of the completion.
    func testAnOlderCLIsCompleteLineReadsToTheBundleTheRunnerImports() throws {
        let json = """
        {"event":"nativeBundleImportComplete","bundle":"/project/Project.lungfish/Phylogenetic Trees/tree.lungfishtree","warningCount":2}
        """

        let line = try XCTUnwrap(try CLIEventLineDecoder().decodeLine(json))

        XCTAssertEqual(
            line.event,
            .complete(outputs: ["/project/Project.lungfish/Phylogenetic Trees/tree.lungfishtree"], message: nil)
        )
        XCTAssertEqual(line.artifacts.map(\.kind), ["phylogenetic-tree"])
    }

    func testRunStreamsProgressEventsIntoOperationCenter() async throws {
        let tempDir = try makeTemporaryDirectory()
        let bundle = tempDir.appendingPathComponent("aligned.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"nativeBundleImportStart","kind":"multiple-sequence-alignment","source":"input.fa"}'
        printf '%s\\n' '{"event":"nativeBundleImportProgress","progress":0.5,"message":"Parsing input.fa"}'
        printf '%s\\n' '{"event":"nativeBundleImportWarning","message":"Duplicate row names are present"}'
        printf '%s\\n' '{"event":"nativeBundleImportComplete","bundle":"\(bundle.path)","warningCount":1}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MSA Import",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentImport,
                cliCommand: nil
            ).rowID
        }

        let result = try await CLINativeBundleImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        // The event glue hops to the main queue; wait for the row to catch up
        // instead of sleeping a fixed 50 ms.
        await waitUntil {
            await MainActor.run {
                OperationCenter.shared.items.first { $0.id == opID }?.logEntries.contains { $0.message == "Duplicate row names are present" } == true
            }
        }
        let item = await MainActor.run {
            OperationCenter.shared.items.first { $0.id == opID }
        }

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(item?.progress, 0.5)
        XCTAssertEqual(item?.detail, "Parsing input.fa")
        XCTAssertTrue(item?.logEntries.contains { $0.level == .warning && $0.message == "Duplicate row names are present" } == true)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    /// Phase 2.2 lane 5B. The App runners read events through the same
    /// launcher as CLISubprocessTransport, so a JSON event line over the 64 KB
    /// line default arrives whole and decodes. It used to be cut in pieces,
    /// and the run then reported no imported bundle.
    func testACompleteEventLineOver64KBIsDecodedWhole() async throws {
        let tempDir = try makeTemporaryDirectory()
        let bundle = tempDir.appendingPathComponent("aligned.lungfishmsa", isDirectory: true)
        let fakeCLI = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"nativeBundleImportWarning","message":"first"}'
        printf '%s\\n' '{"event":"nativeBundleImportWarning","message":"second"}'
        printf '%s\\n' '{"event":"nativeBundleImportWarning","message":"third"}'
        padding=$(/usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\0' 'p')
        printf '%s%s%s\\n' '{"event":"nativeBundleImportComplete","bundle":"\(bundle.path)","warningCount":3,"padding":"' "$padding" '"}'
        """
        try script.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MSA Import",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentImport,
                cliCommand: nil
            ).rowID
        }

        let result = try await CLINativeBundleImportRunner(cliURLOverride: fakeCLI)
            .run(arguments: [], operationID: opID)

        XCTAssertEqual(result.bundleURL.path, bundle.path)
        XCTAssertEqual(result.warningCount, 3)
        await MainActor.run {
            _ = OperationCenter.shared.complete(id: opID, detail: "Test complete")
        }
    }

    // MARK: - Phase 2.6 lane C5, what the runner shows for each stream an older CLI prints

    /// Pins of what the Operations Panel row and the sidebar import get from the runner today. Each
    /// stream is a checked-in transcript of the private events that `import msa` and `import tree`
    /// printed before version 2, played back by a stand-in `lungfish-cli`. The runner moves onto
    /// `CLISubprocessTransport` in a later step of the lane, and these pins must pass unchanged on the
    /// other side, which is how an older CLI is shown to give the same label, log and imported bundle.
    /// Phase 2.10 lane U32 moved each log on purpose. The bridge now logs a progress message once, so a
    /// log holds the start line and the progress messages of the stream in the order they arrived. The
    /// labels, the details and the bars did not move.
    private func replay(
        _ name: String,
        title: String = "MSA Import",
        exitCode: Int32 = 0,
        standardError: [String] = []
    ) async throws -> ImportRunnerShown {
        try await replay(
            transcript: ImportRunnerReplay.legacyTranscript(name),
            title: title,
            exitCode: exitCode,
            standardError: standardError
        )
    }

    private func replay(
        transcript: URL,
        title: String = "MSA Import",
        exitCode: Int32 = 0,
        standardError: [String] = []
    ) async throws -> ImportRunnerShown {
        try await ImportRunnerReplay.replay(
            transcript,
            title: title,
            operationType: .multipleSequenceAlignmentImport,
            exitCode: exitCode,
            standardError: standardError,
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLINativeBundleImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.bundleURL.path, result.warningCount)
        }
    }

    func testAnOlderCLIsCleanMSAImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-msa")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa",
            warningCount: 0,
            failure: nil,
            progress: 0.92,
            detail: "Writing MSA provenance...",
            log: [
                "info: Started multiple-sequence-alignment import via lungfish-cli",
                "info: Preparing MSA bundle destination...",
                "info: Parsing and indexing mhc.aln...",
                "info: Writing MSA provenance...",
            ],
            hasWarnings: false,
            label: "Completed"
        ))
    }

    func testAnOlderCLIsMSAImportWithAWarningShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-msa-with-warning")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Multiple Sequence Alignments/duplicates.lungfishmsa",
            warningCount: 1,
            failure: nil,
            progress: 0.92,
            detail: "Writing MSA provenance...",
            log: [
                "info: Started multiple-sequence-alignment import via lungfish-cli",
                "info: Preparing MSA bundle destination...",
                "info: Parsing and indexing duplicates.fasta...",
                "warning: Duplicate row names are present; stable row IDs preserve row order.",
                "info: Writing MSA provenance...",
            ],
            hasWarnings: true,
            label: "Completed with Warnings"
        ))
    }

    func testAnOlderCLIsRefusedMSAImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-msa-failed", exitCode: 3)

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: nil,
            warningCount: nil,
            failure: "Input file not found: /work/inputs/missing.aln",
            progress: 0.01,
            detail: "Launching lungfish-cli...",
            log: [
                "info: Started multiple-sequence-alignment import via lungfish-cli",
                "error: Input file not found: /work/inputs/missing.aln",
            ],
            hasWarnings: false,
            label: "Failed"
        ))
    }

    func testAnOlderCLIsCleanTreeImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-tree", title: "Tree Import")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Phylogenetic Trees/mhc.lungfishtree",
            warningCount: 0,
            failure: nil,
            progress: 0.92,
            detail: "Writing tree provenance...",
            log: [
                "info: Started phylogenetic-tree import via lungfish-cli",
                "info: Preparing tree bundle destination...",
                "info: Parsing and indexing mhc.nwk...",
                "info: Writing tree provenance...",
            ],
            hasWarnings: false,
            label: "Completed"
        ))
    }

    func testAnOlderCLIsTreeImportWithAWarningShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-tree-with-warning", title: "Tree Import")

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: "/work/Project.lungfish/Phylogenetic Trees/bare.lungfishtree",
            warningCount: 1,
            failure: nil,
            progress: 0.92,
            detail: "Writing tree provenance...",
            log: [
                "info: Started phylogenetic-tree import via lungfish-cli",
                "info: Preparing tree bundle destination...",
                "info: Parsing and indexing bare.nwk...",
                "warning: Tree contains one or more edges without branch lengths.",
                "info: Writing tree provenance...",
            ],
            hasWarnings: true,
            label: "Completed with Warnings"
        ))
    }

    func testAnOlderCLIsRefusedTreeImportShowsWhatTheRunnerShowsToday() async throws {
        let shown = try await replay("import-tree-failed", title: "Tree Import", exitCode: 3)

        XCTAssertEqual(shown, ImportRunnerShown(
            importedPath: nil,
            warningCount: nil,
            failure: "Input file not found: /work/inputs/missing.nwk",
            progress: 0.01,
            detail: "Launching lungfish-cli...",
            log: [
                "info: Started phylogenetic-tree import via lungfish-cli",
                "error: Input file not found: /work/inputs/missing.nwk",
            ],
            hasWarnings: false,
            label: "Failed"
        ))
    }

    /// The count a caller reads is the number of warning lines the CLI printed. An older CLI printed
    /// one line for each warning it counted, so the two agree on every real stream.
    func testTheWarningCountIsTheNumberOfWarningLinesOfTheStream() async throws {
        let transcript = try ImportRunnerReplay.writeTranscript([
            #"{"event":"nativeBundleImportStart","kind":"phylogenetic-tree","source":"/work/inputs/t.nwk"}"#,
            #"{"event":"nativeBundleImportWarning","message":"first"}"#,
            #"{"event":"nativeBundleImportWarning","message":"second"}"#,
            #"{"event":"nativeBundleImportWarning","message":"third"}"#,
            #"{"bundle":"/work/Project.lungfish/Phylogenetic Trees/t.lungfishtree","event":"nativeBundleImportComplete","progress":1,"warningCount":3}"#,
        ], in: try makeTemporaryDirectory())
        let shown = try await ImportRunnerReplay.replay(
            transcript,
            title: "Tree Import",
            operationType: .multipleSequenceAlignmentImport,
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLINativeBundleImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.bundleURL.path, result.warningCount)
        }

        XCTAssertEqual(shown.warningCount, 3)
        XCTAssertEqual(shown.log.filter { $0.hasPrefix("warning: ") }, ["warning: first", "warning: second", "warning: third"])
        XCTAssertEqual(shown.label, "Completed with Warnings")
    }

    /// A line that is not an event, and an event the runner does not know, change nothing.
    func testChatterAndUnknownEventsInTheStreamAreIgnored() async throws {
        let transcript = try ImportRunnerReplay.writeTranscript([
            "Importing mhc.aln",
            #"{"event":"nativeBundleImportStart","kind":"multiple-sequence-alignment","source":"/work/inputs/mhc.aln"}"#,
            #"{"event":"nativeBundleImportPaused","message":"waiting"}"#,
            #"{"note":"a line with no event name"}"#,
            #"{"bundle":"/work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa","event":"nativeBundleImportComplete","progress":1,"warningCount":0}"#,
        ], in: try makeTemporaryDirectory())
        let shown = try await ImportRunnerReplay.replay(
            transcript,
            title: "MSA Import",
            operationType: .multipleSequenceAlignmentImport,
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLINativeBundleImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.bundleURL.path, result.warningCount)
        }

        XCTAssertEqual(shown.importedPath, "/work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa")
        XCTAssertEqual(shown.log, ["info: Started multiple-sequence-alignment import via lungfish-cli"])
        XCTAssertEqual(shown.label, "Completed")
    }

    func testAStreamThatNamesNoBundleEndsWithTheMissingBundleMessage() async throws {
        for lines in [
            [#"{"event":"nativeBundleImportStart","kind":"phylogenetic-tree","source":"/work/inputs/t.nwk"}"#],
            [#"{"event":"nativeBundleImportComplete","bundle":"  ","progress":1,"warningCount":0}"#],
            [#"{"event":"nativeBundleImportComplete","progress":1,"warningCount":0}"#],
        ] {
            let transcript = try ImportRunnerReplay.writeTranscript(lines, in: try makeTemporaryDirectory())
            let shown = try await ImportRunnerReplay.replay(
                transcript,
                title: "Tree Import",
                operationType: .multipleSequenceAlignmentImport,
                directory: try makeTemporaryDirectory()
            ) { cli, operationID in
                let result = try await CLINativeBundleImportRunner(cliURLOverride: cli)
                    .run(arguments: [], operationID: operationID)
                return (result.bundleURL.path, result.warningCount)
            }

            XCTAssertNil(shown.importedPath, "\(lines)")
            XCTAssertEqual(shown.failure, "lungfish-cli finished without reporting an imported bundle.", "\(lines)")
        }
    }

    func testAFailedEventWinsEvenWhenTheCLIExitsCleanly() async throws {
        let shown = try await replay("import-msa-failed", exitCode: 0)

        XCTAssertEqual(shown.failure, "Input file not found: /work/inputs/missing.aln")
        XCTAssertNil(shown.importedPath)
    }

    func testANonzeroExitWithNoFailedEventShowsTheExitStatusAndStandardError() async throws {
        let transcript = try ImportRunnerReplay.writeTranscript(
            [#"{"event":"nativeBundleImportStart","kind":"multiple-sequence-alignment","source":"/work/inputs/mhc.aln"}"#],
            in: try makeTemporaryDirectory()
        )
        let shown = try await ImportRunnerReplay.replay(
            transcript,
            title: "MSA Import",
            operationType: .multipleSequenceAlignmentImport,
            exitCode: 7,
            standardError: ["conda lock wait expired"],
            directory: try makeTemporaryDirectory()
        ) { cli, operationID in
            let result = try await CLINativeBundleImportRunner(cliURLOverride: cli)
                .run(arguments: [], operationID: operationID)
            return (result.bundleURL.path, result.warningCount)
        }

        XCTAssertEqual(shown.failure, "lungfish-cli exited with status 7: conda lock wait expired")
        XCTAssertNil(shown.importedPath)
    }

    func testALaunchThatFailsMarksTheRowFailedBeforeTheRunnerThrows() async throws {
        let missing = try makeTemporaryDirectory().appendingPathComponent("no-such-cli")
        let opID = await MainActor.run {
            OperationCenter.shared.begin(
                title: "MSA Import",
                detail: "Launching...",
                operationType: .multipleSequenceAlignmentImport,
                cliCommand: nil
            ).rowID
        }

        var thrown: Error?
        do {
            _ = try await CLINativeBundleImportRunner(cliURLOverride: missing).run(arguments: [], operationID: opID)
        } catch {
            thrown = error
        }
        let item = await MainActor.run { OperationCenter.shared.items.first { $0.id == opID } }

        XCTAssertTrue(
            (thrown as? CLINativeBundleImportRunner.RunError)?.localizedDescription.hasPrefix("Failed to launch lungfish-cli: ") == true,
            "\(String(describing: thrown))"
        )
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(item?.displayStateLabel, "Failed")
        await MainActor.run { OperationCenter.shared.clearItem(id: opID) }
    }

    // MARK: - A version 2 CLI

    /// Decision V13. A version 2 CLI and an older CLI give the same row, the same label and the same imported
    /// bundle. Each old transcript is written again as the version 2 lines of the same run, and both are
    /// played back through the same runner.
    func testAVersion2CLIGivesTheLogTheLabelAndTheBundleAnOlderCLIGave() async throws {
        let runs: [(name: String, title: String, exitCode: Int32)] = [
            ("import-msa", "MSA Import", 0),
            ("import-msa-with-warning", "MSA Import", 0),
            ("import-msa-failed", "MSA Import", 3),
            ("import-tree", "Tree Import", 0),
            ("import-tree-with-warning", "Tree Import", 0),
            ("import-tree-failed", "Tree Import", 3),
        ]
        for run in runs {
            let older = try await replay(run.name, title: run.title, exitCode: run.exitCode)
            let version2 = try ImportRunnerReplay.version2Transcript(ofLegacy: run.name, in: try makeTemporaryDirectory())
            let version2Lines = try String(contentsOf: version2, encoding: .utf8)
            XCTAssertTrue(version2Lines.contains("\"schemaVersion\":2"), "\(run.name) is written as version 2 lines")
            XCTAssertFalse(version2Lines.contains("nativeBundleImport"), "\(run.name) holds no private name")

            let current = try await replay(transcript: version2, title: run.title, exitCode: run.exitCode)

            XCTAssertEqual(current, older, run.name)
        }
    }

    /// The same check on the real thing. The transcripts of `import msa` and `import tree` that
    /// `CLIEventTranscriptCoverageTests` captures from the commands in process give the runner the
    /// same row, label and import as the checked-in streams that an older CLI printed for the same runs.
    func testTheCheckedInVersion2TranscriptsGiveWhatTheOlderStreamsGave() async throws {
        let runs: [(leaf: String, name: String, older: String, title: String, exitCode: Int32)] = [
            ("import-msa", "complete", "import-msa", "MSA Import", 0),
            ("import-msa", "complete-with-warning", "import-msa-with-warning", "MSA Import", 0),
            ("import-msa", "failed", "import-msa-failed", "MSA Import", 3),
            ("import-tree", "complete", "import-tree", "Tree Import", 0),
            ("import-tree", "complete-with-warning", "import-tree-with-warning", "Tree Import", 0),
            ("import-tree", "failed", "import-tree-failed", "Tree Import", 3),
        ]
        for run in runs {
            let older = try await replay(run.older, title: run.title, exitCode: run.exitCode)
            let version2 = try await replay(
                transcript: ImportRunnerReplay.commandTranscript(leaf: run.leaf, name: run.name),
                title: run.title,
                exitCode: run.exitCode
            )

            XCTAssertEqual(version2, older, "\(run.leaf) \(run.name)")
        }
    }

    /// Plain standard error stays in the operation log at info level, whatever it says, so a tool's
    /// warning text never makes an import read Completed with Warnings (decision S16).
    func testStandardErrorTextIsLoggedAtInfoAndNeverMakesTheRunCompletedWithWarnings() async throws {
        let version2 = try ImportRunnerReplay.version2Transcript(ofLegacy: "import-msa", in: try makeTemporaryDirectory())

        let shown = try await replay(
            transcript: version2,
            standardError: ["Imported /work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa", "warning: the alignment has gaps"]
        )

        XCTAssertTrue(shown.log.contains("info: Imported /work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa"), "\(shown.log)")
        XCTAssertTrue(shown.log.contains("info: warning: the alignment has gaps"), "\(shown.log)")
        XCTAssertEqual(shown.warningCount, 0)
        XCTAssertFalse(shown.hasWarnings)
        XCTAssertEqual(shown.label, "Completed")
    }

    /// `outputs` is the one list an import reads. The typed artifact describes an output and never
    /// stands in for it, so a completion that names a different artifact imports the output, and one
    /// that names no output imports nothing.
    func testATypedArtifactNeverStandsInForTheOutputs() async throws {
        let outputPath = "/work/Project.lungfish/Multiple Sequence Alignments/a.lungfishmsa"
        let artifactPath = "/work/Project.lungfish/Multiple Sequence Alignments/b.lungfishmsa"
        let start = #"{"event":"start","message":"Started multiple-sequence-alignment import via lungfish-cli","progress":0,"schemaVersion":2}"#

        let named = try ImportRunnerReplay.writeTranscript([
            start,
            #"{"artifacts":[{"kind":"multiple-sequence-alignment","path":"\#(artifactPath)","role":"bundle"}],"event":"complete","output":"\#(outputPath)","outputs":["\#(outputPath)"],"progress":1,"schemaVersion":2}"#,
        ], in: try makeTemporaryDirectory())
        let shownNamed = try await replay(transcript: named)
        XCTAssertEqual(shownNamed.importedPath, outputPath)

        let artifactsOnly = try ImportRunnerReplay.writeTranscript([
            start,
            #"{"artifacts":[{"kind":"multiple-sequence-alignment","path":"\#(artifactPath)","role":"bundle"}],"event":"complete","outputs":[],"progress":1,"schemaVersion":2}"#,
        ], in: try makeTemporaryDirectory())
        let shownArtifactsOnly = try await replay(transcript: artifactsOnly)
        XCTAssertNil(shownArtifactsOnly.importedPath)
        XCTAssertEqual(shownArtifactsOnly.failure, "lungfish-cli finished without reporting an imported bundle.")
    }

    /// A later version adds events, keys and kinds, and none of them stops an import (S15).
    func testALaterVersionWithNewEventsAndKeysStillImportsTheBundle() async throws {
        let outputPath = "/work/Project.lungfish/Phylogenetic Trees/t.lungfishtree"
        let transcript = try ImportRunnerReplay.writeTranscript([
            #"{"event":"start","message":"Started phylogenetic-tree import via lungfish-cli","progress":0,"schemaVersion":3,"eta":12}"#,
            #"{"event":"checkpoint","detail":{"step":1},"schemaVersion":3}"#,
            #"{"event":"progress","message":"Parsing t.nwk...","progress":0.35,"schemaVersion":3,"phase":"parse"}"#,
            #"{"artifacts":[{"kind":"phylogenetic-tree-v2","path":"\#(outputPath)","role":"bundle","size":{"bytes":4}}],"event":"complete","outputs":["\#(outputPath)"],"progress":1,"schemaVersion":3,"checksum":"abc"}"#,
        ], in: try makeTemporaryDirectory())

        let shown = try await replay(transcript: transcript, title: "Tree Import")

        XCTAssertEqual(shown.importedPath, outputPath)
        XCTAssertEqual(shown.log, ["info: Started phylogenetic-tree import via lungfish-cli", "info: Parsing t.nwk..."])
        XCTAssertEqual(shown.detail, "Parsing t.nwk...")
        XCTAssertEqual(shown.label, "Completed")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-native-bundle-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

// MARK: - Replaying a stream through an import runner

/// What the Operations Panel row shows, and what a runner hands the sidebar, after the runner read one
/// stream from a stand-in `lungfish-cli`.
struct ImportRunnerShown: Equatable {
    /// The bundle or collection the runner reports. Nil when the run threw.
    var importedPath: String?
    var warningCount: Int?
    /// The text of what the run threw.
    var failure: String?
    var progress: Double
    var detail: String
    /// Each log entry as `level: message`, in order.
    var log: [String]
    /// Whether the row holds warning evidence before the caller finishes it.
    var hasWarnings: Bool
    /// The row's label once the caller has finished it the way `AppDelegate+ImportCenter` does, which is
    /// Completed, Completed with Warnings when the runner counted a warning, or Failed.
    var label: String
}

/// Plays a transcript back through a stand-in `lungfish-cli` and reads what the runner left on its row.
/// `CLIApplicationExportImportRunnerTests` uses it too.
enum ImportRunnerReplay {
    static var legacyFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/cli-events/legacy", isDirectory: true)
    }

    /// A transcript of the private events an older CLI printed, by file name without the extension.
    static func legacyTranscript(_ name: String) -> URL {
        legacyFolder.appendingPathComponent("\(name).ndjson")
    }

    /// The run of an older CLI's transcript as a version 2 CLI prints it. The events that each old line
    /// decodes to through the legacy table are written again as version 2 lines, with the artifacts the
    /// line held, so the two streams are the same run in the two shapes.
    static func version2Transcript(ofLegacy name: String, in directory: URL) throws -> URL {
        let decoder = CLIEventLineDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try String(contentsOf: legacyTranscript(name), encoding: .utf8)
        let lines = try text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { text -> String? in
            guard let old = try decoder.decodeLine(String(text)), let event = old.event else { return nil }
            return String(data: try encoder.encode(CLIEventLine(event: event, artifacts: old.artifacts)), encoding: .utf8)
        }
        return try writeTranscript(lines, in: directory)
    }

    /// The version 2 transcript that `CLIEventTranscriptCoverageTests` keeps for one run of one leaf.
    /// `leaf` is the leaf's path with hyphens, such as `import-msa`, and `name` is `complete`,
    /// `complete-with-warning` or `failed`.
    static func commandTranscript(leaf: String, name: String) -> URL {
        legacyFolder
            .deletingLastPathComponent()
            .appendingPathComponent("commands/\(leaf)/\(name).ndjson")
    }

    /// A transcript made of `lines`, for a stream no real run produces.
    static func writeTranscript(_ lines: [String], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("stream.ndjson")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A `lungfish-cli` that prints the transcript on standard output, then the lines on standard
    /// error, and exits with `exitCode`.
    static func standIn(
        printing transcript: URL,
        standardError: [String],
        exitCode: Int32,
        in directory: URL
    ) throws -> URL {
        let executable = directory.appendingPathComponent("lungfish-cli")
        var script = "#!/bin/sh\n/bin/cat '\(transcript.path)'\n"
        for line in standardError {
            script += "printf '%s\\n' '\(line)' >&2\n"
        }
        script += "exit \(exitCode)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    /// Everything the main queue was asked to do before this call has run when it returns. The runners
    /// hand each event to the main queue, and the queue keeps the order.
    static func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Runs `run` against a stand-in CLI that plays `transcript`, and reads the row it fed.
    static func replay(
        _ transcript: URL,
        title: String,
        operationType: OperationType,
        exitCode: Int32 = 0,
        standardError: [String] = [],
        directory: URL,
        run: (_ cli: URL, _ operationID: UUID) async throws -> (path: String, warningCount: Int)
    ) async throws -> ImportRunnerShown {
        let cli = try standIn(printing: transcript, standardError: standardError, exitCode: exitCode, in: directory)
        let operationID = await MainActor.run {
            OperationCenter.shared.begin(
                title: title,
                detail: "Launching...",
                operationType: operationType,
                cliCommand: nil
            ).rowID
        }

        var imported: (path: String, warningCount: Int)?
        var failure: String?
        do {
            imported = try await run(cli, operationID)
        } catch {
            failure = error.localizedDescription
        }
        await drainMainQueue()

        let importedResult = imported
        let failureText = failure
        return await MainActor.run {
            let item = OperationCenter.shared.items.first { $0.id == operationID }
            let log = item?.logEntries.map { "\($0.level.rawValue): \($0.message)" } ?? []
            let progress = item?.progress ?? -1
            let detail = item?.detail ?? ""
            let hasWarnings = item?.hasWarnings ?? false
            // What the caller does in AppDelegate+ImportCenter once the runner returns or throws.
            if let importedResult {
                let name = URL(fileURLWithPath: importedResult.path).lastPathComponent
                if importedResult.warningCount == 0 {
                    _ = OperationCenter.shared.complete(id: operationID, detail: "Imported \(name)")
                } else {
                    _ = OperationCenter.shared.completeWithWarning(
                        id: operationID,
                        detail: "Imported \(name) with \(importedResult.warningCount) warnings"
                    )
                }
            } else {
                _ = OperationCenter.shared.fail(id: operationID, detail: failureText ?? "")
            }
            let label = OperationCenter.shared.items.first { $0.id == operationID }?.displayStateLabel ?? ""
            OperationCenter.shared.clearItem(id: operationID)
            return ImportRunnerShown(
                importedPath: importedResult?.path,
                warningCount: importedResult?.warningCount,
                failure: failureText,
                progress: progress,
                detail: detail,
                log: log,
                hasWarnings: hasWarnings,
                label: label
            )
        }
    }
}
