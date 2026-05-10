# Database Search Operations Dialog Design

## Goal

Refactor the online database search sheet so it uses the same split launcher pattern as Lungfish tool operations, with a left navigation pane for search destinations and a right pane for destination-specific search controls, results, and downloads.

## Scope

This rollout covers:

- Replacing the current stacked database browser layout with the shared operations shell.
- Converting the search destinations into three left-pane entries:
  - `GenBank & Genomes`
  - `SRA Runs`
  - `Pathoplexus`
- Keeping NCBI submodes such as `Nucleotide`, `Genome`, and `Virus` inside the right pane for `GenBank & Genomes`.
- Removing purely decorative glyphs from the database search UI.
- Preserving the existing search services, result parsing, and background download/import pipeline.
- Establishing the first reusable XCUI foundation for menu-driven GUI testing of the app.

This rollout does not cover:

- Changing the underlying NCBI, ENA, or Pathoplexus service implementations.
- Redesigning download/import behavior beyond what is required to fit the shared dialog shell.
- Renaming underlying service types or external API concepts outside the dialog surface.
- Converting the entire app to XCUI in one pass.

## Requirements

### Shared Shell Behavior

- The database search UI must use the same split-shell structure as existing tool operations.
- The left pane must use the same text-first sidebar card treatment as the operations dialog.
- The right pane must use the same general content rhythm as the operations dialog:
  - summary or guidance text
  - primary controls
  - advanced controls
  - result controls
  - results
- The footer must match the operations dialog pattern:
  - left side for readiness or status text
  - right side for `Cancel` and the primary action
- Existing visual-language frameworks, shared styles, and reusable shell components from the launch splash screen and current tool operation dialogs must be reused where they already exist.
- If those surfaces still rely on local one-off styling in places needed by this refactor, the rollout must extract shared launcher-style primitives instead of introducing search-specific styling that cannot be reused.

### Navigation Model

- The left pane must present the three search destinations as top-level entries:
  - `GenBank & Genomes`
  - `SRA Runs`
  - `Pathoplexus`
- These entries must be treated as destinations, not as a taxonomy of sequence types.
- `Nucleotide`, `Genome`, and `Virus` remain right-pane configuration within `GenBank & Genomes`, not separate sidebar entries.
- Switching destinations must preserve each destination's current query text, filters, results, and selection state.

### Visual Similarity Rules

- The refactored search dialog must visually align with the launch splash screen and existing tool operation dialogs.
- Typography, spacing, sidebar selection treatment, card borders, and footer structure must do most of the visual work.
- Decorative glyphs must be removed from the search interfaces.
- Symbols may remain only when they convey real meaning or interaction state, such as:
  - checkboxes
  - progress indicators
  - warnings
  - explicit status markers
- Empty states, filter headers, autocomplete rows, and destination headers should not rely on decorative symbol art.

### Search and Result Behavior

- Each destination must keep its current functional capabilities:
  - `GenBank & Genomes`: NCBI search modes, advanced filters, and downloads
  - `SRA Runs`: accession import, SRA search, ENA-backed result resolution, and downloads
  - `Pathoplexus`: consent flow, organism selection, filters, results, and downloads
- Existing search progress, pagination, result filtering, selection, and download progress must continue to work after the UI refactor.
- The sheet must still dismiss when a download is launched, with background processing continuing through the existing import path.

### XCUI Foundation Requirements

- This rollout must add a real Xcode UI-test harness for the app, not just package-level unit tests with UI-facing names.
- The first GUI tests must drive the real menu path for opening online database searches rather than relying on direct controller injection.
- UI-test launches must support a deterministic test mode enabled by launch arguments or environment, so GUI tests do not depend on live NCBI, ENA, or Pathoplexus responses.
- The test-mode hook must be designed as reusable app infrastructure rather than a database-search-specific hack.
- Database search must become the first consumer of that infrastructure, not its only intended consumer.
- The database-search surface must expose stable accessibility identifiers for XCUI, following a naming convention that can be reused throughout the app.
- The test fixture and scenario mechanism must support named scenarios so later app features can add their own GUI fixtures without rewriting the harness.

## Architecture

### 1. Shared Dialog Wrapper

Use the existing `DatasetOperationsDialog` as the outer shell for the database search UI.

This yields:

- a consistent left navigation pane
- a consistent right content pane
- a consistent footer
- minimal new shell-specific styling

The database search refactor must adapt itself to the shared shell instead of building another bespoke sheet.

Where the welcome screen or operations surfaces already define the desired visual treatment, the refactor must consume those shared assets directly. Where the treatment exists only inline in one surface, the refactor must extract the minimum shared primitives needed so the database search dialog and future launcher-style tools can use the same visual language.

### 2. Search Dialog State Model

Introduce a dedicated state object for the refactored dialog, parallel in intent to the FASTQ operations dialog state.

The state object owns:

- selected destination
- destination-specific form state
- NCBI submode state for `GenBank & Genomes`
- search phase and status text
- search results
- filtered results
- selected records
- download state

This state object must centralize UI state while delegating provider-specific query construction and service calls to focused helpers or methods.

### 3. Destination-Specific Right Panes

Split the current monolithic database browser view into destination-oriented right-pane views:

- `GenBankGenomesSearchPane`
- `SRARunsSearchPane`
- `PathoplexusSearchPane`

These panes must share common building blocks for the sections that are structurally the same:

- query bar
- advanced filters container
- results toolbar
- results list
- empty state
- progress state
- error state

The goal is not to force all three destinations into identical controls, but to make them feel like three tools inside the same launcher.

### 4. Thin AppKit Wrapper

Keep `DatabaseBrowserViewController` as a thin AppKit host and sheet integration layer.

