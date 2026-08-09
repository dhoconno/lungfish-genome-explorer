import XCTest
import AppKit
@testable import LungfishNvdUI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishCore
import LungfishKit

@MainActor
final class NvdResultViewControllerTests: XCTestCase {
    func testSelectionSurvivesCachedReloadWithDuplicateContigAcrossSamples() {
        let vc = NvdResultViewController()
        _ = vc.view

        let bundleURL = URL(fileURLWithPath: "/project/Analyses/nvd-run-a", isDirectory: true)
        let manifest = NvdManifest(
            experiment: "exp-duplicate-contigs",
            sampleCount: 2,
            contigCount: 2,
            hitCount: 2,
            blastDbVersion: "db",
            snakemakeRunId: "run-a",
            sourceDirectoryPath: "/project",
            samples: [],
            cachedTopContigs: nil
        )

        vc.configureWithCachedRows(
            [
                Self.contigRow(sampleId: "sample-A", qseqid: "NODE_1"),
                Self.contigRow(sampleId: "sample-B", qseqid: "NODE_1"),
            ],
            manifest: manifest,
            bundleURL: bundleURL
        )

        vc.testSelectOutlineRow(1)
        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample-B"])

        vc.configureWithCachedRows(
            [
                Self.contigRow(sampleId: "sample-B", qseqid: "NODE_1"),
                Self.contigRow(sampleId: "sample-A", qseqid: "NODE_1"),
            ],
            manifest: manifest,
            bundleURL: bundleURL
        )

        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample-B"])
        XCTAssertEqual(vc.testOutlineSelectedRowIndexes(), IndexSet(integer: 0))
    }

    func testExtractButtonDisabledWhenOnlyCachedRowsAreLoaded() {
        // Regression test for AS11: the action bar's Extract Reads button
        // unconditionally enabled itself on row selection regardless of
        // `database == nil`, unlike the row-level context menu item which
        // correctly disables in this state. During the cached-rows-only
        // load window (before configure(database:) completes), clicking
        // Extract produced no dialog and no error.
        let vc = NvdResultViewController()
        _ = vc.view

        let bundleURL = URL(fileURLWithPath: "/project/Analyses/nvd-run-a", isDirectory: true)
        let manifest = NvdManifest(
            experiment: "exp-cached-only",
            sampleCount: 1,
            contigCount: 1,
            hitCount: 1,
            blastDbVersion: "db",
            snakemakeRunId: "run-a",
            sourceDirectoryPath: "/project",
            samples: [],
            cachedTopContigs: nil
        )
        vc.configureWithCachedRows(
            [Self.contigRow(sampleId: "sample-A", qseqid: "NODE_1")],
            manifest: manifest,
            bundleURL: bundleURL
        )

        vc.testSelectOutlineRow(0)

        XCTAssertFalse(vc.testActionBar.extractButton.isEnabled)
    }

    func testContextMenuValidationUsesIdentityBackedVisibleSelectionCount() throws {
        let fixture = try NvdMenuFixture(duplicateContigs: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        vc.onBlastVerification = { _, _ in }
        _ = vc.view
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)

        vc.testSelectOutlineRow(1)
        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample2"])

        vc.testSelectOutlineRowsWithoutIdentitySync(IndexSet([0, 1]))
        let state = vc.testContextMenuActionStateForContig(at: 1)

        XCTAssertEqual(state.identitySelectionCount, 1)
        XCTAssertEqual(state.menuSelectionCount, 1)
        XCTAssertTrue(state.blastEnabled)
    }

    func testContextMenuBlastDisabledWhenClickedContigDiffersFromIdentitySelection() throws {
        let fixture = try NvdMenuFixture(duplicateContigs: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        vc.onBlastVerification = { _, _ in }
        _ = vc.view
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)

        vc.testSelectOutlineRow(1)
        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample2"])

        let state = vc.testContextMenuActionStateForFirstContig()

        XCTAssertEqual(state.identitySelectionCount, 1)
        XCTAssertFalse(state.blastEnabled)
    }

