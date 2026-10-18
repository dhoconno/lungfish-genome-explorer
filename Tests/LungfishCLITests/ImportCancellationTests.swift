// ImportCancellationTests.swift - The cancel that the four import commands share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A63 M1, decision S7. `ImportCancellation.run` scopes the SIGTERM cancel around an import,
// and `ImportCancellation.blocking` lets a command that calls one synchronous importer end its wait the
// moment the task is cancelled, since such an importer cannot be interrupted. `ImportCommandsSIGTERMTests`
// proves the whole command through the built lungfish-cli. These cases prove the two pieces without a
// process.

import Foundation
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

    /// Pin of Phase 2.12 lane 12.06 (SWIFT 4, A63 review note 5a). `import msa` and `import tree` run their
    /// importer through `blocking`, which a cancel cannot stop. Their cancel arm removes the destination while
    /// the importer may still write, so a write that lands after the removal leaves a partial bundle beside
    /// "Nothing was published". The step that makes the two leaves publish by stage and rename flips this pin.
    func testACancelInTheWritePhaseLeavesWhatTheCallWritesAfterTheRemovalToday() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-write-phase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("aln.lungfishmsa", isDirectory: true)
        let lateFile = bundle.appendingPathComponent("manifest.json")
        let destination = ImportDestination()
        destination.set(bundle)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await ImportCancellation.blocking { () throws -> Int in
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                release.wait()
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: lateFile)
                return 1
            }
        }
        let began = await Self.waitFor { FileManager.default.fileExists(atPath: bundle.path) }
        XCTAssertTrue(began, "the call began to write")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled wait throws CancellationError")
        } catch is CancellationError {
            // expected
        }
        destination.removeIfCreatedByThisRun()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path), "the cancel arm removed the destination")
        release.signal()
        let wroteLate = await Self.waitFor { FileManager.default.fileExists(atPath: lateFile.path) }
        XCTAssertTrue(wroteLate, "the call still writes after the removal, so a partial bundle stays")
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
