// FASTQBatchImporterCancellationTests.swift - A cancelled import leaves no bundle, staging folder or workspace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Review finding S4-S3: `lungfish-cli import fastq` now turns SIGTERM into a
/// cancel. The import must then stop and leave nothing half-built in the
/// project: no bundle, no hidden `.building-` folder and no workspace.
final class FASTQBatchImporterCancellationTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-cancel")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testACancelledBatchImportsNothing() async throws {
        let files = try writeRun("SRR9100001")
        let config = config()
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FASTQBatchImporter.runBatchImport(pairs: FASTQBatchImporter.detectPairs(from: files), config: config)
        }.value

        XCTAssertEqual(result.completed, 0)
        try assertNothingLeft()
    }

    /// The cancel lands after the statistics step, just before the bundle
    /// would be published.
    func testACancelLateInTheSampleLeavesNoBundleStagingFolderOrWorkspace() async throws {
        let files = try writeRun("SRR9100002")
        let config = config()
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    if case .stepComplete(_, let step, _) = event, step == "Compute statistics" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }.value

        XCTAssertEqual(result.completed, 0, "the cancelled sample is not published")
        try assertNothingLeft()
    }

    // MARK: - Helpers

    private func assertNothingLeft(file: StaticString = #filePath, line: UInt = #line) throws {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let importEntries = (try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []
        XCTAssertEqual(importEntries, [], "no bundle and no hidden .building- folder", file: file, line: line)
        let temp = project.appendingPathComponent(".tmp", isDirectory: true)
        let workspaces = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
            .filter { $0.hasPrefix("fastq-import-") }
        XCTAssertEqual(workspaces, [], "no import workspace", file: file, line: line)
    }

    private func config() -> FASTQBatchImporter.ImportConfig {
        FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: .given(.illumina),
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1
        )
    }

    private func writeRun(_ run: String) throws -> [URL] {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try [("_1", "ACGTACGT"), ("_2", "TTGGCCAA")].map { suffix, bases in
            let url = folder.appendingPathComponent("\(run)\(suffix).fastq")
            let text = (1...4).map { "@\(run).\($0) \($0) length=8\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
    }
}
