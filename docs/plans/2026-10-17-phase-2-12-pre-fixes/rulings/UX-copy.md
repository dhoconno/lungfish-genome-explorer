# UX ruling on Copy Name, the Inspector step overdraw and step copy

Ran as lge-expert on opus (Opus 5.5) at effort max, the UI and UX expert of the panel, field UX, letter U, for the
pre-2.12 fix session. Code read at `c59241aceb2cbedde51482212ccc67928e4e9a45` in the
`laptop-golden-runner-setup-e5434b` worktree on 2026-10-17. Every `path:line` is at that commit. The brief is
`briefs/ux-ruling.md`.

## Rulings at a glance

| Id | Ruling |
|---|---|
| Q-U1 | Something else, built from both options. Each step becomes a disclosure row, collapsed by default. Copy Step runs from a visible copy icon on every step row, from the row's context menu (Copy Step, Copy Command, Copy All Steps), from the same three VoiceOver actions and from Command-C while the step has focus. A visible Copy All Steps button follows the last step. |
| Q-U2 | Plain text only. A title line, then one `Label: value` line per fact the surface shows for that step, in display order, with the command whole on one line. A fact the record does not hold is left out. Copy Command holds the shell-escaped command alone and is the terminal route. |
| Q-U3 | Collapsed shows up to three middle-truncated lines that are not selectable. Expanded shows the whole command in the monospaced Inspector font, selectable and soft-wrapped with no inserted breaks, and the row grows. No Inspector text is selectable while it is truncated. |
| Q-U4 | "Copy Name", directly above Copy Path in the context menu and in Selection > Sidebar Item. It copies each selected row's title as shown, bundles without the package extension, one per line in outline order. No new chord. Command-C runs it while the outline has focus. Every row except a section header qualifies. |
| Q-U5 to Q-U9 | Command-C fallback, three latent overdraw sites, project-relative commands, Copy Path for several rows and the GUI check, ruled at the end. |

## Facts, sidebar

| Id | Fact | Where |
|---|---|---|
| S1 | `SidebarItemAction` is the one list of titles, slugs, chords and selectors that the context menu, the row accessibility actions and Selection > Sidebar Item all read | `Sources/LungfishApp/Views/Sidebar/SidebarItemAction.swift:8-21`, `:49-191` |
| S2 | One availability rule builds all three surfaces. Copy Path sits in the locate section after Show in Finder, for one row and no group row | `Sources/LungfishApp/Views/Sidebar/SidebarViewController+ItemActions.swift:12-25`, `:116-122` |
| S3 | Copy Path writes `url.path` as `.string` to `copyPasteboard` with no feedback, and tests substitute that pasteboard | `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:718-727`, `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift:67-69` |
| S4 | Selection > Sidebar Item is built from `menuSections` with nil targets and identifiers `selection-menu-sidebar-item-<slug>` | `Sources/LungfishApp/App/MainMenu.swift:840-847`, `:874-889`, `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift:227-230` |
| S5 | Each row's custom actions are the single-row subset of the same rule, named by title | `SidebarViewController+ItemActions.swift:196-207`, `Sources/LungfishKit/Accessibility/RowCommand.swift:99-102` |
| S6 | Menu-bar items validate only while the outline has focus, and an action the enum does not know validates true | `SidebarViewController+ItemActions.swift:164-170` |
| S7 | Chords in use. Command-C is Edit > Copy, Command-Shift-C is Copy Visible Region as FASTA, Command-Option-C is Copy CLI Command, Command-Shift-A is Select Siblings and Command-Option-S is Show in Inspector. The app binds each chord once | `MainMenu.swift:408-412`, `:777-782`, `Sources/LungfishApp/Views/Operations/OperationRowAction.swift:88`, `SidebarItemAction.swift:134-143`, `MainMenu.swift:826-835` |
| S8 | No responder in the sidebar's chain answers `copy(_:)`, so Command-C does nothing while the outline has focus. The sidebar folder holds only the drag writer, and the app's two `copy(_:)` responders sit inside viewer views | `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:47`, `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:3516`, `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift:2111` |
| S9 | A bundle row's title drops the package extension, an analysis row's too, and every other row shows its file name | `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:171-183`, `:909-914` |
| S10 | `.group` rows are the section headers PROJECT SEQUENCES and OPEN DOCUMENTS. A batch group carries "n samples" as its subtitle | `SidebarViewController.swift:2179`, `:2196-2203`, `SidebarProjectScanner.swift:902` |
| S11 | `selectedItems()` returns rows in outline order | `SidebarViewController+OutlineDataSource.swift:269-275` |
| S12 | Only Move to Trash and the two exports count the selection in their context titles | `SidebarItemAction.swift:80-94` |

## Facts, Inspector

