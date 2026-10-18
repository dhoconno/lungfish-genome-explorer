// ImportCancellationTests.swift - The cancel that the four import commands share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1, decision S7. `ImportCancellation.run` scopes the SIGTERM cancel around an import,
// and `ImportCancellation.blocking` lets a command that calls one synchronous importer end its wait the
// moment the task is cancelled, since such an importer cannot be interrupted. `ImportCommandsSIGTERMTests`
// proves the whole command through the built lungfish-cli. These cases prove the two pieces without a
// process, and the staged publish of `import msa` and `import tree` (Phase 2.12 lane 12.06) with them.

import Foundation
import LungfishIO
import LungfishTestSupport
import os
import XCTest
@testable import LungfishCLI

final class ImportCancellationTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    func testABlockingCallReturnsItsResult() async throws {
        let value = try await ImportCancellation.blocking { 42 }
        XCTAssertEqual(value, 42)
    }

    func testABlockingCallThatFailsThrowsItsError() async throws {
        do {
            _ = try await ImportCancellation.blocking { () throws -> Int in throw Boom() }
            XCTFail("the call's error is thrown")
        } catch let error as Boom {
            XCTAssertEqual(error, Boom())
        }
    }

    /// A cancel ends the wait at once while the call sits in something it cannot leave, such as a read.
    func testACancelEndsTheWaitWhileTheCallIsStuck() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task { try await ImportCancellation.blocking { release.wait(); return 1 } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let cancelledAt = ContinuousClock.now
        do {
            _ = try await task.value
            XCTFail("a cancelled wait throws CancellationError")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(5), "the wait does not wait for the call")
    }

    /// A cancel that came before the call started ends the wait too.
    func testACancelBeforeTheCallStartsEndsTheWait() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task { try await ImportCancellation.blocking { release.wait(); return 1 } }
        task.cancel()
        let cancelledAt = ContinuousClock.now
        do {
            _ = try await task.value
            XCTFail("a cancelled wait throws CancellationError")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(5))
    }

    /// Phase 2.12 lane 12.06 (SWIFT 4, A63 review note 5a), the pin of M1 flipped. `import msa` and `import tree`
    /// run their importer through `blocking`, which a cancel cannot stop, so they write into a stage in the
    /// project's temporary folder and publish it with one rename once the importer returned (`publishStagedBundle`).
    /// A cancel in the write phase ends the wait at once, a write that lands after it lands in the stage alone, and
    /// the destination never holds a part of a bundle.
    func testACancelInTheWritePhaseLeavesTheLateWriteInTheStageAndPublishesNothing() async throws {
        let project = try Self.makeFolder(named: "Project.lungfish")
        defer { TestTempDirectory.cleanup(project.deletingLastPathComponent()) }
        let bundle = project.appendingPathComponent("Multiple Sequence Alignments/aln.lungfishmsa", isDirectory: true)
        let destination = ImportDestination()
        let staged = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await publishStagedBundle(at: bundle, prefix: "import-msa-", guardedBy: destination) { (stagedURL: URL) throws -> Int in
                try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
                staged.withLock { $0 = stagedURL }
                release.wait()
                try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: stagedURL.appendingPathComponent("manifest.json"))
                return 1
            }
        }
        let began = await Self.waitFor { staged.withLock { $0 } != nil }
        XCTAssertTrue(began, "the call began to write")
        let stagedURL = try XCTUnwrap(staged.withLock { $0 })
        let temporaryFolder = ProjectTempDirectory.tempRoot(for: project).path + "/"
        XCTAssertTrue(stagedURL.path.hasPrefix(temporaryFolder), "the stage sits in the project's temporary folder. \(stagedURL.path)")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled wait throws CancellationError")
        } catch is CancellationError {
            // expected
        }
        destination.removeIfCreatedByThisRun()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path), "the cancel removed the stage")
        release.signal()
        let lateFile = stagedURL.appendingPathComponent("manifest.json")
        let wroteLate = await Self.waitFor { FileManager.default.fileExists(atPath: lateFile.path) }
        XCTAssertTrue(wroteLate, "the call still writes after the cancel, into the stage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), "the destination holds no part of a bundle")
    }

    /// A staged import publishes the whole bundle under its name with one rename and leaves no stage behind.
    func testAStagedImportPublishesTheWholeBundleAndRemovesItsStage() async throws {
        let project = try Self.makeFolder(named: "Project.lungfish")
        defer { TestTempDirectory.cleanup(project.deletingLastPathComponent()) }
        let bundle = project.appendingPathComponent("Phylogenetic Trees/tree.lungfishtree", isDirectory: true)
        let seen = OSAllocatedUnfairLock<(staged: URL, publishedEarly: Bool)?>(initialState: nil)
        let value = try await publishStagedBundle(at: bundle, prefix: "import-tree-", guardedBy: ImportDestination()) { (stagedURL: URL) throws -> Int in
            try FileManager.default.createDirectory(at: stagedURL.appendingPathComponent("tree"), withIntermediateDirectories: true)
            try Data("(A,B);\n".utf8).write(to: stagedURL.appendingPathComponent("tree/primary.nwk"))
            let publishedEarly = FileManager.default.fileExists(atPath: bundle.path)
            seen.withLock { $0 = (stagedURL, publishedEarly) }
            return 7
        }
        XCTAssertEqual(value, 7)
        let observed = try XCTUnwrap(seen.withLock { $0 })
        XCTAssertFalse(observed.publishedEarly, "nothing is published while the importer writes")
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("tree/primary.nwk"), encoding: .utf8), "(A,B);\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: observed.staged.deletingLastPathComponent().path), "the stage is removed")
    }

    /// The rename refuses a bundle that appeared at the destination while the importer wrote, keeps it as it was
    /// and leaves no stage behind.
    func testAStagedImportRefusesABundleThatAppearedAtTheDestinationMeanwhile() async throws {
        let project = try Self.makeFolder(named: "Project.lungfish")
        defer { TestTempDirectory.cleanup(project.deletingLastPathComponent()) }
        let bundle = project.appendingPathComponent("Multiple Sequence Alignments/aln.lungfishmsa", isDirectory: true)
        let staged = OSAllocatedUnfairLock<URL?>(initialState: nil)
        do {
            _ = try await publishStagedBundle(at: bundle, prefix: "import-msa-", guardedBy: ImportDestination()) { (stagedURL: URL) throws -> Int in
                staged.withLock { $0 = stagedURL }
                try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
                try Data("staged".utf8).write(to: stagedURL.appendingPathComponent("manifest.json"))
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data("theirs".utf8).write(to: bundle.appendingPathComponent("manifest.json"))
                return 1
            }
            XCTFail("the rename refuses a destination that exists")
        } catch is CancellationError {
            XCTFail("a refusal is not a cancel")
        } catch {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("manifest.json"), encoding: .utf8), "theirs")
        let stagedURL = try XCTUnwrap(staged.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.deletingLastPathComponent().path), "the stage is removed")
    }

    /// Outside a project the stage sits in the replacement folder of the destination's volume, never beside the
    /// destination, and the bundle is published the same way.
    func testAStagedImportOutsideAProjectPublishesTheBundle() async throws {
        let folder = try Self.makeFolder(named: "Plain Folder")
        defer { TestTempDirectory.cleanup(folder.deletingLastPathComponent()) }
        let bundle = folder.appendingPathComponent("aln.lungfishmsa", isDirectory: true)
        let staged = OSAllocatedUnfairLock<URL?>(initialState: nil)
        _ = try await publishStagedBundle(at: bundle, prefix: "import-msa-", guardedBy: ImportDestination()) { (stagedURL: URL) throws -> Int in
            staged.withLock { $0 = stagedURL }
            try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: stagedURL.appendingPathComponent("manifest.json"))
            return 1
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        let stagedURL = try XCTUnwrap(staged.withLock { $0 })
        XCTAssertFalse(stagedURL.path.hasPrefix(folder.path + "/"), "no stage sits beside the destination. \(stagedURL.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.deletingLastPathComponent().path), "the stage is removed")
    }

    /// A new folder named `name` in a scratch root of its own, holding the destination folders of the two leaves.
    private static func makeFolder(named name: String) throws -> URL {
        let folder = try TestTempDirectory.make(prefix: "import-staged-publish").appendingPathComponent(name, isDirectory: true)
        for destination in ["Multiple Sequence Alignments", "Phylogenetic Trees"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(destination), withIntermediateDirectories: true)
        }
        return folder
    }

    /// Polls `condition` every 20 ms for up to 30 seconds and returns whether it held.
    private static func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testRunReturnsTheWorksResultAndItsErrorWhenNoSIGTERMCameIn() async {
        let success = await ImportCancellation.run { 7 }
        if case .success(let value) = success { XCTAssertEqual(value, 7) } else { XCTFail("\(success)") }

        let failure = await ImportCancellation.run { () async throws -> Int in throw Boom() }
        if case .failure(let error) = failure { XCTAssertTrue(error is Boom, "\(error)") } else { XCTFail("\(failure)") }
    }
}