    func testContextMenuExtractSequenceTargetsClickedContigWhenSelectionDiffers() throws {
        let fixture = try NvdMenuFixture(duplicateContigs: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        var extractedRecords: [String] = []
        vc.onExtractSequenceRequested = { records, _ in
            extractedRecords = records
        }
        _ = vc.view
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)

        vc.testSelectOutlineRow(1)
        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample2"])

        XCTAssertTrue(vc.testInvokeContextMenuItem(title: "Extract Sequence\u{2026}", forContigAt: 0))

        XCTAssertEqual(extractedRecords.count, 1)
        XCTAssertTrue(extractedRecords[0].contains("AACCGGTT"))
        XCTAssertFalse(extractedRecords[0].contains("TTGGCCAA"))
    }

    func testContextMenuExposesSharedFastaActionsWhenCallbacksPresent() throws {
        let fixture = try NvdMenuFixture()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        vc.onBlastVerification = { _, _ in }
        vc.onExportFASTARequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onRunOperationRequested = { _ in }
        _ = vc.view

        vc.configure(
            database: fixture.database,
            manifest: fixture.manifest,
            bundleURL: fixture.bundleURL
        )

        XCTAssertEqual(
            vc.testContextMenuTitlesForFirstContig().filter { !$0.isEmpty },
            [
                "Extract Reads…",
                "Extract Sequence…",
                "Verify with BLAST…",
                "Copy FASTA",
                "Export FASTA…",
                "Create Bundle…",
                "Run Operation…",
                "Copy Contig Name",
                "Copy Accession",
                "View Accession on NCBI",
                "Search PubMed",
            ]
        )
    }

    func testRerunBlastButtonReRunsBlastForSelectedContig() throws {
        let fixture = try NvdMenuFixture()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        _ = vc.view
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)
        vc.testSelectOutlineRow(0)

        var blastRequestCount = 0
        vc.onBlastVerification = { _, _ in
            blastRequestCount += 1
        }

        vc.showBlastResults(BlastVerificationResult(
            taxonName: "contig_1",
            taxId: 0,
            readResults: [],
            submittedAt: Date(),
            completedAt: Date(),
            rid: "RID-1",
            blastProgram: "megablast",
            database: "core_nt"
        ))

        let drawer = try XCTUnwrap(vc.testBlastDrawerContainer)
        drawer.blastResultsTab.rerunBlastButton.performClick(nil)

