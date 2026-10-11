import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

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

    func testParseNativeBundleCompleteEvent() throws {
        let json = """
        {"event":"nativeBundleImportComplete","bundle":"/project/Project.lungfish/Phylogenetic Trees/tree.lungfishtree","warningCount":2}
        """

        let event = try XCTUnwrap(CLINativeBundleImportRunner.parseEvent(from: json))

        guard case let .complete(bundle, warningCount) = event else {
            return XCTFail("Expected complete event, got \(event)")
        }
        XCTAssertEqual(bundle, "/project/Project.lungfish/Phylogenetic Trees/tree.lungfishtree")
        XCTAssertEqual(warningCount, 2)
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
    private func replay(
        _ name: String,
        title: String = "MSA Import",
        exitCode: Int32 = 0,
        standardError: [String] = []
    ) async throws -> ImportRunnerShown {
        try await ImportRunnerReplay.replay(
            ImportRunnerReplay.legacyTranscript(name),
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
            log: ["info: Started multiple-sequence-alignment import via lungfish-cli"],
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
                "warning: Duplicate row names are present; stable row IDs preserve row order.",
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
            log: ["info: Started phylogenetic-tree import via lungfish-cli"],
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
                "warning: Tree contains one or more edges without branch lengths.",
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
