// SequenceAppearance.swift - User preferences for sequence visualization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Storage & Indexing Lead (Role 18)

import Foundation
import AppKit

/// User preferences for sequence visualization appearance.
///
/// Stores customizable colors for DNA/RNA bases, track dimensions, and display options.
/// Settings are persisted to UserDefaults for cross-session persistence.
///
/// ## Default Colors
/// Uses standard bioinformatics colors:
/// - A (Adenine): Green (#00A000)
/// - T (Thymine): Red (#FF0000)
/// - G (Guanine): Yellow/Gold (#FFD700)
/// - C (Cytosine): Blue (#0000FF)
/// - N (Unknown): Gray (#808080)
///
/// ## Example Usage
/// ```swift
/// // Load saved settings or get defaults
/// let appearance = SequenceAppearance.load()
///
/// // Get color for a specific base
/// let adenineColor = appearance.color(forBase: "A")
///
/// // Modify and save
/// var modified = appearance
/// modified.setColor(.systemPurple, forBase: "A")
/// modified.save()
/// ```
public struct SequenceAppearance: Codable, Sendable {

    // MARK: - Properties

    /// Base colors stored as hex strings for Codable support.
    ///
    /// Keys are single-character strings representing bases (e.g., "A", "T", "G", "C", "N").
    /// Values are hex color strings (e.g., "#00FF00").
    public var baseColors: [String: String]

    /// Track height in points.
    ///
    /// Controls the vertical size of sequence tracks in the viewer.
    /// Default is 50 points.
    public var trackHeight: CGFloat

    /// Whether to show quality overlay on sequences.
    ///
    /// When enabled, bases are shaded based on their quality scores
    /// (from FASTQ files). Higher quality bases appear brighter.
    public var showQualityOverlay: Bool

    // MARK: - Default Values

    /// Default appearance settings using standard bioinformatics colors.
    ///
    /// - A (Adenine): Green (#00A000)
    /// - T (Thymine): Red (#FF0000)
    /// - G (Guanine): Yellow/Gold (#FFD700)
    /// - C (Cytosine): Blue (#0000FF)
    /// - N (Unknown): Gray (#808080)
    /// - U (Uracil/RNA): Same as T (#FF0000)
    public static var `default`: SequenceAppearance {
        SequenceAppearance(
            baseColors: [
                "A": "#00A000",  // Green - Adenine
                "T": "#FF0000",  // Red - Thymine
                "G": "#FFD700",  // Yellow/Gold - Guanine
                "C": "#0000FF",  // Blue - Cytosine
                "N": "#808080",  // Gray - Unknown
                "U": "#FF0000"   // Red - Uracil (RNA equivalent of T)
            ],
            trackHeight: 20.0,  // Compact default for sequence tracks
            showQualityOverlay: false
        )
    }

    // MARK: - Initialization

    /// Creates a new SequenceAppearance with the specified settings.
    ///
    /// - Parameters:
    ///   - baseColors: Dictionary mapping base characters to hex color strings
    ///   - trackHeight: Height of sequence tracks in points
    ///   - showQualityOverlay: Whether to display quality score overlay
    public init(
        baseColors: [String: String],
        trackHeight: CGFloat,
        showQualityOverlay: Bool
    ) {
        self.baseColors = baseColors
        self.trackHeight = trackHeight
        self.showQualityOverlay = showQualityOverlay
    }

    // MARK: - Color Accessors

    /// Get the color for a specific base character.
    ///
    /// Returns the configured color for the base, or gray if the base
    /// is not found in the configuration.
    ///
    /// - Parameter base: The base character (e.g., 'A', 'T', 'G', 'C', 'N')
    /// - Returns: The NSColor for the specified base
    public func color(forBase base: Character) -> NSColor {
        let key = String(base).uppercased()
        if let hexString = baseColors[key] {
            return Self.color(from: hexString)
        }
        // Fallback to gray for unknown bases
        return Self.color(from: "#808080")
    }

