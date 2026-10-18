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
/// thread. The key is `chromosomeSortKey` in `ChromosomeNavigatorView.swift`,
/// the same one `naturalChromosomeSort` uses, and `ChromosomeNaturalOrderTests`
/// pins the two orders together. Among equal keys the earliest chromosome wins,
/// as in the stable sort.
func firstChromosomeInNaturalOrder(_ chromosomes: [ChromosomeInfo]) -> ChromosomeInfo? {
    chromosomes.lazy
        .map { (key: chromosomeSortKey($0.name), chromosome: $0) }
        .min { $0.key < $1.key }?
        .chromosome
}
