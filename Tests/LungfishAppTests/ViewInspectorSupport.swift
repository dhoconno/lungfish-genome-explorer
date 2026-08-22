// ViewInspectorSupport.swift - Shared ViewInspector setup for LungfishAppTests
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// F3 (test-suite-optimization): introduces ViewInspector as a test-only
// dependency so SwiftUI dialog-layer assertions can inspect the actual
// rendered view hierarchy instead of grepping production .swift source text
// for substrings (see docs/reports/2026-08-21-test-suite-review.md §3).
//
// Intentionally thin: add further helpers here only once a third converted
// test needs the same construction boilerplate.

import ViewInspector

public extension InspectableView where View == ViewType.VStack {
    /// Finds the single TextField whose placeholder/label text equals `text`,
    /// then returns *its* immediate containing VStack — not an ancestor VStack
    /// that happens to also contain it transitively.
    ///
    /// `find(ViewType.VStack.self, where:)` matches top-down, so a naive
    /// "does this VStack contain a TextField/Text matching X" predicate matches
    /// the first (usually outermost) container satisfying it, not the innermost
    /// one that actually owns the modifier under test. Requiring the match to be
    /// the group's *only* TextField (or its direct first child, for headings)
    /// disambiguates nested `VStack`s that wrap one labeled control each.
    static func lungfishSoleTextFieldGroup(
        in root: InspectableView<ViewType.ClassifiedView>,
        placeholderOrLabel text: String
    ) throws -> InspectableView<ViewType.VStack> {
        try root.find(ViewType.VStack.self, where: { group in
            let fields = group.findAll(ViewType.TextField.self)
            guard fields.count == 1 else { return false }
            return (try? fields[0].labelView().text().string()) == text
        })
    }
}

public extension InspectableView where View == ViewType.ClassifiedView {
    /// HStack-flavored counterpart to `lungfishSoleTextFieldGroup` above.
    ///
    /// `labeledTextField`/`labeledCompactTextField` in FASTQOperationToolPanes.swift
    /// wrap their `Text(title)` label and `TextField("", text:)` control in an
    /// `HStack` (not a `VStack`), and give the `TextField` itself an empty
    /// placeholder/label (`TextField("", text:)`) -- so the label text lives on
    /// a sibling `Text`, not the field's own label. This finds the sole TextField
    /// whose containing HStack also has a sibling `Text` equal to `text`, then
    /// returns *that* HStack (not an ancestor also containing it transitively).
    func lungfishSoleTextFieldHStack(placeholderOrLabel text: String) throws -> InspectableView<ViewType.HStack> {
        try find(ViewType.HStack.self, where: { group in
            let fields = group.findAll(ViewType.TextField.self)
            guard fields.count == 1 else { return false }
            let texts = group.findAll(ViewType.Text.self)
            return texts.contains { (try? $0.string()) == text }
        })
    }
}
