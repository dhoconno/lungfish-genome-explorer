import Testing
@testable import LungfishWorkflow

@Suite("IVarCodonMerger")
struct IVarCodonMergerTests {
    private func snp(pos: Int, ref: String, alt: String, freq: Double, dp: Int = 100, refCodon: String?, altCodon: String?) -> IVarTSVRow {
        IVarTSVRow(
            region: "MN908947.3",
            pos: pos,
            ref: ref,
            alt: alt,
            refDP: max(0, dp - Int(Double(dp) * freq)),
            refRV: 0,
            refQual: 38,
            altDP: Int(Double(dp) * freq),
            altRV: 0,
            altQual: 38,
            altFreq: freq,
            totalDP: dp,
            pval: 0.0,
            pass: true,
            gffFeature: "gene",
            refCodon: refCodon,
            refAA: nil,
            altCodon: altCodon,
            altAA: nil,
            posAA: nil,
            kind: .snp
        )
    }

    @Test("two adjacent SNPs sharing a codon merge into one consensus row")
    func twoAdjacentSNPsMerge() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.94, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 1)
        let merged = result.consensus[0]
        #expect(merged.kind == .merged)
        #expect(merged.positions == [100, 101])
    }

    @Test("two adjacent SNPs with divergent AFs split into individual rows")
    func divergentAFsSplit() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.10, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        // Both members stay, each as its own record. Before the F6 fix the 0.10 member was dropped.
        #expect(result.consensus.map(\.positions) == [[100], [101]])
        #expect(result.consensus.map { $0.rows[0].altFreq } == [0.95, 0.10])
    }

    @Test("non-adjacent SNPs do not merge even with same codon attribute")
    func nonAdjacentDoNotMerge() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 105, ref: "C", alt: "T", freq: 0.94, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 2)
        #expect(result.consensus.allSatisfy { $0.positions.count == 1 })
    }

    @Test("rows missing codon info are passed through unchanged")
    func missingCodonInfoPassThrough() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.95, refCodon: nil, altCodon: nil),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.94, refCodon: nil, altCodon: nil),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.count == 2)
    }

    @Test("all-haplotype output enumerates 2^n combinations for two adjacent SNPs")
    func allHaplotypes() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.5, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.5, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        // 2 positions × 2 states (REF, ALT) − 1 (all-REF) = 3 viable combinations
        #expect(result.allHaplotypes.count >= 3)
    }

    // MARK: F6 (IVAR-CODON-MERGE)
    //
    // A group of changes in one codon becomes one merged record only when every member is above
    // consensusAF. Every other group writes each member as its own record, with the frequency and
    // the depth that iVar measured for it. BIO ruled this in BIO-F5-READ-ORDER, Question 3.

    private static let ivarHeader = "REGION\tPOS\tREF\tALT\tREF_DP\tREF_RV\tREF_QUAL\tALT_DP\tALT_RV\tALT_QUAL\tALT_FREQ\tTOTAL_DP\tPVAL\tPASS\tGFF_FEATURE\tREF_CODON\tREF_AA\tALT_CODON\tALT_AA\tPOS_AA"

    /// The first annotation row of NC_002017.1 469 and 470 in the iVar 1.4.4 TSV of PR8 (SRR5428776), copied
    /// from the hand run's `ivar.tsv`. iVar writes nine rows for each of the two positions, one for each CDS,
    /// and the converter keeps the first one, so these two rows are what the merger gets. Both carry
    /// ALT_CODON AAA, so they form one group.
    private static let pr8Rows = [
        "NC_002017.1\t469\tC\tA\t6179\t2538\t43\t2630\t1313\t39\t0.295572\t8898\t0\tTRUE\tM1:cds-NP_040978.1\tAAC\tN\tAAA\tK\t148",
        "NC_002017.1\t470\tC\tA\t6696\t2853\t44\t705\t505\t31\t0.0948601\t7432\t0\tTRUE\tM1:cds-NP_040978.1\tCAA\tQ\tAAA\tK\t149",
    ]

    @Test("PR8 469 C>A at 0.295572 and 470 C>A at 0.0948601 stay two records")
    func pr8NeighbouringChangesStayTwoRecords() throws {
        let rows = try Self.pr8Rows.map { try #require(IVarTSVRow.parse(line: $0, header: Self.ivarHeader)) }
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        // At the base commit the pair was one merged record `469 CC>AA` at the lower frequency, 0.0948601.
        #expect(result.consensus.map(\.positions) == [[469], [470]])
        #expect(result.consensus.map(\.kind) == [.single, .single])
        #expect(result.consensus.map { $0.rows[0].altFreq } == [0.295572, 0.0948601])
        #expect(result.consensus.map { $0.rows[0].totalDP } == [8898, 7432])
        // The all-haplotypes list is not part of the fix.
        #expect(result.allHaplotypes.map(\.positions) == [[469], [470], [469, 470]])
    }

    @Test("two minor changes of one codon at 0.30 and 0.04 are both kept")
    func twoMinorChangesOfOneCodonAreBothKept() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.30, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.04, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        // At the base commit the merge rule failed and the filter kept only members above consensusAF,
        // so neither change reached the primary list.
        #expect(result.consensus.map(\.positions) == [[100], [101]])
        #expect(result.consensus.map { $0.rows[0].altFreq } == [0.30, 0.04])
    }

    @Test("two changes of one codon at 0.98 and 0.97 still merge into one record")
    func twoMajorChangesOfOneCodonStillMerge() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.98, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.97, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.map(\.positions) == [[100, 101]])
        #expect(result.consensus.map(\.kind) == [.merged])
    }

    @Test("a change at exactly the consensus frequency is not above it, so the pair stays apart")
    func changeAtConsensusFrequencyDoesNotMerge() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.75, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.90, refCodon: "GCT", altCodon: "ATT"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        #expect(result.consensus.map(\.positions) == [[100], [101]])
    }

    @Test("a group with one minor member is never merged and loses no member")
    func groupWithOneMinorMemberKeepsEveryMember() throws {
        let rows = [
            snp(pos: 100, ref: "G", alt: "A", freq: 0.99, refCodon: "GCT", altCodon: "ACT"),
            snp(pos: 101, ref: "C", alt: "T", freq: 0.98, refCodon: "GCT", altCodon: "ATT"),
            snp(pos: 102, ref: "T", alt: "G", freq: 0.20, refCodon: "GCT", altCodon: "ATG"),
        ]
        let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
        // At the base commit the 0.20 member was dropped and the other two were written apart.
        #expect(result.consensus.map(\.positions) == [[100], [101], [102]])
        #expect(result.consensus.map { $0.rows[0].altFreq } == [0.99, 0.98, 0.20])
    }

    @Test("pairs that the 0.4 to 0.6 rule and the distance rule used to merge stay apart")
    func halfAndNearbyFrequenciesNoLongerMerge() throws {
        let cases: [(Double, Double)] = [(0.50, 0.50), (0.30, 0.28)]
        for (first, second) in cases {
            let rows = [
                snp(pos: 100, ref: "G", alt: "A", freq: first, refCodon: "GCT", altCodon: "ACT"),
                snp(pos: 101, ref: "C", alt: "T", freq: second, refCodon: "GCT", altCodon: "ATT"),
            ]
            let result = IVarCodonMerger.merge(rows: rows, consensusAF: 0.75, mergeAFThreshold: 0.25)
            #expect(result.consensus.map(\.positions) == [[100], [101]], "frequencies \(first) and \(second)")
        }
    }
}
