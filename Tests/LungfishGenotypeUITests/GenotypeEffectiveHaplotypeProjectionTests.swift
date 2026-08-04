import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

final class GenotypeEffectiveHaplotypeProjectionTests: XCTestCase {
    func testBuildsImmutableEffectiveSlotsAndOrderedSnapshots() throws {
        let analysis = makeAnalysis()
        let originalManualAssignments = [
            manualAssignment(sample: "Sample-1", locus: "MHC-A", slot: .h1, label: "manual-A1"),
            manualAssignment(sample: "Sample-2", locus: "MHC-B", slot: .h2, label: "manual-B2"),
        ]
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-03T00:00:00Z")
        sidecar.manualHaplotypeAssignments = originalManualAssignments
        sidecar.callOverrides = [
            override(sample: "Sample-1", locus: "MHC-A", slot: .h1, value: "M2A", timestamp: "2026-08-03T01:00:00Z"),
            override(sample: "Sample-1", locus: "MHC-A", slot: .h2, value: "M3A", timestamp: "2026-08-03T01:00:00Z"),
            override(sample: "Sample-1", locus: "MHC-B", slot: .h1, value: "M4B", timestamp: "2026-08-03T01:00:00Z"),
            override(sample: "Sample-2", locus: "MHC-B", slot: .h1, value: "M5B", timestamp: "2026-08-03T01:00:00Z"),
            override(sample: "Sample-2", locus: "MHC-B", slot: .h2, value: "M6B", timestamp: "2026-08-03T01:00:00Z"),
        ]

        let projection = GenotypeEffectiveHaplotypeProjection(
            analysis: analysis,
            sidecar: sidecar
        )

        XCTAssertEqual(
            projection.identity,
            GenotypeEffectiveHaplotypeIdentity(
                assayID: "MHC-exon2-miSeq",
                analysisRevisionID: "revision-7",
                definitionSetID: "definition-2"
            )
        )
        XCTAssertEqual(projection.orderedSamples, ["Sample-1", "Sample-2"])
        XCTAssertEqual(projection.orderedLoci, ["MHC-A", "MHC-B"])

        assertValue(
            projection,
            sample: "Sample-1",
            locus: "MHC-A",
            slot: .h1,
            baseline: "M1A",
            effective: "M2A",
            status: .called,
            source: .analystOverride
        )
        assertValue(
            projection,
            sample: "Sample-1",
            locus: "MHC-B",
            slot: .h2,
            baseline: "ERR: NO HAP",
            effective: "ERR: NO HAP",
            status: .noHaplotype,
            source: .pipeline
        )
        assertValue(
            projection,
            sample: "Sample-2",
            locus: "MHC-A",
            slot: .h1,
            baseline: "Not assayed",
            effective: "Not assayed",
            status: .notAssayed,
            source: .pipeline
        )
        assertValue(
            projection,
            sample: "Sample-2",
            locus: "MHC-B",
            slot: .h2,
            baseline: "ERR: TMH",
            effective: "M6B",
            status: .called,
            source: .analystOverride
        )

        let sampleSnapshot = try XCTUnwrap(projection.snapshot(sample: "Sample-1"))
        XCTAssertEqual(sampleSnapshot.loci.map(\.locus), ["MHC-A", "MHC-B"])
        XCTAssertEqual(sampleSnapshot.loci.map(\.status), [.called, .noHaplotype])
        XCTAssertEqual(
            projection.snapshot(sample: "Sample-2", locus: "MHC-B")?.status,
            .called
        )
        XCTAssertNil(projection.snapshot(sample: "missing"))
        XCTAssertNil(projection.snapshot(sample: "Sample-1", locus: "missing"))
        XCTAssertTrue(
            projection.hasOverride(
                sample: "Sample-1",
                locus: "MHC-A",
                slot: .h1
            )
        )
        XCTAssertFalse(
            projection.hasOverride(
                sample: "missing",
                locus: "MHC-A",
                slot: .h1
            )
        )

        XCTAssertEqual(sidecar.manualHaplotypeAssignments, originalManualAssignments)
        XCTAssertFalse(
            projection.values.values.contains { value in
                value.effective.hasPrefix("manual-")
            }
        )
    }

    func testLatestParseableTimestampWinsWithLaterSidecarOrderBreakingTies() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-03T00:00:00Z")
        sidecar.callOverrides = [
            override(sample: "Sample-1", locus: "MHC-A", slot: .h1, value: "older", timestamp: "2026-08-03T00:59:59Z"),
            override(sample: "Sample-1", locus: "MHC-A", slot: .h1, value: "tie-first", timestamp: "2026-08-03T01:00:00.500Z"),
            override(sample: "Sample-1", locus: "MHC-A", slot: .h1, value: "malformed", timestamp: "later-ish"),
            override(sample: "Sample-1", locus: "MHC-A", slot: .h1, value: "tie-second", timestamp: "2026-08-03T01:00:00.500Z"),
        ]

