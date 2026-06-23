import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeCohortSubjectBuilderTests: XCTestCase {
    private func makeResult(samples: [(String, ONTGenotypeQCStatus)],
                            analysis: GenotypeHaplotypeAnalysis? = nil) -> ONTGenotypeResultBundleData {
        let sampleResults = samples.map { name, qc -> ONTGenotypeSampleResult in
            // Construct passedAlignments/passedUniqueReads so ONTGenotypeSampleResult.qcStatus
            // derives the requested status:
            // - .ok requires calls.nonEmpty + passedAlignments >= 20 + passedUniqueReads >= 1000
            // - .lowSupport requires calls.nonEmpty + alignments < 20 OR uniqueReads < 1000
            // - .review fires when calls empty or alignments==0 or uniqueReads==0
            let call = ONTGenotypeCall(
                sample: name,
                genotype: "01_X_0001",
                passedAlignments: 1_500,
                passedUniqueReads: 1_500,
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
                    sample: name, passedAlignments: 1_500, passedUniqueReads: 1_500,
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

    private func makeResultWithoutSampleSummaries(calls: [ONTGenotypeCall]) -> ONTGenotypeResultBundleData {
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
            calls: calls,
            samples: [],
            haplotypeAnalysis: nil
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

    func testDerivesFallbackQCFromRawCallsWhenSampleSummaryIsMissing() {
        let calls = [
            ONTGenotypeCall(
                sample: "S1",
                genotype: "12_M1_B_046_01_01",
                passedAlignments: 1_500,
                passedUniqueReads: 1_500,
                sampleTotalReads: 2_000,
                sampleUniqueRetainedReads: 1_500,
                sampleUniqueRetainedPercent: 75.0,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "S2",
                genotype: "12_M2_B_019_03",
                passedAlignments: 10,
                passedUniqueReads: 4,
                sampleTotalReads: 2000,
                sampleUniqueRetainedReads: 10,
                sampleUniqueRetainedPercent: 0.5,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: makeResultWithoutSampleSummaries(calls: calls),
            sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "")
        )

        XCTAssertEqual(subjects.map(\.animalId), ["S1", "S2"])
        XCTAssertEqual(subjects.map(\.qcStatus), [.ok, .lowSupport])
        XCTAssertEqual(subjects.map(\.totalReads), [2000, 2000])
    }

    func testCarriesImportedMetadataIntoSmartCohortSubjects() {
        let result = makeResult(samples: [("DW472", .ok), ("DW473", .ok)])
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "")
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: result,
            sidecar: sidecar,
            metadataBySample: [
                "DW472": ["Cohort": "Kenyon20", "Animal ID": "H18C153"],
                "DW473": ["Cohort": "Indonesia", "Animal ID": "H18C174"],
            ]
        )

        let predicate = SmartCohortPredicate.metadataFieldContains(field: "Cohort", value: "Kenyon20")
        XCTAssertEqual(subjects.filter { predicate.evaluate($0) }.map(\.animalId), ["DW472"])
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

    func testCallOverridesFeedCohortCallsAndErrorState() {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "MCM",
            speciesName: "MCM",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B", sourceLocus: "Mafa-B",
                            haplotype1: "M3B", haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [], observedGenotypeCount: 2,
                            observedGenotypes: []
                        )
                    ]
                )
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "")
        sidecar.callOverrides.append(.init(
            sample: "DW472",
            locus: "MHC-B",
            slot: .h2,
            originalCall: "-",
            overrideCall: "M2B",
            reasonTag: .misCall,
            rationale: "Promoted from Review inspector.",
            author: "u",
            timestamp: "t"
        ))

        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: makeResult(samples: [("DW472", .ok)], analysis: analysis),
            sidecar: sidecar
        )
        let subject = subjects.first

        XCTAssertEqual(subject?.calls.map(\.name), ["M3B", "M2B"])
        XCTAssertFalse(subject?.isHomozygousAcrossAll ?? true)
        XCTAssertFalse(subject?.hasErrorAtAnyLocus ?? true)
    }

    func testNotAssayedCallsAreNeutralForHomozygousCohortState() {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "MCM",
            speciesName: "MCM",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DPB", sourceLocus: "Mafa-DPB",
                            haplotype1: "Not assayed", haplotype2: "Not assayed",
                            status: .notAssayed,
                            matchedHaplotypes: [], observedGenotypeCount: 0,
                            observedGenotypes: []
                        )
                    ]
                )
            ]
        )

        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: makeResult(samples: [("DW474", .ok)], analysis: analysis),
            sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "")
        )
        let subject = subjects.first

        XCTAssertFalse(subject?.hasErrorAtAnyLocus ?? true)
        XCTAssertFalse(subject?.isHomozygousAcrossAll ?? true)
        XCTAssertEqual(subject?.calls.map(\.isHomozygous), [false, false])
    }

    func testNotAssayedCallsDoNotPreventCalledLociFromBeingHomozygous() {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "MCM",
            speciesName: "MCM",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A", sourceLocus: "Mafa-A",
                            haplotype1: "M1A", haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [], observedGenotypeCount: 2,
                            observedGenotypes: ["01_M1_F_01_w_06", "11_M1_E_02g3"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DPB", sourceLocus: "Mafa-DPB",
                            haplotype1: "Not assayed", haplotype2: "Not assayed",
                            status: .notAssayed,
                            matchedHaplotypes: [], observedGenotypeCount: 0,
                            observedGenotypes: []
                        )
                    ]
                )
            ]
        )

        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: makeResult(samples: [("DW474", .ok)], analysis: analysis),
            sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "")
        )

        XCTAssertTrue(subjects.first?.isHomozygousAcrossAll ?? false)
    }
}
