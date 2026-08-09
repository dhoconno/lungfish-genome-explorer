# Action-Surface Sweep Findings — 2026-08-08

14-finder workflow over every user-triggerable action. 104 actions traced; 35 verified OK; 36 confirmed defects; 4 stubs; 8 claims refuted in verification.

Trigger: user-reported GenBank bundle merge failure (root cause: docs/../.superpowers ref — see genbank-merge-investigation; fix task GB1). Defect family AS-F1 below generalizes that bug.

### AS1 [silent-noop/high] File > Export > Sequences (FASTA/GenBank)… — Export Sequences (FASTA/GenBank)
- Wiring: `Sources/LungfishApp/App/MainMenu.swift:227-231`
- Handler: `Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2216-2228 (exportFASTA -> exportSequences)`
- exportSequences filters the sidebar multi-selection to items where `$0.type == .referenceBundle || $0.type == .sequence` (line 2228) before exporting. If the user multi-selects a mix of sidebar item types (e.g. a reference bundle plus a FASTQ bundle, assembly, MSA/tree bundle, or classifier result), the non-matching items are silently dropped from `sidebarItems` with no warning that anything was excluded — the export proceeds and reports success ('Exported N sequence(s)...') covering only the subset, misleading the user about what was actually exported. This is the same defect class as the reported GenBank-merge bug: label promises 'export selected items' but the handler silently narrows the selection. No enablement/validateMenuItem guard exists for this action (checked AppDelegate.swift:1719 validateMenuItem — no branch for exportFASTA), so the menu item is always clickable regardless of selection.
- Reachable: User selects 2+ sidebar items of mixed type (only some being .referenceBundle/.sequence) and chooses File > Export > Sequences

### AS2 [silent-noop/high] Sequence menu > Extract Visible Region… — Extract Visible Region…
- Wiring: `Sources/LungfishApp/App/MainMenu.swift:672-677 (action #selector(SequenceMenuActions.extractSelection(_:))); enablement Sources/LungfishApp/App/AppDelegate.swift:1813-1820`
- Handler: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift:249-254`
- validateMenuItem for extractSelection only checks `viewerView != nil` (AppDelegate.swift:1814-1819), NOT `referenceFrame != nil`. The handler's own currentVisibleViewportRegion() (Extraction.swift:257-262) requires `viewController?.referenceFrame != nil` and on failure does `guard ... else { return }` with zero feedback — no NSSound.beep(), no alert. Contrast with the sibling action copySelectionAsFASTA (same file, line 213-217) which beeps on the identical failure. Reachable whenever a sequence viewer is open but no reference frame is set (e.g. a bundle without an active chromosome selection, or between document swaps) — the menu item stays enabled and clicking it does visibly nothing.
- Reachable: (see detail)

### AS3 [silent-noop/high] Sidebar context menu — MHC reference bundle (.lungfishmhcref) — Right-click a single MHC reference bundle item
- Wiring: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:53-67,94-149,204-209 (hasBundles/hasFiles gates)`
- Handler: `n/a — no branch ever fires for .mhcReferenceBundle`
- hasBundles (line 67) only tests item.type == .referenceBundle, so it is false for .mhcReferenceBundle even though SidebarItemType.isBundle (SidebarItem.swift:112) explicitly classifies mhcReferenceBundle as a bundle with its own icon, viewer (ViewerViewController+MHCReferenceBundle.swift) and document section (DocumentSection.swift). Because mhcReferenceBundle.isBundle==true, it is ALSO excluded from hasFiles (line 57), so the generic 'Open' branch (items.count==1 && hasFiles, line 204) never fires either. Result: right-clicking one MHC reference bundle shows none of Open Bundle / Show Package Contents / Get Bundle Info / Import Sample Metadata / Merge into New Bundle / Show in Inspector / Export Sequences — only the generic fallback (Show in Finder, Copy Path, Rename, Duplicate, Move to, Move to Trash). This is the same 'label promises X but handler only supports a subset of selectable kinds' class as the reported GenBank-merge bug: BundleMergeSelection.detectKind (Services/BundleMergeSelection.swift:9-20) and exportSequences (App/AppDelegate+ImportCenter.swift:2228 `.filter { $0.type == .referenceBundle || $0.type == .sequence }`) both silently drop mhcReferenceBundle from selectable inputs for merge/export.
- Reachable: Always reachable — simply right-click any GenBank-derived/MHC amplicon reference bundle (.lungfishmhcref) in the sidebar; no special state needed.

### AS4 [silent-noop/high] Sidebar outline: drag-drop move/copy of multiple selected items onto a folder — Drag N selected sidebar items onto a folder (move, or Control/Option-drag to copy)
- Wiring: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:159 (acceptDrop) -> moveItems/copyItems:916,991`
- Handler: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:932-983 (moveItems(_:toFolderURL:at:)), 1007-1039 (copyItems)`
- Per-item failures inside the loop (missing URL at line 943-946/1018-1021, move-into-self/descendant at 951-955, FileManager error at 968-976) are only os_log'd and the loop continues; no NSAlert is ever shown for a partial failure. acceptDrop's boolean return (line 982/1038, movedCount==sourceItems.count) only controls AppKit's drag-snapback animation, not any user-visible message. Reachable whenever a user multi-drags a mix of movable and non-movable items (e.g. one has a stale/missing url, or a nested selection where one item is a descendant of another being moved) - remaining valid items still move/copy with zero indication that some were skipped. Same shape as the tracked GenBank-merge bug: label promises 'move/copy N items' but the handler silently supports only the movable subset.
- Reachable: (see detail)

