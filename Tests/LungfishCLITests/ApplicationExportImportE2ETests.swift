import ArgumentParser
import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest
import LungfishCore
@testable import LungfishCLI

final class ApplicationExportImportE2ETests: XCTestCase {
    // `ImportStreamCapture`, the in-process capture of the import streams, is declared in
    // `ImportMSATreeE2ETests.swift`.
    private let fileManager = FileManager.default
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? fileManager.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    /// Phase 2.6 lane C5. `import geneious` and `import application-export` print version 2 events, and
    /// each run reads like the old stream that the same run printed before, which is checked in under
    /// `Tests/Fixtures/cli-events/legacy`. The old stream is read through the legacy name table.
    func testTheGeneiousAndApplicationExportImportsPrintVersion2EventsThatReadLikeTheOldStreams() async throws {
        try await ImportStreamCapture.assertVersion2Streams(ofLeaves: ["import geneious", "import application-export"])
    }

    /// Review of lane C5, fix 4. The other two import commands share the emitter of `import msa`, so with
    /// `--format json` off they write each warning and failure as one line of text on standard error too,
    /// `Warning: <message>` and `Error: <message>`. `--quiet` drops the warnings and keeps the failures.
    func testWithoutEventsTheGeneiousAndApplicationExportImportsWriteWarningsAndFailuresAsText() async throws {
        /// `Warning: <message>` for each warning that an older CLI logged on the warning run of `leaf`.
        func expectedWarnings(leaf: String) throws -> [String] {
            let decoder = CLIEventLineDecoder()
            let url = ImportStreamCapture.legacyTranscriptURL(leaf: leaf, name: "complete-with-warning")
            return try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { try decoder.decode(line: String($0)) }
                .compactMap { event -> String? in
                    if case let .log(.warning, message) = event { return "Warning: \(message)" }
                    return nil
                }
        }

        func geneious(_ arguments: [String], missingSource: Bool = false) async throws -> ImportStreamCapture.Output {
            let scratch = try ImportStreamCapture.Scratch()
            defer { scratch.remove() }
            let source = missingSource
                ? scratch.root.appendingPathComponent("inputs/missing.geneious")
                : try ImportStreamCapture.geneiousSource(scratch)
            let command = try ImportCommand.GeneiousSubcommand.parse(
                [source.path, "--project", scratch.project.path, "--no-import-references", "--preserve-unsupported"] + arguments
            )
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        }

        func applicationExport(_ arguments: [String], missingSource: Bool = false) async throws -> ImportStreamCapture.Output {
            let scratch = try ImportStreamCapture.Scratch()
            defer { scratch.remove() }
            let source = missingSource
                ? scratch.root.appendingPathComponent("inputs/missing")
                : try ImportStreamCapture.nativeBundlesSource(scratch, extraFiles: true)
            let command = try ImportCommand.ApplicationExportSubcommand.parse(
                ["alignment-tree", source.path, "--project", scratch.project.path, "--no-import-references"] + arguments
            )
            return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
        }

        let geneiousWarned = try await geneious([])
        XCTAssertNil(geneiousWarned.thrown)
        XCTAssertEqual(geneiousWarned.standardError, try expectedWarnings(leaf: "import geneious"))
        XCTAssertEqual(geneiousWarned.standardError.count, 5)
        XCTAssertEqual(
            geneiousWarned.standardOutput,
            ["Imported /work/Project.lungfish/Geneious Imports/Representative Geneious Import"]
        )
        let geneiousQuiet = try await geneious(["--quiet"])
        XCTAssertEqual(geneiousQuiet.standardError, [])
        let geneiousRefused = try await geneious([], missingSource: true)
        XCTAssertTrue(geneiousRefused.thrown is ExitCode)
        XCTAssertEqual(geneiousRefused.standardError, ["Error: Input file not found: /work/inputs/missing.geneious"])
        let geneiousQuietRefused = try await geneious(["--quiet"], missingSource: true)
        XCTAssertEqual(geneiousQuietRefused.standardError, ["Error: Input file not found: /work/inputs/missing.geneious"])

        let exportWarned = try await applicationExport([])
        XCTAssertNil(exportWarned.thrown)
        XCTAssertEqual(exportWarned.standardError, try expectedWarnings(leaf: "import application-export"))
        XCTAssertEqual(exportWarned.standardError.count, 1)
        let exportQuiet = try await applicationExport(["--quiet"])
        XCTAssertEqual(exportQuiet.standardError, [])
        let exportRefused = try await applicationExport([], missingSource: true)
        XCTAssertTrue(exportRefused.thrown is ExitCode)
        XCTAssertEqual(exportRefused.standardError, ["Error: Input file not found: /work/inputs/missing"])
        let exportQuietRefused = try await applicationExport(["--quiet"], missingSource: true)
        XCTAssertEqual(exportQuietRefused.standardError, ["Error: Input file not found: /work/inputs/missing"])

        // With events on the events carry the warnings and the failure, and no text is written for them.
        let eventsGeneious = try await geneious(["--format", "json"])
        XCTAssertFalse(eventsGeneious.standardError.contains { $0.hasPrefix("Warning: ") }, "\(eventsGeneious.standardError)")
        let eventsRefused = try await applicationExport(["--format", "json"], missingSource: true)
        XCTAssertEqual(eventsRefused.standardError, [])
    }

