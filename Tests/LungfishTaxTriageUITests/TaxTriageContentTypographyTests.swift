import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishTaxTriageUI

@MainActor
final class TaxTriageContentTypographyTests: XCTestCase {
    func testBatchLeafExplicitFontsUseSharedContentTypography() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            let table = BatchTaxTriageTableView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 240)
            )
            table.configure(rows: (0..<40).map { metric(sample: "sample-\($0)") })
            let window = host(table, size: table.frame.size)
            defer { close(window) }
            table.tableView.selectRowIndexes(
                IndexSet(integer: 4),
                byExtendingSelection: false
            )
            table.tableView.sortDescriptors = [
                NSSortDescriptor(key: "tt_sample", ascending: true),
            ]
            table.tableView.tableColumns[0].width = 177
            window.makeFirstResponder(table.testSearchField)
            table.testSearchField.stringValue = "Aeromonas"
            let baselineSelected = table.tableView.selectedRowIndexes
            let baselineSort = table.tableView.sortDescriptors
            let baselineWidths = table.tableView.tableColumns.map(\.width)
            let baselineOrder = table.tableView.tableColumns.map(\.identifier)
            let baselineEditor = try XCTUnwrap(table.testSearchField.currentEditor())
            let sampleColumn = try XCTUnwrap(
                table.tableView.tableColumns.first { $0.identifier.rawValue == "tt_sample" }
            )
            let confidenceColumn = try XCTUnwrap(
                table.tableView.tableColumns.first { $0.identifier.rawValue == "tt_confidence" }
            )
            let sample = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: sampleColumn, row: 0)
                    as? NSTableCellView
            )
            let confidence = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: confidenceColumn, row: 0)
                    as? NSTableCellView
            )
            let baselineSample = try XCTUnwrap(sample.textField?.font).pointSize
            let baselineConfidence = try XCTUnwrap(confidence.textField?.font).pointSize

            settings.contentTextSizePreference = .custom(200)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)

            let enlargedSample = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: sampleColumn, row: 0)
                    as? NSTableCellView
            )
            let enlargedConfidence = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: confidenceColumn, row: 0)
                    as? NSTableCellView
            )
            XCTAssertEqual(enlargedSample.textField?.font?.pointSize, baselineSample * 2)
            XCTAssertEqual(
                enlargedConfidence.textField?.font?.pointSize,
                baselineConfidence * 2
            )
            XCTAssertGreaterThan(table.tableView.rowHeight, 22)
            XCTAssertEqual(table.tableView.selectedRowIndexes, baselineSelected)
            XCTAssertEqual(table.tableView.sortDescriptors, baselineSort)
            XCTAssertEqual(table.tableView.tableColumns.map(\.width), baselineWidths)
            XCTAssertEqual(table.tableView.tableColumns.map(\.identifier), baselineOrder)
            XCTAssertTrue(window.firstResponder === baselineEditor)
            XCTAssertEqual(table.testSearchField.stringValue, "Aeromonas")

            settings.contentTextSizePreference = .custom(100)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            let restored = try XCTUnwrap(
                table.tableView(table.tableView, viewFor: sampleColumn, row: 0)
                    as? NSTableCellView
            )
            XCTAssertEqual(restored.textField?.font?.pointSize, baselineSample)
        }
    }

    func testOrganismTableScalesRealizedAndLateMetadataWithoutChangingScientificCell() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            let provider = MutableTaxTriagePreferredFonts(bodyPointSize: 13)
            let view = TaxTriageOrganismTableView(
                frame: NSRect(x: 0, y: 0, width: 540, height: 180)
            )
            view.testingSetContentPreferredFontProvider(provider)
            view.rows = (0..<40).map {
                TaxTriageTableRow(
                    organism: "Long organism \($0)",
                    tassScore: 0.91,
                    reads: 1_000 + $0,
                    uniqueReads: 500,
                    coverage: 88.5,
                    confidence: "High",
                    taxId: 10_000 + $0
                )
            }
            let window = host(view, size: view.frame.size)
            defer { close(window) }
            view.testingTableView.selectRowIndexes(
                IndexSet(integer: 4),
                byExtendingSelection: false
            )
            view.testingTableView.sortDescriptors = [
                NSSortDescriptor(key: "organism", ascending: true),
            ]
            view.testingTableView.tableColumns[0].width = 213
            view.testingScroll(to: NSPoint(x: 17, y: 42))
            window.makeFirstResponder(view.testingTableView)
            let baselineState = view.testingPresentationState

            let organism = try XCTUnwrap(view.testingCell(column: "organism", row: 4))
            let baselineFont = try XCTUnwrap(organism.font).pointSize
            let confidence = try XCTUnwrap(
                view.testingCellView(column: "confidence", row: 4)
                    as? TaxTriageConfidenceCellView
            )
            let confidenceIdentity = ObjectIdentifier(confidence)
            let confidenceScore = confidence.score
            let baselineConfidenceTrack = confidence.testingTrackRect
            let confidenceColor = confidence.testingFillColor
            XCTAssertEqual(baselineConfidenceTrack.height, 16)
            XCTAssertEqual(baselineConfidenceTrack.midY, confidence.bounds.midY)
            XCTAssertEqual(
                confidenceColor,
                TaxTriageConfidencePalette.color(for: confidenceScore)
            )
            XCTAssertEqual(confidence.accessibilityValue() as? NSNumber, 0.91)
            XCTAssertEqual(
                confidence.accessibilityHelp(),
                "High confidence, TASS score 0.910"
            )
            let baselineReloadCount = view.testingTableReloadCount

            settings.contentTextSizePreference = .custom(200)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            view.layoutSubtreeIfNeeded()
            let enlarged = try XCTUnwrap(view.testingCell(column: "organism", row: 4))
            XCTAssertEqual(enlarged.font?.pointSize, baselineFont * 2)
            XCTAssertGreaterThan(view.testingTableView.rowHeight, 24)
            XCTAssertEqual(view.testingPresentationState, baselineState)
            let confidenceAfter = try XCTUnwrap(
                view.testingCellView(column: "confidence", row: 4)
                    as? TaxTriageConfidenceCellView
            )
            XCTAssertEqual(ObjectIdentifier(confidenceAfter), confidenceIdentity)
            XCTAssertEqual(confidenceAfter.score, confidenceScore)
            XCTAssertEqual(confidenceAfter.testingTrackRect.height, 16)
            XCTAssertEqual(confidenceAfter.testingTrackRect.midY, confidenceAfter.bounds.midY)
            XCTAssertEqual(confidenceAfter.testingFillColor, confidenceColor)
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)

            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(
                view.testingCell(column: "organism", row: 4)?.font?.pointSize,
                baselineFont * 2
            )
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)
            let confidenceRepeated = try XCTUnwrap(
                view.testingCellView(column: "confidence", row: 4)
                    as? TaxTriageConfidenceCellView
            )
            XCTAssertEqual(ObjectIdentifier(confidenceRepeated), confidenceIdentity)
            XCTAssertEqual(confidenceRepeated.score, confidenceScore)
            XCTAssertEqual(confidenceRepeated.testingTrackRect.height, 16)
            XCTAssertEqual(confidenceRepeated.testingFillColor, confidenceColor)
            XCTAssertLessThan(
                view.testingTypographyRealizedCellResolutionCount,
                view.rows.count * view.testingTableView.tableColumns.count
            )

            settings.contentTextSizePreference = .custom(100)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(
                view.testingCell(column: "organism", row: 4)?.font?.pointSize,
                baselineFont
            )
            let confidenceRestored = try XCTUnwrap(
                view.testingCellView(column: "confidence", row: 4)
                    as? TaxTriageConfidenceCellView
            )
            XCTAssertEqual(ObjectIdentifier(confidenceRestored), confidenceIdentity)
            XCTAssertEqual(confidenceRestored.score, confidenceScore)
            XCTAssertEqual(confidenceRestored.testingTrackRect.height, 16)
            XCTAssertEqual(confidenceRestored.testingTrackRect.midY, confidenceRestored.bounds.midY)
            XCTAssertEqual(confidenceRestored.testingFillColor, confidenceColor)
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)
            settings.contentTextSizePreference = .system
            provider.bodyPointSize = 26
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(
                view.testingCell(column: "organism", row: 4)?.font?.pointSize,
                baselineFont * 2
            )
            let confidenceSystem = try XCTUnwrap(
                view.testingCellView(column: "confidence", row: 4)
                    as? TaxTriageConfidenceCellView
            )
            XCTAssertEqual(ObjectIdentifier(confidenceSystem), confidenceIdentity)
            XCTAssertEqual(confidenceSystem.score, confidenceScore)
            XCTAssertEqual(confidenceSystem.testingTrackRect.height, 16)
            XCTAssertEqual(confidenceSystem.testingTrackRect.midY, confidenceSystem.bounds.midY)
            XCTAssertEqual(confidenceSystem.testingFillColor, confidenceColor)
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)

            settings.contentTextSizePreference = .custom(200)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)
            let store = try SampleMetadataStore(
                csvData: Data("sample_id,collection_site\nsample-1,Very long site\n".utf8),
                knownSampleIds: ["sample-1"]
            )
            view.metadataColumns.visibleColumns = ["collection_site"]
            view.metadataColumns.update(store: store, sampleId: "sample-1")
            let metadata = try XCTUnwrap(
                view.testingCell(column: "metadata_collection_site", row: 4)
            )
            XCTAssertEqual(metadata.font?.pointSize, 26)
            XCTAssertEqual(metadata.toolTip, "Very long site")
            XCTAssertEqual(metadata.accessibilityValue(), "Very long site")
        }
    }

    func testBatchOverviewKeepsWindowingDataAndHeatmapSemanticsWhileScaling() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            let ids = (0..<150).map { "sample-\($0)-full-identifier" }
            let view = TaxTriageBatchOverviewView(
                frame: NSRect(x: 0, y: 0, width: 760, height: 260)
            )
            let provider = MutableTaxTriagePreferredFonts(bodyPointSize: 13)
            view.testingSetContentPreferredFontProvider(provider)
            view.configure(
                metrics: ids.map { metric(sample: $0) },
                sampleIds: ids
            )
            let window = host(view, size: view.frame.size)
            defer { close(window) }
            view.testingTableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false
            )
            view.testingTableView.sortDescriptors = [
                NSSortDescriptor(key: "organism", ascending: true),
            ]
            view.testingTableView.tableColumns[0].width = 219
            view.testingScroll(to: NSPoint(x: 31, y: 0))
            window.makeFirstResponder(view.testingTableView)
            let baselineState = view.testingPresentationState
            let organism = try XCTUnwrap(view.testingCell(column: "organism", row: 0))
            let baselineFont = try XCTUnwrap(organism.font).pointSize
            let heatmap = try XCTUnwrap(
                view.testingCellView(column: "sample_\(ids[0])", row: 0) as? NSTableCellView
            )
            let heatmapColor = view.testingBackgroundFillColor(in: heatmap)
            let heatmapText = heatmap.textField?.stringValue
            XCTAssertFalse(heatmap.wantsLayer)
            XCTAssertNotNil(heatmapColor)
            XCTAssertEqual(view.currentFacet, .tass)
            let baselineReloadCount = view.testingTableReloadCount

            settings.contentTextSizePreference = .custom(200)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(view.testingSampleColumnCount, 60)
            XCTAssertEqual(view.testingFullSampleIds, ids)
            XCTAssertEqual(view.testingPresentationState, baselineState)
            XCTAssertEqual(
                view.testingCell(column: "organism", row: 0)?.font?.pointSize,
                baselineFont * 2
            )
            let enlargedHeatmap = try XCTUnwrap(
                view.testingCellView(column: "sample_\(ids[0])", row: 0) as? NSTableCellView
            )
            XCTAssertEqual(view.testingBackgroundFillColor(in: enlargedHeatmap), heatmapColor)
            XCTAssertEqual(enlargedHeatmap.textField?.stringValue, heatmapText)
            XCTAssertEqual(enlargedHeatmap.textField?.accessibilityValue(), heatmapText)
            XCTAssertEqual(view.currentFacet, .tass)
            XCTAssertGreaterThan(view.testingTableView.rowHeight, 22)
            XCTAssertGreaterThan(
                try XCTUnwrap(view.testingTableView.headerView).frame.height,
                24
            )
            XCTAssertGreaterThan(view.testingBannerHeight, 24)
            XCTAssertTrue(view.testingBannerLabelWraps)
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)
            XCTAssertLessThanOrEqual(
                view.testingTypographyRealizedCellResolutionCount,
                view.testingTableView.tableColumns.count
            )

            view.showAllSampleColumns()
            XCTAssertEqual(view.testingSampleColumnCount, 150)
            let late = try XCTUnwrap(view.testingCell(column: "sample_\(ids[149])", row: 0))
            XCTAssertEqual(late.font?.pointSize, 22)
            XCTAssertEqual(
                view.testingTableView.tableColumns.last?.headerCell.font?.pointSize,
                26
            )
            XCTAssertEqual(view.testingFullSampleIds, ids)
            let postRevealReloadCount = view.testingTableReloadCount

            settings.contentTextSizePreference = .custom(100)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(view.testingCell(column: "organism", row: 0)?.font?.pointSize, baselineFont)
            XCTAssertEqual(view.testingTableReloadCount, postRevealReloadCount)
        }
    }

    func testBatchOverviewReusedCellsReplaceFacetAndRiskAccessibilityState() throws {
        let control = TaxTriageMetric(
            sample: "control",
            organism: "Risk organism",
            rank: "S",
            reads: 1_234,
            abundance: 0.1,
            coverageBreadth: 50,
            coverageDepth: 10,
            tassScore: 0.91,
            confidence: "High"
        )
        let safe = TaxTriageMetric(
            sample: "sample-1",
            organism: "Safe organism",
            rank: "S",
            reads: 77,
            abundance: 0.1,
            coverageBreadth: 25,
            coverageDepth: 5,
            tassScore: 0.51,
            confidence: "Medium"
        )
        let view = TaxTriageBatchOverviewView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 100)
        )
        view.configure(
            metrics: [control, safe],
            sampleIds: ["control", "sample-1"],
            negativeControlSampleIds: ["control"]
        )
        let window = host(view, size: view.frame.size)
        defer { close(window) }
        let riskRow = try XCTUnwrap(view.testingRowIndex(organism: "Risk organism"))
        let safeRow = try XCTUnwrap(view.testingRowIndex(organism: "Safe organism"))

        let sampleCell = try XCTUnwrap(
            view.testingConfigureReusableCell(
                column: "sample_control",
                row: riskRow,
                reusing: nil
            )
        )
        XCTAssertEqual(sampleCell.textField?.stringValue, "0.91")
        XCTAssertEqual(sampleCell.textField?.toolTip, "0.91")
        XCTAssertEqual(sampleCell.textField?.accessibilityValue(), "0.91")
        XCTAssertNil(sampleCell.textField?.accessibilityHelp())

        view.testingSelectFacet(.reads)
        let readsCell = try XCTUnwrap(
            view.testingConfigureReusableCell(
                column: "sample_control",
                row: riskRow,
                reusing: sampleCell
            )
        )
        XCTAssertTrue(readsCell === sampleCell)
        XCTAssertEqual(readsCell.textField?.stringValue, "1.2K")
        XCTAssertEqual(readsCell.textField?.toolTip, "1.2K")
        XCTAssertEqual(readsCell.textField?.accessibilityValue(), "1.2K")
        XCTAssertNil(readsCell.textField?.accessibilityHelp())

        let riskCell = try XCTUnwrap(
            view.testingConfigureReusableCell(column: "risk", row: riskRow, reusing: nil)
        )
        XCTAssertFalse(riskCell.wantsLayer)
        XCTAssertNotNil(view.testingBackgroundFillColor(in: riskCell))
        XCTAssertEqual(riskCell.textField?.stringValue, "\u{26A0}")
        XCTAssertEqual(riskCell.textField?.toolTip, "Detected in negative control sample")
        XCTAssertEqual(riskCell.textField?.accessibilityLabel(), "Contamination risk")
        XCTAssertEqual(riskCell.textField?.accessibilityValue(), "\u{26A0}")
        XCTAssertEqual(
            riskCell.textField?.accessibilityHelp(),
            "Detected in negative control sample"
        )

        view.testingTableView.scrollRowToVisible(safeRow)
        view.testingTableView.layoutSubtreeIfNeeded()
        let reusedSafeCell = try XCTUnwrap(
            view.testingConfigureReusableCell(
                column: "risk",
                row: safeRow,
                reusing: riskCell
            )
        )
        XCTAssertTrue(reusedSafeCell === riskCell)
        XCTAssertEqual(reusedSafeCell.textField?.stringValue, "")
        XCTAssertNil(reusedSafeCell.textField?.toolTip)
        XCTAssertNil(reusedSafeCell.textField?.accessibilityLabel())
        XCTAssertEqual(reusedSafeCell.textField?.accessibilityValue(), "")
        XCTAssertNil(reusedSafeCell.textField?.accessibilityHelp())
        XCTAssertNil(view.testingBackgroundFillColor(in: reusedSafeCell))
    }

    func testStrainComparisonScalesLateColumnsWithoutChangingBaseCalls() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            let ids = (0..<150).map { "S\($0)" }
            let view = StrainComparisonView(
                frame: NSRect(x: 0, y: 0, width: 720, height: 240)
            )
            view.testingSetContentPreferredFontProvider(
                MutableTaxTriagePreferredFonts(bodyPointSize: 13)
            )
            view.configure(
                entries: [
                    StrainComparisonEntry(
                        accession: "NC_000001.1",
                        position: 9,
                        referenceBase: "G",
                        sampleBases: Dictionary(uniqueKeysWithValues: ids.map { ($0, "A") })
                    ),
                ],
                sampleIds: ids,
                organismName: "A very long organism heading"
            )
            let window = host(view, size: view.frame.size)
            defer { close(window) }
            view.testingTableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false
            )
            view.testingTableView.sortDescriptors = [
                NSSortDescriptor(key: "position", ascending: true),
            ]
            view.testingTableView.tableColumns[0].width = 171
            view.testingScroll(to: NSPoint(x: 23, y: 0))
            window.makeFirstResponder(view.testingTableView)
            let baselineState = view.testingPresentationState
            let baselineHeader = view.testingHeaderPointSize
            let baselineBase = try XCTUnwrap(
                view.testingCell(column: "sample_S0", row: 0)
            )
            let baselinePointSize = try XCTUnwrap(baselineBase.font).pointSize
            let baselineText = baselineBase.stringValue
            let baselineColor = baselineBase.textColor
            let baselineReloadCount = view.testingTableReloadCount

            settings.contentTextSizePreference = .custom(200)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(view.testingHeaderPointSize, baselineHeader * 2)
            XCTAssertEqual(
                view.testingCell(column: "sample_S0", row: 0)?.font?.pointSize,
                baselinePointSize * 2
            )
            XCTAssertEqual(view.testingCell(column: "sample_S0", row: 0)?.stringValue, baselineText)
            XCTAssertEqual(view.testingCell(column: "sample_S0", row: 0)?.textColor, baselineColor)
            XCTAssertEqual(view.testingSampleColumnCount, 60)
            XCTAssertEqual(view.testingFullSampleIds, ids)
            XCTAssertEqual(view.testingPresentationState, baselineState)
            XCTAssertGreaterThan(view.testingTableView.rowHeight, 20)
            XCTAssertGreaterThan(
                try XCTUnwrap(view.testingTableView.headerView).frame.height,
                24
            )
            XCTAssertEqual(view.testingTableReloadCount, baselineReloadCount)
            XCTAssertLessThanOrEqual(
                view.testingTypographyRealizedCellResolutionCount,
                view.testingTableView.tableColumns.count
            )

            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(view.testingHeaderPointSize, baselineHeader * 2)
            view.showAllSampleColumns()
            let late = try XCTUnwrap(view.testingCell(column: "sample_S149", row: 0))
            XCTAssertEqual(late.font?.pointSize, baselinePointSize * 2)
            XCTAssertEqual(late.stringValue, "A")
            let postRevealReloadCount = view.testingTableReloadCount

            settings.contentTextSizePreference = .custom(100)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(view.testingHeaderPointSize, baselineHeader)
            XCTAssertEqual(
                view.testingCell(column: "sample_S149", row: 0)?.font?.pointSize,
                baselinePointSize
            )
            XCTAssertEqual(view.testingTableReloadCount, postRevealReloadCount)
        }
    }

    func testResultSearchPlaceholderAndFilterRowScaleWithoutTouchingChromeOrMiniBAM() throws {
        try preservingContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .custom(100)
            let provider = MutableTaxTriagePreferredFonts(bodyPointSize: 13)
            let controller = TaxTriageResultViewController()
            controller.testingSetContentPreferredFontProvider(provider)
            controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
            let window = host(controller.view, size: controller.view.frame.size)
            defer { close(window) }
            controller.testingShowFilterRow()
            controller.testingShowMultiSelectionPlaceholder(count: 123)
            controller.view.layoutSubtreeIfNeeded()
            let baselineSearch = try XCTUnwrap(controller.testingOrganismSearchField.font).pointSize
            let baselineFilterHeight = controller.testingFilterRowHeight
            let baselineChrome = controller.testSampleFilterControl.font
            let baselineMiniIdentity = controller.testingMiniBAMControllerIdentity
            let baselineMiniLoadCount = controller.testingMiniBAMLoadCount

            settings.contentTextSizePreference = .custom(200)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            controller.view.layoutSubtreeIfNeeded()
            controller.testingLayoutMultiSelectionPlaceholder(width: 240, height: 160)
            XCTAssertEqual(
                controller.testingOrganismSearchField.font?.pointSize,
                baselineSearch * 2
            )
            XCTAssertGreaterThan(controller.testingFilterRowHeight, baselineFilterHeight)
            XCTAssertGreaterThanOrEqual(
                controller.testingFilterRowHeight,
                ceil(
                    try XCTUnwrap(controller.testingOrganismSearchField.font)
                        .boundingRectForFont.height + 8
                )
            )
            XCTAssertEqual(controller.testSampleFilterControl.font, baselineChrome)
            XCTAssertTrue(controller.testingPlaceholderFields.allSatisfy {
                ($0.font?.pointSize ?? 0) >= 22
                    && $0.maximumNumberOfLines == 0
                    && $0.lineBreakMode == .byWordWrapping
            })
            XCTAssertTrue(controller.testingPlaceholderFieldsAreContainedAndSeparated)
            XCTAssertEqual(controller.testingMiniBAMControllerIdentity, baselineMiniIdentity)
            XCTAssertEqual(controller.testingMiniBAMLoadCount, baselineMiniLoadCount)

            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(
                controller.testingOrganismSearchField.font?.pointSize,
                baselineSearch * 2
            )
            settings.contentTextSizePreference = .custom(100)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(controller.testingOrganismSearchField.font?.pointSize, baselineSearch)
            settings.contentTextSizePreference = .system
            provider.bodyPointSize = 26
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            XCTAssertEqual(
                controller.testingOrganismSearchField.font?.pointSize,
                baselineSearch * 2
            )
        }
    }

    func testTaxTriageTypographyObserversDoNotRetainOwners() {
        weak var organism: TaxTriageOrganismTableView?
        weak var overview: TaxTriageBatchOverviewView?
        weak var strain: StrainComparisonView?
        weak var controller: TaxTriageResultViewController?
        autoreleasepool {
            let strongOrganism = TaxTriageOrganismTableView()
            let strongOverview = TaxTriageBatchOverviewView()
            let strongStrain = StrainComparisonView()
            let strongController = TaxTriageResultViewController()
            _ = strongController.view
            organism = strongOrganism
            overview = strongOverview
            strain = strongStrain
            controller = strongController
            withExtendedLifetime((
                strongOrganism,
                strongOverview,
                strongStrain,
                strongController
            )) {}
        }
        XCTAssertNil(organism)
        XCTAssertNil(overview)
        XCTAssertNil(strain)
        XCTAssertNil(controller)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
    }

    private func metric(sample: String) -> TaxTriageMetric {
        TaxTriageMetric(
            sample: sample,
            organism: "Aeromonas salmonicida",
            rank: "S",
            reads: 2_400,
            abundance: 0.12,
            coverageBreadth: 91.2,
            coverageDepth: 33.1,
            tassScore: 0.91,
            confidence: "High"
        )
    }

    private func host(_ view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func preservingContentTextSizePreference(
        _ body: () throws -> Void
    ) rethrows {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        try body()
    }
}

@MainActor
private final class MutableTaxTriagePreferredFonts: ContentPreferredFontProviding {
    var bodyPointSize: CGFloat

    init(bodyPointSize: CGFloat) {
        self.bodyPointSize = bodyPointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .body, .detail:
            return .systemFont(ofSize: bodyPointSize)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: bodyPointSize, weight: .semibold)
        case .caption:
            return .systemFont(ofSize: bodyPointSize - 2)
        case .monospaced:
            return .monospacedSystemFont(ofSize: bodyPointSize, weight: .regular)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        13
    }
}
