// DatabaseBrowserGenomeRowRouteTests.swift - The route of the NCBI browser's genome rows and what its child gets
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

final class DatabaseBrowserGenomeRowRouteTests: XCTestCase {
    private let key = "lane-a44-test-key-0000"

    func testTheHiddenKeyPicksTheRoute() {
        let suite = makeTestDefaultsSuite(prefix: "genome-row-route")
        let settings = GenomeRowDownloadRouteSettings(defaults: suite.defaults)
        XCTAssertEqual(settings.route, GenomeRowDownloadRouteSettings.defaultRoute, "an unset key")
        let cases: [(Any, GenomeRowDownloadRoute)] = [
            ("cli", .cli), ("legacy", .legacy), ("LEGACY", .legacy), (true, .cli), (false, .legacy),
            ("NO", GenomeRowDownloadRouteSettings.defaultRoute),
        ]
        for (value, route) in cases {
            suite.defaults.set(value, forKey: GenomeRowDownloadRouteSettings.defaultsKey)
            XCTAssertEqual(settings.route, route, "\(value)")
        }
    }

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