| Id | Fact | Where |
|---|---|---|
| I1 | The screenshot is the Run Settings group of a mapping result on the Inspector's Document tab. `contextRows` appends Recorded, then one label and command-line pair per invocation | `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift:189-195`, `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift:163-177` |
| I2 | Each row is a 92-pt trailing label and a value that is selectable, limited to three lines and middle-truncated, all at once. The section holds no expand state | `MappingDocumentSection.swift:235-251`, `:43-49` |
| I3 | Root cause. Selecting a truncated selectable `Text` draws the whole string in a frame laid out for three lines, and nothing clips it, so the command covers the rows below. The screenshot shows it, since the selected minimap2 value has no ellipsis and the unselected samtools values keep theirs. Lane U-B confirms the mechanism on a Debug build | `MappingDocumentSection.swift:243-249` |
| I4 | The Provenance tab's Command row grows correctly, with `.lineLimit(nil)` and `.fixedSize(horizontal: false, vertical: true)` | `Sources/LungfishApp/Views/Inspector/Sections/ProvenanceSection.swift:583-591` |
| I5 | The same latent cause sits at three more sites | `ProvenanceSection.swift:494-505`, `:508-520`, `Sources/LungfishApp/Views/Inspector/Sections/ViralReconDocumentSection.swift:106-112` |
| I6 | An invocation holds a label and an argv, and `commandLine` shell-escapes each argument. The rows are the mapper invocation, then the samtools invocations. `load` resolves `@/` in the JSON before decoding, so a spaced project path stays one quoted word | `Sources/LungfishWorkflow/Mapping/MappingProvenance.swift:8-25`, `:188-190`, `:330-337` |
| I7 | Versions are run-level and shown as the Mapper Version and Samtools Version rows. Recorded is a medium date with a short time | `MappingProvenance.swift:89-90`, `MappingDocumentStateBuilder.swift:189-191`, `:244-249` |
| I8 | A record without stored steps gets synthesized step facts, and every step but the last reads exit code 0 with no wall time. The Document tab rows show no per-step exit status, wall time, inputs or outputs | `MappingProvenance.swift:736-738`, `:758-773` |
| I9 | The whole-record Copy text writes a step as `N. tool version`, then Command, Environment, Inputs, Outputs, Exit Status, Termination, Wall Time, Output and stderr. A list is `Label:` with two-space indented items, and an empty fact is skipped | `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:1019-1027`, `:1065-1076`, `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel+StepTermination.swift:202-213` |
| I10 | A Lineage step keeps the recorded command whole for copying and shows a project-relative label | `ProvenanceInspectorViewModel.swift:219-245`, `:724-726` |
| I11 | Existing copy controls. The Provenance header's icon-only Copy, help and label "Copy provenance text". Raw JSON's borderless Copy with title and icon, through an injectable pasteboard. The Lineage Command row's "Copy Command" menu item and AX action. Recipe steps' "Copy Command" through `.contextActions` and "Copy Pipeline as Script". A command block with a top-trailing copy icon. A per-sequence icon, help "Copy this sequence" | `ProvenanceSection.swift:173-187`, `:356-363`, `ProvenanceInspectorViewModel.swift:426-427`, `ProvenanceSection.swift:401-411`, `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift:1392-1404`, `:1418-1432`, `:1525-1554`, `Sources/LungfishApp/Views/Inspector/Sections/TwelveSDetailSection.swift:156-160` |
| I12 | `.contextActions` publishes each enabled menu command as a VoiceOver action of the same title, in menu order | `Sources/LungfishApp/Views/Shared/ContextActions.swift:89-104` |
| I13 | `ProvenanceDisclosureRow` is the keyboard and AX disclosure. Right Arrow expands, Left Arrow collapses, Return toggles, the value reads Expanded or Collapsed and the actions are Expand and Collapse. It serves runs and steps | `ProvenanceSection.swift:702-720`, `:729-766`, `:260`, `:396` |
| I14 | Copy feedback precedent. The AI Assistant swaps its icon to `checkmark`, described "Copied", for one second | `Sources/LungfishApp/Views/AI/AIAssistantPanel.swift:945-954` |
| I15 | The Inspector font follows View > Content Text Size | `Sources/LungfishApp/Views/Inspector/LungfishInspectorStyle.swift:10-11` |
| I16 | Files at their size baseline, which cannot grow, are MainMenu.swift (1364), ProvenanceInspectorViewModel.swift (1337), DocumentSection.swift (1905), SidebarViewController+MenuDelegate.swift (1215) and SidebarViewController.swift (2616). ProvenanceSection.swift has 776 lines and no baseline | `scripts/ratchets/file-size.baseline:7`, `:27`, `:28`, `:52`, `:54` |
| I17 | features.yaml has no entry for the sidebar commands or the mapping Document section, and the Code Cartographer owns the file. The nearest entries are `map` and `provenance.inspector` | `docs/user-manual/features.yaml:1-2`, `:171-215`, `:2080-2138` |
| I18 | Test seams exist for a hosted section and its AX actions, a hosted `MappingDocumentSection`, the sidebar context menu, AX row probes and Copy Path | `Tests/LungfishAppTests/InspectorSectionAccessibilityTests.swift:40-44`, `:60-98`, `:312-345`, `Tests/Support/LungfishTestSupport/AccessibilityTreeProbe.swift:22`, `:117-132`, `SidebarViewController+MenuDelegate.swift:126-130`, `Tests/LungfishAppTests/SidebarItemActionAccessibilityTests.swift:142-184`, `:296-373` |

The screenshot's record is
`/Volumes/corella_geneious/32616/32616.lungfish/Analyses/minimap2-2026-10-16T20-46-08/mapping-provenance.json`, read
only. It holds mapper version 2.31, samtools version 1.24, a recorded time of 20:58 local on 2026-10-16, five
invocations (minimap2, samtools view, samtools sort, samtools index and samtools flagstat) and six stored steps, the
extra one being `lungfish portable-bam-header`, all with exit code 0. Its `durableReplayArgv` is null, so the replay
command and the executed command agree.

## Q-U1, the step copy affordance

