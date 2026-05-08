// IVarCodonMerger.swift - Codon-aware haplotype merging matching nf-core/viralrecon
// ivar_variants_to_vcf.py semantics. Adjacent SNPs that share a REF_CODON or
// ALT_CODON value are grouped, and all 2^n REF/ALT combinations are enumerated
// and validated against AF rules.

import Foundation

public enum IVarCodonMerger {
    public struct Output: Sendable, Equatable {
        public var consensus: [MergedVariant]
        public var allHaplotypes: [MergedVariant]
        public init(consensus: [MergedVariant], allHaplotypes: [MergedVariant]) {
            self.consensus = consensus
            self.allHaplotypes = allHaplotypes
        }
    }

    public struct MergedVariant: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case single
            case merged
        }
        public let positions: [Int]
        public let rows: [IVarTSVRow]
        public let kind: Kind
        public init(positions: [Int], rows: [IVarTSVRow], kind: Kind) {
            self.positions = positions
            self.rows = rows
            self.kind = kind
        }
    }

    /// Group adjacent SNPs sharing a codon, evaluate AF rules, emit consensus +
    /// all-haplotype outputs. Indels are passed through unchanged.
    public static func merge(
        rows: [IVarTSVRow],
        consensusAF: Double,
        mergeAFThreshold: Double
    ) -> Output {
        var consensus: [MergedVariant] = []
        var allHaplotypes: [MergedVariant] = []
        let groups = adjacentCodonGroups(rows: rows)
        for group in groups {
            if group.count == 1 {
                let single = MergedVariant(positions: [group[0].pos], rows: [group[0]], kind: .single)
                consensus.append(single)
                continue
            }
            let afs = group.map(\.altFreq)
            if mergeRuleCheck(afs: afs, consensusAF: consensusAF, mergeAFThreshold: mergeAFThreshold) {
                let merged = MergedVariant(positions: group.map(\.pos), rows: group, kind: .merged)
                consensus.append(merged)
            } else {
                for row in group where row.altFreq > consensusAF {
                    consensus.append(MergedVariant(positions: [row.pos], rows: [row], kind: .single))
                }
            }
            // All-haplotype: enumerate every non-all-REF subset.
            let positions = group.map(\.pos)
            let n = group.count
            for mask in 1..<(1 << n) {
                var subset: [IVarTSVRow] = []
                for i in 0..<n where (mask & (1 << i)) != 0 {
                    subset.append(group[i])
                }
                allHaplotypes.append(MergedVariant(positions: subset.map(\.pos), rows: subset, kind: subset.count > 1 ? .merged : .single))
                _ = positions   // retained for future codon-position annotation
            }
        }
        return Output(consensus: consensus, allHaplotypes: allHaplotypes)
    }

    /// Group rows whose positions are consecutive AND share a REF_CODON or ALT_CODON. Indels and rows with no codon info land in singleton groups.
    static func adjacentCodonGroups(rows: [IVarTSVRow]) -> [[IVarTSVRow]] {
        var groups: [[IVarTSVRow]] = []
        var current: [IVarTSVRow] = []
        for row in rows {
            guard row.kind == .snp, row.refCodon != nil || row.altCodon != nil else {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                groups.append([row])
                continue
            }
            if let prev = current.last,
               row.pos == prev.pos + 1,
               (row.refCodon == prev.refCodon || row.altCodon == prev.altCodon) {
                current.append(row)
            } else {
                if !current.isEmpty {
                    groups.append(current)
                }
                current = [row]
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// Mirror of viralrecon's `merge_rule_check`. Returns true if the AF group
    /// should be kept as a single merged record.
    static func mergeRuleCheck(afs: [Double], consensusAF: Double, mergeAFThreshold: Double) -> Bool {
        if afs.allSatisfy({ $0 > consensusAF }) { return true }
        if afs.allSatisfy({ $0 >= 0.4 && $0 <= 0.6 }) { return true }
        let sorted = afs.sorted()
        var maxDist = 0.0
        for i in 0..<(sorted.count - 1) {
            maxDist = max(maxDist, abs(sorted[i + 1] - sorted[i]))
        }
        if maxDist < mergeAFThreshold { return true }
        return false
    }
}
