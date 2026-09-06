// EsVirituResultViewControllerSmokeTests.swift - Standalone smoke test for the EsViritu leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit
@testable import LungfishCore

@MainActor
private final class EsVirituRecordingEvidenceViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []
    private(set) var clearCount = 0
    override init() { super.init(); viewController.view = NSView() }
    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() { clearCount += 1 }
}

final class EsVirituResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testDatabaseSelectionBuildsDetachedEvidenceRequestForDuplicateAccession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleABAM = root.appendingPathComponent("sample-a.bam")
        let sampleAIndex = root.appendingPathComponent("sample-a.bam.bai")
        let sampleBBAM = root.appendingPathComponent("sample-b.bam")
        let sampleBIndex = root.appendingPathComponent("sample-b.bam.csi")
        for url in [sampleABAM, sampleAIndex, sampleBBAM, sampleBIndex] {
            try Data().write(to: url)
        }
        let database = try EsVirituDatabase.create(
            at: root.appendingPathComponent("esviritu.sqlite"),
            rows: [
                Self.evidenceRow(sample: "sample-a", bamURL: sampleABAM, indexURL: sampleAIndex),
                Self.evidenceRow(sample: "sample-b", bamURL: sampleBBAM, indexURL: sampleBIndex),
            ],
            metadata: ["tool": "test"]
        )
        let recorder = EsVirituRecordingEvidenceViewer()
        var factoryInvocationCount = 0
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = {
            factoryInvocationCount += 1
            return recorder
        }
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: root)
        let table = controller.testDetectionTableView.testOutlineView
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.testCurrentBAMSampleID, "sample-b")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(controller.testCurrentBAMSampleID, "sample-a")

        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertEqual(recorder.requests.count, 2)
        let firstRequest = recorder.requests[0]
        XCTAssertEqual(firstRequest.workflow, .esViritu)
        XCTAssertEqual(firstRequest.resultIdentity.finalResultURL, root)
        XCTAssertEqual(firstRequest.resultIdentity.provenanceID, "esviritu:\(root.lastPathComponent)")
        XCTAssertEqual(firstRequest.bamURL, sampleBBAM)
        XCTAssertEqual(firstRequest.index.url, sampleBIndex)
        XCTAssertEqual(firstRequest.index.kind, .csi)
        XCTAssertEqual(firstRequest.sample.canonicalID, "sample-b")
        XCTAssertEqual(firstRequest.contig.name, "NC_DUP.1")
        XCTAssertEqual(firstRequest.contig.expectedLength, 4_200)
        XCTAssertNil(firstRequest.referenceCandidate)
        let secondRequest = recorder.requests[1]
        XCTAssertEqual(secondRequest.bamURL, sampleABAM)
        XCTAssertEqual(secondRequest.index.url, sampleAIndex)
        XCTAssertEqual(secondRequest.index.kind, .bai)
        XCTAssertEqual(secondRequest.sample.canonicalID, "sample-a")
        XCTAssertEqual(secondRequest.contig.name, "NC_DUP.1")
        XCTAssertEqual(secondRequest.contig.expectedLength, 4_200)
        XCTAssertNil(secondRequest.referenceCandidate)

        let clearCountBeforeMultiSelection = recorder.clearCount
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertEqual(
            recorder.clearCount,
            clearCountBeforeMultiSelection + 1,
            "actual multi-selection clears the shared provider"
        )
        table.deselectAll(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            recorder.clearCount,
            clearCountBeforeMultiSelection + 2,
            "actual selection clearing clears the shared provider"
        )
    }

    private static func evidenceRow(
        sample: String,
        bamURL: URL,
        indexURL: URL
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample,
            virusName: "Duplicate virus",
            description: nil,
            contigLength: 4_200,
            segment: nil,
            accession: "NC_DUP.1",
            assembly: "ASM_\(sample)",
            assemblyLength: 4_200,
            kingdom: nil,
            phylum: nil,
            tclass: nil,
            torder: nil,
            family: nil,
            genus: nil,
            species: nil,
            subspecies: nil,
            rpkmf: 1,
            readCount: sample == "sample-b" ? 24 : 12,
            uniqueReads: sample == "sample-b" ? 20 : 10,
            coveredBases: 4_200,
            meanCoverage: 1,
            avgReadIdentity: 0.99,
            pi: nil,
            filteredReadsInSample: 100,
            bamPath: bamURL.path,
            bamIndexPath: indexURL.path
        )
    }

    func testEsVirituLeafDoesNotDependOnMiniBAM() throws {
        let directory = URL(fileURLWithPath: "Sources/LungfishEsVirituUI")
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(sources.contains("MiniBAMViewController"))
        let source = try String(contentsOfFile: "Sources/LungfishEsVirituUI/EsVirituResultViewController.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("currentBAMSampleID"))
        XCTAssertTrue(source.contains("sample: .init(canonicalID: sampleID)"))
    }

    @MainActor func testViewControllerInstantiates() {
        let vc = EsVirituResultViewController()
        XCTAssertNotNil(vc.view)
    }

    @MainActor func testViralDetectionSearchFieldChangesAreDebounced() {
        let table = ViralDetectionTableView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        table.result = Self.esvirituResult([
            Self.viralAssembly(name: "Alpha virus", sampleId: "sample-A", assembly: "GCF_A", accession: "NC_A", reads: 40),
            Self.viralAssembly(name: "Beta virus", sampleId: "sample-B", assembly: "GCF_B", accession: "NC_B", reads: 20),
            Self.viralAssembly(name: "Gamma virus", sampleId: "sample-C", assembly: "GCF_C", accession: "NC_C", reads: 10),
        ])
        let initialFilterCount = table.testingFilterApplicationCount

        table.testingSubmitSearchText("a")
        table.testingSubmitSearchText("al")
        table.testingSubmitSearchText("alpha")

        XCTAssertEqual(table.testingFilterApplicationCount, initialFilterCount)

        let deadline = Date().addingTimeInterval(1.0)
        while table.testingFilterApplicationCount == initialFilterCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(table.testingFilterApplicationCount, initialFilterCount + 1)
        XCTAssertEqual(table.testDisplayedAssemblyCount, 1)
    }

    @MainActor func testViralDetectionTypographyScalesLateCellsAndPreservesSelection() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let table = ViralDetectionTableView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 360)
        )
        table.result = Self.esvirituResult([
            Self.viralAssembly(
                name: "Alpha virus",
                sampleId: "sample-A",
                assembly: "GCF_A",
                accession: "NC_A",
                reads: 40
            ),
        ])
        table.testOutlineView.expandItem(table.testOutlineView.item(atRow: 0))
        table.testOutlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let baseline = table.testingTypographyMetrics
        let selectedRows = table.testOutlineView.selectedRowIndexes
        let displayedCount = table.testDisplayedAssemblyCount

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let enlarged = table.testingTypographyMetrics
        XCTAssertEqual(enlarged.searchPointSize, baseline.searchPointSize * 2)
        XCTAssertEqual(enlarged.countPointSize, baseline.countPointSize * 2)
        XCTAssertEqual(enlarged.nameCellPointSize, baseline.nameCellPointSize * 2)
        XCTAssertEqual(enlarged.numericCellPointSize, baseline.numericCellPointSize * 2)
        XCTAssertGreaterThan(enlarged.rowHeight, baseline.rowHeight)
        XCTAssertGreaterThan(enlarged.headerHeight, baseline.headerHeight)
        XCTAssertEqual(table.testOutlineView.selectedRowIndexes, selectedRows)
        XCTAssertEqual(table.testDisplayedAssemblyCount, displayedCount)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(table.testingTypographyMetrics, baseline)
    }

    @MainActor func testLateMetadataCellDoesNotCompoundAtRepeatedTwoHundredPercent() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let table = ViralDetectionTableView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 360)
        )
        table.result = Self.esvirituResult([
            Self.viralAssembly(
                name: "Alpha virus",
                sampleId: "sample-A",
                assembly: "GCF_A",
                accession: "NC_A",
                reads: 40
            ),
        ])
        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        table.metadataColumns.visibleColumns = ["Type"]
        table.metadataColumns.update(
            store: try SampleMetadataStore(
                csvData: Data("Sample\tType\nsample-A\tclinical\n".utf8),
                knownSampleIds: ["sample-A"]
            ),
            sampleId: "sample-A"
        )
        let metadataCell = try XCTUnwrap(
            table.testingRealizedCell(column: "metadata_Type", row: 0)
        )
        let expectedEnlarged = ContentTypography.current().font(for: .body).pointSize
        XCTAssertEqual(metadataCell.textField?.font?.pointSize, expectedEnlarged)

        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(metadataCell.textField?.font?.pointSize, expectedEnlarged)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let expectedBaseline = ContentTypography.current().font(for: .body).pointSize
        XCTAssertEqual(metadataCell.textField?.font?.pointSize, expectedBaseline)
    }

    @MainActor func testEsVirituDetailTypographyDoesNotRebuildScientificContent() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let pane = EsVirituDetailPane(
            frame: NSRect(x: 0, y: 0, width: 360, height: 520)
        )
        let result = Self.esvirituResult([
            Self.viralAssembly(
                name: "Alpha virus",
                sampleId: "sample-A",
                assembly: "GCF_A",
                accession: "NC_A",
                reads: 40
            ),
        ])
        pane.configureOverview(result: result, coverageWindows: [:], bamURL: nil)
        let baseline = pane.testingTypographyMetrics
        let rebuildCount = pane.testingContentRebuildCount

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let enlarged = pane.testingTypographyMetrics
        XCTAssertEqual(enlarged.titlePointSize, baseline.titlePointSize * 2)
        XCTAssertEqual(enlarged.summaryPointSize, baseline.summaryPointSize * 2)
        XCTAssertEqual(pane.testingContentRebuildCount, rebuildCount)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(pane.testingTypographyMetrics, baseline)
        XCTAssertEqual(pane.testingContentRebuildCount, rebuildCount)
    }

    @MainActor func testDetailRebuildReleasesRetiredMetricLayoutConstraints() {
        let assembly = Self.viralAssembly(
            name: "Alpha virus",
            sampleId: "sample-A",
            assembly: "GCF_A",
            accession: "NC_A",
            reads: 40
        )
        let result = Self.esvirituResult([assembly])
        let pane = EsVirituDetailPane()
        pane.showVirusDetail(assembly: assembly, coverageWindows: [:], bamURL: nil)
        XCTAssertEqual(Self.retainedMetricConstraintCount(in: pane), 5)

        pane.configureOverview(result: result, coverageWindows: [:], bamURL: nil)

        XCTAssertEqual(Self.retainedMetricConstraintCount(in: pane), 0)
    }

    @MainActor func testDetailTypographyPreservesScientificViewsAndScrollOrigin() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let first = Self.viralAssembly(
            name: "Segmented virus",
            sampleId: "sample-A",
            assembly: "GCF_SEG",
            accession: "NC_SEG_L",
            reads: 40,
            segment: "L"
        )
        let second = Self.viralAssembly(
            name: "Segmented virus",
            sampleId: "sample-A",
            assembly: "GCF_SEG",
            accession: "NC_SEG_S",
            reads: 30,
            segment: "S"
        )
        let assembly = ViralAssembly(
            assembly: first.assembly,
            assemblyLength: first.assemblyLength + second.assemblyLength,
            name: first.name,
            family: first.family,
            genus: first.genus,
            species: first.species,
            totalReads: first.totalReads + second.totalReads,
            rpkmf: first.rpkmf + second.rpkmf,
            meanCoverage: first.meanCoverage,
            avgReadIdentity: first.avgReadIdentity,
            contigs: first.contigs + second.contigs
        )
        let windows = Dictionary(uniqueKeysWithValues: assembly.contigs.map { contig in
            (
                contig.accession,
                [
                    ViralCoverageWindow(
                        accession: contig.accession,
                        windowIndex: 0,
                        windowStart: 0,
                        windowEnd: 50,
                        averageCoverage: 2
                    ),
                    ViralCoverageWindow(
                        accession: contig.accession,
                        windowIndex: 1,
                        windowStart: 50,
                        windowEnd: 100,
                        averageCoverage: 8
                    ),
                ]
            )
        })
        let pane = EsVirituDetailPane(
            frame: NSRect(x: 0, y: 0, width: 360, height: 180)
        )
        let window = NSWindow(
            contentRect: pane.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = pane
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        pane.showVirusDetail(
            assembly: assembly,
            coverageWindows: windows,
            bamURL: nil
        )
        pane.layoutSubtreeIfNeeded()
        let segmentView = try XCTUnwrap(
            Self.firstDescendant(of: SegmentCompletenessView.self, in: pane)
        )
        let coverageView = try XCTUnwrap(
            Self.firstDescendant(of: CoverageAreaChartView.self, in: pane)
        )
        let scrollView = try XCTUnwrap(
            Self.firstDescendant(of: NSScrollView.self, in: pane)
        )
        let segmentIdentity = ObjectIdentifier(segmentView)
        let coverageIdentity = ObjectIdentifier(coverageView)
        let segmentSize = segmentView.bounds.size
        let coverageSize = coverageView.bounds.size
        let rebuildCount = pane.testingContentRebuildCount
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 24))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let scrollOrigin = scrollView.contentView.bounds.origin

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        pane.layoutSubtreeIfNeeded()

        XCTAssertEqual(ObjectIdentifier(segmentView), segmentIdentity)
        XCTAssertEqual(ObjectIdentifier(coverageView), coverageIdentity)
        XCTAssertEqual(segmentView.bounds.size, segmentSize)
        XCTAssertEqual(coverageView.bounds.size, coverageSize)
        XCTAssertEqual(scrollView.contentView.bounds.origin, scrollOrigin)
        XCTAssertEqual(pane.testingContentRebuildCount, rebuildCount)
    }

    @MainActor func testViralDetectionTypographyPreservesLiveEditingAndOutlineState() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let table = ViralDetectionTableView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 260)
        )
        let assemblies = (0..<30).map {
            let assembly = Self.viralAssembly(
                name: "Virus \($0) with a long complete scientific name",
                sampleId: "sample-\($0)",
                assembly: "GCF_\($0)",
                accession: "NC_000000000\($0).1",
                reads: 40 + $0
            )
            guard $0 == 29 else { return assembly }
            return ViralAssembly(
                assembly: assembly.assembly,
                assemblyLength: assembly.assemblyLength,
                name: assembly.name,
                family: assembly.family,
                genus: assembly.genus,
                species: assembly.species,
                totalReads: assembly.totalReads,
                rpkmf: assembly.rpkmf,
                meanCoverage: assembly.meanCoverage,
                avgReadIdentity: assembly.avgReadIdentity,
                contigs: assembly.contigs + assembly.contigs
            )
        }
        for assembly in assemblies {
            guard let accession = assembly.contigs.first?.accession else { continue }
            table.coverageWindowsByAccession[accession] = [
                ViralCoverageWindow(
                    accession: accession,
                    windowIndex: 0,
                    windowStart: 0,
                    windowEnd: 100,
                    averageCoverage: 2
                ),
                ViralCoverageWindow(
                    accession: accession,
                    windowIndex: 1,
                    windowStart: 100,
                    windowEnd: 200,
                    averageCoverage: 8
                ),
            ]
        }
        table.result = Self.esvirituResult(assemblies)
        let window = NSWindow(
            contentRect: table.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: table.frame)
        table.frame = host.bounds
        table.autoresizingMask = [.width, .height]
        host.addSubview(table)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            _ = window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        table.testOutlineView.sortDescriptors = [
            NSSortDescriptor(key: "reads", ascending: false),
        ]
        let root = try XCTUnwrap(table.testOutlineView.item(atRow: 0))
        table.testOutlineView.expandItem(root)
        XCTAssertTrue(table.testOutlineView.isItemExpanded(root))
        table.testOutlineView.selectRowIndexes(
            IndexSet([0, 1]),
            byExtendingSelection: false
        )
        let search = table.testingSearchField
        search.stringValue = "Virus"
        XCTAssertTrue(window.makeFirstResponder(search))
        search.currentEditor()?.selectedRange = NSRange(location: 1, length: 3)
        table.layoutSubtreeIfNeeded()
        table.testingScrollRowToVisible(20)
        table.testOutlineView.enclosingScrollView?.reflectScrolledClipView(
            table.testOutlineView.enclosingScrollView!.contentView
        )
        let baselineTopVisibleRow = table.testingTopVisibleRow
        let nameCell = try XCTUnwrap(
            table.testingRealizedCell(column: "name", row: baselineTopVisibleRow)
        )
        let baselineSparkline = try XCTUnwrap(
            table.testingCoverageSparkline(row: baselineTopVisibleRow)
        )
        baselineSparkline.superview?.layoutSubtreeIfNeeded()
        let baselineCoverageWindows = baselineSparkline.windows
        let baselineSparklineHeight = baselineSparkline.frame.height
        let baselineNamePointSize = try XCTUnwrap(nameCell.textField?.font?.pointSize)
        let outlineIdentity = ObjectIdentifier(table.testOutlineView)
        let searchIdentity = ObjectIdentifier(search)
        let baselineColumnIdentifiers = table.testOutlineView.tableColumns.map(\.identifier)
        let baselineColumnWidths = table.testOutlineView.tableColumns.map(\.width)
        let baselineFilterCount = table.testingFilterApplicationCount
        let baselineReloadCount = table.testingOutlineReloadCount
        let baselineRebuildCount = table.testingItemRebuildCount

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(ObjectIdentifier(table.testOutlineView), outlineIdentity)
        XCTAssertEqual(ObjectIdentifier(table.testingSearchField), searchIdentity)
        XCTAssertTrue(table.testOutlineView.isItemExpanded(root))
        XCTAssertEqual(table.testOutlineView.selectedRowIndexes, IndexSet([0, 1]))
        XCTAssertEqual(table.testOutlineView.sortDescriptors.first?.key, "reads")
        XCTAssertEqual(search.currentEditor()?.selectedRange, NSRange(location: 1, length: 3))
        XCTAssertEqual(table.testingFilterApplicationCount, baselineFilterCount)
        XCTAssertEqual(table.testingOutlineReloadCount, baselineReloadCount)
        XCTAssertEqual(table.testingItemRebuildCount, baselineRebuildCount)
        XCTAssertEqual(
            table.testOutlineView.tableColumns.map(\.identifier),
            baselineColumnIdentifiers
        )
        XCTAssertEqual(
            table.testOutlineView.tableColumns.map(\.width),
            baselineColumnWidths
        )
        XCTAssertEqual(
            table.testingTopVisibleRow,
            baselineTopVisibleRow,
            "origin=\(table.testingScrollOriginY), anchorRect=\(table.testOutlineView.rect(ofRow: baselineTopVisibleRow)), rowHeight=\(table.testOutlineView.rowHeight), table=\(table.testOutlineView.frame), clip=\(table.testOutlineView.enclosingScrollView?.contentView.bounds ?? .zero)"
        )
        let scaledNameCell = try XCTUnwrap(
            table.testingRealizedCell(column: "name", row: baselineTopVisibleRow)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(scaledNameCell.textField?.font?.pointSize),
            baselineNamePointSize
        )
        XCTAssertEqual(
            scaledNameCell.textField?.toolTip,
            scaledNameCell.textField?.stringValue
        )
        XCTAssertEqual(
            scaledNameCell.textField?.accessibilityValue() as? String,
            scaledNameCell.textField?.stringValue
        )
        let scaledSparkline = try XCTUnwrap(
            table.testingCoverageSparkline(row: baselineTopVisibleRow)
        )
        scaledSparkline.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(scaledSparkline.windows, baselineCoverageWindows)
        XCTAssertEqual(scaledSparkline.frame.height, baselineSparklineHeight)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(
            table.testingTopVisibleRow,
            baselineTopVisibleRow,
            "origin=\(table.testingScrollOriginY), anchorRect=\(table.testOutlineView.rect(ofRow: baselineTopVisibleRow)), rowHeight=\(table.testOutlineView.rowHeight), table=\(table.testOutlineView.frame), clip=\(table.testOutlineView.enclosingScrollView?.contentView.bounds ?? .zero)"
        )
        XCTAssertEqual(
            table.testOutlineView.tableColumns.map(\.identifier),
            baselineColumnIdentifiers
        )
        XCTAssertEqual(
            table.testOutlineView.tableColumns.map(\.width),
            baselineColumnWidths
        )
        XCTAssertEqual(table.testingOutlineReloadCount, baselineReloadCount)
        XCTAssertEqual(table.testingItemRebuildCount, baselineRebuildCount)
        XCTAssertEqual(search.currentEditor()?.selectedRange, NSRange(location: 1, length: 3))
    }

    @MainActor func testBatchEsVirituExplicitFontsRoundTripWithoutCompounding() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let table = BatchEsVirituTableView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 220)
        )
        table.configure(rows: [
            BatchEsVirituRow(
                sample: "sample-A",
                virusName: "Long virus name",
                family: "Longviridae",
                assembly: "GCF_000000001.1",
                readCount: 100,
                uniqueReads: 90,
                rpkmf: 12,
                coverageBreadth: 0.8,
                coverageDepth: 3
            ),
        ])
        let sampleColumn = try XCTUnwrap(
            table.testTableView.tableColumn(withIdentifier: .init("sample"))
        )
        let assemblyColumn = try XCTUnwrap(
            table.testTableView.tableColumn(withIdentifier: .init("assembly"))
        )
        func fonts() throws -> (NSFont, NSFont) {
            let sample = try XCTUnwrap(
                table.tableView(table.testTableView, viewFor: sampleColumn, row: 0)
                    as? NSTableCellView
            )
            let assembly = try XCTUnwrap(
                table.tableView(table.testTableView, viewFor: assemblyColumn, row: 0)
                    as? NSTableCellView
            )
            return (
                try XCTUnwrap(sample.textField?.font),
                try XCTUnwrap(assembly.textField?.font)
            )
        }
        let baseline = try fonts()
        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        let enlarged = try fonts()
        XCTAssertEqual(enlarged.0.pointSize, baseline.0.pointSize * 2)
        XCTAssertEqual(enlarged.1.pointSize, baseline.1.pointSize * 2)
        XCTAssertTrue(enlarged.1.isFixedPitch)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(try fonts().0.pointSize, enlarged.0.pointSize)
        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(try fonts().0.pointSize, baseline.0.pointSize)
        XCTAssertEqual(try fonts().1.pointSize, baseline.1.pointSize)
    }

    @MainActor func testEsNarrowDetailAndPlaceholderReflowAtTwoHundredPercent() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(200)
        let assembly = Self.viralAssembly(
            name: "Extremely long virus name requiring multiple complete lines",
            sampleId: "sample-A",
            assembly: "GCF_LONG",
            accession: "NC_EXTREMELY_LONG_ACCESSION.1",
            reads: 40
        )
        let pane = EsVirituDetailPane(
            frame: NSRect(x: 0, y: 0, width: 240, height: 700)
        )
        let detailWindow = NSWindow(
            contentRect: pane.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        detailWindow.contentView = pane
        detailWindow.makeKeyAndOrderFront(nil)
        defer {
            detailWindow.orderOut(nil)
            detailWindow.contentView = nil
        }
        pane.showVirusDetail(
            assembly: assembly,
            coverageWindows: [:],
            bamURL: nil
        )
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.testingTypographyMetrics.metricOrientation, .vertical)
        XCTAssertTrue(
            pane.testingTypographyMetrics.metricFieldsAreContained,
            pane.testingMetricFrameDescription
        )
        XCTAssertTrue(pane.testingFullTextAccessibility.allSatisfy {
            $0.0.isEmpty || ($0.1 == $0.0 && $0.2 == $0.0)
        })

        let controller = EsVirituResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        let controllerWindow = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        controllerWindow.contentView = controller.view
        controllerWindow.makeKeyAndOrderFront(nil)
        defer {
            controllerWindow.orderOut(nil)
            controllerWindow.contentView = nil
        }
        controller.testingShowMultiSelectionPlaceholder(count: 123_456)
        let placeholder = controller.testingPlaceholderTypographyMetrics
        XCTAssertGreaterThan(placeholder.primaryPointSize, 13)
        XCTAssertGreaterThan(placeholder.secondaryPointSize, 11)
        XCTAssertTrue(
            placeholder.fieldsAreContained,
            controller.testingPlaceholderFrameDescription
        )
    }

    @MainActor func testEsTypographyObserversDoNotRetainTheirHosts() {
        weak var weakTable: ViralDetectionTableView?
        weak var weakPane: EsVirituDetailPane?
        weak var weakController: EsVirituResultViewController?
        autoreleasepool {
            let table = ViralDetectionTableView()
            let pane = EsVirituDetailPane()
            let controller = EsVirituResultViewController()
            _ = controller.view
            weakTable = table
            weakPane = pane
            weakController = controller
        }
        XCTAssertNil(weakTable)
        XCTAssertNil(weakPane)
        XCTAssertNil(weakController)
    }

    @MainActor func testDelimitedDetectionExportWritesScientificProvenanceSidecar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituDetectionExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = Self.esvirituResult([
            Self.viralAssembly(name: "Alpha virus", sampleId: "sample-A", assembly: "GCF_A", accession: "NC_A", reads: 40),
            Self.viralAssembly(name: "Beta virus", sampleId: "sample-B", assembly: "GCF_B", accession: "NC_B", reads: 20),
        ])
        let vc = EsVirituResultViewController()
        _ = vc.view
        vc.isBatchMode = true
        vc.samplePickerState = ClassifierSamplePickerState(allSamples: Set(["sample-A", "sample-B"]))
        vc.samplePickerState.selectedSamples = ["sample-A"]

        let outputURL = tempDir.appendingPathComponent("detections.tsv")
        try vc.writeDelimitedDetections(result: result, separator: "\t", fileExtension: "tsv", to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app esviritu detections export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 2)
        XCTAssertEqual(
            envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample-A"]
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["tableMode"]?.stringValue, "batchHierarchical")
        XCTAssertEqual(envelope.options.resolvedDefaults["searchText"]?.stringValue, "")
    }

    // MARK: - R3-R3ML-5: off-main batch aggregated manifest unique-reads update

    func testApplyingUniqueReadsMergesOnlyMatchingSampleAssemblyRows() {
        let manifest = EsVirituBatchAggregatedManifest(
            createdAt: Date(timeIntervalSince1970: 0),
            sampleCount: 2,
            sampleIds: ["sample-A", "sample-B"],
            cachedRows: [
                Self.cachedRow(sample: "sample-A", assembly: "GCF_A", uniqueReads: 0),
                Self.cachedRow(sample: "sample-B", assembly: "GCF_B", uniqueReads: 0),
            ]
        )

        let updated = EsVirituResultViewController.applyingUniqueReads(
            byAssemblyAndSample: ["sample-A\tGCF_A": 17],
            to: manifest
        )

        XCTAssertEqual(updated.cachedRows.first { $0.sample == "sample-A" }?.uniqueReads, 17)
        // sample-B has no matching entry in byAssemblyAndSample -- must be left unchanged.
        XCTAssertEqual(updated.cachedRows.first { $0.sample == "sample-B" }?.uniqueReads, 0)
        // Non-uniqueReads fields must be preserved untouched.
        XCTAssertEqual(updated.cachedRows.first { $0.sample == "sample-A" }?.readCount, 100)
        XCTAssertEqual(updated.sampleIds, manifest.sampleIds)
        XCTAssertEqual(updated.sampleCount, manifest.sampleCount)
    }

    func testApplyingUniqueReadsIsAPureFunctionThatDoesNotMutateItsInput() {
        let original = EsVirituBatchAggregatedManifest(
            createdAt: Date(timeIntervalSince1970: 0),
            sampleCount: 1,
            sampleIds: ["sample-A"],
            cachedRows: [Self.cachedRow(sample: "sample-A", assembly: "GCF_A", uniqueReads: 5)]
        )

        _ = EsVirituResultViewController.applyingUniqueReads(
            byAssemblyAndSample: ["sample-A\tGCF_A": 99],
            to: original
        )

        XCTAssertEqual(original.cachedRows.first?.uniqueReads, 5, "the input manifest value must not be mutated")
    }

    /// Regression guard for R3-R3ML-5: the manifest read/mutate/write must run off the main
    /// actor (via Task.detached), not synchronously inside the per-sample completion handler.
    /// Asserts the source wiring rather than measuring wall-clock UI blocking, matching the
    /// existing testImportWritesCanonicalProvenanceBeforeManifestUpdate-style ordering guard
    /// used elsewhere in this codebase for changes that aren't practical to fixture end-to-end.
    func testUpdateBatchAggregatedManifestDispatchesToDetachedTaskRatherThanRunningSynchronously() throws {
        let source = try String(
            contentsOf: packageRoot()
                .appendingPathComponent("Sources/LungfishEsVirituUI/EsVirituResultViewController.swift"),
            encoding: .utf8
        )

        let methodRange = try XCTUnwrap(
            source.range(of: "private func updateEsVirituBatchAggregatedManifestUniqueReads() -> Task<Void, Never>? {")
        )
        let nextMethodRange = source.range(
            of: "nonisolated static func applyingUniqueReads",
            range: methodRange.upperBound..<source.endIndex
        )
        let methodBody = String(source[methodRange.upperBound..<(nextMethodRange?.lowerBound ?? source.endIndex)])

        XCTAssertTrue(
            methodBody.contains("Task.detached"),
            "updateEsVirituBatchAggregatedManifestUniqueReads must dispatch its file I/O to a detached background task, not run synchronously on the main actor"
        )
        XCTAssertFalse(
            methodBody.contains("MetagenomicsBatchResultStore.loadEsVirituBatchAggregatedManifest"),
            "the load/mutate/save calls must live in the off-main helper, not inline in the main-actor method"
        )
        // R3ML round-3 review fix: the detached task must route through the
        // per-batchURL serializer, not call writeUpdatedBatchAggregatedManifestUniqueReads
        // directly -- otherwise two concurrent per-sample completions can
        // interleave their load-modify-save and lose an update.
        XCTAssertTrue(
            methodBody.contains("EsVirituBatchManifestMutationSerializer.shared.run"),
            "the write must be serialized per batchURL via EsVirituBatchManifestMutationSerializer"
        )
    }

    /// R3ML round-3 review fix: two per-sample completions racing to update the
    /// same batch aggregated manifest must not lose either update. Before this
    /// fix, `updateEsVirituBatchAggregatedManifestUniqueReads` spawned an
    /// unserialized `Task.detached` per call; two calls for different samples
    /// firing back-to-back could each load the manifest before either had
    /// saved, so the second save would silently discard the first save's
    /// unique-read update (last-write-wins lost update). Routing both calls
    /// through `EsVirituBatchManifestMutationSerializer` (mirroring
    /// `BundleManifestMutationSerializer`) must make both updates land.
    @MainActor func testConcurrentBatchAggregatedManifestWritesDoNotLoseEitherSamplesUpdate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("esviritu-batch-manifest-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let initialManifest = EsVirituBatchAggregatedManifest(
            createdAt: Date(timeIntervalSince1970: 0),
            sampleCount: 2,
            sampleIds: ["sample-A", "sample-B"],
            cachedRows: [
                Self.cachedRow(sample: "sample-A", assembly: "GCF_A", uniqueReads: 0),
                Self.cachedRow(sample: "sample-B", assembly: "GCF_B", uniqueReads: 0),
            ]
        )
        try MetagenomicsBatchResultStore.saveEsVirituBatchAggregatedManifest(initialManifest, to: root)

        let vc = EsVirituResultViewController()
        _ = vc.view
        vc.batchURL = root

        // Writer 1: only sample-A's row is present, so its write must only
        // touch sample-A's uniqueReads (matching applyingUniqueReads's
        // "only matching rows change" contract).
        vc.allBatchRows = [
            BatchEsVirituRow(
                sample: "sample-A", virusName: "Test virus", family: "Testviridae",
                assembly: "GCF_A", readCount: 100, uniqueReads: 17,
                rpkmf: 1.0, coverageBreadth: 0.5, coverageDepth: 2.0
            ),
        ]
        let task1 = vc.testTriggerBatchAggregatedManifestWrite()

        // Writer 2: only sample-B's row is present. Fired immediately after
        // writer 1, before either has necessarily finished its load/save --
        // this is the exact interleaving that used to lose an update.
        vc.allBatchRows = [
            BatchEsVirituRow(
                sample: "sample-B", virusName: "Test virus", family: "Testviridae",
                assembly: "GCF_B", readCount: 100, uniqueReads: 42,
                rpkmf: 1.0, coverageBreadth: 0.5, coverageDepth: 2.0
            ),
        ]
        let task2 = vc.testTriggerBatchAggregatedManifestWrite()

        await task1?.value
        await task2?.value

        let finalManifest = try XCTUnwrap(
            MetagenomicsBatchResultStore.loadEsVirituBatchAggregatedManifest(from: root)
        )
        XCTAssertEqual(
            finalManifest.cachedRows.first { $0.sample == "sample-A" }?.uniqueReads, 17,
            "writer 1's update must survive writer 2's concurrent write"
        )
        XCTAssertEqual(
            finalManifest.cachedRows.first { $0.sample == "sample-B" }?.uniqueReads, 42,
            "writer 2's update must survive writer 1's concurrent write"
        )
    }

    private static func cachedRow(
        sample: String,
        assembly: String,
        uniqueReads: Int
    ) -> EsVirituBatchAggregatedManifest.CachedRow {
        EsVirituBatchAggregatedManifest.CachedRow(
            sample: sample,
            virusName: "Test virus",
            family: "Testviridae",
            assembly: assembly,
            readCount: 100,
            uniqueReads: uniqueReads,
            rpkmf: 1.0,
            coverageBreadth: 0.5,
            coverageDepth: 2.0
        )
    }

    private func packageRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        fatalError("Could not locate package root from #filePath")
    }

    private static func esvirituResult(_ assemblies: [ViralAssembly]) -> LungfishIO.EsVirituResult {
        LungfishIO.EsVirituResult(
            sampleId: "esviritu-ui",
            detections: assemblies.flatMap(\.contigs),
            assemblies: assemblies,
            taxProfile: [],
            coverageWindows: [],
            totalFilteredReads: 1_000,
            detectedFamilyCount: 1,
            detectedSpeciesCount: 1,
            runtime: nil,
            toolVersion: nil
        )
    }

    private static func retainedMetricConstraintCount(
        in pane: EsVirituDetailPane
    ) -> Int {
        return (Mirror(reflecting: pane).children.first {
            $0.label == "activeMetricWidthConstraints"
        }?.value as? [NSLayoutConstraint] ?? []).count
    }

    @MainActor private static func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        if let match = root as? View {
            return match
        }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private static func viralAssembly(
        name: String,
        sampleId: String,
        assembly: String,
        accession: String,
        reads: Int,
        segment: String? = nil
    ) -> ViralAssembly {
        let detection = ViralDetection(
            sampleId: sampleId,
            name: name,
            description: name,
            length: 100,
            segment: segment,
            accession: accession,
            assembly: assembly,
            assemblyLength: 100,
            kingdom: "Viruses",
            phylum: nil,
            tclass: nil,
            order: nil,
            family: "Testviridae",
            genus: nil,
            species: name,
            subspecies: nil,
            rpkmf: Double(reads),
            readCount: reads,
            coveredBases: 100,
            meanCoverage: 1,
            avgReadIdentity: 99,
            pi: 0,
            filteredReadsInSample: 1_000
        )
        return ViralAssembly(
            assembly: assembly,
            assemblyLength: 100,
            name: name,
            family: "Testviridae",
            genus: nil,
            species: name,
            totalReads: reads,
            rpkmf: Double(reads),
            meanCoverage: 1,
            avgReadIdentity: 99,
            contigs: [detection]
        )
    }
}