### AS5 [silent-noop/high] Sidebar outline: multi-selecting mixed item types (context menu / shift/cmd-click) — Select several sidebar items of different types (e.g. a FASTQ bundle + a sequence file + a reference bundle) to view them together
- Wiring: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDelegate.swift:135-144 (outlineViewSelectionDidChange) -> Sources/LungfishApp/Views/MainWindow/MainSplitViewController+SidebarSelection.swift:201-237 (sidebarDidSelectItems)`
- Handler: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:18-27 (handleMultipleItemsSelected)`
- Line 20-22 filters the selection down to only `.sequence`, `.annotation`, `.alignment` items; every other selected type (FASTQ bundles, reference bundles, classification results, assembly results, etc.) is dropped from `displayableItems` with zero user feedback. If the surviving subset is non-empty, the viewer silently displays only that subset as a 'collection' with no indication the other selected items were excluded; if it's empty, only a debug log fires (line 25-26) and the viewport is left untouched (stale content), not even cleared to 'No sequence selected'. A user who multi-selects, say, 2 FASTQ bundles + 1 FASTA expecting a combined view gets only the FASTA shown with no explanation.
- Reachable: (see detail)

### AS6 [silent-noop/high] Variant Query Builder sheet — Click 'Edit Query...' / 'Query Builder...' toolbar button while an existing variant filter is active
- Wiring: `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Filtering.swift:2117-2118 (passes initialFilterText: variantFilterText into VariantQueryBuilderView)`
- Handler: `Sources/LungfishApp/Views/Viewer/VariantQueryBuilderSheet.swift:42-70 (init never parses/uses initialFilterText — only stores unused defaultRule)`
- The 'Edit Query...' button label (AnnotationTableDrawerView+Columns.swift:1870, 'Edit Sample Query...' has the identical bug via SampleQueryBuilderView) implies the sheet will show/restore the current filter. `initialFilterText` is accepted as a parameter but never read anywhere in VariantQueryBuilderSheet.swift after assignment (grep confirms only 1 occurrence, the parameter declaration itself). The sheet always opens with a single blank default QueryRule regardless of the existing filter text, silently discarding the user's current query state with no warning that their prior rules were lost.
- Reachable: (see detail)

### AS7 [silent-noop/high] BLAST results drawer — 'Re-run BLAST' button (Assembly contig-BLAST drawer) — Click 'Re-run BLAST' in the BLAST results drawer opened from the Assembly viewer
- Wiring: `Sources/LungfishAssemblyUI/AssemblyResultViewController.swift:558-602 (ensureBlastDrawer creates BlastResultsDrawerContainerView but never sets container.onRerunBlast anywhere in the file)`
- Handler: `Sources/LungfishKit/BlastResultsDrawerTab.swift:1570-1573: `onRerunBlast?()` — callback is nil in this consumer, so the call is a no-op`
- grep of AssemblyResultViewController.swift for onRerunBlast returns zero matches. rerunBlastButton is never set isEnabled=false or isHidden=true anywhere in BlastResultsDrawerTab.swift, so the button is always visibly active in the Assembly contig-BLAST drawer. Clicking it produces zero feedback: no log beyond 'Re-run BLAST requested' (info log only, no UI change), no alert, no re-run.
- Reachable: (see detail)

### AS8 [silent-noop/high] BLAST results drawer — 'Re-run BLAST' button (NVD result drawer) — Click 'Re-run BLAST' in the BLAST results drawer opened from the NVD (Novel Virus Detection) result viewer
- Wiring: `Sources/LungfishNvdUI/NvdResultViewController.swift:1816 (instantiates BlastResultsDrawerContainerView; grep confirms zero occurrences of onRerunBlast anywhere in this file)`
- Handler: `Sources/LungfishKit/BlastResultsDrawerTab.swift:1570-1573: `onRerunBlast?()` fires against a nil closure`
- Same defect as the Assembly drawer: NvdResultViewController.swift never wires container.onRerunBlast, and BlastResultsDrawerTab never disables/hides rerunBlastButton based on callback presence, so the button always appears clickable but does nothing in the NVD BLAST drawer.
- Reachable: (see detail)

### AS9 [silent-noop/high] LungfishNaoMgsUI — Extract Reads… (action bar button + context menu, both routes)
- Wiring: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:772 (showTaxonDetail calls actionBar.setExtractEnabled(true) unconditionally) and :2119-2121 (context menu item always added, enabled)`
- Handler: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1872-1878 presentUnifiedExtractionDialog(): `guard let resultPath = database?.databaseURL else { return }``
- When a bundle is displayed via the cached-rows path (configureWithCachedRows / configure(result:) — parser output with no SQLite DB, used before the DB finishes opening or when only manifest.json cached rows are available), selecting a taxon still calls setExtractEnabled(true) at line 772 regardless of `database == nil`. Clicking Extract Reads (button or 'Extract Reads…' context item at 2119) then hits the guard at line 1873 and returns with zero error/toast/log visible to the user — the button looks enabled and does nothing.
- Reachable: (see detail)

