import XCTest
@testable import LungfishGenotypeUI
import LungfishIO

final class GenotypeMatrixBaseProjectionTests: XCTestCase {
    func testBaseProjectionPreservesOccurrenceSupportAndZeroVersusMissingRetainedDenominators() {
        let duplicateLow = makeCall(
            sample: "S1",
            genotype: "Mafa-A1*001:01",
            reads: 4,
            retainedReads: 0
        )
        let duplicateHigh = makeCall(
            sample: "S1",
            genotype: "Mafa-A1*001:01",
            reads: 16,
            retainedReads: nil
        )
        let projection = GenotypeMatrixBaseProjection(
            calls: [duplicateLow, duplicateHigh],
            samples: [],
            candidateDocument: nil,
            logicalSampleNames: ["S1"],
            candidateSettings: .default
        )

        XCTAssertEqual(projection.knownOccurrences.count, 2)
        XCTAssertEqual(projection.knownOccurrences.map(\.support.passedUniqueReads), [4, 16])
        XCTAssertEqual(projection.knownOccurrences[0].sampleRetainedDenominator, 0)
        XCTAssertNil(projection.knownOccurrences[1].sampleRetainedDenominator)
        XCTAssertEqual(projection.knownOccurrences.map(\.viewedLocusDenominator), [20, 20])

        let unfiltered = projection.derive(.unfiltered)
        let row = unfiltered.rows.first { $0.genotype == "Mafa-A1*001:01" }
        XCTAssertEqual(row?.sampleSupport.map(\.passedUniqueReads), [16, 4])
        XCTAssertEqual(unfiltered.hiddenCellCount, 0)

        let readFiltered = projection.derive(.init(matrixMinimumReads: 10))
        XCTAssertEqual(
            readFiltered.rows.first { $0.genotype == "Mafa-A1*001:01" }?
                .sampleSupport.map(\.passedUniqueReads),
            [16]
        )
        XCTAssertEqual(readFiltered.hiddenCellCount, 1)
    }

    func testDerivedProjectionMatchesLegacyOccurrenceFilteringForBothDenominators() {
        let calls = [
            makeCall(sample: "S1", genotype: "Mafa-A1*001:01", reads: 20, retainedReads: 40),
            makeCall(sample: "S1", genotype: "Mafa-A1*002:01", reads: 80, retainedReads: nil),
            makeCall(sample: "S2", genotype: "Mafa-A1*001:01", reads: 10, retainedReads: nil),
            makeCall(sample: "S2", genotype: "Mafa-A1*003:01", reads: 90, retainedReads: nil),
        ]
        let samples = [
            makeSample("S1", retainedReads: 200),
            makeSample("S2", retainedReads: 100),
        ]
        let projection = GenotypeMatrixBaseProjection(
            calls: calls,
            samples: samples,
            candidateDocument: nil,
            logicalSampleNames: ["S1", "S2"],
            candidateSettings: .default
        )

        let viewedLocus = projection.derive(.init(
            globalMinimumPercent: 15,
            globalDenominator: .viewedLocus
        ))
        XCTAssertEqual(Set(viewedLocus.rows.map(\.genotype)), [
            "Mafa-A1*001:01",
            "Mafa-A1*002:01",
            "Mafa-A1*003:01",
        ])
        XCTAssertEqual(
            viewedLocus.rows.first { $0.genotype == "Mafa-A1*001:01" }?
                .sampleSupport.map(\.sample),
            ["S1"]
        )

        let retained = projection.derive(.init(
            globalMinimumPercent: 45,
            globalDenominator: .sampleRetained
        ))
        XCTAssertEqual(Set(retained.rows.map(\.genotype)), [
            "Mafa-A1*001:01",
            "Mafa-A1*003:01",
        ])
        XCTAssertEqual(
            retained.rows.first { $0.genotype == "Mafa-A1*001:01" }?
                .sampleSupport.map(\.sample),
            ["S1"]
        )
    }

