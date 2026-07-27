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

    func testOutstandingDecisionIsOwnedByItsTransition() async {
        var isDirty = true
        var promptCount = 0
        var discardCount = 0
        let gate = AsyncManualHaplotypeDecisionGate()
        let coordinator = GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { isDirty },
            save: {
                isDirty = false
                return true
            },
            discard: {
                discardCount += 1
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
        XCTAssertFalse(quitAllowed)
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(discardCount, 1)
        XCTAssertFalse(isDirty)
    }

    func testAppQuitResolutionCannotBeCommittedByConcurrentSelection() async {
        var isDirty = true
        var discardCount = 0
        let gate = AsyncManualHaplotypeDecisionGate()
        let coordinator = GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { isDirty },
            save: {
                isDirty = false
                return true
            },
            discard: {
                discardCount += 1
                isDirty = false
                return true
            }
        )
        let quitResolution = Task { @MainActor in
            await coordinator.resolve(for: .appQuit) {
                await gate.wait()
            }
        }
        await gate.waitUntilPending()

        let selectionAllowed = await coordinator.prepare(
            for: .selection,
            decision: { .discard }
        )
        XCTAssertFalse(selectionAllowed)
        XCTAssertTrue(isDirty)
        XCTAssertEqual(discardCount, 0)

        await gate.resume(with: .discard)
        let resolution = await quitResolution.value
        let quitAllowed = await coordinator.commit(resolution)
        XCTAssertTrue(quitAllowed)
        XCTAssertFalse(isDirty)
        XCTAssertEqual(discardCount, 1)
    }

    func testOutstandingResolutionRetainsOwnershipAfterDraftBecomesClean()
        async
    {
        var isDirty = true
        var discardCount = 0
        let coordinator = GenotypeManualHaplotypeDraftCoordinator(
            hasUnsavedChanges: { isDirty },
            save: {
                isDirty = false
                return true
            },
            discard: {
                discardCount += 1
                isDirty = false
                return true
            }
        )
        let quitResolution = await coordinator.resolve(for: .appQuit) {
            .discard
        }
        isDirty = false

        let selectionAllowed = await coordinator.prepare(
            for: .selection,
            decision: { .discard }
        )

        XCTAssertFalse(selectionAllowed)
        XCTAssertEqual(discardCount, 0)
        let quitAllowed = await coordinator.commit(quitResolution)
        XCTAssertTrue(quitAllowed)
        XCTAssertEqual(discardCount, 1)
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

    func testProjectTransitionBurstRetainsOnlyLatestIntent() async {
        let controller = MainWindowController()
        var isDirty = true
        var applied: [Int] = []
        let gate = AsyncManualHaplotypeDecisionGate()
        controller.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { isDirty },
            prepare: { transition in
                XCTAssertEqual(transition, .projectSwitch)
                let decision = await gate.wait()
                if decision == .discard {
                    isDirty = false
                }
                return decision != .cancel
            }
        )

        XCTAssertTrue(controller.deferManualHaplotypeTransition(
            .projectSwitch,
            mutation: { applied.append(0) }
        ))
        await gate.waitUntilPending()
        for index in 1...100 {
            XCTAssertTrue(controller.deferManualHaplotypeTransition(
                .projectSwitch,
                mutation: { applied.append(index) }
            ))
        }
        XCTAssertEqual(
            controller.testingPendingFallbackManualHaplotypeMutationCount,
            1
        )

        await gate.resume(with: .discard)
        await controller.testingWaitForFallbackManualHaplotypeTransitions()

        XCTAssertEqual(applied, [100])
        XCTAssertEqual(
            controller.testingPendingFallbackManualHaplotypeMutationCount,
            0
        )
    }

    func testCleanIntentStillSupersedesWhileProjectTransitionIsBusy()
        async
    {
        let controller = MainWindowController()
        var isDirty = true
        var applied: [String] = []
        let decisionGate = AsyncManualHaplotypeDecisionGate()
        let completionGate = AsyncManualHaplotypeDecisionGate()
        controller.testingSetManualHaplotypeTransitionState(
            hasUnsavedDraft: { isDirty },
            prepare: { _ in
                let decision = await decisionGate.wait()
                isDirty = false
                _ = await completionGate.wait()
                return decision != .cancel
            }
        )

        XCTAssertTrue(controller.deferManualHaplotypeTransition(
            .projectSwitch,
            mutation: { applied.append("older") }
        ))
        await decisionGate.waitUntilPending()
        await decisionGate.resume(with: .discard)
        await completionGate.waitUntilPending()
        XCTAssertFalse(isDirty)

        XCTAssertTrue(controller.deferManualHaplotypeTransition(
            .projectSwitch,
            mutation: { applied.append("newer") }
        ))
        XCTAssertEqual(
            controller.testingPendingFallbackManualHaplotypeMutationCount,
            1
        )
        await completionGate.resume(with: .discard)
        await controller.testingWaitForFallbackManualHaplotypeTransitions()

        XCTAssertEqual(applied, ["newer"])
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

    func testAppQuitPreflightsEverySaveBeforeAnyDiscardForAllFailureOrders()
        async
    {
        for failingSaveIndex in [0, 2] {
            let controllers = (0..<4).map { _ in MainWindowController() }
            let decisions: [GenotypeManualHaplotypeDraftDecision] = [
                .save,
                .discard,
                .save,
                .discard,
            ]
            var drafts = (0..<4).map { "draft-\($0)" }
            var prepared: [Int] = []
            var finalized: [Int] = []
            for (index, controller) in controllers.enumerated() {
                controller.testingSetManualHaplotypeTransactionalTransitionState(
                    hasUnsavedDraft: { true },
                    decide: { transition in
                        XCTAssertEqual(transition, .appQuit)
                        return decisions[index]
                    },
                    prepare: { decision in
                        guard decision == .save else {
                            return true
                        }
                        prepared.append(index)
                        return index != failingSaveIndex
                    },
                    commit: { decision in
                        finalized.append(index)
                        drafts[index] =
                            decision == .save ? "saved" : "discarded"
                        return true
                    }
                )
            }

            let allowed = await AppDelegate()
                .testingPrepareForManualHaplotypeTermination(
                    in: controllers
                )

            XCTAssertFalse(allowed)
            XCTAssertEqual(
                prepared,
                failingSaveIndex == 0 ? [0] : [0, 2]
            )
            XCTAssertTrue(finalized.isEmpty)
            XCTAssertEqual(drafts, (0..<4).map { "draft-\($0)" })
        }
    }

    func testAppQuitFinalizesSavesBeforeDiscardsRegardlessOfWindowOrder()
        async
    {
        for decisions in [
            [
                GenotypeManualHaplotypeDraftDecision.discard,
                .save,
                .discard,
                .save,
            ],
            [.save, .discard, .save, .discard],
        ] {
            let controllers = (0..<4).map { _ in MainWindowController() }
            var events: [String] = []
            for (index, controller) in controllers.enumerated() {
                controller.testingSetManualHaplotypeTransactionalTransitionState(
                    hasUnsavedDraft: { true },
                    decide: { _ in decisions[index] },
                    prepare: { decision in
                        if decision == .save {
                            events.append("prepare-save-\(index)")
                        }
                        return true
                    },
                    commit: { decision in
                        events.append(
                            "\(decision == .save ? "save" : "discard")-\(index)"
                        )
                        return true
                    }
                )
            }

            let allowed = await AppDelegate()
                .testingPrepareForManualHaplotypeTermination(
                    in: controllers
                )
            XCTAssertTrue(
                allowed
            )
            let firstDiscard = try? XCTUnwrap(
                events.firstIndex { $0.hasPrefix("discard-") }
            )
            let lastSave = try? XCTUnwrap(
                events.lastIndex { $0.hasPrefix("save-") }
            )
            XCTAssertNotNil(firstDiscard)
            XCTAssertNotNil(lastSave)
            if let firstDiscard, let lastSave {
                XCTAssertLessThan(lastSave, firstDiscard)
            }
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