    func testGeneiousImportRunsThroughCLIWithRepresentativeArchive() throws {
        let root = try makeTempDirectory()
        let projectURL = try makeProject(in: root)
        let sourceURL = try makeGeneiousArchive(in: root)

        let result = try runCLI([
            "import", "geneious", sourceURL.path,
            "--project", projectURL.path,
            "--format", "json",
        ])

        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let collectionURL = try assertCLIImportOutput(
            result.stdout,
            expectedCollectionName: "Representative Geneious Import",
            expectsBinaryArtifacts: false
        )
        try assertReferenceBundleProvenance(
            in: collectionURL,
            containsDurableSourcePaths: durablePathSpellings(for: sourceURL),
            temporaryPathMarker: "/Project.lungfish/.tmp/geneious-import-"
        )
    }

    func testApplicationExportCardsRunThroughCLIWithRepresentativeDatasets() throws {
        let fixtures: [RepresentativeApplicationExportFixture] = [
            .init(kindArgument: "clc-workbench", sourceName: "CLC Workbench Export", nativeRelativePath: "native/project.clc", archiveExtension: "zip"),
            .init(kindArgument: "dnastar-lasergene", sourceName: "Lasergene Export", nativeRelativePath: "native/project.pro", archiveExtension: nil),
            .init(kindArgument: "benchling-bulk", sourceName: "Benchling Bulk Export", nativeRelativePath: "benchling_export.json", archiveExtension: "zip"),
            .init(kindArgument: "sequence-design-library", sourceName: "Sequence Library Export", nativeRelativePath: "designs/library.dna", archiveExtension: nil),
            .init(
                kindArgument: "alignment-tree",
                sourceName: "Alignment Tree Export",
                nativeRelativePath: "alignments/example.aln",
                archiveExtension: nil,
                expectedBundleExtensions: ["lungfishmsa"],
                expectsBinaryArtifacts: false
            ),
            .init(kindArgument: "sequencing-platform-run-folder", sourceName: "Sequencing Run Export", nativeRelativePath: "RunInfo.xml", archiveExtension: nil),
            .init(
                kindArgument: "phylogenetics-result-set",
                sourceName: "Phylogenetics Export",
                nativeRelativePath: "usher/tree.nwk",
                archiveExtension: "zip",
                expectedBundleExtensions: ["lungfishtree"],
                expectsBinaryArtifacts: false
            ),
            .init(kindArgument: "qiime2-archive", sourceName: "QIIME2 Export", nativeRelativePath: "metadata.yaml", archiveExtension: "qza"),
            .init(kindArgument: "igv-session-track-set", sourceName: "IGV Session Export", nativeRelativePath: "session.xml", archiveExtension: nil),
        ]

        for fixture in fixtures {
            let root = try makeTempDirectory()
            let projectURL = try makeProject(in: root)
            let sourceURL = try makeApplicationExportFixture(fixture, in: root)

            let result = try runCLI([
                "import", "application-export", fixture.kindArgument, sourceURL.path,
                "--project", projectURL.path,
                "--format", "json",
            ])

            XCTAssertEqual(result.exitCode, 0, "\(fixture.kindArgument) stdout: \(result.stdout)\nstderr: \(result.stderr)")
            let collectionURL = try assertCLIImportOutput(
                result.stdout,
                expectedCollectionNamePrefix: fixture.sourceName,
                expectedBundleExtensions: fixture.expectedBundleExtensions,
                expectsBinaryArtifacts: fixture.expectsBinaryArtifacts
            )
            if fixture.expectedBundleExtensions.contains("lungfishref"), fixture.archiveExtension != nil {
                try assertReferenceBundleProvenance(
                    in: collectionURL,
                    containsDurableSourcePaths: durablePathSpellings(for: sourceURL),
                    temporaryPathMarker: "/Project.lungfish/.tmp/application-export-import-"
                )
            }
        }
    }