        let projection = GenotypeEffectiveHaplotypeProjection(
            analysis: makeAnalysis(),
            sidecar: sidecar
        )

        XCTAssertEqual(
            projection.value(sample: "Sample-1", locus: "MHC-A", slot: .h1)?.effective,
            "tie-second"
        )
        XCTAssertEqual(
            projection.value(sample: "Sample-1", locus: "MHC-A", slot: .h1)?.source,
            .analystOverride
        )
    }

    func testMalformedTimestampCannotCreateAnEffectiveOverride() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-03T00:00:00Z")
        sidecar.callOverrides = [
            override(sample: "Sample-1", locus: "MHC-A", slot: .h2, value: "malformed", timestamp: "not-a-timestamp"),
        ]

        let projection = GenotypeEffectiveHaplotypeProjection(
            analysis: makeAnalysis(),
            sidecar: sidecar
        )

        assertValue(
            projection,
            sample: "Sample-1",
            locus: "MHC-A",
            slot: .h2,
            baseline: "M1A",
            effective: "M1A",
            status: .called,
            source: .pipeline
        )
    }

    func testOverridingH1NeverHidesUnresolvedH2() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-08-03T00:00:00Z")
        sidecar.callOverrides = [
            override(sample: "Sample-1", locus: "MHC-B", slot: .h1, value: "M4B", timestamp: "2026-08-03T01:00:00Z"),
        ]

        let projection = GenotypeEffectiveHaplotypeProjection(
            analysis: makeAnalysis(),
            sidecar: sidecar
        )

        assertValue(
            projection,
            sample: "Sample-1",
            locus: "MHC-B",
            slot: .h1,
            baseline: "ERR: NO HAP",
            effective: "M4B",
            status: .called,
            source: .analystOverride
        )
        assertValue(
            projection,
            sample: "Sample-1",
            locus: "MHC-B",
            slot: .h2,
            baseline: "ERR: NO HAP",
            effective: "ERR: NO HAP",
            status: .noHaplotype,
            source: .pipeline
        )
        XCTAssertEqual(
            projection.snapshot(sample: "Sample-1", locus: "MHC-B")?.status,
            .noHaplotype
        )
    }

    private func makeAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "definition-2",
            definitionSetName: "Definition 2",
            speciesName: "Macaque",
            generatedAt: "2026-08-03T00:00:00Z",
            analysisRevisionID: "revision-7",
            source: .deterministic,
            samples: [
                .init(sample: "Sample-1", calls: [
                    call(locus: "MHC-A", h1: "M1A", h2: "M1A", status: .called),
                    call(locus: "MHC-B", h1: "ERR: NO HAP", h2: "ERR: NO HAP", status: .noHaplotype),
                ]),
                .init(sample: "Sample-2", calls: [
                    call(locus: "MHC-B", h1: "ERR: TMH", h2: "ERR: TMH", status: .tooManyHaplotypes),
                    call(locus: "MHC-A", h1: "Not assayed", h2: "Not assayed", status: .notAssayed),
                ]),
            ]
        )
    }

    private func call(
        locus: String,
        h1: String,
        h2: String,
        status: GenotypeHaplotypeCallStatus
    ) -> GenotypeHaplotypeLocusCall {
        GenotypeHaplotypeLocusCall(
            locus: locus,
            sourceLocus: locus,
            haplotype1: h1,
            haplotype2: h2,
            status: status,
            matchedHaplotypes: [],
            observedGenotypeCount: 0,
            observedGenotypes: []
        )
    }

    private func override(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        value: String,
        timestamp: String
    ) -> GenotypeAnnotationSidecar.CallOverride {
        .init(
            sample: sample,
            locus: locus,
            slot: slot,
            originalCall: "pipeline",
            overrideCall: value,
            reasonTag: .analystJudgment,
            rationale: "test",
            author: "Analyst",
            timestamp: timestamp
        )
    }

    private func manualAssignment(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        label: String
    ) -> ManualHaplotypeAssignment {
        .init(
            sample: sample,
            locus: locus,
            slot: slot,
            label: label,
            colorTokenIndex: 0,
            diagnosticAlleles: [],
            notes: "preserve"
        )
    }

    private func assertValue(
        _ projection: GenotypeEffectiveHaplotypeProjection,
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        baseline: String,
        effective: String,
        status: GenotypeHaplotypeCallStatus,
        source: GenotypeEffectiveHaplotypeValue.Source,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            projection.value(sample: sample, locus: locus, slot: slot),
            GenotypeEffectiveHaplotypeValue(
                baseline: baseline,
                effective: effective,
                status: status,
                source: source
            ),
            file: file,
            line: line
        )
    }
}
