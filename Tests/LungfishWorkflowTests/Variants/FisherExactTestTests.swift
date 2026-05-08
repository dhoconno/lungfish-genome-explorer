import Testing
@testable import LungfishWorkflow

@Suite("FisherExactTest")
struct FisherExactTestTests {
    @Test("matches scipy two-sided p-value for balanced 2x2")
    func balancedTable() throws {
        // scipy.stats.fisher_exact([[10,10],[10,10]], alternative='two-sided')
        // p-value ~ 1.0
        let p = FisherExactTest.twoSidedPValue(a: 10, b: 10, c: 10, d: 10)
        #expect(abs(p - 1.0) < 1e-9)
    }

    @Test("matches scipy for clear strand bias")
    func clearStrandBias() throws {
        // scipy.stats.fisher_exact([[20,0],[0,20]], alternative='two-sided')
        // p-value ~ 5.4e-11
        let p = FisherExactTest.twoSidedPValue(a: 20, b: 0, c: 0, d: 20)
        #expect(p < 1e-10)
    }

    @Test("matches scipy for moderate imbalance")
    func moderateImbalance() throws {
        // scipy.stats.fisher_exact([[8,2],[1,9]], alternative='two-sided')
        // p-value ~ 0.005477494641581329
        let p = FisherExactTest.twoSidedPValue(a: 8, b: 2, c: 1, d: 9)
        #expect(abs(p - 0.005477494641581329) < 1e-9)
    }

    @Test("returns 1.0 for empty table")
    func emptyTable() throws {
        let p = FisherExactTest.twoSidedPValue(a: 0, b: 0, c: 0, d: 0)
        #expect(p == 1.0)
    }

    @Test("handles very large counts without overflow")
    func largeCounts() throws {
        // scipy.stats.fisher_exact([[1000,1000],[1000,1000]], alternative='two-sided')
        // p-value ~ 1.0
        let p = FisherExactTest.twoSidedPValue(a: 1000, b: 1000, c: 1000, d: 1000)
        #expect(abs(p - 1.0) < 1e-9)
    }

    // MARK: - one-sided "greater" (covers production strand-bias path)
    //
    // Reference values were produced with:
    //   scipy.stats.fisher_exact(table, alternative='greater').pvalue
    // and hardcoded to keep the Swift tests deterministic and offline.

    @Test("greater: matches scipy for balanced 2x2")
    func greaterBalancedTable() throws {
        // scipy.stats.fisher_exact([[10,10],[10,10]], alternative='greater')
        // p-value ~ 0.6238144327180455
        let p = FisherExactTest.oneSidedGreaterPValue(a: 10, b: 10, c: 10, d: 10)
        #expect(abs(p - 0.6238144327180455) < 1e-9)
    }

    @Test("greater: matches scipy for clearly greater table")
    func greaterClearlyGreater() throws {
        // scipy.stats.fisher_exact([[20,0],[0,20]], alternative='greater')
        // p-value ~ 7.254444551924844e-12
        let p = FisherExactTest.oneSidedGreaterPValue(a: 20, b: 0, c: 0, d: 20)
        let expected = 7.254444551924844e-12
        // Tiny p-values: use ratio tolerance, like scipy.
        #expect(abs(p - expected) / expected < 1e-9)
    }

    @Test("greater: returns ~1.0 for clearly less table")
    func greaterClearlyLess() throws {
        // scipy.stats.fisher_exact([[0,20],[20,0]], alternative='greater')
        // p-value = 1.0
        let p = FisherExactTest.oneSidedGreaterPValue(a: 0, b: 20, c: 20, d: 0)
        #expect(abs(p - 1.0) < 1e-9)
    }

    @Test("greater: returns 1.0 for empty table")
    func greaterEmptyTable() throws {
        let p = FisherExactTest.oneSidedGreaterPValue(a: 0, b: 0, c: 0, d: 0)
        #expect(p == 1.0)
    }

    @Test("greater: detects amplicon-style strand bias")
    func greaterAmpliconStrandBias() throws {
        // Real-world strand-bias case where REF is entirely forward-strand and
        // ALT is mixed: [[REF_FWD=100, REF_REV=0], [ALT_FWD=100, ALT_REV=100]].
        // scipy.stats.fisher_exact([[100,0],[100,100]], alternative='greater')
        // p-value ~ 2.1775622627965357e-23
        let p = FisherExactTest.oneSidedGreaterPValue(a: 100, b: 0, c: 100, d: 100)
        let expected = 2.1775622627965357e-23
        #expect(abs(p - expected) / expected < 1e-9)
        // And of course p < 0.05 — this should fire the strand-bias filter.
        #expect(p < 0.05)
    }
}
