// SRADownloadSourcePicker.swift - The SRA search window's "Download source" setting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// The "Download source" popup in the SRA search's advanced settings. It
/// stores the choice under `SRADownloadSourcePreference.userDefaultsKey` in
/// the window's `DatabaseBrowserViewModel.sraDownloadDefaults`, which every
/// download the window starts reads once per batch. The caption under the popup names
/// the trade-off, so nothing depends on the help tag alone.
struct SRADownloadSourcePicker: View {
    /// The popup's accessibility identifier.
    static let accessibilityIdentifier = "database-filter-sra-download-source"
    /// The popup's label.
    static let title = "Download source"

    @AppStorage private var preference: SRADownloadSourcePreference

    init(store: UserDefaults = .standard) {
        _preference = Self.storage(in: store)
    }

    /// The stored setting the popup reads and writes.
    static func storage(in store: UserDefaults) -> AppStorage<SRADownloadSourcePreference> {
        AppStorage(wrappedValue: .ena, SRADownloadSourcePreference.userDefaultsKey, store: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.bottom, 4)
            Text(Self.title)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
                // The popup carries this label, so VoiceOver reads it once.
                .accessibilityHidden(true)
            Picker(Self.title, selection: $preference) {
                ForEach(SRADownloadSourcePreference.allCases, id: \.self) { choice in
                    Text(choice.menuTitle).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityHint(SRADownloadSourcePreference.tradeOff)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .help(SRADownloadSourcePreference.tradeOff)
            Text(SRADownloadSourcePreference.tradeOff)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
