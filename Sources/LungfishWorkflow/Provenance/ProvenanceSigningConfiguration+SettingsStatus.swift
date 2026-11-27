// ProvenanceSigningConfiguration+SettingsStatus.swift - The words under Provenance Signing in Settings
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceSigningConfiguration {
    /// The status line the Provenance Signing section of Settings shows under its controls.
    ///
    /// The words sit beside the rule they describe. Every provenance writer asks
    /// ``defaultProvider(environment:)``, and that finds a key only in `signingKeyEnvironmentKey` or
    /// `signingKeyFileEnvironmentKey`. The Provider choice, the key saved to the Keychain and the public key path
    /// are read by no writer.
    ///
    /// - Parameters:
    ///   - provider: The Provider control, `off`, `local` or `cosign`.
    ///   - hasStoredKey: Whether a signing key is saved in the Keychain.
    ///   - environment: The environment the writers read, the process environment unless a test names one.
    public static func settingsStatus(
        provider: String,
        hasStoredKey: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let hasEnvironmentKey = environment[signingKeyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        switch provider {
        case "local":
            if hasStoredKey {
                return "Local signing is enabled with a stored Keychain key."
            } else if hasEnvironmentKey {
                return "Local signing is enabled with LUNGFISH_PROVENANCE_SIGNING_KEY."
            } else {
                return "Local signing is enabled but no signing key is stored."
            }
        case "cosign":
            return "Cosign signing is documented as a command plan; local verification uses sidecar artifacts."
        default:
            return "Provenance signing is off."
        }
    }
}
