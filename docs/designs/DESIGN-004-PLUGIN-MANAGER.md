# Plugin Manager Interface Design

**Document ID:** DESIGN-004-PLUGIN-MANAGER
**Date:** 2026-03-22
**Status:** Design Proposal
**Author:** UX Research / UI Architecture

---

## 1. Research Context and Design Rationale

### 1.1 Existing Codebase Constraints

The design is grounded in the current Lungfish architecture:

- **Settings window** (`SettingsWindowController.swift`): A SwiftUI `TabView` hosted in an `NSWindow` with four tabs (General, Appearance, Rendering, AI Services). Frame: 550x460 min, 680x560 ideal. Uses `.formStyle(.grouped)`.
- **Plugin system** (`LungfishPlugin/`): Built-in plugins registered via `PluginRegistry.shared` (ORFFinder, PatternSearch, RestrictionSiteFinder, SequenceStatistics, Translation, ReverseComplement). Categories defined in `PluginCategory` enum. Plugins have `id`, `name`, `version`, `description`, `category`, `capabilities`, `iconName`.
- **Tool provisioning** (`LungfishWorkflow/Native/ToolProvisioning/`): `ToolProvisioningOrchestrator` provisions tools via `BinaryDownloadProvisioner` and `SourceCompilationProvisioner`. Progress reported through `ProvisioningProgress` struct with phases (downloading, extracting, configuring, compiling, installing, verifying, complete, failed). Dependency resolution built in.
- **Container images** (`ContainerImageRegistry`, `DefaultContainerImages`): Core and optional image specs with `ImageCategory` (.core, .optional, .custom) and `ImagePurpose` (.indexing, .conversion, .compression, .alignment, .variantCalling, .assembly, .qualityControl, .annotation, .visualization, .general).
- **Bundled tools** (`BundledToolSpec`): htslib, samtools, bcftools, ucsc-tools already defined with `LicenseInfo`, `ProvisioningMethod`, dependency chains.
- **Window precedents**: `AboutWindowController` (420x500, titled+closable), `ThirdPartyLicensesWindowController` (600x520, titled+closable+resizable), `SettingsWindowController` (550x460, full chrome). All follow `@MainActor final class` pattern.
- **Menu structure** (`MainMenu.swift`): Application, File, Edit, View, Sequence, Tools, Operations, Window, Help.

### 1.2 User Research Insights (from Reference Application Analysis)

| Reference App | Key Pattern | What Works | What Does Not |
|---|---|---|---|
| Geneious Plugin Manager | Separate window, category sidebar, one-click install | Clear separation of concerns; browsing feels dedicated | Can feel disconnected from main workflow |
| VS Code Extensions | Sidebar panel in main window, search-first | Always accessible; search is fast | Dense information; overwhelming for new users |
| Xcode Components | Nested in Settings > Platforms/Components | Discoverable via standard path | Hidden; users forget it exists |
| macOS System Settings > Extensions | Toggle switches per app | Simple enable/disable | No install/browse capability |

### 1.3 Target User Segments

| Segment | Need | Behavior |
|---|---|---|
| Bench scientists | Install a recommended workflow pack and never think about tools again | Browse by workflow, one-click install packs |
| Bioinformaticians | Cherry-pick specific tool versions, understand dependencies | Search by name, inspect versions and deps |
| Core facility staff | Standardize tool sets across machines | Export/import tool manifests, verify installed state |
| Students | Follow a course protocol that names specific tools | Search, install exactly what the instructor listed |

---

## 2. Architecture Decision: Separate Window

### 2.1 Recommendation

**A dedicated Plugin Manager window**, opened from **Tools > Plugin Manager** (keyboard shortcut: Cmd+Shift+P).

### 2.2 Justification

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| Tab in Settings | Discoverable via Cmd+, | Settings tabs are small (550px wide); cannot fit sidebar+detail. Cramped for browsing 50+ tools. Violates HIG: settings are for preferences, not for browsing/installing content. | Rejected |
| Sheet from main window | Modal focus | Blocks the main workspace; cannot reference documentation while installing. Multi-step installs feel trapped. | Rejected |
| Floating panel | Non-modal, always accessible | Panels are for transient reference (inspector, color picker). Plugin management is a discrete task, not a persistent overlay. | Rejected |
| **Separate window** | Full layout control; non-modal; can be open alongside main window; matches Geneious precedent; natural for browse/search/install workflow | One more window to manage | **Selected** |

