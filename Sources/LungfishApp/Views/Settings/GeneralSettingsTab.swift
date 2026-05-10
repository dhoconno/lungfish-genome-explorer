// GeneralSettingsTab.swift - General preferences tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// General preferences: zoom, undo, VCF import, temp file retention.
struct GeneralSettingsTab: View {

    @State private var settings = AppSettings.shared
    @State private var ncbiAPIKey = ""
    @State private var ncbiKeyStatus = "Checking NCBI API key settings..."
    @State private var ncbiKeyError: String?
    @State private var hasStoredNCBIAPIKey = false
    @State private var provenanceSigningKey = ""
    @State private var provenanceSigningStatus = "Checking provenance signing settings..."
    @State private var provenanceSigningError: String?
    @State private var hasStoredProvenanceSigningKey = false

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

            Section("NCBI") {
                SecureField("API key:", text: $ncbiAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save API Key") {
                        Task { await saveNCBIAPIKey() }
                    }
                    .disabled(ncbiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Clear Stored Key") {
                        Task { await clearNCBIAPIKey() }
                    }
                    .disabled(!hasStoredNCBIAPIKey)
                }

                Text(ncbiKeyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let ncbiKeyError {
                    Text(ncbiKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Provenance Signing") {
                Picker("Provider:", selection: $settings.provenanceSigningProvider) {
                    Text("Off").tag("off")
                    Text("Local").tag("local")
                    Text("Cosign Plan").tag("cosign")
                }
                .pickerStyle(.segmented)

                SecureField("Local signing key:", text: $provenanceSigningKey)
                    .textFieldStyle(.roundedBorder)

                TextField("Public key path:", text: $settings.provenanceSigningPublicKeyPath)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Signing Key") {
                        Task { await saveProvenanceSigningKey() }
                    }
                    .disabled(provenanceSigningKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Clear Signing Key") {
                        Task { await clearProvenanceSigningKey() }
                    }
                    .disabled(!hasStoredProvenanceSigningKey)
                }

                Text(provenanceSigningStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let provenanceSigningError {
                    Text(provenanceSigningError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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
        .onChange(of: settings.provenanceSigningProvider) { _, _ in settings.save() }
        .onChange(of: settings.provenanceSigningPublicKeyPath) { _, _ in settings.save() }
        .task {
            await refreshNCBIAPIKeyStatus()
            await refreshProvenanceSigningStatus()
        }
    }

    private func saveNCBIAPIKey() async {
        do {
            try await settings.storeNCBIAPIKey(ncbiAPIKey)
            ncbiAPIKey = ""
            ncbiKeyError = nil
            await refreshNCBIAPIKeyStatus()
        } catch {
            ncbiKeyError = "Could not save NCBI API key: \(error.localizedDescription)"
        }
    }

    private func clearNCBIAPIKey() async {
        do {
            try await settings.deleteNCBIAPIKey()
            ncbiAPIKey = ""
            ncbiKeyError = nil
            await refreshNCBIAPIKeyStatus()
        } catch {
            ncbiKeyError = "Could not clear NCBI API key: \(error.localizedDescription)"
        }
    }

    private func refreshNCBIAPIKeyStatus() async {
        hasStoredNCBIAPIKey = await settings.hasStoredNCBIAPIKey()
        let hasEnvironmentKey = ProcessInfo.processInfo.environment["NCBI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        switch (hasStoredNCBIAPIKey, hasEnvironmentKey) {
        case (true, true):
            ncbiKeyStatus = "Using the stored Keychain API key. NCBI_API_KEY is available as a fallback."
        case (true, false):
            ncbiKeyStatus = "Using the stored Keychain API key."
        case (false, true):
            ncbiKeyStatus = "Using NCBI_API_KEY from the process environment."
        case (false, false):
            ncbiKeyStatus = "No NCBI API key configured. Requests use the public NCBI rate limit."
        }
    }

    private func saveProvenanceSigningKey() async {
        do {
            try await settings.storeProvenanceSigningPrivateKey(provenanceSigningKey)
            provenanceSigningKey = ""
            provenanceSigningError = nil
            await refreshProvenanceSigningStatus()
        } catch {
            provenanceSigningError = "Could not save signing key: \(error.localizedDescription)"
        }
    }

    private func clearProvenanceSigningKey() async {
        do {
            try await settings.deleteProvenanceSigningPrivateKey()
            provenanceSigningKey = ""
            provenanceSigningError = nil
            await refreshProvenanceSigningStatus()
        } catch {
            provenanceSigningError = "Could not clear signing key: \(error.localizedDescription)"
        }
    }

    private func refreshProvenanceSigningStatus() async {
        hasStoredProvenanceSigningKey = await settings.hasStoredProvenanceSigningPrivateKey()
        let hasEnvironmentKey = ProcessInfo.processInfo.environment["LUNGFISH_PROVENANCE_SIGNING_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        switch settings.provenanceSigningProvider {
        case "local":
            if hasStoredProvenanceSigningKey {
                provenanceSigningStatus = "Local signing is enabled with a stored Keychain key."
            } else if hasEnvironmentKey {
                provenanceSigningStatus = "Local signing is enabled with LUNGFISH_PROVENANCE_SIGNING_KEY."
            } else {
                provenanceSigningStatus = "Local signing is enabled but no signing key is stored."
            }
        case "cosign":
            provenanceSigningStatus = "Cosign signing is documented as a command plan; local verification uses sidecar artifacts."
        default:
            provenanceSigningStatus = "Provenance signing is off."
        }
    }
}