Ruling. Neither option alone. Each step row becomes a disclosure row, and one Copy Step action is reachable four
ways, through a visible copy icon on every step row, the row's context menu, the same commands as VoiceOver actions,
and Command-C on a focused step. Copy All Steps exists, as the last item of every step's context menu and as one
visible button after the last step.

Reasons.

1. The HIG treats a context menu as a shortcut that many people never find, so its commands also need a visible
   control or a menu-bar route. The icon is the visible control, and Edit > Copy is the menu-bar route.
2. The HIG gives Command-C to the current selection. A focused step is that selection, so the step needs no chord of
   its own, and the nearby chords are taken (S7).
3. The app already pairs a context menu with VoiceOver actions through `.contextActions` (I12), already draws
   per-item copy icons (I11) and already names a step's command copy "Copy Command" (I11). The ruling reuses all three.
4. A hover-only icon would hide the route from keyboard, Switch Control and VoiceOver users, so the icon is always
   drawn.
5. Checks UX 5 and UX 7 (`docs/contracts/EXPERT-PANEL.md:132`, `:134`) ask that copied text follow the display and
   VoiceOver order, and that new controls use title case, as `docs/design/design-system/README.md:22` sets for app
   controls.

The step row on the Document tab, from leading to trailing edge.

| Element | Specification |
|---|---|
| Label | Unchanged, the 92-pt trailing secondary label of `MappingDocumentSection.swift:237-241`, top-aligned with the command's first line |
| Disclosure control | A plain button at the leading edge of the value column showing `chevron.right` when collapsed and `chevron.down` when expanded, `.focusable()`. Right Arrow expands, Left Arrow collapses, Return and Space toggle, through `ProvenanceDisclosureKeyCommand` (`ProvenanceSection.swift:702-720`). AX label "<label> command", for example "minimap2 command", value "Collapsed" or "Expanded", hint "Shows or hides the full command.", actions Expand or Collapse. Identifier `mapping-step-<n>-toggle`, with n counting from 1 in row order |
| Command text | As Q-U3 sets. A click on the collapsed text also expands the step. AX value is the whole command in both states. Identifier `mapping-step-<n>-command` |
| Copy icon | `Image(systemName: "doc.on.doc")`, icon only, `.buttonStyle(.borderless)`, top-aligned at the trailing edge in both states. Help "Copy this step". AX label "Copy <label> step", for example "Copy minimap2 step". Identifier `mapping-step-<n>-copy`. A plain button, so it joins the key loop when Full Keyboard Access is on, like every other button |
| Context menu | On the whole row, `.contextActions([.command("Copy Step"), .command("Copy Command", isEnabled: !command.isEmpty), .divider(), .command("Copy All Steps")])`. The row's VoiceOver actions are these three, in this order |
| Command-C | The SwiftUI copy-command modifier (`copyable` or `onCopyCommand`) on the disclosure control returns the Copy Step text, so Edit > Copy is enabled while that control has focus. While text inside an expanded command is selected, the text keeps Command-C and copies the selection, as everywhere in macOS |

After the last step row, still inside Run Settings, sits one button.

| Element | Specification |
|---|---|
| Copy All Steps | `Label("Copy All Steps", systemImage: "doc.on.doc")`, `.labelStyle(.titleAndIcon)`, `.buttonStyle(.borderless)`, the style of the Raw JSON Copy button (`ProvenanceSection.swift:356-363`), its leading edge on the value column. Help "Copy every step of this run". AX label "Copy all steps". Identifier `mapping-steps-copy-all`. Drawn only when the run has a step row |

Feedback. The copy icon and the Copy All Steps button swap their image to `checkmark` for one second after a click,
in the same frame so nothing moves, as the AI Assistant's copy button does (I14). The context menu, the VoiceOver
actions and Command-C give no feedback, as Copy Path, Copy Command and the Finder's Copy give none. No alert, sound
or announcement.

Where it applies.

1. The Run Settings step rows of a mapping result on the Document tab, the reported surface. Required.
2. The Lineage steps on the Provenance tab, for one way to copy a step across the Inspector. The step's
   `ProvenanceDisclosureRow` label and its Command row both carry the same three-item context menu, which replaces the
   single Copy Command item at `ProvenanceSection.swift:408-411` and keeps its name and text. Command-C copies the
   focused step. No new icon there, because the header Copy already copies the whole record (I11) and the step label
   is itself a button, so an icon inside it would nest buttons. Should, and first to cut.
3. The recipe pipeline steps of `DocumentSection.swift:1392-1404` stay as they are this session.

Copy All Steps on the Provenance tab copies the steps of the step's own run, and has no visible button there.

## Q-U2, what a step copy puts on the clipboard

Ruling, in seven rules.

1. Plain text in one `.string` flavour, `\n` line ends and no trailing newline. No Markdown, RTF or file-URL flavour.
2. Line 1 is the step's title as its surface names it. On the Document tab it is `<row label> <version>`, where the
   version is the Mapper Version row's value for the mapper's row (index 0, `MappingProvenance.swift:188-190`), the
   Samtools Version row's value for a row whose `argv[0]` has the base name `samtools`, and nothing otherwise, with
   trailing white space trimmed. On the Provenance tab it is `<ordinal>. <tool> <version>`, the line the whole-record
   Copy text already writes (`ProvenanceInspectorViewModel.swift:1023`).
3. Then one `Label: value` line per fact the surface shows for that step, in display and VoiceOver order. A list is
   `Label:` followed by one line per item indented by two spaces, as I9 sets.