### 2.3 Window Specification

```
NSWindow Configuration:
  contentRect:    NSRect(x: 0, y: 0, width: 780, height: 540)
  styleMask:      [.titled, .closable, .miniaturizable, .resizable]
  minSize:        NSSize(width: 640, height: 440)
  title:          "Plugin Manager"
  frameAutosave:  "PluginManagerWindow"
  toolbar:        Yes (search field in toolbar)
```

This matches the macOS HIG pattern for "manager" or "library" windows (similar to Font Book, Audio MIDI Setup, or Geneious Plugin Manager). The window is resizable to accommodate users who want to see more tools at once.

---

## 3. Layout Architecture

### 3.1 Top-Level Structure

```
+============================================================================+
| Plugin Manager                                               [-][_][x]     |
+============================================================================+
| [Toolbar]                                    [______Search tools..._____]  |
+============================================================================+
|                        |                                                   |
|   SIDEBAR (200pt)      |   CONTENT AREA                                    |
|   (source list style)  |                                                   |
|                        |                                                   |
|   All Tools            |   +---------------------------------------------+|
|   Installed            |   | [Segmented: Installed | Available | Updates] ||
|                        |   +---------------------------------------------+|
|   CATEGORIES           |                                                   |
|   > Alignment          |   +---+ +-------------------------------+ +-----+||
|   > Assembly           |   |   | | Tool Name              v1.21 | |     |||
|   > Compression        |   |icn| | Brief description text here  | | Inst|||
|   > Conversion         |   |   | | bioconda  MIT  ~45 MB        | | all |||
|   > Indexing           |   +---+ +-------------------------------+ +-----+||
|   > Quality Control    |                                                   |
|   > Variant Calling    |   +---+ +-------------------------------+ +-----+||
|   > Annotation         |   |   | | Another Tool            v2.1 | |     |||
|   > Visualization      |   |icn| | Description of this tool     | | Inst|||
|   > General            |   |   | | bioconda  Apache-2.0  ~120MB | | all |||
|                        |   +---+ +-------------------------------+ +-----+||
|   TOOL PACKS           |                                                   |
|   > Essentials         |   ... (scrollable list of tool cards)             |
|   > NGS Alignment      |                                                   |
|   > De Novo Assembly   |                                                   |
|   > QC Pipeline        |                                                   |
|                        |                                                   |
+------------------------+---------------------------------------------------+
|                        STATUS BAR                                          |
| 12 tools installed  |  3 updates available  |  micromamba ready            |
+============================================================================+
```

### 3.2 Sidebar (Source List)

The sidebar uses the macOS source list style (`NSOutlineView` with `.sourceList` style, or SwiftUI `List` with `.sidebar` listStyle). It contains three groups:

**Group 1: Views** (no header, top-level items)

| Item | SF Symbol | Behavior |
|---|---|---|
| All Tools | `square.grid.2x2` | Shows every tool (installed + available) |
| Installed | `checkmark.circle` | Filters to installed tools only |

**Group 2: Categories** (header: "Categories")

These map directly to `ImagePurpose` values from the existing `ContainerImageRegistry`, extended for the plugin manager context:

| Category | SF Symbol | Maps to `ImagePurpose` |
|---|---|---|
| Alignment | `arrow.triangle.branch` | `.alignment` |
| Assembly | `cube.transparent` | `.assembly` |
| Compression | `archivebox` | `.compression` |
| Conversion | `arrow.triangle.2.circlepath` | `.conversion` |
| Indexing | `list.number` | `.indexing` |
| Quality Control | `checkmark.shield` | `.qualityControl` |
| Variant Calling | `waveform.path.ecg` | `.variantCalling` |
| Annotation | `tag` | `.annotation` |
| Visualization | `chart.xyaxis.line` | `.visualization` |
| General | `wrench.and.screwdriver` | `.general` |

