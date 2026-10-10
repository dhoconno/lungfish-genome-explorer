import XCTest
import LungfishCore
@testable import LungfishIO
import LungfishTestSupport

/// A full-length call takes its source locus from its reference record (N9).
///
/// Full-length ONT MHC calls carry the reference sequence ID, here an IPD
/// accession, as the genotype. Parsed alone, the accession is its own
/// pseudo-locus, so every call read 100% of locus. The result stamps each
/// call with the locus its record names when it is built. The fixtures are
/// synthetic, shaped like an IPD-MHC Mafa record store.
final class GenotypeReferenceRecordLocusTests: XCTestCase {
    static let fullLength = GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue
    static let amplicon = GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue

    /// Records keyed by accession, each with an allele and a gene.
    static func metadata(
        _ records: [String: (allele: String?, gene: String?)],
        alleleFieldKey: String? = "feature.allele"
    ) -> ONTGenotypeReferenceMetadata {
        ONTGenotypeReferenceMetadata(
            fields: [
                GenBankRecordDatabase.FieldDefinition(
                    key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0),
                GenBankRecordDatabase.FieldDefinition(
                    key: "feature.gene", displayTitle: "Gene", valueType: "text", sourceCategory: "feature", preferredOrder: 1),
            ],
            recordsBySequenceName: records.mapValues { record in
                var values: [String: String] = [:]
                values["feature.allele"] = record.allele
                values["feature.gene"] = record.gene
                return values
            },
            alleleFieldKey: alleleFieldKey
        )
    }

    static let mafaRecords: [String: (allele: String?, gene: String?)] = [
        "NHP01270": ("Mafa-A2*05:25:01:01", "A2"),
        "NHP01718": ("Mafa-A1*018:01:01:01", "A1"),
        "NHP05001": ("Mafa-I*01:18:01:01", "I"),
        "NHP05002": ("Mafa-G*02:01", "G"),
        "NHP05003": ("Mafa-B02Ps*01:01", "B02Ps"),
        "NHP05004": ("Mafa-AG5*01:02", "AG5"),
        "NHP05005": ("Mafa-J*01:01", "J"),
        "NHP05006": ("Mafa-E*02:01:01", "E"),
        "NHP05007": ("Mafa-B*046:12:01:01", "B"),
    ]

