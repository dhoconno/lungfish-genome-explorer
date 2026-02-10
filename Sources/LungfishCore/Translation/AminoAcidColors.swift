// AminoAcidColors.swift - Color schemes for amino acid display
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Amino Acid Color Scheme

/// Color schemes for amino acid visualization.
public enum AminoAcidColorScheme: String, CaseIterable, Sendable, Codable {
    case zappo
    case clustal
    case taylor
    case hydrophobicity

    /// Returns an RGB color tuple for the given amino acid character.
    public func color(for aminoAcid: Character) -> (red: Double, green: Double, blue: Double) {
        switch self {
        case .zappo: return zappoColor(for: aminoAcid)
        case .clustal: return clustalColor(for: aminoAcid)
        case .taylor: return taylorColor(for: aminoAcid)
        case .hydrophobicity: return hydrophobicityColor(for: aminoAcid)
        }
    }

    public var displayName: String {
        switch self {
        case .zappo: return "Zappo"
        case .clustal: return "ClustalX"
        case .taylor: return "Taylor"
        case .hydrophobicity: return "Hydrophobicity"
        }
    }
}

// MARK: - Zappo Scheme

/// Zappo: groups by physicochemical property
/// Aliphatic (ILVAM) = salmon, Aromatic (FWY) = orange, Positive (KRH) = blue,
/// Negative (DE) = red, Hydrophilic (STNQ) = green, Special (PG) = magenta, Cysteine (C) = yellow
private func zappoColor(for aa: Character) -> (red: Double, green: Double, blue: Double) {
    switch aa {
    // Aliphatic — salmon
    case "I", "L", "V", "A", "M":
        return (0.98, 0.59, 0.59)
    // Aromatic — orange
    case "F", "W", "Y":
        return (1.0, 0.73, 0.30)
    // Positive — blue
    case "K", "R", "H":
        return (0.40, 0.56, 0.93)
    // Negative — red
    case "D", "E":
        return (0.93, 0.30, 0.30)
    // Hydrophilic — green
    case "S", "T", "N", "Q":
        return (0.30, 0.82, 0.42)
    // Special conformations — magenta
    case "P", "G":
        return (0.85, 0.35, 0.85)
    // Cysteine — yellow
    case "C":
        return (0.95, 0.90, 0.30)
    // Stop codon
    case "*":
        return (0.50, 0.50, 0.50)
    // Unknown
    default:
        return (0.75, 0.75, 0.75)
    }
}

// MARK: - ClustalX Scheme

private func clustalColor(for aa: Character) -> (red: Double, green: Double, blue: Double) {
    switch aa {
    // Hydrophobic — blue
    case "A", "I", "L", "M", "F", "W", "V":
        return (0.20, 0.40, 0.90)
    // Positive — red
    case "K", "R":
        return (0.90, 0.20, 0.20)
    // Negative — magenta
    case "D", "E":
        return (0.85, 0.25, 0.85)
    // Polar — green
    case "N", "Q", "S", "T":
        return (0.20, 0.75, 0.35)
    // Cysteine — pink
    case "C":
        return (0.95, 0.55, 0.65)
    // Glycine — orange
    case "G":
        return (0.95, 0.65, 0.20)
    // Proline — yellow
    case "P":
        return (0.85, 0.80, 0.20)
    // Histidine — cyan
    case "H":
        return (0.20, 0.80, 0.80)
    // Tyrosine — cyan
    case "Y":
        return (0.20, 0.80, 0.80)
    // Stop
    case "*":
        return (0.50, 0.50, 0.50)
    default:
        return (0.75, 0.75, 0.75)
    }
}

// MARK: - Taylor Scheme

private func taylorColor(for aa: Character) -> (red: Double, green: Double, blue: Double) {
    switch aa {
    case "D": return (1.0, 0.0, 0.0)       // Red
    case "S": return (1.0, 0.33, 0.0)      // Orange-red
    case "T": return (1.0, 0.53, 0.0)      // Orange
    case "G": return (1.0, 0.80, 0.0)      // Gold
    case "P": return (1.0, 1.0, 0.0)       // Yellow
    case "C": return (1.0, 1.0, 0.0)       // Yellow
    case "A": return (0.80, 1.0, 0.0)      // Yellow-green
    case "V": return (0.53, 1.0, 0.0)      // Light green
    case "I": return (0.27, 1.0, 0.0)      // Green
    case "L": return (0.0, 1.0, 0.0)       // Green
    case "M": return (0.0, 1.0, 0.53)      // Teal
    case "F": return (0.0, 1.0, 0.80)      // Cyan-green
    case "Y": return (0.0, 0.93, 1.0)      // Light cyan
    case "W": return (0.0, 0.80, 1.0)      // Cyan
    case "H": return (0.0, 0.53, 1.0)      // Blue
    case "R": return (0.0, 0.0, 1.0)       // Blue
    case "K": return (0.27, 0.0, 1.0)      // Blue-violet
    case "N": return (0.80, 0.0, 1.0)      // Violet
    case "Q": return (1.0, 0.0, 0.80)      // Magenta
    case "E": return (1.0, 0.0, 0.40)      // Magenta-red
    case "*": return (0.50, 0.50, 0.50)
    default:  return (0.75, 0.75, 0.75)
    }
}

// MARK: - Hydrophobicity Scheme

/// Kyte-Doolittle scale: hydrophobic = red, hydrophilic = blue
private func hydrophobicityColor(for aa: Character) -> (red: Double, green: Double, blue: Double) {
    switch aa {
    // Most hydrophobic — deep red
    case "I": return (0.95, 0.15, 0.15)
    case "V": return (0.90, 0.20, 0.20)
    case "L": return (0.88, 0.22, 0.22)
    // Hydrophobic — red-orange
    case "F": return (0.85, 0.30, 0.20)
    case "C": return (0.82, 0.35, 0.25)
    case "M": return (0.80, 0.38, 0.28)
    case "A": return (0.78, 0.40, 0.30)
    // Mildly hydrophobic — orange
    case "G": return (0.70, 0.50, 0.40)
    case "T": return (0.60, 0.55, 0.50)
    case "S": return (0.55, 0.55, 0.55)
    case "W": return (0.55, 0.50, 0.55)
    case "Y": return (0.50, 0.50, 0.60)
    case "P": return (0.45, 0.50, 0.65)
    // Hydrophilic — blue
    case "H": return (0.35, 0.45, 0.75)
    case "N": return (0.30, 0.42, 0.80)
    case "Q": return (0.28, 0.40, 0.82)
    case "D": return (0.25, 0.38, 0.85)
    case "E": return (0.22, 0.35, 0.88)
    case "K": return (0.18, 0.30, 0.92)
    case "R": return (0.15, 0.25, 0.95)
    // Stop
    case "*": return (0.50, 0.50, 0.50)
    default:  return (0.75, 0.75, 0.75)
    }
}
