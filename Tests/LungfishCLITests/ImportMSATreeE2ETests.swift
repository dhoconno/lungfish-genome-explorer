// ImportMSATreeE2ETests.swift - End-to-end CLI tests for native MSA/tree imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishTestSupport
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
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportStart\""))
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportComplete\""))

        let bundleURL = projectURL
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
            .appendingPathComponent("mhc.lungfishmsa", isDirectory: true)
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
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportStart\""))
        XCTAssertTrue(result.stdout.contains("\"nativeBundleImportComplete\""))

        let bundleURL = projectURL
            .appendingPathComponent("Phylogenetic Trees", isDirectory: true)
            .appendingPathComponent("mhc.lungfishtree", isDirectory: true)
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
    }

    /// Phase 2.6 lane C5, step 1. The stream of `import msa` and `import tree` as `lungfish-cli` printed
    /// it before version 2 events, captured in process on small fixtures and checked in under
    /// `Tests/Fixtures/cli-events/legacy`. Step 3 of the lane moves both commands to version 2 events
    /// and turns this check into the same one on the new transcripts. The old files stay, because
    /// the legacy name table reads them.
    func testTheMSAAndTreeImportStreamsArePinnedInTheirOldShape() async throws {
        try await ImportStreamCapture.assertOldShape(ofLeaves: ["import msa", "import tree"])
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

    /// Runs every case of `leaves` and expects the stream each prints today to be the checked-in
    /// old-shape transcript. Set `LUNGFISH_RECAPTURE_CLI_EVENTS=1` to write the files instead.
    static func assertOldShape(
        ofLeaves leaves: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let recapture = ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1"
        let selected = cases().filter { leaves.contains($0.leaf) }
        XCTAssertEqual(Set(selected.map(\.leaf)), leaves, "Each leaf has cases", file: file, line: line)
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
            XCTAssertTrue(output.standardError.isEmpty, "\(label) wrote to standard error: \(output.standardError)", file: file, line: line)

            let url = legacyTranscriptURL(leaf: testCase.leaf, name: testCase.name)
            if recapture {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (output.standardOutput.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            guard let checkedIn = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("No transcript for \(label). Run with LUNGFISH_RECAPTURE_CLI_EVENTS=1 and review the new file", file: file, line: line)
                continue
            }
            XCTAssertEqual(
                output.standardOutput,
                checkedIn.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
                "\(label) no longer prints the stream pinned in \(url.lastPathComponent)",
                file: file,
                line: line
            )
        }
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

    private static let clustal = """
    CLUSTAL W

    seq1 ACGT-A
    seq2 AC-TTA
    """

    /// Two rows that share a name, which the importer warns about.
    private static let duplicateRows = ">seq1\nACGT-A\n>seq1\nAC-TTA\n"

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
    private static func geneiousSource(_ scratch: Scratch) throws -> URL {
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
    private static func nativeBundlesSource(_ scratch: Scratch, extraFiles: Bool) throws -> URL {
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