It must be responsible for:

- wiring the SwiftUI root view
- applying the initial destination when needed
- keeping the cancel and download-start callbacks
- presenting the sheet through the existing app entry points

It must stop owning a giant all-in-one SwiftUI implementation.

### 5. UI-Test Configuration Layer

Add a small app-level UI-test configuration surface that reads launch arguments and environment at startup.

This layer must:

- detect whether the app is running under XCUI
- expose a stable way to select named test scenarios
- remain inert during normal launches
- be reusable by future app features that need deterministic GUI fixtures

The first use of this layer is database search, but it must be framed as shared app infrastructure.

### 6. Search Backend Injection

Replace direct construction of remote database services inside the browser flow with a small backend or provider abstraction.

The default implementation must keep using the real NCBI, ENA, and Pathoplexus services.

The UI-test implementation must:

- return deterministic search results for named scenarios
- support consent-gated Pathoplexus behavior
- provide predictable selection and download-ready transitions
- avoid real network calls and real background downloads during XCUI

This abstraction should be scoped so future GUI-tested app surfaces can follow the same pattern: production backend by default, deterministic test backend when UI-test mode is enabled.

## Components

### Sidebar Items

Define sidebar items using the same model shape as the shared operations dialog:

- title
- subtitle
- availability or status text when relevant

Recommended subtitles:

- `GenBank & Genomes`
  - `Nucleotide, assembly, and virus records from NCBI`
- `SRA Runs`
  - `Sequencing runs and FASTQ availability`
- `Pathoplexus`
  - `Open pathogen records and surveillance metadata`

### Shared Right-Pane Sections

Each destination pane must follow the same broad structure:

1. summary text
2. primary search controls
3. optional advanced controls
4. results controls
5. results list or empty state

This keeps the search experiences recognizable as siblings even when their actual fields differ.

### Destination-Specific Sections

- `GenBank & Genomes`
  - NCBI mode selector for `Nucleotide`, `Genome`, `Virus`
  - NCBI-specific filters and search settings
- `SRA Runs`
  - accession import support
  - SRA-specific filters
  - ENA-backed run result handling
- `Pathoplexus`
  - consent screen when required
  - organism selector
  - Pathoplexus-specific filters

### XCUI Identifier Surface

The database-search dialog must define stable identifiers for the first XCUI flows, including:

- sheet root
- sidebar container
- `GenBank & Genomes` destination row
- `SRA Runs` destination row
- `Pathoplexus` destination row
- shared search field
- shared primary footer button
- shared status text
- results list
- Pathoplexus consent accept button
- Pathoplexus consent cancel button
- any destination-specific controls needed for the initial flows, such as the NCBI mode selector

Identifier names should follow a consistent app-wide convention so later XCUI expansion does not create feature-by-feature naming drift.

## Data Flow

### Search

1. User selects a destination in the left pane.
2. The right pane binds to that destination's stored state.
3. User edits query and filters.
4. State builds the appropriate search request.
5. Existing service code performs the search.
6. Results, progress, and errors flow back into the same shared dialog state.

### Destination Switching

1. User switches from one destination to another.
2. Shared dialog state changes the selected destination only.
3. Each destination restores its own previously entered query, filters, results, and row selection.
4. No cross-destination state should leak or be silently reset unless the destination itself requires it.

### Download

1. User selects result rows in the right pane.
2. User triggers download through the shared footer action.
3. Existing download and import code runs unchanged.
4. The sheet dismisses immediately after the download starts, matching current behavior.

## Error Handling

- Search errors must remain destination-specific and readable in the shared footer or right-pane status area.
- Destination switching must not clear an error for another destination unless that destination is re-run or manually reset.
- Consent-gated flows such as Pathoplexus must continue to block search interaction until the consent requirement is satisfied.
- Large-result confirmation flows must remain intact after the shell migration.

## Testing

Add or update coverage for:

- left-pane destination routing using the shared dialog shell
- preservation of per-destination query and filter state across navigation changes
- continued support for NCBI submode switching inside `GenBank & Genomes`
- continued support for SRA accession import flow
- continued support for Pathoplexus consent gating
- footer status and primary action behavior across searching, idle, and download-ready states
- regression checks ensuring decorative, non-semantic glyphs are not reintroduced into the shared search shell
- app-driven XCUI launch of the real menu path to `Search Online Databases`
- menu-driven opening of each top-level search destination
- Pathoplexus consent gating in XCUI
- a deterministic end-to-end search flow in XCUI that transitions from `Search` to `Download Selected`
- preservation of per-destination query state when switching sidebar destinations in XCUI

XCUI tests in this rollout should prioritize stable user-journey coverage over exhaustive permutation testing.

The first XCUI slice should prove the harness is reusable:

- shared launch helper
- shared menu-navigation helper
- named fixture or scenario selection
- stable accessibility identifiers

This rollout does not need to add GUI coverage for the whole app, but it must leave behind the reusable foundation for doing so.

## Rollout Notes

- Implement this work in an isolated worktree and branch so it can merge cleanly alongside unrelated UI work already in progress on `main`.
- Prefer extracting reusable destination-specific panes and shared subviews over leaving a single monolithic search view in place.
- Keep the current search services and import pipeline stable while the UI shell changes.
- Match the existing operations dialog and welcome-splash visual language so the search browser no longer reads as a special-case surface.
- Treat this refactor as an opportunity to strengthen shared launcher-style UI infrastructure: reuse existing framework pieces first, then extract missing ones into reusable components or styling primitives rather than hard-coding them inside the database search dialog.
- Treat the XCUI work the same way: prefer reusable app-wide test infrastructure, reusable identifiers, and reusable scenario plumbing over database-search-only shortcuts.
