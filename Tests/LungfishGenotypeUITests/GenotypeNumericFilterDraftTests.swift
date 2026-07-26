import XCTest
@testable import LungfishGenotypeUI
import LungfishKit

@MainActor
final class GenotypeNumericFilterDraftTests: XCTestCase {
    func testIntegerDraftAllowsEmptyTypingWithoutPublishing() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var states: [GenotypeResultDisplayState] = []
        viewModel.onDisplayStateChanged = { states.append($0) }

        viewModel.updateMatrixMinimumReadsDraft("")
        scheduler.advance(by: 1)

        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "")
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 0)
        XCTAssertTrue(states.isEmpty)
    }

    func testValidPastedIntegerPublishesAfterExactlyTwoHundredMilliseconds() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var values: [Int] = []
        viewModel.onDisplayStateChanged = { values.append($0.matrixMinimumReads) }

        viewModel.updateMatrixMinimumReadsDraft("12,345")
        scheduler.advance(by: 0.199)
        XCTAssertTrue(values.isEmpty)

        scheduler.advance(by: 0.001)

        XCTAssertEqual(values, [12_345])
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 12_345)
    }

    func testDecimalDraftUsesLocaleDecimalSeparator() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(
            scheduler: scheduler,
            locale: Locale(identifier: "de_DE")
        )
        var values: [Double] = []
        viewModel.onDisplayStateChanged = { values.append($0.matrixMinimumPercent) }

        viewModel.updateMatrixMinimumPercentDraft("12,5")
        scheduler.advance(by: 0.2)

        XCTAssertEqual(values, [12.5])
        XCTAssertEqual(viewModel.displayState.matrixMinimumPercent, 12.5)
    }

    func testInvalidDraftNeverPublishesAndIdleRestoresCommittedValue() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let announcements = RecordingNumericFilterAnnouncements()
        let viewModel = makeViewModel(
            scheduler: scheduler,
            announcements: announcements
        )
        viewModel.updateDisplayState(.init(matrixMinimumReads: 42))
        var states: [GenotypeResultDisplayState] = []
        viewModel.onDisplayStateChanged = { states.append($0) }

        viewModel.updateMatrixMinimumReadsDraft("forty-two")
        XCTAssertTrue(viewModel.matrixMinimumReadsDraft.isInvalid)
        scheduler.advance(by: 0.2)

        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "42")
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 42)
        XCTAssertTrue(states.isEmpty)
        XCTAssertEqual(
            announcements.messages,
            ["Min reads must be a number from 0 through 100,000."]
        )
    }

    func testValidationAnnouncementPostsExactlyOncePerInvalidTransition() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let announcements = RecordingNumericFilterAnnouncements()
        let viewModel = makeViewModel(
            scheduler: scheduler,
            announcements: announcements
        )

        viewModel.updateMatrixMinimumReadsDraft("bad")
        viewModel.updateMatrixMinimumReadsDraft("still bad")
        XCTAssertEqual(announcements.messages.count, 1)

        viewModel.updateMatrixMinimumReadsDraft("12")
        viewModel.updateMatrixMinimumReadsDraft("bad again")

        XCTAssertEqual(announcements.messages.count, 2)
    }

    func testReturnCommitsImmediatelyAndClampsBounds() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var values: [Int] = []
        viewModel.onDisplayStateChanged = { values.append($0.matrixMinimumReads) }

        viewModel.updateMatrixMinimumReadsDraft("100001")
        viewModel.commitMatrixMinimumReadsDraft()

        XCTAssertEqual(values, [100_000])
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "100,000")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testFocusLossCommitsPercentImmediatelyAndClampsBounds() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var values: [Double] = []
        viewModel.onDisplayStateChanged = { values.append($0.matrixMinimumPercent) }

        viewModel.updateMatrixMinimumPercentDraft("101")
        viewModel.commitMatrixMinimumPercentDraft()

        XCTAssertEqual(values, [100])
        XCTAssertEqual(viewModel.matrixMinimumPercentDraft.draftText, "100.0")
    }

    func testEscapeRestoresLastCommittedValueWithoutPublishing() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        viewModel.updateDisplayState(.init(matrixMinimumReads: 87))
        var states: [GenotypeResultDisplayState] = []
        viewModel.onDisplayStateChanged = { states.append($0) }

        viewModel.updateMatrixMinimumReadsDraft("900")
        viewModel.restoreMatrixMinimumReadsDraft()
        scheduler.runAllIncludingCancelled()

        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "87")
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 87)
        XCTAssertTrue(states.isEmpty)
    }

    func testStepperValueIsVisibleImmediatelyAndPublishesOnlyLatestValue() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var values: [Int] = []
        viewModel.onDisplayStateChanged = { values.append($0.matrixMinimumReads) }

        viewModel.stepMatrixMinimumReads(up: true)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "1")
        XCTAssertTrue(values.isEmpty)
        viewModel.stepMatrixMinimumReads(up: true)
        viewModel.stepMatrixMinimumReads(up: true)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "3")

        scheduler.runAllIncludingCancelled()

        XCTAssertEqual(values, [3])
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 3)
    }

    func testPendingDraftCannotPublishAfterBundleSwitch() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var values: [Int] = []
        viewModel.onDisplayStateChanged = { values.append($0.matrixMinimumReads) }
        viewModel.updateMatrixMinimumReadsDraft("900")

        viewModel.update(
            isAvailable: true,
            state: .init(matrixMinimumReads: 17)
        )
        scheduler.runAllIncludingCancelled()

        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 17)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "17")
    }

    func testPendingDraftCannotPublishAfterInspectorClear() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var publicationCount = 0
        viewModel.onDisplayStateChanged = { _ in publicationCount += 1 }
        viewModel.updateMatrixMinimumReadsDraft("900")

        viewModel.clear()
        scheduler.runAllIncludingCancelled()

        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "0")
    }

    func testPendingDraftCannotPublishAfterCallbackRewire() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var oldPublications = 0
        var newPublications = 0
        viewModel.onDisplayStateChanged = { _ in oldPublications += 1 }
        viewModel.updateMatrixMinimumReadsDraft("900")

        viewModel.onDisplayStateChanged = { _ in newPublications += 1 }
        scheduler.runAllIncludingCancelled()

        XCTAssertEqual(oldPublications, 0)
        XCTAssertEqual(newPublications, 0)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "0")
    }

    func testPendingDraftCannotPublishAfterViewModelDeinitialization() {
        let scheduler = ManualGenotypeNumericFilterScheduler()
        var publicationCount = 0
        weak var weakViewModel: GenotypeResultDisplaySectionViewModel?
        do {
            var viewModel: GenotypeResultDisplaySectionViewModel? =
                makeViewModel(scheduler: scheduler)
            weakViewModel = viewModel
            viewModel?.onDisplayStateChanged = { _ in publicationCount += 1 }
            viewModel?.updateMatrixMinimumReadsDraft("900")
            viewModel = nil
        }

        XCTAssertNil(weakViewModel)
        scheduler.runAllIncludingCancelled()
        XCTAssertEqual(publicationCount, 0)
    }

    func testAccessibilityStateExposesStableIdentityValueBoundsAndActions() {
        let draft = GenotypeNumericFilterDraft(
            configuration: .matrixMinimumReads,
            committedValue: 42,
            locale: Locale(identifier: "en_US"),
            validationAnnouncementPoster: RecordingNumericFilterAnnouncements()
        )

        XCTAssertEqual(
            draft.configuration.fieldAccessibilityIdentifier,
            "genotype-view-minimum-reads-field"
        )
        XCTAssertEqual(
            draft.configuration.stepperAccessibilityIdentifier,
            "genotype-view-minimum-reads-stepper"
        )
        XCTAssertEqual(draft.accessibility.label, "Min reads")
        XCTAssertEqual(draft.accessibility.value, "42")
        XCTAssertEqual(draft.accessibility.bounds, "Minimum 0, maximum 100,000.")
        XCTAssertEqual(draft.accessibility.incrementAction, "Increase Min reads by 1.")
        XCTAssertEqual(draft.accessibility.decrementAction, "Decrease Min reads by 1.")
        XCTAssertNil(draft.accessibility.validationDescription)

        draft.updateDraftText("not a number")

        XCTAssertEqual(
            draft.accessibility.validationDescription,
            "Min reads must be a number from 0 through 100,000."
        )
    }

    func testPercentAccessibilityUsesSeparateStableIdentifiersAndHalfPercentStep() {
        let draft = GenotypeNumericFilterDraft(
            configuration: .matrixMinimumPercent,
            committedValue: 12.5,
            locale: Locale(identifier: "en_US"),
            validationAnnouncementPoster: RecordingNumericFilterAnnouncements()
        )

        XCTAssertEqual(
            draft.configuration.fieldAccessibilityIdentifier,
            "genotype-view-minimum-percent-field"
        )
        XCTAssertEqual(
            draft.configuration.stepperAccessibilityIdentifier,
            "genotype-view-minimum-percent-stepper"
        )
        XCTAssertEqual(draft.accessibility.label, "Min percent")
        XCTAssertEqual(draft.accessibility.value, "12.5 percent")
        XCTAssertEqual(draft.accessibility.bounds, "Minimum 0, maximum 100 percent.")
        XCTAssertEqual(draft.accessibility.incrementAction, "Increase Min percent by 0.5 percent.")
        XCTAssertEqual(draft.accessibility.decrementAction, "Decrease Min percent by 0.5 percent.")
    }

    private func makeViewModel(
        scheduler: ManualGenotypeNumericFilterScheduler,
        locale: Locale = Locale(identifier: "en_US"),
        announcements: RecordingNumericFilterAnnouncements =
            RecordingNumericFilterAnnouncements()
    ) -> GenotypeResultDisplaySectionViewModel {
        GenotypeResultDisplaySectionViewModel(
            numericFilterScheduler: scheduler,
            numericFilterLocale: locale,
            numericFilterValidationAnnouncementPoster: announcements
        )
    }
}

