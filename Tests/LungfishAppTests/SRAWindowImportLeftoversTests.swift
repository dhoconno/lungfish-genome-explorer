// SRAWindowImportLeftoversTests.swift - What a cancelled CLI import of one SRA run leaves, and what the window does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// Review findings S4-S2 and S4-S3. A shell script stands in for
/// `lungfish-cli`, so no real import runs.
final class SRAWindowImportLeftoversTests: XCTestCase {

    private static let run = "SRR9000001"
    private var project: URL!
    private var imports: URL!
    private var priorCLIPath: String??

    override func setUp() async throws {
        try await super.setUp()
        await OperationCenter.useTemporaryFailureReportsForTesting()
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-import-leftovers-\(UUID().uuidString)/Project.lungfish", isDirectory: true)
        imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let priorCLIPath {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        try await super.tearDown()
    }

    // MARK: - Telling the run's bundle apart

    func testOnlyTheRunsNewBundleIsItsOwn() throws {
        let leftovers = SRAWindowImportLeftovers(projectDirectory: project, accession: Self.run, files: Self.files)
        _ = try makeFolder(".SRR9000002.building-another")
        let bundle = try makeFolder("\(Self.run).lungfishfastq")
        XCTAssertEqual(leftovers.publishedBundle()?.lastPathComponent, bundle.lastPathComponent)
    }

    func testABundleCreatedBeforeTheLaunchIsNotTheRunsEvenIfItIsNew() throws {
        let launchedAt = Date().addingTimeInterval(60)
        let leftovers = SRAWindowImportLeftovers(
            projectDirectory: project, accession: Self.run, files: Self.files, launchedAt: launchedAt
        )
        _ = try makeFolder("\(Self.run).lungfishfastq")
        XCTAssertNil(leftovers.publishedBundle(), "made before the launch, so not provably the run's")
    }

    func testABundleThatWasThereBeforeIsNotTheRuns() throws {
        _ = try makeFolder("\(Self.run).lungfishfastq")
        let leftovers = SRAWindowImportLeftovers(projectDirectory: project, accession: Self.run, files: Self.files)
        XCTAssertNil(leftovers.publishedBundle())
    }

    // MARK: - The window's import of one run

    /// S4-S2: a cancel after staging and before the launch: no CLI process
    /// and no bundle.
    func testACancelBeforeTheLaunchRunsNoCLIAndMakesNoBundle() async throws {
        let marker = project.deletingLastPathComponent().appendingPathComponent("launched")
        try useFakeCLI("""
        #!/bin/sh
        touch "\(marker.path)"
        mkdir -p "\(imports.path)/\(Self.run).lungfishfastq"
        echo '{"event":"sampleComplete","sample":"\(Self.run)","bundle":"\(Self.run).lungfishfastq","durationSeconds":0.1,"originalBytes":1,"finalBytes":1}'
        """)
        let outcome = await importRun(cancelledFirst: true)

        XCTAssertEqual(outcome, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no CLI process ran")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), [], "no bundle")
    }

    /// Orchestrator ruling: the window never removes a `.building-` folder,
    /// since it cannot tell one from a concurrent import's. A same-named
    /// folder the window did not create survives a cancelled import.
    func testASameNamedStagingFolderTheWindowDidNotCreateSurvivesACancel() async throws {
        let marker = project.deletingLastPathComponent().appendingPathComponent("launched")
        let concurrent = imports.appendingPathComponent(".\(Self.run).building-concurrent", isDirectory: true)
        let killed = imports.appendingPathComponent(".\(Self.run).building-killed", isDirectory: true)
        try useFakeCLI("""
        #!/bin/sh
        mkdir -p "\(killed.path)"
        touch "\(marker.path)"
        while true; do sleep 0.1; done
        """)
        // Another import of the same sample, started before this one.
        try FileManager.default.createDirectory(at: concurrent, withIntermediateDirectories: true)
        let outcome = await importRun(cancelWhen: { FileManager.default.fileExists(atPath: marker.path) })

        XCTAssertEqual(outcome, "cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: concurrent.path), "the other import's folder survives")
        XCTAssertTrue(FileManager.default.fileExists(atPath: killed.path), "the window removes no staging folder")
    }

    /// S4-S3: a cancel that lands after the CLI published the bundle but
    /// before it said so. The bundle is complete, so the window keeps it and
    /// records the run's SRA metadata in it.
    func testAfterACancelABundleTheCLIPublishedIsKeptForTheWindowToFinish() async throws {
        let marker = project.deletingLastPathComponent().appendingPathComponent("launched")
        let bundle = imports.appendingPathComponent("\(Self.run).lungfishfastq", isDirectory: true)
        try useFakeCLI("""
        #!/bin/sh
        mkdir -p "\(bundle.path)"
        touch "\(marker.path)"
        while true; do sleep 0.1; done
        """)
        let outcome = await importRun(cancelWhen: { FileManager.default.fileExists(atPath: marker.path) })

        XCTAssertEqual(outcome, bundle.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    // MARK: - Helpers

    private static let files = ["_1", "_2"].map { URL(fileURLWithPath: "/staged/\(run)\($0).fastq.gz") }

    /// Runs the window's import of one run and says how it ended: the
    /// bundle's name, "cancelled", or the error.
    private func importRun(
        cancelledFirst: Bool = false,
        cancelWhen condition: (@Sendable () -> Bool)? = nil
    ) async -> String {
        let row = await MainActor.run {
            OperationCenter.shared.begin(title: "SRA import test", detail: "Starting", operationType: .download, cliCommand: nil).rowID
        }
        addTeardownBlock {
            await MainActor.run {
                _ = OperationCenter.shared.complete(id: row, detail: "Test finished")
                OperationCenter.shared.clearItem(id: row)
            }
        }
        let project = self.project!
        let outcome = Outcome()
        let task = Task.detached {
            if cancelledFirst {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            do {
                let bundle = try await SRAWindowImportLeftovers.importRun(
                    arguments: [],
                    operationID: row,
                    projectDirectory: project,
                    accession: Self.run,
                    files: Self.files
                )
                outcome.set(bundle.lastPathComponent)
            } catch is CancellationError {
                outcome.set("cancelled")
            } catch {
                outcome.set("error: \(error.localizedDescription)")
            }
        }
        if let condition {
            let started = await waitUntil(timeout: .seconds(30)) { condition() }
            XCTAssertTrue(started, "the fake CLI started")
            task.cancel()
        }
        let ended = await waitUntil(timeout: .seconds(30)) { outcome.value != nil }
        XCTAssertTrue(ended, "the import ends promptly")
        return outcome.value ?? "still running"
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = imports.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func useFakeCLI(_ script: String) throws {
        let cli = project.deletingLastPathComponent().appendingPathComponent("lungfish-cli")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        if priorCLIPath == nil {
            priorCLIPath = .some(ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"])
        }
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
    }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { if stored == nil { stored = value } } }
}