    func testDerivedProjectionCombinesGlobalMatrixPercentAndReadThresholdsPerOccurrence() {
        let calls = [
            makeCall(sample: "S1", genotype: "Mafa-A1*001:01", reads: 30, retainedReads: 100),
            makeCall(sample: "S1", genotype: "Mafa-A1*002:01", reads: 70, retainedReads: 100),
            makeCall(sample: "S2", genotype: "Mafa-A1*001:01", reads: 60, retainedReads: 200),
            makeCall(sample: "S2", genotype: "Mafa-A1*003:01", reads: 40, retainedReads: 200),
        ]
        let projection = GenotypeMatrixBaseProjection(
            calls: calls,
            samples: [],
            candidateDocument: nil,
            logicalSampleNames: ["S1", "S2"],
            candidateSettings: .default
        )

        let derived = projection.derive(.init(
            globalMinimumPercent: 25,
            globalDenominator: .viewedLocus,
            matrixMinimumReads: 50,
            matrixMinimumPercent: 30,
            matrixDenominator: .sampleRetained
        ))

        XCTAssertEqual(Set(derived.rows.map(\.genotype)), [
            "Mafa-A1*002:01",
            "Mafa-A1*001:01",
        ])
        XCTAssertEqual(
            derived.rows.first { $0.genotype == "Mafa-A1*001:01" }?
                .sampleSupport.map(\.sample),
            ["S2"]
        )
        XCTAssertEqual(derived.hiddenCellCount, 2)
    }

    func testDerivedProjectionAppliesPopulationAndReadThresholdsToKnownAndCandidateRows() {
        let document = makeCandidateDocument()
        let projection = GenotypeMatrixBaseProjection(
            calls: [
                makeCall(sample: "S1", genotype: "Mafa-A1*001:01", reads: 60, retainedReads: 100),
            ],
            samples: [],
            candidateDocument: document,
            logicalSampleNames: ["S1", "S2", "S3", "S4"],
            candidateSettings: .default
        )

        let populationFiltered = projection.derive(.init(
            matrixMinimumPercent: 30,
            matrixDenominator: .sampleRetained
        ))
        XCTAssertEqual(Set(populationFiltered.rows.map(\.genotype)), [
            "Mafa-A1*001:01",
            "Mafa-A1*900:01_nov",
        ])

        let readFiltered = projection.derive(.init(matrixMinimumReads: 8))
        let sharedCandidate = readFiltered.rows.first { $0.stableClusterID == "shared" }
        XCTAssertEqual(sharedCandidate?.sampleSupport.map(\.sample), ["S2"])
        XCTAssertNil(readFiltered.rows.first { $0.stableClusterID == "singleton" })
        XCTAssertEqual(readFiltered.hiddenCellCount, 2)
    }

    func testCandidateTintChangesDoNotChangeBaseProjectionIdentityOrDerivedRows() {
        let document = makeCandidateDocument()
        let original = GenotypeMatrixBaseProjection(
            calls: [],
            samples: [],
            candidateDocument: document,
            logicalSampleNames: ["S1", "S2", "S3", "S4"],
            candidateSettings: .default
        )
        var tintedSettings = ONTMHCCandidateDisplaySettings.default
        tintedSettings.tints[.sharedNovel] = AnnotationColor(hex: "#123456")!
        let tinted = GenotypeMatrixBaseProjection(
            calls: [],
            samples: [],
            candidateDocument: document,
            logicalSampleNames: ["S1", "S2", "S3", "S4"],
            candidateSettings: tintedSettings
        )

        XCTAssertEqual(original.scientificIdentity, tinted.scientificIdentity)
        XCTAssertEqual(original.derive(.unfiltered).rows, tinted.derive(.unfiltered).rows)
    }