4. A fact the record does not hold is left out, never filled. The Document tab writes no exit status, wall time,
   inputs or outputs, because its rows show none and a record without stored steps would offer a synthesized 0 (I8).
5. The Command line holds the whole command, never truncated and never re-wrapped. On the Document tab it is
   `commandLine` (`MappingProvenance.swift:19-21`), the string the expanded row shows. On the Provenance tab it is the
   whole `step.command` (`ProvenanceInspectorViewModel.swift:725`), not the shortened label.
6. Copy Command puts only that command on the clipboard, one line and nothing else.
7. Copy All Steps is the Copy Step text of every step of the run, in row order, joined by one blank line, so it always
   equals what copying each step in turn would give.

The line sets that follow.

| Surface | Lines after the title |
|---|---|
| Document tab, Run Settings | `Recorded: <the Recorded row's text>`, then `Command: <commandLine>`. Recorded comes first because its row comes before the steps in display and VoiceOver order (`MappingDocumentStateBuilder.swift:191-195`) |
| Provenance tab, Lineage | Exactly `appendStepLines(of:to:)` (I9), so a step copied alone equals its block in the header's Copy text. One function builds both, and `buildCopyableText` calls it |

Why this pastes cleanly.

| Destination | Result |
|---|---|
| Lab notebook (Notes, Word, OneNote, Benchling) | Each fact is one labelled line, the command is whole and nothing needs a renderer |
| Markdown file | Inside a fenced block it renders verbatim. Outside one, a renderer joins the lines into a paragraph but keeps every character. Markdown syntax on the clipboard would show as literal backticks in a notebook, so the clipboard carries none |
| Terminal | No labelled block can paste into zsh, the macOS default shell, since a `Label:` line runs as a command and zsh treats `#` as a command while interactive comments are off, as they are by default. Copy Command is the terminal route. Its words are shell-escaped one argument at a time, so a spaced project path stays one word (I6) |

The step copy is a record of what ran, not a replay. A replay into a new folder is the Operations panel's Copy CLI
Command (UX 4, `docs/contracts/EXPERT-PANEL.md:131`). The paths in a step's command may be gone, such as the staged
`reference.fa` under `.tmp`.

Filled example. Copy Step on the screenshot's minimap2 row, from the record named under the facts.

```text
minimap2 2.31
Recorded: Oct 16, 2026 at 8:58 PM
Command: minimap2 -a -x sr -t 14 -R '@RG\tID:SRR35517702-lengthFilter-subsampleCount\tSM:SRR35517702-lengthFilter-subsampleCount\tLB:SRR35517702-lengthFilter-subsampleCount\tPL:ILLUMINA\tPU:SRR35517702-lengthFilter-subsampleCount' --secondary=no -o /Volumes/corella_geneious/32616/32616.lungfish/Analyses/minimap2-2026-10-16T20-46-08/SRR35517702-lengthFilter-subsampleCount.raw.sam /Volumes/corella_geneious/32616/32616.lungfish/.tmp/mapping-reference-stage-41B36A8C-9FC1-49ED-82AD-F8D0F393B10B/reference.fa /Volumes/corella_geneious/32616/32616.lungfish/Analyses/SRR35517702-lengthFilter-subsampleCount.lungfishfastq/subsampleCount.fastq.gz
```

Copy Command on the same row gives the text after `Command: ` alone. Copy All Steps gives this block, a blank line,
`samtools view 1.24` with its Recorded and Command lines, and so on through `samtools flagstat 1.24`.

The Recorded text is whatever the row shows. The current macOS formatter puts a narrow no-break space (U+202F) before
PM, so a test compares with the builder's own string and never with a typed literal.

The same step copied on the Provenance tab has this shape. The tool line's version is the Lineage row's text, the
command is the stored step's own argv, launcher included, and the paths are the record's.

```text
1. minimap2 <the Lineage row's version>
Command: micromamba run -n minimap2 minimap2 -a -x sr -t 14 -R '@RG\tID:…' --secondary=no -o /Volumes/…/SRR35517702-lengthFilter-subsampleCount.raw.sam /Volumes/…/reference.fa /Volumes/…/subsampleCount.fastq.gz
Inputs:
  /Volumes/…/SRR35517702-lengthFilter-subsampleCount.lungfishfastq/subsampleCount.fastq.gz
  /Volumes/…/.tmp/mapping-reference-stage-41B36A8C-9FC1-49ED-82AD-F8D0F393B10B/reference.fa
Outputs:
  /Volumes/…/Analyses/minimap2-2026-10-16T20-46-08/SRR35517702-lengthFilter-subsampleCount.raw.sam
Exit Status: 0
Wall Time: 59.68 s
```

The ellipses mark text this ruling shortens. The copy never contains one.

## Q-U3, the expanded-step display

Ruling. The rule behind the fix is that no Inspector text is selectable while it is truncated. A collapsed step is a
preview that cannot be selected, and an expanded step is the whole command, selectable, in a row that grows.