        XCTAssertEqual(blastRequestCount, 1)
    }

    func testContigTSVExportWritesScientificProvenanceSidecar() throws {
        let fixture = try NvdMenuFixture()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        _ = vc.view
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let outputURL = outputDirectory.appendingPathComponent("nvd-contigs.tsv")
        try vc.writeContigsTSV(to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app nvd contigs export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 1)
        XCTAssertEqual(
            envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample1"]
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["searchQuery"]?.stringValue, "")
        XCTAssertEqual(envelope.options.resolvedDefaults["groupingMode"]?.stringValue, "bySample")
        XCTAssertTrue(envelope.files.contains { $0.path == fixture.database.databaseURL.path && $0.checksumSHA256 != nil })
        let sourceDirectory = try XCTUnwrap(envelope.files.first { $0.path == fixture.rootURL.path && $0.role == .input })
        XCTAssertNotNil(sourceDirectory.checksumSHA256)
        XCTAssertNotNil(sourceDirectory.fileSize)
    }

    func testOutlineTypographyScalesReusedRolesAndLateMetadataWithoutReloading() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)

        let fixture = try NvdMenuFixture(includeSecondaryHit: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let provider = MutableNvdPreferredFonts(bodyPointSize: 13)
        let vc = NvdResultViewController()
        vc.testingSetContentPreferredFontProvider(provider)
        vc.view.frame = NSRect(x: 0, y: 0, width: 820, height: 420)
        let window = NSWindow(
            contentRect: vc.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        let table = vc.testOutlineView
        vc.testExpandFirstContig()
        vc.view.layoutSubtreeIfNeeded()

        let contig = try Self.outlineField(table, identifier: "contig", row: 0)
        let child = try Self.outlineField(table, identifier: "contig", row: 2)
        let baselineContig = try XCTUnwrap(contig.font).pointSize
        let baselineChild = try XCTUnwrap(child.font).pointSize
        XCTAssertEqual(baselineContig, 11)
        XCTAssertEqual(baselineChild, 10)
        XCTAssertEqual(child.alphaValue, 0.7)
        XCTAssertEqual(contig.toolTip, contig.stringValue)
        XCTAssertEqual(child.accessibilityValue(), child.stringValue)

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(contig.font?.pointSize, baselineContig * 2)
        XCTAssertEqual(child.font?.pointSize, baselineChild * 2)

        vc.testSetGroupingMode(.byTaxon)
        vc.testExpandFirstTaxon()
        var taxon = try Self.outlineField(table, identifier: "contig", row: 0)
        var rank = try Self.outlineField(table, identifier: "rank", row: 0)
        XCTAssertEqual(taxon.font?.pointSize, 22)
        XCTAssertTrue(try XCTUnwrap(taxon.font).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(rank.font?.pointSize, 22)

        let store = try SampleMetadataStore(
            csvData: Data("sample_id,collection_site\nsample1,Very long collection site\n".utf8),
            knownSampleIds: ["sample1"]
        )
        vc.testShowMetadataColumn("collection_site", store: store)
        vc.view.layoutSubtreeIfNeeded()
        var metadata = try Self.outlineField(
            table,
            identifier: "metadata_collection_site",
            row: 1
        )
        let enlargedMetadata = try XCTUnwrap(metadata.font).pointSize
        let enlargedSearch = try XCTUnwrap(vc.testSearchField.font).pointSize
        let baselineRows = vc.testOutlineReloadCount
        let baselineChildLoads = vc.testChildHitLoadCount
        let baselineExpanded = vc.testExpandedOutlineItemIdentities
        let baselineSelection = table.selectedRowIndexes
        let baselineWidths = table.tableColumns.map(\.width)
        let baselineColumnOrder = table.tableColumns.map(\.identifier)
        table.sortDescriptors = [NSSortDescriptor(key: "contig", ascending: false)]
        let baselineSort = table.sortDescriptors

        XCTAssertEqual(taxon.font?.pointSize, 22)
        XCTAssertEqual(metadata.font?.pointSize, enlargedMetadata)
        XCTAssertEqual(vc.testSearchField.font?.pointSize, enlargedSearch)
        XCTAssertGreaterThan(table.rowHeight, 22)
        XCTAssertGreaterThan(try XCTUnwrap(table.headerView).frame.height, 24)

        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(taxon.font?.pointSize, 22)
        XCTAssertEqual(vc.testOutlineReloadCount, baselineRows)
        XCTAssertEqual(vc.testChildHitLoadCount, baselineChildLoads)
        XCTAssertEqual(vc.testExpandedOutlineItemIdentities, baselineExpanded)
        XCTAssertEqual(table.selectedRowIndexes, baselineSelection)
        XCTAssertEqual(table.sortDescriptors, baselineSort)
        XCTAssertEqual(table.tableColumns.map(\.width), baselineWidths)
        XCTAssertEqual(table.tableColumns.map(\.identifier), baselineColumnOrder)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        taxon = try Self.outlineField(table, identifier: "contig", row: 0)
        rank = try Self.outlineField(table, identifier: "rank", row: 0)
        metadata = try Self.outlineField(
            table,
            identifier: "metadata_collection_site",
            row: 1
        )
        XCTAssertEqual(taxon.font?.pointSize, 11)
        XCTAssertEqual(rank.font?.pointSize, 11)
        XCTAssertEqual(metadata.font?.pointSize, enlargedMetadata / 2)
        XCTAssertEqual(vc.testSearchField.font?.pointSize, enlargedSearch / 2)
        XCTAssertEqual(table.tableColumns.map(\.identifier), baselineColumnOrder)

        settings.contentTextSizePreference = .system
        provider.bodyPointSize = 26
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        taxon = try Self.outlineField(table, identifier: "contig", row: 0)
        rank = try Self.outlineField(table, identifier: "rank", row: 0)
        metadata = try Self.outlineField(
            table,
            identifier: "metadata_collection_site",
            row: 1
        )
        XCTAssertEqual(taxon.font?.pointSize, 22)
        XCTAssertEqual(rank.font?.pointSize, 22)
        XCTAssertEqual(metadata.font?.pointSize, enlargedMetadata)
        provider.bodyPointSize = 13
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        taxon = try Self.outlineField(table, identifier: "contig", row: 0)
        rank = try Self.outlineField(table, identifier: "rank", row: 0)
        XCTAssertEqual(taxon.font?.pointSize, 11)
        XCTAssertEqual(rank.font?.pointSize, 11)
    }

    func testDetailTypographyReflowsAtNarrowWidthWithoutRebuildingMiniBAM() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let fixture = try NvdMenuFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let provider = MutableNvdPreferredFonts(bodyPointSize: 13)
        let vc = NvdResultViewController()
        vc.testingSetContentPreferredFontProvider(provider)
        vc.testDisableMiniBAMLoading = true
        vc.view.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        let window = NSWindow(
            contentRect: vc.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)
        vc.testSetDetailPaneWidth(240)
        vc.testSelectOutlineRow(0)
        vc.view.layoutSubtreeIfNeeded()

        let baseline = vc.testDetailPrimaryPointSizes
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "contig_1"), 14)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Sample: sample1"), 10)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Identity"), 10)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "100.0%"), 12)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Contig Alignment"), 11)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Best hit:"), 10)
        XCTAssertEqual(vc.testLoadingPointSize, 12)
        let detailIdentity = ObjectIdentifier(vc.testDetailContentView)
        let miniIdentity = vc.testMiniBAMControllerIdentity
        let miniHeight = vc.testMiniBAMViewHeight
        let rebuilds = vc.testDetailRebuildCount
        let loads = vc.testMiniBAMLoadCount
        vc.testDetailScrollView.contentView.scroll(to: NSPoint(x: 0, y: 18))
        let origin = vc.testDetailScrollView.contentView.bounds.origin

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(zip(vc.testDetailPrimaryPointSizes, baseline).allSatisfy { $0 > $1 })
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "contig_1"), 28)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Sample: sample1"), 20)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Identity"), 18)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "100.0%"), 24)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Contig Alignment"), 22)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "Best hit:"), 20)
        XCTAssertEqual(vc.testLoadingPointSize, 24)
        XCTAssertTrue(vc.testDetailPrimaryFieldsAreContained)
        XCTAssertEqual(vc.testMetricStackOrientation, .vertical)
        XCTAssertEqual(ObjectIdentifier(vc.testDetailContentView), detailIdentity)
        XCTAssertEqual(vc.testMiniBAMControllerIdentity, miniIdentity)
        XCTAssertEqual(vc.testMiniBAMViewHeight, miniHeight)
        XCTAssertEqual(vc.testDetailRebuildCount, rebuilds)
        XCTAssertEqual(vc.testMiniBAMLoadCount, loads)
        XCTAssertEqual(vc.testDetailScrollView.contentView.bounds.origin, origin)
        XCTAssertTrue(vc.testDetailFullTextAccessibility)

        settings.contentTextSizePreference = .custom(100)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "contig_1"), 14)
        settings.contentTextSizePreference = .system
        provider.bodyPointSize = 26
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "contig_1"), 28)
        provider.bodyPointSize = 13
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(vc.testDetailPrimaryPointSize(containing: "contig_1"), 14)
        XCTAssertEqual(vc.testDetailRebuildCount, rebuilds)
        XCTAssertEqual(vc.testMiniBAMLoadCount, loads)

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        vc.testingShowMultiSelectionPlaceholder(count: 3)
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(vc.testPlaceholderFieldsAreContained)
        XCTAssertTrue(vc.testPlaceholderPointSizes.allSatisfy { $0 >= 20 })
    }

    func testLargeOutlineTypographyIsBoundedAndPreservesEditorScrollAndColumns() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let vc = NvdResultViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 820, height: 420)
        let window = NSWindow(
            contentRect: vc.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let rows = (0..<120).map {
            Self.contigRow(sampleId: "sample-A", qseqid: "NODE_\($0)")
        }
        vc.configureWithCachedRows(
            rows,
            manifest: NvdManifest(
                experiment: "exp-large",
                sampleCount: 1,
                contigCount: rows.count,
                hitCount: rows.count,
                blastDbVersion: "db",
                snakemakeRunId: "run",
                sourceDirectoryPath: "/tmp",
                samples: [],
                cachedTopContigs: nil
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/nvd-large", isDirectory: true)
        )
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        vc.view.layoutSubtreeIfNeeded()

        let table = vc.testOutlineView
        table.selectRowIndexes(IndexSet(integer: 30), byExtendingSelection: false)
        XCTAssertTrue(window.makeFirstResponder(vc.testSearchField))
        let editor = try XCTUnwrap(vc.testSearchField.currentEditor() as? NSTextView)
        editor.string = "unfinished analyst search"
        editor.setSelectedRange(NSRange(location: 11, length: 7))
        let editorIdentity = ObjectIdentifier(editor)
        let editorText = editor.string
        let editorSelection = editor.selectedRange()

        table.moveColumn(0, toColumn: 3)
        let columnOrder = table.tableColumns.map(\.identifier)
        let columnWidths = table.tableColumns.map(\.width)
        let sort = [NSSortDescriptor(key: "contig", ascending: false)]
        table.sortDescriptors = sort
        table.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        let requestedOrigin = NSPoint(x: 37, y: table.rect(ofRow: 30).minY + 3)
        scrollView.contentView.scroll(to: requestedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        _ = try Self.outlineField(table, identifier: "contig", row: 30)
        _ = try Self.outlineField(table, identifier: "rank", row: 30)
        let exactOrigin = scrollView.contentView.bounds.origin
        let reloads = vc.testOutlineReloadCount
        let childLoads = vc.testChildHitLoadCount
        let selection = table.selectedRowIndexes
        let realizedCellCapacity = table.rows(in: table.visibleRect).length
            * table.tableColumns.filter { !$0.isHidden }.count
        vc.testResetTypographyDisplayedContigScanCount()

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(scrollView.contentView.bounds.origin, exactOrigin)
        XCTAssertEqual(window.firstResponder.map(ObjectIdentifier.init), ObjectIdentifier(editor))
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(vc.testSearchField.currentEditor() as? NSTextView)), editorIdentity)
        XCTAssertEqual(editor.string, editorText)
        XCTAssertEqual(editor.selectedRange(), editorSelection)
        XCTAssertEqual(table.selectedRowIndexes, selection)
        XCTAssertEqual(table.tableColumns.map(\.identifier), columnOrder)
        XCTAssertEqual(table.tableColumns.map(\.width), columnWidths)
        XCTAssertEqual(table.sortDescriptors, sort)
        XCTAssertEqual(vc.testOutlineReloadCount, reloads)
        XCTAssertEqual(vc.testChildHitLoadCount, childLoads)
        XCTAssertEqual(vc.testTypographyDisplayedContigScanCount, 0)
        XCTAssertLessThanOrEqual(
            vc.testTypographyRealizedCellResolutionCount,
            realizedCellCapacity
        )
    }

    func testByTaxonTypographyIsBoundedAndPreservesOutlineState() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let fixture = try NvdMenuFixture(taxonCount: 80)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        let vc = NvdResultViewController()
        vc.testDisableMiniBAMLoading = true
        vc.view.frame = NSRect(x: 0, y: 0, width: 820, height: 420)
        let window = NSWindow(
            contentRect: vc.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        vc.configure(
            database: fixture.database,
            manifest: fixture.manifest,
            bundleURL: fixture.bundleURL
        )
        vc.testSetGroupingMode(.byTaxon)
        vc.testExpandFirstTaxon()
        vc.view.layoutSubtreeIfNeeded()

        let table = vc.testOutlineView
        let targetRow = min(40, table.numberOfRows - 1)
        table.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        table.sortDescriptors = [NSSortDescriptor(key: "mappedReads", ascending: false)]
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        scrollView.contentView.scroll(
            to: NSPoint(x: 29, y: table.rect(ofRow: targetRow).minY + 2)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        _ = try Self.outlineField(table, identifier: "mappedReads", row: targetRow)
        _ = try Self.outlineField(table, identifier: "rank", row: targetRow)
        let origin = scrollView.contentView.bounds.origin
        let selection = table.selectedRowIndexes
        let sort = table.sortDescriptors
        let columnOrder = table.tableColumns.map(\.identifier)
        let columnWidths = table.tableColumns.map(\.width)
        let expanded = vc.testExpandedOutlineItemIdentities
        let reloads = vc.testOutlineReloadCount
        let childLoads = vc.testChildHitLoadCount
        let realizedCellCapacity = table.rows(in: table.visibleRect).length
            * table.tableColumns.filter { !$0.isHidden }.count
        vc.testResetTypographyDisplayedContigScanCount()

        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(vc.testTypographyTaxonGroupScanCount, 0)
        XCTAssertLessThanOrEqual(
            vc.testTypographyRealizedCellResolutionCount,
            realizedCellCapacity
        )
        XCTAssertEqual(scrollView.contentView.bounds.origin, origin)
        XCTAssertEqual(table.selectedRowIndexes, selection)
        XCTAssertEqual(table.sortDescriptors, sort)
        XCTAssertEqual(table.tableColumns.map(\.identifier), columnOrder)
        XCTAssertEqual(table.tableColumns.map(\.width), columnWidths)
        XCTAssertEqual(vc.testExpandedOutlineItemIdentities, expanded)
        XCTAssertEqual(vc.testOutlineReloadCount, reloads)
        XCTAssertEqual(vc.testChildHitLoadCount, childLoads)
    }

    func testTypographyObservationDoesNotRetainController() {
        weak var weakController: NvdResultViewController?
        autoreleasepool {
            let controller = NvdResultViewController()
            _ = controller.view
            weakController = controller
        }
        XCTAssertNil(weakController)
    }

    func testNoBAMDetailMessageUsesLiveContentTypography() {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
            NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        }
        settings.contentTextSizePreference = .custom(100)
        let vc = NvdResultViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        let window = NSWindow(
            contentRect: vc.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = vc.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        vc.configureWithCachedRows(
            [Self.contigRow(sampleId: "sample-A", qseqid: "NODE_1")],
            manifest: NvdManifest(
                experiment: "exp-no-bam",
                sampleCount: 1,
                contigCount: 1,
                hitCount: 1,
                blastDbVersion: "db",
                snakemakeRunId: "run",
                sourceDirectoryPath: "/tmp",
                samples: [],
                cachedTopContigs: nil
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/nvd-no-bam", isDirectory: true)
        )
        vc.testSelectOutlineRow(0)
        vc.testSetDetailPaneWidth(240)
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            vc.testDetailPrimaryPointSize(containing: "No BAM data available"),
            11
        )
        let rebuilds = vc.testDetailRebuildCount
        settings.contentTextSizePreference = .custom(200)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        vc.testSetDetailPaneWidth(240)
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            vc.testDetailPrimaryPointSize(containing: "No BAM data available"),
            22
        )
        XCTAssertEqual(vc.testDetailRebuildCount, rebuilds)
        XCTAssertTrue(vc.testDetailPrimaryFieldsAreContained)
        XCTAssertTrue(vc.testDetailFullTextAccessibility)
    }

    private static func contigRow(sampleId: String, qseqid: String) -> NvdContigRow {
        NvdContigRow(
            sampleId: sampleId,
            qseqid: qseqid,
            qlen: 100,
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            sseqid: "NC_000001.1",
            stitle: "Reference title",
            pident: 99.5,
            evalue: 1e-20,
            bitscore: 120,
            mappedReads: 10,
            readsPerBillion: 10_000
        )
    }

    private static func outlineField(
        _ table: NSOutlineView,
        identifier: String,
        row: Int
    ) throws -> NSTextField {
        let column = table.column(
            withIdentifier: NSUserInterfaceItemIdentifier(identifier)
        )
        guard column >= 0 else {
            XCTFail("Missing outline column \(identifier)")
            throw NSError(domain: "NvdTests", code: 1)
        }
        return try XCTUnwrap(
            (table.view(atColumn: column, row: row, makeIfNecessary: true)
                as? NSTableCellView)?.textField
        )
    }
}