    func testIncompleteReferenceSpanCandidateRemainsReviewableWithoutExternalSequence() throws {
        let candidate = makeCandidate(
            id: "partial-drb",
            name: "Mamu-DRB*W001:01_1nt_nov",
            support: .singleton,
            samples: ["CN29"]
        )
        let artifact = ONTMHCArtifactReference(
            path: "unnameable.fasta",
            sha256: String(repeating: "c", count: 64),
            sizeBytes: 1
        )
        let document = ONTMHCUnnameableClustersDocument(
            schemaVersion: 4,
            createdAt: "2026-08-02T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: artifact,
            clusters: [
                ONTMHCUnnameableRecord(
                    stableClusterID: candidate.stableClusterID,
                    reason: .incompleteReferenceSpan,
                    failedMetrics: ["reference_coverage": 0.4],
                    supportClass: .singleton,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 267,
                    supportingSampleIDs: ["CN29"],
                    reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                        bamPath: "reciprocal.bam",
                        queryName: candidate.stableClusterID,
                        alignmentCount: 1,
                        targetAlignmentCounts: [candidate.closestReferenceName: 1],
                        exactMatchTargetNames: [],
                        closestMatchTargetNames: [candidate.closestReferenceName]
                    ),
                    selectedEvidence: nil,
                    candidateInterpretation: .init(candidate: candidate)
                ),
                ONTMHCUnnameableRecord(
                    stableClusterID: "unclassified",
                    reason: .noAlignment,
                    failedMetrics: [:],
                    supportClass: .singleton,
                    independentSampleCount: 1,
                    occurrenceCount: 1,
                    totalClusterReads: 10,
                    supportingSampleIDs: ["CN29"],
                    reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                        bamPath: "reciprocal.bam",
                        queryName: "unclassified",
                        alignmentCount: 0,
                        targetAlignmentCounts: [:],
                        exactMatchTargetNames: [],
                        closestMatchTargetNames: []
                    ),
                    selectedEvidence: nil
                ),
            ],
            observations: [
                makeObservation(cluster: candidate.stableClusterID, sample: "CN29", reads: 267),
                makeObservation(cluster: "unclassified", sample: "CN29", reads: 10),
            ]
        )

        let projection = GenotypeMatrixBaseProjection(
            calls: [],
            samples: [],
            candidateDocument: nil,
            unnameableDocument: document,
            logicalSampleNames: ["CN29"],
            candidateSettings: .default
        )
        let derived = projection.derive(.unfiltered)

        XCTAssertEqual(derived.rows.map(\.stableClusterID), ["partial-drb"])
        XCTAssertEqual(derived.rows.first?.genotype, "Mamu-DRB*W001:01_1nt_nov")
        XCTAssertEqual(derived.rows.first?.sampleSupport.first?.passedUniqueReads, 267)
        XCTAssertEqual(derived.rows.first?.incompleteCandidateInterpretation?.classification, .novel)
        XCTAssertNil(derived.rows.first?.candidate)
        XCTAssertEqual(derived.totalRowCount, 1)
        XCTAssertEqual(derived.hiddenCellCount, 0)
    }

    func testCachedProjectionMatchesLegacyOracleAcrossScientificEdgeCases() {
        let calls = [
            makeCall(sample: "S0", genotype: "Mafa-A1*000:01", reads: 0, retainedReads: 0),
            makeCall(sample: "SMissing", genotype: "Mafa-A1*099:01", reads: 5, retainedReads: nil),
            makeCall(sample: "S1", genotype: "Mafa-A1*001:01", reads: 4, retainedReads: 100),
            makeCall(sample: "S1", genotype: "Mafa-A1*001:01", reads: 16, retainedReads: nil),
            makeCall(sample: "S1", genotype: "Mafa-A1*002:01", reads: 80, retainedReads: nil),
            makeCall(sample: "S2", genotype: "Mafa-A1*001:01", reads: 10, retainedReads: nil),
            makeCall(sample: "S2", genotype: "Mafa-A1*003:01", reads: 90, retainedReads: nil),
        ]
        let samples = [
            makeSample("S0", retainedReads: 0),
            makeSample("S1", retainedReads: 100),
            makeSample("S2", retainedReads: 100),
        ]
        let logicalSamples = ["S0", "SMissing", "S1", "S2", "S3", "S4"]
        let candidateDocument = makeCandidateDocument()
        let settings = ONTMHCCandidateDisplaySettings.default
        let cached = GenotypeMatrixBaseProjection(
            calls: calls,
            samples: samples,
            candidateDocument: candidateDocument,
            logicalSampleNames: logicalSamples,
            candidateSettings: settings
        )
        let filters: [GenotypeMatrixBaseProjection.Filter] = [
            .unfiltered,
            .init(matrixMinimumReads: 8),
            .init(globalMinimumPercent: 10, globalDenominator: .viewedLocus),
            .init(globalMinimumPercent: 10, globalDenominator: .sampleRetained),
            .init(matrixMinimumPercent: 20, matrixDenominator: .viewedLocus),
            .init(matrixMinimumPercent: 20, matrixDenominator: .sampleRetained),
            .init(
                globalMinimumPercent: 10,
                globalDenominator: .viewedLocus,
                matrixMinimumReads: 8,
                matrixMinimumPercent: 20,
                matrixDenominator: .sampleRetained
            ),
        ]

        for filter in filters {
            let expected = legacyProjection(
                calls: calls,
                samples: samples,
                candidateDocument: candidateDocument,
                logicalSampleNames: logicalSamples,
                settings: settings,
                filter: filter
            )
            let actual = cached.derive(filter)
            XCTAssertEqual(actual.rows, expected.rows, "rows for \(filter)")
            XCTAssertEqual(actual.totalRowCount, expected.totalRowCount, "total rows for \(filter)")
            XCTAssertEqual(actual.hiddenCellCount, expected.hiddenCellCount, "hidden cells for \(filter)")
        }
        for denominator in ONTGenotypeSupportDenominator.allCases {
            XCTAssertEqual(
                cached.supportFractions(for: denominator),
                legacySupportFractions(
                    calls: calls,
                    samples: samples,
                    candidateDocument: candidateDocument,
                    logicalSampleNames: logicalSamples,
                    denominator: denominator
                ),
                "fractions for \(denominator)"
            )
        }

        let retainedFiltered = cached.derive(.init(
            globalMinimumPercent: 1,
            globalDenominator: .sampleRetained
        ))
        XCTAssertFalse(retainedFiltered.rows.contains {
            $0.genotype == "Mafa-A1*000:01"
                || $0.genotype == "Mafa-A1*099:01"
                || $0.stableClusterID == "unsupported"
        })
    }

    private struct LegacyProjection {
        let rows: [GenotypeCandidateMatrixRow]
        let totalRowCount: Int
        let hiddenCellCount: Int
    }

    private func legacyProjection(
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        candidateDocument: ONTMHCCandidateAllelesDocument?,
        logicalSampleNames: [String],
        settings: ONTMHCCandidateDisplaySettings,
        filter: GenotypeMatrixBaseProjection.Filter
    ) -> LegacyProjection {
        let retainedBySample = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.sample, $0.passedUniqueReads) }
        )
        let viewedDenominators = Dictionary(grouping: calls) {
            "\($0.sample)\u{0}\($0.locusGroup)"
        }.mapValues { $0.reduce(0) { $0 + $1.passedUniqueReads } }
        func fraction(
            _ call: ONTGenotypeCall,
            denominator: ONTGenotypeSupportDenominator
        ) -> Double? {
            let value: Int?
            switch denominator {
            case .viewedLocus:
                value = viewedDenominators["\(call.sample)\u{0}\(call.locusGroup)"]
            case .sampleRetained:
                value = call.sampleUniqueRetainedReads ?? retainedBySample[call.sample]
            }
            guard let value, value > 0 else { return nil }
            return Double(call.passedUniqueReads) / Double(value)
        }
        let globalThreshold = filter.globalMinimumPercent / 100
        let matrixThreshold = filter.matrixMinimumPercent / 100
        let filteredCalls = calls.filter { call in
            if globalThreshold > 0,
               (fraction(call, denominator: filter.globalDenominator) ?? -.infinity)
                < globalThreshold {
                return false
            }
            if matrixThreshold > 0,
               (fraction(call, denominator: filter.matrixDenominator) ?? -.infinity)
                < matrixThreshold {
                return false
            }
            return filter.matrixMinimumReads == 0
                || call.passedUniqueReads >= filter.matrixMinimumReads
        }
        let knownRows = Dictionary(grouping: filteredCalls) {
            "\($0.locusGroup)\u{0}\($0.genotype)"
        }.map { _, groupedCalls in
            ONTGenotypeSharedCall(
                locus: groupedCalls[0].locusGroup,
                genotype: groupedCalls[0].genotype,
                sampleSupport: groupedCalls.map {
                    ONTGenotypeSampleSupport(
                        sample: $0.sample,
                        passedAlignments: $0.passedAlignments,
                        passedUniqueReads: $0.passedUniqueReads,
                        sampleUniqueRetainedReads: $0.sampleUniqueRetainedReads
                    )
                }
            )
        }
        var rows = GenotypeCandidateMatrixProjection.rows(
            knownRows: knownRows,
            candidateDocument: candidateDocument,
            settings: settings,
            usesBiologicalAlleleOrder: false
        )
        let eligibleSamples = Set(logicalSampleNames)
        if globalThreshold > 0
            || matrixThreshold > 0
            || filter.matrixMinimumReads > 0 {
            rows = rows.compactMap { row in
                guard row.population != .known else { return row }
                let supportingSamples = Set(row.sampleSupport.map(\.sample))
                    .intersection(eligibleSamples)
                let populationFraction = eligibleSamples.isEmpty
                    ? nil
                    : Double(supportingSamples.count) / Double(eligibleSamples.count)
                if globalThreshold > 0,
                   (populationFraction ?? -.infinity) < globalThreshold {
                    return nil
                }
                if matrixThreshold > 0,
                   (populationFraction ?? -.infinity) < matrixThreshold {
                    return nil
                }
                let support = filter.matrixMinimumReads > 0
                    ? row.sampleSupport.filter {
                        $0.passedUniqueReads >= filter.matrixMinimumReads
                    }
                    : row.sampleSupport
                guard !support.isEmpty else { return nil }
                return GenotypeCandidateMatrixRow(
                    id: row.id,
                    alleleName: row.alleleName,
                    locus: row.locus,
                    stableClusterID: row.stableClusterID,
                    population: row.population,
                    tintCategory: row.tintCategory,
                    sampleSupport: support,
                    evidenceBySample: row.evidenceBySample,
                    candidate: row.candidate,
                    incompleteCandidateInterpretation: row.incompleteCandidateInterpretation
                )
            }
        }
        rows.sort { lhs, rhs in
            let locusOrder = lhs.locus.localizedStandardCompare(rhs.locus)
            if locusOrder != .orderedSame {
                return locusOrder == .orderedAscending
            }
            let nameOrder = lhs.alleleName.localizedStandardCompare(rhs.alleleName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id.deterministicSortKey < rhs.id.deterministicSortKey
        }
        let uniqueKnownRows = Set(calls.map {
            "\($0.locusGroup)\u{0}\($0.genotype)"
        }).count
        let candidateCellCount = candidateDocument.map {
            Set($0.observations.map {
                "\($0.stableClusterID)\u{0}\($0.sampleID)"
            }).count
        } ?? 0
        let visibleCellCount = rows.reduce(0) { $0 + $1.sampleCount }
        return LegacyProjection(
            rows: rows,
            totalRowCount: uniqueKnownRows + (candidateDocument?.candidates.count ?? 0),
            hiddenCellCount: max(
                0,
                calls.count + candidateCellCount - visibleCellCount
            )
        )
    }

    private func legacySupportFractions(
        calls: [ONTGenotypeCall],
        samples: [ONTGenotypeSampleResult],
        candidateDocument: ONTMHCCandidateAllelesDocument?,
        logicalSampleNames: [String],
        denominator: ONTGenotypeSupportDenominator
    ) -> [GenotypeMatrixBaseProjection.CellIdentity: Double] {
        let retainedBySample = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.sample, $0.passedUniqueReads) }
        )
        let viewedDenominators = Dictionary(grouping: calls) {
            "\($0.sample)\u{0}\($0.locusGroup)"
        }.mapValues { $0.reduce(0) { $0 + $1.passedUniqueReads } }
        var fractions: [GenotypeMatrixBaseProjection.CellIdentity: Double] = [:]
        for call in calls {
            let denominatorValue: Int?
            switch denominator {
            case .viewedLocus:
                denominatorValue = viewedDenominators[
                    "\(call.sample)\u{0}\(call.locusGroup)"
                ]
            case .sampleRetained:
                denominatorValue = call.sampleUniqueRetainedReads
                    ?? retainedBySample[call.sample]
            }
            guard let denominatorValue, denominatorValue > 0 else { continue }
            let key = GenotypeMatrixBaseProjection.CellIdentity(
                locus: call.locusGroup,
                genotype: call.genotype,
                sample: call.sample,
                stableClusterID: nil
            )
            if fractions[key] == nil {
                fractions[key] =
                    Double(call.passedUniqueReads) / Double(denominatorValue)
            }
        }
        let eligibleSampleCount = Set(logicalSampleNames).count
        if eligibleSampleCount > 0, let candidateDocument {
            let observationsByCluster = Dictionary(
                grouping: candidateDocument.observations,
                by: \.stableClusterID
            )
            for candidate in candidateDocument.candidates {
                let supportingSamples = Set(
                    (observationsByCluster[candidate.stableClusterID] ?? [])
                        .map(\.sampleID)
                )
                let populationFraction =
                    Double(supportingSamples.count) / Double(eligibleSampleCount)
                for sample in supportingSamples {
                    fractions[.init(
                        locus: candidate.locus,
                        genotype: candidate.provisionalName,
                        sample: sample,
                        stableClusterID: candidate.stableClusterID
                    )] = populationFraction
                }
            }
        }
        return fractions
    }

    private func makeCall(
        sample: String,
        genotype: String,
        reads: Int,
        retainedReads: Int?
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: retainedReads,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeSample(_ sample: String, retainedReads: Int) -> ONTGenotypeSampleResult {
        ONTGenotypeSampleResult(
            sample: sample,
            passedAlignments: retainedReads,
            passedUniqueReads: retainedReads,
            sampleTotalReads: nil,
            sampleUniqueRetainedPercent: nil,
            calls: []
        )
    }

    private func makeCandidateDocument() -> ONTMHCCandidateAllelesDocument {
        let candidates = [
            makeCandidate(id: "shared", name: "Mafa-A1*900:01_nov", support: .shared, samples: ["S1", "S2"]),
            makeCandidate(id: "singleton", name: "Mafa-A1*901:01_nov", support: .singleton, samples: ["S3"]),
            makeCandidate(id: "unsupported", name: "Mafa-A1*902:01_nov", support: .singleton, samples: []),
        ]
        let observations = [
            makeObservation(cluster: "shared", sample: "S1", reads: 4),
            makeObservation(cluster: "shared", sample: "S2", reads: 9),
            makeObservation(cluster: "singleton", sample: "S3", reads: 7),
        ]
        let artifact = ONTMHCArtifactReference(
            path: "candidate.fasta",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1
        )
        return ONTMHCCandidateAllelesDocument(
            schemaVersion: 1,
            createdAt: "2026-07-25T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: artifact,
            candidates: candidates,
            observations: observations
        )
    }

    private func makeCandidate(
        id: String,
        name: String,
        support: ONTMHCCandidateSupportClass,
        samples: [String]
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: id,
            provisionalName: name,
            locus: "MHC-A1",
            classification: .novel,
            supportClass: support,
            closestReferenceName: "Mafa-A1*001:01",
            closestReferenceClass: .genomicDNA,
            snpCount: 1,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: 0,
            comparableBases: 2_000,
            shorterCoverage: 1,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: 2_000,
            independentSampleCount: samples.count,
            occurrenceCount: samples.count,
            totalClusterReads: samples.count * 5,
            supportingSampleIDs: samples,
            fastaRecordID: id,
            sequenceSHA256: String(repeating: "b", count: 64),
            selectedEvidence: ONTMHCEvidenceLocator(
                bamPath: "evidence.bam",
                queryName: id,
                referenceName: "Mafa-A1*001:01",
                readGroupID: nil,
                referenceStart: 1,
                cigar: "2000M"
            )
        )
    }

    private func makeObservation(
        cluster: String,
        sample: String,
        reads: Int
    ) -> ONTMHCCandidateObservation {
        ONTMHCCandidateObservation(
            stableClusterID: cluster,
            sampleID: sample,
            readGroupID: sample,
            sourceClusterIDs: ["source-\(cluster)-\(sample)"],
            sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
            aggregatedSampleReadCount: reads,
            evidence: []
        )
    }
}
