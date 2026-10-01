# Plan: app-wide keyboard and accessibility pass (2026-09-30)

Owner rule: every surface that is mouse-only gets keyboard and accessibility controls, for accessibility and so automation and LLM agents can drive LGE. Background automation uses the macOS AX API and cannot open context menus, pull-downs, or hover.

## Owner decisions (2026-09-30, binding)

- **New top-level Selection menu** between Sequence and Tools, with submenus **Sidebar Item** and **Table Row**.
- **Promote** sidebar New Folder (Cmd-Shift-N), Duplicate (Cmd-Shift-D) and Move to Trash (Cmd-Delete) to real menu-bar key equivalents, enabled only while the sidebar outline is first responder.
- **Native SwiftUI `Table`** for the MSA pairwise list, primer binding rows and primer order oligos.
- **Focused table** routing: menu-bar row commands validate and act on the first-responder table (like Operations). Automation focuses the table first.

Defaults taken by the coordinator (not asked): retarget View > Expand All / Collapse All to a shared outline protocol so every outline answers. Sunburst gets only Zoom In / Zoom Out custom actions. Table header column menus get the menu mirror helper (custom actions on the header). Drawer resize handles stay drag-only (layout, no command lost). 12S export formats get custom actions on the export button plus one menu-bar "Export 12S Result…" item that presents the format list as a sheet. Leave the genotype comparison row list lazy (children already hidden, no actions lost).

## 0. Ground truth

