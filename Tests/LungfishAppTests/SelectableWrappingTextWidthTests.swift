// SelectableWrappingTextWidthTests.swift - Selectable wrapping text never lays out wider than the view it fills
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

/// Walk finding F1. The Raw JSON pane wrapped a long line at a width wider than the Inspector and
/// cut off its end. SwiftUI measures a flexible view at more than one width while it negotiates a
/// layout, with a zero width, an infinite one and sometimes a wider one than it assigns. The text
/// view set its text container to each width it measured and never set it back, so the container
/// stayed wider than the view and a line wrapped at the wrong place.
///
/// Each case lays a 2,000-character line with no space in it at the Inspector's narrowest and
/// widest widths, and requires that the text never lays out wider than the width it is given.
@MainActor
final class SelectableWrappingTextWidthTests: XCTestCase {
    /// `inspectorMinWidth` and `inspectorMaxWidth` of `MainSplitViewController`.
    private let inspectorWidths: [CGFloat] = [260, 720]
    private let unbrokenLine = String(repeating: "a1b2c3d4e5", count: 200)

    // MARK: - Harness

    private func mount(width: CGFloat, scrolling: Bool = false) throws -> (host: NSHostingView<AnyView>, textView: IntrinsicTextView) {
        let text = SelectableWrappingText(
            unbrokenLine,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            accessibilityIdentifier: "width-test-text"
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        let column = VStack(alignment: .leading, spacing: 12) {
            Text("Raw JSON")
            text
            Text("After")
        }
        let root: AnyView = scrolling ? AnyView(ScrollView { column }) : AnyView(column)

        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        addTeardownBlock { window.close() }
        settle(host)
        let textView = try XCTUnwrap(descendants(of: host).compactMap { $0 as? IntrinsicTextView }.first)
        return (host, textView)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The text lays out no wider than `width`: its container is `width` wide, the lines it wraps
    /// fit in it, and the view itself is no wider.
    private func assertNoGrowth(
        _ textView: IntrinsicTextView,
        width: CGFloat,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let container = try XCTUnwrap(textView.textContainer, file: file, line: line)
        let layoutManager = try XCTUnwrap(textView.layoutManager, file: file, line: line)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        XCTAssertEqual(
            container.containerSize.width, width, accuracy: 0.5,
            "\(context): the container is as wide as the view.", file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            used.width, width + 0.5,
            "\(context): the wrapped text fits the view's width.", file: file, line: line
        )
        XCTAssertEqual(
            textView.frame.width, width, accuracy: 0.5,
            "\(context): the view does not grow past its width.", file: file, line: line
        )
        XCTAssertGreaterThan(
            used.height, 2 * (textView.font?.boundingRectForFont.height ?? 10),
            "\(context): a line with no space still wraps.", file: file, line: line
        )
    }

    // MARK: - Laid out by SwiftUI

    func testAnUnbrokenLineWrapsAtTheViewsWidthAtTheNarrowestAndWidestInspector() throws {
        for width in inspectorWidths {
            for scrolling in [false, true] {
                let mounted = try mount(width: width, scrolling: scrolling)
                try assertNoGrowth(mounted.textView, width: width, "\(Int(width)) pt, scrolling \(scrolling)")
            }
        }
    }

    // MARK: - The measurements SwiftUI makes

    /// A measurement at a width other than the view's own answers the height the text needs there, which
    /// is more than at the view's width for a narrower one and less for a wider one, and it leaves the
    /// view's frame alone because SwiftUI sizes the view.
    func testAMeasurementAtAnotherWidthLeavesTheTextWrappedAtTheViewsWidth() throws {
        for width in inspectorWidths {
            let mounted = try mount(width: width)
            let textView = mounted.textView
            let heightAtWidth = try XCTUnwrap(textView.fittingSize(forProposedWidth: width)).height
            let frame = textView.frame
            for probe in [width * 4, width / 2, width * 1.5, width] {
                let size = try XCTUnwrap(textView.fittingSize(forProposedWidth: probe))
                XCTAssertEqual(size.width, probe, "a measurement at a finite width is answered at that width")
                XCTAssertGreaterThan(size.height, 0, "\(Int(probe)) pt in a \(Int(width)) pt view answers a height")
                if probe < width {
                    XCTAssertGreaterThan(size.height, heightAtWidth, "\(Int(probe)) pt wraps onto more lines than \(Int(width)) pt")
                } else if probe > width {
                    XCTAssertLessThan(size.height, heightAtWidth, "\(Int(probe)) pt wraps onto fewer lines than \(Int(width)) pt")
                } else {
                    XCTAssertEqual(size.height, heightAtWidth, "the view's own width answers the same height again")
                }
                XCTAssertEqual(textView.frame, frame, "measuring at \(Int(probe)) pt never resizes the \(Int(width)) pt view")
                try assertNoGrowth(textView, width: width, "after measuring at \(Int(probe)) pt in a \(Int(width)) pt view")
            }
        }
    }

    func testAnInfiniteOrMissingWidthMeansTheCurrentWidth() throws {
        for width in inspectorWidths {
            let mounted = try mount(width: width)
            let textView = mounted.textView
            let current = try XCTUnwrap(textView.fittingSize(forProposedWidth: width))

            for proposed in [CGFloat.infinity, nil] {
                let size = try XCTUnwrap(
                    textView.fittingSize(forProposedWidth: proposed),
                    "\(String(describing: proposed)) answers with the current width"
                )
                XCTAssertEqual(size.width, width, "an unbounded proposal is answered at the view's width")
                XCTAssertTrue(size.width.isFinite)
                XCTAssertEqual(size.height, current.height, "the height is the one for the current width")
                try assertNoGrowth(textView, width: width, "after measuring at \(String(describing: proposed)) in a \(Int(width)) pt view")
            }
            XCTAssertNil(textView.fittingSize(forProposedWidth: 0), "no width to measure at")
        }
    }

    func testTheLastMeasurementBeforeALayoutPassCannotLeaveTheContainerWide() throws {
        for width in inspectorWidths {
            let mounted = try mount(width: width)
            let textView = mounted.textView

            _ = textView.fittingSize(forProposedWidth: width)
            _ = textView.fittingSize(forProposedWidth: .infinity)
            _ = textView.fittingHeight(for: width * 3)
            textView.layout()
            settle(mounted.host)

            try assertNoGrowth(textView, width: width, "\(Int(width)) pt after a final wide measurement and a layout pass")
        }
    }

    func testTheIntrinsicHeightFollowsTheViewsWidth() throws {
        let narrow = try mount(width: 260).textView
        let wide = try mount(width: 720).textView

        XCTAssertGreaterThan(
            narrow.intrinsicContentSize.height, wide.intrinsicContentSize.height,
            "A narrower view wraps the line onto more lines."
        )
        XCTAssertEqual(narrow.intrinsicContentSize.width, NSView.noIntrinsicMetric)
    }
}