### AS10 [silent-noop/high] LungfishNaoMgsUI — Export… (action bar button)
- Wiring: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1786-1788 actionBar.onExport -> exportResults()`
- Handler: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2601-2602 exportResults(): `guard database != nil, let window = view.window else { return }``
- Same cached-rows-only condition (no SQLite DB yet, e.g. right after import before DB opens, or a manifest-only bundle). displayedRows is populated and writeSummaryTSV(to:) only needs `!displayedRows.isEmpty` (line 2623), so the underlying data is exportable, but exportResults() bails on `database == nil` before even showing the save panel — no feedback to the user that Export did nothing.
- Reachable: (see detail)

### AS11 [silent-noop/high] LungfishNvdUI — Extract Reads… (action bar button)
- Wiring: `Sources/LungfishNvdUI/NvdResultViewController.swift:2069-2070 / :2086-2087 actionBar.setExtractEnabled(true) fires on any single or multi row selection, independent of database state`
- Handler: `Sources/LungfishNvdUI/NvdResultViewController.swift:1571-1576 presentUnifiedExtractionDialog(selectors:): `guard let resultPath = database?.databaseURL else { return }``
- Mirrors the NAO-MGS bug: NVD also has a two-phase load (configureWithCachedRows before configure(database:) completes). The action-bar Extract button is enabled purely on selection state, so a user who clicks Extract during that window (or on a bundle where only manifest.json cached rows loaded) gets no dialog and no error. Note the row-level context menu 'Extract Reads…' item at line 1886 correctly disables via `extractReadsItem.isEnabled = database != nil` — only the action bar's global button lacks this guard, so behavior is inconsistent between the two triggers for the identical action.
- Reachable: (see detail)

### AS12 [silent-noop/high] TaxonomyViewController (DB-backed batch/SQLite taxonomy view) — Right-click taxon -> "Extract Reads…" (sunburst context menu) or table "Extract Reads…"
- Wiring: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:1393-1397 (contextExtractReads), 360-362 & 447-449 (onExtractReadsRequested wiring)`
- Handler: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:725-734 (presentUnifiedExtractionDialog) calling resolveKraken2ResultPath() at line 719-723`
- resolveKraken2ResultPath() only checks `classificationResult` and (isBatchMode && batchURL); configureFromDatabase() (line 424-449) sets `kraken2Database` and `isBatchMode = true` but NEVER sets `batchURL` or `classificationResult`. Any taxonomy view opened via configureFromDatabase (SQLite-backed batch Kraken2 result) has resolveKraken2ResultPath() return nil, so presentUnifiedExtractionDialog silently returns at its first guard with zero user feedback -- despite the code comment at line 445 explicitly claiming 'Reuse the same taxonomy context actions... so DB-backed batch display preserves workflows.' Menu item is not disabled for this state.
- Reachable: (see detail)

### AS13 [silent-noop/med] Inspector > Sample section > per-sample metadata edit sheet — Save (metadata edit for a variant sample)
- Wiring: `Sources/LungfishApp/Views/Inspector/Sections/SampleSection.swift:122-138 (saveMetadataEdits) -> Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift:437-456 (onSaveMetadata closure)`
- Handler: `Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift:437-456`
- saveMetadataEdits() first optimistically writes the edited metadata into the local `sampleMetadata` dict and dismisses the editing sheet (line 129-130, unconditional), THEN fires `onSaveMetadata?(sampleName, metadata)`. The wired closure guards on `canWriteProjectOutputs(...) == true` and returns silently if write access is denied (locked/read-only project), and on `VariantSampleMetadataMutationService` throwing it only does `inspectorLogger.warning(...)` -- no NSAlert, no UI rollback. Net effect: user edits metadata, dialog closes as if saved, Inspector still shows the new value, but the underlying VariantDatabase file(s) were never touched and the edit is lost on next reload/reselect. Same pattern as the known GenBank-merge defect class: label promises a save, only a subset of conditions (write-permitted + service success) actually persists it.
- Reachable: (see detail)

