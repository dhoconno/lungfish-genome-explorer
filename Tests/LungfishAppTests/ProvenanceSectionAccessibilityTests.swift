// ProvenanceSectionAccessibilityTests.swift - Provenance rows keep their own identifiers in the AX tree
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp

/// Hosts the real Provenance section in a window and walks the NSAccessibility
/// tree the way VoiceOver and AX-driven automation do. A SwiftUI accessibility
/// identifier set on a plain container is applied to every descendant, which
/// once made every row in the section answer "provenance-root".
@MainActor
final class ProvenanceSectionAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try await super.tearDown()
    }

    func testLineageRowsExposeTheirOwnIdentifiers() throws {
        let recorded = "minimap2 -a '/tmp/lge-demo-build/projects/Human Mapping.lungfish/Imports/reads.fq'"
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.lineageRuns = [
            ProvenanceLineageRun(
                id: UUID(), title: "lungfish map", subtitle: "lungfish map (development build)",
                steps: [
                    ProvenanceLineageStep(
                        id: UUID(), ordinal: 1, toolName: "minimap2", toolVersion: "v2.31",
                        command: recorded, commandLabel: "minimap2 -a Imports/reads.fq",
                        inputPaths: [], outputPaths: [],
                        exitStatus: 0, wallTimeSeconds: nil, stderr: nil, dependsOn: []
                    ),
                    ProvenanceLineageStep(
                        id: UUID(), ordinal: 2, toolName: "samtools", toolVersion: "v1.22",
                        command: "samtools sort", inputPaths: [], outputPaths: [],
                        exitStatus: 0, wallTimeSeconds: nil, stderr: nil, dependsOn: []
                    ),
                ]
            ),
        ]
        let host = host(ProvenanceSection(viewModel: viewModel))

        waitUntil { AXTree.element(in: host, identifier: "provenance-run-1") != nil }
        let run = try XCTUnwrap(
            AXTree.element(in: host, identifier: "provenance-run-1"),
            "the run row must carry its own identifier; tree:\n" + AXTree.dump(host)
        )
        XCTAssertEqual(AXTree.label(run), "Run 1, lungfish map")

        let roots = AXTree.all(in: host).filter { AXTree.identifier($0) == "provenance-root" }
        XCTAssertEqual(roots.count, 1, "the section container keeps its identifier without leaking it to descendants")
        XCTAssertFalse(AXTree.all(in: host).contains { AXTree.identifier($0) == "provenance-root" && AXTree.label($0)?.hasPrefix("Run ") == true })

        XCTAssertTrue(AXTree.press(run), "the run row must answer AXPress")
        waitUntil { AXTree.element(in: host, identifier: "provenance-run-1-step-1") != nil }
        let step = try XCTUnwrap(AXTree.element(in: host, identifier: "provenance-run-1-step-1"))
        XCTAssertEqual(AXTree.label(step), "Step 1, minimap2")
        XCTAssertNotNil(AXTree.element(in: host, identifier: "provenance-run-1-step-2"))

        // The Command row shows the project-relative form and keeps the
        // recorded command as its accessibility value.
        XCTAssertTrue(AXTree.press(step))
        waitUntil { AXTree.element(in: host, identifier: "provenance-step-command") != nil }
        let command = try XCTUnwrap(AXTree.element(in: host, identifier: "provenance-step-command"))
        XCTAssertEqual(AXTree.value(command), recorded)
    }

    /// Hosts `content` in a window and returns that window, the root of the
    /// tree to walk. SwiftUI builds its accessibility nodes only once an
    /// assistive client is attached, and this app-level attribute is how such
    /// a client announces itself.
    private func host<Content: View>(_ content: Content) -> NSObject {
        NSApplication.shared.accessibilitySetValue(
            true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 720)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

// MARK: - Accessibility tree walking

/// Reads the NSAccessibility tree through the same informal protocol AppKit's
/// accessibility server uses, so SwiftUI's own nodes are included.
@MainActor
private enum AXTree {
    static func children(of element: NSObject) -> [NSObject] {
        let modern = ((element as AnyObject).accessibilityChildren?() ?? nil) ?? []
        if !modern.isEmpty { return modern.compactMap { $0 as? NSObject } }
        return ((element.accessibilityAttributeValue(.children) as? [Any]) ?? []).compactMap { $0 as? NSObject }
    }

    static func all(in root: NSObject) -> [NSObject] {
        [root] + children(of: root).flatMap { all(in: $0) }
    }

    static func element(in root: NSObject, identifier: String) -> NSObject? {
        all(in: root).first { self.identifier($0) == identifier }
    }

    static func identifier(_ element: NSObject) -> String? {
        (element as AnyObject).accessibilityIdentifier?() ?? nil
    }

    static func label(_ element: NSObject) -> String? {
        (element as AnyObject).accessibilityLabel?() ?? nil
    }

    /// The value through the modern protocol, which is what VoiceOver and the
    /// AX API read. The legacy `.value` attribute of a SwiftUI text node
    /// echoes its text instead of a value set with `.accessibilityValue`.
    static func value(_ element: NSObject) -> String? {
        element.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? String
            ?? element.accessibilityAttributeValue(.value) as? String
    }

    static func dump(_ root: NSObject, depth: Int = 0) -> String {
        let role = (element(root) as NSAccessibility.Role?)?.rawValue ?? "?"
        let line = String(repeating: "  ", count: depth) + "\(role) | \(label(root) ?? "") | \(identifier(root) ?? "")"
        return ([line] + children(of: root).map { dump($0, depth: depth + 1) }).joined(separator: "\n")
    }

    private static func element(_ element: NSObject) -> NSAccessibility.Role? {
        (element as AnyObject).accessibilityRole?() ?? nil
    }

    static func press(_ element: NSObject) -> Bool {
        (element as AnyObject).accessibilityPerformPress?() ?? false
    }
}
