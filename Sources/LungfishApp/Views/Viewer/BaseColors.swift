// BaseColors.swift - IGV-standard DNA base colors
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

// MARK: - Base Colors (IGV Standard)

/// Standard IGV-like base colors for DNA visualization
/// Reference: IGV's SequenceTrack.java
public enum BaseColors {
    /// A = Green (#00CC00)
    public static let A = NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.0, alpha: 1.0)
    /// T = Red (#CC0000)
    public static let T = NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 1.0)
    /// C = Blue (#0000CC)
    public static let C = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.8, alpha: 1.0)
    /// G = Orange/Yellow (#FFB300)
    public static let G = NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.0, alpha: 1.0)
    /// N = Gray (#888888)
    public static let N = NSColor(calibratedRed: 0.53, green: 0.53, blue: 0.53, alpha: 1.0)
    /// U = Red (RNA, same as T)
    public static let U = T

    /// Returns the color for a given base character
    public static func color(for base: Character) -> NSColor {
        switch base.uppercased().first {
        case "A": return A
        case "T": return T
        case "C": return C
        case "G": return G
        case "U": return U
        case "N": return N
        default: return N
        }
    }

    /// Dictionary mapping base characters to colors
    public static let colorMap: [Character: NSColor] = [
        "A": A, "a": A,
        "T": T, "t": T,
        "C": C, "c": C,
        "G": G, "g": G,
        "U": U, "u": U,
        "N": N, "n": N,
    ]
}
