// ViewSwitchFixtures.swift - The fixture of each view-switch kind, which the matrix and the view state tests share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved out of ViewSwitchMatrixTests so ViewSwitchViewStateTests builds each kind the same way (VS Q1).

import XCTest
@testable import LungfishApp
import LungfishTestSupport

/// One kind's fixture: the folder it is built in, its sidebar row and the reading of the kind alone.
struct ViewSwitchFixture {
    let kind: ViewSwitchKind
    let root: URL
    let item: SidebarItem
    let alone: ViewSwitchReading
}

@MainActor
enum ViewSwitchFixtures {
    /// Builds the representative row of every kind under its own folder.
    static func build(in root: URL) async throws -> [ViewSwitchFixture] {
        var fixtures: [ViewSwitchFixture] = []
        for kind in ViewSwitchKinds.all {
            fixtures.append(try await build(kind, in: root))
        }
        return fixtures
    }

    /// Builds the representative row of `kind` under its own folder in `root`.
    static func build(_ kind: ViewSwitchKind, in root: URL) async throws -> ViewSwitchFixture {
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind), "\(kind.name) names no routing row \(kind.row)")
        let kindRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent(kind.folder, isDirectory: true))
        let built = try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot)))
        XCTAssertEqual(ViewSwitchKinds.outcome(of: built.expected), kind.outcome, "\(kind.name): its row \(kind.row) opens another kind")
        XCTAssertLessThanOrEqual(built.expected.viewports.count, 1, "\(kind.name) alone installs more than one viewer")
        return ViewSwitchFixture(kind: kind, root: kindRoot, item: built.item, alone: .alone(built.expected, kind: kind))
    }

    /// The kind of `ViewSwitchKinds.all` named `name`.
    static func kind(named name: String) throws -> ViewSwitchKind {
        try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == name }, "no view-switch kind is named \(name)")
    }
}
