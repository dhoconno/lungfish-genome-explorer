// GenotypeWaitingRetryCountTests.swift - A matrix edit that waits for the workbook counts as saving (Phase 3.2 lane QUITEDIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A comment or review made while the workbook is being published waits behind the publication lock and tries again
// when its retry timer fires. Between two tries no edit is running, so Quit used to find nothing to wait for. These
// tests hold the lock so the edit stays queued, and read `isSavingAnnotationEdits` and the Quit wait at each point.
// Every way the retry can end must give back the count it took, since a count that never falls would make every later
// Quit wait the whole 15 seconds.

import XCTest
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishTestSupport

@MainActor
final class GenotypeWaitingRetryCountTests: GenotypeResultViewportTestCase {
    private static let genotype = "01_Mafa_A1_SUPPORTED"
    private static let body = "queued behind the workbook update"

    /// A bundle folder, the lock on it, the cell the edit targets and the scheduler that holds the retry.
    private struct Setup {
        let root: URL
        let bundleURL: URL
        let target: GenotypeAnnotationSidecar.MatrixTarget
        let lock: ONTGenotypeBundlePublicationLock
        let scheduler: MatrixAnnotationRetrySchedulerSpy
    }

    private func makeSetup() throws -> Setup {
        let root = try TestTempDirectory.make(prefix: "WaitingRetryCount")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return Setup(
            root: root,
            bundleURL: bundleURL,
            target: .cell(locus: "MHC-A", genotype: Self.genotype, sample: "AnimalA"),
            lock: try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL),
            scheduler: MatrixAnnotationRetrySchedulerSpy()
        )
    }

    /// A controller on `setup`'s bundle with one comment queued behind the lock and its first try done, so its retry
    /// is scheduled and nothing is running.
    private func makeWaitingController(_ setup: Setup) async -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        controller.matrixAnnotationRetryScheduler = setup.scheduler
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: setup.bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: Self.genotype, reads: 9)]
        ))
        controller.editMatrixComment(.init(targets: [setup.target], intent: .upsert(body: Self.body)))
        await waitForAnnotationEdits()
        return controller
    }

    private func savedBody(_ setup: Setup) throws -> String? {
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: setup.bundleURL)
        return sidecar.resolvedMatrixComments[setup.target]?.body
    }

    // MARK: - The edit counts while it waits

    func testAWaitingMatrixEditCountsAsSavingAndQuitWaitsForIt() async throws {
        let setup = try makeSetup()
        defer { TestTempDirectory.cleanup(setup.root) }
        let controller = await makeWaitingController(setup)

        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 1)
        XCTAssertEqual(setup.scheduler.scheduledCount, 1, "the edit never asked for its retry")
        XCTAssertTrue(
            GenotypeResultViewController.isSavingAnnotationEdits,
            "a waiting edit was not counted as saving, so Quit would not wait for it"
        )

        var quitWaitEnded = false
        let quitWait = Task { @MainActor in
            await GenotypeResultViewController.waitForAnnotationEditsToSave(timeout: .seconds(5))
            quitWaitEnded = true
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(quitWaitEnded, "the Quit wait ended while the edit still waited for its workbook")

        setup.lock.release()
        setup.scheduler.fireScheduledActions()
        await quitWait.value

        XCTAssertTrue(quitWaitEnded)
        XCTAssertFalse(GenotypeResultViewController.isSavingAnnotationEdits)
        XCTAssertEqual(try savedBody(setup), Self.body, "the edit was not saved when the Quit wait ended")
        withExtendedLifetime(controller) {}
    }

    // MARK: - Every way the retry ends gives its count back

    /// The retry fires and the lock is still held. The retry that runs gives its own count back and the new wait
    /// takes one, so the edit stays counted without the count growing.
    func testARetryThatFiresWithTheLockStillHeldKeepsTheEditCountedOnce() async throws {
        let setup = try makeSetup()
        defer { TestTempDirectory.cleanup(setup.root) }
        let controller = await makeWaitingController(setup)
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "the waiting edit was not counted")

        setup.scheduler.fireScheduledActions()
        await waitForAnnotationEdits()

        XCTAssertEqual(setup.scheduler.scheduledCount, 1, "the retry did not ask for another try")
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "the edit stopped counting while it still waited")
        setup.lock.release()
        setup.scheduler.fireScheduledActions()
        await GenotypeResultViewController.waitForAnnotationEditsToSave(timeout: .seconds(5))

        XCTAssertFalse(GenotypeResultViewController.isSavingAnnotationEdits, "the count never fell after the second retry")
        XCTAssertEqual(try savedBody(setup), Self.body)
        withExtendedLifetime(controller) {}
    }

    /// The retry fires, finds the lock free and drains the queue. The next Quit finds nothing to wait for.
    func testARetryThatDrainsTheQueueGivesItsCountBackAndTheNextQuitDoesNotWait() async throws {
        let setup = try makeSetup()
        defer { TestTempDirectory.cleanup(setup.root) }
        let controller = await makeWaitingController(setup)
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "the waiting edit was not counted")

        setup.lock.release()
        setup.scheduler.fireScheduledActions()
        await GenotypeResultViewController.waitForAnnotationEditsToSave(timeout: .seconds(5))

        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 0)
        XCTAssertFalse(GenotypeResultViewController.isSavingAnnotationEdits, "the count never fell after the queue drained")
        let started = ContinuousClock.now
        await GenotypeResultViewController.waitForAnnotationEditsToSave(timeout: .seconds(5))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "a later Quit waited with nothing saving")
        XCTAssertEqual(try savedBody(setup), Self.body)
    }

    /// The controller goes before its timer fires. The retry finds no controller and gives its count back.
    func testARetryWhoseControllerHasGoneGivesItsCountBack() async throws {
        let setup = try makeSetup()
        defer { TestTempDirectory.cleanup(setup.root) }
        weak var gone: GenotypeResultViewController?
        do {
            let controller = await makeWaitingController(setup)
            gone = controller
            XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "the waiting edit was not counted")
        }
        let released = await waitUntil(budget: .lookup) { gone == nil }
        XCTAssertTrue(released, "the controller stayed alive, so the retry cannot find it gone")
        XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "the count fell before the retry fired")

        setup.scheduler.fireScheduledActions()

        XCTAssertFalse(GenotypeResultViewController.isSavingAnnotationEdits, "the count never fell after the controller went")
        setup.lock.release()
    }

    /// The scheduler is dropped with its retry never fired. The count still falls, since nothing else can give it back.
    func testARetryThatIsDroppedWithoutFiringGivesItsCountBack() async throws {
        let setup = try makeSetup()
        defer { TestTempDirectory.cleanup(setup.root) }
        weak var gone: GenotypeResultViewController?
        do {
            let scheduler = MatrixAnnotationRetrySchedulerSpy()
            let controller = makeMatrixAnnotationGuardedController()
            controller.matrixAnnotationRetryScheduler = scheduler
            _ = controller.view
            controller.configure(result: makeResult(
                bundleURL: setup.bundleURL,
                samples: [],
                calls: [makeCall(sample: "AnimalA", genotype: Self.genotype, reads: 9)]
            ))
            controller.editMatrixComment(.init(targets: [setup.target], intent: .upsert(body: Self.body)))
            await waitForAnnotationEdits()
            gone = controller
            XCTAssertEqual(scheduler.scheduledCount, 1)
            XCTAssertTrue(GenotypeResultViewController.isSavingAnnotationEdits, "the waiting edit was not counted")
        }
        let fell = await waitUntil(budget: .lookup) {
            gone == nil && !GenotypeResultViewController.isSavingAnnotationEdits
        }

        XCTAssertTrue(fell, "a retry dropped without firing kept its count, so every later Quit would wait")
        setup.lock.release()
    }
}
