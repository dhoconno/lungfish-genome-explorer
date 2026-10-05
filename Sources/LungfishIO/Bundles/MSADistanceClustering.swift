// MSADistanceClustering.swift - Deterministic UPGMA leaf order for MSA distance matrices
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum MSADistanceClustering {
    /// Returns the UPGMA (average linkage) leaf order of `count` items.
    ///
    /// `distance(i, j)` must be finite and symmetric for `i != j`. Each step merges the pair of
    /// clusters with the smallest (distance, smaller cluster minimum index, larger cluster
    /// minimum index), where a cluster's minimum index is the smallest original index it holds.
    /// The child holding the smaller original index is placed first. The result is therefore
    /// fully deterministic, including on ties.
    static func averageLinkageOrder(count: Int, distance: (Int, Int) -> Double) -> [Int] {
        guard count > 2 else { return Array(0..<count) }

        // Cluster slots are the original indices. A merged cluster reuses the slot of its
        // smaller minimum index, so slot == minimum index for every active cluster.
        var dist = [Double](repeating: 0, count: count * count)
        for i in 0..<count {
            for j in (i + 1)..<count {
                let d = distance(i, j)
                dist[i * count + j] = d
                dist[j * count + i] = d
            }
        }
        var sizes = [Int](repeating: 1, count: count)
        var leaves: [[Int]] = (0..<count).map { [$0] }
        var active = [Bool](repeating: true, count: count)
        var best = [Int](repeating: -1, count: count)

        func less(_ a: (Double, Int, Int), _ b: (Double, Int, Int)) -> Bool {
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }
        func key(_ i: Int, _ j: Int) -> (Double, Int, Int) {
            (dist[i * count + j], min(i, j), max(i, j))
        }
        func rescan(_ i: Int) {
            var candidate = -1
            for j in 0..<count where j != i && active[j] {
                if candidate < 0 || less(key(i, j), key(i, candidate)) {
                    candidate = j
                }
            }
            best[i] = candidate
        }

        for i in 0..<count { rescan(i) }

        var remaining = count
        while remaining > 1 {
            var a = -1
            for i in 0..<count where active[i] && best[i] >= 0 {
                if a < 0 || less(key(i, best[i]), key(a, best[a])) {
                    a = i
                }
            }
            let b = best[a]
            let keep = min(a, b)
            let drop = max(a, b)

            let sizeKeep = Double(sizes[keep])
            let sizeDrop = Double(sizes[drop])
            for k in 0..<count where active[k] && k != keep && k != drop {
                let merged = (sizeKeep * dist[keep * count + k] + sizeDrop * dist[drop * count + k])
                    / (sizeKeep + sizeDrop)
                dist[keep * count + k] = merged
                dist[k * count + keep] = merged
            }
            leaves[keep] += leaves[drop]
            leaves[drop] = []
            sizes[keep] += sizes[drop]
            active[drop] = false
            remaining -= 1

            rescan(keep)
            for k in 0..<count where active[k] && k != keep {
                if best[k] == keep || best[k] == drop {
                    rescan(k)
                } else if less(key(k, keep), key(k, best[k])) {
                    best[k] = keep
                }
            }
        }
        return leaves[active.firstIndex(of: true) ?? 0]
    }
}