**Group 3: Tool Packs** (header: "Tool Packs")

| Pack | SF Symbol | Description |
|---|---|---|
| Essentials | `star` | Core tools every user needs (samtools, bcftools, htslib, bgzip, tabix) |
| NGS Alignment | `arrow.right.arrow.left` | Short and long read alignment (bwa, minimap2, samtools) |
| De Novo Assembly | `puzzlepiece` | Genome assembly workflow (spades, minimap2, samtools) |
| QC Pipeline | `gauge.with.needle` | Quality control suite (fastqc, multiqc) |

### 3.3 Content Area

The content area changes based on sidebar selection. It has two modes:

**Mode A: Tool List** (when a category, view, or search is active)

A vertically scrolling list of **tool cards**. At the top of the content area is a segmented control for filtering:

```
[Segmented Control: Installed | Available | Updates]
```

- **Installed**: Shows only tools currently installed, with Remove buttons.
- **Available**: Shows tools not yet installed, with Install buttons.
- **Updates**: Shows installed tools that have newer versions available, with Update buttons.

When "All Tools" is selected in the sidebar, all three segments are relevant. When a specific category is selected, the list is pre-filtered to that category.

**Mode B: Tool Pack Detail** (when a tool pack is selected)

Shows a pack header with description, followed by the list of included tools with their individual install states. The pack has a single "Install All" button that queues all missing tools.

### 3.4 Toolbar

The toolbar contains a single element:

```
[Flexible Space] [NSSearchField: "Search tools..."]
```

The search field filters the tool list in real-time by name, description, or executable name. It follows the standard NSSearchField behavior with recents and cancel button.

When the search field has content, the sidebar selection is overridden and the content area shows search results across all categories. The sidebar highlights "All Tools" with a search badge. Clearing the search field returns to the previous sidebar selection.

### 3.5 Status Bar

A thin bar at the bottom of the window showing:

```
[tool_count] tools installed  |  [update_count] updates available  |  [runtime_status]
```

Where `[runtime_status]` is one of:
- "micromamba ready" (green dot)
- "micromamba not found" (orange warning triangle)
- "Installing micromamba..." (spinner)

---

## 4. Tool Card Design

### 4.1 Standard Tool Card Layout

Each card is a single row in the list, approximately 64pt tall:

```
+---+  +--------------------------------------------------+  +-----------+
|   |  | Tool Display Name                       v1.21    |  |           |
|icn|  | Brief one-line description of what the tool does  |  |  Install  |
|   |  | bioconda  *  MIT  *  ~45 MB  *  arm64             |  |           |
+---+  +--------------------------------------------------+  +-----------+
 44pt                    flexible                              88pt
```

**Left column (44pt)**: Category icon using the SF Symbol from the category mapping above. Rendered at 24pt in `.secondary` label color. If the tool is installed, a small green checkmark badge overlays the bottom-right corner of the icon (12pt, `checkmark.circle.fill` in `.systemGreen`).

**Center column (flexible)**: Three lines of text.

- **Line 1**: Tool display name (`.headline` weight `.semibold`) + version string (`.subheadline`, `.secondary` color, right-aligned via spacer).
- **Line 2**: Description (`.subheadline`, `.secondary` color, single line, truncated with ellipsis).
- **Line 3**: Metadata badges, separated by interpuncts. Each badge uses `.caption` weight and system secondary color:
  - **Channel**: "bioconda" or "conda-forge" (text badge with subtle background)
  - **License**: SPDX identifier from `LicenseInfo.spdxId` (e.g., "MIT", "Apache-2.0", "GPL-3.0")
  - **Size**: Estimated install size (derived from `estimatedSizeBytes`)
  - **Architecture**: "arm64" or "x86_64" or "universal" (from `supportedArchitectures`)

**Right column (88pt)**: Action button, one of:

