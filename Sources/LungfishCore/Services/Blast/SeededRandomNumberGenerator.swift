// SeededRandomNumberGenerator.swift - NCBI BLAST URL API client
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Seeded Random Number Generator

/// A deterministic random number generator for reproducible subsampling.
///
/// Uses a simple xorshift64 algorithm seeded with a fixed value.
/// This ensures that the same reads are selected for the same taxon
/// across repeated runs.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a seeded RNG.
    ///
    /// - Parameter seed: The seed value. A seed of 0 is remapped to 1
    ///   to avoid the degenerate xorshift state.
    init(seed: UInt64) {
        // xorshift64 requires non-zero state
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64 algorithm
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
