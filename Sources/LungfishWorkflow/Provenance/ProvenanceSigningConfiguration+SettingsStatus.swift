// ProvenanceSigningConfiguration+SettingsStatus.swift - The words under Provenance Signing in Settings
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceSigningConfiguration {
    /// The status line the Provenance Signing section of Settings shows under its controls.
    ///
    /// The words say what the writers do. Every provenance writer asks ``defaultProvider(environment:)``, which
    /// finds a key only in `signingKeyEnvironmentKey` or `signingKeyFileEnvironmentKey`, so a record is signed
    /// when one of them holds a key and not otherwise. No writer reads the Provider choice, the key saved to the
    /// Keychain or the public key path, so the line says that too (PROVSIGN-KEYCHAIN-KEY-UNUSED).
    ///
    /// - Parameters:
    ///   - provider: The Provider control, `off`, `local` or `cosign`. Only `cosign` adds words, about its plan.
    ///   - hasStoredKey: Whether a signing key is saved in the Keychain. No writer reads it, so the words do not
    ///     depend on it, and the tests hold them to that. It stays an input so that the words change here, and
    ///     nowhere else, if a writer ever reads the saved key.
    ///   - environment: The environment the writers read, the process environment unless a test names one.
    public static func settingsStatus(
        provider: String,
        hasStoredKey: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var words = defaultProvider(environment: environment) != nil
            ? "Records are signed with the key set in \(signingKeyEnvironmentKey) or \(signingKeyFileEnvironmentKey)."
            : "Records are not signed. Lungfish signs a record only when \(signingKeyEnvironmentKey) or "
                + "\(signingKeyFileEnvironmentKey) holds a key."
        words += " The Provider, the saved key and the public key path above are not used to sign."
        if provider == "cosign" {
            words += " Cosign signing is documented as a command plan; local verification uses sidecar artifacts."
        }
        return words
    }
}
