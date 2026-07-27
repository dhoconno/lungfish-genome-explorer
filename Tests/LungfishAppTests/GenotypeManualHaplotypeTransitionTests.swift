import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypeTransitionTests: XCTestCase {
    func testEveryAbandoningTransitionCanBeCancelledWithoutMutation() async {
        let transitions: [GenotypeManualHaplotypeDraftCoordinator.Transition] = [
            .selection,
            .search,
            .filter,
            .visibility,
            .lens,
            .reload,
            .bundleSwitch,
            .projectSwitch,
            .windowClose,
            .appQuit,
            .eligibilityChange,
        ]

        for transition in transitions {
            var isDirty = true
            var saveCount = 0
            var discardCount = 0
            let coordinator = GenotypeManualHaplotypeDraftCoordinator(
                hasUnsavedChanges: { isDirty },
                save: {
                    saveCount += 1
                    isDirty = false
                    return true
                },
                discard: {
                    discardCount += 1
                    isDirty = false
                    return true
                }
            )

            let allowed = await coordinator.prepare(
                for: transition,
                decision: { .cancel }
            )

            XCTAssertFalse(allowed, "\(transition)")
            XCTAssertTrue(isDirty, "\(transition)")
            XCTAssertEqual(saveCount, 0, "\(transition)")
            XCTAssertEqual(discardCount, 0, "\(transition)")
        }
    }

    func testSaveAndDiscardResolveOnlyAfterTheirOperationSucceeds() async {
        var isDirty = true
        var saveSucceeds = false
        var discardSucceeds = false
        let coordinator = GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { isDirty },
            save: {
                guard saveSucceeds else { return false }
                isDirty = false
                return true
            },
            discard: {
                guard discardSucceeds else { return false }
                isDirty = false
                return true
            }
        )

        let failedSave = await coordinator.prepare(
            for: .selection,
            decision: { .save }
        )
        XCTAssertFalse(failedSave)
        XCTAssertTrue(isDirty)

        saveSucceeds = true
        let saved = await coordinator.prepare(
            for: .selection,
            decision: { .save }
        )
        XCTAssertTrue(saved)
        XCTAssertFalse(isDirty)

        isDirty = true
        let failedDiscard = await coordinator.prepare(
            for: .reload,
            decision: { .discard }
        )
        XCTAssertFalse(failedDiscard)
        XCTAssertTrue(isDirty)

        discardSucceeds = true
        let discarded = await coordinator.prepare(
            for: .reload,
            decision: { .discard }
        )
        XCTAssertTrue(discarded)
        XCTAssertFalse(isDirty)
    }

    func testRepeatedCloseAndQuitRequestsShareOneResolution() async {
        var isDirty = true
        var promptCount = 0
        let gate = AsyncManualHaplotypeDecisionGate()
        let coordinator = GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { isDirty },
            save: {
                isDirty = false
                return true
            },
            discard: {
                isDirty = false
                return true
            }
        )

        let close = Task { @MainActor in
            await coordinator.prepare(for: .windowClose) {
                promptCount += 1
                return await gate.wait()
            }
        }
        await gate.waitUntilPending()
        let quit = Task { @MainActor in
            await coordinator.prepare(for: .appQuit) {
                promptCount += 1
                return .cancel
            }
        }
        await gate.resume(with: .discard)

        let closeAllowed = await close.value
        let quitAllowed = await quit.value
        XCTAssertTrue(closeAllowed)
        XCTAssertTrue(quitAllowed)
        XCTAssertEqual(promptCount, 1)
        XCTAssertFalse(isDirty)
    }

    func testRepeatedWindowCloseRequestsShareOnePromptAndCancelKeepsWindowOpen()
        async throws
    {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        var promptCount = 0
        let gate = AsyncManualHaplotypeDecisionGate()
        controller.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { transition in
                XCTAssertEqual(transition, .windowClose)
                promptCount += 1
                return await gate.wait() != .cancel
            }
        )

        XCTAssertFalse(controller.windowShouldClose(window))
        await gate.waitUntilPending()
        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertEqual(promptCount, 1)

        await gate.resume(with: .cancel)
        await controller.testingWaitForManualHaplotypeCloseResolution()

        XCTAssertEqual(promptCount, 1)
        XCTAssertNotNil(controller.window)
    }

    func testAppQuitChecksEveryDirtyWindowAndAnyCancelVetoesTermination()
        async
    {
        let first = MainWindowController()
        let second = MainWindowController()
        var firstTransitions:
            [GenotypeManualHaplotypeDraftCoordinator.Transition] = []
        var secondTransitions:
            [GenotypeManualHaplotypeDraftCoordinator.Transition] = []
        first.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { transition in
                firstTransitions.append(transition)
                return true
            }
        )
        second.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { transition in
                secondTransitions.append(transition)
                return false
            }
        )

        let allowed = await AppDelegate()
            .testingPrepareForManualHaplotypeTermination(
                in: [first, second]
            )

        XCTAssertFalse(allowed)
        XCTAssertEqual(firstTransitions, [.appQuit])
        XCTAssertEqual(secondTransitions, [.appQuit])
    }
}

private actor AsyncManualHaplotypeDecisionGate {
    private var continuation:
        CheckedContinuation<GenotypeManualHaplotypeDraftDecision, Never>?

    func wait() async -> GenotypeManualHaplotypeDraftDecision {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPending() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume(with decision: GenotypeManualHaplotypeDraftDecision) {
        continuation?.resume(returning: decision)
        continuation = nil
    }
}
