// AIServicesSettingsTab.swift - AI service API key management tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

/// AI Services preferences: API key management, model selection, enable/disable.
struct AIServicesSettingsTab: View {
    private enum ProviderKind {
        case openAI
        case anthropic
        case gemini
    }

    private enum KeyValidationState: Equatable {
        case empty
        case unverified
        case validating
        case valid
        case invalid(String)
    }

    @State private var settings = AppSettings.shared

    @State private var openAIKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var geminiKey: String = ""
    @State private var keychainErrorMessage: String?
    @State private var showClearConfirmation = false
    @State private var isLoadingKeys = false
    @State private var openAIValidation: KeyValidationState = .empty
    @State private var anthropicValidation: KeyValidationState = .empty
    @State private var geminiValidation: KeyValidationState = .empty

    // Debounce tasks for Keychain writes (avoid writing on every keystroke)
    @State private var openAISaveTask: Task<Void, Never>?
    @State private var anthropicSaveTask: Task<Void, Never>?
    @State private var geminiSaveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI-powered search", isOn: $settings.aiSearchEnabled)
                    .accessibilityIdentifier(SettingsAccessibilityID.aiSearchToggle)
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
                .accessibilityIdentifier(SettingsAccessibilityID.aiPreferredProviderPicker)
                Text("The preferred provider will be used for AI Assistant queries. The first provider with a configured API key will be used as fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Anthropic") {
                HStack {
                    statusIndicator(state: anthropicValidation)
                    SecureField("API Key", text: $anthropicKey, prompt: Text("sk-ant-..."))
                        .accessibilityIdentifier(SettingsAccessibilityID.aiAnthropicKeyField)
                }
                validationText(for: anthropicValidation)
                Picker("Model:", selection: $settings.anthropicModel) {
                    Text("Claude Sonnet 4.5").tag("claude-sonnet-4-5-20250929")
                    Text("Claude Haiku 4.5").tag("claude-haiku-4-5-20251001")
                }
                .accessibilityIdentifier(SettingsAccessibilityID.aiAnthropicModelPicker)
            }

            Section("OpenAI") {
                HStack {
                    statusIndicator(state: openAIValidation)
                    SecureField("API Key", text: $openAIKey, prompt: Text("sk-..."))
                        .accessibilityIdentifier(SettingsAccessibilityID.aiOpenAIKeyField)
                }
                validationText(for: openAIValidation)
                Picker("Model:", selection: $settings.openAIModel) {
                    Text("GPT-5 Mini (Recommended)").tag("gpt-5-mini")
                    Text("GPT-5").tag("gpt-5")
                    Text("GPT-4.1").tag("gpt-4.1")
                    Text("GPT-4o").tag("gpt-4o")
                    Text("GPT-4o Mini").tag("gpt-4o-mini")
                }
                .accessibilityIdentifier(SettingsAccessibilityID.aiOpenAIModelPicker)
            }

            Section("Google Gemini") {
                HStack {
                    statusIndicator(state: geminiValidation)
                    SecureField("API Key", text: $geminiKey, prompt: Text("AIza..."))
                        .accessibilityIdentifier(SettingsAccessibilityID.aiGeminiKeyField)
                }
                validationText(for: geminiValidation)
                Picker("Model:", selection: $settings.geminiModel) {
                    Text("Gemini 2.5 Flash (Recommended)").tag("gemini-2.5-flash")
                    Text("Gemini 2.5 Pro").tag("gemini-2.5-pro")
                    Text("Gemini 2.5 Flash Lite").tag("gemini-2.5-flash-lite")
                    Text("Gemini 3 Flash Preview").tag("gemini-3-flash-preview")
                }
                .accessibilityIdentifier(SettingsAccessibilityID.aiGeminiModelPicker)
            }

            HStack {
                Button("Clear All Keys") {
                    showClearConfirmation = true
                }
                .foregroundStyle(Color.lungfishOrangeFallback)
                .accessibilityIdentifier(SettingsAccessibilityID.aiClearKeysButton)
                Spacer()
                Button("Restore Defaults") {
                    settings.resetSection(.aiServices)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.aiRestoreDefaultsButton)
            }