| State | Button Label | Style | Behavior |
|---|---|---|---|
| Not installed | "Install" | `.borderedProminent` (accent color) | Begins installation |
| Installing | [ProgressView] | Circular determinate progress | Shows phase and percentage |
| Installed | "Remove" | `.bordered` (destructive, secondary) | Confirms then removes |
| Update available | "Update" | `.borderedProminent` (accent color) | Begins update |
| Failed | "Retry" | `.bordered` (warning) | Retries last operation |

### 4.2 Expanded Tool Card (on selection)

When a tool card is selected (single click), the card expands in-place to show additional detail:

```
+---+  +--------------------------------------------------+  +-----------+
|   |  | SAMtools                                 v1.21   |  |           |
|icn|  | Tools for manipulating alignments in SAM/BAM/    |  |  Remove   |
|   |  | CRAM format and FASTA indexing                    |  |           |
+---+  +--------------------------------------------------+  +-----------+
       |                                                   |
       |  Executables:  samtools                           |
       |  Channel:      bioconda                           |
       |  License:      MIT/Expat (permissive)     [View]  |
       |  Install size: ~45 MB                             |
       |  Dependencies: htslib (v1.21)                     |
       |  Architecture: arm64, x86_64                      |
       |  Documentation:               [Open in Browser]   |
       |                                                   |
       +---------------------------------------------------+
```

The expanded section shows:

- **Executables**: List of command-line executables provided (from `BundledToolSpec.executables` or `ContainerImageSpec`).
- **Channel**: Source repository (bioconda, conda-forge, custom).
- **License**: Full SPDX ID + summary text from `LicenseInfo.summary`. A "View" link opens the license URL (from `LicenseInfo.url`) in the default browser.
- **Install size**: Human-readable size from `estimatedSizeBytes`.
- **Dependencies**: List of dependency names with versions. Each dependency name is clickable (scrolls to that tool in the list). Dependencies that are already installed show a green checkmark. Missing dependencies show an orange warning.
- **Architecture**: From `supportedArchitectures`. If x86_64-only on Apple Silicon, show "x86_64 (via Rosetta 2)" with an info tooltip.
- **Documentation**: "Open in Browser" button that opens `documentationURL`.

### 4.3 Tool Card States

| Visual State | Card Appearance |
|---|---|
| Available, not installed | Standard card, "Install" button prominent |
| Installing | Card background has subtle blue tint. Progress indicator replaces button. Phase text below progress ("Downloading...", "Compiling..."). |
| Installed | Faint green left-border accent (2pt). Green checkmark badge on icon. "Remove" button in secondary style. |
| Update available | Faint orange left-border accent (2pt). "Update" button in prominent style. Old and new version shown. |
| Failed | Faint red left-border accent (2pt). Error message in `.caption` red text below card. "Retry" button. |
| Dependency missing | "Install" button disabled. Tooltip: "Requires [dependency] to be installed first." |

---

## 5. Tool Pack Design

### 5.1 Pack Detail View

When a tool pack is selected in the sidebar, the content area shows a pack detail view instead of the standard tool list:

```
+====================================================================+
|                                                                    |
|  [star.fill]  Essentials Pack                                      |
|                                                                    |
|  The core bioinformatics tools every Lungfish user needs.          |
|  Includes file indexing, compression, format conversion, and       |
|  variant manipulation tools.                                       |
|                                                                    |
|  5 tools  *  ~180 MB total  *  3 of 5 installed                   |
|                                                                    |
|  +------------------------------------------------------------+   |
|  |  [=========================       ]  Installing 2 of 5...  |   |
|  +------------------------------------------------------------+   |
|                                                                    |
|  [          Install Missing (2)          ]                         |
|  [          Remove All                   ]                         |
|                                                                    |
+====================================================================+
|                                                                    |
|  Included Tools:                                                   |
|                                                                    |
|  [checkmark.circle.fill green] samtools     v1.21   Installed     |
|  [checkmark.circle.fill green] bcftools     v1.21   Installed     |
|  [checkmark.circle.fill green] htslib       v1.21   Installed     |
|  [circle.dashed]               bgzip        v1.21   Not installed |
|  [circle.dashed]               tabix        v1.21   Not installed |
|                                                                    |
+====================================================================+
```

### 5.2 Pack Behavior