| Aspect | Specification |
|---|---|
| Default | Collapsed, every time the section shows a result. Expansion is view state per step (`@State` keyed by row index), never saved, and expanding one step leaves the others alone |
| Collapsed | The command in up to three lines with middle truncation, as today, but in `LungfishInspectorStyle.controlFont.monospaced()` and with no `.textSelection`. Help and AX value are the whole command |
| Expanded | The whole command, `.lineLimit(nil)`, `.fixedSize(horizontal: false, vertical: true)`, `.textSelection(.enabled)`, the same monospaced font, wrapped at the value column's width. The row grows and every row below moves down. Nothing draws outside the row, and there is no inner scroll view, unlike the 60-pt command block at `DocumentSection.swift:1525-1554` |
| Line breaks | Soft wrap only, at the points the text system chooses, which today include spaces, slashes and hyphens. No break is inserted at an argument boundary and no `\` continuation is added, so the shown text, a partial selection and Copy Command all hold the same single-line command |
| Monospace | Commands are code, so they read in monospace, as the recipe step commands and the command block already do (`DocumentSection.swift:1392-1393`, `:1530-1531`). The font follows View > Content Text Size (I15) |
| Paths | Shown as recorded this session. A project-relative display like the Provenance tab's is Q-U7 |
| Other rows | The non-step rows of Run Settings share `contextRow`, which is selectable and truncated at once (`MappingDocumentSection.swift:243-249`). They keep their look and selection but drop the line limit and truncation, as the Provenance tab's `summaryValueText` does (I4), so a long value such as Extra arguments shows whole. They never expand |

The data the view needs. `MappingDocumentStateBuilder` stops putting invocation rows into `contextRows` and returns
them as a separate `steps: [MappingDocumentStep]`, each holding `label`, `command` (`commandLine`) and `version` as
Q-U2 rule 2 picks it, plus the Recorded text the section already shows. Recorded stays a context row.
`MappingDocumentState.==` (`MappingDocumentSection.swift:33-40`) compares the new fields. This keeps the builder the
only place that reads the record, so the view does no file work (SWIFT 2, `docs/contracts/EXPERT-PANEL.md:108`).

## Q-U4, Copy Name

| Aspect | Ruling |
|---|---|
| Label | "Copy Name", title case like every app control. For more than one row the context title reads "Copy <n> Names", a fourth case in `contextTitle(selectionCount:)` (`SidebarItemAction.swift:86-94`). The menu-bar title stays "Copy Name", as Move to Trash stays singular there |
| Context menu | In the locate section, directly above Copy Path, giving Show in Finder, Copy Name, Copy Path, Show in Inspector. The name comes before the path as the Finder's Copy comes before Copy as Pathname |
| Main menu | Selection > Sidebar Item, in the same section, giving Show in Finder, Copy Name, Copy Path (`menuSections`, `SidebarItemAction.swift:187`). `MainMenu.swift` needs no edit, since it builds from `menuSections` (S4) |
| Shortcut | No chord of its own. Edit > Copy (Command-C) runs Copy Name while the sidebar outline has keyboard focus, through a `copy(_:)` responder on `SidebarViewController`. Command-Option-C and Command-Shift-C are taken and the app binds each chord once (S7). Command-C there does nothing today (S8). The Selection item shows no chord, because showing Command-C on it would bind that chord twice |
| What name means | The row's title, the primary text the row shows (`SidebarItem.title`). A bundle reads without its package extension, an analysis row likewise, a plain file with its extension, and a folder or the project by its name (S9). Never the subtitle or inline secondary text (a read composition, Virtual, n samples), and never a path |
| Which rows | Every row except the section headers PROJECT SEQUENCES and OPEN DOCUMENTS (S10), the rule Copy Path and Show in Finder already follow (S2). A batch group row and a result row copy their titles |
| Several rows | One title per line, joined by `\n`, in outline order (S11), with no trailing newline. A parent and its child both selected give a line each |
| Enabling | Enabled when the selection has at least one row and no section header. The one availability rule drives the context menu, the Selection item (enabled only while the outline has focus, S6) and the row actions. Edit > Copy uses the same rule and the same focus test |
| Clipboard | `copyPasteboard.clearContents()`, then `setString(_:forType: .string)`, one flavour as Copy Path writes (S3). No file URL, so a paste in the Finder copies no bundle |
| Feedback | None, as Copy Path |
| Accessibility | Each row's custom actions gain "Copy Name" in context-menu order, which the availability rule gives for free (S5). Slug `copy-name`, so the menu-bar identifier is `selection-menu-sidebar-item-copy-name`. A menu item's AX title is its title. Context-menu items carry no identifier, as the others carry none |
| Handler | `copySelectedSidebarItemName(_:)` joins the `SidebarItemMenuActions` protocol (`SidebarItemAction.swift:200-224`). Its body and `copy(_:)` go in the extension at `SidebarViewController+ItemActions.swift:175-184`, because `SidebarViewController+MenuDelegate.swift` is at its size baseline (I16). `validateMenuItem` gains one branch for `#selector(NSText.copy(_:))` that returns the focus test and the Copy Name rule, since an unknown action otherwise validates true (S6) |

### features.yaml

The file's header gives it to the Code Cartographer (I17), so a `code-cartographer` agent on sonnet at effort max
writes these after each lane, and the `scripts/checks/features-yaml-sources.py` check named in that header passes.

A new entry, placed after `project.demo-projects`.

```yaml
  sidebar.copy-name:
    title: Copy the names of sidebar items
    entry_points:
      - "Sidebar context menu > Copy Name"
      - "Selection > Sidebar Item > Copy Name"
    inputs: [bundle, folder, file]
    outputs: [clipboard-text]
    viewport_class: none
    sources:
      - Sources/LungfishApp/Views/Sidebar/SidebarItemAction.swift
      - Sources/LungfishApp/Views/Sidebar/SidebarViewController+ItemActions.swift
    module: [LungfishApp]
    tests:
      - Tests/LungfishAppTests/SidebarItemActionAccessibilityTests.swift
      - Tests/LungfishAppViewTests/SelectionMenuTests.swift
    notes: >-
      Copy Name puts the name each selected row shows on the clipboard as plain
      text, one name per line in sidebar order. A bundle's name has no package
      extension. Section headers offer no Copy Name. Command-C does the same
      while the sidebar has keyboard focus, and each row offers Copy Name as a
      VoiceOver action.
```

