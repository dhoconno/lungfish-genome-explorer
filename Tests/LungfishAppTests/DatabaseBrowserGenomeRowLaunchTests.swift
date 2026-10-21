// DatabaseBrowserGenomeRowLaunchTests.swift - The route of the NCBI browser's genome rows and what its child gets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44, ruling Q2b and SWIFT 6. A genome row of the browser's batch download runs
// `lungfish-cli fetch genome <accession> --output-dir <folder> --format json`, or the in-process
// build when the hidden key asks for it (C4). The key is read through the defaults the test gives,
// the folder is the project's Downloads folder or the user's, and the NCBI key reaches the child
// through its environment, never its arguments or the recorded command. The child here is a stub
// script that records what it was given and prints the two events a run ends with.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

final class DatabaseBrowserGenomeRowLaunchTests: XCTestCase {
    private let key = "lane-a44-test-key-0000"

    func testTheFolderIsTheProjectsDownloadsFolderOrTheUsers() {
        let project = URL(fileURLWithPath: "/tmp/lane a44/Project.lungfish", isDirectory: true)
        let user = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)
        XCTAssertEqual(
            DatabaseBrowserViewModel.genomeRowFolder(projectURL: project, userDownloads: user).path,
            "/tmp/lane a44/Project.lungfish/Downloads")
        XCTAssertEqual(DatabaseBrowserViewModel.genomeRowFolder(projectURL: nil, userDownloads: user), user)
        XCTAssertFalse(DatabaseBrowserViewModel.userDownloadsFolder.path.contains("Lungfish Downloads"))
    }

    @MainActor
    func testTheArgumentsAndTheRecordedCommandHoldNoKey() throws {
        let folder = URL(fileURLWithPath: "/tmp/lane a44/Project.lungfish/Downloads", isDirectory: true)
        let arguments = DatabaseBrowserViewModel.genomeFetchArguments(accessions: ["GCF_000000001.1"], folder: folder)
        XCTAssertEqual(arguments, [
            "fetch", "genome", "GCF_000000001.1", "--output-dir", folder.path, "--format", "json",
        ])
        XCTAssertEqual(DatabaseBrowserViewModel.genomeFetchEnvironment(apiKey: key), ["NCBI_API_KEY": key])
        XCTAssertEqual(DatabaseBrowserViewModel.genomeFetchEnvironment(apiKey: nil), [:])
        let command = try XCTUnwrap(DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .ncbi, searchType: .genome, accessions: ["GCF_000000001.1"],
            projectURL: folder.deletingLastPathComponent()))
        for text in [arguments.joined(separator: " "), command] {
            XCTAssertFalse(text.contains(key), text)
            XCTAssertFalse(text.contains("--api-key"), text)
            XCTAssertFalse(text.contains("NCBI_API_KEY"), text)
        }
    }

    func testTheChildGetsTheKeyThroughItsEnvironmentOnlyAndNamesItsBundle() async throws {
        let root = try TestTempDirectory.make(prefix: "genome-row-child")
        defer { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("Project.lungfish/Downloads", isDirectory: true)
        let bundle = folder.appendingPathComponent("Stand-in - StandInAsm1.lungfishref", isDirectory: true)
        let stub = try Self.writeStubCLI(in: root, bundle: bundle)

        let download = GenomeRowCLIDownload(operationID: UUID(), index: 1, totalCount: 2, cliURLOverride: stub)
        let returned = try await download.fetch("GCF_000000001.1", into: folder, apiKey: key)

        XCTAssertEqual(returned.path, bundle.path)
        let argv = try String(contentsOf: root.appendingPathComponent("argv.txt"), encoding: .utf8)
        XCTAssertEqual(argv, "fetch\ngenome\nGCF_000000001.1\n--output-dir\n\(folder.path)\n--format\njson\n")
        XCTAssertFalse(argv.contains(key))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("key.txt"), encoding: .utf8), key)
        XCTAssertEqual(download.share(0.5), 0.75, accuracy: 1e-9)
        XCTAssertEqual(download.share(2), 1, accuracy: 1e-9)
    }

    /// Ruling 1. A genome row on the CLI route writes into the Downloads folder and never asks for
    /// the batch folder, so a CLI genome batch leaves no `batch-` entry under `<project>/.tmp`. The
    /// loop of `performBatchDownload` itself finds the app's CLI and reports through DownloadCenter,
    /// so this runs the row the loop runs, with the stub CLI.
    @MainActor
    func testACLIGenomeRowMakesNoBatchFolder() async throws {
        let root = try TestTempDirectory.make(prefix: "genome-row-no-batch")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bundle = project.appendingPathComponent("Downloads/Stand-in - StandInAsm1.lungfishref", isDirectory: true)
        let stub = try Self.writeStubCLI(in: root, bundle: bundle)
        let service = NCBIService(apiKey: nil, environment: [:])
        let record = SearchResultRecord(id: "9900001", accession: "GCF_000000001.1", title: "StandInAsm1", source: .ncbi)

        let returned = try await DatabaseBrowserViewModel.downloadGenomeRow(
            record, index: 0, totalCount: 1, operationID: UUID(),
            ncbi: service, projectURL: project, cliURLOverride: stub)

        XCTAssertEqual(returned.path, bundle.path)
        XCTAssertEqual(Self.batchFolders(in: project), [])
    }

    /// The `batch-` folders under `<project>/.tmp`.
    static func batchFolders(in project: URL) -> [String] {
        let tmp = project.appendingPathComponent(".tmp", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return names.filter { $0.hasPrefix("batch-") }.sorted()
    }

    /// A stand-in `lungfish-cli` that writes its arguments and `NCBI_API_KEY` beside it, then prints
    /// a progress event and a complete event that names `bundle`.
    static func writeStubCLI(in folder: URL, bundle: URL) throws -> URL {
        let complete = #"{"event":"complete","message":"Fetched 1 genome(s)","outputs":["\#(bundle.path)"],"progress":1,"schemaVersion":2}"#
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(folder.path)/argv.txt'
            printf '%s' "${NCBI_API_KEY-unset}" > '\(folder.path)/key.txt'
            printf '%s\\n' '{"event":"progress","message":"GCF_000000001.1: Building","progress":0.5,"schemaVersion":2}'
            printf '%s\\n' '\(complete)'
            """
        let url = folder.appendingPathComponent("lungfish-cli")
        try (script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
