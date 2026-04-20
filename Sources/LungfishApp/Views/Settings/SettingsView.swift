// SettingsView.swift - Root SwiftUI settings tab view
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// Root settings view containing all preference tabs.
///
/// Follows macOS HIG tab-based settings layout with five categories:
/// General, Appearance, Rendering, Storage, and AI Services.
struct SettingsView: View {
    @Bindable private var navigation = SettingsNavigationState.shared

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            GeneralSettingsTab()
                .tag(SettingsNavigationTab.general)
                .accessibilityIdentifier(SettingsAccessibilityID.panel(.general))
                .tabItem {
                    Label("General", systemImage: "gearshape")
                        .accessibilityIdentifier(SettingsAccessibilityID.tab(.general))
                }
            AppearanceSettingsTab()
                .tag(SettingsNavigationTab.appearance)
                .accessibilityIdentifier(SettingsAccessibilityID.panel(.appearance))
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                        .accessibilityIdentifier(SettingsAccessibilityID.tab(.appearance))
                }
            RenderingSettingsTab()
                .tag(SettingsNavigationTab.rendering)
                .accessibilityIdentifier(SettingsAccessibilityID.panel(.rendering))
                .tabItem {
                    Label("Rendering", systemImage: "slider.horizontal.3")
                        .accessibilityIdentifier(SettingsAccessibilityID.tab(.rendering))
                }
            StorageSettingsTab()
                .tag(SettingsNavigationTab.storage)
                .accessibilityIdentifier(SettingsAccessibilityID.panel(.storage))
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                        .accessibilityIdentifier(SettingsAccessibilityID.tab(.storage))
                }
            AIServicesSettingsTab()
                .tag(SettingsNavigationTab.aiServices)
                .accessibilityIdentifier(SettingsAccessibilityID.panel(.aiServices))
                .tabItem {
                    Label("AI Services", systemImage: "brain")
                        .accessibilityIdentifier(SettingsAccessibilityID.tab(.aiServices))
                }
        }
        .frame(minWidth: 550, idealWidth: 680, minHeight: 460, idealHeight: 560)
        .accessibilityIdentifier(SettingsAccessibilityID.root)
    }
}
