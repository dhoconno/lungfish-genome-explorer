// ClassifierSampleMetadataImportTests.swift - Live classifier metadata import coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishEsVirituUI
import LungfishIO
import LungfishKit

@MainActor
final class ClassifierSampleMetadataImportTests: XCTestCase {
    func testGenericInspectorImportImmediatelyPublishesToLiveEsVirituConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassifierSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = try EsVirituDatabase.create(
            at: root.appendingPathComponent("esviritu.sqlite"),
            rows: [
                EsVirituDetectionRow(
                    sample: "sample-a", virusName: "Example virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000001.1",
                    assembly: "ASM_1", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
                ),
                EsVirituDetectionRow(
                    sample: "sample-b", virusName: "Other virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000002.1",
                    assembly: "ASM_2", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 2, uniqueReads: 2,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 2, bamPath: nil, bamIndexPath: nil
                ),
            ],
            metadata: [:]
        )
        let viewer = EsVirituResultViewController()
        _ = viewer.view
        viewer.configureFromDatabase(database, resultURL: root)

        let context = try SampleMetadataPresentationContext(
            finalResultURL: root,
            identityIndex: SampleIdentityIndex(samples: [
                .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
                .init(canonicalID: "sample-b", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
            ]),
            importContext: .init(
                resultID: root.lastPathComponent,
                provenanceID: "esviritu:\(root.lastPathComponent)",
                workflowName: "EsViritu",
                workflowVersion: "test"
            )
        )
        let consumerToken = context.observe(viewer)
        defer { context.removeObserver(consumerToken) }

        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.updateClassifierSampleState(
            pickerState: viewer.samplePickerState,
            entries: viewer.sampleEntries,
            strippedPrefix: viewer.strippedPrefix,
            presentationContext: context,
            attachments: BundleAttachmentStore(bundleURL: root)
        )

        let sourceURL = root.appendingPathComponent("metadata.tsv")
        try """
        Sample\tCohort\tSite
        sample-a\ttreated\tHilo
        sample-b\tcontrol\t\n
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        try inspector.testingImportMetadata(from: sourceURL)

        XCTAssertEqual(context.sampleMetadataStore?.columnNames, ["Cohort", "Site"])
        XCTAssertEqual(viewer.sampleMetadataStore?.records["sample-a"]?["Cohort"], "treated")
        XCTAssertEqual(viewer.sampleMetadataStore?.records["sample-b"]?["Site"], "")
    }
}