- **"Install Missing (N)"**: Queues all uninstalled tools in dependency order. Button label dynamically shows count. Disabled when all tools are installed (label changes to "All Installed" with checkmark).
- **"Remove All"**: Confirmation alert before removing. Only enabled when at least one tool is installed.
- **Progress**: Aggregate progress bar during pack installation. Shows "Installing N of M..." with the current tool name.
- **Individual tools in the list**: Each tool is a mini-card (single line) that is clickable to navigate to the full tool card in "All Tools" view.

### 5.3 Predefined Packs

| Pack ID | Display Name | SF Symbol | Tools | Description |
|---|---|---|---|---|
| `essentials` | Essentials | `star` | samtools, bcftools, htslib, bedToBigBed, bedGraphToBigWig | Core tools for reference bundle creation |
| `ngs-alignment` | NGS Alignment | `arrow.right.arrow.left` | bwa, minimap2, samtools | Short and long read alignment pipeline |
| `de-novo-assembly` | De Novo Assembly | `puzzlepiece` | spades, minimap2, samtools | Genome assembly from raw reads |
| `qc-pipeline` | QC Pipeline | `gauge.with.needle` | fastqc, multiqc | Sequencing quality control and reporting |

---

## 6. Installation UX

### 6.1 Installation Flow

```
User clicks "Install"
        |
        v
[Resolve dependencies]
        |
        +--> Dependencies missing?
        |         |
        |         v  YES
        |    Show confirmation:
        |    "Installing samtools also requires htslib (v1.21).
        |     Install both? [Cancel] [Install All]"
        |         |
        |         v
        +--> Queue installations in dependency order
        |
        v
[Per-tool progress in card]
  Phase 1: "Downloading..."    (0% - 40%)
  Phase 2: "Extracting..."     (40% - 50%)
  Phase 3: "Configuring..."    (50% - 60%)
  Phase 4: "Compiling..."      (60% - 85%)
  Phase 5: "Installing..."     (85% - 95%)
  Phase 6: "Verifying..."      (95% - 100%)
        |
        v
[Complete]
  Card transitions to "Installed" state
  Status bar updates count
  Notification: "samtools v1.21 installed successfully"
```

### 6.2 Progress Indicators

**Per-tool progress**: Each tool card in the "Installing" state shows a circular determinate `ProgressView` in the action button area, with the phase name below it in `.caption` text. The progress percentage maps to `ProvisioningProgress.progress`.

**Aggregate progress** (for pack installs): A linear `ProgressView` at the top of the pack detail view. Shows overall completion across all tools in the pack.

**Background installation**: Installations continue even if the Plugin Manager window is closed. A badge on the Tools menu item indicates active installations. Re-opening the Plugin Manager shows current progress.

### 6.3 Queue and Cancellation

- Multiple tool installations are queued and processed sequentially (respecting dependency order).
- Each installation can be cancelled individually by clicking the progress indicator (which shows a small X on hover).
- Cancelling a tool that is a dependency of a queued tool cancels the dependent tool as well, with a confirmation: "Cancelling htslib will also cancel samtools. Continue?"
- The queue is visible in the status bar: "Installing: htslib (1 of 3)..."

### 6.4 Error Handling

| Error Scenario | User-Facing Message | Recovery |
|---|---|---|
| Network failure | "Download failed: unable to reach bioconda. Check your internet connection." | Retry button on card |
| Checksum mismatch | "Verification failed for samtools. The download may be corrupted." | Retry (re-downloads) |
| Compilation failure | "Build failed for htslib. See details for the error log." | Expandable error log in card detail; Retry button |
| Disk space | "Not enough disk space to install SPAdes (~1.5 GB required)." | No retry; user must free space |
| Dependency failure | "Cannot install samtools: dependency htslib failed to install." | Fix dependency first, then retry |

Error details are expandable within the tool card (a disclosure triangle reveals the error log text in a monospaced scrollable text view, max 200pt tall).

---

## 7. Uninstall UX

### 7.1 Single Tool Removal

