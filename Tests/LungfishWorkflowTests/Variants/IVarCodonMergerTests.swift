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
        #expect(result.consensus.count == 1)        // The first row is above consensusAF
        #expect(result.consensus[0].positions == [100])
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
}