`map` gains the entry point `"Inspector > Document > Run Settings"`, the sources `MappingDocumentStateBuilder.swift`,
`Sections/MappingDocumentSection.swift` and the new step-row file, the tests `MappingDocumentStateBuilderTests.swift`
and `InspectorSectionAccessibilityTests.swift`, and this note. "On the Inspector's Document tab, Run Settings lists
each recorded command as a step that expands to its whole command. Copy Step, Copy Command and Copy All Steps copy
steps as plain text from a step's copy button, its context menu, its VoiceOver actions or Command-C."

`provenance.inspector` gains this note when the Provenance part lands. "Each Lineage step offers Copy Step, Copy
Command and Copy All Steps from its context menu and VoiceOver actions, and Command-C copies a focused step. Copy Step
copies the step's block of the Copy text." Any new source file joins its `sources`.

### Release notes and the manual

Wording for the manager's release notes, under UX 7.

1. "Copy Name, in the sidebar's context menu and in Selection > Sidebar Item, copies the names of the selected items,
   one per line. Command-C does the same while the sidebar has focus."
2. "In a mapping result's Inspector, each command in Run Settings now expands to its full length without drawing over
   the rows below, and Copy Step, Copy Command and Copy All Steps copy steps as plain text."
3. If the Provenance part lands, "Lineage steps on the Provenance tab offer the same three copy commands."

Under the owner's rule of 2026-10-07 that defers manual work, the manual is not edited this session. The manager
records a docs fact for each change and a screenshot punchlist row for any manual image of the sidebar context menu,
which gains a row.

## Further questions a lane needs answered

| Id | Question | Ruling |
|---|---|---|
| Q-U5 | What if the SwiftUI copy modifier does not fire on a focused plain button, or a right-click on selected command text shows the text's own menu instead of the step's? | Lane U-B checks both on a Debug build. If Command-C does not fire, the lane ships the other three routes, adds no chord and reports the gap. If selected text shows its own menu, that is acceptable, since the step menu stays on the label, the disclosure control and the copy icon. The lane records what it saw |
| Q-U6 | Do the three latent selectable and truncated sites (I5) change now? | No, a follow-up after 2.12, recorded under Moved out. The pattern is to show a value whole where it fits and, where it stays truncated, drop `.textSelection` and offer `.contextActions([.command("Copy Path")])` with the whole value. The legacy Provenance file rows keep their look under UX 5, so only selection changes there. Lane type `lge-worker`, sonnet, effort max |
| Q-U7 | Should a Document tab command read project-relative, as the Provenance tab's does (I10)? | Not this session. It would shorten the minimap2 preview by about 150 characters, but `ProvenanceCommandPresentation.display` checks each path on disk (`Sources/LungfishWorkflow/Provenance/ProvenanceCommandPresentation.swift:39-55`), so it belongs in the builder with a SWIFT review, and it changes shown strings in every mapping Inspector (UX 1). Moved out |
| Q-U8 | Should Copy Path accept several rows now that Copy Name does? | Not now. Copy Path stays single-row as `SidebarItemActionAccessibilityTests.swift:165` pins it. A later session may give it one path per line. Moved out |
| Q-U9 | How is the work checked by eye? | One GUI check after both lanes land, by `lge-worker` on sonnet at effort max with Computer Use on `build/Debug/Lungfish Debug.app` from `python3 scripts/release/release.py debug`. It uses a scratch project with a mapping result, never the owner's 32616 project, because opening a project writes its lock record (`docs/user-manual/features.yaml:2242-2256`). The five checks follow. If Computer Use is unavailable, they go on the owner check list |

The five GUI checks.

1. Expand the minimap2 step, drag a selection across its command, and capture the Inspector. Nothing draws outside the
   row, and the rows below have moved down.
2. Click the step's copy icon, then paste into TextEdit. The text matches Q-U2, and the icon shows a checkmark for one
   second.
3. Press Tab to reach a step's disclosure control, then press Command-C and paste. The text matches again.
4. Right-click a step. The menu reads Copy Step, Copy Command, a divider and Copy All Steps, and VoiceOver's Actions
   menu (VO-Command-Space) lists the same three.
5. In the sidebar, choose Copy Name on a FASTQ bundle and paste, which gives the name without its extension. Select
   three rows, press Command-C and paste three lines. Selection > Sidebar Item > Copy Name is enabled only while the
   sidebar has focus.

## Candidate lanes

The two lanes share no file and can run at once in separate worktrees. One `code-cartographer` run writes
features.yaml after both land.

### Lane U-A, Copy Name

Agent `lge-worker` on sonnet at effort max, since every choice is pinned above and the work follows Copy Path.

