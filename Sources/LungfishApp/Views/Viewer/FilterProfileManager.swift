// FilterProfileManager.swift - Preset filter profiles for variant tables
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Filter Profile

/// A named profile that captures column preferences, smart tokens, and filter state.
///
/// Profiles let users switch between curated views (Clinical, Research, QC)
/// or save their own custom configurations for one-click recall.
struct FilterProfile: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Smart tokens to activate (by raw value).
    let activeTokens: [String]
    /// Filter text to set in the search field.
    let filterText: String
    /// Whether this is a built-in (non-deletable) profile.
    let isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, activeTokens: [String] = [], filterText: String = "", isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.activeTokens = activeTokens
        self.filterText = filterText
        self.isBuiltIn = isBuiltIn
    }

    /// Converts active token raw values back to SmartToken set.
    var smartTokens: Set<SmartToken> {
        Set(activeTokens.compactMap { SmartToken(rawValue: $0) })
    }

    // MARK: - Built-In Profiles

    /// Clinical analysis: PASS variants with ClinVar pathogenic hits.
    static let clinical = FilterProfile(
        name: "Clinical",
        activeTokens: [SmartToken.passOnly.rawValue, SmartToken.clinvarPathogenic.rawValue],
        filterText: "",
        isBuiltIn: true
    )

    /// Research exploration: rare variants, no pre-filters.
    static let research = FilterProfile(
        name: "Research",
        activeTokens: [SmartToken.rareVariant.rawValue],
        filterText: "",
        isBuiltIn: true
    )

    /// Quality control: focus on call quality metrics.
    static let qualityControl = FilterProfile(
        name: "QC",
        activeTokens: [SmartToken.qualityGE30.rawValue, SmartToken.depthGE10.rawValue],
        filterText: "",
        isBuiltIn: true
    )

    /// High-confidence coding variants.
    static let highConfidence = FilterProfile(
        name: "High Confidence",
        activeTokens: [SmartToken.passOnly.rawValue, SmartToken.qualityGE30.rawValue, SmartToken.highImpact.rawValue],
        filterText: "",
        isBuiltIn: true
    )

    static let builtInProfiles: [FilterProfile] = [.clinical, .research, .qualityControl, .highConfidence]
}

// MARK: - Profile Persistence

enum FilterProfileStore {
    private static let keyPrefix = "com.lungfish.filterProfiles"

    private static func key(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return keyPrefix }
        return "\(keyPrefix).\(bundleIdentifier)"
    }

    static func loadCustomProfiles(bundleIdentifier: String? = nil) -> [FilterProfile] {
        guard let data = UserDefaults.standard.data(forKey: key(bundleIdentifier: bundleIdentifier)) else { return [] }
        return (try? JSONDecoder().decode([FilterProfile].self, from: data)) ?? []
    }

    static func saveCustomProfiles(_ profiles: [FilterProfile], bundleIdentifier: String? = nil) {
        let data = try? JSONEncoder().encode(profiles.filter { !$0.isBuiltIn })
        UserDefaults.standard.set(data, forKey: key(bundleIdentifier: bundleIdentifier))
    }
}
