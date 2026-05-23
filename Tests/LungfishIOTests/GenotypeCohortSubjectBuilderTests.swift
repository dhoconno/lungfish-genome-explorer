import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeCohortSubjectBuilderTests: XCTestCase {
    private func makeResult(samples: [(String, ONTGenotypeQCStatus)],
                            analysis: GenotypeHaplotypeAnalysis? = nil) -> ONTGenotypeResultBundleData {
        let sampleResults = samples.map { name, qc -> ONTGenotypeSampleResult in
            // Construct passedAlignments/passedUniqueReads so ONTGenotypeSampleResult.qcStatus
            // derives the requested status:
            // - .ok requires calls.nonEmpty + passedAlignments >= 20 + passedUniqueReads >= 5
            // - .lowSupport requires calls.nonEmpty + alignments < 20 OR uniqueReads < 5
            // - .review fires when calls empty or alignments==0 or uniqueReads==0
            let call = ONTGenotypeCall(
                sample: name,
                genotype: "01_X_0001",
                passedAlignments: 100,
                passedUniqueReads: 50,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
            switch qc {
            case .ok:
                return ONTGenotypeSampleResult(
                    sample: name, passedAlignments: 100, passedUniqueReads: 50,
                    sampleTotalReads: 50000, sampleUniqueRetainedPercent: nil,
                    calls: [call]
                )
            case .lowSupport:
                return ONTGenotypeSampleResult(
                    sample: name, passedAlignments: 10, passedUniqueReads: 5,
                    sampleTotalReads: 50000, sampleUniqueRetainedPercent: nil,
                    calls: [call]
                )
            case .review:
                return ONTGenotypeSampleResult(
                    sample: name, passedAlignments: 0, passedUniqueReads: 0,
                    sampleTotalReads: 50000, sampleUniqueRetainedPercent: nil,
                    calls: []
                )
            }
        }
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "out",
            analysisName: "Test",
            primaryWorkbookPath: "workbook.xlsx",
            longSummaryCSVPath: "long.csv",
            sampleSummaryCSVPath: "sample.csv",
            statsJSONPath: "stats.json",
            provenancePath: "prov"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: URL(fileURLWithPath: "/tmp/x.xlsx"),
            longSummaryCSVURL: URL(fileURLWithPath: "/tmp/x.csv"),
            sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/y.csv"),
            statsJSONURL: URL(fileURLWithPath: "/tmp/s.json"),
            provenanceURL: URL(fileURLWithPath: "/tmp/p")
        )
        return ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/x.lungfishgenotype"),
            manifest: manifest,
            artifacts: artifacts,
            stats: ONTGenotypeRunStats(),
            calls: [],
            samples: sampleResults,
            haplotypeAnalysis: analysis
        )
    }

    func testProducesOneSubjectPerSample() {
        let result = makeResult(samples: [("S1", .ok), ("S2", .lowSupport)])
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "")
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(result: result, sidecar: sidecar)
        XCTAssertEqual(subjects.count, 2)
        XCTAssertEqual(subjects[0].qcStatus, .ok)
        XCTAssertEqual(subjects[1].qcStatus, .lowSupport)
    }

    func testFoldsAnnotationStateIntoSubject() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "")
        sidecar.sampleNotes.append(.init(sample: "S1", body: "review me", author: "u", timestamp: "t"))
        sidecar.cellHighlights.append(.init(
            sample: "S1", locus: "MHC-A", slot: .h1,
            fillColor: "#FFEB3B", borderColor: nil, author: "u", timestamp: "t"
        ))
        sidecar.sampleStatusFlags.append(.init(sample: "S1", value: .needsReview, author: "u", timestamp: "t"))
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: makeResult(samples: [("S1", .ok)]),
            sidecar: sidecar
        )
        let s1 = subjects.first { $0.animalId == "S1" }
        XCTAssertNotNil(s1)
        XCTAssertTrue(s1?.hasAnyComment ?? false)
        XCTAssertEqual(s1?.statusValue, .needsReview)
        XCTAssertEqual(s1?.highlightFills, ["#FFEB3B"])
    }

    func testHasErrorAtAnyLocusFromAnalysis() {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "MCM",
            speciesName: "MCM",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "S1",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A", sourceLocus: "Mafa-A",
                            haplotype1: "ERR: TMH (M1A)", haplotype2: "ERR: TMH (M1A)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [], observedGenotypeCount: 4,
                            observedGenotypes: []
                        )
                    ]
                )
            ]
        )
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: makeResult(samples: [("S1", .review)], analysis: analysis),
            sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "")
        )
        XCTAssertTrue(subjects.first?.hasErrorAtAnyLocus ?? false)
    }
}