            if let keychainErrorMessage {
                Text(keychainErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(SettingsAccessibilityID.aiErrorMessage)
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
            cancelPendingSaves()
        }
        .alert("Clear All API Keys?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) { clearAllKeys() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all stored API keys from the Keychain. You will need to re-enter them to use AI features.")
        }
    }

    // MARK: - Helpers

    private func statusIndicator(state: KeyValidationState) -> some View {
        let symbol: String
        let color: Color
        switch state {
        case .empty:
            symbol = "minus.circle"
            color = .secondary
        case .unverified, .validating:
            symbol = "hourglass.circle"
            color = .orange
        case .valid:
            symbol = "checkmark.circle.fill"
            color = .green
        case .invalid:
            symbol = "xmark.circle.fill"
            color = .red
        }
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.small)
    }

    @ViewBuilder
    private func validationText(for state: KeyValidationState) -> some View {
        switch state {
        case .empty:
            EmptyView()
        case .unverified:
            Text("Key saved. Enter a full key to validate automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .validating:
            Text("Validating API key and quota...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .valid:
            Text("Key is valid and ready for AI queries.")
                .font(.caption)
                .foregroundStyle(.green)
        case .invalid(let message):
            Text("Validation failed: \(message)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func loadKeys() {
        Task { @MainActor in
            isLoadingKeys = true
            defer { isLoadingKeys = false }
            do {
                openAIKey = try await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.openAIAPIKey) ?? ""
                anthropicKey = try await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.anthropicAPIKey) ?? ""
                geminiKey = try await KeychainSecretStorage.shared.retrieve(forKey: KeychainSecretStorage.geminiAPIKey) ?? ""
                openAIValidation = openAIKey.isEmpty ? .empty : .unverified
                anthropicValidation = anthropicKey.isEmpty ? .empty : .unverified
                geminiValidation = geminiKey.isEmpty ? .empty : .unverified
                keychainErrorMessage = nil
            } catch {
                keychainErrorMessage = error.localizedDescription
            }
        }
    }

    /// Debounces Keychain writes by 500ms to avoid writing on every keystroke.
    private func debouncedStore(_ value: String, forKey key: String, task: inout Task<Void, Never>?) {
        guard !isLoadingKeys else { return }
        let provider = providerForKey(key)
        setValidationState(value.isEmpty ? .empty : .unverified, for: provider)
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await KeychainSecretStorage.shared.store(secret: value, forKey: key)
                keychainErrorMessage = nil
                guard !Task.isCancelled else { return }
                if shouldValidate(keyValue: value, provider: provider),
                   shouldApplyValidationResult(expectedKey: value, provider: provider) {
                    await validateKey(value, provider: provider)
                }
            } catch {
                keychainErrorMessage = error.localizedDescription
                if shouldApplyValidationResult(expectedKey: value, provider: provider) {
                    setValidationState(.invalid(error.localizedDescription), for: provider)
                }
            }
        }
    }

    private func clearAllKeys() {
        cancelPendingSaves()
        Task { @MainActor in
            do {
                try await KeychainSecretStorage.shared.deleteAll()
                isLoadingKeys = true
                defer { isLoadingKeys = false }
                openAIKey = ""
                anthropicKey = ""
                geminiKey = ""
                openAIValidation = .empty
                anthropicValidation = .empty
                geminiValidation = .empty
                keychainErrorMessage = nil
            } catch {
                keychainErrorMessage = error.localizedDescription
            }
        }
    }

    private func providerForKey(_ keychainKey: String) -> ProviderKind {
        switch keychainKey {
        case KeychainSecretStorage.anthropicAPIKey:
            return .anthropic
        case KeychainSecretStorage.geminiAPIKey:
            return .gemini
        default:
            return .openAI
        }
    }

    private func shouldValidate(keyValue: String, provider: ProviderKind) -> Bool {
        let trimmed = normalizedKey(keyValue)
        guard !trimmed.isEmpty else { return false }
        switch provider {
        case .openAI:
            return trimmed.hasPrefix("sk-") && trimmed.count >= 20
        case .anthropic:
            return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 20
        case .gemini:
            return trimmed.hasPrefix("AIza") && trimmed.count >= 20
        }
    }

    @MainActor
    private func validateKey(_ keyValue: String, provider: ProviderKind) async {
        guard shouldApplyValidationResult(expectedKey: keyValue, provider: provider) else { return }
        setValidationState(.validating, for: provider)
        do {
            let aiProvider: any AIProvider
            switch provider {
            case .openAI:
                aiProvider = OpenAIProvider(apiKey: keyValue, modelId: settings.openAIModel)
            case .anthropic:
                aiProvider = AnthropicProvider(apiKey: keyValue, modelId: settings.anthropicModel)
            case .gemini:
                aiProvider = GeminiProvider(apiKey: keyValue, modelId: settings.geminiModel)
            }
            try await aiProvider.validateCredentials()
            guard shouldApplyValidationResult(expectedKey: keyValue, provider: provider) else { return }
            setValidationState(.valid, for: provider)
        } catch let providerError as AIProviderError {
            guard shouldApplyValidationResult(expectedKey: keyValue, provider: provider) else { return }
            setValidationState(.invalid(providerError.localizedDescription), for: provider)
        } catch {
            guard shouldApplyValidationResult(expectedKey: keyValue, provider: provider) else { return }
            setValidationState(.invalid(error.localizedDescription), for: provider)
        }
    }

    @MainActor
    private func setValidationState(_ state: KeyValidationState, for provider: ProviderKind) {
        switch provider {
        case .openAI:
            openAIValidation = state
        case .anthropic:
            anthropicValidation = state
        case .gemini:
            geminiValidation = state
        }
    }

    private func cancelPendingSaves() {
        openAISaveTask?.cancel()
        anthropicSaveTask?.cancel()
        geminiSaveTask?.cancel()
        openAISaveTask = nil
        anthropicSaveTask = nil
        geminiSaveTask = nil
    }

    private func currentKey(for provider: ProviderKind) -> String {
        switch provider {
        case .openAI:
            openAIKey
        case .anthropic:
            anthropicKey
        case .gemini:
            geminiKey
        }
    }

    private func normalizedKey(_ keyValue: String) -> String {
        keyValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldApplyValidationResult(expectedKey: String, provider: ProviderKind) -> Bool {
        normalizedKey(currentKey(for: provider)) == normalizedKey(expectedKey)
    }
}
