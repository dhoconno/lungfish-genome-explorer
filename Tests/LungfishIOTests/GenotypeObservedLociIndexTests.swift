import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

final class GenotypeObservedLociIndexTests: XCTestCase {
    private func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        GenotypeTestFixtures.makeCall(sample: sample, genotype: genotype, reads: reads)
    }

    private func makeBundle(calls: [ONTGenotypeCall],
                            analyzedLoci: [String]) -> ONTGenotypeResultBundleData {
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out", analysisName: "Test",
            primaryWorkbookPath: "wb.xlsx", longSummaryCSVPath: "l.csv",
            sampleSummaryCSVPath: "s.csv", statsJSONPath: "s.json",
            provenancePath: "p"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: URL(fileURLWithPath: "/tmp/x.xlsx"),
            longSummaryCSVURL: URL(fileURLWithPath: "/tmp/l.csv"),
            sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/s.csv"),
            statsJSONURL: URL(fileURLWithPath: "/tmp/x.json"),
            provenanceURL: URL(fileURLWithPath: "/tmp/p")
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "test", definitionSetID: "test", definitionSetName: "test",
            speciesName: "test",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S1",
                    calls: analyzedLoci.map { locus in
                        GenotypeHaplotypeLocusCall(
                            locus: locus, sourceLocus: locus,
                            haplotype1: "M1A", haplotype2: "M2A",
                            status: .called, matchedHaplotypes: [],
                            observedGenotypeCount: 0, observedGenotypes: []
                        )
                    }
                )
            ]
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/x.lungfishgenotype"),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: calls,
            samples: [],
            haplotypeAnalysis: analysis
        )
    }

    func testMergesAnalyzedAndObservedLoci() {
        let result = makeBundle(
            calls: [
                makeCall(sample: "S1", genotype: "05_M1M2M3_A1_063g", reads: 100), // → MHC-A
                makeCall(sample: "S2", genotype: "05_M1M2M3_A1_063g", reads: 80),
                makeCall(sample: "S1", genotype: "01_M1_F_01_w_06", reads: 30),   // → MHC-F
            ],
            analyzedLoci: ["MHC-A", "MHC-B"]
        )
        let index = GenotypeObservedLociIndex.build(from: result)
        XCTAssertTrue(index.loci.contains("MHC-A"))
        XCTAssertTrue(index.loci.contains("MHC-B"))
        XCTAssertTrue(index.loci.contains("MHC-F"))
        let mhcA = index.summariesByLocus["MHC-A"]
        XCTAssertEqual(mhcA?.sampleCount, 2)
        XCTAssertTrue(mhcA?.isAnalyzed ?? false)
        let mhcF = index.summariesByLocus["MHC-F"]
        XCTAssertEqual(mhcF?.sampleCount, 1)
        XCTAssertFalse(mhcF?.isAnalyzed ?? true)
    }

    func testAnalyzedLociAppearFirstInOriginalOrder() {
        let result = makeBundle(
            calls: [makeCall(sample: "S1", genotype: "01_M1_F_01_w_06", reads: 1)],
            analyzedLoci: ["MHC-B", "MHC-A", "MHC-DRB"]
        )
        let index = GenotypeObservedLociIndex.build(from: result)
        XCTAssertEqual(Array(index.loci.prefix(3)), ["MHC-B", "MHC-A", "MHC-DRB"])
    }

    /// D2. Two full-length references tied on one 1,000-read cluster and a
    /// 15-read allele are 1,015 reads at the locus, not 2,015. The sample
    /// count and the per-sample call lists keep every tied call.
    func testATiedClusterCountsOnceInTheLocusReadTotal() {
        let tie = ["Mamu-A1*001:01", "Mamu-A1*001:02"]
        let calls = tie.map { reference in
            ONTGenotypeCall(
                sample: "S1", genotype: reference, passedAlignments: 1_000, passedUniqueReads: 1_000,
                sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil,
                overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil,
                ambiguousWith: tie
            )
        } + [makeCall(sample: "S1", genotype: "Mamu-A1*002:01", reads: 15)]
        let index = GenotypeObservedLociIndex.build(from: makeBundle(calls: calls, analyzedLoci: ["MHC-A"]))
        let mhcA = index.summariesByLocus["MHC-A"]
        XCTAssertEqual(mhcA?.totalReads, 1_015)
        XCTAssertEqual(mhcA?.sampleCount, 1)
        XCTAssertEqual(index.observedCallsBySampleAndLocus["S1"]?["MHC-A"]?.count, 3)
    }

    func testGroupsCallsBySampleAndLocus() {
        let result = makeBundle(
            calls: [
                makeCall(sample: "S1", genotype: "05_M1M2M3_A1_063g", reads: 100),
                makeCall(sample: "S1", genotype: "05_M4_A1_031_01", reads: 60),
                makeCall(sample: "S2", genotype: "05_M1M2M3_A1_063g", reads: 80),
            ],
            analyzedLoci: ["MHC-A"]
        )
        let index = GenotypeObservedLociIndex.build(from: result)
        XCTAssertEqual(index.observedCallsBySampleAndLocus["S1"]?["MHC-A"]?.count, 2)
        XCTAssertEqual(index.observedCallsBySampleAndLocus["S2"]?["MHC-A"]?.count, 1)
    }
}