    @discardableResult
    private func assertCLIImportOutput(
        _ stdout: String,
        expectedCollectionName: String? = nil,
        expectedCollectionNamePrefix: String? = nil,
        expectedBundleExtensions: Set<String> = ["lungfishref"],
        expectsBinaryArtifacts: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let events = try parseJSONLineEvents(stdout)
        XCTAssertTrue(events.contains { $0["event"] as? String == "progress" }, file: file, line: line)

        // Version 2 events, with the collection in outputs and described by one artifact.
        let complete = try ImportStreamCapture.assertVersion2Stream(
            stdout,
            importedPath: nil,
            artifactKind: "import-collection",
            artifactRole: "collection",
            file: file,
            line: line
        )
        guard case let .complete(outputs, _)? = complete.event, let collectionPath = outputs.first else {
            XCTFail("The stream does not end with a complete event", file: file, line: line)
            throw CocoaError(.fileReadUnknown)
        }
        let collectionURL = URL(fileURLWithPath: collectionPath, isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: collectionURL.path), file: file, line: line)

        if let expectedCollectionName {
            XCTAssertEqual(collectionURL.lastPathComponent, expectedCollectionName, file: file, line: line)
        }
        if let expectedCollectionNamePrefix {
            XCTAssertTrue(
                collectionURL.lastPathComponent.hasPrefix(expectedCollectionNamePrefix),
                "Unexpected collection name: \(collectionURL.lastPathComponent)",
                file: file,
                line: line
            )
        }

