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

    func testAppQuitCancelIsTransactionalForEveryWindowRegardlessOfVetoOrder()
        async
    {
        for cancellingIndex in [0, 2] {
            let controllers = [
                MainWindowController(),
                MainWindowController(),
                MainWindowController(),
            ]
            var drafts = ["first-draft", "middle-draft", "last-draft"]
            var decisions: [Int] = []
            var commits: [Int] = []
            for (index, controller) in controllers.enumerated() {
                controller.testingSetManualHaplotypeTransactionalTransitionState(
                    hasUnsavedDraft: { true },
                    decide: { transition in
                        XCTAssertEqual(transition, .appQuit)
                        decisions.append(index)
                        return index == cancellingIndex ? .cancel : .discard
                    },
                    commit: { decision in
                        commits.append(index)
                        switch decision {
                        case .save:
                            drafts[index] = "saved"
                        case .discard:
                            drafts[index] = "discarded"
                        case .cancel:
                            XCTFail("Cancel must never enter the commit phase.")
                        }
                        return true
                    }
                )
            }

            let allowed = await AppDelegate()
                .testingPrepareForManualHaplotypeTermination(
                    in: controllers
                )

            XCTAssertFalse(allowed)
            XCTAssertEqual(decisions, [0, 1, 2])
            XCTAssertTrue(commits.isEmpty)
            XCTAssertEqual(
                drafts,
                ["first-draft", "middle-draft", "last-draft"]
            )
        }
    }

    func testAppQuitAwaitsEveryDirtyWindowWhenFirstVetoesAndRepeatedRequestsStaySingleFlight()
        async
    {
        let first = MainWindowController()
        let second = MainWindowController()
        let delegate = AppDelegate()
        let secondGate = AsyncManualHaplotypeDecisionGate()
        var firstPromptCount = 0
        var secondPromptCount = 0
        var replies: [Bool] = []
        first.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { transition in
                XCTAssertEqual(transition, .appQuit)
                firstPromptCount += 1
                return false
            }
        )
        second.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { transition in
                XCTAssertEqual(transition, .appQuit)
                secondPromptCount += 1
                return await secondGate.wait() != .cancel
            }
        )
        delegate.testingSetMainWindowControllers([first, second])

        XCTAssertEqual(
            delegate.testingApplicationShouldTerminate {
                replies.append($0)
            },
            .terminateLater
        )
        XCTAssertEqual(
            delegate.testingApplicationShouldTerminate {
                replies.append($0)
            },
            .terminateLater
        )
        for _ in 0..<100 where !(await secondGate.isPending) {
            await Task.yield()
        }

        XCTAssertEqual(firstPromptCount, 1)
        XCTAssertEqual(secondPromptCount, 1)
        let secondPromptIsPending = await secondGate.isPending
        XCTAssertTrue(secondPromptIsPending)
        XCTAssertTrue(replies.isEmpty)

        await secondGate.resume(with: .discard)
        await delegate.testingWaitForManualHaplotypeTermination()

        XCTAssertEqual(firstPromptCount, 1)
        XCTAssertEqual(secondPromptCount, 1)
        XCTAssertEqual(replies, [false])
    }

    func testApplicationTerminationRepliesOnceAndReentryTerminatesNow()
        async
    {
        let controller = MainWindowController()
        let delegate = AppDelegate()
        let gate = AsyncManualHaplotypeDecisionGate()
        var replies: [Bool] = []
        controller.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { true },
            prepare: { transition in
                XCTAssertEqual(transition, .appQuit)
                return await gate.wait() != .cancel
            }
        )
        delegate.testingSetMainWindowControllers([controller])

        XCTAssertEqual(
            delegate.testingApplicationShouldTerminate {
                replies.append($0)
            },
            .terminateLater
        )
        XCTAssertEqual(
            delegate.testingApplicationShouldTerminate {
                replies.append($0)
            },
            .terminateLater
        )
        await gate.waitUntilPending()
        await gate.resume(with: .discard)
        await delegate.testingWaitForManualHaplotypeTermination()

        XCTAssertEqual(replies, [true])
        XCTAssertEqual(
            delegate.testingApplicationShouldTerminate {
                replies.append($0)
            },
            .terminateNow
        )
        XCTAssertEqual(replies, [true])
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

    var isPending: Bool {
        continuation != nil
    }

    func resume(with decision: GenotypeManualHaplotypeDraftDecision) {
        continuation?.resume(returning: decision)
        continuation = nil
    }
}
