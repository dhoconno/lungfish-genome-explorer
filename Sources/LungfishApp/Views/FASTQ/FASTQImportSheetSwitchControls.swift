// FASTQImportSheetSwitchControls.swift - The checkboxes of a recipe's switches in the Import FASTQ sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

/// One checkbox for each switch of the chosen recipe, under the recipe picker (ruling BIO-PRESET P3, UX review points 2
/// and 7). Each starts at the chosen preset's value and goes back to it when the picker changes to another option.
/// ``changedValues`` holds only a checkbox that differs from the preset. The sheet passes those to the CLI as the CLI's
/// own options (`--no-remove-duplicates`), so the Operations row's command equals the argv that ran
/// (`docs/contracts/CLI-EQUIVALENCE.md`).
///
/// The stack takes no height while no checkbox shows, so the sheet for a recipe without switches lays out as it did
/// before. Each checkbox is a standard checkbox. Tab reaches it with Full Keyboard Access and Space toggles it, and it
/// has an accessibility label (the switch's label), an identifier and a help text that names the CLI option a change adds.
@MainActor
final class FASTQImportSheetSwitchControls: NSStackView {

    private struct Row {
        let option: FASTQImportSheetSwitch
        let checkbox: NSButton
    }

    private var rows: [Row] = []
    private var shownOptionID: String?
    private var topConstraint: NSLayoutConstraint?
    private var collapsedHeight: NSLayoutConstraint?

    /// Called after the user changes a checkbox, so the sheet can refresh the Workflow line.
    var onChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityLabel("Recipe settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Adds the stack to `view` under `label` and in line with `popup`.
    func install(in view: NSView, below label: NSView, alignedWith popup: NSView) {
        view.addSubview(self)
        let top = topAnchor.constraint(equalTo: label.bottomAnchor)
        let collapsed = heightAnchor.constraint(equalToConstant: 0)
        topConstraint = top
        collapsedHeight = collapsed
        NSLayoutConstraint.activate([top, leadingAnchor.constraint(equalTo: popup.leadingAnchor), collapsed])
    }

    /// Shows the checkboxes of `option` when `visible`, and none otherwise. The checkboxes go back to the preset's
    /// values when `option` is not the one shown last, and keep the user's choices otherwise, so turning the recipe
    /// off and on again changes nothing.
    func display(_ option: FASTQImportSheetRecipeOption?, visible: Bool) {
        if option?.id != shownOptionID { rebuild(for: option) }
        let showing = visible && !rows.isEmpty
        isHidden = !showing
        for row in rows { row.checkbox.isHidden = !showing }
        topConstraint?.constant = showing ? 6 : 0
        collapsedHeight?.isActive = !showing
        // The checkboxes appear after the window is on screen, and AppKit builds a window's key view loop once, so a
        // checkbox made or shown later can be left out of Tab order unless the loop is recalculated.
        window?.recalculateKeyViewLoop()
    }

    /// Every switch's value now, by switch id.
    var values: [String: Bool] {
        var result: [String: Bool] = [:]
        for row in rows { result[row.option.id] = row.checkbox.state == .on }
        return result
    }

    /// The switches whose checkbox differs from the preset's value, by switch id. Empty while every checkbox is at the
    /// preset's value.
    var changedValues: [String: Bool] {
        var result: [String: Bool] = [:]
        for row in rows where (row.checkbox.state == .on) != row.option.presetValue {
            result[row.option.id] = row.checkbox.state == .on
        }
        return result
    }

    private func rebuild(for option: FASTQImportSheetRecipeOption?) {
        for row in rows {
            removeArrangedSubview(row.checkbox)
            row.checkbox.removeFromSuperview()
        }
        rows = (option?.switches ?? []).map { gate in
            let checkbox = NSButton(checkboxWithTitle: gate.label, target: self, action: #selector(toggled(_:)))
            checkbox.state = gate.presetValue ? .on : .off
            checkbox.font = .systemFont(ofSize: 12)
            let optionName = RecipeSwitch.optionName(for: gate.id)
            let change = gate.presetValue ? "--no-\(optionName)" : "--\(optionName)"
            let help = "The chosen recipe sets this \(gate.presetValue ? "on" : "off"). Changing it adds \(change) to the import command."
            checkbox.toolTip = help
            checkbox.setAccessibilityLabel(gate.label)
            checkbox.setAccessibilityHelp(help)
            checkbox.setAccessibilityIdentifier("fastq-import-switch-\(gate.id)")
            addArrangedSubview(checkbox)
            return Row(option: gate, checkbox: checkbox)
        }
        shownOptionID = option?.id
    }

    @objc private func toggled(_ sender: NSButton) {
        onChange?()
    }
}
