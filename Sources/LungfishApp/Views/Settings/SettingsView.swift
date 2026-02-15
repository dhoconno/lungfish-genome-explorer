// SettingsView.swift - Root SwiftUI settings tab view
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Root settings view containing all preference tabs.
///
/// Follows macOS HIG tab-based settings layout with four categories:
/// General, Appearance, Rendering, and AI Services.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            RenderingSettingsTab()
                .tabItem { Label("Rendering", systemImage: "slider.horizontal.3") }
            AIServicesSettingsTab()
                .tabItem { Label("AI Services", systemImage: "brain") }
        }
        .frame(minWidth: 550, idealWidth: 680, minHeight: 460, idealHeight: 560)
    }
}
