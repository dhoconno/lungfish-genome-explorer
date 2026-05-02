import Foundation
import XCTest

final class ApplicationExportImportE2ETests: XCTestCase {
    private let fileManager = FileManager.default
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? fileManager.removeItem(at: url)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
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

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        try assertCLIImportOutput(result.stdout, expectedCollectionName: "Representative Geneious Import")
    }

    func testApplicationExportCardsRunThroughCLIWithRepresentativeDatasets() throws {
        let fixtures: [RepresentativeApplicationExportFixture] = [
            .init(kindArgument: "clc-workbench", sourceName: "CLC Workbench Export", nativeRelativePath: "native/project.clc", archiveExtension: "zip"),
            .init(kindArgument: "dnastar-lasergene", sourceName: "Lasergene Export", nativeRelativePath: "native/project.pro", archiveExtension: nil),
            .init(kindArgument: "benchling-bulk", sourceName: "Benchling Bulk Export", nativeRelativePath: "benchling_export.json", archiveExtension: "zip"),
            .init(kindArgument: "sequence-design-library", sourceName: "Sequence Library Export", nativeRelativePath: "designs/library.dna", archiveExtension: nil),
            .init(kindArgument: "alignment-tree", sourceName: "Alignment Tree Export", nativeRelativePath: "alignments/example.aln", archiveExtension: nil),
            .init(kindArgument: "sequencing-platform-run-folder", sourceName: "Sequencing Run Export", nativeRelativePath: "RunInfo.xml", archiveExtension: nil),
            .init(kindArgument: "phylogenetics-result-set", sourceName: "Phylogenetics Export", nativeRelativePath: "usher/tree.nwk", archiveExtension: "zip"),
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

            XCTAssertEqual(result.exitCode, 0, "\(fixture.kindArgument) stderr: \(result.stderr)")
            try assertCLIImportOutput(result.stdout, expectedCollectionNamePrefix: fixture.sourceName)
        }
    }

    private func assertCLIImportOutput(
        _ stdout: String,
        expectedCollectionName: String? = nil,
        expectedCollectionNamePrefix: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let events = try parseJSONLineEvents(stdout)
        XCTAssertTrue(events.contains { $0["event"] as? String == "applicationExportImportStart" }, file: file, line: line)
        XCTAssertTrue(events.contains { $0["event"] as? String == "applicationExportProgress" }, file: file, line: line)

        let complete = try XCTUnwrap(
            events.first { $0["event"] as? String == "applicationExportImportComplete" },
            file: file,
            line: line
        )
        let collectionPath = try XCTUnwrap(complete["collection"] as? String, file: file, line: line)
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
        XCTAssertFalse(try recursiveDirectories(at: collectionURL.appendingPathComponent("LGE Bundles")).filter { $0.pathExtension == "lungfishref" }.isEmpty, file: file, line: line)
        XCTAssertFalse(try recursiveFiles(at: collectionURL.appendingPathComponent("Binary Artifacts")).isEmpty, file: file, line: line)
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
        try "representative native export artifact\n".write(to: nativeURL, atomically: true, encoding: .utf8)
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
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
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
}