```
User clicks "Remove" on installed tool
        |
        v
[Check reverse dependencies]
        |
        +--> Other tools depend on this?
        |         |
        |         v  YES
        |    Show confirmation:
        |    "samtools and bcftools depend on htslib.
        |     Removing htslib will also remove them.
        |     Remove all 3 tools? [Cancel] [Remove All]"
        |         |
        v
[Confirmation alert]
  "Remove samtools v1.21?
   This will free approximately 45 MB.
   [Cancel] [Remove]"
        |
        v
[Remove tool files]
  Brief spinner on card
        |
        v
[Complete]
  Card transitions to "Available" state
  Status bar updates count
```

### 7.2 Core Tool Warning

If the user attempts to remove a core tool (samtools, bcftools, htslib, bedToBigBed, bedGraphToBigWig), show an additional warning:

```
"samtools is a core tool required for reference bundle creation.
 Removing it may prevent some Lungfish features from working.

 [Cancel] [Remove Anyway]"
```

---

## 8. Search UX

### 8.1 Search Behavior

The toolbar search field (`NSSearchField`) provides instant filtering:

- **Searches across**: tool name, display name, description, executable names, channel name.
- **Debounce**: 150ms after last keystroke before filtering.
- **Results**: Content area shows matching tools from all categories. Category sidebar shows match counts next to each category name: "Alignment (2)".
- **Empty state**: When no results match, show centered placeholder: "No tools matching '[query]'" with suggestion: "Try searching by tool name (e.g., 'samtools') or function (e.g., 'alignment')."
- **Clearing**: Press Escape or click the X in the search field to clear and return to previous sidebar selection.

### 8.2 Search Result Ranking

Results are ranked by relevance:
1. Exact name match (highest)
2. Name prefix match
3. Executable name match
4. Description keyword match (lowest)

Within each relevance tier, installed tools sort before available tools.

---

## 9. macOS 26 HIG Compliance

### 9.1 Window Chrome

- Standard title bar with traffic lights.
- Window title: "Plugin Manager" (follows HIG naming: noun phrase describing content).
- Resizable with `minSize` constraint to prevent layout collapse.
- `setFrameAutosaveName` for position persistence.
- No full-screen support (not a document window).

### 9.2 Typography

| Element | Font | Weight | Size |
|---|---|---|---|
| Tool name | `.headline` | `.semibold` | System default (13pt) |
| Version | `.subheadline` | `.regular` | System default (11pt) |
| Description | `.subheadline` | `.regular` | System default (11pt) |
| Metadata badges | `.caption` | `.regular` | System default (10pt) |
| Sidebar items | Default source list | System default | System default |
| Pack title | `.title2` | `.bold` | System default (17pt) |
| Status bar | `.caption` | `.regular` | System default (10pt) |

All typography uses the system font (SF Pro) via SwiftUI semantic styles. No hardcoded font names or sizes.

### 9.3 Colors

| Element | Color |
|---|---|
| Tool card background | `.clear` (inherits list background) |
| Installed accent border | `Color.green.opacity(0.4)` (2pt leading edge) |
| Update accent border | `Color.orange.opacity(0.4)` (2pt leading edge) |
| Failed accent border | `Color.red.opacity(0.4)` (2pt leading edge) |
| Installing tint | `Color.accentColor.opacity(0.05)` (card background) |
| Metadata text | `.secondary` label color |
| Status bar background | `.separator` opacity over window background |
| Sidebar selection | System highlight color (automatic) |

All colors adapt automatically to light/dark mode via system semantic colors.

### 9.4 SF Symbols Reference

Complete symbol inventory for the Plugin Manager:

| Usage | SF Symbol Name | Rendering Mode |
|---|---|---|
| All Tools (sidebar) | `square.grid.2x2` | Monochrome |
| Installed (sidebar) | `checkmark.circle` | Monochrome |
| Alignment category | `arrow.triangle.branch` | Monochrome |
| Assembly category | `cube.transparent` | Monochrome |
| Compression category | `archivebox` | Monochrome |
| Conversion category | `arrow.triangle.2.circlepath` | Monochrome |
| Indexing category | `list.number` | Monochrome |
| Quality Control category | `checkmark.shield` | Monochrome |
| Variant Calling category | `waveform.path.ecg` | Monochrome |
| Annotation category | `tag` | Monochrome |
| Visualization category | `chart.xyaxis.line` | Monochrome |
| General category | `wrench.and.screwdriver` | Monochrome |
| Essentials pack | `star` | Monochrome |
| NGS Alignment pack | `arrow.right.arrow.left` | Monochrome |
| De Novo Assembly pack | `puzzlepiece` | Monochrome |
| QC Pipeline pack | `gauge.with.needle` | Monochrome |
| Installed badge (overlay) | `checkmark.circle.fill` | Hierarchical (green) |
| Not installed indicator | `circle.dashed` | Monochrome |
| Update available badge | `arrow.up.circle.fill` | Hierarchical (orange) |
| Error badge | `exclamationmark.triangle.fill` | Hierarchical (red) |
| Status: ready | `circle.fill` | Monochrome (green, 6pt) |
| Status: warning | `exclamationmark.triangle` | Monochrome (orange) |
| Status: installing | `progress.indicator` | N/A (use ProgressView) |
| Open documentation | `safari` | Monochrome |
| License link | `doc.text` | Monochrome |

### 9.5 Accessibility

- All tool cards are accessible as grouped elements with `.accessibilityLabel` combining tool name, version, and install state.
- Action buttons have `.accessibilityHint` describing the action ("Double-tap to install samtools version 1.21").
- Progress indicators announce phase changes via `.accessibilityValue` ("Downloading, 45 percent").
- Sidebar categories have `.accessibilityLabel` including item count ("Alignment, 3 tools").
- Search field: standard `NSSearchField` accessibility is inherited.
- Keyboard navigation: Tab moves between sidebar, search field, content area. Arrow keys navigate within the tool list. Return activates the action button on the selected card.
- Minimum touch target: 44x44pt for all interactive elements.
- Color is never the sole indicator of state (badges + text labels + icons all reinforce state).

### 9.6 Dark Mode

No special handling required. All colors use semantic system colors that automatically adapt. The source list sidebar inherits the system source list background. Card accents use opacity-based colors that work in both modes.

---

## 10. CLI Parity

### 10.1 Shared Backend

Both the GUI Plugin Manager and the CLI `lungfish tools` command share the same backend:

```
GUI (Plugin Manager Window)          CLI (lungfish tools)
         |                                    |
         v                                    v
    PluginManagerViewModel        ToolsCommand (ArgumentParser)
         |                                    |
         +------------------------------------+
         |
         v
    ToolProvisioningOrchestrator (actor)
         |
         v
    ToolProvisioner protocol implementations
    (BinaryDownloadProvisioner, SourceCompilationProvisioner)
```

The `ToolProvisioningOrchestrator` is already an actor with progress reporting via `@Sendable` callbacks. The GUI wraps this in a `PluginManagerViewModel` that translates progress into `@Observable` state for the SwiftUI view layer.

### 10.2 State Synchronization

Tool installation state is stored on disk (the presence of executables in the tools directory, verified by `ToolProvisioner.isInstalled(in:)`). Both CLI and GUI read the same directory, so they are always in sync. No additional synchronization mechanism is needed.

### 10.3 CLI Commands (for parity)

```
lungfish tools list                  # List all tools with install status
lungfish tools install samtools      # Install a specific tool
lungfish tools install --pack essentials  # Install a tool pack
lungfish tools remove samtools       # Remove a tool
lungfish tools update                # Update all installed tools
lungfish tools search minimap        # Search available tools
lungfish tools info samtools         # Show detailed tool info
```

---

## 11. Implementation Plan

### 11.1 New Files

| File | Module | Purpose |
|---|---|---|
| `PluginManagerWindowController.swift` | LungfishApp | NSWindowController hosting SwiftUI content |
| `PluginManagerView.swift` | LungfishApp | Root SwiftUI view (NavigationSplitView) |
| `PluginManagerSidebar.swift` | LungfishApp | Sidebar with categories and packs |
| `ToolListView.swift` | LungfishApp | Scrolling list of tool cards |
| `ToolCardView.swift` | LungfishApp | Individual tool card component |
| `ToolPackDetailView.swift` | LungfishApp | Pack detail view |
| `PluginManagerViewModel.swift` | LungfishApp | Observable view model for state management |
| `ToolPack.swift` | LungfishWorkflow | Tool pack definitions |
| `PluginManagerStatusBar.swift` | LungfishApp | Bottom status bar component |

