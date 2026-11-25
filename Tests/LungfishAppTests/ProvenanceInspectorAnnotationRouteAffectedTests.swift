// ProvenanceInspectorAnnotationRouteAffectedTests.swift - The Inspector finds the kinds of the annotation S1 rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane AFFECTED-ANNOT (AFFECTED-WORDS-17 item 3). A reference bundle has the sidebar type `.referenceBundle`
// (`InspectorViewController+PublicAPI.swift`, `updateBundleMetadata`), which named no kind before. A track source has no
// sidebar type and reads the kind of its own record. No Inspector source exists for an annotation track, since
// `configureVariantSources` lists the variant tracks only, so the record of a GFF3 or GTF import is read on the bundle.

import XCTest
import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ProvenanceInspectorAnnotationRouteAffectedTests: XCTestCase {
    private typealias Name = AffectedResults.RecordName

    private func item(_ type: SidebarItemType?) -> ProvenanceInspectableItem {
        ProvenanceInspectableItem(
            url: URL(fileURLWithPath: "/tmp/affected-annotation-route-test"), sidebarType: type, contentMode: .genomics,
            displayName: "result"
        )
    }

    private func kind(_ item: ProvenanceInspectableItem, _ envelope: ProvenanceEnvelope? = nil) -> String? {
        ProvenanceInspectorViewModel.affectedResultKind(for: item, envelope: envelope)?.rawValue
    }

    private func record(
        _ workflow: String, app: String = "Lungfish 2026.11.16 (14223)", explicit: [String: ParameterValue] = [:],
        argv: [String] = [], inputs: [String] = [], steps: [ProvenanceStep] = []
    ) -> ProvenanceEnvelope {
        var envelope = ProvenanceEnvelope.fixture()
        envelope.workflowName = workflow
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: app)
        envelope.options = ProvenanceOptions(explicit: explicit)
        envelope.argv = argv
        envelope.files = inputs.map {
            ProvenanceFileDescriptor(
                path: $0, checksumSHA256: String(repeating: "a", count: 64), fileSize: 12, format: .unknown, role: .input
            )
        }
        envelope.steps = steps
        return envelope
    }

    private func extraction(sourceBundle: Bool = true, joined: Bool = false, app: String = "Lungfish 2026.11.16 (14223)")
        -> ProvenanceEnvelope {
        record(
            Name.extractSequence, app: app,
            explicit: [
                "source_bundle": sourceBundle ? .file(URL(fileURLWithPath: "/p/Source.lungfishref")) : .null,
                "concatenate_exons": .boolean(joined),
            ],
            argv: ["lungfish-cli", "extract", "sequence", "/p/Source.lungfishref", "chr1:3-6", "--bundle"]
        )
    }

    /// The backlog ids the Warnings of a lookup of `item` that found `envelope` show.
    private func shown(_ item: ProvenanceInspectableItem, _ envelope: ProvenanceEnvelope) -> [String] {
        let model = ProvenanceInspectorViewModel()
        model.resolvedEnvelope = envelope
        model.applyAffectedResults(kind: ProvenanceInspectorViewModel.affectedResultKind(for: item, envelope: envelope))
        return model.warnings.filter { $0.title == ProvenanceInspectorViewModel.affectedResultsWarningTitle }
            .compactMap { warning in AffectedResults.rows.first { $0.words == warning.message }?.backlogID }
    }

    func testAReferenceBundleNamesTheKindOfAnExtractionRecord() {
        XCTAssertEqual(kind(item(.referenceBundle), extraction()), "sequenceExtractionBundle")
        XCTAssertEqual(shown(item(.referenceBundle), extraction()), ["ANNOT-EXPORT-MISSING-TRACK", "EXTRACT-SAME-SITE-DEDUP"])
        XCTAssertEqual(
            shown(item(.referenceBundle), extraction(joined: true)),
            ["ANNOT-EXPORT-MISSING-TRACK", "EXTRACT-SAME-SITE-DEDUP", "GTF-SPLICE"]
        )
        XCTAssertEqual(shown(item(.referenceBundle), extraction(app: "Lungfish 2026.11.17 (14643)")), [], "a later build")
    }

    func testAReferenceBundleNamesTheKindOfAGFF3Import() {
        let imported = record(Name.annotationTrackImport, inputs: ["/data/genes.gff3"])
        XCTAssertEqual(kind(item(.referenceBundle), imported), "annotationTrackImport")
        XCTAssertEqual(shown(item(.referenceBundle), imported), ["ANNOT-IMPORT-SAME-SITE-DEDUP"])
        let bed = record(Name.annotationTrackImport, inputs: ["/data/primers.bed"])
        XCTAssertNil(kind(item(.referenceBundle), bed))
    }

    func testAReferenceBundleOfAnyOtherRecordStillShowsNoRow() {
        XCTAssertNil(kind(item(.referenceBundle)), "no record")
        XCTAssertNil(kind(item(.referenceBundle), extraction(sourceBundle: false)), "a FASTA input carries no tracks")
        XCTAssertNil(kind(item(.referenceBundle), record("lungfish fastq trim")))
        XCTAssertNil(kind(item(.referenceBundle), record("lungfish variants call", steps: [])), "no iVar step")
    }

    func testATrackSourceReadsTheKindOfItsOwnRecord() {
        let ivar = ProvenanceStep(
            toolName: "ivar", toolVersion: "1", argv: ["/tools/ivar", "variants", "-p", "p", "-r", "ref.fa"], inputs: [],
            outputs: [], exitStatus: 0, wallTimeSeconds: 1, stderr: nil, startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
        let calls = record(Name.variantsCall, app: "Lungfish 2026.11.7 (12972)", steps: [ivar])
        XCTAssertEqual(kind(item(nil), calls), "variantCalls")
        XCTAssertEqual(shown(item(nil), calls), ["IVAR-CODON-MERGE", "ANNOT-EXPORT-MISSING-TRACK"])
        let imported = record(Name.annotationTrackImport, inputs: ["/data/genes.gtf"])
        XCTAssertEqual(kind(item(nil), imported), "annotationTrackImport", "the nil case reads a track's own record")
        XCTAssertEqual(shown(item(nil), imported), ["ANNOT-IMPORT-SAME-SITE-DEDUP"])
    }
}