- Commit 4d44d4a20 is the pattern. Row commands live on **cell views**, installed from `tableView(_:viewFor:row:)` through `Sources/LungfishApp/Views/Shared/AccessibilityCellActions.swift`. Handlers resolve the row at call time (`AccessibilityCellActions.currentRow(of:)`). `NSTableView.accessibilityRows()` returns private row proxies that ignore row-view actions; their AXChildren are cell proxies that forward `accessibilityCustomActions` to the `NSTableCellView`. `AccessibilityActionRowView` no longer exists.
- Tests read actions through `Tests/LungfishAppViewTests/AccessibilityRowProbe.swift` (table, row proxy, AXChildren, cell proxy, accessibilityCustomActions). Never assert only the Swift getter.
- `NSOutlineView` has not been probed. Lane A's first test is the go/no-go for every outline surface. Fallbacks if it fails: actions on the outline column's cell view only, else per-row `NSAccessibilityElement` children.
- Menu-bar model: `Sources/LungfishApp/Views/Operations/OperationRowAction.swift` plus `makeSelectedOperationItem()` in `MainMenu.swift`.
- `screencasts/_shared/capture/axdrive.swift` (menu, row, rowAction on the row's first cell, focusTable, press, key, --dump) is the GUI verification tool.
- Key equivalents in use: Cmd-Opt C D F G H I L N O V + - 0, matrix-local Cmd-Opt P X R M. Cmd-Shift A B C E F G I O P R T U Z 0 Left Right (plus the sidebar context-only N, D). Cmd A C F G H K L M N O Q R V W X Z , + - 0 1 [ ] ?. Ctrl-Cmd S F. Only one new chord is added: **Cmd-Opt-S, Show in Inspector**. Everything else is an unbound menu item.

## 1. Inventory

### 1a. Context-menu-only tables (AppKit)

| Surface | File | Mouse-only today | Route | Shortcut |
|---|---|---|---|---|
| Sidebar outline | Sidebar/SidebarViewController+MenuDelegate.swift, SidebarViewController.swift | 25 commands (Manage Project Storage, Export Sequences, Merge into New Bundle, Export Alignment, Open Bundle, Show Package Contents, Get Bundle Info, Import Sample Metadata, Delete Variant Tracks, Reassemble, Export as FASTQ, Clone Metadata From, Copy Classification Command, Open, New Folder, Edit/Export/Import Sample Metadata, Show in Finder, Copy Path, Show in Inspector, Rename, Duplicate, Move to, Move to Trash). Only Delete and Cmd-Shift-A by keyboard. | `SidebarItemAction` enum (shape of `OperationRowAction`) backing `populateContextMenu`, Selection > Sidebar Item, `NSMenuItemValidation` on `selectedItems()`. Cell actions in `outlineView(_:viewFor:item:)` for single-item commands. "Move to" stays a submenu. | Cmd-Shift-N, Cmd-Shift-D, Cmd-Delete (hoisted), Cmd-Opt-S |
| Taxonomy table | Metagenomics/TaxonomyTableView.swift (buildContextMenu 724, validateMenuItem 793, keyDown 1386) | Extract Reads, Expand variants, BLAST Matching Reads, NCBI Taxonomy/GenBank/PubMed, Copy Taxon Name | `ResultRowMenuActions` selectors, cell actions, selected row (clicked fallback) | none |
| Reference bundle record table | Results/Reference/ReferenceBundleRecordTable.swift, LungfishKit/BatchTableView.swift | FASTA builder items | `BatchTableView` hook, `ResultRowMenuActions` | none |
| Chromosome navigator | Viewer/ChromosomeNavigatorView.swift | Extract to New Bundle, Copy Name, Copy Length, Show in Inspector; sort pop-up | Return/Enter = double-click; cell actions incl. Navigate; menu bar selectors; sort pop-up mirror | Cmd-Opt-S |
| FASTA collection table | Viewer/FASTACollectionViewController.swift | Extract Sequence, Verify with BLAST, Copy Name(s)/Sequence(s)/FASTA, Export FASTA, Extract to New Bundle, Align with MAFFT, Run Operation | Return/Enter opens; shared `FASTASequenceActionMenuBuilder.accessibilityActions`; menu bar | none |
| Viral detection (EsViritu) | LungfishEsVirituUI/ViralDetectionTableView.swift | Extract, BLAST, GenBank/Assembly/PubMed/Taxonomy, Copy Name/Accession/Row as TSV, Expand/Collapse All | `ResultRowMenuActions`, cell actions, `OutlineExpandCollapseActions` | none |
| NVD outline | LungfishNvdUI/NvdResultViewController.swift | Extract, FASTA items, Copy Contig Name/Accession, NCBI, PubMed | same, refactor to selected hit | none |
| NAO MGS table and accession buttons | LungfishNaoMgsUI/NaoMgsResultViewController.swift | BLAST N reads, Copy Taxon ID/Top Accessions, NCBI, PubMed, Extract; accession button menus | same; one "Verify with BLAST" opening the existing popover; button custom action "Copy Accession" | none |
| TaxTriage batch and per-sample | LungfishTaxTriageUI/BatchTaxTriageTableView.swift, TaxTriageResultViewController.swift | Verify with BLAST, Copy Organism/Accession/Taxon ID/Row as TSV, NCBI Taxonomy, Extract | selected rows, BatchTableView hook, `ResultRowMenuActions` | none |
| 12S amplicon | LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift | copy menu; button-popped metadata-columns and export menus | cell actions, copy selectors; mirror on both buttons; "Export 12S Result…" sheet item | none |
| BLAST results drawer | LungfishKit/BlastResultsDrawerTab.swift | Copy FASTA/Read ID/Accession, Expand/Collapse All; header column menu | cell actions, selectors, outline protocol; header mirror | none |
| Phylogenetic tree node table | LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift | Show in Inspector, Copy Node Label, Copy Subtree as Newick, Root on Branch to Here | cell actions, selectors, module-local Root on Selected Branch | Cmd-Opt-S |
| FASTQ metadata kit table | Viewer/FASTQMetadataDrawerView.swift | three copy items | cell actions | none |
| Annotation drawer (rest) | Viewer/AnnotationTableDrawerView.swift | Copy Name/Coordinates/Sequence/RC/FASTA/Translation, Extract, Add/Edit/Delete Annotation, Select Related Gene Features, Show Overlapping Variants, Copy Variant ID/Ref-Alt/VCF Line, Bookmark, Export Bookmarked; pull-downs | extend `installAccessibilityActions`; Table Row selectors; Sequence > Add/Edit/Delete Annotation; mirror on pull-downs | Cmd-Opt-S |
| Operations panel | Views/Operations | done | verify only | |

### 1b. Hover-dependent

| Surface | File | Route |
|---|---|---|
| AI assistant copy button | Views/AI/AIAssistantPanel.swift | verify, add label "Copy message" if missing |
| Analyses section rows | Inspector/Sections/AnalysesSection.swift | `.accessibilityValue` and `.help` with the absolute timestamp |
| Track header disclosure triangles | Viewer/TrackHeaderView.swift, EnhancedCoordinateRulerView.swift | NSAccessibilityElement per track (disclosure triangle, press toggles); focusable, Up/Down, Space; View > Toggle Annotations for Selected Track |
| Welcome window | Welcome/WelcomeWindowController.swift | optional-tools LazyVGrid to Grid; verify tiles |
| Known-allele feature blocks | LungfishGenotypeUI/GenotypeKnownAlleleOverviewView.swift | role button, press selects, Highlight Feature / Clear Highlight, Left/Right/Return |
| Tooltips | various | informational, out of scope; sunburst Zoom In / Zoom Out actions |

### 1c. Lazy stacks and grids

| File | Lists | Proposal |
|---|---|---|
| DemoProjects/DemoProjectsView.swift | already VStack | verify |
| Inspector/Sections/VariantSection.swift 491 | selected variants (hundreds) | VStack capped at 100 with "showing 100 of N" |
| VariantSection.swift 535, 692 | fields | VStack |
| Inspector/Sections/MultipleSequenceAlignmentDocumentSection.swift 411 | pairwise rows N(N-1)/2 | Table, max height 320 |
| PluginManager/PluginManagerView.swift 448 | packs | VStack |
| PrimerAnalysis/PrimerBindingInspectionView.swift 253 | per-row comparisons | Table |
| PrimerAnalysis/PrimerOrderResultView.swift 110, 131 | pools, oligos | pools VStack, oligos Table |
| Results/MHCReference/MHCReferenceBundleViewport.swift 258 | definitions | VStack |
| LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift 272, 381 | candidates (up to 384), loci | VStack, keep ScrollViewReader |
| GenotypeSampleComparisonPanel.swift 580 | comparison rows | leave lazy |
| LungfishKit/ClassifierSamplePickerView.swift 100 | samples with toggles | VStack |
| Welcome/WelcomeWindowController.swift 966 | optional tool cards | Grid |
| Inspector/LungfishInspectorStyle.swift 33 | option buttons | Grid |
| Inspector/Sections/AnnotationSection.swift 405, 507 | filter chips | FlowLayout (Views/Shared/FlowLayout.swift) |
| GenotypeMatrixAnnotationSection.swift 361, GenotypeHaplotypeDefinitionEditor.swift 496 | swatches | Grid |
| Settings/AppearanceSettingsTab.swift 121 | colour pickers | Grid |
| LungfishNaoMgsUI/NaoMgsChartViews.swift 201 | metric cards | leave |

### 1d. Pull-downs and drag-only

- Annotation drawer pull-downs (sampleGroupPreset, profile, haploidMode, export, columnConfig), genotype `columnsButton`, chromosome sort pop-up: mirror helper.
- Gene tab bar overflow: Sequence > Go to Gene… (Cmd-Opt-G) covers it, verify and document.
- Drawer resize handles: stay drag-only. Sidebar drag and drop: covered by Import Center and Move to. Drawer row drag: covered by Copy.
- MSA gutter and header menus: audit `MultipleSequenceAlignmentActionRegistry` against the Sequence menu, list gaps.

### 1e. SwiftUI `.contextMenu` sites

AttachmentsSection (Reveal in Finder, Quick Look, Remove Attachment), DocumentSection 1399/1661/1810 (Copy Command, Copy Value, Copy Link, Remove Derived Alignment…), PrimerReviewContextMenu and its five call sites. All go through a `contextActions(_:)` modifier that emits both the menu and `.accessibilityAction(named:)`.

## 2. Shared infrastructure (Lane 0, lands first)

1. Move `AccessibilityCellActions` to `Sources/LungfishKit/Accessibility/AccessibilityCellActions.swift` (public, same API), delete the LungfishApp copy.
2. Move `AccessibilityRowProbe` to `Tests/Support/LungfishTestSupport/` (public), add `outlineRowProxies(of:)`.
3. `RowCommand` protocol (LungfishKit): title, menuBarTitle, identifierSlug, keyEquivalent, menuSelector, with helpers for menu bar items, context items and cell actions. `OperationRowAction` adopts it with no behaviour change.
4. `@objc public protocol ResultRowMenuActions` (LungfishKit): extractReadsForSelectedRows, blastVerifySelectedRow, copySelectedRowName, copySelectedRowAccession, copySelectedRowTaxonID, copySelectedRowAsTSV, copySelectedRowSequence, copySelectedRowFASTA, openSelectedRowOnNCBI, openSelectedRowTaxonomyOnNCBI, openSelectedRowGenBank, searchPubMedForSelectedRow, showSelectedRowInInspector, extractSelectedRowsToNewBundle, activateSelectedRow. Plus `OutlineExpandCollapseActions` (expandAllOutlineItems, collapseAllOutlineItems); retarget View > Expand All / Collapse All.
5. Selection menu in MainMenu.swift (Sidebar Item, Table Row), nil targets, `MainMenuAccessibilityID.selection*` identifiers, Show in Inspector Cmd-Opt-S. Lane 0 also adds the nil-target items Lane B needs (View > Toggle Annotations for Selected Track, Sequence > Add/Edit/Delete Annotation) and the "Export 12S Result…" item, so MainMenu.swift is touched once.
6. `BatchTableView` hook `accessibilityActions(forRow:cellView:)` called from its `viewFor`.
7. `FASTASequenceActionMenuBuilder.accessibilityActions(selectionCount:handlers:)`.
8. Menu mirror helper (`NSPopUpButton` and any `NSMenu` owner, including header views).
9. SwiftUI `contextActions(_:)` modifier in Views/Shared/ContextActions.swift.
10. `ContextMenuParityAssert` test helper (every context title has a cell action of the same title or a menu-bar item with the same selector) and `MainMenuShortcutCollisionTests` (every key equivalent in the whole tree unique, plus the view-local registry).
11. axdrive: `outline` step support and an `elementAction` step for non-table elements.

## 3. Lanes

Lane 0 first. Then A to D, disjoint files.

- **Lane A, sidebar and inspector sections (LungfishApp).** SidebarItemAction, SidebarViewController (validation, cell actions), Attachments/Document/Analyses/Variant/MSA/Annotation sections, inspector style, FlowLayout. Tests: SidebarItemActionAccessibilityTests (availability parity with SidebarBundleCapabilityTests, menu routing, validation false unless the outline is first responder, outline probe performs Copy Path through AX: the outline go/no-go, parity assert), InspectorSectionAccessibilityTests (hosted sections expose actions through the bridge, Variant cap). Docs: appendix Selection menu section, hoisted sidebar chords, Cmd-Opt-S, index.
- **Lane B, viewer tables and track header (LungfishApp Viewer, Metagenomics, Results).** ChromosomeNavigator, FASTACollection, annotation drawer (full actions, mirror on pull-downs), GeneTabBar (verify), TrackHeader and ruler handler, Taxonomy table/controller, ReferenceBundleRecordTable, FASTQMetadataDrawer, sunburst actions. Tests: extend ChromosomeNavigatorSelectionTests, FASTACollectionViewControllerTests, AnnotationTableContextMenuTests (all tabs parity), TaxonomyViewControllerTests (outline probe, validation), new TrackHeaderViewAccessibilityTests, PopUpMirrorInDrawerTests. Docs: viewport section rows.
- **Lane C, result modules.** EsViritu, NVD, NAO MGS, TaxTriage batch and per-sample, 12S, phylogenetics, BLAST drawer. One test class per module target: probe titles, Copy via probe writes the pasteboard, validation follows selection, parity assert, row-reuse regression (a view reused for a far row reports the far row). Docs: classifier result section.
- **Lane D, genotype and SwiftUI lists.** Known-allele overview, sample comparison panel, swatch grids, columnsButton mirror, classifier picker, plugin manager, welcome grid, appearance settings, primer views (context actions and Tables), MHC viewport. Tests: KnownAlleleFeatureBlockAccessibilityTests, SampleComparisonPanelAccessibilityTests, ClassifierSamplePickerAccessibilityTests, primer row actions, WelcomeOptionalToolGridAccessibilityTests. Docs: genotype section keys.

Rules for every lane: XCTest; `swift test --filter <Class>` one class at a time, never `--parallel`, never the full suite; async tests wait on a clock deadline, never yield counts; macOS 26 API rules (no runModal, lockFocus, wantsLayer, synchronize, deprecated NSSplitViewController delegate methods); manual prose rules (no em dashes, semicolons, mid-sentence colons, "LGE"), lint with `LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh docs/user-manual/chapters/appendices/keyboard-shortcuts.md`. Only append rows to your own appendix section and rebase before committing.

## 4. GUI verification (debug app in the background)

Build `scripts/build-app.sh --debug`, launch by path, note the pid, rebuild axdrive. Query, perform, observe, with the app not frontmost.

- Lane 0: Selection > Table Row > Show in Inspector disabled with nothing focused; identifiers present; Operations row actions still listed and performable.
- Lane A: sidebar bundle row cell actions (Open Bundle, Show in Finder, Copy Path, Show in Inspector); Copy Path performed; Selection > Sidebar Item > Show in Inspector; Cmd-Delete in an inspector text field edits text; Attachments row actions; Variant section cap and no AXOpaqueProviderGroup.
- Lane B: chromosome row actions and Return recentres; FASTA Copy FASTA; drawer variant row full action list; profile pull-down actions switch columns; track header disclosure elements toggle and the View item toggles back; taxonomy Expand All and Copy Taxon Name.
- Lane C: each result type lists actions, Copy and NCBI actions work, Selection > Table Row > Extract Reads… opens the dialog, View > Expand All expands NVD and EsViritu; 12S columns button actions.
- Lane D: feature block is an AXButton with actions and keyboard; sample panel candidates are AXButtons; picker toggles are AXCheckBoxes; plugin manager and welcome buttons reachable; primer row actions; appearance grid reachable.

## 5. Risks

1. Outline proxies unproven (Lane A gate).
2. Cmd-Delete must never fire outside the focused sidebar (validation plus a manual check).
3. Cell action cost on high-rate scroll in the annotation drawer: measure with a large variant set before merging Lane B.
4. `Table` changes the look and text selection of three lists (owner accepted).
5. `AccessibilityRowProbe` relies on private proxy behaviour; keep the axdrive check as a second line.

## 6. Apple HIG and accessibility conformance (owner requirement, binding for every lane)

Every change follows the Apple Human Interface Guidelines (menus, keyboard, accessibility) and Apple's accessibility programming guidance for AppKit and SwiftUI. Concretely:

- **Menus.** Title-case menu and item titles. An ellipsis (…) only when the command needs more input before it acts (a sheet, dialog or panel). Disable items that cannot apply rather than hiding them. Group related items with separators, keep submenus one level deep where possible. App-specific menus sit between View and Window, so the Selection menu is placed after Sequence and before Tools, never after Window or Help.
- **Keyboard shortcuts.** Never override a standard macOS shortcut for a different meaning (Cmd-C/V/X/Z/A/S/W/Q/H/M/N/O/P/F/G/comma and the system-reserved chords). Reuse platform meanings where they exist: Cmd-Delete Move to Trash (Finder), Cmd-Shift-N New Folder (Finder), Return/Enter to activate a selected row, Space to toggle a focused disclosure, Left/Right to collapse/expand outline rows, Escape to cancel. Prefer Cmd and Cmd-Shift, use Option only as a secondary modifier, avoid Control-based chords. The shortcut audit test also checks against a list of the HIG standard shortcuts.
- **Full Keyboard Access.** Every control is reachable with Tab/Shift-Tab and shows the system focus ring. No custom drawing suppresses the focus ring. Custom views that accept first responder draw a focus indicator with `NSFocusRingType.default` or `focusRingMaskBounds`/`drawFocusRingMask`.
- **VoiceOver semantics.** Correct roles (button, disclosure triangle, checkbox, row, cell), a concise accessibility label for every icon-only control (no "button" in the label, no redundant role words), help text (`accessibilityHelp` / `.help`) where a tooltip carries meaning, values for stateful controls (expanded/collapsed, on/off). Custom action names are short title-case verb phrases matching the menu titles. Decorative images are hidden from accessibility. Groups that read as one item use `.accessibilityElement(children: .combine)` deliberately, never by accident.
- **Information without hover or colour.** Anything shown only on hover is also available as an accessibility value or help, and through a keyboard route. Colour is never the only carrier of meaning.
- **System settings.** Respect Reduce Motion, Increase Contrast and Differentiate Without Colour where the changed surfaces animate or encode state in colour.
- **Verification.** Each lane runs the Xcode Accessibility Inspector audit (or `performAccessibilityAudit` in UI tests where available) on its surfaces and fixes or explains every warning, in addition to the axdrive checks. An independent accessibility reviewer (accessibility-tester agent) reviews each lane's diff against this section before merge.