| File | Change |
|---|---|
| `Sources/LungfishApp/Views/Sidebar/SidebarItemAction.swift` | Case `copyName` with title "Copy Name", context title "Copy <n> Names" for n above 1 (`:86-94`), slug `copy-name`, selector `copySelectedSidebarItemName(_:)`, the protocol method (`:200-224`) and the section `[.showInFinder, .copyName, .copyPath]` (`:187`) |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController+ItemActions.swift` | `if !hasGroups { locateSection.append(.copyName) }` between the Show in Finder line (`:117`) and the Copy Path line (`:118`). The two handlers in the extension at `:175-184`. One `validateMenuItem` branch for `#selector(NSText.copy(_:))` returning `sidebarOutlineHasKeyboardFocus && canPerformSidebarItemAction(.copyName)` (`:164-170`) |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift` | At `:107-112`, fold the Move to Trash case into `default`, so the file shrinks by two lines under its baseline. The replacement is `default:` then `let item = action.makeContextMenuItem(target: self, action: action.menuSelector)`, `item.title = action.contextTitle(selectionCount: items.count)` and `return item` |

Tests, all on behaviour, in `Tests/LungfishAppTests/SidebarItemActionAccessibilityTests.swift` (415 lines).

| Test | Assertion |
|---|---|
| `testCopyNameCopiesTheBundleTitleWithoutItsExtension` | After `copySelectedSidebarItemName(nil)` on `bundleURL`, the pasteboard string equals the row's title and `bundleURL.deletingPathExtension().lastPathComponent` |
| `testCopyNameKeepsAPlainFilesExtension` | On `fastaURL` the string equals `fastaURL.lastPathComponent` |
| `testCopyNameOnTwoRowsWritesOneNamePerLineInOutlineOrder` | Two FASTA rows give the two titles joined by `\n` in row order with no trailing newline, and the context menu holds "Copy 2 Names" |
| `testSectionHeadersOfferNoCopyName` | `availableSidebarItemActions(for:)` holds no `.copyName` for a `.group` item alone or mixed with a file |
| `testEditCopyCopiesNamesOnlyWhileTheOutlineHasFocus` | With the outline first responder, an Edit > Copy item validates true and `copy(nil)` writes the name. With the text field first responder it validates false, after the model of `:265` |
| `testOutlineRowCopyNamePerformsThroughAX` | `AccessibilityRowProbe.performCellAction(named: "Copy Name", in:)` writes the row's title, after the model of `:339-373` |
| Existing, changed on purpose | `testBundleContextMenuKeepsTheBaselineCommandsInAppleTitleCase` (`:169-184`) expects "Copy Name" right before "Copy Path". The menu-bar validation test (`:223-262`) adds the Copy Name item |

`Tests/LungfishAppViewTests/SelectionMenuTests.swift` covers the new item through `menuSections` and the distinct
slug, selector and title checks (`:68-88`, `:180-190`, `:281-295`), and its chord test (`:90-111`) stays green with
no new chord. The lane runs `swift test --skip-update --filter SidebarItemActionAccessibilityTests` and
`--filter SelectionMenuTests`.

Review by `lge-expert` on sonnet at effort max against UX 1, UX 7, ARCH 6 and QA 2. Fact-check of the features.yaml
note and the release-note line by `manual-fidelity-reviewer` on sonnet at effort max.

### Lane U-B, the Inspector step display and step copy

Agent `lge-worker` on opus at effort max, since the work sets SwiftUI layout, focus and accessibility and is the
longer chain.

| File | Change |
|---|---|
| `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift` | Return the invocations as `steps` with label, command and version (Q-U2 rule 2) and the Recorded text, and stop appending them to `contextRows` (`:193-195`) |
| `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift` | `MappingDocumentStep`, the new state fields and `==` (`:21-41`). Run Settings draws context rows, then step rows, then Copy All Steps (`:163-177`). `contextRow` drops its line limit and truncation (`:243-249`). A `pasteboard` property defaulting to `.general` for tests |
| New `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentStepRow.swift` | The step row of Q-U1 and Q-U3 |
| New `Sources/LungfishApp/Views/Inspector/InspectorStepCopyText.swift` | Pure builders for the Document tab's Copy Step and for Copy All Steps on both tabs |
| Provenance part, should | `ProvenanceSection.swift` step menus (`:396-411`) and an optional copy closure on `ProvenanceDisclosureRow` (`:729-766`), keeping the file at or under 800 lines and moving `stepDisclosure` to a new `ProvenanceSection+StepRow.swift` if needed. A new `ProvenanceInspectorViewModel+StepCopy.swift` with `stepCopyText(of:)` and `allStepsCopyText(of:)`, and `ProvenanceInspectorViewModel.swift:1023-1024` replaced by one call, which shrinks that baselined file |
| `Tests/Support/LungfishTestSupport/AccessibilityTreeProbe.swift` | A `frame(_:)` helper that reads `accessibilityFrame()` |

Tests, all on behaviour. Fixtures use a project folder name with a space and a command over 600 characters.

