// AppSettings.swift - Centralized application preferences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import os.log

private let settingsLogger = Logger(subsystem: "com.lungfish.core", category: "AppSettings")

// MARK: - Settings Section

/// Sections of the settings UI, used for per-section reset.
public enum SettingsSection: String, Sendable {
    case general
    case appearance
    case rendering
    case aiServices
}

// MARK: - AppSettings

/// Centralized, observable application preferences.
///
/// Singleton accessed via `AppSettings.shared`. Persists non-secret values as a single
/// JSON blob in UserDefaults. API keys are stored separately in Keychain via
/// `KeychainSecretStorage`.
///
/// ## Usage
/// ```swift
/// // Read a setting
/// let maxRows = AppSettings.shared.maxAnnotationRows
///
/// // Modify and save
/// AppSettings.shared.maxAnnotationRows = 100
/// AppSettings.shared.save()
/// ```
@Observable
@MainActor
public final class AppSettings: Sendable {

    // MARK: - Singleton

    public static let shared = AppSettings()

    // MARK: - General

    /// Default zoom window in base pairs when opening a chromosome.
    public var defaultZoomWindow: Int = 10_000

    /// Maximum undo history depth.
    public var maxUndoLevels: Int = 100

    /// VCF import profile: "auto", "fast", or "lowMemory".
    public var vcfImportProfile: String = "auto"

    /// Temporary file retention in hours before cleanup.
    public var tempFileRetentionHours: Int = 24

    // MARK: - Appearance

    /// Nucleotide base color configuration (persisted as hex strings).
    public var sequenceAppearance: SequenceAppearance = .default

    /// Annotation type colors as hex strings keyed by `AnnotationType.rawValue`.
    public var annotationTypeColorHexes: [String: String] = defaultAnnotationTypeColorHexes

    /// Variant color theme name ("Modern", "IGV Classic", "High Contrast").
    public var variantColorThemeName: String = "Modern"

    /// Default annotation feature height in pixels.
    public var defaultAnnotationHeight: Double = 16

    /// Default vertical spacing between annotation rows in pixels.
    public var defaultAnnotationSpacing: Double = 2

    // MARK: - Rendering

    /// Maximum annotation rows before showing "+N more" indicator.
    public var maxAnnotationRows: Int = 50

    /// Maximum sequence fetch size in kilobases.
    public var sequenceFetchCapKb: Int = 500

    /// Maximum number of items displayed in annotation/variant tables.
    public var maxTableDisplayCount: Int = 5_000

    /// Zoom threshold (bp/pixel) above which density histogram mode is used.
    public var densityThresholdBpPerPixel: Double = 50_000

    /// Zoom threshold (bp/pixel) above which squished mode is used.
    public var squishedThresholdBpPerPixel: Double = 500

    /// Zoom threshold (bp/pixel) below which individual base letters are shown.
    public var showLettersThresholdBpPerPixel: Double = 10.0

    /// Delay in seconds before showing hover tooltips.
    public var tooltipDelay: Double = 0.15

    // MARK: - AI Services

    /// Whether AI-powered natural language search is enabled.
    public var aiSearchEnabled: Bool = false

    /// Selected OpenAI model identifier.
    public var openAIModel: String = "gpt-4o"

    /// Selected Anthropic model identifier.
    public var anthropicModel: String = "claude-sonnet-4-5-20250929"

    /// Selected Google Gemini model identifier.
    public var geminiModel: String = "gemini-2.0-flash"

    // MARK: - Defaults

    /// Default annotation type colors matching the hardcoded values in the viewer.
    public static let defaultAnnotationTypeColorHexes: [String: String] = [
        "gene": "#339933",
        "CDS": "#3366CC",
        "exon": "#994DCC",
        "mRNA": "#CC6633",
        "transcript": "#B38050",
        "misc_feature": "#808080",
        "region": "#66B3B3",
        "primer": "#33CC33",
        "restriction_site": "#CC3333",
    ]

    // MARK: - Persistence

    private static let userDefaultsKey = "com.lungfish.appSettings"
    private static let legacyAppearanceKey = "SequenceAppearance"
    private static let legacyVCFProfileKey = "VCFImportProfile"

