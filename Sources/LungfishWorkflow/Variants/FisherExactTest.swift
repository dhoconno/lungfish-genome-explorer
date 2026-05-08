// FisherExactTest.swift - Pure-Swift Fisher's exact test for 2x2 contingency tables.
// Uses log-gamma to avoid overflow for large counts. Provides both two-sided and
// one-sided ("greater") variants matching scipy.stats.fisher_exact.

import Foundation

public enum FisherExactTest {
    /// Two-sided Fisher's exact p-value for a 2x2 table:
    ///
    ///     [[a, b],
    ///      [c, d]]
    ///
    /// Uses the standard "sum of probabilities <= observed" definition. Returns
    /// 1.0 for the degenerate all-zeros table.
    public static func twoSidedPValue(a: Int, b: Int, c: Int, d: Int) -> Double {
        let n = a + b + c + d
        if n == 0 { return 1.0 }

        let row1 = a + b
        let row2 = c + d
        let col1 = a + c
        let col2 = b + d

        // Probability of a single 2x2 table with given marginals having `a` in cell (0,0):
        //     P(a) = C(row1, a) * C(row2, col1 - a) / C(n, col1)
        //          = exp( lgamma(row1+1) + lgamma(row2+1) + lgamma(col1+1) + lgamma(col2+1)
        //                 - lgamma(n+1)
        //                 - lgamma(a+1) - lgamma(b+1) - lgamma(c+1) - lgamma(d+1) )
        //
        // Constant factor depending only on the marginals:
        let logMarginalsConstant =
            lgamma(Double(row1 + 1))
            + lgamma(Double(row2 + 1))
            + lgamma(Double(col1 + 1))
            + lgamma(Double(col2 + 1))
            - lgamma(Double(n + 1))

        func logP(forA aValue: Int) -> Double {
            let bValue = row1 - aValue
            let cValue = col1 - aValue
            let dValue = row2 - cValue
            if aValue < 0 || bValue < 0 || cValue < 0 || dValue < 0 {
                return -.infinity
            }
            return logMarginalsConstant
                - lgamma(Double(aValue + 1))
                - lgamma(Double(bValue + 1))
                - lgamma(Double(cValue + 1))
                - lgamma(Double(dValue + 1))
        }

        let logPObserved = logP(forA: a)
        // Two-sided: sum probabilities of all tables with same marginals whose
        // probability is <= observed. Use a small epsilon to handle ties robustly.
        let epsilon = 1e-12
        let lowA = max(0, col1 - row2)
        let highA = min(row1, col1)

        var sum = 0.0
        for candidate in lowA...highA {
            let lp = logP(forA: candidate)
            if lp <= logPObserved + epsilon {
                sum += exp(lp)
            }
        }
        return min(1.0, sum)
    }

    /// One-sided "greater" Fisher's exact p-value matching
    /// `scipy.stats.fisher_exact(table, alternative="greater")`.
    ///
    /// Returns the probability of seeing a 2x2 table at least as extreme in the
    /// "greater" direction (more weight in cell (0,0) given the marginals)
    /// as the observed table. Returns 1.0 for the degenerate all-zeros table.
    public static func oneSidedGreaterPValue(a: Int, b: Int, c: Int, d: Int) -> Double {
        let n = a + b + c + d
        if n == 0 { return 1.0 }

        let row1 = a + b
        let row2 = c + d
        let col1 = a + c
        let col2 = b + d

        let logMarginalsConstant =
            lgamma(Double(row1 + 1))
            + lgamma(Double(row2 + 1))
            + lgamma(Double(col1 + 1))
            + lgamma(Double(col2 + 1))
            - lgamma(Double(n + 1))

        func logP(forA aValue: Int) -> Double {
            let bValue = row1 - aValue
            let cValue = col1 - aValue
            let dValue = row2 - cValue
            if aValue < 0 || bValue < 0 || cValue < 0 || dValue < 0 {
                return -.infinity
            }
            return logMarginalsConstant
                - lgamma(Double(aValue + 1))
                - lgamma(Double(bValue + 1))
                - lgamma(Double(cValue + 1))
                - lgamma(Double(dValue + 1))
        }

        // "greater" => sum probabilities for a' >= a (more weight in cell (0,0)
        // given the fixed marginals)
        let highA = min(row1, col1)
        var sum = 0.0
        for candidate in a...highA where candidate >= 0 {
            sum += exp(logP(forA: candidate))
        }
        return min(1.0, sum)
    }
}