@MainActor
private final class RecordingNumericFilterAnnouncements:
    AccessibilityAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(
        _ message: String,
        priority _: ContentAccessibilityAnnouncementPriority
    ) {
        messages.append(message)
    }
}

@MainActor
private final class ManualGenotypeNumericFilterScheduler:
    GenotypeNumericFilterScheduling {
    private final class ScheduledTask: GenotypeNumericFilterScheduled {
        let deadline: TimeInterval
        let sequence: Int
        let action: @MainActor () -> Void
        var isCancelled = false

        init(
            deadline: TimeInterval,
            sequence: Int,
            action: @escaping @MainActor () -> Void
        ) {
            self.deadline = deadline
            self.sequence = sequence
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private var now: TimeInterval = 0
    private var nextSequence = 0
    private var tasks: [ScheduledTask] = []

    var pendingCount: Int {
        tasks.filter { !$0.isCancelled }.count
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any GenotypeNumericFilterScheduled {
        nextSequence += 1
        let task = ScheduledTask(
            deadline: now + delay,
            sequence: nextSequence,
            action: action
        )
        tasks.append(task)
        return task
    }

    func advance(by interval: TimeInterval) {
        now += interval
        runReady(includingCancelled: false)
    }

    func runAllIncludingCancelled() {
        now = .greatestFiniteMagnitude
        runReady(includingCancelled: true)
    }

    private func runReady(includingCancelled: Bool) {
        let ready = tasks
            .filter { $0.deadline <= now }
            .sorted {
                ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence)
            }
        tasks.removeAll { $0.deadline <= now }
        for task in ready where includingCancelled || !task.isCancelled {
            task.action()
        }
    }
}
