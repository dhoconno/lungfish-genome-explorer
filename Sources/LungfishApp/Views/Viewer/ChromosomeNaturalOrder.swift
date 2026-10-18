// ChromosomeNaturalOrder.swift - The first chromosome in natural karyotype order, without a sort
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The chromosome `naturalChromosomeSort(_:)` puts first, found in one pass
/// that builds each sort key once.
///
/// Opening a bundle needs only its first chromosome, and sorting the 905,628
/// sequences of a large reference to take it cost 12 seconds on the main
/// thread. The key below matches `chromosomeSortKey` in
/// `ChromosomeNavigatorView.swift`, and `ChromosomeNaturalOrderTests` pins the
/// two orders together. Among equal keys the earliest chromosome wins, as in
/// the stable sort.
func firstChromosomeInNaturalOrder(_ chromosomes: [ChromosomeInfo]) -> ChromosomeInfo? {
    chromosomes.lazy
        .map { (key: naturalOrderKey($0.name), chromosome: $0) }
        .min { $0.key < $1.key }?
        .chromosome
}

private let scaffoldSeparators = CharacterSet(charactersIn: "_-")

/// Natural karyotype order: 1 to 22, X, Y, W, Z, M or MT, then the rest by name.
private func naturalOrderKey(_ name: String) -> (Int, Int, String) {
    var stripped = name
    for prefix in ["chromosome", "Chromosome", "CHROMOSOME", "chr", "Chr", "CHR"] {
        if stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
    }
    stripped = stripped.trimmingCharacters(in: scaffoldSeparators)

    if let number = Int(stripped) {
        return (0, number, "")
    }

    switch stripped.uppercased() {
    case "X": return (1, 0, "")
    case "Y": return (1, 1, "")
    case "W": return (1, 2, "")
    case "Z": return (1, 3, "")
    case "M", "MT": return (2, 0, "")
    default: return (3, 0, name)
    }
}