    /// Set the color for a specific base character.
    ///
    /// Updates the color configuration for the specified base.
    /// The change is not automatically persisted; call `save()` to persist.
    ///
    /// - Parameters:
    ///   - color: The new color to use for the base
    ///   - base: The base character to configure (e.g., 'A', 'T', 'G', 'C', 'N')
    public mutating func setColor(_ color: NSColor, forBase base: Character) {
        let key = String(base).uppercased()
        baseColors[key] = Self.hexString(from: color)
    }

    // MARK: - Hex Color Conversion

    /// Converts an NSColor to a hex string representation.
    ///
    /// - Parameter color: The color to convert
    /// - Returns: A hex string in the format "#RRGGBB"
    private static func hexString(from color: NSColor) -> String {
        // Convert to RGB color space if needed
        guard let rgbColor = color.usingColorSpace(.sRGB) else {
            // Fallback for colors that can't be converted
            return "#808080"
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Converts a hex string to an NSColor.
    ///
    /// Supports formats:
    /// - "#RRGGBB" (6 digits with hash)
    /// - "RRGGBB" (6 digits without hash)
    /// - "#RGB" (3 digits with hash, expanded to 6)
    /// - "RGB" (3 digits without hash, expanded to 6)
    ///
    /// - Parameter hexString: The hex color string to parse
    /// - Returns: The corresponding NSColor, or gray if parsing fails
    private static func color(from hexString: String) -> NSColor {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove leading hash if present
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }

        // Expand 3-digit hex to 6-digit
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        // Validate hex string length
        guard hex.count == 6 else {
            return NSColor.gray
        }

        // Parse hex components
        guard let hexValue = UInt32(hex, radix: 16) else {
            return NSColor.gray
        }

        let red = CGFloat((hexValue >> 16) & 0xFF) / 255.0
        let green = CGFloat((hexValue >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hexValue & 0xFF) / 255.0

        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
    }
}

// MARK: - Persistence

extension SequenceAppearance {

    /// UserDefaults key for storing appearance settings.
    private static let userDefaultsKey = "SequenceAppearance"

    /// Save current settings to UserDefaults.
    ///
    /// Encodes the appearance settings as JSON and stores them in UserDefaults.
    /// If encoding fails, the operation silently fails (settings are not critical).
    ///
    /// ## Thread Safety
    /// This method is safe to call from any thread, as UserDefaults
    /// handles synchronization internally.
    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            // Log error but don't crash - appearance settings are not critical
            #if DEBUG
            print("SequenceAppearance: Failed to save settings: \(error)")
            #endif
        }
    }

    /// Load settings from UserDefaults, or return default if none saved.
    ///
    /// Attempts to decode previously saved settings from UserDefaults.
    /// If no settings are found or decoding fails, returns the default appearance.
    ///
    /// ## Thread Safety
    /// This method is safe to call from any thread, as UserDefaults
    /// handles synchronization internally.
    ///
    /// - Returns: The saved SequenceAppearance, or `SequenceAppearance.default` if none exists
    public static func load() -> SequenceAppearance {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return .default
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(SequenceAppearance.self, from: data)
        } catch {
            // Log error but return defaults - don't crash for settings
            #if DEBUG
            print("SequenceAppearance: Failed to load settings: \(error)")
            #endif
            return .default
        }
    }

    /// Resets appearance settings to defaults.
    ///
    /// Removes any saved settings from UserDefaults and returns
    /// the default appearance configuration.
    ///
    /// - Returns: The default SequenceAppearance
    @discardableResult
    public static func resetToDefaults() -> SequenceAppearance {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        return .default
    }
}

// MARK: - Equatable

extension SequenceAppearance: Equatable {
    public static func == (lhs: SequenceAppearance, rhs: SequenceAppearance) -> Bool {
        lhs.baseColors == rhs.baseColors &&
        lhs.trackHeight == rhs.trackHeight &&
        lhs.showQualityOverlay == rhs.showQualityOverlay
    }
}

// MARK: - Hashable

extension SequenceAppearance: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(baseColors)
        hasher.combine(trackHeight)
        hasher.combine(showQualityOverlay)
    }
}