        XCTAssertTrue(fileManager.fileExists(atPath: collectionURL.appendingPathComponent("inventory.json").path), file: file, line: line)
        XCTAssertTrue(fileManager.fileExists(atPath: collectionURL.appendingPathComponent("import-report.md").path), file: file, line: line)
        XCTAssertTrue(fileManager.fileExists(atPath: collectionURL.appendingPathComponent(".lungfish-provenance.json").path), file: file, line: line)
        let importedExtensions = Set(try recursiveDirectories(at: collectionURL.appendingPathComponent("LGE Bundles")).map(\.pathExtension))
        XCTAssertTrue(expectedBundleExtensions.isSubset(of: importedExtensions), file: file, line: line)
        if expectsBinaryArtifacts {
            XCTAssertFalse(try recursiveFiles(at: collectionURL.appendingPathComponent("Binary Artifacts")).isEmpty, file: file, line: line)
        } else {
            XCTAssertFalse(fileManager.fileExists(atPath: collectionURL.appendingPathComponent("Binary Artifacts").path), file: file, line: line)
        }
        return collectionURL
    }

    private func assertReferenceBundleProvenance(
        in collectionURL: URL,
        containsDurableSourcePaths durableSourcePaths: Set<String>,
        temporaryPathMarker: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundles = try recursiveDirectories(at: collectionURL.appendingPathComponent("LGE Bundles"))
            .filter { $0.pathExtension == "lungfishref" }
        XCTAssertFalse(bundles.isEmpty, file: file, line: line)
        for bundleURL in bundles {
            let provenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
            let sidecar = String(
                decoding: PortablePath.resolveJSON(try Data(contentsOf: provenanceURL), forFileAt: provenanceURL),
                as: UTF8.self
            )
            let normalizedSidecar = sidecar.replacingOccurrences(of: "\\/", with: "/")
            XCTAssertTrue(
                durableSourcePaths.contains { normalizedSidecar.contains($0) },
                "Expected \(provenanceURL.path) to reference one durable source spelling from \(durableSourcePaths.sorted())",
                file: file,
                line: line
            )
            XCTAssertFalse(
                normalizedSidecar.contains(temporaryPathMarker),
                "Expected \(provenanceURL.path) to omit temporary path marker \(temporaryPathMarker)",
                file: file,
                line: line
            )
        }
    }

    private func durablePathSpellings(for url: URL) -> Set<String> {
        [
            url.path,
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
        ]
    }

    private func makeApplicationExportFixture(
        _ fixture: RepresentativeApplicationExportFixture,
        in root: URL
    ) throws -> URL {
        let source = root.appendingPathComponent(fixture.sourceName, isDirectory: true)
        try writeRepresentativeFiles(in: source, nativeRelativePath: fixture.nativeRelativePath)
        guard let archiveExtension = fixture.archiveExtension else {
            return source
        }
        let archiveURL = root.appendingPathComponent("\(fixture.sourceName).\(archiveExtension)")
        try zipDirectory(source, to: archiveURL)
        return archiveURL
    }

    private func makeGeneiousArchive(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("Representative", isDirectory: true)
        try writeRepresentativeFiles(in: source, nativeRelativePath: "document.geneious")
        let xml = """
        <geneious version="2024.0" minimumVersion="2023.0">
          <geneiousDocument class="urn:com.biomatters.geneious.publicapi.documents.sequence.NucleotideSequenceDocument"/>
          <hiddenField name="cache_name">Representative</hiddenField>
        </geneious>
        """
        try xml.write(to: source.appendingPathComponent("document.geneious"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0x02]).write(to: source.appendingPathComponent("fileData.1"))
        let archiveURL = root.appendingPathComponent("Representative.geneious")
        try zipDirectory(source, to: archiveURL)
        return archiveURL
    }

    private func writeRepresentativeFiles(in source: URL, nativeRelativePath: String) throws {
        try fileManager.createDirectory(at: source.appendingPathComponent("refs", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("reports", isDirectory: true), withIntermediateDirectories: true)
        try ">chr1\nACGTACGTACGTACGT\n".write(
            to: source.appendingPathComponent("refs/reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "sample\tmetric\nA\t1\n".write(
            to: source.appendingPathComponent("reports/summary.tsv"),
            atomically: true,
            encoding: .utf8
        )
        let nativeURL = source.appendingPathComponent(nativeRelativePath)
        try fileManager.createDirectory(at: nativeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch nativeURL.pathExtension.lowercased() {
        case "aln", "clustal":
            try """
            CLUSTAL W

            seq1 ACGT-A
            seq2 AC-TTA
            """.write(to: nativeURL, atomically: true, encoding: .utf8)
        case "nwk", "newick", "tree", "tre":
            try "((A:0.1,B:0.2)90:0.3,C:0.4);\n".write(to: nativeURL, atomically: true, encoding: .utf8)
        default:
            try "representative native export artifact\n".write(to: nativeURL, atomically: true, encoding: .utf8)
        }
    }

    private func parseJSONLineEvents(_ stdout: String) throws -> [[String: Any]] {
        try stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") }
            .map { line in
                let data = try XCTUnwrap(line.data(using: .utf8))
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
    }

    private func recursiveFiles(at root: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func recursiveDirectories(at root: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                directories.append(url)
            }
        }
        return directories
    }

    private func makeProject(in root: URL) throws -> URL {
        let projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("application-export-cli-e2e-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func zipDirectory(_ source: URL, to archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-qr", archiveURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private var cliBinaryPath: URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        )
    }

    private func runCLI(_ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let binary = cliBinaryPath else {
            throw XCTSkip("lungfish-cli binary not built at expected path")
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
}

private struct RepresentativeApplicationExportFixture {
    let kindArgument: String
    let sourceName: String
    let nativeRelativePath: String
    let archiveExtension: String?
    var expectedBundleExtensions: Set<String> = ["lungfishref"]
    var expectsBinaryArtifacts = true
}
