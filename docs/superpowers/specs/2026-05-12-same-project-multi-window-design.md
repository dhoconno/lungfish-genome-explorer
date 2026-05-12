# Same Project Multi-Window - Design Spec

Date: 2026-05-12
Owner: Project Lead Agent
Status: Draft for approval
Scope: Planning only. No implementation is approved by this document.

## Current Implementation Verdict

The current app can open the same `.lungfish` project folder in more than one window, but this is incidental rather than a safely supported VS Code-style same-folder multi-window model.

Evidence from the current implementation:

- `AppDelegate` keeps an array of open `MainWindowController` instances and `File > Open Project Folder...` creates a new controller every time. There is no duplicate-project guard or single-window reuse path in `Sources/LungfishApp/App/AppDelegate.swift:526` and `Sources/LungfishApp/App/AppDelegate.swift:1235`.
- Each `SidebarViewController` has its own `projectURL` and `FileSystemWatcher`, so basic per-window folder browsing exists. See `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:720` and `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:2050`.
- `DocumentManager` is still a singleton with one `documents`, one `activeDocument`, one `activeProject`, and one `activeProjectOpenWarningState`. Opening a project in any window replaces that global state. See `Sources/LungfishApp/App/DocumentManager.swift:117` through `Sources/LungfishApp/App/DocumentManager.swift:129`.
- `MainSplitViewController` filters the global `DocumentManager.projectOpenedNotification` so only the active window reacts, but then it reads `DocumentManager.shared.documents` to populate that window. See `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift:672` through `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift:706`.
- Menu and workflow routing still frequently depends on `AppDelegate.mainWindowController`, `DocumentManager.shared.activeProject`, or global completion callbacks. This can send async completion work to whichever window is active later, not necessarily the window that launched the operation.
- Project lock handling is warning-only. `ProjectOpenWarningState` can identify active or unknown external locks, but the current app does not enforce a read-only project UI from that state.

Practical answer: read-only visual review in two same-project windows may appear to work for simple cases, because sidebars and viewers are mostly per-window. It is not safe to advertise as supported for real work involving imports, transformations, exports, provenance inspection, or long-running workflows until project/document state, notifications, and operation routing are made explicitly window-scoped and project-aware.

## Expert Panel Input

The Project Lead coordinated four parallel reviews:

- Codebase explorer: same-project multi-window currently "incidentally works with caveats."
- Genomics domain panel: users need side-by-side scientific review, but provenance, stale input detection, and operation routing are blocking correctness requirements.
- UI/UX panel: the feature should feel like peer windows over one project, with explicit duplicate-window affordances and no focus stealing.
- Software architecture planner: implement window-owned project sessions, project-wide refresh fanout, and operation routing metadata before claiming support.

## Goals

- Let a user open the same `.lungfish` project in multiple app windows in the same process.
- Keep each window's UI state independent: sidebar selection, search, expansion, active document, viewer zoom/scroll, inspector tab, drawer state, table filters, selected taxon, selected contig, and pending dialog state.
- Share project contents across windows: project metadata, on-disk bundles, provenance sidecars, search index, project-wide operations, and file change notifications.
- Route every project mutation and async completion through an explicit origin window and canonical project URL.
- Refresh all same-project windows when project contents change, while auto-selecting or focusing new outputs only in the originating window.
- Preserve Lungfish provenance requirements for all scientific data created, imported, transformed, exported, or wrapped by GUI workflows.
- Surface external active/unknown project locks as read-only UI state rather than a hidden log warning.

## Non-Goals

- Multi-user collaborative editing over network storage.
- Cross-process simultaneous write support.
- A full `NSDocument` rewrite.
- Automatic linked navigation between windows. Linked navigation can be added later as an explicit opt-in mode.
- Persisting per-window navigation or filters into portable bundle state by default. Portable `.viewstate.json` should not become a last-window-wins scratchpad.

## Real-World Workflows

### Variant Review

A user reviews a VCF table in one window while inspecting the reference bundle, BAM pileup, coverage, and caller provenance in another. Each window needs independent filters, row selection, coordinate zoom, and inspector state. Variant export or annotation commands must target the key window's selected variant context.

### Taxonomy Triage and Read Extraction

A user keeps a taxonomy result or sunburst open while extracting taxon-assigned reads and inspecting the newly created FASTQ bundle in a second window. Extraction must snapshot the selected classifier result, taxon IDs, include-children option, source FASTQ paths, checksums, and output target when the user launches the command. Changing a taxon selection in another window while extraction runs must not alter the output.

### Mapping QC and Assembly Review

A user compares mapping coverage, primer trimming, assembly contigs, Nx plots, and remapping results side by side. BAM, BAI, FASTA, and index files must not become selectable while still being written. A rerun should mark dependent results stale when input hashes or provenance generations change.

### FASTQ Preprocessing and Downstream Results

A user trims, deduplicates, demultiplexes, merges, or scrubs FASTQ data in one window while reviewing classification or mapping outputs in another. Derived FASTQ bundles need unique identities, lineage, current/stale status, final-payload provenance, and collision-safe output naming.

### Teaching, Review, and Provenance Audit

An instructor or reviewer can show a provenance panel, methods details, and an output table in separate windows. The Operations panel is not a substitute for durable provenance; provenance viewers must update on sidecar changes and verify final stored payload paths.

## Product Behavior

