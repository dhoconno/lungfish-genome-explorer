import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// A click in the genotype matrix or in Haplotype Calls gives that view the
/// keyboard focus.
///
/// Selection > Genotype Call and Selection > Genotype Sample are nil-target
/// menu items, so AppKit enables them only when the responder chain from the
/// window's first responder reaches the matrix or the result controller. Each
/// test starts with the focus in a text field that stands in for the sidebar,
/// where it sits after the analyst picks the result in the project.
@MainActor
final class GenotypeReviewMenuClickFocusTests: GenotypeResultViewportTestCase {
    private struct MatrixFixture {
        let controller: GenotypeResultViewController
        let matrix: GenotypeComparisonMatrixView
        let root: URL
    }

    private func makeMatrixFixture() throws -> MatrixFixture {
        let root = try TestTempDirectory.make(prefix: "MatrixClickFocus")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8),
                makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 7),
            ]
        ))
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        matrix.layoutSubtreeIfNeeded()
        return MatrixFixture(controller: controller, matrix: matrix, root: root)
    }

    /// Puts `content` in a window under a sidebar stand-in that has the focus.
    private func hostWithSidebarFocus(_ content: NSView, size: NSSize) -> NSWindow {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + 40))
        let sidebar = NSTextField(frame: NSRect(x: 0, y: size.height + 8, width: 200, height: 24))
        container.addSubview(sidebar)
        container.addSubview(content)
        if content.translatesAutoresizingMaskIntoConstraints {
            content.frame = NSRect(origin: .zero, size: size)
        } else {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                content.heightAnchor.constraint(equalToConstant: size.height),
            ])
        }
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(sidebar), "the sidebar stand-in takes the focus")
        return window
    }

    /// The object a nil-target menu item reaches, found by walking the
    /// responder chain from the window's first responder as AppKit does.
    private func responderChainTarget(for action: Selector, in window: NSWindow) -> AnyObject? {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    private func subviewTree(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + subviewTree(of: $0) }
    }

    /// Sends a left mouse down to the centre of the cell of `genotype` and
    /// `sample`, the event a real click delivers to the matrix table, and
    /// returns the table that received it.
    private func clickCell(
        genotype: String,
        sample: String,
        in matrix: GenotypeComparisonMatrixView
    ) throws -> NSTableView {
        let columnID = NSUserInterfaceItemIdentifier(try XCTUnwrap(matrix.testingSortKey(forSample: sample)))
        let table = try XCTUnwrap(
            subviewTree(of: matrix).compactMap { $0 as? NSTableView }.first { $0.column(withIdentifier: columnID) >= 0 },
            "no matrix table shows \(sample)"
        )
        let row = try XCTUnwrap(matrix.testingVisibleGenotypes.firstIndex(of: genotype))
        let frame = table.frameOfCell(atColumn: table.column(withIdentifier: columnID), row: row)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: table.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        table.mouseDown(with: event)
        return table
    }

    /// Sends a left mouse down and up at `windowPoint` through the window, the
    /// events a real click delivers, so gesture recognizers see the click.
    private func sendClick(at windowPoint: NSPoint, in window: NSWindow) throws {
        let start = ProcessInfo.processInfo.systemUptime
        for (type, delay) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.02)] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: start + delay,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )))
        }
    }

    private func selectedCells(_ matrix: GenotypeComparisonMatrixView) -> [String] {
        matrix.testingSelectedMatrixTargets.map { target in
            switch target {
            case let .cell(_, genotype, sample, _): return "\(genotype) \(sample)"
            case let .row(_, genotype, _): return "row \(genotype)"
            case let .column(sample): return "column \(sample)"
            }
        }
    }

    func testClickingAMatrixCellFocusesTheMatrixAndEnablesTheGenotypeCallItems() throws {
        let fixture = try makeMatrixFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let window = hostWithSidebarFocus(fixture.matrix, size: NSSize(width: 900, height: 500))
        defer { window.orderOut(nil) }

        let table = try clickCell(genotype: "01_Mafa_A1", sample: "AnimalA", in: fixture.matrix)

        XCTAssertEqual(selectedCells(fixture.matrix), ["01_Mafa_A1 AnimalA"])
        XCTAssertTrue(window.firstResponder === table, "the clicked matrix table takes the keyboard focus")
        XCTAssertTrue(fixture.matrix.ownsKeyboardFocus)
        let item = NSMenuItem(
            title: "Mark False Positive",
            action: #selector(GenotypeMatrixReviewMenuActions.markSelectionFalsePositive(_:)),
            keyEquivalent: "p"
        )
        item.keyEquivalentModifierMask = [.command, .option]
        XCTAssertTrue(
            responderChainTarget(for: try XCTUnwrap(item.action), in: window) === fixture.matrix,
            "Selection > Genotype Call reaches the matrix"
        )
        XCTAssertTrue(fixture.matrix.validateMenuItem(item), "Mark False Positive is enabled")
    }

    func testDownArrowAfterAMatrixCellClickMovesTheSelectionDownOneRow() throws {
        let fixture = try makeMatrixFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let window = hostWithSidebarFocus(fixture.matrix, size: NSSize(width: 900, height: 500))
        defer { window.orderOut(nil) }
        let genotypes = fixture.matrix.testingVisibleGenotypes
        XCTAssertEqual(genotypes.count, 2)
        _ = try clickCell(genotype: genotypes[0], sample: "AnimalA", in: fixture.matrix)

        // U+F701 is NSDownArrowFunctionKey and key code 125 the down arrow.
        let downArrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false,
            keyCode: 125
        ))
        window.sendEvent(downArrow)

        XCTAssertEqual(selectedCells(fixture.matrix), ["\(genotypes[1]) AnimalA"])
    }

    func testClickingAHaplotypeCallFocusesTheCallsAndEnablesTheGenotypeSampleItems() throws {
        let root = try TestTempDirectory.make(prefix: "HaplotypeCallClickFocus")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        ))
        let window = hostWithSidebarFocus(controller.view, size: NSSize(width: 1_000, height: 700))
        defer { window.orderOut(nil) }
        XCTAssertEqual(controller.testingSummaryViewMode, .outline, "the result opens in Haplotype Calls")
        let outline = try XCTUnwrap(subviewTree(of: controller.view).compactMap { $0 as? GenotypeOutlineView }.first)
        outline.testingForceRowMaterialization()
        outline.layoutSubtreeIfNeeded()
        let tape = try XCTUnwrap(
            subviewTree(of: outline).compactMap { $0 as? GenotypeHaplotypeTapeView }
                .first { $0.sampleAccessibilityLabel == "AnimalA" },
            "AnimalA has no haplotype tape"
        )
        XCTAssertGreaterThan(tape.bounds.width, 0)

        // A click on the H1 call of the tape's only locus, sent through the
        // window so the tape's click recognizer handles it as it handles a
        // real click. The tape is flipped, so H1 is the top half.
        try sendClick(at: tape.convert(NSPoint(x: tape.bounds.midX, y: tape.bounds.height / 4), to: nil), in: window)
        AccessibilityTreeProbe.waitUntil { controller.testingOutlineSelectedSample == "AnimalA" }

        XCTAssertEqual(controller.testingOutlineSelectedSample, "AnimalA")
        XCTAssertEqual(controller.testingOutlineSelectedLocus, "MHC-A")
        XCTAssertEqual(controller.reviewCommandTargetSample, "AnimalA")
        for selector in GenotypeResultViewController.reviewCommandSelectors {
            XCTAssertTrue(
                responderChainTarget(for: selector, in: window) === controller,
                "Selection > Genotype Sample reaches the controller for \(NSStringFromSelector(selector))"
            )
        }
        let item = NSMenuItem(
            title: "Mark Sample Reviewed",
            action: #selector(GenotypeResultViewController.markSelectedSampleReviewed(_:)),
            keyEquivalent: "r"
        )
        XCTAssertTrue(controller.validateMenuItem(item), "Mark Sample Reviewed is enabled")
    }
}
