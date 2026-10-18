// ImportMSATreeE2ETests.swift - End-to-end CLI tests for native MSA/tree imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class ImportMSATreeE2ETests: XCTestCase {
    private let fileManager = FileManager.default
    private var cleanupURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in cleanupURLs {
            try? fileManager.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        try super.tearDownWithError()
    }

    func testImportMSAWritesNativeBundleProgressAndProvenance() throws {
        let workspace = try makeWorkspace()
        let projectURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = workspace.appendingPathComponent("mhc.aln")
        try """
        CLUSTAL W

        seq1 ACGT-A
        seq2 AC-TTA
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "import", "msa", sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let bundleURL = projectURL
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
            .appendingPathComponent("mhc.lungfishmsa", isDirectory: true)
        try ImportStreamCapture.assertVersion2Stream(
            result.stdout,
            importedPath: bundleURL.path,
            artifactKind: "multiple-sequence-alignment",
            artifactRole: "bundle"
        )
        XCTAssertTrue(
            result.stderr.contains("Imported \(bundleURL.path)"),
            "The summary is human text, so it goes to standard error while events are on: \(result.stderr)"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
        let provenance = try String(
            contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"),
            encoding: .utf8
        )
        let normalizedProvenance = provenance.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedProvenance.contains("lungfish import msa"))
        XCTAssertTrue(normalizedProvenance.contains(bundleURL.path))
        XCTAssertFalse(normalizedProvenance.contains("\"/tmp/"), "MSA provenance should point at final project paths, not /tmp")
        try Self.assertTheRecordNamesThePublishedBundle(bundleURL)
    }

    func testImportTreeWritesNativeBundleProgressAndProvenance() throws {
        let workspace = try makeWorkspace()
        let projectURL = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let sourceURL = workspace.appendingPathComponent("mhc.nwk")
        try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try runCLI([
            "import", "tree", sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        let bundleURL = projectURL
            .appendingPathComponent("Phylogenetic Trees", isDirectory: true)
            .appendingPathComponent("mhc.lungfishtree", isDirectory: true)
        try ImportStreamCapture.assertVersion2Stream(
            result.stdout,
            importedPath: bundleURL.path,
            artifactKind: "phylogenetic-tree",
            artifactRole: "bundle"
        )
        XCTAssertTrue(
            result.stderr.contains("Imported \(bundleURL.path)"),
            "The summary is human text, so it goes to standard error while events are on: \(result.stderr)"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: bundleURL.appendingPathComponent(".lungfish-provenance.json").path))
        let provenance = try String(
            contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"),
            encoding: .utf8
        )
        let normalizedProvenance = provenance.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(normalizedProvenance.contains("lungfish import tree"))
        XCTAssertTrue(normalizedProvenance.contains(bundleURL.path))
        XCTAssertFalse(normalizedProvenance.contains("\"/tmp/"), "Tree provenance should point at final project paths, not /tmp")
        try Self.assertTheRecordNamesThePublishedBundle(bundleURL)
    }

    /// The record of a published bundle names the bundle as its output and each file under it, never the stage in
    /// the project's temporary folder that the importer wrote to (Phase 2.12 lane 12.06, SWIFT 4). The files it lists
    /// exist at the published paths with the digests it records, which shows through the real command that the
    /// checksums read the stage and still hold for the published bundle (review of M2, fix 4).
    private static func assertTheRecordNamesThePublishedBundle(
        _ bundleURL: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        XCTAssertEqual((record["output"] as? [String: Any])?["path"] as? String, bundleURL.path, file: file, line: line)
        for (relativePath, entry) in (record["files"] as? [String: [String: Any]]) ?? [:] {
            XCTAssertEqual(entry["path"] as? String, bundleURL.appendingPathComponent(relativePath).path, file: file, line: line)
        }
        let output = try XCTUnwrap((record["output"] as? [String: Any])?["path"] as? String, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output), "the output the record names exists", file: file, line: line)
        let files = (record["files"] as? [String: [String: Any]]) ?? [:]
        let checksums = (record["checksums"] as? [String: String]) ?? [:]
        XCTAssertFalse(files.isEmpty && checksums.isEmpty, "the record lists files with digests", file: file, line: line)
        for (relativePath, entry) in files {
            let path = try XCTUnwrap(entry["path"] as? String, file: file, line: line)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            XCTAssertTrue(exists, "the file the record lists exists: \(relativePath)", file: file, line: line)
            guard exists, !isDirectory.boolValue else { continue }
            let digest = MultipleSequenceAlignmentBundle.sha256Hex(for: try Data(contentsOf: URL(fileURLWithPath: path)))
            XCTAssertEqual(entry["checksumSHA256"] as? String, digest, relativePath, file: file, line: line)
        }
        for (relativePath, recorded) in checksums {
            let digest = MultipleSequenceAlignmentBundle.sha256Hex(for: try Data(contentsOf: bundleURL.appendingPathComponent(relativePath)))
            XCTAssertEqual(recorded, digest, relativePath, file: file, line: line)
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(text.contains("/.tmp/"), "the record names no stage", file: file, line: line)
    }

    /// Phase 2.6 lane C5. `import msa` and `import tree` print version 2 events, and each run reads like
    /// the old stream that the same run printed before, which is checked in under
    /// `Tests/Fixtures/cli-events/legacy`. The old stream is read through the legacy name table.
    func testTheMSAAndTreeImportsPrintVersion2EventsThatReadLikeTheOldStreams() async throws {
        try await ImportStreamCapture.assertVersion2Streams(ofLeaves: ["import msa", "import tree"])
    }

    /// The summary of an import is human text. While `--format json` is on it goes to standard error,
    /// where a reader that looks for events never meets it, and `--quiet` silences it. With events
    /// off the same text stays on standard output and no event line is printed.
    func testTheSummaryOfAnImportGoesToStandardErrorWhileEventsAreOn() async throws {
        let summary = [
            "Imported /work/Project.lungfish/Multiple Sequence Alignments/mhc.lungfishmsa",
            "Rows: 2",
            "Columns: 6",
        ]

        func run(_ arguments: [String]) async throws -> ImportStreamCapture.Output {
            let scratch = try ImportStreamCapture.Scratch()
            defer { scratch.remove() }
            let source = try scratch.write("inputs/mhc.aln", ImportStreamCapture.clustal)
            let command = try ImportCommand.MSASubcommand.parse(
                [source.path, "--project", scratch.project.path] + arguments
            )
            let output = try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
            XCTAssertNil(output.thrown)
            return output
        }

        let events = try await run(["--format", "json"])
        XCTAssertEqual(events.standardError, summary)
        XCTAssertTrue(events.standardOutput.allSatisfy { $0.hasPrefix("{") }, "\(events.standardOutput)")
        XCTAssertEqual(events.standardOutput.count, 5, "start, three progress lines and complete")

        let quiet = try await run(["--format", "json", "--quiet"])
        XCTAssertEqual(quiet.standardError, [])
        XCTAssertEqual(quiet.standardOutput, events.standardOutput)

        let text = try await run([])
        XCTAssertEqual(text.standardOutput, summary)
        XCTAssertEqual(text.standardError, [])
    }

    /// Review of lane C5, fix 4. With `--format json` off no event is written, so a warning and a failure
    /// reach a person as one line of text each on standard error, `Warning: <message>` and
    /// `Error: <message>`. The summary stays on standard output. `--quiet` drops the warning and keeps
    /// the failure. With events on the events carry both, and no text is written for them.
    func testWithoutEventsAWarningAndAFailureAreWrittenAsTextOnStandardError() async throws {
        let warning = "Warning: Duplicate row names are present; stable row IDs preserve row order."
        let failure = "Error: Input file not found: /work/inputs/missing.aln"

        func run(_ arguments: [String], duplicateRows: Bool) async throws -> ImportStreamCapture.Output {
            let scratch = try ImportStreamCapture.Scratch()
            defer { scratch.remove() }
            let source = duplicateRows
                ? try scratch.write("inputs/duplicates.fasta", ImportStreamCapture.duplicateRows)
                : scratch.root.appendingPathComponent("inputs/missing.aln")
            let command = try ImportCommand.MSASubcommand.parse(
                [source.path, "--project", scratch.project.path] + arguments
            )
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        }

        let warned = try await run([], duplicateRows: true)
        XCTAssertNil(warned.thrown)
        XCTAssertEqual(warned.standardError, [warning])
        XCTAssertEqual(warned.standardOutput, [
            "Imported /work/Project.lungfish/Multiple Sequence Alignments/duplicates.lungfishmsa",
            "Rows: 2",
            "Columns: 6",
        ])

        let refused = try await run([], duplicateRows: false)
        XCTAssertTrue(refused.thrown is ExitCode)
        XCTAssertEqual(refused.standardError, [failure])
        XCTAssertEqual(refused.standardOutput, [])

        let quietWarned = try await run(["--quiet"], duplicateRows: true)
        XCTAssertEqual(quietWarned.standardError, [])
        let quietRefused = try await run(["--quiet"], duplicateRows: false)
        XCTAssertTrue(quietRefused.thrown is ExitCode)
        XCTAssertEqual(quietRefused.standardError, [failure])

        let eventsWarned = try await run(["--format", "json"], duplicateRows: true)
        XCTAssertFalse(eventsWarned.standardError.contains { $0.hasPrefix("Warning: ") }, "\(eventsWarned.standardError)")
        XCTAssertTrue(eventsWarned.standardOutput.contains { $0.contains("\"level\":\"warning\"") }, "The warning is an event")
        let eventsRefused = try await run(["--format", "json"], duplicateRows: false)
        XCTAssertEqual(eventsRefused.standardError, [])
        XCTAssertTrue(eventsRefused.standardOutput.last?.contains("\"event\":\"failed\"") == true, "The failure is an event")
    }

    /// `printHumanLine` is the helper of C-L1 that these commands are the first to call.
    func testPrintHumanLineWritesToStandardErrorOnlyWhileEventsAreOn() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }

        let output = try await ImportStreamCapture.capture(in: scratch) {
            printHumanLine("while events are on", eventsOn: true)
            printHumanLine("with events off", eventsOn: false)
        }

        XCTAssertEqual(output.standardError, ["while events are on"])
        XCTAssertEqual(output.standardOutput, ["with events off"])
    }

    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let binary = cliBinaryPath else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private var cliBinaryPath: URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        )
    }

    private func makeWorkspace() throws -> URL {
        let root = repoRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cli-msa-tree-e2e-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        cleanupURLs.append(root)
        return root
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

// MARK: - In-process captures of the import event streams

/// Runs the four import commands in process on small fixtures and keeps what they print, so a test can
/// compare a stream with a checked-in transcript without the built `lungfish-cli`.
///
/// `ApplicationExportImportE2ETests` and `CLIEventTranscriptCoverageTests` use it too. Each run has its
/// own scratch folder, which becomes `/work` in every line the run printed. The fixtures need no external
/// tool, and the two commands that can import references run with `--no-import-references`.
enum ImportStreamCapture {
    /// What one run printed, with the scratch folder rewritten to `/work`.
    struct Output {
        let standardOutput: [String]
        let standardError: [String]
        /// What the command threw, such as the exit code of an import that was refused.
        let thrown: Error?
    }

    /// One run of one leaf that ends one way. `name` is `complete`, `complete-with-warning` or `failed`.
    struct Case {
        let leaf: String
        let name: String
        let run: (Scratch) async throws -> Output
    }

    final class Scratch {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/test-artifacts/ImportStreams-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// The project folder every import writes into.
        var project: URL {
            let url = root.appendingPathComponent("Project.lungfish", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// A file under the scratch folder, with the folders above it made.
        @discardableResult
        func write(_ relativePath: String, _ text: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        /// The scratch folder becomes `/work`, in the plain and the slash-escaped spelling a line can hold.
        func normalized(_ line: String) -> String {
            let escaped = root.path.replacingOccurrences(of: "/", with: "\\/")
            return line
                .replacingOccurrences(of: escaped, with: "\\/work")
                .replacingOccurrences(of: root.path, with: "/work")
        }

        /// The file that a normalized `/work` path names, for a check that it exists.
        func resolved(_ normalizedPath: String) -> URL {
            URL(fileURLWithPath: root.path + normalizedPath.dropFirst("/work".count))
        }
    }

    // MARK: Checked-in transcripts

    static var legacyFolder: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/cli-events/legacy", isDirectory: true)
    }

    /// `import-msa.ndjson` for a clean run, with `-with-warning` or `-failed` after the stem for the others.
    static func legacyTranscriptURL(leaf: String, name: String) -> URL {
        let stem = leaf.split(separator: " ").joined(separator: "-")
        let suffix: String
        switch name {
        case "complete": suffix = ""
        case "failed": suffix = "-failed"
        default: suffix = "-with-warning"
        }
        return legacyFolder.appendingPathComponent("\(stem)\(suffix).ndjson")
    }

    /// What each leaf describes its output with, as the kind and the role of its one artifact.
    private static let artifactShapes: [String: (kind: String, role: String)] = [
        "import msa": ("multiple-sequence-alignment", "bundle"),
        "import tree": ("phylogenetic-tree", "bundle"),
        "import geneious": ("import-collection", "collection"),
        "import application-export": ("import-collection", "collection"),
    ]

    /// Runs every case of `leaves` and checks the stream it prints. Standard output holds nothing but
    /// version 2 event lines. The run reads like the old stream that the same run printed before version 2,
    /// as the legacy name table maps it, so the progress, the warnings, the failure text and the outputs
    /// are the ones an older CLI gave. A completion holds one artifact for its output, with the record
    /// that the import wrote beside it.
    static func assertVersion2Streams(
        ofLeaves leaves: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let selected = cases().filter { leaves.contains($0.leaf) }
        XCTAssertEqual(Set(selected.map(\.leaf)), leaves, "Each leaf has cases", file: file, line: line)
        let decoder = CLIEventLineDecoder()
        for testCase in selected {
            let scratch = try Scratch()
            defer { scratch.remove() }
            let output = try await testCase.run(scratch)
            let label = "\(testCase.leaf) (\(testCase.name))"
            if testCase.name == "failed" {
                XCTAssertTrue(output.thrown is ExitCode, "\(label) ends with an exit code", file: file, line: line)
            } else {
                XCTAssertNil(output.thrown, "\(label) threw \(String(describing: output.thrown))", file: file, line: line)
            }

            let current = try output.standardOutput.map { text -> CLIEventLine in
                XCTAssertTrue(text.hasPrefix("{"), "\(label) prints text that a reader skips: \(text)", file: file, line: line)
                let envelope = try XCTUnwrap(try decoder.decodeLine(text), "\(label): \(text)", file: file, line: line)
                XCTAssertNotNil(envelope.event, "\(label) prints an event that a reader ignores: \(text)", file: file, line: line)
                XCTAssertEqual(envelope.schemaVersion, CLIEventLine.currentSchemaVersion, "\(label): \(text)", file: file, line: line)
                return envelope
            }

            let legacyURL = legacyTranscriptURL(leaf: testCase.leaf, name: testCase.name)
            let old = try String(contentsOf: legacyURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { text in
                    try XCTUnwrap(try decoder.decodeLine(String(text)), "\(legacyURL.lastPathComponent): \(text)", file: file, line: line)
                }
            XCTAssertEqual(
                current.compactMap(\.event),
                old.compactMap(\.event),
                "\(label) no longer reads like \(legacyURL.lastPathComponent)",
                file: file,
                line: line
            )

            guard let last = current.last, case let .complete(outputs, _)? = last.event else { continue }
            let shape = try XCTUnwrap(artifactShapes[testCase.leaf], file: file, line: line)
            XCTAssertEqual(outputs.count, 1, "\(label) names \(outputs)", file: file, line: line)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: scratch.resolved(outputs[0]).path),
                "\(label) names an output that does not exist: \(outputs[0])",
                file: file,
                line: line
            )
            XCTAssertEqual(last.artifacts.count, 1, "\(label) describes its output once", file: file, line: line)
            let artifact = try XCTUnwrap(last.artifacts.first, file: file, line: line)
            XCTAssertEqual(artifact.path, outputs[0], "The artifact describes the output, which stays the import's input", file: file, line: line)
            XCTAssertEqual(artifact.kind, shape.kind, label, file: file, line: line)
            XCTAssertEqual(artifact.role, shape.role, label, file: file, line: line)
            XCTAssertEqual(
                old.last?.artifacts.map { [$0.kind, $0.path, $0.role ?? ""] },
                last.artifacts.map { [$0.kind, $0.path, $0.role ?? ""] },
                "An older CLI's completion reads to the same artifact apart from the record: \(label)",
                file: file,
                line: line
            )
            let record = try XCTUnwrap(artifact.provenancePath, "\(label) names no provenance record", file: file, line: line)
            XCTAssertTrue(record.hasSuffix("/.lungfish-provenance.json"), record, file: file, line: line)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: scratch.resolved(record).path),
                "\(label) names a record that does not exist: \(record)",
                file: file,
                line: line
            )
        }
    }

    private struct NoCompletion: Error {}

    /// What a real run of the built `lungfish-cli` printed on standard output with `--format json`.
    /// Returns the completion line after checking that the stream holds nothing but version 2 event
    /// lines, that it starts, that it ends with the completion and that the completion names
    /// `importedPath`, when given, in `outputs` and in its one typed artifact.
    @discardableResult
    static func assertVersion2Stream(
        _ standardOutput: String,
        importedPath: String?,
        artifactKind: String,
        artifactRole: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CLIEventLine {
        let decoder = CLIEventLineDecoder()
        let envelopes = try standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { text -> CLIEventLine in
                XCTAssertTrue(text.hasPrefix("{"), "Standard output holds text that a reader skips: \(text)", file: file, line: line)
                return try XCTUnwrap(try decoder.decodeLine(String(text)), String(text), file: file, line: line)
            }
        XCTAssertFalse(standardOutput.contains("nativeBundleImport"), "No private event name is left", file: file, line: line)
        XCTAssertFalse(standardOutput.contains("applicationExport"), "No private event name is left", file: file, line: line)
        XCTAssertTrue(envelopes.allSatisfy { $0.event != nil }, "A line is an event this reader ignores", file: file, line: line)
        XCTAssertTrue(
            envelopes.allSatisfy { $0.schemaVersion == CLIEventLine.currentSchemaVersion },
            "A line carries no schemaVersion",
            file: file,
            line: line
        )
        guard case .start? = envelopes.first?.event else {
            XCTFail("The stream does not start with a start event", file: file, line: line)
            throw NoCompletion()
        }
        let last = try XCTUnwrap(envelopes.last, file: file, line: line)
        guard case let .complete(outputs, _)? = last.event else {
            XCTFail("The stream does not end with a complete event", file: file, line: line)
            throw NoCompletion()
        }
        XCTAssertEqual(outputs.count, 1, "\(outputs)", file: file, line: line)
        if let importedPath {
            XCTAssertEqual(outputs, [importedPath], file: file, line: line)
        }
        let artifact = try XCTUnwrap(last.artifacts.first, "The completion describes its output", file: file, line: line)
        XCTAssertEqual(last.artifacts.count, 1, file: file, line: line)
        XCTAssertEqual(artifact.path, outputs.first, file: file, line: line)
        XCTAssertEqual(artifact.kind, artifactKind, file: file, line: line)
        XCTAssertEqual(artifact.role, artifactRole, file: file, line: line)
        let record = try XCTUnwrap(artifact.provenancePath, "The artifact names its record", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record), "The record does not exist: \(record)", file: file, line: line)
        return last
    }

    // MARK: Running a command

    /// The standard output and standard error of a run, each redirected to a file for its length.
    static func capture(in scratch: Scratch, _ run: () async throws -> Void) async throws -> Output {
        let outputFile = scratch.root.appendingPathComponent("standard-output.capture")
        let errorFile = scratch.root.appendingPathComponent("standard-error.capture")
        fflush(stdout)
        fflush(stderr)
        let savedOutput = dup(STDOUT_FILENO)
        let savedError = dup(STDERR_FILENO)
        let outputDescriptor = open(outputFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let errorDescriptor = open(errorFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard savedOutput >= 0, savedError >= 0, outputDescriptor >= 0, errorDescriptor >= 0 else {
            for descriptor in [savedOutput, savedError, outputDescriptor, errorDescriptor] where descriptor >= 0 {
                close(descriptor)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        dup2(outputDescriptor, STDOUT_FILENO)
        dup2(errorDescriptor, STDERR_FILENO)
        close(outputDescriptor)
        close(errorDescriptor)
        var thrown: Error?
        do {
            try await run()
        } catch {
            thrown = error
        }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOutput, STDOUT_FILENO)
        dup2(savedError, STDERR_FILENO)
        close(savedOutput)
        close(savedError)

        func lines(of file: URL) throws -> [String] {
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { scratch.normalized(String($0)) }
        }
        return Output(standardOutput: try lines(of: outputFile), standardError: try lines(of: errorFile), thrown: thrown)
    }

    // MARK: The cases

    /// Every run of every leaf, in the order of the contract table.
    static func cases() -> [Case] {
        msaCases() + treeCases() + geneiousCases() + applicationExportCases()
    }

    static let clustal = """
    CLUSTAL W

    seq1 ACGT-A
    seq2 AC-TTA
    """

    /// Two rows that share a name, which the importer warns about.
    static let duplicateRows = ">seq1\nACGT-A\n>seq1\nAC-TTA\n"

    private static func msaCases() -> [Case] {
        func run(_ scratch: Scratch, source: URL) async throws -> Output {
            let command = try ImportCommand.MSASubcommand.parse([
                source.path, "--project", scratch.project.path, "--format", "json",
            ])
            return try await capture(in: scratch) { try await command.run() }
        }
        return [
            Case(leaf: "import msa", name: "complete") { scratch in
                try await run(scratch, source: try scratch.write("inputs/mhc.aln", clustal))
            },
            Case(leaf: "import msa", name: "complete-with-warning") { scratch in
                try await run(scratch, source: try scratch.write("inputs/duplicates.fasta", duplicateRows))
            },
            Case(leaf: "import msa", name: "failed") { scratch in
                try await run(scratch, source: scratch.root.appendingPathComponent("inputs/missing.aln"))
            },
        ]
    }

    private static func treeCases() -> [Case] {
        func run(_ scratch: Scratch, source: URL) async throws -> Output {
            let command = try ImportCommand.TreeSubcommand.parse([
                source.path, "--project", scratch.project.path, "--format", "json",
            ])
            return try await capture(in: scratch) { try await command.run() }
        }
        return [
            Case(leaf: "import tree", name: "complete") { scratch in
                try await run(scratch, source: try scratch.write("inputs/mhc.nwk", "((A:0.1,B:0.2)90:0.3,C:0.4);\n"))
            },
            Case(leaf: "import tree", name: "complete-with-warning") { scratch in
                try await run(scratch, source: try scratch.write("inputs/bare.nwk", "(A,B,C);\n"))
            },
            Case(leaf: "import tree", name: "failed") { scratch in
                try await run(scratch, source: scratch.root.appendingPathComponent("inputs/missing.nwk"))
            },
        ]
    }

    /// A folder that scans as a Geneious export, with a reference, a report and the document XML.
    static func geneiousSource(_ scratch: Scratch) throws -> URL {
        try scratch.write("inputs/Representative/refs/reference.fa", ">chr1\nACGTACGTACGTACGT\n")
        try scratch.write("inputs/Representative/reports/summary.tsv", "sample\tmetric\nA\t1\n")
        try scratch.write("inputs/Representative/document.geneious", """
        <geneious version="2024.0" minimumVersion="2023.0">
          <geneiousDocument class="urn:com.biomatters.geneious.publicapi.documents.sequence.NucleotideSequenceDocument"/>
          <hiddenField name="cache_name">Representative</hiddenField>
        </geneious>
        """)
        try scratch.write("inputs/Representative/fileData.1", "binary\n")
        return scratch.root.appendingPathComponent("inputs/Representative", isDirectory: true)
    }

    private static func geneiousCases() -> [Case] {
        func run(_ scratch: Scratch, source: URL, arguments: [String] = []) async throws -> Output {
            let command = try ImportCommand.GeneiousSubcommand.parse(
                [source.path, "--project", scratch.project.path, "--no-import-references", "--format", "json"] + arguments
            )
            return try await capture(in: scratch) { try await command.run() }
        }
        return [
            Case(leaf: "import geneious", name: "complete") { scratch in
                try await run(scratch, source: try geneiousSource(scratch))
            },
            // Preserving the unsupported items is what makes the collection service warn about each.
            Case(leaf: "import geneious", name: "complete-with-warning") { scratch in
                try await run(scratch, source: try geneiousSource(scratch), arguments: ["--preserve-unsupported"])
            },
            Case(leaf: "import geneious", name: "failed") { scratch in
                try await run(scratch, source: scratch.root.appendingPathComponent("inputs/missing.geneious"))
            },
        ]
    }

    /// A folder of one alignment and one tree, which the `alignment-tree` card imports as native bundles.
    static func nativeBundlesSource(_ scratch: Scratch, extraFiles: Bool) throws -> URL {
        try scratch.write("inputs/Alignment Tree Export/alignments/example.aln", clustal)
        try scratch.write("inputs/Alignment Tree Export/trees/example.nwk", "((A:0.1,B:0.2)Clade:0.3,C:0.4);\n")
        if extraFiles {
            try scratch.write("inputs/Alignment Tree Export/reports/summary.tsv", "sample\tmetric\nA\t1\n")
        }
        return scratch.root.appendingPathComponent("inputs/Alignment Tree Export", isDirectory: true)
    }

    private static func applicationExportCases() -> [Case] {
        func run(_ scratch: Scratch, kind: String, source: URL) async throws -> Output {
            let command = try ImportCommand.ApplicationExportSubcommand.parse(
                [kind, source.path, "--project", scratch.project.path, "--no-import-references", "--format", "json"]
            )
            return try await capture(in: scratch) { try await command.run() }
        }
        return [
            Case(leaf: "import application-export", name: "complete") { scratch in
                try await run(scratch, kind: "alignment-tree", source: try nativeBundlesSource(scratch, extraFiles: false))
            },
            Case(leaf: "import application-export", name: "complete-with-warning") { scratch in
                try await run(scratch, kind: "alignment-tree", source: try nativeBundlesSource(scratch, extraFiles: true))
            },
            Case(leaf: "import application-export", name: "failed") { scratch in
                try await run(scratch, kind: "alignment-tree", source: scratch.root.appendingPathComponent("inputs/missing"))
            },
        ]
    }
}
