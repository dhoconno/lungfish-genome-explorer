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

    private struct ModelOption: Identifiable {
        let id: String
        let label: String
    }

    private static let anthropicModelOptions: [ModelOption] = [
        ModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 (Recommended)"),
        ModelOption(id: "claude-opus-4-8", label: "Claude Opus 4.8"),
        ModelOption(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"),
        ModelOption(id: "claude-fable-5", label: "Claude Fable 5"),
    ]

    private static let openAIModelOptions: [ModelOption] = [
        ModelOption(id: "gpt-5.5", label: "GPT-5.5 (Recommended)"),
        ModelOption(id: "gpt-5.4", label: "GPT-5.4"),
        ModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        ModelOption(id: "gpt-5.4-nano", label: "GPT-5.4 Nano"),
        ModelOption(id: "gpt-5.1", label: "GPT-5.1"),
        ModelOption(id: "gpt-5.1-mini", label: "GPT-5.1 Mini"),
        ModelOption(id: "gpt-5.1-nano", label: "GPT-5.1 Nano"),
        ModelOption(id: "gpt-5-mini", label: "GPT-5 Mini"),
        ModelOption(id: "gpt-5", label: "GPT-5"),
        ModelOption(id: "gpt-4.1", label: "GPT-4.1"),
        ModelOption(id: "gpt-4.1-mini", label: "GPT-4.1 Mini"),
        ModelOption(id: "gpt-4.1-nano", label: "GPT-4.1 Nano"),
    ]

    private static let geminiModelOptions: [ModelOption] = [
        ModelOption(id: "gemini-3.5-flash", label: "Gemini 3.5 Flash (Recommended)"),
        ModelOption(id: "gemini-3.5-pro", label: "Gemini 3.5 Pro"),
        ModelOption(id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro Preview"),
        ModelOption(id: "gemini-3-pro-preview", label: "Gemini 3 Pro Preview"),
        ModelOption(id: "gemini-3-flash-preview", label: "Gemini 3 Flash Preview"),
        ModelOption(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro"),
        ModelOption(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash"),
        ModelOption(id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite"),
    ]

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
                    modelOptions(Self.anthropicModelOptions, selection: settings.anthropicModel)
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
                    modelOptions(Self.openAIModelOptions, selection: settings.openAIModel)
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
                    modelOptions(Self.geminiModelOptions, selection: settings.geminiModel)
                }
                .accessibilityIdentifier(SettingsAccessibilityID.aiGeminiModelPicker)
            }

            Section("Azure AI") {
                Toggle("Use Azure AI-hosted endpoint", isOn: $settings.openAIHostedEndpointEnabled)
                TextField("Endpoint", text: $settings.openAIHostedEndpoint, prompt: Text("https://example.openai.azure.com"))
                TextField("Deployment", text: $settings.openAIHostedDeployment, prompt: Text("gpt-5-mini"))
                Text("Use this for models deployed through Azure AI or Azure OpenAI endpoints. The deployment field accepts the deployment name exposed by your Azure resource.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(Color.lungfishDangerFallback)
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
        .onChange(of: settings.openAIHostedEndpointEnabled) { _, _ in settings.save() }
        .onChange(of: settings.openAIHostedEndpoint) { _, _ in settings.save() }
        .onChange(of: settings.openAIHostedDeployment) { _, _ in settings.save() }
        .onDisappear {
            cancelPendingSaves()
        }
        .alert("Clear All API Keys?", isPresented: $showClearConfirmation) {
            Button("Clear") { clearAllKeys() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all stored API keys from the Keychain. You will need to re-enter them to use AI features.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func modelOptions(_ options: [ModelOption], selection: String) -> some View {
        ForEach(options) { option in
            Text(option.label).tag(option.id)
        }
        if !selection.isEmpty && !options.contains(where: { $0.id == selection }) {
            Text("Custom (\(selection))").tag(selection)
        }
    }

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
            color = Color.lungfishDangerFallback
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
                .foregroundStyle(Color.lungfishDangerFallback)
        }
    }

    @MainActor
    private func loadKeys() {
        Task {
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
    @MainActor
    private func debouncedStore(_ value: String, forKey key: String, task: inout Task<Void, Never>?) {
        guard !isLoadingKeys else { return }
        let provider = providerForKey(key)
        setValidationState(value.isEmpty ? .empty : .unverified, for: provider)
        task?.cancel()
        task = Task {
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

    @MainActor
    private func clearAllKeys() {
        cancelPendingSaves()
        Task {
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
            if settings.openAIHostedEndpointEnabled {
                return trimmed.count >= 8
            }
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
                aiProvider = OpenAIProvider(
                    apiKey: keyValue,
                    modelId: settings.openAIModel,
                    endpointConfiguration: try settings.openAIEndpointConfiguration()
                )
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
