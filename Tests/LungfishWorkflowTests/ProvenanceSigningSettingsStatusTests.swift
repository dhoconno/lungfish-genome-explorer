// ProvenanceSigningSettingsStatusTests.swift - The status words under Provenance Signing in Settings
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// PROVSIGN-KEYCHAIN-KEY-UNUSED. Every provenance writer signs from `LUNGFISH_PROVENANCE_SIGNING_KEY` or
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` and reads no other source, so the Provider control, the key saved to the
// Keychain and the public key path decide nothing it does. The status line under those controls says what the
// writers do, and these tests hold it to `defaultProvider(environment:)`, the question each writer asks.

import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Provenance Signing settings status")
struct ProvenanceSigningSettingsStatusTests {
    private static let providers = ["off", "local", "cosign"]
    private static let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
    private static let keyFileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey

    private func words(_ provider: String, saved: Bool, _ environment: [String: String]) -> String {
        ProvenanceSigningConfiguration.settingsStatus(provider: provider, hasStoredKey: saved, environment: environment)
    }

    @Test("The words say records are signed exactly when the writers sign, whatever the Provider and the saved key")
    func wordsFollowTheWritersRule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provsign-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyFile = directory.appendingPathComponent("signing.key")
        try Data("throwaway-key".utf8).write(to: keyFile)
        let emptyFile = directory.appendingPathComponent("empty.key")
        try Data().write(to: emptyFile)
        let missingFile = directory.appendingPathComponent("missing.key")

        let environments: [(name: String, values: [String: String], writersSign: Bool)] = [
            ("no key", [:], false),
            ("blank key", [Self.keyName: "   "], false),
            ("key", [Self.keyName: "throwaway-key"], true),
            ("key file", [Self.keyFileName: keyFile.path], true),
            ("empty key file", [Self.keyFileName: emptyFile.path], false),
            ("missing key file", [Self.keyFileName: missingFile.path], false),
        ]
        for environment in environments {
            let writerSigns = ProvenanceSigningConfiguration.defaultProvider(environment: environment.values) != nil
            #expect(writerSigns == environment.writersSign, "the table row \(environment.name) is wrong")
            for provider in Self.providers {
                for saved in [false, true] {
                    let text = words(provider, saved: saved, environment.values)
                    let expected = writerSigns ? "Records are signed" : "Records are not signed"
                    #expect(
                        text.hasPrefix(expected),
                        "\(provider), saved key \(saved), \(environment.name): \(text)"
                    )
                }
            }
        }
    }

    @Test("Off does not say signing is off while a key in the environment signs records")
    func offWithAKeyInTheEnvironment() {
        let text = words("off", saved: false, [Self.keyName: "throwaway-key"])
        #expect(!text.contains("is off"), "\(text)")
        #expect(text.hasPrefix("Records are signed"), "\(text)")
    }

    @Test("Local with a saved Keychain key and none in the environment does not say signing is enabled")
    func localWithOnlyASavedKey() {
        let text = words("local", saved: true, [:])
        #expect(!text.contains("enabled"), "\(text)")
        #expect(!text.contains("Keychain key."), "\(text)")
        #expect(text.hasPrefix("Records are not signed"), "\(text)")
    }

    @Test("The words name both variables and say the Provider, the saved key and the public key path are not used")
    func wordsNameWhatSignsAndWhatDoesNot() {
        for provider in Self.providers {
            for saved in [false, true] {
                let text = words(provider, saved: saved, [:])
                #expect(text.contains(Self.keyName), "\(provider), saved key \(saved): \(text)")
                #expect(text.contains(Self.keyFileName), "\(provider), saved key \(saved): \(text)")
                #expect(
                    text.contains("The Provider, the saved key and the public key path above are not used to sign."),
                    "\(provider), saved key \(saved): \(text)"
                )
            }
        }
    }
}
