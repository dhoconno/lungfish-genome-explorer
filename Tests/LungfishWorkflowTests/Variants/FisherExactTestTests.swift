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
}