    static func result(
        calls: [ONTGenotypeCall],
        kind: String = fullLength,
        referenceMetadata: ONTGenotypeReferenceMetadata? = metadata(mafaRecords),
        candidates: ONTMHCCandidateAllelesDocument? = nil
    ) -> ONTGenotypeResultBundleData {
        let samples = Dictionary(grouping: calls, by: \.sample).sorted { $0.key < $1.key }.map { sample, calls in
            ONTGenotypeSampleResult(
                sample: sample, passedAlignments: calls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: calls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: calls
            )
        }
        let base = GenotypeTestFixtures.makeResult(
            samples: samples, calls: calls, kind: kind, referenceMetadata: referenceMetadata)
        guard let candidates else { return base }
        return ONTGenotypeResultBundleData(
            bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts, stats: base.stats,
            calls: calls, samples: base.samples, haplotypeAnalysis: nil,
            mhcCandidates: candidates, mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:], mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: .empty, mhcReferenceVisualizations: nil, integrityWarnings: [],
            referenceMetadata: referenceMetadata, provisionalExon2SequencesByGenotype: [:],
            provisionalExon2ArtifactURLs: .empty
        )
    }

    static func call(_ sample: String, _ genotype: String, _ reads: Int) -> ONTGenotypeCall {
        GenotypeTestFixtures.makeCall(sample: sample, genotype: genotype, reads: reads)
    }

    // MARK: The resolution rule

    func testTheRecordAllelePrefixNamesTheLocus() {
        let resolve = GenotypeHaplotypeLocusResolver.referenceRecordLocus(alleleName:gene:)
        XCTAssertEqual(resolve("Mafa-A2*05:25:01:01", "A2"), "MHC-A")
        XCTAssertEqual(resolve("Mafa-A1*018:01:01:01", nil), "MHC-A")
        XCTAssertEqual(resolve("Mafa-I*01:18:01:01", nil), "MHC-I",
                       "the full allele would parse to MHC-I*01:18:01:01")
        XCTAssertEqual(resolve("Mafa-J*01:01", nil), "MHC-J")
        XCTAssertEqual(resolve("Mafa-G*02:01", nil), "MHC-G")
        XCTAssertEqual(resolve("Mafa-E*02:01:01", nil), "MHC-E")
        XCTAssertEqual(resolve("Mafa-F*01:01", nil), "MHC-F")
        XCTAssertEqual(resolve("Mafa-K*01:01", nil), "MHC-K")
        for gene in ["A1", "A2", "A3", "A4", "A5", "A6"] {
            XCTAssertEqual(resolve("Mafa-\(gene)*01:01", nil), "MHC-A", gene)
            XCTAssertEqual(resolve(nil, gene), "MHC-A", gene)
        }
        for gene in ["AG1", "AG2", "AG3", "AG4", "AG5", "AG6"] {
            XCTAssertEqual(resolve("Mafa-\(gene)*01:01", nil), "MHC-AG", "\(gene) stays apart from MHC-A")
            XCTAssertEqual(resolve(nil, gene), "MHC-AG", gene)
        }
        for gene in ["B", "B16", "B02Ps", "B10Ps", "B14Ps", "B21Ps"] {
            XCTAssertEqual(resolve("Mafa-\(gene)*01:01", nil), "MHC-B", gene)
            XCTAssertEqual(resolve(nil, gene), "MHC-B", gene)
        }
        XCTAssertEqual(resolve(nil, "I"), "MHC-I")
        XCTAssertNil(resolve(nil, nil))
        XCTAssertNil(resolve("  ", " "))
        XCTAssertNil(resolve("*01:01", nil))
    }

    // MARK: Stamping a full-length result

    /// Two A alleles of one animal share the MHC-A total, so NHP01270 reads
    /// 674 of 1,386 and no longer 100% of its own pseudo-locus.
    func testAFullLengthAccessionCallTakesTheLocusOfItsRecordAllele() throws {
        let result = Self.result(calls: [
            Self.call("CR1178", "NHP01270", 674),
            Self.call("CR1178", "NHP01718", 712),
        ])
        let a2 = try XCTUnwrap(result.calls.first { $0.genotype == "NHP01270" })
        XCTAssertEqual(a2.locusGroup, "MHC-A")
        XCTAssertEqual(a2.genotypeLocusGroup, "MHC-NHP01270", "the genotype alone still names the old pseudo-locus")
        XCTAssertEqual(a2.genotype, "NHP01270", "the genotype is unchanged")
        let denominator = GenotypeLocusDenominator(result: result)
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: a2)), 674.0 / 1_386.0, accuracy: 1e-12)
        XCTAssertEqual(result.samples.first?.calls.map(\.locusGroup), ["MHC-A", "MHC-A"],
                       "the per-sample calls are stamped too")
        XCTAssertEqual(result.integrityWarnings, [])
    }

    func testAMafaA1CandidateAddsToTheStampedMHCATotal() throws {
        let candidates = GenotypeLocusDenominatorFixtures.candidateDocument(
            candidates: [("novel-1", "Mafa-A1*900:01_nov", "MHC-A1")],
            observations: [("novel-1", "CR1178", 114)]
        )
        let result = Self.result(calls: [
            Self.call("CR1178", "NHP01270", 674),
            Self.call("CR1178", "NHP01718", 712),
        ], candidates: candidates)
        let a2 = try XCTUnwrap(result.calls.first { $0.genotype == "NHP01270" })
        let denominator = GenotypeLocusDenominator(result: result)
        XCTAssertEqual(denominator.total(for: a2), 1_500)
        XCTAssertEqual(try XCTUnwrap(denominator.fraction(for: a2)), 674.0 / 1_500.0, accuracy: 1e-12)
    }

    func testEachMafaGeneLandsOnItsOwnLocus() {
        let result = Self.result(calls: [
            Self.call("S1", "NHP05001", 10),
            Self.call("S1", "NHP05002", 10),
            Self.call("S1", "NHP05003", 10),
            Self.call("S1", "NHP05004", 10),
            Self.call("S1", "NHP05005", 10),
            Self.call("S1", "NHP05006", 10),
            Self.call("S1", "NHP05007", 10),
        ])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.calls.map { ($0.genotype, $0.locusGroup) }), [
            "NHP05001": "MHC-I",
            "NHP05002": "MHC-G",
            "NHP05003": "MHC-B",
            "NHP05004": "MHC-AG",
            "NHP05005": "MHC-J",
            "NHP05006": "MHC-E",
            "NHP05007": "MHC-B",
        ])
        // I, J, G and E never pool into A or B, and AG stays apart from A.
        let denominator = GenotypeLocusDenominator(result: result)
        for call in result.calls where !["NHP05003", "NHP05007"].contains(call.genotype) {
            XCTAssertEqual(denominator.total(for: call), 10, call.genotype)
        }
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-B"), 20)
    }

    func testTheGeneNamesTheLocusWhenTheRecordHasNoAllele() {
        let result = Self.result(
            calls: [Self.call("S1", "NHP09001", 10), Self.call("S1", "NHP09002", 10)],
            referenceMetadata: Self.metadata(["NHP09001": (nil, "AG5"), "NHP09002": ("", "I")])
        )
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-AG", "MHC-I"])
        XCTAssertEqual(result.integrityWarnings, [])
    }

    func testTheMetadataAlleleFieldIsTheOneRead() {
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [],
            recordsBySequenceName: ["NHP09001": ["record.allele_name": "Mafa-J*01:01", "feature.allele": "Mafa-B*01:01"]],
            alleleFieldKey: "record.allele_name"
        )
        let result = Self.result(calls: [Self.call("S1", "NHP09001", 10)], referenceMetadata: metadata)
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-J"])
    }

    func testAnAccessionWithoutARecordKeepsItsLocusAndWarns() throws {
        let result = Self.result(calls: [
            Self.call("S1", "NHP01270", 674),
            Self.call("S1", "NHP77777", 20),
            Self.call("S2", "NHP77777", 30),
            Self.call("S1", "NHP77778", 5),
        ])
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-A", "MHC-NHP77777", "MHC-NHP77777", "MHC-NHP77778"])
        let warning = try XCTUnwrap(result.integrityWarnings.first { $0.code == .referenceLocusUnresolved })
        XCTAssertEqual(result.integrityWarnings.count, 1)
        XCTAssertEqual(warning.code.rawValue, "reference-locus-unresolved")
        XCTAssertTrue(warning.detail.hasPrefix("3 full-length calls name a reference sequence"), warning.detail)
        XCTAssertTrue(warning.detail.contains("(NHP77777, NHP77778)"), warning.detail)
        for forbidden in ["\u{2014}", ";"] {
            XCTAssertFalse(warning.detail.contains(forbidden), forbidden)
        }

        let noStore = Self.result(calls: [Self.call("S1", "NHP01270", 674)], referenceMetadata: nil)
        XCTAssertEqual(noStore.calls.map(\.locusGroup), ["MHC-NHP01270"], "without a record store nothing is stamped")
        XCTAssertEqual(noStore.integrityWarnings.map(\.code), [.referenceLocusUnresolved])
    }

    func testAnAccessionListLongerThanFiveIsCut() throws {
        let calls = (1...7).map { Self.call("S1", "NHP7000\($0)", 1) }
        let result = Self.result(calls: calls, referenceMetadata: Self.metadata([:]))
        let warning = try XCTUnwrap(result.integrityWarnings.first)
        XCTAssertTrue(warning.detail.contains("(NHP70001, NHP70002, NHP70003, NHP70004, NHP70005 and 2 more)"), warning.detail)
    }

    func testAnAlleleNameWithoutARecordNeedsNoWarning() {
        let result = Self.result(calls: [Self.call("S1", "Mafa-A1*001:01", 10)], referenceMetadata: Self.metadata([:]))
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-A"])
        XCTAssertEqual(result.integrityWarnings, [])
    }

    func testAnAlleleAndGeneAtDifferentLociTakeTheAlleleAndWarn() throws {
        let result = Self.result(
            calls: [Self.call("S1", "NHP09001", 10)],
            referenceMetadata: Self.metadata(["NHP09001": ("Mafa-E*02:01", "G")])
        )
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-E"])
        let warning = try XCTUnwrap(result.integrityWarnings.first)
        XCTAssertEqual(warning.code, .referenceLocusConflict)
        XCTAssertTrue(warning.detail.contains("(NHP09001)"), warning.detail)
    }

    func testAmpliconResultsAreNeverStamped() {
        let calls = [Self.call("S1", "NHP01270", 674), Self.call("S1", "NHP01718", 712)]
        let result = Self.result(calls: calls, kind: Self.amplicon)
        XCTAssertEqual(result.calls, calls)
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-NHP01270", "MHC-NHP01718"])
        XCTAssertEqual(result.integrityWarnings, [])
    }

    func testSourceLociMetadataOutranksTheRecord() {
        let genotype = "MCM_0102|source_loci=MHC-AG1|alleles=Mafa-AG_05:02"
        let result = Self.result(
            calls: [Self.call("S1", genotype, 10)],
            referenceMetadata: Self.metadata([genotype: ("Mafa-B*01:01", "B")])
        )
        XCTAssertEqual(result.calls.map(\.locusGroup), ["MHC-AG"])
        XCTAssertNil(result.calls[0].sourceLocus)
    }

    /// A tie of two references of one cluster now sits at one locus, so the
    /// D2 rule counts it once there.
    func testATieOfTwoAccessionsAtOneLocusCountsOnce() throws {
        func tied(_ genotype: String) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: "S1", genotype: genotype, passedAlignments: 500, passedUniqueReads: 500,
                sampleTotalReads: nil, sampleUniqueRetainedReads: nil, sampleUniqueRetainedPercent: nil,
                overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil,
                ambiguousWith: ["NHP01270", "NHP01718"]
            )
        }
        let result = Self.result(calls: [tied("NHP01270"), tied("NHP01718"), Self.call("S1", "NHP05007", 40)])
        let denominator = GenotypeLocusDenominator(result: result)
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-A"), 500)
        XCTAssertEqual(denominator.total(sample: "S1", sourceLocus: "MHC-B"), 40)
    }

    // MARK: Encoding

    func testAStampedCallEncodesTheSameBytesAsBefore() throws {
        let plain = Self.call("CR1178", "NHP01270", 674)
        let stamped = try XCTUnwrap(Self.result(calls: [plain]).calls.first)
        XCTAssertEqual(stamped.sourceLocus, "MHC-A")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plainBytes = try encoder.encode(plain)
        XCTAssertEqual(try encoder.encode(stamped), plainBytes)
        XCTAssertFalse(String(decoding: plainBytes, as: UTF8.self).contains("sourceLocus"))
        let decoded = try JSONDecoder().decode(ONTGenotypeCall.self, from: plainBytes)
        XCTAssertNil(decoded.sourceLocus)
    }

    func testADecodedResultStampsAgainFromItsMetadata() throws {
        let original = Self.result(calls: [
            Self.call("CR1178", "NHP01270", 674),
            Self.call("CR1178", "NHP77777", 3),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleData.self, from: data)
        XCTAssertEqual(decoded.calls.map(\.locusGroup), ["MHC-A", "MHC-NHP77777"])
        XCTAssertEqual(decoded.integrityWarnings.map(\.code), [.referenceLocusUnresolved], "the warning is not doubled")
        XCTAssertEqual(decoded, original)
    }
}
