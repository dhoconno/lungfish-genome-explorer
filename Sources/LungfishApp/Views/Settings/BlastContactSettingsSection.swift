// BlastContactSettingsSection.swift - The optional address NCBI gets with each BLAST contact
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import SwiftUI

/// The `NCBI BLAST` section of the General tab (O132, UX-BLAST-WORDS Q6). Nothing here goes over the network, so its
/// states are what the text reads as, and each change is kept at once, in order, for the next contact to read.
struct BlastContactSettingsSection: View {
    @State private var text = ""
    @State private var kept = ""
    @State private var loaded = false
    @State private var saveFailure: String?
    @State private var lastSave: Task<Void, Never>?

    private let store: BlastContactAddressStore

    init(store: BlastContactAddressStore = .managedStorageDefault(environment: ProcessInfo.processInfo.environment)) {
        self.store = store
    }

    private var reading: BlastContactAddress.Reading {
        BlastContactAddress.reading(of: text)
    }

    var body: some View {
        Section(BlastContactAddress.Words.section) {
            TextField(BlastContactAddress.Words.label, text: $text, prompt: Text(BlastContactAddress.Words.placeholder))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier(SettingsAccessibilityID.blastContactEmailField)

            Text(BlastContactAddress.Words.caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(BlastContactAddress.Words.state(reading))
                .font(.caption)
                .foregroundStyle(reading == .notValid ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))

            if let saveFailure {
                Text(saveFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            let saved = await store.savedText()
            kept = saved
            text = saved
            loaded = true
        }
        .onChange(of: text) { _, newValue in
            guard loaded, newValue != kept else { return }
            kept = newValue
            save(newValue)
        }
    }

    /// Each save waits for the one before it, so the last thing typed is what stays.
    private func save(_ value: String) {
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            do {
                try await store.save(value)
                saveFailure = nil
            } catch {
                saveFailure = BlastContactAddress.Words.saveFailed(error.localizedDescription)
            }
        }
    }
}
