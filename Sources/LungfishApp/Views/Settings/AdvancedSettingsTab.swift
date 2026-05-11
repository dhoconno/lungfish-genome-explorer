// AdvancedSettingsTab.swift - Advanced and experimental preferences
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Advanced preferences for work-in-progress app surfaces.
struct AdvancedSettingsTab: View {

    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Experimental Features") {
                Toggle("Show Experimental Features", isOn: $settings.experimentalFeaturesEnabled)
                    .accessibilityIdentifier(SettingsAccessibilityID.experimentalFeaturesToggle)

                Text("Experimental features may be incomplete, change without compatibility guarantees, and are not intended for production scientific work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workflow Builder") {
                Label("Workflow Builder is marked experimental while the builder and runner are being validated.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settings.resetSection(.advanced)
                    settings.save()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.experimentalFeaturesEnabled) { _, _ in settings.save() }
    }
}
