// AppSettings.swift - Centralized application preferences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import os.log

private let settingsLogger = Logger(subsystem: LogSubsystem.core, category: "AppSettings")

// MARK: - Settings Section

/// Sections of the settings UI, used for per-section reset.
public enum SettingsSection: String, Sendable {
    case general
    case appearance
    case rendering
    case aiServices
}

/// Scroll direction behavior for custom viewport interaction handling.
public enum ScrollDirectionPreference: String, Sendable, CaseIterable, Codable {
    case system
    case natural
    case traditional

    public var label: String {
        switch self {
        case .system: return "System"
        case .natural: return "Natural"
        case .traditional: return "Traditional"
        }
    }
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

    /// Scroll direction preference for horizontal panning in the viewport.
    public var horizontalScrollDirection: ScrollDirectionPreference = .system

    /// Scroll direction preference for vertical scrolling in stacked rows.
    public var verticalScrollDirection: ScrollDirectionPreference = .system

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
    public var openAIModel: String = "gpt-5-mini"

    /// Selected Anthropic model identifier.
    public var anthropicModel: String = "claude-sonnet-4-5-20250929"

    /// Selected Google Gemini model identifier.
    public var geminiModel: String = "gemini-2.5-flash"

    /// Which AI provider to use for the AI assistant.
    public var preferredAIProvider: String = "anthropic"

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

    // MARK: - Bounds

    private static let defaultZoomWindowBounds = 1_000...1_000_000
    private static let maxUndoLevelsBounds = 10...1_000
    private static let tempRetentionHoursBounds = 1...168
    private static let annotationHeightBounds: ClosedRange<Double> = 8...32
    private static let annotationSpacingBounds: ClosedRange<Double> = 0...8
    private static let maxAnnotationRowsBounds = 10...200
    private static let fetchCapKbBounds = 100...5_000
    private static let tableDisplayCountBounds = 1_000...50_000
    private static let densityThresholdBounds: ClosedRange<Double> = 10_000...500_000
    private static let squishedThresholdBounds: ClosedRange<Double> = 100...5_000
    private static let showLettersThresholdBounds: ClosedRange<Double> = 1...50
    private static let tooltipDelayBounds: ClosedRange<Double> = 0...1.0

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
        var horizontalScrollDirection: ScrollDirectionPreference
        var verticalScrollDirection: ScrollDirectionPreference
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
        var preferredAIProvider: String