- `File > Open Project Folder...` continues to open a project in a new window.
- Add `Window > New Window for Current Project` for the common same-project workflow.
- If a user opens an already-open project through an ambiguous path, present a sheet with `Show Existing Window`, `Open Another Window`, and `Cancel`.
- Duplicate windows use distinct titles, for example `ProjectName [1] - Lungfish Genome Explorer` and `ProjectName [2] - Lungfish Genome Explorer`.
- If an external active or unknown project lock exists, append `(Read Only)` to the title and show a persistent banner with tool, mode, user, host, pid, and created time.
- Selection, filters, drawer state, inspector tab, and viewport position remain per-window.
- Project-wide operations appear in a global Operations panel with filters for `All`, `Current Project`, and `Current Window`.
- Operation rows include project name and originating window label.
- Completed operations refresh every open window for the same project. Only the originating window auto-selects or displays the output.
- Conflicting write actions are disabled while a relevant project or bundle operation is running elsewhere, with a direct `View Operation` affordance.

## Architecture

### Project Sessions

Introduce a window-owned `ProjectSession` in `Sources/LungfishApp/StateManagement/ProjectSession.swift`.

The session owns:

- `id`
- `windowStateScope`
- `projectURL`
- `project: ProjectFile?`
- `openWarningState`
- `documents`
- `activeDocument`
- `workingDirectoryURL`

`MainWindowController` receives one `ProjectSession` at initialization and passes it to `MainSplitViewController`, `SidebarViewController`, `ViewerViewController`, and `InspectorViewController` as needed. `DocumentManager.shared` remains temporarily as a compatibility facade for file loading during migration, but project/window state must move out of the singleton before the feature is considered supported.

### Project Registry

Add an app-scoped `ProjectSessionRegistry` that tracks:

- all open project sessions,
- canonical project URLs,
- same-project window numbering,
- frontmost session for legacy menu fallback,
- read-only state from external locks,
- helpers to find all windows for a project.

The registry is the place where `Show Existing Window` vs `Open Another Window` decisions are made.

### Notification Contract

Window-private UI events must carry `windowStateScope` and be ignored by other windows.

Project-wide refresh events must carry canonical `projectURL` and be delivered to every session for that project.

Operation-originated events carry both:

- `projectURL` for fanout,
- `originWindowStateScope` for auto-selection and focus behavior.

Unscoped UI-affecting notifications are not acceptable for this feature. Existing partially scoped events in the sidebar and inspector are the pattern to complete, not the final state.

### Operation Routing

Add an `OperationRoute` value to `OperationCenter.Item` or equivalent operation metadata:

```swift
public struct OperationRoute: Codable, Hashable, Sendable {
    public var projectURL: URL
    public var originWindowStateScope: WindowStateScope
    public var autoSelectOutputs: Bool
}
```

Completion delivery must include output URLs plus route metadata. The current raw `onBundleReady: ([URL]) -> Void` callback is insufficient because it loses the originating window and project context.

### Filesystem Refresh

Create a project refresh coordinator with one watcher per canonical project URL. It fans out changes to registered sessions. Sidebars keep responsibility for preserving their own expansion, selection, and search state.

Sidecar-only changes must update provenance/search/inspector surfaces even when they do not require a full sidebar rebuild.

### Scientific Data Integrity

All project-writing workflows must:

- capture project URL, origin window scope, selected dataset identity, final output target, user-visible options, resolved defaults, input paths, checksums, file sizes, and provenance generation at launch;
- revalidate captured inputs immediately before writing final outputs;
- publish output atomically from temp workspace to final bundle;
- write complete provenance into final bundles/directories;
- mark or block outputs whose provenance is missing, points to staging files, or fails checksum validation.

Missing provenance remains a blocking defect for new scientific outputs.

## Error Handling

- External active/unknown lock: open read-only, show banner, disable project-mutating actions, allow safe browsing and exports outside the project.
- Origin window closed during operation: refresh same-project windows on completion, but do not focus or auto-select in another window.
- Output naming conflict: serialize if same target bundle is being written, otherwise collision-rename with deterministic suffix and record the final name in provenance.
- Selected item deleted or renamed from another window: preserve visible content if possible, show a stale-content banner, and offer reveal/reload actions.
- Provenance missing or invalid: show the operation as failed or warning, do not present the output as a valid derived scientific bundle.

## Acceptance Criteria

- Opening the same project twice creates two independently usable windows with distinct titles.
- The same project can also be opened through `Window > New Window for Current Project`.
- Ambiguous reopen of an already-open project offers focus existing vs open another window.
- Selecting or filtering content in one same-project window does not change selection or filters in the other.
- Commands always apply to the sender/key window's project/session.
- A completed operation refreshes every same-project window but auto-selects output only in the origin window.
- Operation rows identify project and originating window.
- External active/unknown locks force visible read-only UI.
- Missing required provenance blocks success presentation for new scientific outputs.
- Tests cover two same-project sessions, notification scoping, operation routing, refresh fanout, lock read-only state, and one end-to-end XCUITest smoke path.

## Risks

- `DocumentManager.shared` is deeply referenced. The migration must preserve behavior while moving state to sessions incrementally.
- Many `AppDelegate` actions rely on `mainWindowController`. The plan needs explicit sender/key-window routing before more feature work layers onto it.
- Notification scoping is partially implemented. A partial migration could make behavior harder to reason about than today.
- Centralizing filesystem watchers improves architecture but touches sidebar refresh behavior that already handles selection preservation.
- Provenance/currentness enforcement may reveal existing workflows that create outputs before provenance is complete. Those are blocking defects, not regressions in the new feature.
