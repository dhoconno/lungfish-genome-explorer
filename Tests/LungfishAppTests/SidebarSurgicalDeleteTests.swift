// SidebarSurgicalDeleteTests.swift - surgical NSOutlineView row removal on delete
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task 18 (Phase 3, incremental reloads): the sidebar DELETE path removes only the
// deleted rows via `NSOutlineView.removeItems(at:inParent:)` instead of tearing the
// whole tree down with `reloadData()`. These tests pin two things:
//   1. The PURE planner (`surgicalRemovalPlan`) computes the correct (parent, IndexSet)
//      groups against the PRE-mutation model, and correctly signals a fallback (nil)
//      when surgical removal cannot be done safely.
//   2. The integration path actually removes exactly the deleted rows from a populated
//      outline without a full teardown.

import XCTest
@testable import LungfishApp

@MainActor
final class SidebarSurgicalDeleteTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a small in-memory tree:
    ///   root0  (folder "Reads")
    ///     child00 "A"
    ///     child01 "B"
    ///     child02 "C"
    ///   root1  (folder "Results")
    ///     child10 "X"
    ///     child11 "Y"
    ///   root2  "Loose" (top-level document)
    private func makeTree() -> (roots: [SidebarItem], items: [String: SidebarItem]) {
        let child00 = SidebarItem(title: "A", type: .document, url: URL(fileURLWithPath: "/p/Reads/A"))
        let child01 = SidebarItem(title: "B", type: .document, url: URL(fileURLWithPath: "/p/Reads/B"))
        let child02 = SidebarItem(title: "C", type: .document, url: URL(fileURLWithPath: "/p/Reads/C"))
        let root0 = SidebarItem(title: "Reads", type: .folder, children: [child00, child01, child02], url: URL(fileURLWithPath: "/p/Reads"))

        let child10 = SidebarItem(title: "X", type: .document, url: URL(fileURLWithPath: "/p/Results/X"))
        let child11 = SidebarItem(title: "Y", type: .document, url: URL(fileURLWithPath: "/p/Results/Y"))
        let root1 = SidebarItem(title: "Results", type: .folder, children: [child10, child11], url: URL(fileURLWithPath: "/p/Results"))

        let root2 = SidebarItem(title: "Loose", type: .document, url: URL(fileURLWithPath: "/p/Loose"))

        let items = [
            "child00": child00, "child01": child01, "child02": child02, "root0": root0,
            "child10": child10, "child11": child11, "root1": root1,
            "root2": root2,
        ]
        return ([root0, root1, root2], items)
    }

    // MARK: - Pure planner

    func testPlanGroupsSiblingChildrenUnderOneParentAsSingleIndexSet() throws {
        let (roots, items) = makeTree()
        let plan = try XCTUnwrap(
            SidebarViewController.surgicalRemovalPlan(
                for: [items["child00"]!, items["child02"]!],
                rootItems: roots,
                isFiltered: false
            )
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan[0].parent === items["root0"])
        XCTAssertEqual(plan[0].indices, IndexSet([0, 2]))
    }

    func testPlanForRootLevelItemUsesNilParentAndRootIndex() throws {
        let (roots, items) = makeTree()
        let plan = try XCTUnwrap(
            SidebarViewController.surgicalRemovalPlan(
                for: [items["root2"]!],
                rootItems: roots,
                isFiltered: false
            )
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertNil(plan[0].parent)
        XCTAssertEqual(plan[0].indices, IndexSet(integer: 2))
    }

    func testPlanAcrossDifferentParentsProducesOneGroupPerParent() throws {
        let (roots, items) = makeTree()
        let plan = try XCTUnwrap(
            SidebarViewController.surgicalRemovalPlan(
                for: [items["child01"]!, items["child10"]!, items["root2"]!],
                rootItems: roots,
                isFiltered: false
            )
        )
        XCTAssertEqual(plan.count, 3)
        let byParent = Dictionary(uniqueKeysWithValues: plan.map { ($0.parent.map { ObjectIdentifier($0) }, $0.indices) })
        XCTAssertEqual(byParent[ObjectIdentifier(items["root0"]!)], IndexSet(integer: 1))
        XCTAssertEqual(byParent[ObjectIdentifier(items["root1"]!)], IndexSet(integer: 0))
        XCTAssertEqual(byParent[Optional<ObjectIdentifier>.none], IndexSet(integer: 2))
    }

    func testPlanReturnsNilWhenFilterActive() {
        let (roots, items) = makeTree()
        XCTAssertNil(
            SidebarViewController.surgicalRemovalPlan(
                for: [items["child00"]!],
                rootItems: roots,
                isFiltered: true
            )
        )
    }

    func testPlanReturnsNilWhenDeletingParentAndItsDescendant() {
        // Deleting "root0" AND one of its children can't be done surgically without
        // corrupting the outline (removing the parent already removes the child).
        let (roots, items) = makeTree()
        XCTAssertNil(
            SidebarViewController.surgicalRemovalPlan(
                for: [items["root0"]!, items["child01"]!],
                rootItems: roots,
                isFiltered: false
            )
        )
    }

    func testPlanReturnsNilWhenItemNotFoundInTree() {
        let (roots, _) = makeTree()
        let stranger = SidebarItem(title: "Ghost", type: .document, url: URL(fileURLWithPath: "/p/Ghost"))
        XCTAssertNil(
            SidebarViewController.surgicalRemovalPlan(
                for: [stranger],
                rootItems: roots,
                isFiltered: false
            )
        )
    }

    // MARK: - Integration: real outline, exact row removal, no full reload

    func testSurgicalRemovalDropsExactlyDeletedRowsFromOutline() throws {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let (roots, items) = makeTree()
        sidebar.rootItems = roots
        sidebar.reloadData()
        sidebar.outlineView.expandItem(nil, expandChildren: true)

        let rowsBefore = sidebar.outlineView.numberOfRows
        XCTAssertGreaterThan(rowsBefore, 0)

        let didSurgical = sidebar.applySurgicalRemoval(of: [items["child00"]!, items["child02"]!])
        XCTAssertTrue(didSurgical, "Deleting two sibling children should take the surgical path")

        // Exactly two rows removed.
        XCTAssertEqual(sidebar.outlineView.numberOfRows, rowsBefore - 2)
        // Model updated: those children are gone, sibling B remains.
        XCTAssertEqual(items["root0"]!.children.map(\.title), ["B"])
        // Untouched subtrees intact.
        XCTAssertEqual(items["root1"]!.children.count, 2)
    }

    func testSurgicalRemovalReturnsFalseForParentAndDescendant() {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let (roots, items) = makeTree()
        sidebar.rootItems = roots
        sidebar.reloadData()

        XCTAssertFalse(sidebar.applySurgicalRemoval(of: [items["root0"]!, items["child00"]!]))
    }
}
