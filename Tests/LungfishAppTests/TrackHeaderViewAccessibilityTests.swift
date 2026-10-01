// TrackHeaderViewAccessibilityTests.swift - Track disclosure triangles without a mouse
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// The track header's disclosure triangles are reachable as accessibility
/// disclosure elements (label, expanded value, press) and from the keyboard
/// (Up and Down move the focus ring, Space and Return toggle).
@MainActor
final class TrackHeaderViewAccessibilityTests: XCTestCase {

    /// Toggles the track like the viewer does: flips the flag and hands the
    /// header the new stacked list.
    private final class HeaderDelegateSpy: TrackHeaderViewDelegate {
        var toggled: [Int] = []
        var sequences: [StackedSequenceInfo] = []
        func trackHeaderView(_ headerView: TrackHeaderView, didToggleAnnotationsForTrackAt index: Int) {
            toggled.append(index)
            sequences[index].showAnnotations.toggle()
            headerView.setStackedSequences(sequences)
        }
    }

    private func makeHeader() throws -> (TrackHeaderView, HeaderDelegateSpy, NSWindow) {
        _ = NSApplication.shared
        func track(_ name: String, index: Int, annotated: Bool) throws -> StackedSequenceInfo {
            StackedSequenceInfo(
                sequence: try Sequence(name: name, alphabet: .dna, bases: "ACGTACGT"),
                trackIndex: index,
                yOffset: 20 + CGFloat(index) * 40,
                sequenceHeight: 28,
                annotationHeight: 30,
                annotations: annotated ? [SequenceAnnotation(type: .gene, name: "\(name)-gene", chromosome: name, start: 1, end: 5)] : [],
                showAnnotations: false
            )
        }
        let spy = HeaderDelegateSpy()
        spy.sequences = [
            try track("ref", index: 0, annotated: true),
            try track("plain", index: 1, annotated: false),
            try track("query", index: 2, annotated: true),
        ]
        let header = TrackHeaderView(frame: NSRect(x: 0, y: 0, width: 160, height: 200))
        header.delegate = spy
        header.setStackedSequences(spy.sequences)
        let window = NSWindow(contentRect: header.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = header
        return (header, spy, window)
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: code
        ))
    }

    func testOneDisclosureElementPerAnnotatedTrackWithLabelValueAndPress() throws {
        let (header, spy, window) = try makeHeader()
        defer { window.close() }

        let children = try XCTUnwrap(header.accessibilityChildren() as? [TrackDisclosureElement])
        XCTAssertEqual(children.count, 2, "the track without annotations has no triangle")
        XCTAssertEqual(children.map { $0.accessibilityLabel() }, ["ref", "query"])
        XCTAssertEqual(children.map { $0.accessibilityRole() }, [.disclosureTriangle, .disclosureTriangle])
        XCTAssertEqual(children.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [0, 0])
        XCTAssertEqual(children[1].accessibilityFrameInParentSpace(), header.rowRect(forTrackAt: 2))
        XCTAssertEqual(header.accessibilityRole(), .group)

        XCTAssertTrue(children[1].accessibilityPerformPress())
        XCTAssertEqual(spy.toggled, [2])
        let after = try XCTUnwrap(header.accessibilityChildren() as? [TrackDisclosureElement])
        XCTAssertEqual(after.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [0, 1], "the value follows the toggle")
    }

    func testKeyboardFocusMovesBetweenAnnotatedTracksAndSpaceToggles() throws {
        let (header, spy, window) = try makeHeader()
        defer { window.close() }
        XCTAssertTrue(header.acceptsFirstResponder)
        XCTAssertTrue(window.makeFirstResponder(header))
        XCTAssertEqual(header.focusedTrackIndex, 0, "focus starts on the first annotated track")
        XCTAssertFalse(header.focusRingMaskBounds.isEmpty, "the focus ring is drawn while focused")

        header.keyDown(with: try key(125)) // Down
        XCTAssertEqual(header.focusedTrackIndex, 2, "the track without annotations is skipped")
        header.keyDown(with: try key(125))
        XCTAssertEqual(header.focusedTrackIndex, 2, "no track below")
        header.keyDown(with: try key(49)) // Space
        XCTAssertEqual(spy.toggled, [2])
        header.keyDown(with: try key(36)) // Return
        XCTAssertEqual(spy.toggled, [2, 2])
        header.keyDown(with: try key(126)) // Up
        XCTAssertEqual(header.focusedTrackIndex, 0)

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(header.focusRingMaskBounds.isEmpty, "no ring without focus")
    }

    func testHeaderWithoutAnnotatedTracksIsNotFocusableAndHasNoChildren() throws {
        _ = NSApplication.shared
        let header = TrackHeaderView(frame: NSRect(x: 0, y: 0, width: 160, height: 200))
        header.setTrackNames(["ref"])
        XCTAssertFalse(header.acceptsFirstResponder)
        XCTAssertEqual((header.accessibilityChildren() as? [Any])?.count ?? 0, 0)
        XCTAssertFalse(header.toggleAnnotations(forTrackAt: 0))
    }
}
