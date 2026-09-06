import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Full-length MHC sequence detail and candidate allele rows/matrix
@MainActor
final class GenotypeResultViewportCandidateDetailTests: GenotypeResultViewportTestCase {
    func testFullLengthMHCSequenceDetailIsEmptyUntilAlleleRowSelection() throws {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertGreaterThan(
            controller.testingDetailArrangedSubviewCount,
            0
        )
        XCTAssertEqual(controller.testingAlleleSequenceText, "")

        controller.testingSelectMatrixCell(genotype: "known-a", sample: "AnimalA")
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
    }


    func testFullLengthMHCKnownRowShowsExactRecordAndFormatToggles() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))

        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)

        XCTAssertEqual(controller.testingAlleleSequenceFormat, .genBank)
        XCTAssertEqual(controller.testingAlleleSequenceText, known.genBankText)
        controller.testingSelectAlleleSequenceFormat(.fasta)
        XCTAssertEqual(controller.testingAlleleSequenceText, known.fastaText)
        controller.testingSelectAlleleSequenceFormat(.embl)
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("AC   known-a;"))
    }


    func testFullLengthMHCSupportedCellHelperClearsSelectedRowSequenceForCellsAndNoMatches() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        XCTAssertFalse(controller.testingAlleleSequenceText.isEmpty)

        XCTAssertEqual(controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 1).count, 1)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")

        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        XCTAssertFalse(controller.testingAlleleSequenceText.isEmpty)
        XCTAssertTrue(controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 100).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
    }


    func testFullLengthMHCCellsAvoidDetailHierarchyWhileColumnsUseSharedSampleRenderer() {
        let call = makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [.init(
                sample: "AnimalA",
                passedAlignments: 10,
                passedUniqueReads: 10,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            )],
            calls: [call],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: "known-a",
                    alleleName: "Mafa-A1*001:01"
                )]
            )
        ))

        for _ in 0..<50 {
            controller.testingSelectMatrixCell(genotype: "known-a", sample: "AnimalA")
            controller.testingSelectMatrixColumn(sample: "AnimalA")
        }

        XCTAssertGreaterThan(
            controller.testingDetailArrangedSubviewCount,
            0
        )
        XCTAssertEqual(
            controller.testingLegacyNonRowDetailBuildCount,
            50
        )
        XCTAssertEqual(controller.testingKnownAlleleDetailMountCount, 0)
        XCTAssertEqual(controller.testingCandidateAlleleDetailMountCount, 0)
        XCTAssertFalse(controller.testingCurrentSelectionMatrixTargets.isEmpty)
    }


    func testFullLengthMHCKnownSequenceRecordsAreFormattedOnlyDuringConfigure() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        XCTAssertEqual(controller.testingKnownAlleleSequenceRecordBuildCount, 1)
        XCTAssertEqual(controller.testingKnownAlleleSequenceCacheCount, 1)

        for _ in 0..<50 {
            controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        }

        XCTAssertEqual(controller.testingKnownAlleleSequenceRecordBuildCount, 1)
        XCTAssertEqual(controller.testingKnownAlleleSequenceCacheCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceText, known.genBankText)
    }


    func testFullLengthMHCCandidateRowUsesExactCandidateArtifactNotClosestReference() throws {
        let fixture = try makeSequenceDetailCandidateResult()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)

        controller.testingSelectCandidateRow(stableClusterID: "candidate-stable")

        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["candidate-stable"])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("ACCESSION   candidate-accession"))
        XCTAssertFalse(controller.testingAlleleSequenceText.contains("closest-reference"))
        controller.testingSelectAlleleSequenceFormat(.fasta)
        XCTAssertEqual(
            controller.testingAlleleSequenceText,
            ">candidate-accession Mafa-A1*001:01_1nt_nov\nACGTACGT\n"
        )
        controller.testingSelectAlleleSequenceFormat(.embl)
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("AC   candidate-accession;"))
    }


    func testFullLengthMHCCandidateCatalogKeepsValidRecordWhenAnotherChecksumIsInvalid() throws {
        let fixture = try makeSequenceDetailCandidateResult(includeInvalidCandidate: true)
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)

        controller.testingSelectCandidateRow(stableClusterID: "candidate-stable")

        XCTAssertTrue(controller.testingAlleleSequenceText.contains(
            "ACCESSION   candidate-accession"
        ))
        XCTAssertFalse(controller.testingAlleleSequenceText.contains(
            "Validated allele record unavailable"
        ))

        controller.testingSelectCandidateRow(stableClusterID: "candidate-invalid")

        XCTAssertEqual(
            controller.testingAlleleSequenceRecordIdentities,
            ["candidate-invalid"]
        )
        XCTAssertTrue(controller.testingAlleleSequenceText.contains(
            "Validated allele record unavailable"
        ))
    }


    func testFullLengthMHCUnresolvedSelectionReplacesPriorRecordWithUnavailableRecord() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "known-a", reads: 10),
                makeCall(sample: "AnimalA", genotype: "missing", reads: 9),
            ],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)

        controller.testingSelectMatrixRows(genotypes: ["missing"], sample: nil)

        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["missing"])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertFalse(controller.testingAlleleSequenceText.contains("known-a"))
    }


    func testReconfigureToCandidateOnlyFullLengthResultClearsPriorSequenceDetail() throws {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let candidateFixture = try makeSequenceDetailCandidateResult()
        defer { TestTempDirectory.cleanup(candidateFixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)

        controller.configure(result: candidateFixture.result)

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertTrue(controller.testingAlleleSequenceRecordIdentities.isEmpty)
    }


    func testMatrixOrdersArbitraryRowTargetsByVisibleRowsAndKeepsDuplicateCandidateLabels() {
        let candidates = [
            makeCandidate(id: "cluster-b", name: "Same_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-a", name: "Same_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 10)],
            candidates: candidates,
            observations: candidates.map {
                makeCandidateObservation(cluster: $0.stableClusterID, sample: "AnimalA", reads: 5)
            }
        ))
        let input: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .row(locus: "MHC-A1", genotype: "Same_nov", stableClusterID: "cluster-b"),
            .column(sample: "AnimalA"),
            .row(locus: "MHC-KNOWN", genotype: "Known"),
            .cell(locus: "MHC-A1", genotype: "Same_nov", sample: "AnimalA", stableClusterID: "cluster-a"),
            .row(locus: "MHC-A1", genotype: "Same_nov", stableClusterID: "cluster-a"),
        ]

        XCTAssertEqual(
            matrix.orderedVisibleRowTargets(from: input),
            matrix.testingVisibleRows.map {
                .row(
                    locus: $0.locus,
                    genotype: $0.genotype,
                    stableClusterID: $0.stableClusterID
                )
            }
        )
    }


    func testFullLengthMHCMixedRowsUseViewportOrderPersistFormatAndKeepOneSequenceHierarchy() throws {
        let fixture = try makeSequenceDetailCandidateResult(includeKnown: true)
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        try FileManager.default.removeItem(
            at: fixture.result.mhcCandidateGenBankArtifactURLs.candidateAlleles!
        )
        let unordered: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .row(
                locus: "MHC-A1",
                genotype: "Mafa-A1*001:01_1nt_nov",
                stableClusterID: "candidate-stable"
            ),
            .row(
                locus: try XCTUnwrap(
                    fixture.result.locusSummaries
                        .flatMap(\.sharedCalls)
                        .first { $0.genotype == "known-a" }?
                        .locus
                ),
                genotype: "known-a"
            ),
        ]

        controller.testingShowMatrixTargetSelection(unordered)

        XCTAssertEqual(
            controller.testingAlleleSequenceRecordIdentities,
            ["known-a", "candidate-stable"]
        )
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        let knownRange = try XCTUnwrap(controller.testingAlleleSequenceText.range(of: "known-a"))
        let candidateRange = try XCTUnwrap(
            controller.testingAlleleSequenceText.range(of: "candidate-accession")
        )
        XCTAssertLessThan(knownRange.lowerBound, candidateRange.lowerBound)
        controller.testingSelectAlleleSequenceFormat(.fasta)
        let baselineSubviewCount = descendants(of: controller.view).count
        for _ in 0..<50 {
            controller.testingShowMatrixTargetSelection(Array(unordered.reversed()))
            XCTAssertEqual(controller.testingAlleleSequenceFormat, .fasta)
        }
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        XCTAssertEqual(descendants(of: controller.view).count, baselineSubviewCount)
        XCTAssertTrue(knownAlleleDetails(in: controller.view).isEmpty)
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)

        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-b", reads: 4)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: "known-b",
                    alleleName: "Mafa-B*001:01"
                )]
            )
        ))

        XCTAssertEqual(controller.testingAlleleSequenceFormat, .genBank)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
    }


    func testFullLengthMHCRowsUseSpeciesAgnosticBiologicalAlleleOrder() throws {
        let alleleFieldKey = "feature.allele"
        let knownAlleles = [
            "raw-k": "Mamu-K*001:01",
            "raw-a2": "Mamu-A2*001:01",
            "raw-ag": "Mamu-AG*001:01",
            "raw-b": "Mamu-B*001:01",
            "raw-f": "Mamu-F*001:01",
        ]
        let candidateNames = [
            "cluster-other": "Mamu-E*001:01_nov",
            "cluster-g-z": "Mamu-G*009:01_nov",
            "cluster-b16": "Mamu-B16*001:01_nov",
            "cluster-a1": "Mamu-A1*001:01_nov",
            "cluster-i": "Mamu-I*001:01_nov",
            "cluster-g-a": "Mamu-G*009:01_nov",
            "cluster-j": "Mamu-J*001:01_nov",
            "cluster-b02ps": "Mamu-B02ps*001:01_nov",
        ]
        let calls = ["raw-k", "raw-a2", "raw-ag", "raw-b", "raw-f"].map {
            makeCall(sample: "AnimalA", genotype: $0, reads: 10)
        }
        let candidates = [
            "cluster-other", "cluster-g-z", "cluster-b16", "cluster-a1",
            "cluster-i", "cluster-g-a", "cluster-j", "cluster-b02ps",
        ].map { id in
            makeCandidate(
                id: id,
                name: candidateNames[id]!,
                classification: .novel,
                support: .singleton,
                samples: ["AnimalA"]
            )
        }
        let observations = candidates.map {
            makeCandidateObservation(cluster: $0.stableClusterID, sample: "AnimalA", reads: 5)
        }
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [GenBankRecordDatabase.FieldDefinition(
                key: alleleFieldKey,
                displayTitle: "Allele",
                valueType: "text",
                sourceCategory: "feature",
                preferredOrder: 0
            )],
            recordsBySequenceName: knownAlleles.mapValues { [alleleFieldKey: $0] },
            alleleFieldKey: alleleFieldKey
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeCandidateResult(
            calls: calls,
            candidates: candidates,
            observations: observations,
            referenceMetadata: metadata
        ))
        let expected = [
            candidateNames["cluster-a1"]!,
            "raw-a2",
            "raw-b",
            candidateNames["cluster-b02ps"]!,
            candidateNames["cluster-b16"]!,
            candidateNames["cluster-i"]!,
            "raw-f",
            candidateNames["cluster-g-a"]!,
            candidateNames["cluster-g-z"]!,
            "raw-ag",
            candidateNames["cluster-j"]!,
            "raw-k",
            candidateNames["cluster-other"]!,
        ]
        let expectedIdentities = [
            "\(candidateNames["cluster-a1"]!)|cluster-a1",
            "raw-a2|known",
            "raw-b|known",
            "\(candidateNames["cluster-b02ps"]!)|cluster-b02ps",
            "\(candidateNames["cluster-b16"]!)|cluster-b16",
            "\(candidateNames["cluster-i"]!)|cluster-i",
            "raw-f|known",
            "\(candidateNames["cluster-g-a"]!)|cluster-g-a",
            "\(candidateNames["cluster-g-z"]!)|cluster-g-z",
            "raw-ag|known",
            "\(candidateNames["cluster-j"]!)|cluster-j",
            "raw-k|known",
            "\(candidateNames["cluster-other"]!)|cluster-other",
        ]
        let visibleIdentities = {
            matrix.testingVisibleRows.map {
                "\($0.alleleName)|\($0.stableClusterID ?? "known")"
            }
        }

        XCTAssertEqual(matrix.testingVisibleGenotypes, expected)
        XCTAssertEqual(visibleIdentities(), expectedIdentities)
        let alleleSortKey = try XCTUnwrap(matrix.testingActiveSortDescriptorKey)
        XCTAssertEqual(alleleSortKey, "reference.\(alleleFieldKey)")

        matrix.testingSetSortDescriptor(key: alleleSortKey, ascending: true)
        XCTAssertEqual(matrix.testingVisibleGenotypes, expected)
        XCTAssertEqual(visibleIdentities(), expectedIdentities)

        matrix.testingSetSortDescriptor(key: alleleSortKey, ascending: false)
        XCTAssertEqual(matrix.testingVisibleGenotypes, expected.reversed())
        XCTAssertEqual(visibleIdentities(), expectedIdentities.reversed())
    }


    func testFullLengthMHCFASTAProjectionUsesBiologicalAlleleOrderAndStableCandidateTies() throws {
        let candidates = [
            makeCandidate(id: "cluster-other", name: "Mamu-E*001:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-g-z", name: "Mamu-G*009:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-a1", name: "Mamu-A1*001:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-g-a", name: "Mamu-G*009:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
        ]
        let result = makeCandidateResult(
            calls: [
                makeCall(sample: "AnimalA", genotype: "Mamu-K*001:01", reads: 10),
                makeCall(sample: "AnimalA", genotype: "Mamu-B*001:01", reads: 10),
                makeCall(sample: "AnimalA", genotype: "Mamu-A2*001:01", reads: 10),
            ],
            candidates: candidates,
            observations: candidates.map {
                makeCandidateObservation(cluster: $0.stableClusterID, sample: "AnimalA", reads: 5)
            }
        )
        let expectedIdentities = [
            "Mamu-A1*001:01_nov|cluster-a1",
            "Mamu-A2*001:01|known",
            "Mamu-B*001:01|known",
            "Mamu-G*009:01_nov|cluster-g-a",
            "Mamu-G*009:01_nov|cluster-g-z",
            "Mamu-K*001:01|known",
            "Mamu-E*001:01_nov|cluster-other",
        ]
        let projectedRows = GenotypeCandidateMatrixProjection.rows(
            knownRows: result.locusSummaries.flatMap(\.sharedCalls),
            candidateDocument: try XCTUnwrap(result.mhcCandidates),
            settings: .default,
            usesBiologicalAlleleOrder: true
        )

        XCTAssertEqual(projectedRows.map {
            "\($0.alleleName)|\($0.stableClusterID ?? "known")"
        }, expectedIdentities)

        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, "genotype")
        XCTAssertEqual(matrix.testingVisibleRows.map {
            "\($0.alleleName)|\($0.stableClusterID ?? "known")"
        }, expectedIdentities)
    }


    func testNonFullLengthGenotypeAndAlleleSortsKeepLocalizedStandardOrder() throws {
        let expectedGenotypes = ["Mamu-E*001:01", "Mamu-K*001:01"]
        let fastaMatrix = GenotypeComparisonMatrixView()
        fastaMatrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: expectedGenotypes[1], reads: 10),
                makeCall(sample: "AnimalA", genotype: expectedGenotypes[0], reads: 10),
            ]
        ))

        XCTAssertEqual(fastaMatrix.testingVisibleGenotypes, expectedGenotypes)
        let genotypeSortKey = try XCTUnwrap(fastaMatrix.testingActiveSortDescriptorKey)
        XCTAssertEqual(genotypeSortKey, "genotype")
        fastaMatrix.testingSetSortDescriptor(key: genotypeSortKey, ascending: true)
        XCTAssertEqual(fastaMatrix.testingVisibleGenotypes, expectedGenotypes)

        let alleleFieldKey = "feature.allele"
        let genBankMatrix = GenotypeComparisonMatrixView()
        genBankMatrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "raw-k", reads: 10),
                makeCall(sample: "AnimalA", genotype: "raw-e", reads: 10),
            ],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: [GenBankRecordDatabase.FieldDefinition(
                    key: alleleFieldKey,
                    displayTitle: "Allele",
                    valueType: "text",
                    sourceCategory: "feature",
                    preferredOrder: 0
                )],
                recordsBySequenceName: [
                    "raw-k": [alleleFieldKey: expectedGenotypes[1]],
                    "raw-e": [alleleFieldKey: expectedGenotypes[0]],
                ],
                alleleFieldKey: alleleFieldKey
            )
        ))

        XCTAssertEqual(genBankMatrix.testingVisibleGenotypes, ["raw-e", "raw-k"])
        let alleleSortKey = try XCTUnwrap(genBankMatrix.testingActiveSortDescriptorKey)
        XCTAssertEqual(alleleSortKey, "reference.\(alleleFieldKey)")
        genBankMatrix.testingSetSortDescriptor(key: alleleSortKey, ascending: true)
        XCTAssertEqual(genBankMatrix.testingVisibleGenotypes, ["raw-e", "raw-k"])
    }


    func testFullLengthCandidateControlsExposeExactLabelsDefaultsAndIndependentTintReset() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 3)],
            candidates: [
                makeCandidate(id: "shared", name: "Shared_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "single", name: "Single_ext", classification: .extension, support: .singleton, samples: ["AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 2),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 4),
                makeCandidateObservation(cluster: "single", sample: "AnimalB", reads: 6),
            ]
        )

        viewModel.updateMHCCandidatePresentation(from: result)

        XCTAssertTrue(viewModel.mhcCandidateControlsAvailable)
        XCTAssertEqual(GenotypeCandidateEvidenceSection.visibilityLabels, [
            "Known",
            "Shared candidates (2+ samples)",
            "Singleton candidates (1 sample)",
        ])
        XCTAssertEqual(GenotypeCandidateEvidenceSection.tintLabels, [
            "Shared novel",
            "Singleton novel",
            "Shared extension",
            "Singleton extension",
        ])
        XCTAssertEqual(viewModel.mhcCandidateDisplaySettings, .default)

        let replacement = AnnotationColor(red: 0.12, green: 0.34, blue: 0.56, alpha: 0.78)
        viewModel.setMHCCandidateTint(replacement, category: .sharedNovel)
        XCTAssertEqual(viewModel.mhcCandidateDisplaySettings.tints[.sharedNovel], replacement)
        XCTAssertEqual(
            viewModel.mhcCandidateDisplaySettings.tints[.singletonNovel],
            ONTMHCCandidateDisplaySettings.defaultTints[.singletonNovel]
        )

        viewModel.resetMHCCandidateTint(.sharedNovel)
        XCTAssertEqual(viewModel.mhcCandidateDisplaySettings.tints, ONTMHCCandidateDisplaySettings.defaultTints)
    }


    func testCompactSchemaTwoCandidateDocumentEnablesRowsAndUnavailableSequenceDetail() throws {
        let stableClusterID = "compact-candidate"
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 3)],
            candidates: [
                makeCandidate(
                    id: stableClusterID,
                    name: "Mafa-A1*001:01_1nt_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                ONTMHCCandidateObservation(
                    stableClusterID: stableClusterID,
                    sampleID: "AnimalA",
                    readGroupID: "AnimalA",
                    sourceClusterIDs: ["source-compact"],
                    sourceClusterReadCounts: ["source-compact": 7],
                    aggregatedSampleReadCount: 7,
                    genotypingHitSummaries: [try ONTMHCGenotypingTargetHitSummary(
                        bamPath: "artifacts/alignments/genotyping-evidence.bam",
                        targetName: "AnimalA|source-compact",
                        alignmentCount: 7,
                        queryAlignmentCounts: ["compact-reference": 7],
                        exactMatchQueryNames: [],
                        closestMatchQueryNames: ["compact-reference"]
                    )]
                ),
            ],
            candidateSequences: [stableClusterID: String(repeating: "A", count: 24)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeCandidateReferenceVisualizationRecord(
                    rawReferenceID: "compact-reference",
                    alleleName: "Mafa-A1*001:01",
                    stableClusterID: stableClusterID
                )]
            ),
            candidateDocumentSchemaVersion: 2
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: result)
        XCTAssertTrue(viewModel.mhcCandidateControlsAvailable)

        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.stableClusterID == stableClusterID })

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: stableClusterID)
        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, [stableClusterID])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.first {
                $0.0 == "Genotyping Evidence"
            }?.1,
            "7 alignments in indexed BAM"
        )
    }


    func testSchemaFourCanonicalCandidateRendersOnceWithAllObservationSupport() throws {
        let stableClusterID = "canonical-candidate"
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: stableClusterID,
                    name: "Mafa-A1*001:01_1nt_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["AnimalA", "AnimalB"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: stableClusterID, sample: "AnimalA", reads: 7),
                makeCandidateObservation(cluster: stableClusterID, sample: "AnimalB", reads: 11),
            ],
            candidateDocumentSchemaVersion: 4,
            candidateArtifactManifestSchemaVersion: 2
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: result)
        XCTAssertTrue(viewModel.mhcCandidateControlsAvailable)

        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)
        let candidateRows = matrix.testingVisibleRows.filter {
            $0.stableClusterID == stableClusterID
        }
        XCTAssertEqual(candidateRows.count, 1)
        XCTAssertEqual(candidateRows[0].support(for: "AnimalA")?.passedUniqueReads, 7)
        XCTAssertEqual(candidateRows[0].support(for: "AnimalB")?.passedUniqueReads, 11)
    }


    func testLegacyAndInvalidCandidateBundlesDoNotExposeControlsAndInvalidWarningIsNonfatal() {
        let candidate = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let legacyBase = makeResult(samples: candidate.samples, calls: candidate.calls)
        let legacy = ONTGenotypeResultBundleData(
            bundleURL: legacyBase.bundleURL,
            manifest: legacyBase.manifest,
            artifacts: legacyBase.artifacts,
            stats: legacyBase.stats,
            calls: candidate.calls,
            samples: candidate.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
        let invalid = ONTGenotypeResultBundleData(
            bundleURL: candidate.bundleURL,
            manifest: candidate.manifest,
            artifacts: candidate.artifacts,
            stats: candidate.stats,
            calls: candidate.calls,
            samples: candidate.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: [.init(
                code: .candidateArtifactChecksumMismatch,
                detail: "candidate JSON checksum did not match",
                path: "artifacts/candidates/candidates.json"
            )],
            referenceMetadata: nil
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: legacy)
        XCTAssertFalse(viewModel.mhcCandidateControlsAvailable)
        XCTAssertTrue(viewModel.mhcCandidateIntegrityWarnings.isEmpty)

        viewModel.updateMHCCandidatePresentation(from: invalid)
        XCTAssertFalse(viewModel.mhcCandidateControlsAvailable)
        XCTAssertEqual(viewModel.mhcCandidateIntegrityWarnings.count, 1)
        XCTAssertTrue(viewModel.mhcCandidateIntegrityWarnings[0].contains("checksum"))

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: invalid)
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Known"])
        XCTAssertTrue(controller.testingCandidateIntegrityWarningText.contains("checksum"))
    }


    func testNonFullLengthBundleDoesNotExposeCandidateWarningsOrEvidenceSection() {
        let candidate = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let nonFullLengthBase = makeResult(samples: candidate.samples, calls: candidate.calls)
        let nonFullLength = ONTGenotypeResultBundleData(
            bundleURL: nonFullLengthBase.bundleURL,
            manifest: nonFullLengthBase.manifest,
            artifacts: nonFullLengthBase.artifacts,
            stats: nonFullLengthBase.stats,
            calls: candidate.calls,
            samples: candidate.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: candidate.mhcCandidates,
            mhcUnnameableClusters: nil,
            integrityWarnings: [.init(
                code: .candidateArtifactChecksumMismatch,
                detail: "candidate JSON checksum did not match",
                path: "artifacts/candidates/candidates.json"
            )],
            referenceMetadata: nil
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: nonFullLength)

        XCTAssertFalse(viewModel.mhcCandidateControlsAvailable)
        XCTAssertTrue(viewModel.mhcCandidateIntegrityWarnings.isEmpty)
        XCTAssertNil(viewModel.mhcCandidatePersistenceWarning)

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: nonFullLength)
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Known"])
        XCTAssertEqual(controller.testingCandidateIntegrityWarningText, "")
    }


    func testCandidateRowsUseDistinctSamplePopulationFractionForGlobalThresholds() {
        let result = makeCandidateResult(
            calls: [
                makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_KnownHigh", reads: 9),
                makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_KnownLow", reads: 1),
            ],
            candidates: [
                makeCandidate(id: "shared", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "singleton", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalC"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 3),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 3),
                makeCandidateObservation(cluster: "singleton", sample: "AnimalC", reads: 3),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        XCTAssertEqual(matrix.testingSupportFraction(rowID: .candidate(stableClusterID: "shared"), sample: "AnimalA"), 0.5)
        XCTAssertEqual(matrix.testingSupportFraction(rowID: .candidate(stableClusterID: "singleton"), sample: "AnimalC"), 0.25)

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 25))
        XCTAssertEqual(Set(matrix.testingVisibleRows.map(\.id)), Set([
            .known(locus: "MHC-A", genotype: "01_Mafa_A1_KnownHigh"),
            .candidate(stableClusterID: "shared"),
            .candidate(stableClusterID: "singleton"),
        ]), "The singleton is exactly 1/4 of the eligible sample union and remains visible at threshold")

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 25.1))
        XCTAssertEqual(Set(matrix.testingVisibleRows.map(\.id)), Set([
            .known(locus: "MHC-A", genotype: "01_Mafa_A1_KnownHigh"),
            .candidate(stableClusterID: "shared"),
        ]), "Stable cluster IDs must keep same-named candidates from sharing threshold state")

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 50))
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .candidate(stableClusterID: "shared") })

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 50.1))
        XCTAssertFalse(matrix.testingVisibleRows.contains { $0.population != .known })
        XCTAssertEqual(matrix.testingVisibleRows.map(\.genotype), ["01_Mafa_A1_KnownHigh"], "Candidate-only samples must not alter known read-share semantics")
    }


    func testCandidateRowsUsePopulationFractionForMatrixThresholdAndVisibilityDoesNotChangeDenominator() {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_Known", reads: 10)],
            candidates: [
                makeCandidate(id: "shared", name: "Shared_ext", classification: .extension, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "singleton", name: "Singleton_ext", classification: .extension, support: .singleton, samples: ["AnimalC"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 3),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 3),
                makeCandidateObservation(cluster: "singleton", sample: "AnimalC", reads: 3),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        matrix.applyDisplayState(.init(matrixMinimumPercent: 25))
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .candidate(stableClusterID: "singleton") })

        var settings = ONTMHCCandidateDisplaySettings.default
        settings.showSingletonCandidates = false
        matrix.applyDisplayState(.init(matrixMinimumPercent: 50, mhcCandidateDisplaySettings: settings))
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .candidate(stableClusterID: "shared") })

        matrix.applyDisplayState(.init(matrixMinimumPercent: 50.1, mhcCandidateDisplaySettings: settings))
        XCTAssertFalse(matrix.testingVisibleRows.contains { $0.population != .known }, "Hidden singleton samples remain in the eligible matrix sample union")
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .known(locus: "MHC-A", genotype: "01_Mafa_A1_Known") })
    }


    func testCandidatePopulationThresholdHandlesEmptyEligibleSampleUnion() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "orphan", name: "Orphan_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: []
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 1))

        XCTAssertTrue(matrix.testingVisibleRows.isEmpty)
        XCTAssertNil(matrix.testingSupportFraction(rowID: .candidate(stableClusterID: "orphan"), sample: "AnimalA"))
    }


    func testCandidateSelectionUsesExclusiveCallbackAndCompleteStableEvidenceDetail() throws {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [
                makeCandidate(id: "cluster-a", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "cluster-b", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingSelectCandidateCell(stableClusterID: "cluster-b", sample: "AnimalA")

        XCTAssertEqual(controller.testingSelectedCandidateStableClusterID, "cluster-b")
        let details = Dictionary(uniqueKeysWithValues: controller.testingCurrentSelectionDetailRows)
        XCTAssertEqual(details["Stable Cluster ID"], "cluster-b")
        XCTAssertEqual(details["Provisional Name"], "Collision_nov")
        XCTAssertEqual(details["Classification"], "Novel")
        XCTAssertEqual(details["Support Class"], "Singleton (1 sample)")
        XCTAssertEqual(details["Independent Samples"], "1")
        XCTAssertEqual(details["Occurrence Count"], "1")
        XCTAssertEqual(details["Total Cluster Reads"], "5")
        XCTAssertEqual(details["Selected Sample"], "AnimalA")
        XCTAssertEqual(details["Selected Sample Reads"], "11")
        XCTAssertEqual(details["Closest Reference"], "Mafa-A1*018:01:01:01")
        XCTAssertEqual(details["SNP Substitutions"], "5")
        XCTAssertEqual(details["FASTA Record ID"], "cluster-b")
        XCTAssertEqual(details["Candidate FASTA Path"], "artifacts/candidates/candidates.fasta")
        XCTAssertEqual(details["Genotyping BAM Path"], "artifacts/alignments/genotyping-evidence.bam")
        XCTAssertEqual(details["Genotyping BAI Path"], "artifacts/alignments/genotyping-evidence.bam.bai")
        XCTAssertEqual(details["Reciprocal BAM Path"], "artifacts/alignments/unmatched-to-reference.bam")
        XCTAssertEqual(details["Reciprocal BAI Path"], "artifacts/alignments/unmatched-to-reference.bam.bai")
        XCTAssertEqual(details["Selected Alignment Query"], "cluster-b")
        XCTAssertEqual(details["Selected Alignment CIGAR"], "2000M")
        XCTAssertEqual(details["Genotyping Evidence"], "1 alignment in indexed BAM")
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains {
            $0.0.hasPrefix("Genotyping Alignment")
        })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0.localizedCaseInsensitiveContains("sequence bases") })
        XCTAssertEqual(controller.testingCandidateSelectionCallbackCounts, .init(known: 0, candidate: 1))
    }


    func testCandidateSelectionSummarizesLargeBAMEvidenceWithoutBuildingOneViewPerAlignment() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "cluster-heavy",
                    name: "Mafa-A1*018:01:01:01_5nt_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "cluster-heavy",
                    sample: "AnimalA",
                    reads: 1_573,
                    evidenceCount: 1_573
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingSelectCandidateCell(stableClusterID: "cluster-heavy", sample: "AnimalA")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertEqual(
            rows.first(where: { $0.0 == "Genotyping Evidence" })?.1,
            "1,573 alignments in indexed BAM"
        )
        XCTAssertFalse(rows.contains { $0.0.hasPrefix("Genotyping Alignment") })
        XCTAssertLessThan(rows.count, 60, "Detail metadata must stay bounded as BAM evidence grows.")
    }


    func testCandidateCellKeepsInspectorEvidenceWhileRowMountsSequenceDetail() throws {
        let root = try TestTempDirectory.make(prefix: "CandidateGraphicalSelection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let provisionalName = "Collision_nov"
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: provisionalName, classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-b", name: provisionalName, classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
            ],
            candidateSequences: [
                "cluster-a": "AAAA",
                "cluster-b": "CCCCCCCCCCCCCCCCC",
            ],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-a",
                        alleleName: "Mafa-A1*001:01",
                        stableClusterID: "cluster-a"
                    ),
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-b",
                        alleleName: "Mafa-A1*002:01",
                        stableClusterID: "cluster-b"
                    ),
                ]
            ),
            integrityWarnings: [.init(
                code: .candidateArtifactMalformedFASTA,
                detail: "Legacy candidate warning"
            )]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-21T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A1", genotype: provisionalName, stableClusterID: "cluster-b"),
                body: "Cluster B row comment.",
                author: "qa",
                timestamp: "2026-07-21T00:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A1",
                    genotype: provisionalName,
                    sample: "AnimalA",
                    stableClusterID: "cluster-b"
                ),
                body: "Cluster B cell comment.",
                author: "qa",
                timestamp: "2026-07-21T00:00:01Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: result)

        controller.testingSelectCandidateCell(stableClusterID: "cluster-b", sample: "AnimalA")

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertEqual(selection?.highlightTarget?.stableClusterID, "cluster-b")
        XCTAssertEqual(selection?.matrixTargets, [
            .cell(
                locus: "MHC-A1",
                genotype: provisionalName,
                sample: "AnimalA",
                stableClusterID: "cluster-b"
            ),
        ])
        XCTAssertTrue(selection?.detailRows.contains { $0 == ("Selected Sample Reads", "11") } == true)

        controller.testingSelectCandidateRow(stableClusterID: "cluster-b")

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["cluster-b"])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Selected Sample" })

        let highlightColor = AnnotationColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: .init(
                genotype: provisionalName,
                locus: "MHC-A1",
                stableClusterID: "cluster-b"
            ),
            scope: .selectedRow,
            color: highlightColor
        ))

        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["cluster-b"])
        XCTAssertEqual(controller.testingCurrentSelectionStyle.fillColor, highlightColor)
    }


    func testFullSizeCandidateSequenceDetailOccupiesVisiblePane() throws {
        let stableClusterID = "cluster-visible"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_680, height: 1_475),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentViewController = controller
        controller.configure(result: makeCandidateResult(
            calls: [makeCall(sample: "CR1178", genotype: "Mafa-A1*018:01:01:01", reads: 8)],
            candidates: [
                makeCandidate(
                    id: stableClusterID,
                    name: "Mafa-AG1*05:08:01:01_16nt_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["CR1178", "CR1178b"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: stableClusterID, sample: "CR1178", reads: 106),
                makeCandidateObservation(cluster: stableClusterID, sample: "CR1178b", reads: 134),
            ],
            candidateSequences: [stableClusterID: String(repeating: "A", count: 2_000)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "NHP11358",
                        alleleName: "Mafa-AG1*05:08:01:01",
                        stableClusterID: stableClusterID
                    ),
                ]
            )
        ))

        controller.testingSelectCandidateRow(stableClusterID: stableClusterID)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
        let detailScrollView = try XCTUnwrap(
            firstAncestor(of: detail, ofType: NSScrollView.self)
        )
        XCTAssertGreaterThan(controller.testingDetailPaneWidth, 1_000)
        XCTAssertEqual(
            detail.bounds.width,
            controller.testingDetailPaneWidth - 20,
            accuracy: 2,
            "The sequence detail must fill the available detail pane."
        )
        XCTAssertEqual(
            detail.bounds.height,
            detailScrollView.contentSize.height - 16,
            accuracy: 2,
            "The sequence detail must grow to fill the visible pane height."
        )
        XCTAssertNotNil(descendants(of: detail).first {
            $0.accessibilityIdentifier() == "mhc-sequence-format"
        })
        XCTAssertNotNil(descendants(of: detail).first {
            $0.accessibilityIdentifier() == "mhc-sequence-text"
        })

        let splitView = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSplitView.self)
        )
        splitView.setPosition(splitView.bounds.height - 320, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let compactDetailHeight = detail.bounds.height
        XCTAssertEqual(
            compactDetailHeight,
            detailScrollView.contentSize.height - 16,
            accuracy: 2
        )

        splitView.setPosition(splitView.bounds.height - 700, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(detail.bounds.height, compactDetailHeight)
        XCTAssertEqual(
            detail.bounds.height,
            detailScrollView.contentSize.height - 16,
            accuracy: 2,
            "Dragging the divider must resize the sequence detail with the pane."
        )
    }


    func testRepeatedCandidateRowSelectionsReuseOneSequenceDetail() throws {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-heavy", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-light", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "cluster-heavy",
                    sample: "AnimalA",
                    reads: 18_000,
                    evidenceCount: 18_000
                ),
                makeCandidateObservation(cluster: "cluster-light", sample: "AnimalA", reads: 7),
            ],
            candidateSequences: [
                "cluster-heavy": String(repeating: "A", count: 32),
                "cluster-light": String(repeating: "C", count: 28),
            ],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-heavy",
                        alleleName: "Mafa-A1*001:01",
                        stableClusterID: "cluster-heavy"
                    ),
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-light",
                        alleleName: "Mafa-A1*002:01",
                        stableClusterID: "cluster-light"
                    ),
                ]
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: "cluster-heavy")
        let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
        let baselineDescendantCount = descendants(of: detail).count
        let baselineConstraintIDs = Set(activeConstraints(in: detail).map(ObjectIdentifier.init))
        XCTAssertLessThan(baselineDescendantCount, 300)

        for _ in 0..<20 {
            controller.testingSelectCandidateRow(stableClusterID: "cluster-light")
            controller.testingSelectCandidateRow(stableClusterID: "cluster-heavy")
            let current = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
            XCTAssertTrue(detail === current)
            XCTAssertEqual(descendants(of: current).count, baselineDescendantCount)
            XCTAssertEqual(
                Set(activeConstraints(in: current).map(ObjectIdentifier.init)),
                baselineConstraintIDs
            )
        }

        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertLessThan(controller.testingCurrentSelectionDetailRows.count, 60)
        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.first { $0.0 == "Genotyping Evidence" }?.1,
            "18,000 alignments in indexed BAM"
        )
    }


    func testRepeatedCandidateRowSelectionsPreserveSequenceDetailConstraintsAtConfiguredContentSizes() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "cluster-heavy",
                    name: "Collision_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
                makeCandidate(
                    id: "cluster-light",
                    name: "Collision_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "cluster-heavy",
                    sample: "AnimalA",
                    reads: 18_000,
                    evidenceCount: 18_000
                ),
                makeCandidateObservation(cluster: "cluster-light", sample: "AnimalA", reads: 7),
            ],
            candidateSequences: [
                "cluster-heavy": String(repeating: "A", count: 32),
                "cluster-light": String(repeating: "C", count: 28),
            ],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-heavy",
                        alleleName: "Mafa-A1*001:01",
                        stableClusterID: "cluster-heavy"
                    ),
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-light",
                        alleleName: "Mafa-A1*002:01",
                        stableClusterID: "cluster-light"
                    ),
                ]
            )
        )

        for percent in [100, 200] {
            settings.contentTextSizePreference = .custom(percent)
            settings.save()
            let controller = GenotypeResultViewController()
            _ = controller.view
            controller.configure(result: result)
            controller.testingSelectCandidateRow(stableClusterID: "cluster-heavy")
            let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
            let baselineConstraintIDs = Set(
                activeConstraints(in: detail).map(ObjectIdentifier.init)
            )

            for _ in 0..<20 {
                controller.testingSelectCandidateRow(stableClusterID: "cluster-light")
                controller.testingSelectCandidateRow(stableClusterID: "cluster-heavy")
                let current = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
                XCTAssertTrue(detail === current, "Content size \(percent)%")
                XCTAssertEqual(
                    Set(activeConstraints(in: current).map(ObjectIdentifier.init)),
                    baselineConstraintIDs,
                    "Content size \(percent)%"
                )
            }
        }
    }


    func testMissingCandidateRecordUsesUnavailableSequenceWithoutReloading() async throws {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "legacy-candidate", name: "Legacy_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "legacy-candidate", sample: "AnimalA", reads: 9),
            ]
        )
        let loaderSpy = KnownSelectionResultLoaderSpy(result: result)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.genotypeResultLoader = { url in
            await loaderSpy.load(url)
        }
        controller.configure(result: result)

        controller.testingSelectCandidateRow(stableClusterID: "legacy-candidate")

        let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertLessThan(descendants(of: detail).count, 300)
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        let loaderInvocationCount = await loaderSpy.currentInvocationCount()
        XCTAssertEqual(loaderInvocationCount, 0)
    }


    func testKnownAndCandidateRowsReuseOneSequenceDetailAndCellsClearIt() throws {
        let knownID = "01_Mafa_A1_Known"
        let knownRecord = makeMHCReferenceVisualizationRecord(
            rawReferenceID: knownID,
            alleleName: "Mafa-A1*001:01"
        )
        let candidateReference = makeCandidateReferenceVisualizationRecord(
            rawReferenceID: "candidate-reference",
            alleleName: "Mafa-A1*002:01",
            stableClusterID: "candidate-a"
        )
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: knownID, reads: 12)],
            candidates: [
                makeCandidate(id: "candidate-a", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate-a", sample: "AnimalA", reads: 8),
            ],
            candidateSequences: ["candidate-a": String(repeating: "A", count: 24)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [knownRecord, candidateReference]
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: "candidate-a")
        let sequenceDetail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))

        controller.testingSelectMatrixRows(genotypes: [knownID], sample: nil)

        XCTAssertTrue(sequenceDetail === onlyAlleleSequenceDetail(in: controller.view))

        controller.testingSelectCandidateCell(stableClusterID: "candidate-a", sample: "AnimalA")

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertTrue(knownAlleleDetails(in: controller.view).isEmpty)

        controller.testingSelectMatrixRows(genotypes: [knownID], sample: nil)

        XCTAssertTrue(sequenceDetail === onlyAlleleSequenceDetail(in: controller.view))
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
    }


    func testUnsupportedKnownCellRefreshDoesNotResurrectPreviousCandidateDetail() throws {
        let root = try TestTempDirectory.make(prefix: "UnsupportedKnownCellRefresh")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let knownID = "01_Mafa_A1_Known"
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: knownID, reads: 12)],
            candidates: [
                makeCandidate(id: "candidate-a", name: "Candidate_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate-a", sample: "AnimalA", reads: 8),
                makeCandidateObservation(cluster: "candidate-a", sample: "AnimalB", reads: 6),
            ],
            candidateSequences: ["candidate-a": String(repeating: "A", count: 24)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeCandidateReferenceVisualizationRecord(
                    rawReferenceID: "candidate-reference",
                    alleleName: "Mafa-A1*002:01",
                    stableClusterID: "candidate-a"
                )]
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: "candidate-a")
        XCTAssertNotNil(onlyAlleleSequenceDetail(in: controller.view))

        controller.testingSelectMatrixCell(genotype: knownID, sample: "AnimalB")
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Selection Type", "Cell")
        })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Sample", "AnimalB")
        })

        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Unsupported cell note"
        ))

        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Selection Type", "Cell")
        })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Cell Comment", "Unsupported cell note")
        })
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: knownID, sample: "AnimalB"),
        ])
    }


    func testSampleAlleleDetailsPreserveCandidateClusterIdentity() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "cluster-b", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        let details = matrix.visibleSampleAlleleDetails(sample: "AnimalA")

        XCTAssertEqual(Set(details.map(\.rowID)), [
            .candidate(stableClusterID: "cluster-a"),
            .candidate(stableClusterID: "cluster-b"),
        ])
        XCTAssertEqual(Set(details.compactMap(\.stableClusterID)), ["cluster-a", "cluster-b"])
        XCTAssertEqual(Set(details.map { $0.support.passedUniqueReads }), [5, 11])
    }


    func testCandidateVisibilityPersistsBeforeRedrawWithoutMutatingCurrentWorkbook() async throws {
        let root = try TestTempDirectory.make(prefix: "CandidateDisplayPersistence")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("current.xlsx")
        let workbookBytes = Data("workbook-must-not-change".utf8)
        try workbookBytes.write(to: workbookURL)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        _ = controller.testingVisibleMatrixGenotypes
        var state = controller.testingDisplayState
        var candidateSettings = try XCTUnwrap(state.mhcCandidateDisplaySettings)
        candidateSettings.showSingletonCandidates = false
        state.mhcCandidateDisplaySettings = candidateSettings

        controller.applyDisplayState(state)

        XCTAssertTrue(controller.testingVisibleMatrixGenotypes.contains("Candidate_nov"), "Redraw must wait for durable sidecar publication")
        await controller.testingWaitForCandidateSettingsPersistence()
        XCTAssertFalse(controller.testingVisibleMatrixGenotypes.contains("Candidate_nov"))
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)
        XCTAssertFalse(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
                .settings.mhcCandidateDisplay.showSingletonCandidates
        )
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: annotationURL))
        )
        XCTAssertEqual(provenance.options.explicit["action"], .string("updateMHCCandidateDisplaySettings"))
        XCTAssertEqual(provenance.options.explicit["showSingletonCandidates"], .boolean(false))
        XCTAssertEqual(provenance.output?.path, annotationURL.path)
        XCTAssertNil(controller.testingCandidatePersistenceWarning)
    }


    func testCandidateTintRequiresExplicitWorkbookRefreshButVisibilityDoesNot() async throws {
        let root = try TestTempDirectory.make(prefix: "CandidateTintWorkbookRefresh")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("current.xlsx")
        let workbookBytes = Data("workbook-must-not-change-until-explicit-update".utf8)
        try workbookBytes.write(to: workbookURL)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        controller.matrixWorkbookUpdateScheduler = scheduler
        var requests: [GenotypeCurrentWorkbookUIRequest] = []
        controller.onCurrentWorkbookSyncRequested = { requests.append($0) }
        _ = controller.view
        controller.configure(result: result)

        var tintState = controller.testingDisplayState
        var tintSettings = try XCTUnwrap(tintState.mhcCandidateDisplaySettings)
        tintSettings.tints[.singletonNovel] = AnnotationColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5)
        tintState.mhcCandidateDisplaySettings = tintSettings
        controller.applyDisplayState(tintState)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertTrue(controller.testingCurrentWorkbookUpdateStatus?.contains("Pending edits") == true)
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)

        controller.editMatrixComment(.init(
            targets: [.column(sample: "AnimalA")],
            intent: .upsert(body: "retain pending tint")
        ))
        controller.testingRequestCurrentWorkbookUpdateAndView()
        XCTAssertEqual(requests.last?.snapshot.annotationOnly, false)
        XCTAssertEqual(requests.last?.action, .synchronize(.updateAndView))
        XCTAssertEqual(scheduler.scheduledCount, 0)

        controller.applyCurrentWorkbookUpdateCompleted(
            result: result,
            annotationOnly: true
        )
        XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertTrue(
            controller.testingCurrentWorkbookUpdateStatus?.contains("Pending edits") == true
        )

        controller.applyCurrentWorkbookUpdateCompleted(result: result)
        XCTAssertFalse(controller.testingCurrentWorkbookNeedsRefresh)

        var visibilityState = controller.testingDisplayState
        var visibilitySettings = try XCTUnwrap(visibilityState.mhcCandidateDisplaySettings)
        visibilitySettings.showSingletonCandidates = false
        visibilityState.mhcCandidateDisplaySettings = visibilitySettings
        controller.applyDisplayState(visibilityState)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertFalse(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)
    }


    func testCandidateSettingsConflictRestoresLatestSidecarAndShowsNonfatalWarning() async throws {
        let root = try TestTempDirectory.make(prefix: "CandidateDisplayConflict")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        let concurrent = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "other")
        var concurrentSettings = concurrent.sidecar.settings.mhcCandidateDisplay
        concurrentSettings.showKnown = false
        try concurrent.updateMHCCandidateDisplaySettings(concurrentSettings)
        var state = controller.testingDisplayState
        var staleSettings = try XCTUnwrap(state.mhcCandidateDisplaySettings)
        staleSettings.showSingletonCandidates = false
        state.mhcCandidateDisplaySettings = staleSettings

        controller.applyDisplayState(state)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertFalse(try XCTUnwrap(controller.testingDisplayState.mhcCandidateDisplaySettings).showKnown)
        XCTAssertTrue(try XCTUnwrap(controller.testingDisplayState.mhcCandidateDisplaySettings).showSingletonCandidates)
        XCTAssertTrue(controller.testingCandidatePersistenceWarning?.localizedCaseInsensitiveContains("changed") == true)
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Candidate_nov"])
    }


    func testRapidCandidateControlEditsCoalesceWithoutLosingTheLatestSettings() async throws {
        let root = try TestTempDirectory.make(prefix: "CandidateDisplayCoalescing")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        var firstState = controller.testingDisplayState
        var firstSettings = try XCTUnwrap(firstState.mhcCandidateDisplaySettings)
        firstSettings.showKnown = false
        firstState.mhcCandidateDisplaySettings = firstSettings
        var latestState = firstState
        var latestSettings = firstSettings
        latestSettings.showSingletonCandidates = false
        latestState.mhcCandidateDisplaySettings = latestSettings

        controller.applyDisplayState(firstState)
        controller.applyDisplayState(latestState)
        await controller.testingWaitForCandidateSettingsPersistence()

        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
            .settings.mhcCandidateDisplay
        XCTAssertFalse(saved.showKnown)
        XCTAssertFalse(saved.showSingletonCandidates)
        XCTAssertTrue(controller.testingVisibleMatrixGenotypes.isEmpty)
    }


    func testCandidateSelectionPersistsByStableIDAcrossTintReloadAndClearsWhenHidden() async throws {
        let root = try TestTempDirectory.make(prefix: "CandidateSelectionReload")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [makeCandidate(id: "stable-a", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "stable-a", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateCell(stableClusterID: "stable-a", sample: "AnimalA")
        var tintState = controller.testingDisplayState
        var tintSettings = try XCTUnwrap(tintState.mhcCandidateDisplaySettings)
        tintSettings.tints[.singletonNovel] = AnnotationColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5)
        tintState.mhcCandidateDisplaySettings = tintSettings

        controller.applyDisplayState(tintState)
        await controller.testingWaitForCandidateSettingsPersistence()
        XCTAssertEqual(controller.testingSelectedCandidateStableClusterID, "stable-a")

        var hiddenState = controller.testingDisplayState
        var hiddenSettings = try XCTUnwrap(hiddenState.mhcCandidateDisplaySettings)
        hiddenSettings.showSingletonCandidates = false
        hiddenState.mhcCandidateDisplaySettings = hiddenSettings
        controller.applyDisplayState(hiddenState)
        await controller.testingWaitForCandidateSettingsPersistence()
        XCTAssertNil(controller.testingSelectedCandidateStableClusterID)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.isEmpty)
    }


    func testCandidateRowsRemainExcludedFromKnownCallQCAndHaplotypeOutputs() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"])],
            observations: [
                makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 500),
                makeCandidateObservation(cluster: "candidate", sample: "AnimalB", reads: 700),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        XCTAssertEqual(result.callCount, 0)
        XCTAssertTrue(result.locusSummaries.isEmpty)
        let workbookCalls = controller.testingCurrentWorkbookHaplotypeCalls()
        XCTAssertEqual(workbookCalls.count, 14)
        XCTAssertTrue(
            workbookCalls.allSatisfy {
                $0.haplotype1.isEmpty
                    && $0.haplotype2.isEmpty
                    && !$0.locus.contains("Candidate")
            }
        )
        XCTAssertFalse(controller.testingHaplotypeMatrixText.contains("Candidate_nov"))
    }

    func testMHCCandidateMatrixKeepsCollidingLabelsAsStableRowsAndShowsAllPopulationsByDefault() throws {
        let knownCall = makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 13)
        let result = makeCandidateResult(
            calls: [knownCall],
            candidates: [
                makeCandidate(
                    id: "cluster-b",
                    name: "Mafa-A1*018:01:01:01_5nt_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalB"]
                ),
                makeCandidate(
                    id: "cluster-a",
                    name: "Mafa-A1*018:01:01:01_5nt_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["AnimalA", "AnimalB"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 11),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()

        matrix.configure(result: result, sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z"))

        XCTAssertEqual(matrix.testingVisibleRows.map(\.population), [.known, .sharedCandidate, .singletonCandidate])
        let collisions = matrix.testingVisibleRows.filter {
            $0.alleleName == "Mafa-A1*018:01:01:01_5nt_nov"
        }
        XCTAssertEqual(collisions.count, 2)
        XCTAssertEqual(collisions.map(\.id), [
            .candidate(stableClusterID: "cluster-a"),
            .candidate(stableClusterID: "cluster-b"),
        ])
        XCTAssertEqual(collisions[0].support(for: "AnimalA")?.passedUniqueReads, 5)
        XCTAssertEqual(collisions[0].evidenceBySample["AnimalA"]?.first?.queryName, "cluster-a|AnimalA")
        XCTAssertTrue(matrix.testingLocusFilterTitles.contains("MHC-A1"))
        matrix.testingSelectCandidateCell(rowID: collisions[0].id, sample: "AnimalB")
        XCTAssertTrue(matrix.testingDrawsSelectionFocus(rowID: collisions[0].id, sample: "AnimalB"))
        XCTAssertFalse(matrix.testingDrawsSelectionFocus(rowID: collisions[1].id, sample: "AnimalB"))
    }


    func testMHCCandidateMatrixShowsStableClusterIDColumnWithFilterSortCopyAndAccessibility() throws {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 13)],
            candidates: [
                makeCandidate(id: "cluster-b", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalB"]),
                makeCandidate(id: "cluster-a", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 11),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        XCTAssertEqual(matrix.testingPinnedColumnTitles, ["", "Genotype", "Cluster ID", "Locus", "Samples", "Unique"])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Known and candidate genotype calls, stable cluster identifiers, loci, and summary statistics"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellValue(
                rowID: .known(locus: "MHC-KNOWN", genotype: "Known"),
                column: .stableClusterID
            ),
            ""
        )
        XCTAssertEqual(
            matrix.testingPinnedCellValue(rowID: .candidate(stableClusterID: "cluster-a"), column: .stableClusterID),
            "cluster-a"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellValue(rowID: .candidate(stableClusterID: "cluster-b"), column: .stableClusterID),
            "cluster-b"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellToolTip(rowID: .candidate(stableClusterID: "cluster-a"), column: .stableClusterID),
            "Stable cluster ID: cluster-a"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellAccessibilityLabel(rowID: .candidate(stableClusterID: "cluster-a"), column: .stableClusterID),
            "Stable cluster ID: cluster-a"
        )
        XCTAssertTrue(matrix.testingPinnedCellIsSelectable(
            rowID: .candidate(stableClusterID: "cluster-a"),
            column: .stableClusterID
        ))

        matrix.testingSetFilter("cluster-b")
        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [.candidate(stableClusterID: "cluster-b")])

        matrix.testingSetFilter("Collision_nov")
        matrix.testingSetSortDescriptor(key: matrix.testingStableClusterIDSortKey, ascending: true)
        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [
            .candidate(stableClusterID: "cluster-a"),
            .candidate(stableClusterID: "cluster-b"),
        ])
    }


    func testCollidingCandidatesKeepStableIdentityThroughSelectionSupportStylesHighlightsAndComments() throws {
        let genotype = "Mafa-A1*018:01:01:01_5nt_nov"
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: genotype, classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "cluster-b", name: genotype, classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalB", reads: 13),
            ]
        )
        let rowA = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-a"
        )
        let rowB = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-b"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: rowA,
                style: .init(fillColor: "#123456"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(target: rowA, body: "Only cluster A", author: "test", timestamp: "2026-07-20T00:00:00Z"),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        let idA = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "cluster-a")
        let idB = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "cluster-b")
        let styledA = try XCTUnwrap(matrix.testingBackgroundColor(rowID: idA, column: .alleleName))
        XCTAssertEqual(Double(styledA.redComponent), 0x12 / 255.0, accuracy: 0.000_001)
        XCTAssertNotEqual(
            matrix.testingBackgroundColor(rowID: idB, column: .alleleName)?.usingColorSpace(.deviceRGB)?.redComponent,
            0x12 / 255.0
        )
        XCTAssertTrue(matrix.testingPinnedCellToolTip(rowID: idA, column: .alleleName)?.contains("Only cluster A") == true)
        XCTAssertFalse(matrix.testingPinnedCellToolTip(rowID: idB, column: .alleleName)?.contains("Only cluster A") == true)

        matrix.testingClickCandidateRowChiclet(rowID: idA)
        matrix.testingClickCandidateRowChiclet(rowID: idB, modifiers: .command)
        XCTAssertEqual(Set(matrix.testingSelectedMatrixTargets), Set([rowA, rowB]))

        matrix.testingClickCandidateRowChiclet(rowID: idA)
        matrix.testingClickCandidateRowChiclet(rowID: idB, modifiers: .shift)
        XCTAssertEqual(Set(matrix.testingSelectedMatrixTargets), Set([rowA, rowB]))

        matrix.testingSelectCandidateCell(rowID: idA, sample: "AnimalA")
        XCTAssertEqual(matrix.testingSelectSupportedCellsInSelectedRow(minimumReads: 1), [
            .cell(locus: "MHC-A1", genotype: genotype, sample: "AnimalA", stableClusterID: "cluster-a"),
            .cell(locus: "MHC-A1", genotype: genotype, sample: "AnimalB", stableClusterID: "cluster-a"),
        ])

        matrix.applyHighlight(.init(
            target: .init(genotype: genotype, locus: "MHC-A1", stableClusterID: "cluster-a"),
            scope: .selectedRow,
            color: AnnotationColor(red: 0.1, green: 0.8, blue: 0.2)
        ))
        let highlightedA = try XCTUnwrap(matrix.testingBackgroundColor(rowID: idA, column: .alleleName))
        XCTAssertEqual(Double(highlightedA.greenComponent), 0.8, accuracy: 0.000_001)
        XCTAssertNotEqual(matrix.testingBackgroundColor(rowID: idB, column: .alleleName)?.usingColorSpace(.deviceRGB)?.greenComponent, 0.8)
    }


    func testCandidateTintContrastUsesCompositedNameCellBackgroundAndManualTextWins() throws {
        let candidates = [
            makeCandidate(id: "dark", name: "Dark_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            makeCandidate(id: "light", name: "Light_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "semi", name: "Semi_ext", classification: .extension, support: .shared, samples: ["AnimalA", "AnimalB"]),
            makeCandidate(id: "manual", name: "Manual_ext", classification: .extension, support: .singleton, samples: ["AnimalA"]),
        ]
        let observations = candidates.flatMap { candidate in
            candidate.supportingSampleIDs.map {
                makeCandidateObservation(cluster: candidate.stableClusterID, sample: $0, reads: 5)
            }
        }
        let result = makeCandidateResult(calls: [], candidates: candidates, observations: observations)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(tints: [
            .sharedNovel: AnnotationColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 1),
            .singletonNovel: AnnotationColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1),
            .sharedExtension: AnnotationColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 0.2),
            .singletonExtension: AnnotationColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 1),
        ])
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A1", genotype: "Manual_ext", stableClusterID: "manual"),
                style: .init(textColor: "#CC1933"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "dark"), column: .alleleName)).hexString, "#FFFFFF")
        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "light"), column: .alleleName)).hexString, "#000000")
        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "semi"), column: .alleleName)).hexString, "#000000")
        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "manual"), column: .alleleName)).hexString, "#CC1933")
        XCTAssertNil(matrix.testingBackgroundColor(rowID: .candidate(stableClusterID: "dark"), column: .locus))
        XCTAssertNotNil(matrix.testingBackgroundColor(rowID: .candidate(stableClusterID: "dark"), column: .sample("AnimalA")))
        XCTAssertNil(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "dark"), column: .locus))
    }


    func testCandidateCellDetailsIncludeLegacyAndExactRowCommentsWithoutCollisionLeakage() throws {
        let root = try TestTempDirectory.make(prefix: "CandidateInheritedComments")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "Mafa-A1*018:01:01:01_5nt_nov"
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: genotype, classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-b", name: genotype, classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 7),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A1", genotype: genotype),
                body: "Inherited legacy row.",
                author: "qa",
                timestamp: "2026-07-20T00:00:00Z"
            ),
            .init(
                target: .row(locus: "MHC-A1", genotype: genotype, stableClusterID: "cluster-a"),
                body: "Cluster A row.",
                author: "qa",
                timestamp: "2026-07-20T00:00:01Z"
            ),
            .init(
                target: .row(locus: "MHC-A1", genotype: genotype, stableClusterID: "cluster-b"),
                body: "Cluster B row.",
                author: "qa",
                timestamp: "2026-07-20T00:00:02Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A1",
                    genotype: genotype,
                    sample: "AnimalA",
                    stableClusterID: "cluster-a"
                ),
                body: "Cluster A cell.",
                author: "qa",
                timestamp: "2026-07-20T00:00:03Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            [.cell(
                locus: "MHC-A1",
                genotype: genotype,
                sample: "AnimalA",
                stableClusterID: "cluster-a"
            )]
        )
        let commentBodies = controller.testingCurrentSelectionDetailRows
            .filter { $0.0.hasSuffix("Comment") }
            .map(\.1)
        XCTAssertEqual(commentBodies.filter { $0 == "Inherited legacy row." }.count, 1)
        XCTAssertEqual(commentBodies.filter { $0 == "Cluster A row." }.count, 1)
        XCTAssertEqual(commentBodies.filter { $0 == "Cluster A cell." }.count, 1)
        XCTAssertFalse(commentBodies.contains("Cluster B row."))
    }


    func testNonFullLengthBundleCannotProjectCandidateRowsSamplesSettingsOrColumns() {
        let knownCall = makeCall(sample: "AnimalA", genotype: "Known", reads: 13)
        let fullLengthResult = makeCandidateResult(
            calls: [knownCall],
            candidates: [
                makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["CandidateOnlySample"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate", sample: "CandidateOnlySample", reads: 7),
            ]
        )
        let nonFullLengthManifest = makeResult(
            samples: [],
            calls: [],
            mhcCandidateArtifacts: fullLengthResult.manifest.mhcCandidateArtifacts
        ).manifest
        let nonFullLengthResult = ONTGenotypeResultBundleData(
            bundleURL: fullLengthResult.bundleURL,
            manifest: nonFullLengthManifest,
            artifacts: fullLengthResult.artifacts,
            stats: fullLengthResult.stats,
            calls: [knownCall],
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 13,
                passedUniqueReads: 13,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [knownCall]
            )],
            haplotypeAnalysis: nil,
            mhcCandidates: fullLengthResult.mhcCandidates,
            mhcUnnameableClusters: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(showKnown: false)
        let matrix = GenotypeComparisonMatrixView()

        matrix.configure(result: nonFullLengthResult, sidecar: sidecar)

        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [.known(locus: "MHC-KNOWN", genotype: "Known")])
        XCTAssertEqual(matrix.testingVisibleSampleNames, ["AnimalA"])
        XCTAssertEqual(matrix.testingPinnedColumnTitles, ["", "Genotype", "Locus", "Samples", "Unique"])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Shared genotype calls, loci, and summary statistics"
        )
    }


    func testMHCCandidateMatrixVisibilitySettingsFilterEachPopulationIndependently() {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 3)],
            candidates: [
                makeCandidate(id: "shared", name: "Shared_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "single", name: "Single_ext", classification: .extension, support: .singleton, samples: ["AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 2),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 4),
                makeCandidateObservation(cluster: "single", sample: "AnimalB", reads: 6),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()

        for (settings, expected) in [
            (ONTMHCCandidateDisplaySettings(showKnown: false), ["Shared_nov", "Single_ext"]),
            (ONTMHCCandidateDisplaySettings(showSharedCandidates: false), ["Known", "Single_ext"]),
            (ONTMHCCandidateDisplaySettings(showSingletonCandidates: false), ["Known", "Shared_nov"]),
            (ONTMHCCandidateDisplaySettings(showKnown: false, showSharedCandidates: false), ["Single_ext"]),
            (ONTMHCCandidateDisplaySettings(showKnown: false, showSingletonCandidates: false), ["Shared_nov"]),
            (ONTMHCCandidateDisplaySettings(showSharedCandidates: false, showSingletonCandidates: false), ["Known"]),
        ] {
            var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
            sidecar.settings.mhcCandidateDisplay = settings
            matrix.configure(result: result, sidecar: sidecar)
            XCTAssertEqual(matrix.testingVisibleGenotypes, expected)
        }
    }


    func testMHCCandidateTintsAreExactAndOnlyColorAlleleNameCells() throws {
        let categories: [(ONTMHCCandidateTintCategory, ONTMHCCandidateClassification, ONTMHCCandidateSupportClass, String)] = [
            (.sharedNovel, .novel, .shared, "shared-nov"),
            (.singletonNovel, .novel, .singleton, "singleton-nov"),
            (.sharedExtension, .extension, .shared, "shared-ext"),
            (.singletonExtension, .extension, .singleton, "singleton-ext"),
        ]
        let candidateSpecs = categories + [
            (.sharedExtension, .partialExtension, .shared, "shared-partial-ext"),
            (.singletonExtension, .partialExtension, .singleton, "singleton-partial-ext"),
        ]
        let customTints = Dictionary(uniqueKeysWithValues: categories.enumerated().map { index, value in
            (value.0, AnnotationColor(
                red: Double(index + 1) / 10,
                green: Double(index + 2) / 10,
                blue: Double(index + 3) / 10,
                alpha: Double(index + 4) / 10
            ))
        })
        let candidates = candidateSpecs.map { _, classification, support, id in
            makeCandidate(
                id: id,
                name: id,
                classification: classification,
                support: support,
                samples: support == .shared ? ["AnimalA", "AnimalB"] : ["AnimalA"]
            )
        }
        let observations = candidates.flatMap { candidate in
            candidate.supportingSampleIDs.map {
                makeCandidateObservation(cluster: candidate.stableClusterID, sample: $0, reads: 5)
            }
        }
        let result = makeCandidateResult(calls: [], candidates: candidates, observations: observations)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(tints: customTints)
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        for (category, _, _, id) in candidateSpecs {
            let rowID = GenotypeCandidateMatrixRowID.candidate(stableClusterID: id)
            let color = try XCTUnwrap(matrix.testingBackgroundColor(rowID: rowID, column: .alleleName))
            let expected = try XCTUnwrap(customTints[category])
            XCTAssertEqual(color.redComponent, expected.red, accuracy: 0.000_000_1)
            XCTAssertEqual(color.greenComponent, expected.green, accuracy: 0.000_000_1)
            XCTAssertEqual(color.blueComponent, expected.blue, accuracy: 0.000_000_1)
            XCTAssertEqual(color.alphaComponent, expected.alpha, accuracy: 0.000_000_1)
            XCTAssertNil(matrix.testingBackgroundColor(rowID: rowID, column: .locus))
            XCTAssertNotNil(matrix.testingBackgroundColor(rowID: rowID, column: .sample("AnimalA")))
        }
    }


    func testAutomaticSupportFillIsUniformAcrossEveryProjectedAlleleKindForGenotypeOnlyONTAndMiSeq()
        throws
    {
        let namedGenotype = "Mafa-A1*001:01"
        let provisionalGenotype = "Mafa-A1*007:08:01:01_1nt_nov"
        let zeroSupportGenotype = "Mafa-A1*999:01"
        let named = makeCall(
            sample: "AnimalA",
            genotype: namedGenotype,
            reads: 1
        )
        let provisional = makeCall(
            sample: "AnimalA",
            genotype: provisionalGenotype,
            reads: 1_200
        )
        let zeroSupport = makeCall(
            sample: "AnimalA",
            genotype: zeroSupportGenotype,
            reads: 0
        )
        let extensionCandidate = makeCandidate(
            id: "uniform-extension",
            name: "Mafa-A1*007:06_ext",
            classification: .extension,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let novel = makeCandidate(
            id: "uniform-novel",
            name: "Mafa-A1*018:01:01:01_5nt_nov",
            classification: .novel,
            support: .shared,
            samples: ["AnimalA", "AnimalB"]
        )
        for kind in [
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ] {
            let extensionCall = makeCall(
                sample: "AnimalA",
                genotype: extensionCandidate.provisionalName,
                reads: 7
            )
            let novelCall = makeCall(
                sample: "AnimalA",
                genotype: novel.provisionalName,
                reads: 300
            )
            let usesCandidateRows = kind == .fullLengthONTMHCGenotype
            let calls = [named, provisional, zeroSupport]
                + (usesCandidateRows ? [] : [extensionCall, novelCall])
            let matrix = GenotypeComparisonMatrixView()
            matrix.configure(result: makeCandidateResult(
                calls: calls,
                candidates:
                    usesCandidateRows ? [extensionCandidate, novel] : [],
                observations: usesCandidateRows ? [
                    makeCandidateObservation(
                        cluster: "uniform-extension",
                        sample: "AnimalA",
                        reads: 7
                    ),
                    makeCandidateObservation(
                        cluster: "uniform-novel",
                        sample: "AnimalA",
                        reads: 300
                    ),
                    makeCandidateObservation(
                        cluster: "uniform-novel",
                        sample: "AnimalB",
                        reads: 2
                    ),
                ] : [],
                provisionalExon2SequencesByGenotype: [
                    provisionalGenotype: ONTGenotypeProvisionalExon2Sequence(
                        genotype: provisionalGenotype,
                        locus: provisional.locusGroup,
                        sequence: "AACCGGTT",
                        sequenceSHA256: String(repeating: "a", count: 64),
                        sampleSupport: [
                            .init(
                                sample: "AnimalA",
                                passedAlignments: 1_200,
                                passedUniqueReads: 1_200
                            ),
                        ]
                    ),
                ],
                kind: kind
            ))

            let supportedColors = try [
                GenotypeCandidateMatrixRowID.known(
                    locus: named.locusGroup,
                    genotype: namedGenotype
                ),
                usesCandidateRows
                    ? .candidate(stableClusterID: "uniform-extension")
                    : .known(
                        locus: extensionCall.locusGroup,
                        genotype: extensionCall.genotype
                    ),
                usesCandidateRows
                    ? .candidate(stableClusterID: "uniform-novel")
                    : .known(
                        locus: novelCall.locusGroup,
                        genotype: novelCall.genotype
                    ),
                .known(
                    locus: provisional.locusGroup,
                    genotype: provisionalGenotype
                ),
            ].map {
                try XCTUnwrap(
                    matrix.testingBackgroundColor(
                        rowID: $0,
                        column: .sample("AnimalA")
                    ),
                    kind.rawValue
                )
            }
            for color in supportedColors.dropFirst() {
                XCTAssertEqual(
                    color,
                    supportedColors[0],
                    kind.rawValue
                )
            }

            XCTAssertNil(matrix.testingBackgroundColor(
                rowID: .known(
                    locus: zeroSupport.locusGroup,
                    genotype: zeroSupportGenotype
                ),
                column: .sample("AnimalA")
            ))
            XCTAssertNil(matrix.testingBackgroundColor(
                rowID: .known(
                    locus: named.locusGroup,
                    genotype: namedGenotype
                ),
                column: .sample("AnimalB")
            ))
        }
    }


    func testAuthoritativeHaplotypedResultRetainsFractionBasedSupportFill() throws {
        let low = makeCall(
            sample: "AnimalA",
            genotype: "Mafa-A1*001:01",
            reads: 10
        )
        let high = makeCall(
            sample: "AnimalA",
            genotype: "Mafa-A1*002:01",
            reads: 90
        )
        for kind in [
            GenotypeResultWorkflowKind.fullLengthONTMHCGenotype,
            .miSeqAmpliconMHCGenotype,
        ] {
            let matrix = GenotypeComparisonMatrixView()
            matrix.configure(result: makeResult(
                samples: [],
                calls: [low, high],
                kind: kind.rawValue,
                haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
            ))

            let lowColor = try XCTUnwrap(
                matrix.testingBackgroundColor(
                    rowID: .known(
                        locus: low.locusGroup,
                        genotype: low.genotype
                    ),
                    column: .sample("AnimalA")
                ),
                kind.rawValue
            )
            let highColor = try XCTUnwrap(
                matrix.testingBackgroundColor(
                    rowID: .known(
                        locus: high.locusGroup,
                        genotype: high.genotype
                    ),
                    column: .sample("AnimalA")
                ),
                kind.rawValue
            )

            XCTAssertLessThan(
                lowColor.alphaComponent,
                highColor.alphaComponent,
                kind.rawValue
            )
            XCTAssertLessThan(
                lowColor.alphaComponent,
                0.20,
                kind.rawValue
            )
        }
    }


    func testMHCCandidateTintIsBelowKnownAnnotationAndSelectionFocus() throws {
        let candidate = makeCandidate(
            id: "candidate",
            name: "Candidate_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [candidate],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A1", genotype: "Candidate_nov"),
                style: .init(fillColor: "#123456"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
            .init(
                target: .row(locus: "MHC-KNOWN", genotype: "Known"),
                style: .init(fillColor: "#654321"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        let candidateID = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "candidate")
        let annotatedCandidateColor = try XCTUnwrap(matrix.testingBackgroundColor(rowID: candidateID, column: .alleleName))
        XCTAssertEqual(annotatedCandidateColor.redComponent, 0x12 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedCandidateColor.greenComponent, 0x34 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedCandidateColor.blueComponent, 0x56 / 255.0, accuracy: 0.000_000_1)
        let annotatedKnownColor = try XCTUnwrap(matrix.testingBackgroundColor(
            rowID: .known(locus: "MHC-KNOWN", genotype: "Known"),
            column: .alleleName
        ))
        XCTAssertEqual(annotatedKnownColor.redComponent, 0x65 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedKnownColor.greenComponent, 0x43 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedKnownColor.blueComponent, 0x21 / 255.0, accuracy: 0.000_000_1)
        matrix.testingSelectCandidateCell(rowID: candidateID, sample: "AnimalA")
        XCTAssertTrue(matrix.testingDrawsSelectionFocus(rowID: candidateID, sample: "AnimalA"))
        XCTAssertEqual(matrix.testingSelectedRowID, candidateID)
    }


    func testMHCCandidateProjectionFailsSoftAndClearsAcrossBundleReload() {
        let matrix = GenotypeComparisonMatrixView()
        let candidateResult = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        matrix.configure(result: candidateResult, sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z"))
        XCTAssertEqual(matrix.testingVisibleRows.count, 2)
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Known and candidate genotype calls, stable cluster identifiers, loci, and summary statistics"
        )

        let legacyManifest = makeResult(samples: candidateResult.samples, calls: candidateResult.calls).manifest
        let legacyResult = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/legacy.lungfishgenotype"),
            manifest: legacyManifest,
            artifacts: candidateResult.artifacts,
            stats: candidateResult.stats,
            calls: candidateResult.calls,
            samples: candidateResult.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: candidateResult.mhcCandidates,
            mhcUnnameableClusters: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
        matrix.configure(result: legacyResult, sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z"))
        XCTAssertEqual(matrix.testingVisibleRows.map(\.population), [.known])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Shared genotype calls, loci, and summary statistics"
        )

        let invalidCandidateResult = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/reloaded.lungfishgenotype"),
            manifest: candidateResult.manifest,
            artifacts: candidateResult.artifacts,
            stats: candidateResult.stats,
            calls: candidateResult.calls,
            samples: candidateResult.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: [.init(code: .candidateArtifactMalformedJSON, detail: "invalid")],
            referenceMetadata: nil
        )
        var invalidSidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        invalidSidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(showKnown: false)
        matrix.configure(result: invalidCandidateResult, sidecar: invalidSidecar)

        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [
            .known(locus: "MHC-KNOWN", genotype: "Known"),
        ])
        XCTAssertEqual(matrix.testingPinnedColumnTitles, ["", "Genotype", "Locus", "Samples", "Unique"])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Shared genotype calls, loci, and summary statistics"
        )
    }

}
