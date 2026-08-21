// NaoMgsResultViewControllerSmokeTests.swift - Standalone smoke test for the NAO-MGS leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
import SwiftUI
@testable import LungfishNaoMgsUI
@testable import LungfishIO
import LungfishWorkflow
@testable import LungfishKit
import LungfishCore

final class NaoMgsResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testImportedMetadataImmediatelyUpdatesActualTaxonomyTableChooserAndCells() throws {
        let controller = NaoMgsResultViewController()
        controller.loadViewIfNeeded()
        controller.configureWithCachedRows(
            [
                Self.makeCachedRow(sample: "sample-A", taxId: 1),
                Self.makeCachedRow(sample: "sample-B", taxId: 2),
                Self.makeCachedRow(sample: "sample-C", taxId: 3),
            ],
            manifest: Self.makeManifest()
        )
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample-A\tcase\nsample-B\tcontrol\n".utf8),
            knownSampleIds: ["sample-A", "sample-B", "sample-C"]
        )

        controller.applySampleMetadata(store)
        let table = controller.testTaxonomyTableView
        XCTAssertTrue(Set(["Cohort"]).isSubset(of: Self.metadataMenuTitles(in: table)))
        try Self.showMetadataColumn(named: "Cohort", in: table)

        XCTAssertEqual(try Self.tableField(table, identifier: "metadata_Cohort", row: 0).stringValue, "case")
        XCTAssertEqual(try Self.tableField(table, identifier: "metadata_Cohort", row: 1).stringValue, "control")
        XCTAssertEqual(try Self.tableField(table, identifier: "metadata_Cohort", row: 2).stringValue, "—")
    }
    @MainActor func testViewControllerInstantiates() {
        let vc = NaoMgsResultViewController()
        XCTAssertNotNil(vc.view)
    }

    @MainActor func testResultViewportExportWritesTSVToProvidedURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsResultViewportExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("naomgs-summary.tsv")
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [
                NaoMgsTaxonSummaryRow(
                    sample: "sample-1",
                    taxId: 1234,
                    name: "Example\tvirus",
                    hitCount: 10,
                    uniqueReadCount: 8,
                    avgIdentity: 99.5,
                    avgBitScore: 200,
                    avgEditDistance: 1,
                    pcrDuplicateCount: 2,
                    accessionCount: 1,
                    topAccessions: ["NC_000001.1"],
                    bamPath: nil,
                    bamIndexPath: nil
                ),
            ],
            manifest: NaoMgsManifest(
                sampleName: "sample-1",
                sourceFilePath: "/tmp/naomgs.tsv",
                hitCount: 10,
                taxonCount: 1,
                topTaxon: "Example virus",
                topTaxonId: 1234
            )
        )

        try vc.exportResults(to: outputURL, format: .tsv)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(
            content.hasPrefix(
                "sample\ttaxon_id\tname\thit_count\tunique_read_count\tpcr_duplicate_count\tavg_identity\tavg_bit_score\tavg_edit_distance\taccession_count\n"
            )
        )
        XCTAssertTrue(content.contains("sample-1\t1234\tExample virus\t10\t8\t2\t99.50\t200.0\t1.0\t1\n"))

        let provenance = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(provenance.workflowName, "lungfish app naomgs summary export")
        XCTAssertEqual(provenance.output?.path, outputURL.path)
        XCTAssertNotNil(provenance.output?.checksumSHA256)
        XCTAssertEqual(provenance.options.resolvedDefaults["rowCount"]?.integerValue, 1)
        XCTAssertEqual(
            provenance.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample-1"]
        )
        XCTAssertEqual(provenance.options.resolvedDefaults["columnFilterComposition"]?.stringValue, "all")
        XCTAssertFalse(provenance.options.resolvedDefaults["sortDescriptors"]?.arrayValue?.isEmpty ?? true)
    }

    @MainActor func testConfigureResultPopulatesCachedRowsForViewportExport() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsConfigureResult-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = NaoMgsResult(
            virusHits: [],
            taxonSummaries: [
                NaoMgsTaxonSummary(
                    taxId: 5678,
                    name: "Cached result virus",
                    hitCount: 12,
                    avgIdentity: 98.25,
                    avgBitScore: 175,
                    avgEditDistance: 2,
                    accessions: ["NC_000002.1", "NC_000003.1"],
                    pcrDuplicateCount: 3
                ),
            ],
            totalHitReads: 12,
            sampleName: "parser-sample",
            sourceDirectory: tempDir,
            virusHitsFile: tempDir.appendingPathComponent("virus_hits_final.tsv")
        )

        let outputURL = tempDir.appendingPathComponent("parser-backed-summary.tsv")
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configure(result: result)

        try vc.exportResults(to: outputURL, format: .tsv)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(content.contains("parser-sample\t5678\tCached result virus\t12\t9\t3\t98.25\t175.0\t2.0\t2\n"))

        let provenance = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(provenance.options.resolvedDefaults["rowCount"]?.integerValue, 1)
        XCTAssertEqual(provenance.options.resolvedDefaults["sampleName"]?.stringValue, "parser-sample")
    }

    @MainActor func testTaxonomyTypographyScalesRealizedAndLateMetadataCellsWithoutReloading() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)

        let rows = (0..<80).map { index in
            NaoMgsTaxonSummaryRow(
                sample: index.isMultiple(of: 2) ? "sample-A" : "sample-B",
                taxId: 10_000 + index,
                name: "Complete taxon name \(index)",
                hitCount: 10_000 - index,
                uniqueReadCount: 9_000 - index,
                avgIdentity: 98.5,
                avgBitScore: 200,
                avgEditDistance: 1,
                pcrDuplicateCount: 1,
                accessionCount: 3,
                topAccessions: ["NC_000001.1"],
                bamPath: nil,
                bamIndexPath: nil
            )
        }
        let manifest = NaoMgsManifest(
            sampleName: "batch",
            sourceFilePath: "/tmp/naomgs.tsv",
            hitCount: 100_000,
            taxonCount: rows.count,
            topTaxon: rows.first?.name,
            topTaxonId: rows.first?.taxId
        )
        let controller = NaoMgsResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        controller.configureWithCachedRows(rows, manifest: manifest, awaitingDatabase: false)
        controller.view.layoutSubtreeIfNeeded()

        let table = controller.testTaxonomyTableView
        let scrollView = controller.testTaxonomyScrollView
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertEqual(table.columnAutoresizingStyle, .noColumnAutoresizing)
        table.selectRowIndexes(IndexSet(integer: 24), byExtendingSelection: false)
        XCTAssertTrue(window.makeFirstResponder(table))
        table.scrollRowToVisible(24)
        scrollView.contentView.scroll(to: NSPoint(x: 38, y: table.rect(ofRow: 24).minY + 3))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()

        let sampleColumn = try XCTUnwrap(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "sample"
        })
        let hitsColumn = try XCTUnwrap(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "hits"
        })
        let sampleField = try XCTUnwrap(
            (table.view(atColumn: sampleColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        let hitsField = try XCTUnwrap(
            (table.view(atColumn: hitsColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        table.tableColumns[sampleColumn].width = 173
        let baselineSampleSize = try XCTUnwrap(sampleField.font).pointSize
        let baselineHitsSize = try XCTUnwrap(hitsField.font).pointSize
        let baselineRowHeight = table.rowHeight
        let baselineHeaderHeight = try XCTUnwrap(table.headerView).frame.height
        let baselineSelection = table.selectedRowIndexes
        let baselineTableIdentity = ObjectIdentifier(table)
        let baselineOrigin = scrollView.contentView.bounds.origin
        let baselineReloadCount = controller.testTaxonomyReloadCount
        let baselineTransformCount = controller.testTaxonomyTransformCount
        let baselineSort = table.sortDescriptors.map {
            "\($0.key ?? ""):\($0.ascending)"
        }
        let baselineOrder = controller.testDisplayedTaxonOrder
        let baselineColumnWidths = Dictionary(
            uniqueKeysWithValues: table.tableColumns.map {
                ($0.identifier.rawValue, $0.width)
            }
        )

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        controller.view.layoutSubtreeIfNeeded()

        let enlargedSampleField = try XCTUnwrap(
            (table.view(atColumn: sampleColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        let enlargedHitsField = try XCTUnwrap(
            (table.view(atColumn: hitsColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        XCTAssertEqual(enlargedSampleField.font?.pointSize, baselineSampleSize * 2)
        XCTAssertEqual(enlargedHitsField.font?.pointSize, baselineHitsSize * 2)
        XCTAssertTrue(
            NSFontManager.shared.traits(of: try XCTUnwrap(enlargedHitsField.font))
                .contains(.fixedPitchFontMask)
        )
        XCTAssertGreaterThan(table.rowHeight, baselineRowHeight)
        XCTAssertGreaterThan(try XCTUnwrap(table.headerView).frame.height, baselineHeaderHeight)
        XCTAssertEqual(table.selectedRowIndexes, baselineSelection)
        XCTAssertEqual(ObjectIdentifier(table), baselineTableIdentity)
        XCTAssertEqual(window.firstResponder as? NSTableView, table)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, baselineOrigin.x, accuracy: 0.5)
        XCTAssertEqual(table.rows(in: table.visibleRect).location, 24)
        XCTAssertEqual(controller.testTaxonomyReloadCount, baselineReloadCount)
        XCTAssertEqual(controller.testTaxonomyTransformCount, baselineTransformCount)
        XCTAssertEqual(table.sortDescriptors.map { "\($0.key ?? ""):\($0.ascending)" }, baselineSort)
        XCTAssertEqual(controller.testDisplayedTaxonOrder, baselineOrder)
        for column in table.tableColumns where baselineColumnWidths[column.identifier.rawValue] != nil {
            let baselineWidth = try XCTUnwrap(
                baselineColumnWidths[column.identifier.rawValue]
            )
            XCTAssertEqual(
                column.width,
                baselineWidth,
                accuracy: 0.01
            )
        }
        XCTAssertEqual(enlargedSampleField.toolTip, enlargedSampleField.stringValue)
        XCTAssertEqual(enlargedSampleField.accessibilityValue(), enlargedSampleField.stringValue)
        XCTAssertTrue(table.tableColumns.allSatisfy {
            $0.headerToolTip == $0.headerCell.stringValue
        })

        controller.metadataColumnController.visibleColumns = ["Cohort"]
        controller.sampleMetadataStore = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample-A\tLongitudinal clinical cohort\nsample-B\tControl\n".utf8),
            knownSampleIds: ["sample-A", "sample-B"]
        )
        controller.view.layoutSubtreeIfNeeded()
        let metadataColumn = try XCTUnwrap(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "metadata_Cohort"
        })
        let metadataField = try XCTUnwrap(
            (table.view(atColumn: metadataColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        let expectedMetadataSize = ContentTypography.current().font(for: .body).pointSize
        XCTAssertEqual(metadataField.font?.pointSize, expectedMetadataSize)
        XCTAssertEqual(metadataField.toolTip, metadataField.stringValue)
        XCTAssertEqual(metadataField.accessibilityValue(), metadataField.stringValue)

        let reloadsAfterMetadata = controller.testTaxonomyReloadCount
        let transformsAfterMetadata = controller.testTaxonomyTransformCount
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(enlargedSampleField.font?.pointSize, baselineSampleSize * 2)
        XCTAssertEqual(metadataField.font?.pointSize, expectedMetadataSize)
        XCTAssertEqual(controller.testTaxonomyReloadCount, reloadsAfterMetadata)
        XCTAssertEqual(controller.testTaxonomyTransformCount, transformsAfterMetadata)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let restoredSampleField = try XCTUnwrap(
            (table.view(atColumn: sampleColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        let restoredHitsField = try XCTUnwrap(
            (table.view(atColumn: hitsColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        XCTAssertEqual(restoredSampleField.font?.pointSize, baselineSampleSize)
        XCTAssertEqual(restoredHitsField.font?.pointSize, baselineHitsSize)
        XCTAssertEqual(table.rowHeight, baselineRowHeight)
        XCTAssertEqual(try XCTUnwrap(table.headerView).frame.height, baselineHeaderHeight)
        XCTAssertEqual(table.sortDescriptors.map { "\($0.key ?? ""):\($0.ascending)" }, baselineSort)
        XCTAssertEqual(controller.testDisplayedTaxonOrder, baselineOrder)
        for column in table.tableColumns where baselineColumnWidths[column.identifier.rawValue] != nil {
            let baselineWidth = try XCTUnwrap(
                baselineColumnWidths[column.identifier.rawValue]
            )
            XCTAssertEqual(
                column.width,
                baselineWidth,
                accuracy: 0.01
            )
        }

        settings.contentTextSizePreference = .system
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let systemSampleField = try XCTUnwrap(
            (table.view(atColumn: sampleColumn, row: 24, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        let firstSystemSize = systemSampleField.font?.pointSize
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(systemSampleField.font?.pointSize, firstSystemSize)
        XCTAssertEqual(table.sortDescriptors.map { "\($0.key ?? ""):\($0.ascending)" }, baselineSort)
        XCTAssertEqual(controller.testDisplayedTaxonOrder, baselineOrder)
        for column in table.tableColumns where baselineColumnWidths[column.identifier.rawValue] != nil {
            let baselineWidth = try XCTUnwrap(
                baselineColumnWidths[column.identifier.rawValue]
            )
            XCTAssertEqual(
                column.width,
                baselineWidth,
                accuracy: 0.01
            )
        }
    }

    @MainActor func testTaxonomySystemTypographyUsesInjectedPreferredMetricsAndRecovers() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .system
        let provider = MutableNaoMgsPreferredFonts(bodyPointSize: 13)
        let controller = NaoMgsResultViewController()
        controller.testingSetContentPreferredFontProvider(provider)
        controller.loadViewIfNeeded()
        controller.configureWithCachedRows(
            [
                NaoMgsTaxonSummaryRow(
                    sample: "sample-A",
                    taxId: 12_345,
                    name: "System typography taxon",
                    hitCount: 100,
                    uniqueReadCount: 90,
                    avgIdentity: 99,
                    avgBitScore: 210,
                    avgEditDistance: 1,
                    pcrDuplicateCount: 10,
                    accessionCount: 1,
                    topAccessions: ["NC_000001.1"],
                    bamPath: nil,
                    bamIndexPath: nil
                ),
            ],
            manifest: NaoMgsManifest(
                sampleName: "sample-A",
                sourceFilePath: "/tmp/naomgs.tsv",
                hitCount: 100,
                taxonCount: 1,
                topTaxon: "System typography taxon",
                topTaxonId: 12_345
            ),
            awaitingDatabase: false
        )
        let table = controller.testTaxonomyTableView
        let nameColumn = try XCTUnwrap(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "name"
        })
        let field = try XCTUnwrap(
            (table.view(atColumn: nameColumn, row: 0, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        let baselineSize = try XCTUnwrap(field.font).pointSize
        let baselineRowHeight = table.rowHeight
        let baselineHeaderHeight = try XCTUnwrap(table.headerView).frame.height

        provider.bodyPointSize = 26
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let enlargedField = try XCTUnwrap(
            (table.view(atColumn: nameColumn, row: 0, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        XCTAssertEqual(enlargedField.font?.pointSize, baselineSize * 2)
        XCTAssertGreaterThan(table.rowHeight, baselineRowHeight)
        XCTAssertGreaterThan(try XCTUnwrap(table.headerView).frame.height, baselineHeaderHeight)

        provider.bodyPointSize = 13
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let restoredField = try XCTUnwrap(
            (table.view(atColumn: nameColumn, row: 0, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
        XCTAssertEqual(restoredField.font?.pointSize, baselineSize)
        XCTAssertEqual(table.rowHeight, baselineRowHeight)
        XCTAssertEqual(try XCTUnwrap(table.headerView).frame.height, baselineHeaderHeight)
    }

    @MainActor func testOverviewScalesOnlyOrdinaryTextAndKeepsTaxonGraphGeometryFixed() {
        final class StubPreferredFonts: ContentPreferredFontProviding {
            func preferredFont(for role: ContentTypography.Role) -> NSFont {
                switch role {
                case .caption:
                    return .systemFont(ofSize: 11)
                default:
                    return .systemFont(ofSize: 13)
                }
            }

            func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
                role == .caption ? 11 : 13
            }
        }

        let notifications = NotificationCenter()
        final class PreferenceBox: @unchecked Sendable {
            var value = ContentTextSizePreference.custom(100)
        }
        let preference = PreferenceBox()
        let model = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: StubPreferredFonts()
        )
        let baseline = NaoMgsOverviewTypography.testingMetrics(model: model)
        XCTAssertEqual(baseline.metricLabelPointSize, 10)
        XCTAssertEqual(baseline.metricValuePointSize, 13)
        XCTAssertEqual(baseline.titlePointSize, 14)
        XCTAssertEqual(baseline.explanationPointSize, 11)
        XCTAssertEqual(baseline.sectionPointSize, 11)
        XCTAssertEqual(baseline.taxonLabelPointSize, 10)
        XCTAssertEqual(baseline.taxonCountPointSize, 10)
        XCTAssertEqual(baseline.taxonBarHeight, 8)

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)
        let enlarged = NaoMgsOverviewTypography.testingMetrics(model: model)
        XCTAssertEqual(enlarged.metricLabelPointSize, 18)
        XCTAssertEqual(enlarged.metricValuePointSize, 26)
        XCTAssertEqual(enlarged.titlePointSize, 28)
        XCTAssertEqual(enlarged.explanationPointSize, 22)
        XCTAssertEqual(enlarged.sectionPointSize, 22)
        XCTAssertEqual(enlarged.taxonLabelPointSize, baseline.taxonLabelPointSize)
        XCTAssertEqual(enlarged.taxonCountPointSize, baseline.taxonCountPointSize)
        XCTAssertEqual(enlarged.taxonBarHeight, baseline.taxonBarHeight)

        let taxon = NaoMgsTaxonSummary(
            taxId: 12_345,
            name: "Complete virus taxon name",
            hitCount: 4_321,
            avgIdentity: 99,
            avgBitScore: 210,
            avgEditDistance: 1,
            accessions: ["NC_000001.1"],
            pcrDuplicateCount: 21
        )
        let accessibility = NaoMgsTaxonBarPresentation(summary: taxon)
        XCTAssertEqual(accessibility.accessibilityLabel, "Complete virus taxon name")
        XCTAssertEqual(accessibility.accessibilityValue, "4,321 reads")
    }

    @MainActor func testOverviewQuickStatsRemainContainedAtNarrowTwoHundredPercent() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(200)
        let view = NaoMgsOverviewView(
            taxonSummaries: [
                NaoMgsTaxonSummary(
                    taxId: 12_345,
                    name: "Complete virus taxon name",
                    hitCount: 4_321,
                    avgIdentity: 99,
                    avgBitScore: 210,
                    avgEditDistance: 1,
                    accessions: ["NC_000001.1"],
                    pcrDuplicateCount: 21
                ),
            ],
            totalHitReads: 4_321,
            sampleNames: [
                "Extremely long longitudinal clinical sample identifier that must wrap",
            ]
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
        hostingView.layoutSubtreeIfNeeded()

        let contentWidth: CGFloat = 240 - 24
        let layout = NaoMgsOverviewTypography.testingQuickStatsLayout(
            availableWidth: contentWidth
        )
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.itemWidth, contentWidth)
        let sampleFont = NSFont.monospacedSystemFont(ofSize: 26, weight: .semibold)
        let sampleBounds = (
            "Extremely long longitudinal clinical sample identifier that must wrap"
                as NSString
        ).boundingRect(
            with: NSSize(width: layout.itemWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: sampleFont]
        )
        XCTAssertLessThanOrEqual(sampleBounds.width, layout.itemWidth)
        XCTAssertGreaterThan(sampleBounds.height, sampleFont.boundingRectForFont.height)
        XCTAssertEqual(hostingView.frame.width, 240)
    }

    @MainActor func testHostedOverviewRefitsAfterLiveModelUpdatesAndPreservesScrollOrigin() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let provider = MutableNaoMgsPreferredFonts(bodyPointSize: 13)
        let rows = (0..<30).map { index in
            NaoMgsTaxonSummaryRow(
                sample: "Extremely long longitudinal clinical sample identifier",
                taxId: 20_000 + index,
                name: "Complete taxon name \(index)",
                hitCount: 10_000 - index,
                uniqueReadCount: 9_000 - index,
                avgIdentity: 99,
                avgBitScore: 210,
                avgEditDistance: 1,
                pcrDuplicateCount: 1,
                accessionCount: 1,
                topAccessions: ["NC_000001.1"],
                bamPath: nil,
                bamIndexPath: nil
            )
        }
        let controller = NaoMgsResultViewController()
        controller.testingSetContentPreferredFontProvider(provider)
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        controller.configureWithCachedRows(
            rows,
            manifest: NaoMgsManifest(
                sampleName: rows[0].sample,
                sourceFilePath: "/tmp/naomgs.tsv",
                hitCount: 100_000,
                taxonCount: rows.count,
                topTaxon: rows[0].name,
                topTaxonId: rows[0].taxId
            ),
            awaitingDatabase: false
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.view.layoutSubtreeIfNeeded()
        let hostingView = try XCTUnwrap(controller.testOverviewHostingView)
        let scrollView = controller.testDetailScrollView
        let baselineHostingIdentity = ObjectIdentifier(hostingView)
        let baselineHeight = controller.testDetailContentView.frame.height
        XCTAssertTrue(controller.testOverviewIsContained)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 24))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let baselineOrigin = scrollView.contentView.bounds.origin
        XCTAssertEqual(baselineOrigin.y, 24, accuracy: 0.5)

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        controller.view.layoutSubtreeIfNeeded()
        drainDeferredUIWork()
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.testOverviewHostingView)), baselineHostingIdentity)
        XCTAssertTrue(controller.testOverviewIsContained)
        XCTAssertGreaterThan(controller.testDetailContentView.frame.height, baselineHeight)
        XCTAssertEqual(scrollView.contentView.bounds.origin, baselineOrigin)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        controller.view.layoutSubtreeIfNeeded()
        drainDeferredUIWork()
        XCTAssertTrue(controller.testOverviewIsContained)
        XCTAssertEqual(controller.testDetailContentView.frame.height, baselineHeight, accuracy: 1)
        XCTAssertEqual(scrollView.contentView.bounds.origin, baselineOrigin)

        settings.contentTextSizePreference = .system
        provider.bodyPointSize = 26
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        controller.view.layoutSubtreeIfNeeded()
        drainDeferredUIWork()
        XCTAssertTrue(controller.testOverviewIsContained)
        XCTAssertGreaterThan(controller.testDetailContentView.frame.height, baselineHeight)
        XCTAssertEqual(scrollView.contentView.bounds.origin, baselineOrigin)

        provider.bodyPointSize = 13
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        controller.view.layoutSubtreeIfNeeded()
        drainDeferredUIWork()
        XCTAssertTrue(controller.testOverviewIsContained)
        XCTAssertEqual(controller.testDetailContentView.frame.height, baselineHeight, accuracy: 1)
        XCTAssertEqual(scrollView.contentView.bounds.origin, baselineOrigin)
    }

    func testTaxonRowsUseNativeButtonActivationSemantics() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishNaoMgsUI/NaoMgsChartViews.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Button {"))
        XCTAssertTrue(source.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(source.contains(".onTapGesture"))
        XCTAssertTrue(source.contains(".accessibilityLabel(presentation.accessibilityLabel)"))
        XCTAssertTrue(source.contains(".accessibilityValue(presentation.accessibilityValue)"))
    }

    @MainActor func testDatabaseDetailTypographyReflowsWithoutRebuildingOrMutatingMiniBAMState() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .system
        let provider = MutableNaoMgsPreferredFonts(bodyPointSize: 13)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsTypography-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let database = try NaoMgsDatabase.create(
            at: tempDirectory.appendingPathComponent("hits.sqlite"),
            hits: Self.makeNaoMgsHits()
        )
        let manifest = NaoMgsManifest(
            sampleName: "sample-A",
            sourceFilePath: "/tmp/naomgs.tsv",
            hitCount: 2,
            taxonCount: 1,
            topTaxon: "Very long complete virus taxon name for reflow verification",
            topTaxonId: 12_345
        )
        let controller = NaoMgsResultViewController()
        controller.testingSetContentPreferredFontProvider(provider)
        controller.testDisableMiniBAMLoading = true
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 440)
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        controller.configure(database: database, manifest: manifest, bundleURL: tempDirectory)
        controller.testTaxonomyTableView.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let detailContent = controller.testDetailContentView
        let detailScroll = controller.testDetailScrollView
        let title = try XCTUnwrap(
            Self.descendantTextField(
                in: detailContent,
                containing: "Very long complete virus taxon name"
            )
        )
        let subtitle = try XCTUnwrap(
            Self.descendantTextField(in: detailContent, containing: "Taxid: 12345")
        )
        let listHeading = try XCTUnwrap(
            Self.descendantTextField(in: detailContent, containing: "miniBAM Panels")
        )
        let note = try XCTUnwrap(
            Self.descendantTextField(in: detailContent, containing: "Top references")
        )
        let stats = try XCTUnwrap(
            Self.descendantTextField(in: detailContent, containing: "bp covered")
        )
        let accessionButton = try XCTUnwrap(
            Self.descendantButton(in: detailContent, title: "NC_000001.1")
        )
        let secondAccessionButton = try XCTUnwrap(
            Self.descendantButton(in: detailContent, title: "NC_000002.1")
        )
        let pillLabel = try XCTUnwrap(
            Self.descendantTextField(in: detailContent, exactly: "Avg Identity")
        )
        let pillValue = try XCTUnwrap(
            Self.descendantTextField(in: detailContent, exactly: "99.0%")
        )
        let baselineSizes: [CGFloat?] = [
            title.font?.pointSize,
            subtitle.font?.pointSize,
            listHeading.font?.pointSize,
            note.font?.pointSize,
            stats.font?.pointSize,
            accessionButton.font?.pointSize,
            pillLabel.font?.pointSize,
            pillValue.font?.pointSize,
            controller.testLoadingLabel.font?.pointSize,
        ]
        XCTAssertEqual(controller.testDetailMetricsOrientation, .horizontal)
        XCTAssertEqual(controller.testAccessionHeaderCount, 2)
        XCTAssertEqual(controller.testAccessionHeaderOrientations, [.horizontal, .horizontal])
        XCTAssertEqual(controller.testAccessionButtonCount, 2)
        let contentIdentity = ObjectIdentifier(detailContent)
        let miniBAMIdentities = controller.testMiniBAMControllerIdentities
        let miniBAMHeights = controller.testMiniBAMViewSizes.map(\.height)
        let accessionCacheCount = controller.testCurrentAccessionSummaryCount
        let rebuildCount = controller.testDetailRebuildCount
        let loadStartCount = controller.testMiniBAMLoadStartCount
        detailScroll.contentView.scroll(to: NSPoint(x: 0, y: 30))
        detailScroll.reflectScrolledClipView(detailScroll.contentView)
        let baselineScrollOrigin = detailScroll.contentView.bounds.origin
        XCTAssertEqual(baselineScrollOrigin.y, 30, accuracy: 0.5)

        provider.bodyPointSize = 26
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        controller.view.layoutSubtreeIfNeeded()
        drainDeferredUIWork()

        let enlargedSizes: [CGFloat?] = [
            title.font?.pointSize,
            subtitle.font?.pointSize,
            listHeading.font?.pointSize,
            note.font?.pointSize,
            stats.font?.pointSize,
            accessionButton.font?.pointSize,
            pillLabel.font?.pointSize,
            pillValue.font?.pointSize,
            controller.testLoadingLabel.font?.pointSize,
        ]
        XCTAssertTrue(zip(baselineSizes, enlargedSizes).allSatisfy {
            guard let baseline = $0.0, let enlarged = $0.1 else { return false }
            return enlarged > baseline
        })
        XCTAssertEqual(controller.testDetailMetricsOrientation, .vertical)
        XCTAssertEqual(controller.testAccessionHeaderOrientations, [.vertical, .vertical])
        XCTAssertEqual(
            controller.testAccessionButtonPointSizes,
            [baselineSizes[5]! * 2, baselineSizes[5]! * 2]
        )
        XCTAssertTrue(controller.testDetailTypographyFieldsAreContained)
        let inaccessibleText = controller.testDetailFullTextAccessibility.filter {
            !$0.text.isEmpty && ($0.toolTip != $0.text || $0.accessibilityValue != $0.text)
        }
        XCTAssertTrue(inaccessibleText.isEmpty, inaccessibleText.map(\.text).joined(separator: " | "))
        XCTAssertEqual(accessionButton.toolTip, accessionButton.title)
        XCTAssertEqual(accessionButton.accessibilityValue() as? String, accessionButton.title)
        XCTAssertEqual(secondAccessionButton.toolTip, secondAccessionButton.title)
        XCTAssertEqual(
            secondAccessionButton.accessibilityValue() as? String,
            secondAccessionButton.title
        )
        XCTAssertEqual(
            detailScroll.contentView.bounds.origin,
            baselineScrollOrigin,
            "content=\(detailContent.frame) clip=\(detailScroll.contentView.bounds)"
        )
        XCTAssertEqual(ObjectIdentifier(detailContent), contentIdentity)
        XCTAssertEqual(controller.testMiniBAMControllerIdentities, miniBAMIdentities)
        XCTAssertEqual(controller.testMiniBAMViewSizes.map(\.height), miniBAMHeights)
        XCTAssertEqual(controller.testCurrentAccessionSummaryCount, accessionCacheCount)
        XCTAssertEqual(controller.testDetailRebuildCount, rebuildCount)
        XCTAssertEqual(controller.testMiniBAMLoadStartCount, loadStartCount)

        controller.testingShowMultiSelectionPlaceholder(count: 123_456)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.testPlaceholderFieldsAreContained)
        XCTAssertTrue(controller.testPlaceholderPointSizes.allSatisfy { $0 > 11 })

        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(controller.testDetailRebuildCount, rebuildCount)
        XCTAssertEqual(controller.testMiniBAMLoadStartCount, loadStartCount)
        provider.bodyPointSize = 13
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(title.font?.pointSize, baselineSizes[0])
        XCTAssertEqual(accessionButton.font?.pointSize, baselineSizes[5])
        XCTAssertEqual(secondAccessionButton.font?.pointSize, baselineSizes[5])
        XCTAssertEqual(controller.testDetailMetricsOrientation, .horizontal)
        XCTAssertEqual(controller.testAccessionHeaderOrientations, [.horizontal, .horizontal])
    }

    /// F41 regression: the on-demand miniBAM materialization fallback must not let a
    /// slow, superseded selection's result clobber a newer selection's card.
    ///
    /// Selecting taxon A starts a fallback materialization (no BAM exists yet for the
    /// sample). Before it completes, the test selects taxon B, which cancels/supersedes
    /// the loading task and rebuilds `miniBAMControllers`. Taxon A's fallback is injected
    /// with a long delay via `testMaterializationHook`; taxon B's completes immediately.
    /// Without the generation guard, A's stale write would land after B's and show the
    /// wrong contig. With the guard, only B's (current-generation) write is applied.
    @MainActor func testMiniBAMFallbackMaterializationDiscardsStaleGenerationWrite() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsFallbackRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let hits: [NaoMgsVirusHit] = [
            Self.makeNaoMgsHit(
                sample: "sample-A",
                seqId: "read-old",
                taxId: 111,
                subjectSeqId: "NC_OLD00001.1",
                subjectTitle: "Stale selection virus"
            ),
            Self.makeNaoMgsHit(
                sample: "sample-A",
                seqId: "read-new",
                taxId: 222,
                subjectSeqId: "NC_NEW00002.1",
                subjectTitle: "Fresh selection virus"
            ),
        ]
        let database = try NaoMgsDatabase.create(
            at: tempDirectory.appendingPathComponent("hits.sqlite"),
            hits: hits
        )
        let manifest = NaoMgsManifest(
            sampleName: "sample-A",
            sourceFilePath: "/tmp/naomgs.tsv",
            hitCount: 2,
            taxonCount: 2,
            topTaxon: "Stale selection virus",
            topTaxonId: 111
        )

        let controller = NaoMgsResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        // Generation 1 (stale/old selection) sleeps well past generation 2's completion
        // before returning; generation 2 (fresh/new selection) returns immediately.
        // The test synchronizes on `generation1HookEntered` to guarantee generation 1's
        // detached fallback task has actually started (i.e. run past the outer Task's
        // cancellation check) before the test triggers the superseding selection —
        // otherwise plain Task scheduling could let generation 2 cancel generation 1
        // before it ever reaches the fallback path, masking the race this test targets.
        let staleDelayNanoseconds: UInt64 = 300_000_000
        let generation1HookEntered = expectation(description: "Generation 1 fallback hook entered")
        controller.testMaterializationHook = { generation in
            if generation == 1 {
                generation1HookEntered.fulfill()
                try? await Task.sleep(nanoseconds: staleDelayNanoseconds)
            }
            // Touch the shared BAM path so the post-hook fileExists() check passes
            // regardless of which generation wins the race.
            let resultURL = database.databaseURL.deletingLastPathComponent()
            let bamsDir = resultURL.appendingPathComponent("bams")
            try? FileManager.default.createDirectory(at: bamsDir, withIntermediateDirectories: true)
            let bamURL = bamsDir.appendingPathComponent("sample-A.bam")
            if !FileManager.default.fileExists(atPath: bamURL.path) {
                FileManager.default.createFile(atPath: bamURL.path, contents: Data())
            }
        }

        controller.configure(database: database, manifest: manifest, bundleURL: tempDirectory)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Select taxon A (taxId 111) first — starts the slow (generation 1) fallback.
        let table = controller.testTaxonomyTableView
        let rowForTaxonA = try XCTUnwrap(
            (0..<table.numberOfRows).first {
                controller.testDisplayedTaxonOrder[$0] == "sample-A:111"
            }
        )
        table.selectRowIndexes(IndexSet(integer: rowForTaxonA), byExtendingSelection: false)
        XCTAssertEqual(controller.testMiniBAMLoadGeneration, 1)
        wait(for: [generation1HookEntered], timeout: 10)

        // Now that generation 1's fallback has actually started (and is sleeping),
        // select taxon B (taxId 222) — this supersedes generation 1 and starts
        // generation 2, which resolves immediately.
        let rowForTaxonB = try XCTUnwrap(
            (0..<table.numberOfRows).first {
                controller.testDisplayedTaxonOrder[$0] == "sample-A:222"
            }
        )
        table.selectRowIndexes(IndexSet(integer: rowForTaxonB), byExtendingSelection: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.testMiniBAMLoadGeneration, 2)

        // Wait past generation 1's injected delay so its (guarded) completion has had
        // every opportunity to run and clobber generation 2's card if the guard is missing.
        let raceResolved = expectation(description: "Stale generation 1 fallback settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            raceResolved.fulfill()
        }
        wait(for: [raceResolved], timeout: 3)

        // Only generation 2's (current, fresh-selection) write should have been applied.
        // Generation 1's late write must have been discarded by the guard.
        XCTAssertEqual(
            controller.testAppliedFallbackWrites.map(\.generation),
            [2],
            "Stale generation 1's fallback write should be discarded, not applied after generation 2"
        )
        XCTAssertEqual(
            controller.testAppliedFallbackWrites.map(\.contig),
            ["NC_NEW00002.1"]
        )
    }

    private static func makeNaoMgsHit(
        sample: String,
        seqId: String,
        taxId: Int,
        subjectSeqId: String,
        subjectTitle: String
    ) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample,
            seqId: seqId,
            taxId: taxId,
            bestAlignmentScore: 120,
            cigar: "100M",
            queryStart: 0,
            queryEnd: 100,
            refStart: 0,
            refEnd: 100,
            readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100),
            subjectSeqId: subjectSeqId,
            subjectTitle: subjectTitle,
            bitScore: 210,
            eValue: 1e-40,
            percentIdentity: 99,
            editDistance: 1,
            fragmentLength: 100,
            isReverseComplement: false,
            pairStatus: "CP",
            queryLength: 100
        )
    }

    @MainActor func testNaoMgsTypographyObserversDoNotRetainController() {
        weak var weakController: NaoMgsResultViewController?
        autoreleasepool {
            let controller = NaoMgsResultViewController()
            _ = controller.view
            weakController = controller
        }
        XCTAssertNil(weakController)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertNil(weakController)
    }

    private static func makeNaoMgsHits() -> [NaoMgsVirusHit] {
        [
            NaoMgsVirusHit(
            sample: "sample-A",
            seqId: "read-1",
            taxId: 12_345,
            bestAlignmentScore: 120,
            cigar: "100M",
            queryStart: 0,
            queryEnd: 100,
            refStart: 0,
            refEnd: 100,
            readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100),
            subjectSeqId: "NC_000001.1",
            subjectTitle: "Very long complete virus taxon name for reflow verification",
            bitScore: 210,
            eValue: 1e-40,
            percentIdentity: 99,
            editDistance: 1,
            fragmentLength: 100,
            isReverseComplement: false,
            pairStatus: "CP",
            queryLength: 100
            ),
            NaoMgsVirusHit(
                sample: "sample-A",
                seqId: "read-2",
                taxId: 12_345,
                bestAlignmentScore: 119,
                cigar: "100M",
                queryStart: 0,
                queryEnd: 100,
                refStart: 100,
                refEnd: 200,
                readSequence: String(repeating: "C", count: 100),
                readQuality: String(repeating: "I", count: 100),
                subjectSeqId: "NC_000002.1",
                subjectTitle: "Very long complete virus taxon name for reflow verification",
                bitScore: 209,
                eValue: 1e-39,
                percentIdentity: 99,
                editDistance: 1,
                fragmentLength: 100,
                isReverseComplement: false,
                pairStatus: "CP",
                queryLength: 100
            ),
        ]
    }

    @MainActor private static func descendantTextField(
        in root: NSView,
        containing text: String
    ) -> NSTextField? {
        descendants(of: NSTextField.self, in: root).first {
            $0.stringValue.contains(text)
        }
    }

    @MainActor private static func descendantTextField(
        in root: NSView,
        exactly text: String
    ) -> NSTextField? {
        descendants(of: NSTextField.self, in: root).first {
            $0.stringValue == text
        }
    }

    @MainActor private static func descendantButton(in root: NSView, title: String) -> NSButton? {
        descendants(of: NSButton.self, in: root).first { $0.title == title }
    }

    @MainActor private static func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        if let typed = root as? T {
            result.append(typed)
        }
        for subview in root.subviews {
            result.append(contentsOf: descendants(of: type, in: subview))
        }
        return result
    }

    @MainActor private func drainDeferredUIWork(iterations: Int = 3) {
        for _ in 0..<iterations {
            let deferredWorkCompleted = expectation(description: "Deferred UI work completed")
            DispatchQueue.main.async {
                deferredWorkCompleted.fulfill()
            }
            wait(for: [deferredWorkCompleted], timeout: 10)
        }
    }

    // MARK: - AS9/AS10: Extract Reads enablement in cached-rows-only state (no database)

    @MainActor func testExtractButtonDisabledWhenOnlyCachedRowsAreLoaded() {
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [Self.makeCachedRow()],
            manifest: Self.makeManifest(),
            awaitingDatabase: false
        )

        vc.testSelectTaxonomyRow(0)

        XCTAssertFalse(vc.testActionBar.extractButton.isEnabled)
        XCTAssertEqual(vc.testContextMenuExtractReadsEnabled(), false)
    }

    @MainActor func testExtractButtonDisabledForMultiSelectionWithoutDatabase() {
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [Self.makeCachedRow(taxId: 1), Self.makeCachedRow(taxId: 2)],
            manifest: Self.makeManifest(),
            awaitingDatabase: false
        )

        vc.testingShowMultiSelectionPlaceholder(count: 2)

        XCTAssertFalse(vc.testActionBar.extractButton.isEnabled)
    }

    // MARK: - AS10: Export enablement/behavior when only cached rows are loaded

    @MainActor func testExportSucceedsWithCachedRowsAndNoDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsExportCachedRows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        vc.configureWithCachedRows(
            [Self.makeCachedRow()],
            manifest: Self.makeManifest(),
            awaitingDatabase: false
        )

        // exportResults() used to bail out entirely when database == nil, even
        // though displayedRows (and therefore writeSummaryTSV) had data to export.
        XCTAssertNoThrow(try vc.writeSummaryTSV(to: tempDir.appendingPathComponent("cached-summary.tsv")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("cached-summary.tsv").path))
    }

    // MARK: - AS26: Accession NCBI URL must not force-unwrap

    @MainActor func testViewAccessionOnNCBIDoesNotCrashForMalformedAccession() {
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "View on NCBI", action: nil, keyEquivalent: "")
        item.representedObject = "bad accession with spaces"

        // Previously this force-unwrapped URL(string:), which crashes for
        // accessions containing characters invalid in a URL.
        vc.contextViewAccessionOnNCBI(item)

        // Foundation percent-encodes the spaces, so assert containment rather
        // than exact equality.
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened[0].absoluteString.contains("ncbi.nlm.nih.gov/nuccore"))
    }

    @MainActor func testViewAccessionOnNCBIOpensExactURLForWellFormedAccession() {
        let vc = NaoMgsResultViewController()
        vc.loadViewIfNeeded()
        var opened: [URL] = []
        vc.onOpenURLRequested = { opened.append($0) }

        let item = NSMenuItem(title: "View on NCBI", action: nil, keyEquivalent: "")
        item.representedObject = "NC_045512.2"

        vc.contextViewAccessionOnNCBI(item)

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].absoluteString, "https://www.ncbi.nlm.nih.gov/nuccore/NC_045512.2")
    }

    private static func makeCachedRow(sample: String = "sample-1", taxId: Int = 1234) -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: sample,
            taxId: taxId,
            name: "Example virus",
            hitCount: 10,
            uniqueReadCount: 8,
            avgIdentity: 99.5,
            avgBitScore: 200,
            avgEditDistance: 1,
            pcrDuplicateCount: 2,
            accessionCount: 1,
            topAccessions: ["NC_000001.1"],
            bamPath: nil,
            bamIndexPath: nil
        )
    }

    private static func makeManifest() -> NaoMgsManifest {
        NaoMgsManifest(
            sampleName: "sample-1",
            sourceFilePath: "/tmp/naomgs.tsv",
            hitCount: 10,
            taxonCount: 1,
            topTaxon: "Example virus",
            topTaxonId: 1234
        )
    }

    @MainActor private static func metadataMenuTitles(in table: NSTableView) -> [String] {
        table.headerView?.menu?.items.compactMap { $0.representedObject as? String } ?? []
    }

    @MainActor private static func showMetadataColumn(named name: String, in table: NSTableView) throws {
        let menu = try XCTUnwrap(table.headerView?.menu)
        let index = try XCTUnwrap(menu.items.firstIndex {
            ($0.representedObject as? String) == name
        })
        menu.performActionForItem(at: index)
    }

    @MainActor private static func tableField(
        _ table: NSTableView,
        identifier: String,
        row: Int
    ) throws -> NSTextField {
        let column = table.column(withIdentifier: .init(identifier))
        guard column >= 0 else {
            XCTFail("Missing table column \(identifier)")
            throw NSError(domain: "NaoMgsMetadataTests", code: 1)
        }
        return try XCTUnwrap(
            (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
        )
    }
}

@MainActor
private final class MutableNaoMgsPreferredFonts:
    ContentPreferredFontProviding,
    @unchecked Sendable
{
    var bodyPointSize: CGFloat

    init(bodyPointSize: CGFloat) {
        self.bodyPointSize = bodyPointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        let size: CGFloat
        switch role {
        case .caption:
            size = bodyPointSize * 11 / 13
        case .tableHeader:
            size = bodyPointSize * 12 / 13
        default:
            size = bodyPointSize
        }
        switch role {
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: size, weight: .bold)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            return .systemFont(ofSize: size)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        switch role {
        case .caption:
            return 11
        case .tableHeader:
            return 12
        default:
            return 13
        }
    }
}
