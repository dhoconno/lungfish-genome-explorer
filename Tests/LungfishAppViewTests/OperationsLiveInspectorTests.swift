import AppKit
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class OperationsLiveInspectorTests: XCTestCase {
    private func find<T: NSView>(_ root: NSView, _ identifier: String, as type: T.Type) -> T? {
        if root.accessibilityIdentifier() == identifier { return root as? T }
        return root.subviews.compactMap { find($0, identifier, as: type) }.first
    }

    private func panel(id: UUID) throws -> (OperationsPanelController, NSView, NSTableView) {
        _ = NSApplication.shared
        let controller = OperationsPanelController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 700))
        let view = try XCTUnwrap(window.contentViewController?.view)
        view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(find(view, "operations-table", as: NSTableView.self))
        let row = try XCTUnwrap(OperationCenter.shared.items.firstIndex { $0.id == id })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let titleColumn = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "title" })
        let titleCell = try XCTUnwrap(table.view(atColumn: titleColumn, row: row, makeIfNecessary: true))
        let logButton = try XCTUnwrap(titleCell.viewWithTag(102) as? NSButton)
        logButton.performClick(nil)
        view.layoutSubtreeIfNeeded()
        return (controller, view, table)
    }

    func testContinuousUpdatesRenderLatestLineWithoutWaitingForSilence() async throws {
        let id = OperationCenter.shared.start(title: "Live inspector fixture", detail: "Working", operationType: .assembly)
        defer {
            _ = OperationCenter.shared.complete(id: id, detail: "Done")
            OperationCenter.shared.clearItem(id: id)
        }
        let (controller, view, table) = try panel(id: id)
        defer { controller.close() }
        var observedDuringStream = false
        var observedInLogDuringStream = false
        for index in 0..<20 {
            OperationCenter.shared.log(id: id, level: .info, message: "Live output \(index)")
            try await Task.sleep(for: .milliseconds(30))
            view.layoutSubtreeIfNeeded()
            if let header = find(view, "operations-inspector-latest", as: NSTextField.self),
               header.stringValue.contains("Live output") { observedDuringStream = true }
            if let log = find(view, "operations-inspector-log-text", as: NSTextView.self),
               log.string.contains("Live output \(index)") { observedInLogDuringStream = true }
        }
        XCTAssertTrue(observedDuringStream, "A continuing stream must not restart the refresh deadline")
        XCTAssertTrue(observedInLogDuringStream, "The open log must update while the operation is still producing output")
        XCTAssertNil(table.tableColumn(withIdentifier: .init("eta")))
        XCTAssertEqual(table.tableColumn(withIdentifier: .init("elapsed"))?.title, "Time")
        let progressColumn = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "progress" })
        let cell = try XCTUnwrap(table.view(atColumn: progressColumn, row: 0, makeIfNecessary: true))
        XCTAssertNotNil(find(cell, "operations-progress-\(id)", as: NSTextField.self))
        let titleColumn = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "title" })
        let titleCell = try XCTUnwrap(table.view(atColumn: titleColumn, row: 0, makeIfNecessary: true))
        let latest = try XCTUnwrap(find(titleCell, "operations-latest-\(id)", as: NSTextField.self))
        XCTAssertTrue(latest.stringValue.contains("Live output"))
    }

    func testLogSelectionPausesFollowingAndSurvivesNewLinesAndSwitching() async throws {
        let other = OperationCenter.shared.start(title: "Other fixture", detail: "Working", operationType: .assembly)
        let id = OperationCenter.shared.start(title: "Reading fixture", detail: "Working", operationType: .assembly)
        defer {
            for value in [id, other] {
                _ = OperationCenter.shared.complete(id: value, detail: "Done")
                OperationCenter.shared.clearItem(id: value)
            }
        }
        for index in 0..<120 { OperationCenter.shared.log(id: id, level: .info, message: "Earlier output \(index)") }
        let (controller, view, table) = try panel(id: id)
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(200))
        let text = try XCTUnwrap(find(view, "operations-inspector-log-text", as: NSTextView.self))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "First opening follows the tail")
        text.setSelectedRange(NSRange(location: 0, length: 8))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let selection = text.selectedRange()
        OperationCenter.shared.log(id: id, level: .info, message: "New output while reading")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        let jump = try XCTUnwrap(find(view, "operations-inspector-jump-latest", as: NSButton.self))
        XCTAssertTrue(jump.title.contains("1 new"))
        let follow = try XCTUnwrap(find(view, "operations-inspector-follow-latest", as: NSButton.self))
        XCTAssertEqual(follow.title, "Reviewing log history")
        XCTAssertEqual(follow.accessibilityLabel(), "Follow latest log output")
        let title = try XCTUnwrap(find(view, "operations-inspector-title", as: NSTextField.self))
        XCTAssertTrue(title.stringValue.contains("Running"), "Reviewing logs must not pause the operation")
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        view.layoutSubtreeIfNeeded()
        let inspector = try XCTUnwrap(find(view, "operations-log-inspector", as: NSView.self))
        for control in [follow, jump] {
            let rect = inspector.convert(control.bounds, from: control)
            XCTAssertTrue(inspector.bounds.contains(rect), "Log review controls must fit at minimum width")
        }
        let latest = try XCTUnwrap(find(view, "operations-inspector-latest", as: NSTextField.self))
        XCTAssertTrue(latest.stringValue.contains("New output while reading"))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(text.selectedRange(), selection)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        jump.performClick(nil)
        XCTAssertEqual(follow.title, "Follow latest")
        XCTAssertEqual(text.selectedRange().length, 0)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        OperationCenter.shared.log(id: id, level: .info, message: "Following again")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(text.string.contains("Following again"))
        XCTAssertFalse(jump.title.contains("new"))
    }
    func testUserScrollPausesButResizeKeepsFollowing() async throws {
        let id = OperationCenter.shared.start(title: "Resize fixture", detail: "Graph construction", operationType: .assembly)
        defer {
            _ = OperationCenter.shared.complete(id: id, detail: "Done")
            OperationCenter.shared.clearItem(id: id)
        }
        for index in 0..<120 { OperationCenter.shared.log(id: id, level: .info, message: "Graph output \(index)") }
        let (controller, view, _) = try panel(id: id)
        defer { controller.close() }
        try await Task.sleep(for: .milliseconds(200))
        let window = try XCTUnwrap(controller.window)
        let follow = try XCTUnwrap(find(view, "operations-inspector-follow-latest", as: NSButton.self))
        let text = try XCTUnwrap(find(view, "operations-inspector-log-text", as: NSTextView.self))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        XCTAssertEqual(follow.state, .on)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(follow.state, .on, "Window resize is not user log scrolling")
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, text.bounds.maxY - 3)

        // A live-scroll notification is emitted by AppKit for a user's scrollbar
        // or gesture scroll. A plain bounds change from layout must not pause.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(follow.state, .off)
        OperationCenter.shared.log(id: id, level: .info, message: "Output while scrolled up")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        let jump = try XCTUnwrap(find(view, "operations-inspector-jump-latest", as: NSButton.self))
        XCTAssertTrue(jump.title.contains("1 new"))
        jump.performClick(nil)
        XCTAssertEqual(follow.state, .on)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, text.bounds.maxY - 3)
    }

    func testNarrowInspectorKeepsFailureDetailsAndLogInsideWindow() async throws {
        let id = OperationCenter.shared.start(
            title: "SPAdes assembly: sample 01", detail: "Preparing assembly", operationType: .assembly,
            cliCommand: "lungfish-cli assemble --assembler spades --input /project/reads/sample-01.fastq --threads 8"
        )
        defer { OperationCenter.shared.clearItem(id: id) }
        for index in 0..<80 {
            OperationCenter.shared.log(id: id, level: .info, message: "Assembly log line \(index): constructing graph")
        }
        _ = OperationCenter.shared.fail(id: id, detail: "Assembler exited with status 1",
            errorMessage: "Assembly failed: insufficient memory to construct the graph.",
            errorDetail: "Tool stderr and the exact command remain available in this diagnostic snapshot.")
        let (controller, view, _) = try panel(id: id)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let inspector = try XCTUnwrap(find(view, "operations-log-inspector", as: NSView.self))
        let text = try XCTUnwrap(find(view, "operations-inspector-log-text", as: NSTextView.self))
        let log = try XCTUnwrap(text.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(inspector.bounds.height, 329)
        XCTAssertGreaterThanOrEqual(log.bounds.height, 69)
        XCTAssertGreaterThanOrEqual(log.bounds.width, 570)
        for identifier in ["operations-inspector-latest", "operations-inspector-failure", "operations-inspector-jump-latest", "operations-inspector-actions"] {
            let control = try XCTUnwrap(find(view, identifier, as: NSView.self))
            let rect = inspector.convert(control.bounds, from: control)
            XCTAssertTrue(inspector.bounds.insetBy(dx: -1, dy: -1).contains(rect), "\(identifier) must remain inside the inspector")
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/issue33-operations.png"))
    }

    /// The details-pane title was clipped at the top on finished and failed
    /// rows. Every header control must sit fully inside the inspector.
    func testInspectorTitleIsNotClippedForFinishedAndFailedRows() async throws {
        let completed = OperationCenter.shared.start(
            title: "Map Reads (minimap2): finished fixture", detail: "Mapping", operationType: .fastqOperation,
            cliCommand: "lungfish-cli map reads.fastq --reference ref.fasta"
        )
        OperationCenter.shared.log(id: completed, level: .info, message: "Running minimap2...")
        _ = OperationCenter.shared.complete(id: completed, detail: "Mapping complete: 10/10 reads mapped")
        let failed = OperationCenter.shared.start(
            title: "Map Reads (minimap2): failed fixture", detail: "Mapping", operationType: .fastqOperation,
            cliCommand: "lungfish-cli map reads.fastq --reference ref.fasta --extra-args --bogus"
        )
        OperationCenter.shared.log(id: failed, level: .info, message: "Running minimap2...")
        _ = OperationCenter.shared.fail(
            id: failed, detail: "minimap2 failed",
            errorMessage: "minimap2 exited with status 1: [E::main] unknown option --bogus. The run stopped before any reads were mapped.",
            errorDetail: "[E::main] unknown option --bogus"
        )
        defer {
            OperationCenter.shared.clearItem(id: completed)
            OperationCenter.shared.clearItem(id: failed)
        }

        for id in [completed, failed] {
            let (controller, view, _) = try panel(id: id)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            let inspector = try XCTUnwrap(find(view, "operations-log-inspector", as: NSView.self))
            for identifier in ["operations-inspector-title", "operations-inspector-close", "operations-inspector-latest"] {
                let control = try XCTUnwrap(find(view, identifier, as: NSView.self))
                let rect = inspector.convert(control.bounds, from: control)
                XCTAssertTrue(
                    inspector.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                    "\(identifier) must remain inside the inspector: \(rect) vs \(inspector.bounds)"
                )
            }
            let title = try XCTUnwrap(find(view, "operations-inspector-title", as: NSTextField.self))
            XCTAssertGreaterThanOrEqual(
                title.frame.height, title.intrinsicContentSize.height - 0.5,
                "the title must get its full line height"
            )
        }
    }

    private func label(_ root: NSView, text: String) -> NSTextField? {
        if let field = root as? NSTextField, field.stringValue == text { return field }
        return root.subviews.compactMap { label($0, text: text) }.first
    }

    /// Manual capture at a 1200x650 panel showed the details title
    /// ("FASTQ: fastp Adapter + Quality Trim · Completed") clipped at its
    /// bottom by the Command label. Each header row must get its full
    /// height and sit strictly above the next one.
    func testDrawerHeaderRowsDoNotOverlapAtManualCaptureSize() async throws {
        let completed = OperationCenter.shared.start(
            title: "FASTQ: fastp Adapter + Quality Trim", detail: "Preparing...", operationType: .fastqOperation,
            cliCommand: "lungfish-cli fastq fastp-trim HG002.lungfishfastq --output <derived>"
        )
        for index in 0..<200 {
            OperationCenter.shared.log(id: completed, level: .info, message: "fastp: Read1 before filtering: total reads \(index) quality and length filtering ongoing with a long line of output text")
        }
        OperationCenter.shared.log(id: completed, level: .info, message: "Completed in 4.2s")
        let failed = OperationCenter.shared.start(
            title: "FASTQ: fastp Adapter + Quality Trim", detail: "Preparing...", operationType: .fastqOperation,
            cliCommand: "lungfish-cli fastq fastp-trim HG002.lungfishfastq --output <derived>"
        )
        _ = OperationCenter.shared.fail(id: failed, detail: "fastp failed", errorMessage: "fastp exited with status 1")
        defer {
            OperationCenter.shared.clearItem(id: completed)
            OperationCenter.shared.clearItem(id: failed)
        }

        for id in [completed, failed] {
            let (controller, view, _) = try panel(id: id)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 1200, height: 650))
            view.layoutSubtreeIfNeeded()
            if id == completed {
                // Finish while the drawer is open, as a real run does.
                _ = OperationCenter.shared.complete(id: completed, detail: "Done in 4.2s")
            }
            try await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let inspector = try XCTUnwrap(find(view, "operations-log-inspector", as: NSView.self))
            let title = try XCTUnwrap(find(inspector, "operations-inspector-title", as: NSTextField.self))
            let latest = try XCTUnwrap(find(inspector, "operations-inspector-latest", as: NSTextField.self))
            let failure = try XCTUnwrap(find(inspector, "operations-inspector-failure", as: NSTextField.self))
            let command = try XCTUnwrap(label(inspector, text: "Command"))
            let rows = [title, latest, failure, command].filter { !$0.isHidden }
            let frames = rows.map { inspector.convert($0.bounds, from: $0) }
            let described = zip(rows, frames).map { "\($0.0.stringValue.prefix(24)): \($0.1)" }.joined(separator: "; ")
            for (field, frame) in zip(rows, frames) {
                XCTAssertGreaterThanOrEqual(
                    frame.height, field.intrinsicContentSize.height - 0.5,
                    "\(field.stringValue.prefix(24)) must get its full line height: \(described)"
                )
                XCTAssertTrue(inspector.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), described)
            }
            for (upper, lower) in zip(frames, frames.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    upper.minY, lower.maxY - 0.5,
                    "header rows overlap: \(described)"
                )
            }
        }
    }

    /// When the drawer is shorter than its header, the title used to be
    /// squeezed with the other header rows and drew clipped at its bottom
    /// by the row beneath it. The title keeps its full line at the top and
    /// the overflow is clipped from the bottom of the drawer instead.
    func testTitleKeepsItsFullLineWhenDrawerIsShorterThanItsHeader() throws {
        let center = OperationCenter()
        let id = center.start(title: "FASTQ: fastp Adapter + Quality Trim", detail: "Preparing...",
                              operationType: .fastqOperation,
                              cliCommand: "lungfish-cli fastq fastp-trim HG002.lungfishfastq")
        center.log(id: id, level: .info, message: "Completed in 4.2s")
        center.complete(id: id, detail: "Done in 4.2s")
        let item = try XCTUnwrap(center.items.first { $0.id == id })

        for height in [CGFloat(60), 100, 140] {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: height))
            let inspector = OperationsLogInspector(frame: host.bounds)
            inspector.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(inspector)
            NSLayoutConstraint.activate([
                inspector.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                inspector.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                inspector.topAnchor.constraint(equalTo: host.topAnchor),
                inspector.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                host.widthAnchor.constraint(equalToConstant: 1200),
                host.heightAnchor.constraint(equalToConstant: height),
            ])
            inspector.display(item)
            host.layoutSubtreeIfNeeded()

            XCTAssertEqual(inspector.bounds.height, height, accuracy: 0.5)
            XCTAssertTrue(inspector.clipsToBounds, "overflow must not paint outside the drawer")
            let title = try XCTUnwrap(find(inspector, "operations-inspector-title", as: NSTextField.self))
            let latest = try XCTUnwrap(find(inspector, "operations-inspector-latest", as: NSTextField.self))
            let titleFrame = inspector.convert(title.bounds, from: title)
            let latestFrame = inspector.convert(latest.bounds, from: latest)
            XCTAssertGreaterThanOrEqual(
                titleFrame.height, title.intrinsicContentSize.height - 0.5,
                "height \(height): the title must get its full line, got \(titleFrame)"
            )
            XCTAssertEqual(titleFrame.maxY, height - 8, accuracy: 1, "height \(height): the title stays pinned to the top")
            XCTAssertGreaterThanOrEqual(
                titleFrame.minY, latestFrame.maxY - 0.5,
                "height \(height): the next row must not overlap the title: \(titleFrame) vs \(latestFrame)"
            )
        }
    }

    func testDrawerShowsCommandSupportsTextSizingAndClosesFromInspector() throws {
        let command = "lungfish-cli fastq orient --input /project/reads.fastq --output /project/oriented.fastq"
        let id = OperationCenter.shared.start(
            title: "Command fixture", detail: "Orienting reads", operationType: .fastqOperation,
            cliCommand: command
        )
        defer {
            _ = OperationCenter.shared.complete(id: id, detail: "Done")
            OperationCenter.shared.clearItem(id: id)
        }
        let (controller, view, _) = try panel(id: id)
        defer { controller.close() }

        let commandText = try XCTUnwrap(find(view, "operations-inspector-command-text", as: NSTextView.self))
        XCTAssertEqual(commandText.string, command)
        XCTAssertTrue(commandText.isSelectable)
        XCTAssertNil(find(view, "operations-inspector-details-toggle", as: NSButton.self))

        let logText = try XCTUnwrap(find(view, "operations-inspector-log-text", as: NSTextView.self))
        let originalSize = try XCTUnwrap(logText.font?.pointSize)
        let larger = try XCTUnwrap(find(view, "operations-inspector-larger-text", as: NSButton.self))
        let smaller = try XCTUnwrap(find(view, "operations-inspector-smaller-text", as: NSButton.self))
        if larger.isEnabled {
            larger.performClick(nil)
            XCTAssertEqual(try XCTUnwrap(logText.font?.pointSize), originalSize + 1)
            smaller.performClick(nil)
        } else {
            smaller.performClick(nil)
            XCTAssertEqual(try XCTUnwrap(logText.font?.pointSize), originalSize - 1)
            larger.performClick(nil)
        }
        XCTAssertEqual(try XCTUnwrap(logText.font?.pointSize), originalSize)

        let inspector = try XCTUnwrap(find(view, "operations-log-inspector", as: NSView.self))
        let close = try XCTUnwrap(find(view, "operations-inspector-close", as: NSButton.self))
        close.performClick(nil)
        XCTAssertTrue(inspector.isHidden)
    }

    func testTimestampIncludesDateOnlyAfterTwentyFourHours() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 26, hour: 14, minute: 0
        )))
        let recent = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: -23, to: now))
        let old = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: -25, to: now))
        let recentText = OperationsLogInspector.timestamp(for: recent, at: now)
        let oldText = OperationsLogInspector.timestamp(for: old, at: now)
        XCTAssertFalse(recentText.contains("2026"))
        XCTAssertTrue(oldText.contains("2026"))
    }

    /// A drawer shorter than the header plus the log's preferred minimum
    /// used to break the stack's top pin, drawing the title above the
    /// inspector. The log must give up height instead.
    func testShortInspectorKeepsTitleOnScreenForFailedOperation() throws {
        let center = OperationCenter()
        let id = center.start(title: "Map Reads (minimap2): short drawer", detail: "Mapping",
                              cliCommand: "lungfish-cli map reads.fastq --reference ref.fasta")
        center.log(id: id, level: .info, message: "Running minimap2...")
        center.fail(id: id, detail: "minimap2 failed",
                    errorMessage: "minimap2 exited with status 1: [E::main] unknown option --bogus. The run stopped before any reads were mapped and no result was written.",
                    errorDetail: "[E::main] unknown option --bogus")
        let item = try XCTUnwrap(center.items.first { $0.id == id })

        // The split view gives the drawer a fixed height; the inspector
        // cannot grow past it.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 220))
        let inspector = OperationsLogInspector(frame: host.bounds)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(inspector)
        NSLayoutConstraint.activate([
            inspector.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: host.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 700),
            host.heightAnchor.constraint(equalToConstant: 220),
        ])
        inspector.display(item)
        host.layoutSubtreeIfNeeded()
        inspector.layoutSubtreeIfNeeded()

        XCTAssertEqual(inspector.bounds.height, 220, accuracy: 0.5)
        // Before the fix the header text fields were compressed (title 16pt
        // tall squeezed to 12pt, failure text to 0pt) and drew clipped at
        // the top.
        for identifier in ["operations-inspector-title", "operations-inspector-latest"] {
            let field = try XCTUnwrap(find(inspector, identifier, as: NSTextField.self))
            XCTAssertGreaterThanOrEqual(
                field.frame.height, field.intrinsicContentSize.height - 0.5,
                "\(identifier) must get its full line height, got \(field.frame)"
            )
        }
        let failure = try XCTUnwrap(find(inspector, "operations-inspector-failure", as: NSTextField.self))
        XCTAssertFalse(failure.isHidden)
        XCTAssertGreaterThanOrEqual(failure.frame.height, 15, "the failure text must stay readable")
        for identifier in ["operations-inspector-title", "operations-inspector-close", "operations-inspector-latest"] {
            let control = try XCTUnwrap(find(inspector, identifier, as: NSView.self))
            let rect = inspector.convert(control.bounds, from: control)
            XCTAssertTrue(
                inspector.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                "\(identifier) must remain inside a short inspector: \(rect) vs \(inspector.bounds)"
            )
        }
    }

    func testEmptyInspectorCanStillClose() throws {
        let inspector = OperationsLogInspector(frame: NSRect(x: 0, y: 0, width: 700, height: 330))
        var didClose = false
        inspector.onClose = { didClose = true }
        inspector.display(nil)
        let close = try XCTUnwrap(find(inspector, "operations-inspector-close", as: NSButton.self))
        XCTAssertTrue(close.isEnabled)
        close.performClick(nil)
        XCTAssertTrue(didClose)
    }

}
