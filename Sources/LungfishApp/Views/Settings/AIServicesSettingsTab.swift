// AIServicesSettingsTab.swift - AI service API key management tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// AI Services preferences: API key management, model selection, enable/disable.
struct AIServicesSettingsTab: View {

    @State private var settings = AppSettings.shared

    @State private var openAIKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var geminiKey: String = ""
    @State private var showClearConfirmation = false

    // Debounce tasks for Keychain writes (avoid writing on every keystroke)
    @State private var openAISaveTask: Task<Void, Never>?
    @State private var anthropicSaveTask: Task<Void, Never>?
    @State private var geminiSaveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI-powered search", isOn: $settings.aiSearchEnabled)
                Text("When enabled, natural language queries can use AI models to search annotations and retrieve genomic context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI") {
                HStack {
                    statusIndicator(hasKey: !openAIKey.isEmpty)
                    SecureField("API Key", text: $openAIKey, prompt: Text("sk-..."))
                }
                Picker("Model:", selection: $settings.openAIModel) {
                    Text("GPT-4o").tag("gpt-4o")
                    Text("GPT-4o Mini").tag("gpt-4o-mini")
                    Text("GPT-4 Turbo").tag("gpt-4-turbo")
                }
            }

            Section("Anthropic") {
                HStack {
                    statusIndicator(hasKey: !anthropicKey.isEmpty)
                    SecureField("API Key", text: $anthropicKey, prompt: Text("sk-ant-..."))
                }
                Picker("Model:", selection: $settings.anthropicModel) {
                    Text("Claude Sonnet 4.5").tag("claude-sonnet-4-5-20250929")
                    Text("Claude Haiku 4.5").tag("claude-haiku-4-5-20251001")
                }
            }

            Section("Google Gemini") {
                HStack {
                    statusIndicator(hasKey: !geminiKey.isEmpty)
                    SecureField("API Key", text: $geminiKey, prompt: Text("AIza..."))
                }
                Picker("Model:", selection: $settings.geminiModel) {
                    Text("Gemini 2.0 Flash").tag("gemini-2.0-flash")
                    Text("Gemini 1.5 Pro").tag("gemini-1.5-pro")
                }
            }

            HStack {
                Button("Clear All Keys") {
                    showClearConfirmation = true
                }
                .foregroundStyle(.red)
                Spacer()
                Button("Restore Defaults") {
                    settings.resetSection(.aiServices)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadKeys() }
        .onChange(of: openAIKey) { _, newValue in debouncedStore(newValue, forKey: KeychainSecretStorage.openAIAPIKey, task: &openAISaveTask) }
        .onChange(of: anthropicKey) { _, newValue in debouncedStore(newValue, forKey: KeychainSecretStorage.anthropicAPIKey, task: &anthropicSaveTask) }
        .onChange(of: geminiKey) { _, newValue in debouncedStore(newValue, forKey: KeychainSecretStorage.geminiAPIKey, task: &geminiSaveTask) }
        .onChange(of: settings.aiSearchEnabled) { _, _ in settings.save() }
        .onChange(of: settings.openAIModel) { _, _ in settings.save() }
        .onChange(of: settings.anthropicModel) { _, _ in settings.save() }
        .onChange(of: settings.geminiModel) { _, _ in settings.save() }
        .alert("Clear All API Keys?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) { clearAllKeys() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all stored API keys from the Keychain. You will need to re-enter them to use AI features.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusIndicator(hasKey: Bool) -> some View {
        Image(systemName: hasKey ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(hasKey ? .green : .secondary)
            .imageScale(.small)
    }

    private func loadKeys() {
        Task {
            openAIKey = (try? await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.openAIAPIKey)) ?? ""
            anthropicKey = (try? await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.anthropicAPIKey)) ?? ""
            geminiKey = (try? await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.geminiAPIKey)) ?? ""
        }
    }

    /// Debounces Keychain writes by 500ms to avoid writing on every keystroke.
    private func debouncedStore(_ value: String, forKey key: String, task: inout Task<Void, Never>?) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? await KeychainSecretStorage.shared.store(secret: value, forKey: key)
        }
    }

    private func clearAllKeys() {
        Task {
            try? await KeychainSecretStorage.shared.deleteAll()
            openAIKey = ""
            anthropicKey = ""
            geminiKey = ""
        }
    }
}