        init(
            defaultZoomWindow: Int,
            maxUndoLevels: Int,
            vcfImportProfile: String,
            tempFileRetentionHours: Int,
            sequenceAppearance: SequenceAppearance,
            annotationTypeColorHexes: [String: String],
            variantColorThemeName: String,
            defaultAnnotationHeight: Double,
            defaultAnnotationSpacing: Double,
            horizontalScrollDirection: ScrollDirectionPreference,
            verticalScrollDirection: ScrollDirectionPreference,
            maxAnnotationRows: Int,
            sequenceFetchCapKb: Int,
            maxTableDisplayCount: Int,
            densityThresholdBpPerPixel: Double,
            squishedThresholdBpPerPixel: Double,
            showLettersThresholdBpPerPixel: Double,
            tooltipDelay: Double,
            aiSearchEnabled: Bool,
            openAIModel: String,
            anthropicModel: String,
            geminiModel: String,
            preferredAIProvider: String
        ) {
            self.defaultZoomWindow = defaultZoomWindow
            self.maxUndoLevels = maxUndoLevels
            self.vcfImportProfile = vcfImportProfile
            self.tempFileRetentionHours = tempFileRetentionHours
            self.sequenceAppearance = sequenceAppearance
            self.annotationTypeColorHexes = annotationTypeColorHexes
            self.variantColorThemeName = variantColorThemeName
            self.defaultAnnotationHeight = defaultAnnotationHeight
            self.defaultAnnotationSpacing = defaultAnnotationSpacing
            self.horizontalScrollDirection = horizontalScrollDirection
            self.verticalScrollDirection = verticalScrollDirection
            self.maxAnnotationRows = maxAnnotationRows
            self.sequenceFetchCapKb = sequenceFetchCapKb
            self.maxTableDisplayCount = maxTableDisplayCount
            self.densityThresholdBpPerPixel = densityThresholdBpPerPixel
            self.squishedThresholdBpPerPixel = squishedThresholdBpPerPixel
            self.showLettersThresholdBpPerPixel = showLettersThresholdBpPerPixel
            self.tooltipDelay = tooltipDelay
            self.aiSearchEnabled = aiSearchEnabled
            self.openAIModel = openAIModel
            self.anthropicModel = anthropicModel
            self.geminiModel = geminiModel
            self.preferredAIProvider = preferredAIProvider
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // General
            defaultZoomWindow = try container.decodeIfPresent(Int.self, forKey: .defaultZoomWindow) ?? 10_000
            maxUndoLevels = try container.decodeIfPresent(Int.self, forKey: .maxUndoLevels) ?? 100
            vcfImportProfile = try container.decodeIfPresent(String.self, forKey: .vcfImportProfile) ?? "auto"
            tempFileRetentionHours = try container.decodeIfPresent(Int.self, forKey: .tempFileRetentionHours) ?? 24
            // Appearance
            sequenceAppearance = try container.decodeIfPresent(SequenceAppearance.self, forKey: .sequenceAppearance) ?? .default
            annotationTypeColorHexes = try container.decodeIfPresent([String: String].self, forKey: .annotationTypeColorHexes) ?? [
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
            variantColorThemeName = try container.decodeIfPresent(String.self, forKey: .variantColorThemeName) ?? VariantColorTheme.modern.name
            defaultAnnotationHeight = try container.decodeIfPresent(Double.self, forKey: .defaultAnnotationHeight) ?? 16
            defaultAnnotationSpacing = try container.decodeIfPresent(Double.self, forKey: .defaultAnnotationSpacing) ?? 2
            horizontalScrollDirection = try container.decodeIfPresent(ScrollDirectionPreference.self, forKey: .horizontalScrollDirection) ?? .system
            verticalScrollDirection = try container.decodeIfPresent(ScrollDirectionPreference.self, forKey: .verticalScrollDirection) ?? .system
            // Rendering
            maxAnnotationRows = try container.decodeIfPresent(Int.self, forKey: .maxAnnotationRows) ?? 50
            sequenceFetchCapKb = try container.decodeIfPresent(Int.self, forKey: .sequenceFetchCapKb) ?? 500
            maxTableDisplayCount = try container.decodeIfPresent(Int.self, forKey: .maxTableDisplayCount) ?? 5_000
            densityThresholdBpPerPixel = try container.decodeIfPresent(Double.self, forKey: .densityThresholdBpPerPixel) ?? 50_000
            squishedThresholdBpPerPixel = try container.decodeIfPresent(Double.self, forKey: .squishedThresholdBpPerPixel) ?? 500
            showLettersThresholdBpPerPixel = try container.decodeIfPresent(Double.self, forKey: .showLettersThresholdBpPerPixel) ?? 10.0
            tooltipDelay = try container.decodeIfPresent(Double.self, forKey: .tooltipDelay) ?? 0.15
            // AI Services
            aiSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiSearchEnabled) ?? false
            openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-5-mini"
            anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel) ?? "claude-sonnet-4-5-20250929"
            geminiModel = try container.decodeIfPresent(String.self, forKey: .geminiModel) ?? "gemini-2.5-flash"
            preferredAIProvider = try container.decodeIfPresent(String.self, forKey: .preferredAIProvider) ?? "anthropic"
        }
    }

    private static func clamp(_ value: Int, to bounds: ClosedRange<Int>) -> Int {
        max(bounds.lowerBound, min(bounds.upperBound, value))
    }

    private static func clamp(_ value: Double, to bounds: ClosedRange<Double>) -> Double {
        max(bounds.lowerBound, min(bounds.upperBound, value))
    }

    private static func normalizedImportProfile(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "fast":
            return "fast"
        case "lowmemory":
            return "lowMemory"
        default:
            return "auto"
        }
    }

    private static func normalizedVariantThemeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let validNames = Set(VariantColorTheme.allBuiltIn.map(\.name))
        return validNames.contains(trimmed) ? trimmed : VariantColorTheme.modern.name
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            defaultZoomWindow: Self.clamp(defaultZoomWindow, to: Self.defaultZoomWindowBounds),
            maxUndoLevels: Self.clamp(maxUndoLevels, to: Self.maxUndoLevelsBounds),
            vcfImportProfile: Self.normalizedImportProfile(vcfImportProfile),
            tempFileRetentionHours: Self.clamp(tempFileRetentionHours, to: Self.tempRetentionHoursBounds),
            sequenceAppearance: sequenceAppearance,
            annotationTypeColorHexes: annotationTypeColorHexes,
            variantColorThemeName: Self.normalizedVariantThemeName(variantColorThemeName),
            defaultAnnotationHeight: Self.clamp(defaultAnnotationHeight, to: Self.annotationHeightBounds),
            defaultAnnotationSpacing: Self.clamp(defaultAnnotationSpacing, to: Self.annotationSpacingBounds),
            horizontalScrollDirection: horizontalScrollDirection,
            verticalScrollDirection: verticalScrollDirection,
            maxAnnotationRows: Self.clamp(maxAnnotationRows, to: Self.maxAnnotationRowsBounds),
            sequenceFetchCapKb: Self.clamp(sequenceFetchCapKb, to: Self.fetchCapKbBounds),
            maxTableDisplayCount: Self.clamp(maxTableDisplayCount, to: Self.tableDisplayCountBounds),
            densityThresholdBpPerPixel: Self.clamp(densityThresholdBpPerPixel, to: Self.densityThresholdBounds),
            squishedThresholdBpPerPixel: Self.clamp(squishedThresholdBpPerPixel, to: Self.squishedThresholdBounds),
            showLettersThresholdBpPerPixel: Self.clamp(showLettersThresholdBpPerPixel, to: Self.showLettersThresholdBounds),
            tooltipDelay: Self.clamp(tooltipDelay, to: Self.tooltipDelayBounds),
            aiSearchEnabled: aiSearchEnabled,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel,
            geminiModel: geminiModel,
            preferredAIProvider: preferredAIProvider
        )
    }

    private func apply(_ snapshot: Snapshot) {
        defaultZoomWindow = Self.clamp(snapshot.defaultZoomWindow, to: Self.defaultZoomWindowBounds)
        maxUndoLevels = Self.clamp(snapshot.maxUndoLevels, to: Self.maxUndoLevelsBounds)
        vcfImportProfile = Self.normalizedImportProfile(snapshot.vcfImportProfile)
        tempFileRetentionHours = Self.clamp(snapshot.tempFileRetentionHours, to: Self.tempRetentionHoursBounds)
        sequenceAppearance = snapshot.sequenceAppearance
        annotationTypeColorHexes = snapshot.annotationTypeColorHexes
        variantColorThemeName = Self.normalizedVariantThemeName(snapshot.variantColorThemeName)
        defaultAnnotationHeight = Self.clamp(snapshot.defaultAnnotationHeight, to: Self.annotationHeightBounds)
        defaultAnnotationSpacing = Self.clamp(snapshot.defaultAnnotationSpacing, to: Self.annotationSpacingBounds)
        horizontalScrollDirection = snapshot.horizontalScrollDirection
        verticalScrollDirection = snapshot.verticalScrollDirection
        maxAnnotationRows = Self.clamp(snapshot.maxAnnotationRows, to: Self.maxAnnotationRowsBounds)
        sequenceFetchCapKb = Self.clamp(snapshot.sequenceFetchCapKb, to: Self.fetchCapKbBounds)
        maxTableDisplayCount = Self.clamp(snapshot.maxTableDisplayCount, to: Self.tableDisplayCountBounds)
        densityThresholdBpPerPixel = Self.clamp(snapshot.densityThresholdBpPerPixel, to: Self.densityThresholdBounds)
        squishedThresholdBpPerPixel = Self.clamp(snapshot.squishedThresholdBpPerPixel, to: Self.squishedThresholdBounds)
        showLettersThresholdBpPerPixel = Self.clamp(snapshot.showLettersThresholdBpPerPixel, to: Self.showLettersThresholdBounds)
        tooltipDelay = Self.clamp(snapshot.tooltipDelay, to: Self.tooltipDelayBounds)
        aiSearchEnabled = snapshot.aiSearchEnabled
        openAIModel = snapshot.openAIModel
        anthropicModel = snapshot.anthropicModel
        geminiModel = snapshot.geminiModel
        preferredAIProvider = snapshot.preferredAIProvider
    }

    /// Persists current settings to UserDefaults and posts change notifications.
    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(makeSnapshot())
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
            settingsLogger.info("Settings saved")
        } catch {
            settingsLogger.warning("Failed to save settings: \(error)")
        }

        NotificationCenter.default.post(name: .appSettingsChanged, object: nil)
        NotificationCenter.default.post(name: .appearanceChanged, object: nil)
    }

    /// Loads settings from UserDefaults into the shared instance.
    public static func load() {
        let defaults = UserDefaults.standard
        let hadPersistedSettings = defaults.data(forKey: userDefaultsKey) != nil

        if let data = defaults.data(forKey: userDefaultsKey) {
            do {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                shared.apply(snapshot)
                settingsLogger.info("Settings loaded from UserDefaults")
                return
            } catch {
                settingsLogger.warning("Failed to decode settings, resetting to defaults: \(error)")
            }
        }

        shared.resetToDefaults()
        if hadPersistedSettings {
            settingsLogger.info("Using defaults after failing to decode persisted settings")
        } else {
            settingsLogger.info("No persisted settings found, using defaults")
        }
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
            horizontalScrollDirection = fresh.horizontalScrollDirection
            verticalScrollDirection = fresh.verticalScrollDirection
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
            preferredAIProvider = fresh.preferredAIProvider
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
