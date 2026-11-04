// BlastContactSettingsSection.swift - The optional address NCBI gets with each BLAST contact
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishCore
import LungfishKit
import Observation
import SwiftUI

/// What the `NCBI BLAST` row holds and does, apart from the view, so that its loading and its chained saves can run
/// under a test (the inspector runs neither `task` nor `onChange`). Each change is kept at once, in order, for the next
/// contact to read, and the last thing typed is what stays.
@MainActor
@Observable
final class BlastContactSettingsModel {
    var text = ""
    private(set) var saveFailure: String?
    @ObservationIgnored private var kept = ""
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var lastSave: Task<Void, Never>?
    private let store: BlastContactAddressStore

    init(store: BlastContactAddressStore) {
        self.store = store
    }

    /// What the text reads as.
    var reading: BlastContactAddress.Reading {
        BlastContactAddress.reading(of: text)
    }

    /// Shows what is saved. A change made before this ends is not saved.
    func load() async {
        let saved = await store.savedText()
        kept = saved
        text = saved
        loaded = true
    }

    /// Keeps `newValue` for the next contact, unless it is what is already kept.
    func textChanged(_ newValue: String) {
        guard loaded, newValue != kept else { return }
        kept = newValue
        save(newValue)
    }

    /// Ends when the last save has ended.
    func settle() async {
        await lastSave?.value
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

/// The `NCBI BLAST` section of the General tab (O132, UX-BLAST-WORDS Q6). Nothing here goes over the network, so its
/// states are what the text reads as, and each change is kept at once, in order, for the next contact to read.
struct BlastContactSettingsSection: View {
    @State private var model: BlastContactSettingsModel

    init(store: BlastContactAddressStore = .managedStorageDefault(environment: ProcessInfo.processInfo.environment)) {
        _model = State(initialValue: BlastContactSettingsModel(store: store))
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.text }, set: { model.text = $0 })
    }

    var body: some View {
        Section(BlastContactAddress.Words.section) {
            TextField(BlastContactAddress.Words.label, text: textBinding, prompt: Text(BlastContactAddress.Words.placeholder))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier(SettingsAccessibilityID.blastContactEmailField)

            Text(BlastContactAddress.Words.caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(BlastContactAddress.Words.state(model.reading))
                .font(.caption)
                .foregroundStyle(model.reading == .notValid ? AnyShapeStyle(Color.lungfishDangerFallback) : AnyShapeStyle(.secondary))

            if let saveFailure = model.saveFailure {
                Text(saveFailure)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishDangerFallback)
            }
        }
        .task { await model.load() }
        .onChange(of: model.text) { _, newValue in model.textChanged(newValue) }
    }
}