| Test | Assertion |
|---|---|
| `testStepsComeFromTheInvocationsWithTheirRunVersions`, in `MappingDocumentStateBuilderTests.swift` | Five steps in invocation order with the mapper version first and the samtools version after, commands equal `commandLine`, no invocation label left in `contextRows`, Recorded still a context row. The check at `:115` moves to `steps` |
| `testCopyStepWritesTheTitleRecordedAndTheWholeCommand` | After the AX action Copy Step on step 1 with a private pasteboard, the string equals `"<label> <version>\nRecorded: <recorded>\nCommand: <command>"`, holds no ellipsis and ends without a newline |
| `testCopyCommandWritesOnlyTheCommand` | The string equals the command, and the spaced path appears single-quoted |
| `testCopyAllStepsJoinsEveryStepWithOneBlankLine` | Pressing `mapping-steps-copy-all` writes every Copy Step text joined by `\n\n` |
| `testStepRowOffersItsCopyCommandsInMenuOrder` | `customActionNames` equals Copy Step, Copy Command, Copy All Steps, and Copy Command is absent for an empty command |
| `testStepDisclosureReportsAndChangesItsState` | `mapping-step-1-toggle` reads label "minimap2 command" and value Collapsed, then Expanded after the Expand action |
| `testExpandedStepGrowsAndClearsTheNextRow` | In a window 320 pt wide, the expanded command is taller than the collapsed one, and its frame ends above the frame of `mapping-step-2-toggle` |
| `testCopyIconCopiesTheStep` | Pressing `mapping-step-1-copy` writes the Copy Step text, and its AX label is "Copy minimap2 step" |
| `testStepCopyTextEqualsItsBlockInTheCopyText`, Provenance part | Each step's `stepCopyText` appears whole in `copyableText`, a step with no exit status has no Exit Status line, and `allStepsCopyText` joins the steps by `\n\n` |

A test that pins the Lineage Command row's single Copy Command action changes on purpose, and the lane names it.

Cut order, first to cut first. The Provenance part, then the visible Copy All Steps button (its menu item stays), then
Command-C if Q-U5 finds it does not fire. Never cut are the overdraw fix, the disclosure, and Copy Step and Copy
Command through the icon, the menu and VoiceOver.

Review by `lge-expert` on sonnet at effort max against UX 1, UX 5, UX 6, UX 7, SWIFT 2, ARCH 6, QA 1 and QA 2.
Fact-check by `manual-fidelity-reviewer` on sonnet at effort max. Fixes by `lge-worker` on sonnet at effort max, and
landing by `lge-worker` on sonnet at effort max.

## Open question

| Id | For | Question |
|---|---|---|
| Q-U10 | QA | QA 1 wants a defect fix to show its test failing at the base, but no unit test can drive a real text selection. The owner's screenshot shows the base failing, and GUI check 1 shows the fix. The QA expert rules whether that pair meets QA 1 |

## Q-S1, progress and partial display

Facts. The summary bar is one 32-pt label showing the bundle's title until the mapping result is read, then the
mapping summary (`Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:94-110`,
`:483-519`). The viewer clears to "Loading reference viewer..." with three periods (`:851`), and the detail pane reads
"Select a sequence to inspect." with nothing selected (`:146-154`). The Provenance pane shows a small spinner and
"Loading provenance…" (`ProvenanceSection.swift:145-153`), with Copy disabled meanwhile (`:186`). A new selection
clears the pane and a superseded lookup is dropped by generation (`ProvenanceInspectorViewModel.swift:448-505`). The
record lookup and the lineage walk run in one detached lookup today (`:494-497`, `:524-545`).

Ruling. Yes. The list and the mapping table show as soon as their own rows are ready and never wait for the viewer
or the lineage. No pane is ever blank. A pane waits behind a placeholder naming its work for as long as that work
runs, with no time limit, since the work no longer holds the main thread.

| Pane | Meanwhile | Done |
|---|---|---|
| Summary bar | Its text stays the title, then the mapping summary, and never carries progress. A trailing status item, a small spinner hidden from VoiceOver beside secondary text, reads "Loading sequences…" while rows load, then "Loading reference viewer…" while the viewer opens. AX label equals the text | Status item hidden |
| List or mapping table | Before its first rows, a centred small spinner and "Loading sequences…". Rows never grow silently. If the first paint holds a subset, such as the sequences with reads, the summary bar says so until the rest arrive, in words that wait on BIO's Q-S3 | Rows, sortable and selectable at once |
| Embedded viewer | "Loading reference viewer…" with the ellipsis character, fixing `:851` (UX 7). "Select a sequence to inspect." still shows with nothing selected. Selecting a row while it opens retargets it and drops the earlier open | The sequence |
| Provenance pane | "Loading provenance…" until the record is read. Its groups may then show while the Lineage group holds a small spinner and "Loading lineage…". Copy and Export stay disabled until the lineage is done, so no copy or export lacks it (UX 5) | Lineage rows, Copy and Export enabled |

VoiceOver. Nothing is announced when work starts, since the user's action just moved focus and every placeholder is
readable text. One medium-priority announcement, posted as
`Sources/LungfishApp/Views/ProjectStorage/ProjectStorageSheetViewController.swift:517-526` does, when the list or table
first becomes usable, "Sequence list ready, 1,234 sequences" or "Mapping table ready, 94 sequences", with the count
formatted for the locale and "1 sequence" in the singular. "Lineage ready" is announced only while the Provenance tab
is the visible Inspector tab. The viewer finishing announces nothing.

Cancelled by a selection change. A superseded lineage lookup ends silently. The pane switches at once to the new
selection's state, "Loading provenance…" or that item's own status, never shows the old item's lineage, and shows no
"Cancelled" text, alert or announcement, since the user cancelled nothing. The viewport follows the same rule. A
decode or viewer load for a bundle the user left is dropped by a generation check, and nothing of it reaches the new
bundle's panes.

Tests on behaviour, in the SWIFT lanes. A slow injected decode leaves the list placeholder and the status item
readable through AX, then rows. A superseded load leaves only the new selection's rows. Copy is disabled while the
lineage loads. The ready announcement posts once per opened bundle. Review by `lge-expert` on sonnet at effort max
against UX 1, UX 5 and UX 7.

