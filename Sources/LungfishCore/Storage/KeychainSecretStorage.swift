// KeychainSecretStorage.swift - Generic Keychain storage for API keys and secrets
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security
import os.log

private let keychainLogger = Logger(subsystem: "com.lungfish.core", category: "KeychainSecretStorage")

/// Generic Keychain-based storage for secrets (API keys, tokens, etc.).
///
/// Uses the macOS Keychain to securely store string secrets. Each secret is
/// identified by a key string (e.g., `"ai.openai.apiKey"`).
///
/// ## Usage
/// ```swift
/// // Store an API key
/// try await KeychainSecretStorage.shared.store(secret: "sk-...", forKey: "ai.openai.apiKey")
///
/// // Retrieve it
/// let key = try await KeychainSecretStorage.shared.retrieve(forKey: "ai.openai.apiKey")
///
/// // Delete it
/// try await KeychainSecretStorage.shared.delete(forKey: "ai.openai.apiKey")
/// ```
public actor KeychainSecretStorage {

    public static let shared = KeychainSecretStorage()

    private let service = "com.lungfish.secrets"

    public init() {}

    // MARK: - Well-Known Keys

    /// Keychain account key for the OpenAI API key.
    public static let openAIAPIKey = "ai.openai.apiKey"

    /// Keychain account key for the Anthropic API key.
    public static let anthropicAPIKey = "ai.anthropic.apiKey"

    /// Keychain account key for the Google Gemini API key.
    public static let geminiAPIKey = "ai.gemini.apiKey"

    // MARK: - Operations

    /// Stores a secret string in the Keychain under the given key.
    ///
    /// If a secret already exists for this key, it is replaced.
    /// Empty strings are treated as deletion.
    ///
    /// - Parameters:
    ///   - secret: The secret string to store
    ///   - key: The account identifier for this secret
    /// - Throws: `KeychainSecretError.unableToStore` if the operation fails
    public func store(secret: String, forKey key: String) throws {
        // Treat empty string as deletion
        if secret.isEmpty {
            try delete(forKey: key)
            return
        }

        guard let data = secret.data(using: .utf8) else {
            throw KeychainSecretError.unableToStore
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        // Delete existing item first (ignore error if not found)
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            keychainLogger.error("Keychain store failed for key '\(key)': \(status)")
            throw KeychainSecretError.unableToStore
        }

        keychainLogger.info("Secret stored for key '\(key)'")
    }

    /// Retrieves a secret string from the Keychain.
    ///
    /// - Parameter key: The account identifier for the secret
    /// - Returns: The secret string, or nil if not found
    /// - Throws: `KeychainSecretError.unableToRetrieve` on unexpected errors
    public func retrieve(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            keychainLogger.error("Keychain retrieve failed for key '\(key)': \(status)")
            throw KeychainSecretError.unableToRetrieve
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes a secret from the Keychain.
    ///
    /// - Parameter key: The account identifier for the secret to delete
    /// - Throws: `KeychainSecretError.unableToDelete` on unexpected errors
    public func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            keychainLogger.error("Keychain delete failed for key '\(key)': \(status)")
            throw KeychainSecretError.unableToDelete
        }

        keychainLogger.info("Secret deleted for key '\(key)'")
    }

    /// Checks whether a secret exists for the given key without revealing its value.
    ///
    /// - Parameter key: The account identifier to check
    /// - Returns: True if a secret is stored for this key
    public func hasSecret(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    /// Deletes all secrets stored by this app in the Keychain.
    public func deleteAll() throws {
        for key in [Self.openAIAPIKey, Self.anthropicAPIKey, Self.geminiAPIKey] {
            try delete(forKey: key)
        }
    }

    // MARK: - Errors

    public enum KeychainSecretError: Error, LocalizedError, Sendable {
        case unableToStore
        case unableToRetrieve
        case unableToDelete

        public var errorDescription: String? {
            switch self {
            case .unableToStore: return "Failed to store secret in Keychain"
            case .unableToRetrieve: return "Failed to retrieve secret from Keychain"
            case .unableToDelete: return "Failed to delete secret from Keychain"
            }
        }
    }
}