### 11.2 Modified Files

| File | Change |
|---|---|
| `MainMenu.swift` | Add "Plugin Manager..." item to Tools menu with Cmd+Shift+P |
| `AppDelegate.swift` | Add `pluginManagerWindowController` property and `showPluginManager()` method |
| `ToolManifest.swift` | Extend with remote catalog URL for fetching available tools beyond bundled defaults |

### 11.3 SwiftUI View Hierarchy

```
PluginManagerView
  NavigationSplitView
    sidebar:
      PluginManagerSidebar
        List (.sidebar)
          Section "Views"
            NavigationLink "All Tools"
            NavigationLink "Installed"
          Section "Categories"
            ForEach(categories)
              NavigationLink(category)
          Section "Tool Packs"
            ForEach(packs)
              NavigationLink(pack)
    detail:
      if selectedPack != nil:
        ToolPackDetailView
      else:
        VStack
          Picker (segmented: Installed/Available/Updates)
          ToolListView
            ForEach(filteredTools)
              ToolCardView
      StatusBarView (pinned to bottom)
  .searchable(text:, placement: .toolbar)
```

### 11.4 ViewModel Design

```swift
// Conceptual structure (not implementation code)
@Observable @MainActor
final class PluginManagerViewModel {
    // State
    var allTools: [ToolDisplayItem]
    var installedTools: Set<String>
    var activeInstallations: [String: InstallationProgress]
    var searchText: String
    var selectedCategory: ToolCategory?
    var selectedFilter: ToolFilter  // .installed, .available, .updates
    var selectedToolID: String?

    // Computed
    var filteredTools: [ToolDisplayItem]
    var statusText: String
    var runtimeStatus: RuntimeStatus

    // Actions
    func install(toolID: String) async
    func remove(toolID: String) async
    func installPack(packID: String) async
    func cancelInstallation(toolID: String)
    func refreshCatalog() async
}
```

### 11.5 Phased Delivery

**Phase 1**: Window shell + sidebar + tool list with install states (read-only). Display tools from existing `BundledToolSpec.defaultTools` and `DefaultContainerImages.all`. No install/remove yet.

**Phase 2**: Install/remove single tools. Wire up to `ToolProvisioningOrchestrator`. Progress reporting. Error display.

**Phase 3**: Tool packs. Pack definitions. Aggregate progress. "Install Missing" flow.

**Phase 4**: Search. Real-time filtering. Result ranking.

**Phase 5**: Remote catalog. Fetch available tools from a hosted manifest beyond the built-in set. Update checking.

---

## 12. Open Questions for Stakeholder Review

1. **Runtime strategy**: Should the Plugin Manager install tools natively (via `ToolProvisioningOrchestrator` compiling from source / downloading binaries) or via container images (via `ContainerImageRegistry` pulling OCI images)? The codebase supports both. Recommendation: native-first for core tools (faster, no VM overhead), container-based for optional tools that have complex dependencies.

2. **micromamba integration**: The prompt mentions "bioconda package repository via micromamba." The current codebase uses either source compilation or binary download (via `ToolProvisioner`), or container images with `mamba install` inside the container. Should we add a third provisioning path that runs micromamba directly on the host macOS? This would be simpler for many bioconda packages but requires micromamba to be installed on the host.

3. **Custom tool support**: Should users be able to register arbitrary bioconda packages not in the curated catalog? This would require a "Custom" section in the sidebar and a text field for entering package names.

4. **Auto-update policy**: Should the Plugin Manager check for updates on launch? On a schedule? Only when manually triggered? Recommendation: check on launch with a maximum frequency of once per 24 hours, with a user preference to disable.

5. **Tool pack customization**: Should users be able to create their own tool packs (for team standardization)? If so, packs would need an export/import mechanism (JSON manifest).
