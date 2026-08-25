// NumericSliderField.swift - Slider paired with a directly editable numeric field
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Resolves typed text into a slider-legal value.
///
/// Kept separate from the view so the clamping and rejection rules are
/// directly testable: a typed value is the user's explicit intent, so it is
/// clamped into range rather than discarded, but text that names no number at
/// all must leave the current value untouched.
public enum NumericSliderFieldParser {
    /// Snaps `value` to the nearest `step` within `bounds`.
    ///
    /// Rounding happens relative to the lower bound so a non-integral step
    /// (or a lower bound that is not a multiple of the step) still lands on a
    /// reachable slider position.
    public static func snap(
        _ value: Double,
        bounds: ClosedRange<Double>,
        step: Double
    ) -> Double {
        let clamped = min(max(value, bounds.lowerBound), bounds.upperBound)
        guard step > 0 else { return clamped }
        let steps = ((clamped - bounds.lowerBound) / step).rounded()
        return min(max(bounds.lowerBound + steps * step, bounds.lowerBound), bounds.upperBound)
    }

    /// Parses `text` into a snapped, in-range value, or `nil` when the text
    /// carries no number and the existing value must be preserved.
    public static func parse(
        _ text: String,
        bounds: ClosedRange<Double>,
        step: Double
    ) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Tolerate decorated input ("50%", "1,000") so a value copied from the
        // adjacent read-out is accepted as typed.
        trimmed = trimmed.replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else { return nil }
        return snap(parsed, bounds: bounds, step: step)
    }
}

/// A labelled slider whose current value is also a text field, so a precise
/// value can be typed instead of dragged.
///
/// Dragging the slider and typing in the field write the same binding; the
/// field commits on Return or focus loss and reverts to the bound value when
/// the text names no number.
public struct NumericSliderField: View {
    private let title: String
    private let bounds: ClosedRange<Double>
    private let step: Double
    private let suffix: String
    private let format: (Double) -> String
    private let onEditingChanged: (Bool) -> Void
    private let titleFont: Font?
    @Binding private var value: Double

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    public init(
        _ title: String,
        value: Binding<Double>,
        in bounds: ClosedRange<Double>,
        step: Double = 1,
        suffix: String = "",
        format: @escaping (Double) -> String = { String(Int($0)) },
        titleFont: Font? = nil,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title
        self._value = value
        self.bounds = bounds
        self.step = step
        self.suffix = suffix
        self.format = format
        self.titleFont = titleFont
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(titleFont)
                Spacer()
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: fieldWidth)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .accessibilityLabel(title)
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(titleFont)
                        .foregroundStyle(.secondary)
                }
            }
            Slider(value: $value, in: bounds, step: step, onEditingChanged: onEditingChanged)
                .accessibilityLabel(title)
        }
        .onAppear { text = format(value) }
        // The binding is also written by the slider and by evidence reloads;
        // mirror those into the field except while it is being typed in.
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            text = format(newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    /// Wider fields for larger ranges so six-figure values stay readable.
    private var fieldWidth: CGFloat {
        let magnitude = max(abs(bounds.lowerBound), abs(bounds.upperBound))
        return magnitude >= 10_000 ? 88 : 64
    }

    private func commit() {
        guard let resolved = NumericSliderFieldParser.parse(text, bounds: bounds, step: step) else {
            text = format(value)
            return
        }
        if resolved != value {
            value = resolved
            // A typed commit is a discrete edit, not a drag: report it as a
            // completed interaction so callers persist it like a slider release.
            onEditingChanged(false)
        }
        text = format(resolved)
    }
}

/// A single-row variant: `label  [====slider====]  [field]`.
///
/// Used where the surrounding form already supplies its own row label layout
/// and a stacked title would duplicate it.
public struct InlineNumericSliderField: View {
    private let label: String?
    private let bounds: ClosedRange<Double>
    private let step: Double
    private let suffix: String
    private let format: (Double) -> String
    private let accessibilityTitle: String
    private let sliderIdentifier: String?
    private let labelWidth: CGFloat?
    private let sliderMaxWidth: CGFloat?
    private let labelFont: Font?
    @Binding private var value: Double

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    public init(
        label: String? = nil,
        accessibilityTitle: String,
        value: Binding<Double>,
        in bounds: ClosedRange<Double>,
        step: Double = 1,
        suffix: String = "",
        format: @escaping (Double) -> String = { String(Int($0)) },
        sliderIdentifier: String? = nil,
        labelWidth: CGFloat? = nil,
        sliderMaxWidth: CGFloat? = nil,
        labelFont: Font? = nil
    ) {
        self.label = label
        self.accessibilityTitle = accessibilityTitle
        self.sliderIdentifier = sliderIdentifier
        self.labelWidth = labelWidth
        self.sliderMaxWidth = sliderMaxWidth
        self.labelFont = labelFont
        self._value = value
        self.bounds = bounds
        self.step = step
        self.suffix = suffix
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let label {
                Text(label)
                    .font(labelFont)
                    .frame(width: labelWidth, alignment: labelWidth == nil ? .leading : .trailing)
            }
            Slider(value: $value, in: bounds, step: step)
                .frame(maxWidth: sliderMaxWidth ?? .infinity)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityIdentifier(sliderIdentifier ?? "")
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .focused($isFocused)
                .onSubmit(commit)
                .accessibilityLabel(accessibilityTitle)
            if !suffix.isEmpty {
                Text(suffix).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            text = format(newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        guard let resolved = NumericSliderFieldParser.parse(text, bounds: bounds, step: step) else {
            text = format(value)
            return
        }
        value = resolved
        text = format(resolved)
    }
}
