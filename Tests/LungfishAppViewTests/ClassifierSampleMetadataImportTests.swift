// ClassifierSampleMetadataImportTests.swift - Live classifier metadata import coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishApp
import LungfishCore
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishKit

@MainActor
final class ClassifierSampleMetadataImportTests: XCTestCase {
    func testMainSplitRehydratesBeforeViewLoadAndUnregistersReplacedActualConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassifierMetadataLifecycle-\(UUID().uuidString)", isDirectory: true)
        let replacementRoot = root.appendingPathComponent("replacement", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)

        let originalData = Data("Sample\tCohort\tSite\nsample-a\tcase\tAustin\n".utf8)
        let persistedStore = try SampleMetadataStore(
            csvData: originalData,
            knownSampleIds: ["sample-a"]
        )
        try persistedStore.persist(originalData: originalData, to: root)

        let split = MainSplitViewController()
        let firstViewer = EsVirituResultViewController()
        let entry = EsVirituResultViewController.EsVirituSampleEntry(
            id: "sample-a", displayName: "sample-a", detectedVirusCount: 1
        )
        split.installClassifierMetadataPresentation(
            resultURL: root,
            pickerState: ClassifierSamplePickerState(allSamples: ["sample-a"]),
            entries: [entry],
            strippedPrefix: "",
            workflowName: "EsViritu",
            consumer: firstViewer
        )
        let firstContext = try XCTUnwrap(split.classifierMetadataPresentationContext)
        XCTAssertEqual(firstViewer.sampleMetadataStore?.columnNames, ["Cohort", "Site"])

        _ = firstViewer.view
        XCTAssertTrue(
            Set(["Cohort", "Site"]).isSubset(
                of: metadataMenuTitles(in: firstViewer.testDetectionTableView.testOutlineView)
            )
        )

