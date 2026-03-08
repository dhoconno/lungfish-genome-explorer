// GeneralSettingsTab.swift - General preferences tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// General preferences: zoom, undo, VCF import, temp file retention.
struct GeneralSettingsTab: View {

    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Viewer") {
                Stepper(
                    "Default zoom window: \(settings.defaultZoomWindow.formatted()) bp",
                    value: $settings.defaultZoomWindow,
                    in: 1_000...1_000_000,
                    step: 1_000
                )
                HStack {
                    Text("Tooltip delay:")
                    Slider(value: $settings.tooltipDelay, in: 0...1.0, step: 0.05)
                    Text(String(format: "%.2fs", settings.tooltipDelay))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Editing") {
                Stepper(
                    "Max undo levels: \(settings.maxUndoLevels)",
                    value: $settings.maxUndoLevels,
                    in: 10...1_000,
                    step: 10
                )
            }

            Section("VCF Import") {
                Picker("Import profile:", selection: $settings.vcfImportProfile) {
                    Text("Auto").tag("auto")
                    Text("Fast").tag("fast")
                    Text("Low Memory").tag("lowMemory")
                }
                .pickerStyle(.segmented)
                Text("Auto balances speed and memory. Fast uses more RAM for large files. Low Memory streams in chunks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                Stepper(
                    "Temp file retention: \(settings.tempFileRetentionHours) hours",
                    value: $settings.tempFileRetentionHours,
                    in: 1...168,
                    step: 1
                )
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settings.resetSection(.general)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.defaultZoomWindow) { _, _ in settings.save() }
        .onChange(of: settings.tooltipDelay) { _, _ in settings.save() }
        .onChange(of: settings.maxUndoLevels) { _, _ in settings.save() }
        .onChange(of: settings.vcfImportProfile) { _, _ in settings.save() }
        .onChange(of: settings.tempFileRetentionHours) { _, _ in settings.save() }
    }
}
