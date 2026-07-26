import AppKit
import SwiftUI
import XCTest
@testable import LungfishGenotypeUI
import LungfishKit

@MainActor
final class GenotypeNumericFilterControlTests: XCTestCase {
    func testHostedFieldsRouteReturnTabAndEscapeToTheSelectedDraft() throws {
        let scheduler = HostedNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var states: [GenotypeResultDisplayState] = []
        viewModel.onDisplayStateChanged = { states.append($0) }
        let host = hostSection(viewModel)
        defer { host.window.orderOut(nil) }
        var readsField = try nativeTextField("Min reads", in: host)

        var editor = try replaceText("12", in: readsField, host: host)
        editor.insertNewline(nil)
        flush(host)

        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 12)
        XCTAssertEqual(states.last?.matrixMinimumReads, 12)

        let percentField = try nativeTextField("Min percent", in: host)
        editor = try replaceText("22.5", in: percentField, host: host)
        editor.insertTab(nil)
        flush(host)

        XCTAssertEqual(viewModel.displayState.matrixMinimumPercent, 22.5)
        XCTAssertEqual(states.last?.matrixMinimumPercent, 22.5)

        readsField = try nativeTextField("Min reads", in: host)
        _ = try replaceText("99", in: readsField, host: host)
        sendEscape(to: host)
        flush(host)

        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 12)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "12")
    }

    func testHostedStepperCommitsItsExactNativeValueAndEscapeKeepsClick() throws {
        let scheduler = HostedNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        var values: [Int] = []
        viewModel.onDisplayStateChanged = {
            values.append($0.matrixMinimumReads)
        }
        let host = hostSection(viewModel)
        defer { host.window.orderOut(nil) }
        var readsField = try nativeTextField("Min reads", in: host)
        let readsStepper = try nativeStepper(
            adjacentTo: readsField,
            in: host
        )

        _ = try replaceText("100001", in: readsField, host: host)
        clickDecrement(readsStepper, host: host)
        flush(host)

        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 99_999)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "99,999")
        XCTAssertEqual(values, [99_999])
        XCTAssertEqual(scheduler.pendingCount, 0)

        readsField = try nativeTextField("Min reads", in: host)
        _ = try focus(readsField, host: host)
        sendEscape(to: host)
        flush(host)

        XCTAssertEqual(viewModel.displayState.matrixMinimumReads, 99_999)
        XCTAssertEqual(viewModel.matrixMinimumReadsDraft.draftText, "99,999")
        XCTAssertEqual(values, [99_999])
    }

    func testHostedControlsUseSharedAccessibilityContractAndNativeActions() throws {
        let scheduler = HostedNumericFilterScheduler()
        let viewModel = makeViewModel(scheduler: scheduler)
        let host = hostSection(viewModel)
        defer { host.window.orderOut(nil) }
        let readsField = try nativeTextField("Min reads", in: host)
        let readsStepper = try nativeStepper(
            adjacentTo: readsField,
            in: host
        )
        let percentField = try nativeTextField("Min percent", in: host)
        let percentStepper = try nativeStepper(
            adjacentTo: percentField,
            in: host
        )
        let readsDraft = viewModel.matrixMinimumReadsDraft
        let percentDraft = viewModel.matrixMinimumPercentDraft

        XCTAssertEqual(
            readsDraft.configuration.fieldAccessibilityIdentifier,
            "genotype-view-minimum-reads-field"
        )
        XCTAssertEqual(
            readsDraft.configuration.stepperAccessibilityIdentifier,
            "genotype-view-minimum-reads-stepper"
        )
        XCTAssertEqual(readsDraft.accessibility.label, "Min reads")
        XCTAssertEqual(readsDraft.accessibility.value, "0")
        XCTAssertEqual(
            readsDraft.accessibility.bounds,
            "Minimum 0, maximum 100,000."
        )
        XCTAssertEqual(
            readsDraft.accessibility.incrementAction,
            "Increase Min reads by 1."
        )
        XCTAssertEqual(
            readsDraft.accessibility.decrementAction,
            "Decrease Min reads by 1."
        )
        XCTAssertEqual(readsField.stringValue, "0")
        XCTAssertTrue(readsStepper.isEnabled)

        XCTAssertEqual(
            percentDraft.configuration.fieldAccessibilityIdentifier,
            "genotype-view-minimum-percent-field"
        )
        XCTAssertEqual(
            percentDraft.configuration.stepperAccessibilityIdentifier,
            "genotype-view-minimum-percent-stepper"
        )
        XCTAssertEqual(percentDraft.accessibility.label, "Min percent")
        XCTAssertEqual(percentDraft.accessibility.value, "0.0 percent")
        XCTAssertEqual(
            percentDraft.accessibility.bounds,
            "Minimum 0, maximum 100 percent."
        )
        XCTAssertEqual(
            percentDraft.accessibility.incrementAction,
            "Increase Min percent by 0.5 percent."
        )
        XCTAssertEqual(
            percentDraft.accessibility.decrementAction,
            "Decrease Min percent by 0.5 percent."
        )
        XCTAssertEqual(percentField.stringValue, "0.0")
        XCTAssertTrue(percentStepper.isEnabled)

        _ = try replaceText("invalid", in: readsField, host: host)
        flush(host)

        XCTAssertEqual(
            readsDraft.accessibility.validationDescription,
            "Min reads must be a number from 0 through 100,000."
        )
    }

    private func makeViewModel(
        scheduler: HostedNumericFilterScheduler
    ) -> GenotypeResultDisplaySectionViewModel {
        let viewModel = GenotypeResultDisplaySectionViewModel(
            numericFilterScheduler: scheduler,
            numericFilterLocale: Locale(identifier: "en_US"),
            numericFilterValidationAnnouncementPoster:
                HostedNumericFilterAnnouncements()
        )
        viewModel.update(
            isAvailable: true,
            state: .init(summaryViewMode: .matrix),
            hasHaplotypingResult: true
        )
        return viewModel
    }

    private typealias Host = (
        window: NSWindow,
        view: NSHostingView<GenotypeResultDisplaySection>
    )

    private func hostSection(
        _ viewModel: GenotypeResultDisplaySectionViewModel
    ) -> Host {
        let host = NSHostingView(
            rootView: GenotypeResultDisplaySection(viewModel: viewModel)
        )
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 1_200)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        flush((window, host))
        return (window, host)
    }

    private func nativeTextField(
        _ placeholder: String,
        in host: Host
    ) throws -> NSTextField {
        try XCTUnwrap(
            descendants(of: host.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == placeholder },
            "Expected hosted native text field \(placeholder)."
        )
    }

    private func nativeStepper(
        adjacentTo field: NSTextField,
        in host: Host
    ) throws -> NSStepper {
        let fieldFrame = field.convert(field.bounds, to: host.view)
        return try XCTUnwrap(
            descendants(of: host.view)
                .compactMap { $0 as? NSStepper }
                .min {
                    let leftFrame = $0.convert($0.bounds, to: host.view)
                    let rightFrame = $1.convert($1.bounds, to: host.view)
                    return abs(leftFrame.midY - fieldFrame.midY)
                        < abs(rightFrame.midY - fieldFrame.midY)
                },
            "Expected hosted native stepper beside \(field.placeholderString ?? "field")."
        )
    }

    private func replaceText(
        _ value: String,
        in field: NSTextField,
        host: Host
    ) throws -> NSTextView {
        let editor = try focus(field, host: host)
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: editor.selectedRange())
        flush(host)
        return editor
    }

    private func focus(
        _ field: NSTextField,
        host: Host
    ) throws -> NSTextView {
        XCTAssertTrue(host.window.makeFirstResponder(field))
        flush(host)
        return try XCTUnwrap(
            field.currentEditor() as? NSTextView,
            "Expected an active field editor for \(field.placeholderString ?? "field")."
        )
    }

    private func sendEscape(to host: Host) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        )
        if let event {
            host.window.sendEvent(event)
        }
        flush(host)
    }

    private func clickDecrement(_ stepper: NSStepper, host: Host) {
        stepper.doubleValue = stepper.minValue
        _ = stepper.sendAction(stepper.action, to: stepper.target)
        flush(host)
    }

    private func flush(_ host: Host) {
        host.window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        host.window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

}

@MainActor
private final class HostedNumericFilterAnnouncements:
    AccessibilityAnnouncementPosting {
    func post(
        _: String,
        priority _: ContentAccessibilityAnnouncementPriority
    ) {}
}

@MainActor
private final class HostedNumericFilterScheduler:
    GenotypeNumericFilterScheduling {
    private final class Task: GenotypeNumericFilterScheduled {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private var tasks: [Task] = []

    var pendingCount: Int {
        tasks.filter { !$0.isCancelled }.count
    }

    func schedule(
        after _: TimeInterval,
        _: @escaping @MainActor () -> Void
    ) -> any GenotypeNumericFilterScheduled {
        let task = Task()
        tasks.append(task)
        return task
    }
}
