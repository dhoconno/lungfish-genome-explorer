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
    @State private var keychainErrorMessage: String?
    @State private var showClearConfirmation = false
    @State private var isLoadingKeys = false

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

            Section("Preferred Provider") {
                Picker("Default provider:", selection: $settings.preferredAIProvider) {
                    Text("Anthropic Claude").tag("anthropic")
                    Text("OpenAI").tag("openai")
                    Text("Google Gemini").tag("gemini")
                }
                Text("The preferred provider will be used for AI Assistant queries. The first provider with a configured API key will be used as fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("OpenAI") {
                HStack {
                    statusIndicator(hasKey: !openAIKey.isEmpty)
                    SecureField("API Key", text: $openAIKey, prompt: Text("sk-..."))
                }
                Picker("Model:", selection: $settings.openAIModel) {
                    Text("GPT-4.1 Mini (Recommended)").tag("gpt-4.1-mini")
                    Text("GPT-4.1").tag("gpt-4.1")
                    Text("GPT-4o").tag("gpt-4o")
                    Text("GPT-4o Mini").tag("gpt-4o-mini")
                }
            }

            Section("Google Gemini") {
                HStack {
                    statusIndicator(hasKey: !geminiKey.isEmpty)
                    SecureField("API Key", text: $geminiKey, prompt: Text("AIza..."))
                }
                Picker("Model:", selection: $settings.geminiModel) {
                    Text("Gemini 2.5 Flash (Recommended)").tag("gemini-2.5-flash")
                    Text("Gemini 2.5 Pro").tag("gemini-2.5-pro")
                    Text("Gemini 3 Flash Preview").tag("gemini-3-flash-preview")
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

            if let keychainErrorMessage {
                Text(keychainErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadKeys() }
        .onChange(of: openAIKey) { _, newValue in
            debouncedStore(newValue, forKey: KeychainSecretStorage.openAIAPIKey, task: &openAISaveTask)
        }
        .onChange(of: anthropicKey) { _, newValue in
            debouncedStore(newValue, forKey: KeychainSecretStorage.anthropicAPIKey, task: &anthropicSaveTask)
        }
        .onChange(of: geminiKey) { _, newValue in
            debouncedStore(newValue, forKey: KeychainSecretStorage.geminiAPIKey, task: &geminiSaveTask)
        }
        .onChange(of: settings.aiSearchEnabled) { _, _ in settings.save() }
        .onChange(of: settings.preferredAIProvider) { _, _ in settings.save() }
        .onChange(of: settings.openAIModel) { _, _ in settings.save() }
        .onChange(of: settings.anthropicModel) { _, _ in settings.save() }
        .onChange(of: settings.geminiModel) { _, _ in settings.save() }
        .onDisappear {
            openAISaveTask?.cancel()
            anthropicSaveTask?.cancel()
            geminiSaveTask?.cancel()
        }
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
        Task { @MainActor in
            isLoadingKeys = true
            defer { isLoadingKeys = false }
            do {
                openAIKey = try await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.openAIAPIKey) ?? ""
                anthropicKey = try await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.anthropicAPIKey) ?? ""
                geminiKey = try await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.geminiAPIKey) ?? ""
                keychainErrorMessage = nil
            } catch {
                keychainErrorMessage = error.localizedDescription
            }
        }
    }

    /// Debounces Keychain writes by 500ms to avoid writing on every keystroke.
    private func debouncedStore(_ value: String, forKey key: String, task: inout Task<Void, Never>?) {
        guard !isLoadingKeys else { return }
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await KeychainSecretStorage.shared.store(secret: value, forKey: key)
                keychainErrorMessage = nil
            } catch {
                keychainErrorMessage = error.localizedDescription
            }
        }
    }

    private func clearAllKeys() {
        Task { @MainActor in
            do {
                try await KeychainSecretStorage.shared.deleteAll()
                isLoadingKeys = true
                openAIKey = ""
                anthropicKey = ""
                geminiKey = ""
                isLoadingKeys = false
                keychainErrorMessage = nil
            } catch {
                keychainErrorMessage = error.localizedDescription
            }
        }
    }
}