    /// Codable snapshot for UserDefaults persistence.
    private struct Snapshot: Codable {
        // General
        var defaultZoomWindow: Int
        var maxUndoLevels: Int
        var vcfImportProfile: String
        var tempFileRetentionHours: Int
        // Appearance
        var sequenceAppearance: SequenceAppearance
        var annotationTypeColorHexes: [String: String]
        var variantColorThemeName: String
        var defaultAnnotationHeight: Double
        var defaultAnnotationSpacing: Double
        // Rendering
        var maxAnnotationRows: Int
        var sequenceFetchCapKb: Int
        var maxTableDisplayCount: Int
        var densityThresholdBpPerPixel: Double
        var squishedThresholdBpPerPixel: Double
        var showLettersThresholdBpPerPixel: Double
        var tooltipDelay: Double
        // AI Services
        var aiSearchEnabled: Bool
        var openAIModel: String
        var anthropicModel: String
        var geminiModel: String
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            defaultZoomWindow: defaultZoomWindow,
            maxUndoLevels: maxUndoLevels,
            vcfImportProfile: vcfImportProfile,
            tempFileRetentionHours: tempFileRetentionHours,
            sequenceAppearance: sequenceAppearance,
            annotationTypeColorHexes: annotationTypeColorHexes,
            variantColorThemeName: variantColorThemeName,
            defaultAnnotationHeight: defaultAnnotationHeight,
            defaultAnnotationSpacing: defaultAnnotationSpacing,
            maxAnnotationRows: maxAnnotationRows,
            sequenceFetchCapKb: sequenceFetchCapKb,
            maxTableDisplayCount: maxTableDisplayCount,
            densityThresholdBpPerPixel: densityThresholdBpPerPixel,
            squishedThresholdBpPerPixel: squishedThresholdBpPerPixel,
            showLettersThresholdBpPerPixel: showLettersThresholdBpPerPixel,
            tooltipDelay: tooltipDelay,
            aiSearchEnabled: aiSearchEnabled,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel,
            geminiModel: geminiModel
        )
    }

    private func apply(_ snapshot: Snapshot) {
        defaultZoomWindow = snapshot.defaultZoomWindow
        maxUndoLevels = snapshot.maxUndoLevels
        vcfImportProfile = snapshot.vcfImportProfile
        tempFileRetentionHours = snapshot.tempFileRetentionHours
        sequenceAppearance = snapshot.sequenceAppearance
        annotationTypeColorHexes = snapshot.annotationTypeColorHexes
        variantColorThemeName = snapshot.variantColorThemeName
        defaultAnnotationHeight = snapshot.defaultAnnotationHeight
        defaultAnnotationSpacing = snapshot.defaultAnnotationSpacing
        maxAnnotationRows = snapshot.maxAnnotationRows
        sequenceFetchCapKb = snapshot.sequenceFetchCapKb
        maxTableDisplayCount = snapshot.maxTableDisplayCount
        densityThresholdBpPerPixel = snapshot.densityThresholdBpPerPixel
        squishedThresholdBpPerPixel = snapshot.squishedThresholdBpPerPixel
        showLettersThresholdBpPerPixel = snapshot.showLettersThresholdBpPerPixel
        tooltipDelay = snapshot.tooltipDelay
        aiSearchEnabled = snapshot.aiSearchEnabled
        openAIModel = snapshot.openAIModel
        anthropicModel = snapshot.anthropicModel
        geminiModel = snapshot.geminiModel
    }

    /// Persists current settings to UserDefaults and posts change notifications.
    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(makeSnapshot())
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
            // Also keep legacy SequenceAppearance key in sync for backward compatibility
            sequenceAppearance.save()
            settingsLogger.info("Settings saved")
        } catch {
            settingsLogger.warning("Failed to save settings: \(error)")
        }

        NotificationCenter.default.post(name: .appSettingsChanged, object: nil)
        NotificationCenter.default.post(name: .appearanceChanged, object: nil)
    }

    /// Loads settings from UserDefaults into the shared instance, migrating legacy keys if needed.
    public static func load() {
        let defaults = UserDefaults.standard

        // Try loading the new unified settings key
        if let data = defaults.data(forKey: userDefaultsKey) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                shared.apply(snapshot)
                settingsLogger.info("Settings loaded from UserDefaults")
                return
            } catch {
                settingsLogger.warning("Failed to decode settings, using defaults: \(error)")
            }
        }

        // Migrate legacy SequenceAppearance if present
        if defaults.data(forKey: legacyAppearanceKey) != nil {
            shared.sequenceAppearance = SequenceAppearance.load()
            settingsLogger.info("Migrated legacy SequenceAppearance")
        }

        // Migrate legacy VCF import profile if present
        if let profile = defaults.string(forKey: legacyVCFProfileKey) {
            shared.vcfImportProfile = profile
            settingsLogger.info("Migrated legacy VCFImportProfile: \(profile)")
        }

        // Save migrated settings under the new key
        shared.save()
    }

    /// Resets all settings to their default values (in-memory only; call `save()` to persist).
    public func resetToDefaults() {
        let fresh = AppSettings()
        apply(fresh.makeSnapshot())
        settingsLogger.info("All settings reset to defaults")
    }

    /// Resets a specific section of settings to defaults.
    public func resetSection(_ section: SettingsSection) {
        let fresh = AppSettings()
        switch section {
        case .general:
            defaultZoomWindow = fresh.defaultZoomWindow
            maxUndoLevels = fresh.maxUndoLevels
            vcfImportProfile = fresh.vcfImportProfile
            tempFileRetentionHours = fresh.tempFileRetentionHours
        case .appearance:
            sequenceAppearance = fresh.sequenceAppearance
            annotationTypeColorHexes = fresh.annotationTypeColorHexes
            variantColorThemeName = fresh.variantColorThemeName
            defaultAnnotationHeight = fresh.defaultAnnotationHeight
            defaultAnnotationSpacing = fresh.defaultAnnotationSpacing
        case .rendering:
            maxAnnotationRows = fresh.maxAnnotationRows
            sequenceFetchCapKb = fresh.sequenceFetchCapKb
            maxTableDisplayCount = fresh.maxTableDisplayCount
            densityThresholdBpPerPixel = fresh.densityThresholdBpPerPixel
            squishedThresholdBpPerPixel = fresh.squishedThresholdBpPerPixel
            showLettersThresholdBpPerPixel = fresh.showLettersThresholdBpPerPixel
            tooltipDelay = fresh.tooltipDelay
        case .aiServices:
            aiSearchEnabled = fresh.aiSearchEnabled
            openAIModel = fresh.openAIModel
            anthropicModel = fresh.anthropicModel
            geminiModel = fresh.geminiModel
        }
        settingsLogger.info("Section '\(section.rawValue)' reset to defaults")
    }

    // MARK: - Color Helpers

    /// Returns an NSColor for the given annotation type, using the user's configured hex color.
    public func annotationColor(for type: AnnotationType) -> NSColor {
        let key = type.rawValue
        guard let hex = annotationTypeColorHexes[key] else {
            return NSColor.gray
        }
        return Self.color(from: hex)
    }

    /// Converts a hex string (e.g. "#339933") to an NSColor.
    public static func color(from hexString: String) -> NSColor {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .gray }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// Converts an NSColor to a hex string (e.g. "#339933").
    public static func hexString(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