### AS14 [guard-blocked/med] GenotypeResultViewController toolbar "Actions" menu — AI Discovery / AI Refinement (Actions menu items)
- Wiring: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:2677-2680 (menu.addItem "AI Discovery"/"AI Refinement", action: #selector(runAIHaplotypingDiscovery)/#selector(runAIHaplotypingRefinement))`
- Handler: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:5630-5648 (requestAIHaplotyping)`
- The inline audit-section buttons for the same actions (lines 5612-5624) are disabled via `discoveryButton.isEnabled = !isReadOnly` / `refinementButton.isEnabled = hasAnalysis && !isReadOnly`, but the toolbar "Actions" NSMenu built at 2676-2681 adds these as plain `NSMenuItem`s with no `isEnabled`/validateMenuItem gating and no `hasAnalysis` check for Refinement. `requestAIHaplotyping` (5638) itself never checks `annotationStore?.isReadOnly` or whether an analysis exists — it only checks `result` and `onAIHaplotypingRequested`. On a read-only bundle, or before any haplotype analysis exists, the toolbar menu items are clickable and will queue an AI haplotyping write request (`onAIHaplotypingRequested?(...)`) that the inline buttons in the same feature correctly prevent.
- Reachable: (see detail)

### AS15 [silent-noop/med] File > Export > FASTQ… — Export FASTQ
- Wiring: `Sources/LungfishApp/App/MainMenu.swift:237-241`
- Handler: `Sources/LungfishApp/App/AppDelegate+ImportExport.swift:287-297 (exportFASTQ)`
- Filters sidebar selectedItems() to `$0.type == .fastqBundle && $0.url != nil` (line 293). If the user's sidebar multi-selection mixes FASTQ bundles with any other type (reference bundle, assembly, tree, etc.), non-FASTQ items are silently dropped from export with zero indication of what was excluded; only if the filtered set is completely empty does the user get an error ('No FASTQ datasets selected...', line 295). A partial-match selection exports fewer files than selected with no mention of the dropped items in the success alert (line 365-370).
- Reachable: Multi-select sidebar items where only some are FASTQ bundles, then File > Export > FASTQ

### AS16 [guard-blocked/med] File > Export > Annotations (GFF3)… — Export Annotations (GFF3)
- Wiring: `Sources/LungfishApp/App/MainMenu.swift:232-236`
- Handler: `Sources/LungfishApp/App/AppDelegate+ImportCenter.swift:2995-3006 (exportGFF3)`
- Only ever reads `mainWindowController?.mainSplitViewController?.viewerController?.currentDocument` (line 2997) — it completely ignores sidebar multi-selection, unlike exportFASTA/exportFASTQ which at least attempt sidebar-based export. If a user selects one or more reference bundles/annotation-bearing items in the sidebar (without a document open in the viewer) and invokes Export > Annotations, they get 'No document is currently open' even though a selected bundle may have annotations on disk. Label ('Annotations (GFF3)') doesn't communicate this viewer-only scope restriction.
- Reachable: Sidebar item(s) with annotations selected but nothing open in the main viewer document, then File > Export > Annotations

### AS17 [silent-noop/med] Sequence menu > Zoom is not present here, but View menu > Zoom In/Zoom Out/Zoom to Fit/Zoom Reset (10kb) — Zoom In / Zoom Out / Zoom to Fit / Zoom Reset (10kb)
- Wiring: `Sources/LungfishApp/App/MainMenu.swift:548-570 (#selector(ViewMenuActions.zoomIn/zoomOut/zoomToFit/zoomReset)); no validateMenuItem entry for any of these selectors in AppDelegate.swift:1719-1900, so items are always enabled`
- Handler: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:3498 (zoomIn), 3515 (zoomOut), 3553 (zoomToFit), 3568 (zoomReset)`
- Each handler does `guard let frame = referenceFrame else { return }` (zoomToFit additionally guards `viewerView.sequence`) with no fallback and no user feedback. Since these four menu items have no corresponding validateMenuItem branch, they remain clickable/enabled even when no sequence/reference frame is loaded (e.g. Taxonomy or other non-sequence viewport is frontmost, or a freshly created project window). Clicking any of them does nothing and gives no indication why.
- Reachable: (see detail)

### AS18 [silent-noop/med] Sidebar context menu — 5 other bundle kinds (MSA, phylogenetic tree, primer scheme, genotype result, 12S amplicon result) — Right-click a single bundle of type .multipleSequenceAlignmentBundle / .phylogeneticTreeBundle / .primerSchemeBundle / .genotypeResultBundle / .twelveSAmpliconResultBundle
- Wiring: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift (no reference to any of these 5 case names in the whole file — grep confirmed)`
- Handler: `n/a — falls through to generic items only`
- SidebarItemType.isBundle (SidebarItem.swift:110-118) lists 8 bundle kinds, but the context-menu delegate only special-cases 2 of them (.referenceBundle via hasBundles, .fastqBundle via hasFASTQBundles). The other 5 (.multipleSequenceAlignmentBundle, .phylogeneticTreeBundle, .primerSchemeBundle, .genotypeResultBundle, .twelveSAmpliconResultBundle) get zero bundle-specific menu items and are excluded from hasFiles (so no 'Open' either), leaving only Show in Finder / Copy Path / Rename / Duplicate / Move to / Move to Trash. Users cannot open these bundles from the context menu at all; they must double-click in the outline view instead (a different, less discoverable code path) to view contents.
- Reachable: Always reachable — right-click any single MSA/tree/primer-scheme/genotype-result/12S-result bundle in the sidebar.

### AS19 [silent-noop/med] Sidebar context menu — Reassemble — 'Reassemble…' item on a single .referenceBundle with assembly/provenance.json
- Wiring: `SidebarViewController+MenuDelegate.swift:142-146 (menu wiring), :752-801 (handler)`
- Handler: `contextMenuReassemble, SidebarViewController+MenuDelegate.swift:756-760`
- If AssemblyProvenance.load(from:) throws (corrupt/partial provenance.json), the handler logs an error via sidebarLogger and returns (lines 757-760) with zero user-facing alert — the menu item was clickable (bundleHasAssemblyProvenance only checks file existence at line 747-750, not validity) but the click produces no visible effect.
- Reachable: Bundle has an assembly/provenance.json file present (so the menu item appears and is enabled) but the file is malformed/undecodable JSON.

### AS20 [guard-blocked/med] Sidebar outline: internal drag-drop validateDrop/acceptDrop destination resolution — Drag a sidebar item and drop it directly onto a non-container item (e.g. onto a sequence file or classification result row) instead of onto a folder
- Wiring: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:90 (validateDrop) and 159 (acceptDrop)`
- Handler: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:312-321 (internalDropDestinationURL) returns nil unless destinationItem.type is .folder or .project`
- validateDrop returns `[]` (line 107) for any internal drag proposed over a non-folder/non-project item, so AppKit shows no drop indicator and the drop is rejected outright rather than retargeting to the item's parent folder (which is what the sibling external-file-drop path at lines 126-150 explicitly does via its own comment 'retarget to project root'). A user dragging a file onto another file (a very natural gesture, e.g. to reorder or drop 'next to' something) gets a hard rejection with no explanation, while the analogous external-file-drop case is intentionally permissive. Internally inconsistent UX between the two drop-source code paths in the same method group.
- Reachable: (see detail)

### AS21 [silent-noop/med] Inspector > Attachments section > attachment row context menu — Remove Attachment
- Wiring: `Sources/LungfishApp/Views/Inspector/Sections/AttachmentsSection.swift:71-73`
- Handler: `Sources/LungfishCore/Models/BundleAttachmentStore.swift:80-87 (remove(filename:))`
- Context-menu action calls `try? store.remove(filename:)`, discarding the thrown error entirely. `remove(filename:)` calls `FileManager.trashItem(at:resultingItemURL:)`, which can throw for reachable reasons (file locked/in use, TCC/permission denial on the bundle's parent folder, race where the attachment file was already moved/deleted). On failure the attachment silently remains in the list with zero alert/log visible to the user -- it looks like the click did nothing. Compare to the sibling 'Attach File...' action in the same file (line 77-90), which does surface `attachmentErrorMessage` on failure; Remove has no equivalent error path.
- Reachable: (see detail)

### AS22 [silent-noop/med] FASTQ Operations dialog / Alignment / MAFFT (Run) — Run — MAFFT alignment with no project open
- Wiring: `FASTQOperationDialog.swift:73-81 handleRun -> state.prepareForRun()`
- Handler: `FASTQOperationDialogState.swift:368-376 prepareForRun mafft branch; :752-776 makeMSAAlignmentRequest guard let projectURL`
- prepareForRun's mafft branch checks `selectedToolConfigurationIsReady` (readiness text derived from selectedToolConfigurationReadinessText, case .mafft at lines 1416-1429) which validates FASTQ-input confirmation, thread count, and advanced-options parsing — but never checks for a non-nil projectURL. makeMSAAlignmentRequest (line 753) then does `guard let projectURL else { return nil }`, so if selectedToolConfigurationIsReady passed (all its checks pass) but projectURL is nil, pendingMSAAlignmentRequest silently becomes nil and pendingLaunchRequest is also nil (line 374) — Run does nothing, and the readiness banner never warned the user about the missing project because that check lives only in makeMSAAlignmentRequest, not in selectedToolConfigurationReadinessText.
- Reachable: MAFFT tool selected with projectURL == nil (e.g. FASTQ Operations dialog invoked on files not associated with an open Lungfish project) while inputs/threads/options are otherwise valid — Run silently no-ops with a readiness banner claiming the tool is ready.

### AS23 [silent-noop/med] Welcome window - "Create Project" / "Open Project" tiles — Create Project / Open Project launch tiles
- Wiring: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift:762-774 (LaunchActionTile onTap) -> performAction(_:) :953-966`
- Handler: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift:968-990 showCreateProjectPanel, :992-1010 showOpenProjectPanel`
- Both handlers do `guard let window = NSApp.keyWindow else { return }` before presenting the NSOpenPanel/NSSavePanel sheet, with no fallback to NSApp.mainWindow (unlike showStorageLocationPanel at line 1019 which does fall back). If the Welcome window is visible but momentarily not key (e.g. focus stolen by a background task alert, Spotlight, or a just-dismissed sheet not yet having restored key status) the click produces zero visible effect: no panel opens, no error, no log.
- Reachable: User clicks Create Project or Open Project tile at a moment when the Welcome NSWindow is not NSApp.keyWindow (e.g. right after dismissing another sheet/alert, or in scripted/automation-driven clicks).

### AS24 [silent-noop/med] LungfishTaxTriageUI — Extract Reads… (action bar button + organism-table context menu item)
- Wiring: `Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2671-2672 / :2699-2700 / :2959-2960 / :2985-2986 / :3118-3119 actionBar.setExtractEnabled(true) on row selection; :4740-4742 contextExtractFASTQ forwards to same onExtractFASTQ callback`
- Handler: `Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:3387-3393 presentUnifiedExtractionDialog(): `guard let resultPath = taxTriageDatabase?.databaseURL ?? taxTriageConfig?.outputDirectory else { return }`; additionally buildTaxTriageSelectors() (3369-3383) can return `[]` and that empty array is dispatched to onExtractReadsRequested without a not-empty guard, unlike the NAO-MGS/NVD siblings which check `!selectors.isEmpty``
- Same database/config-nil silent-noop as the other three metagenomics leaves (5 separate call sites set setExtractEnabled(true) without checking taxTriageDatabase/taxTriageConfig). Additionally, unlike NvdResultViewController's presentUnifiedExtractionDialog(selectors:) which explicitly guards `!selectors.isEmpty` before dispatching, TaxTriage's version has no such check, so an empty-selector case is passed straight to onExtractReadsRequested — downstream behavior in the extraction dialog for a zero-selector invocation is unverified from this file and should be checked in the App-side dialog handler.
- Reachable: (see detail)

### AS25 [silent-noop/med] LungfishNaoMgsUI — BLAST Verify (action bar button, BAM-fallback path)
- Wiring: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1780-1783 actionBar.onBlastVerify -> showBlastConfigPopover -> executeBlastVerification`
- Handler: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2198-2216 executeBlastVerification fallback path: silently `return`s (only a logger.warning) if `accessions.isEmpty` or the BAM file does not exist on disk at the manifest-recorded path`
- When the virus_hits table is empty (merged/batch databases per the code comment at 2171-2173) and either row.topAccessions is empty or the on-disk BAM referenced by row.bamPath/'bams/<sample>.bam' is missing (e.g. moved/renamed bundle), BLAST Verify does nothing visible — user sees the popover close with no drawer opening and no error.
- Reachable: (see detail)

### AS26 [error/med] LungfishNaoMgsUI — Accession button click / 'View <accession> on NCBI GenBank' (miniBAM panel + context menu)
- Wiring: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1101-1105 accessionButton target/action, and :2331-2335 contextViewAccessionOnNCBI`
- Handler: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2331-2335: `let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(accession)")!` — force-unwrapped URL(string:) built directly from a database-sourced accession string with no percent-encoding`
- accessionSummary.accession comes from NaoMgsAccessionSummary rows in the SQLite database (populated by an external NAO-MGS pipeline, not app-validated). If an accession string ever contains characters invalid in a URL (whitespace, non-ASCII, '#', etc. — plausible from malformed pipeline output or a corrupted/edited bundle), `URL(string:)` returns nil and the force-unwrap crashes the app. The sibling `openGenBankFromButton` (2338-2351) and NVD's equivalent (2042-2047) correctly use `if let url = URL(string:)` instead of force-unwrap — this is an inconsistency, not a defense-in-depth choice.
- Reachable: (see detail)

### AS27 [silent-noop/med] TaxonomyViewController export kebab menu -> Export as CSV…/TSV… — NSSavePanel completes, write fails (disk full, permission denied, path unwritable)
- Wiring: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:1648-1655 (exportCSVAction/exportTSVAction) -> exportDelimited`
- Handler: `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:1530-1540`
- On `content.write(to:...)` throwing, the catch block only calls `logger.error(...)`; no NSAlert or other user-visible feedback is shown. User believes the export succeeded (panel closed) when it silently failed.
- Reachable: (see detail)

### AS28 [silent-noop/med] AssemblyActionBar 'Copy FASTA' button (assembly contig result viewport) — Copy FASTA button / context menu 'Copy FASTA'
- Wiring: `Sources/LungfishAssemblyUI/AssemblyActionBar.swift:11,17,80 -> AssemblyResultViewController.swift:205 (actionBar.onCopy)`
- Handler: `Sources/LungfishAssemblyUI/AssemblyResultViewController.swift:361-367 (performCopySelectedFASTA) calling `try? await materializationAction.copyFASTA(...)``
- copyFASTA invokes the CLI runner (LungfishCLIRunner.run) which can throw for a stale/renamed contig name, a corrupted assembly output dir, or any CLI failure; the `try?` swallows the error entirely with no alert/log path exposed to the user, unlike performBlastSelected which has a warningPresenter for at least one failure mode. Unlike Extract/Export/Bundle (which route to app-level callbacks with fuller error handling when wired), Copy FASTA has no callback override in ViewerViewController+Assembly.swift -- it always uses this unguarded leaf-only path.
- Reachable: (see detail)

### AS29 [silent-noop/med] ClassificationWizardSheet (Kraken2) Run button — Run
- Wiring: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift:312-318 (Button('Run') { performRun() }, .disabled(!canRun))`
- Handler: `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift:567-569 performRun()`
- performRun() does `guard let extraArguments = try? AdvancedCommandLineOptions.parse(extraArgumentsText) else { return }`. The `canRun` computed property (line 169-171) that gates button enablement never checks extraArgumentsText, so the Run button stays enabled and clickable even when the user has typed unparseable extra arguments (e.g. an unterminated quote). Clicking Run then does nothing at all -- no error text, no alert, no visual change, and the sheet stays open with no explanation of why nothing happened.
- Reachable: (see detail)

### AS30 [silent-noop/med] EsVirituWizardSheet Run button — Run
- Wiring: `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift:219-242 standaloneBody -> WizardSheet(onPrimary: performRun, isPrimaryEnabled: canRun)`
- Handler: `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift:503-505 performRun()`
- Identical pattern to ClassificationWizardSheet: `guard let extraArguments = try? AdvancedCommandLineOptions.parse(extraArgumentsText) else { return }` at line 505, but `canRun` (EsVirituRunReadiness.canRun, lines 8-20) never checks extraArgumentsText parseability. Malformed extra args (e.g. unbalanced quotes) leave Run enabled; clicking it silently no-ops with zero user feedback.
- Reachable: (see detail)

### AS31 [silent-noop/med] TaxTriageWizardSheet Run button — Run
- Wiring: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift:209-228 standaloneBody -> WizardSheet(onPrimary: performRun, isPrimaryEnabled: standalonePresentation.isPrimaryEnabled)`
- Handler: `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift:649-650 performRun()`
- Same pattern a third time: `guard let extraArguments = try? AdvancedCommandLineOptions.parse(extraArgumentsText) else { return }` at line 650. `canRun` (lines 150-156) does not check extraArgumentsText. A malformed Extra Arguments field (accessibilityIdentifier 'taxtriage-extra-arguments-field') leaves Run enabled but clicking it does nothing -- no message like MappingWizardSheet's or AssemblyWizardSheet's advancedOptionsParseError banner is shown.
- Reachable: (see detail)

### AS32 [guard-blocked/low] File > Export (submenu items generally) — All Export submenu actions
- Wiring: `Sources/LungfishApp/App/MainMenu.swift:227-278`
- Handler: `AppDelegate.swift:1719 validateMenuItem`
- No validateMenuItem branch exists for any of exportFASTA/exportGFF3/exportFASTQ/exportProjectSampleMetadata/exportImage/exportPDF/exportProvenance*, so all Export submenu items are always enabled (default AppKit target-action validation) even when there is no document, no bundle, and no sidebar selection at all — clicking any of them with nothing open/selected always round-trips through a runtime alert instead of being grayed out proactively. Not a correctness bug per se (alerts do fire) but is inconsistent with the rest of the File menu (e.g. importBAMToBundle/importSampleMetadataToBundle ARE gated via validateMenuItem at lines 1761-1765) and creates a worse UX/discoverability experience for Export vs Import actions.
- Reachable: Any Export submenu item invoked with no relevant document/bundle/selection present

### AS33 [silent-noop/low] Tools menu — Category submenu operation items (e.g. Trimming & Filtering > ..., Mapping > ..., etc.) and per-tool workflow items
- Wiring: `MainMenu.swift:816-824 (launchFASTQOperationToolFromMenu) / :827-851 (workflowMenuItem)`
- Handler: `AppDelegate+ToolsMenu.swift:72-75 launchFASTQOperationToolFromMenu -> showFASTQOperationsDialog -> showFASTQOperationsDialog body at :94-238`
- If no window/split/window is available (guard at :100-105), the action silently no-ops with only a debugLog call and no user-facing alert — same pattern repeated at launchNaoMgsImport (:368-372), launchPrimerSchemeImport (:395-399), launchNvdImport (:442-446), launchCzIdImport (:469-473). Reachable if the user closes all project windows but leaves the app running (macOS keeps the menu bar/app alive with no windows); menu items have no validateMenuItem gate disabling them in that state, so a keyboard shortcut or menu click produces zero feedback.
- Reachable: (see detail)

### AS34 [suspicious/low] Sidebar context menu — Export Sequences… labeled count vs actual export scope — 'Export N Sequences…' when selection mixes .referenceBundle with other selected items (e.g. plain .sequence files or mhc bundles)
- Wiring: `SidebarViewController+MenuDelegate.swift:94-100 (bundleCount = items.filter{$0.type==.referenceBundle}.count, but exportSeqItem invokes FileMenuActions.exportFASTA(_:) which re-derives its own filtered set)`
- Handler: `AppDelegate+ImportCenter.swift:2216-2260 exportFASTA -> exportSequences`
- The menu label's bundleCount is computed independently from what exportSequences() will actually act on (its own re-filter at line 2228 to .referenceBundle/.sequence, and a further branch at 2251-2253 requiring sidebarItems.allSatisfy{.referenceBundle} for batch export). If the original selection includes reference bundles plus other non-referenceBundle/non-sequence items, the label says 'Export N Sequences' (N = referenceBundle count) but the actual downstream selection re-query may diverge in edge cases (e.g. selection order/state changes between menu build and action dispatch is unlikely here since it's synchronous, but the duplicate-filtering logic living in two places is a maintenance hazard consistent with the reported class of bug). Not fully confirmed to manifest incorrect output from static reading alone.
- Reachable: Mixed selection of reference bundles with plain sequence files or unsupported bundle kinds, then invoke Export Sequences from context menu.

### AS35 [silent-noop/low] Sidebar outline: cross-window internal drag when destination folder cannot be resolved — Drag a sidebar item from Window A's sidebar and drop it into Window B's sidebar at a location where Window B has no project open (destinationItem nil and projectURL nil)
- Wiring: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:90 (validateDrop), 159 (acceptDrop)`
- Handler: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:312-321 (internalDropDestinationURL): `projectURL?.standardizedFileURL` is nil when no project is open`
- validateDrop line 106-108 returns `[]` when internalDropDestinationURL is nil, silently refusing the drop; no dialog explains 'open a project first' or similar. Because line 99-125 special-cases 'Internal type from another window' as a copy import only when hasLocalSource is false, but that path is only reached AFTER internalDropDestinationURL succeeds (it's checked first at line 106), a cross-window drag into an empty-project window fails silently rather than falling through to something actionable.
- Reachable: (see detail)

### AS36 [silent-noop/low] Sidebar outline: selection routing when destination item's file has moved/vanished mid-selection — Select a sidebar item whose underlying document type resolution fails (DocumentType.detect returns nil) during a multi-select load
- Wiring: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:45-61 (item categorization loop inside handleMultipleItemsSelected)`
- Handler: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+MultiDocument.swift:52,55 (`else if let docType = DocumentType.detect(from: url)` — no else branch)`
- When an item has a URL, isn't already loaded, and DocumentType.detect(from:) returns nil (unrecognized extension, e.g. a renamed/corrupted file), the item is silently dropped from both placeholderDocuments and unregisteredURLs with no log line and no user feedback at all (the two nested `else if let` branches at 52 and 55 have no matching `else`). The item simply disappears from the resulting collection view with zero trace, even in debug logs.
- Reachable: (see detail)

## Stubs

- [med] Sidebar outline: selection routing when destination item's file has moved/vanished mid-selection — Freyja Demix (wastewater-surveillance): showFreyjaDemix(_:) is fully implemented (PluginManagerWindowController.show(packID: "wastewater-surveillance")) and has a reserved accessibility identifier suggesting it was meant to appear in the Tools menu, but createToolsMenu()/categoryToolsMenuItem() never add an NSMenuItem with action #selector(showFreyjaDemix(_:)). Zero #selector references to this method exist in the whole codebase, so the action is currently unreachable from any UI surface. Likely orphaned during a refactor (Freyja demix logically belongs under Classification/wastewater tooling but was dropped from the menu build). (`AppDelegate+ToolsMenu.swift:77-79`)

- [low] Sidebar outline: selection routing when destination item's file has moved/vanished mid-selection — classifyReads(_:) selector: Implemented as showFASTQOperationsDialog(sender, initialCategory: .classification) but never attached to any NSMenuItem, button, or gesture. Classification is otherwise reachable via the per-category Tools > Classification submenu (workflow catalog items), so this appears to be dead/duplicate code left over from a prior design, not a current gap in user-facing functionality. (`AppDelegate+ToolsMenu.swift:1326-1328`)

- [low] Sidebar outline: selection routing when destination item's file has moved/vanished mid-selection — showImportCenterClassification(_:) selector: Implemented as ImportCenterWindowController.show(tab: .classificationResults) but never wired to a menu item; only the plain showImportCenter(_:) (File menu) is wired, always opening the default tab. Dead handler with no accessibility identifier either. (`AppDelegate+ToolsMenu.swift:1322-1324`)

- [low] Sidebar outline: selection routing when destination item's file has moved/vanished mid-selection — N/A — unreachable handlers: These two @objc methods exist and would themselves also fail (guard let seq = sequence, same bundle-mode gap as copySelectionToClipboard) but are not currently reachable from any menu item, toolbar item, or key equivalent in this file — likely leftover from a prior menu layout. Not user-triggerable today so not scored as a live defect, but worth removing or wiring correctly given the adjacent bundle-mode bug. (`SequenceViewerView+Interaction.swift:1067-1121`)

## Refuted claims

- Sidebar context menu — Merge into New Bundle (mixed-kind selection) — Select 2+ items of mixed bundle kinds (e.g. one .referenceBundle + one .mhcReferenceBundle) and right-click: The gating code (BundleMergeSelection.detectKind, SidebarViewController+MenuDelegate.swift:69/102/167) is accurately described: mixing .referenceBundle and .mhcReferenceBundle in a multi-select does cause the 'Merge into

- TaxonomyViewController export/provenance kebab menu (buildExportMenu) — Export as CSV…/Export as TSV…/Copy Summary/Show Provenance…: The claim asserts that in DB-backed batch mode neither `classificationResult` nor `tree` are ever populated, causing all 4 export/provenance menu items to silently no-op. This is only half true. `tree` (the guard used by

- Sidebar outline: outlineViewSelectionDidChange during a deferred genotype-haplotype transition — Click a different sidebar item while the genotype comparison matrix has an in-progress manual-haplotyping draft that requires confirmation before switching bundles: Traced the full chain: SidebarViewController+OutlineDelegate.handleSelectionChange -> MainSplitViewController.sidebarShouldDeferSelectionTransition -> GenotypeResultViewController.deferManualHaplotypeTransition -> Genoty

- Variant Query Builder button (toolbar, Variants tab) — Click 'Query Builder...' / 'Edit Query...' when the loaded VCF database(s) exceed the materialized-only size threshold: The claim asserts the button remains visually enabled with no tooltip and no disabled styling when materialized-only mode is active, but this is factually wrong. In AnnotationTableDrawerView+Columns.swift updateSearchFie

- FASTQ Operations dialog / Trimming & Filtering / Primer Trimming (Run) — Run — Primer Trimming, Reference FASTA source: The silent-no-op mechanism does not hold up. Run can only be invoked when isRunEnabled is true, which requires missingRequiredAuxiliaryInputKinds.isEmpty (FASTQOperationDialogState.swift:1054-1056), which for .primerTrim

- Inspector Document tab "Smart Cohorts" section (genotype) — Select cohort row / Delete cohort (minus-circle) / "Save Current Filter…" (+Add): The claim's premise is false. It asserts a previously-saved user cohort persisted in the sidecar can populate state.smartCohorts and render as clickable rows while hasHaplotypingResult is false, making the guarded callba

- File > Import Center… — Open Import Center: Traced the full chain: MainMenu -> showImportCenter -> ImportCenterWindowController.show() -> ImportCenterViewModel's Reference Sequences card (id: "fasta", ImportCenterViewModel.swift:487-523) opens an NSOpenPanel pre-f

- Viewer annotation context menu → "Extract Overlapping Reads…" — Extract Overlapping Reads: Verified against ViewerViewController+Mapping.swift and SequenceViewerView+Interaction.swift lines 846-859: the menu item is only added when activeMappingViewportController?.currentResult != nil, and mappingExtractionUna