private struct NvdMenuFixture {
    let rootURL: URL
    let bundleURL: URL
    let manifest: NvdManifest
    let database: NvdDatabase

    init(
        duplicateContigs: Bool = false,
        includeSecondaryHit: Bool = false,
        taxonCount: Int = 1
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-menu-tests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("fixture.nvd", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastaRelativePath = "sample1.fasta"
        let fastaURL = bundleURL.appendingPathComponent(fastaRelativePath)
        try """
        >contig_1
        AACCGGTT
        """.write(to: fastaURL, atomically: true, encoding: .utf8)
        let secondFastaRelativePath = "sample2.fasta"
        let secondFastaURL = bundleURL.appendingPathComponent(secondFastaRelativePath)
        try """
        >contig_1
        TTGGCCAA
        """.write(to: secondFastaURL, atomically: true, encoding: .utf8)

        let hit = NvdBlastHit(
            experiment: "exp-1",
            blastTask: "blastn",
            sampleId: "sample1",
            qseqid: "contig_1",
            qlen: 8,
            sseqid: "NC_000001.1",
            stitle: "Reference title",
            taxRank: "species",
            length: 8,
            pident: 100,
            evalue: 0,
            bitscore: 50,
            sscinames: "Example virus",
            staxids: "1234",
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            mappedReads: 10,
            totalReads: 1000,
            statDbVersion: "stats-1",
            adjustedTaxid: "1234",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 10_000_000
        )
        let duplicateHit = NvdBlastHit(
            experiment: "exp-1",
            blastTask: "blastn",
            sampleId: "sample2",
            qseqid: "contig_1",
            qlen: 8,
            sseqid: "NC_000002.1",
            stitle: "Reference title 2",
            taxRank: "species",
            length: 8,
            pident: 99,
            evalue: 0,
            bitscore: 45,
            sscinames: "Example virus",
            staxids: "1234",
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            mappedReads: 12,
            totalReads: 1000,
            statDbVersion: "stats-1",
            adjustedTaxid: "1234",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 12_000_000
        )
        let secondaryHit = NvdBlastHit(
            experiment: "exp-1",
            blastTask: "blastn",
            sampleId: "sample1",
            qseqid: "contig_1",
            qlen: 8,
            sseqid: "NC_000003.1",
            stitle: "Secondary reference title",
            taxRank: "species",
            length: 7,
            pident: 97,
            evalue: 1e-10,
            bitscore: 40,
            sscinames: "Example virus",
            staxids: "1234",
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            mappedReads: 8,
            totalReads: 1000,
            statDbVersion: "stats-1",
            adjustedTaxid: "1234",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            hitRank: 2,
            readsPerBillion: 8_000_000
        )
        let additionalTaxonHits = (1..<taxonCount).map { index in
            NvdBlastHit(
                experiment: "exp-1",
                blastTask: "blastn",
                sampleId: "sample1",
                qseqid: "taxon_contig_\(index)",
                qlen: 100,
                sseqid: "NC_TAXON_\(index)",
                stitle: "Taxon reference \(index)",
                taxRank: "species",
                length: 90,
                pident: 98,
                evalue: 1e-8,
                bitscore: 40,
                sscinames: "Taxon \(index)",
                staxids: "\(2000 + index)",
                blastDbVersion: "db",
                snakemakeRunId: "run-1",
                mappedReads: 1_000 - index,
                totalReads: 1000,
                statDbVersion: "stats-1",
                adjustedTaxid: "\(2000 + index)",
                adjustmentMethod: "dominant",
                adjustedTaxidName: String(format: "Taxon %03d", index),
                adjustedTaxidRank: "species",
                hitRank: 1,
                readsPerBillion: Double(1_000 - index) * 1_000_000
            )
        }

        let databaseURL = bundleURL.appendingPathComponent("nvd.sqlite")
        database = try NvdDatabase.create(
            at: databaseURL,
            hits: [hit]
                + (duplicateContigs ? [duplicateHit] : [])
                + (includeSecondaryHit ? [secondaryHit] : [])
                + additionalTaxonHits,
            samples: [
                NvdSampleMetadata(
                    sampleId: "sample1",
                    bamPath: "sample1.bam",
                    fastaPath: fastaRelativePath,
                    totalReads: 1000,
                    contigCount: 1,
                    hitCount: 1
                ),
            ] + (duplicateContigs ? [
                NvdSampleMetadata(
                    sampleId: "sample2",
                    bamPath: "sample2.bam",
                    fastaPath: secondFastaRelativePath,
                    totalReads: 1000,
                    contigCount: 1,
                    hitCount: 1
                ),
            ] : [])
        )

        manifest = NvdManifest(
            experiment: "exp-1",
            sampleCount: duplicateContigs ? 2 : 1,
            contigCount: taxonCount + (duplicateContigs ? 1 : 0),
            hitCount: taxonCount + (duplicateContigs ? 1 : 0),
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            sourceDirectoryPath: rootURL.path,
            samples: [
                NvdSampleSummary(
                    sampleId: "sample1",
                    contigCount: 1,
                    hitCount: 1,
                    totalReads: 1000,
                    bamRelativePath: "sample1.bam",
                    fastaRelativePath: fastaRelativePath
                ),
            ] + (duplicateContigs ? [
                NvdSampleSummary(
                    sampleId: "sample2",
                    contigCount: 1,
                    hitCount: 1,
                    totalReads: 1000,
                    bamRelativePath: "sample2.bam",
                    fastaRelativePath: secondFastaRelativePath
                ),
            ] : []),
            cachedTopContigs: nil
        )
    }
}

@MainActor
private final class MutableNvdPreferredFonts: ContentPreferredFontProviding {
    var bodyPointSize: CGFloat

    init(bodyPointSize: CGFloat) {
        self.bodyPointSize = bodyPointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .caption:
            return .systemFont(ofSize: bodyPointSize * 10 / 13)
        case .monospaced:
            return .monospacedSystemFont(ofSize: bodyPointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: bodyPointSize, weight: .semibold)
        case .body, .detail:
            return .systemFont(ofSize: bodyPointSize)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        role == .caption ? 10 : 13
    }
}