        let replacementViewer = EsVirituResultViewController()
        split.installClassifierMetadataPresentation(
            resultURL: replacementRoot,
            pickerState: ClassifierSamplePickerState(allSamples: ["sample-a"]),
            entries: [entry],
            strippedPrefix: "",
            workflowName: "EsViritu",
            consumer: replacementViewer
        )
        let replacementStore = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample-a\treplacement\n".utf8),
            knownSampleIds: ["sample-a"]
        )
        firstContext.updateSampleMetadataStore(replacementStore)
        XCTAssertEqual(firstViewer.sampleMetadataStore?.records["sample-a"]?["Cohort"], "case")

        try XCTUnwrap(split.classifierMetadataPresentationContext)
            .updateSampleMetadataStore(replacementStore)
        XCTAssertEqual(replacementViewer.sampleMetadataStore?.records["sample-a"]?["Cohort"], "replacement")
    }

    func testKraken2ContextImmediatelyUpdatesActualBatchTableChooserAndCells() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kraken2Metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try Kraken2Database.create(
            at: root.appendingPathComponent("kraken2.sqlite"),
            rows: [
                Kraken2ClassificationRow(sample: "sample-a", taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root", readsDirect: 0, readsClade: 10, percentage: 100, parentTaxId: nil, depth: 0, fractionDirect: 0),
                Kraken2ClassificationRow(sample: "sample-b", taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root", readsDirect: 0, readsClade: 10, percentage: 100, parentTaxId: nil, depth: 0, fractionDirect: 0),
            ],
            metadata: [:]
        )
        let viewer = TaxonomyViewController()
        _ = viewer.view
        viewer.configureFromDatabase(database)
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample-a\tcase\nsample-b\tcontrol\n".utf8),
            knownSampleIds: ["sample-a", "sample-b"]
        )
        let context = try SampleMetadataPresentationContext(
            finalResultURL: root,
            identityIndex: SampleIdentityIndex(samples: [
                .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
                .init(canonicalID: "sample-b", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
            ]),
            sampleMetadataStore: store,
            importContext: .init(resultID: "kraken", provenanceID: "kraken:test", workflowName: "Kraken2", workflowVersion: "test")
        )
        let token = context.observe(viewer)
        defer { context.removeObserver(token) }

        let table = viewer.testBatchTableView.testTableView
        XCTAssertTrue(Set(["Cohort"]).isSubset(of: metadataMenuTitles(in: table)))
        try showMetadataColumn(named: "Cohort", in: table)
        let sampleARow = try XCTUnwrap(viewer.testBatchTableView.displayedRows.firstIndex { $0.sample == "sample-a" })
        let sampleBRow = try XCTUnwrap(viewer.testBatchTableView.displayedRows.firstIndex { $0.sample == "sample-b" })
        XCTAssertEqual(viewer.testBatchTableView.testCellText(row: sampleARow, columnID: "metadata_Cohort").primary, "case")
        XCTAssertEqual(viewer.testBatchTableView.testCellText(row: sampleBRow, columnID: "metadata_Cohort").primary, "control")
    }

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
                EsVirituDetectionRow(
                    sample: "sample-c", virusName: "Unannotated virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000003.1",
                    assembly: "ASM_3", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 1, uniqueReads: 1,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 1, bamPath: nil, bamIndexPath: nil
                ),
            ],
            metadata: [:]
        )
        let viewer = EsVirituResultViewController()
        _ = viewer.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewer
        window.layoutIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        viewer.configureFromDatabase(database, resultURL: root)

        let context = try SampleMetadataPresentationContext(
            finalResultURL: root,
            identityIndex: SampleIdentityIndex(samples: [
                .init(canonicalID: "sample-a", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
                .init(canonicalID: "sample-b", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
                .init(canonicalID: "sample-c", aliases: [], alignmentTrackIDs: [], readGroupIDs: []),
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

        let detectionTable = viewer.testDetectionTableView
        let batchTable = viewer.testBatchTableView
        XCTAssertTrue(Set(["Cohort", "Site"]).isSubset(of: metadataMenuTitles(in: detectionTable.testOutlineView)))
        XCTAssertTrue(Set(["Cohort", "Site"]).isSubset(of: metadataMenuTitles(in: batchTable.testTableView)))

        try showMetadataColumn(named: "Cohort", in: detectionTable.testOutlineView)
        try showMetadataColumn(named: "Cohort", in: batchTable.testTableView)

        viewer.samplePickerState.selectedSamples = ["sample-a"]
        NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)

        let deadline = Date().addingTimeInterval(5)
        while batchTable.displayedRows.count < 3 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(batchTable.displayedRows.count, 3)

        let selectedDetectionRow = try XCTUnwrap(
            detectionRow(in: detectionTable.testOutlineView, sample: "sample-a")
        )
        XCTAssertEqual(
            detectionTable.testingRealizedCell(column: "metadata_Cohort", row: selectedDetectionRow)?.textField?.stringValue,
            "treated"
        )
        let sampleARow = try XCTUnwrap(batchTable.displayedRows.firstIndex { $0.sample == "sample-a" })
        let sampleBRow = try XCTUnwrap(batchTable.displayedRows.firstIndex { $0.sample == "sample-b" })
        XCTAssertEqual(batchTable.testCellText(row: sampleARow, columnID: "metadata_Cohort").primary, "treated")
        XCTAssertEqual(batchTable.testCellText(row: sampleBRow, columnID: "metadata_Cohort").primary, "control")

        try showMetadataColumn(named: "Site", in: batchTable.testTableView)
        XCTAssertEqual(batchTable.testCellText(row: sampleBRow, columnID: "metadata_Site").primary, "")
        XCTAssertEqual(batchTable.testCellText(row: sampleARow, columnID: "metadata_Site").primary, "Hilo")
        let unannotatedRow = try XCTUnwrap(batchTable.displayedRows.firstIndex { $0.sample == "sample-c" })
        XCTAssertEqual(batchTable.testCellText(row: unannotatedRow, columnID: "metadata_Cohort").primary, "\u{2014}")
    }

    private func metadataMenuTitles(in table: NSTableView) -> [String] {
        table.headerView?.menu?.items
            .filter { $0.representedObject is String && $0.target is MetadataColumnController }
            .compactMap { $0.representedObject as? String } ?? []
    }

    private func showMetadataColumn(named name: String, in table: NSTableView) throws {
        let menu = try XCTUnwrap(table.headerView?.menu)
        let index = try XCTUnwrap(menu.items.firstIndex {
            ($0.representedObject as? String) == name
        })
        menu.performActionForItem(at: index)
    }

    private func detectionRow(in table: NSOutlineView, sample: String) -> Int? {
        let sampleColumn = table.column(withIdentifier: .init("sample"))
        guard sampleColumn >= 0 else { return nil }
        return (0..<table.numberOfRows).first { row in
            let cell = table.view(atColumn: sampleColumn, row: row, makeIfNecessary: true) as? NSTableCellView
            return cell?.textField?.stringValue == sample
        }
    }
}
