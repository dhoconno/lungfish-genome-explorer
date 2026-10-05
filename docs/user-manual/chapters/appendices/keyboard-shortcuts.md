---
title: Keyboard Shortcuts
chapter_id: appendices/keyboard-shortcuts
audience: bench-scientist
prereqs: []
estimated_reading_min: 24
task: Look up the keyboard shortcut for any common Lungfish Genome Explorer operation.
tags: [reference, shortcuts, productivity, macos]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: [key-equivalent, modifier-key, classifier, pipeline, chord, lens, plate-map, metadata, call, bundle, provenance, plugin-pack, viewport, gff, fasta, haplotype, miseq, variant-caller]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This appendix covers every keyboard shortcut in Lungfish Genome Explorer (LGE) on macOS and where Escape acts, and nothing else. A keyboard shortcut is a combination of keys that runs a command without going to the menu bar. macOS calls the letter or symbol at the end of that combination the [key equivalent](../../GLOSSARY.md#key-equivalent), and every Shortcut column in this appendix prints the modifiers first and that key equivalent last.

The keys you hold down first are [modifier keys](../../GLOSSARY.md#modifier-key), and LGE uses four of them. Cmd is the Command key beside the space bar. Opt is the Option key next to it, labelled Alt on some keyboards. Shift is the key you already use for capital letters. Ctrl is the Control key near the left end of the bottom row, sitting just to the right of fn.

Every row below comes from LGE's own menu and view definitions. The menu bar is the fastest check you can run yourself, because macOS prints the shortcut on the right-hand side of every menu row that has one.

Most of these shortcuts are ones LGE inherits from macOS itself, which is why they will already feel familiar. Cmd-Q quits, Cmd-W closes the window, Cmd-Z undoes, Cmd-C copies, Cmd-V pastes, and Cmd-A selects all, exactly as they do in every other Mac application. The shortcuts that are LGE's own act on sequence, on the panels, and on the [viewport](../../GLOSSARY.md#viewport), the main display area in the middle of the window.

## Before you press anything

Three facts decide whether a shortcut does anything at all, and reading them first will save you a puzzled minute later.

A shortcut acts on the window that has focus. Focus means the window or pane you clicked most recently, so clicking a sequence display and then pressing an arrow key moves that display rather than the sidebar beside it. Every table below states the window or pane that must have focus before its rows work.

A greyed menu item is disabled, and its shortcut does nothing until the item is enabled. Nothing happens and no message appears. LGE greys items out on purpose whenever the command has nothing to act on, so the four zoom commands are disabled until a sequence or an alignment is on screen and **Cancel All Operations** is disabled until something is running.

One part of the Tools menu is gated further. A Genotyping tool shows "(not enabled)" after its name, in grey, until you turn it on in the [Workflow Library](../../GLOSSARY.md#workflow-library). Choosing it, or pressing its shortcut, asks whether to open the Workflow Library rather than starting the tool, as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows.

Your work is saved as you go. There is no Save command and no Cmd-S in LGE, because every change is written to the project folder the moment you make it. Nothing sits in memory waiting to be saved, and closing a window loses nothing.

## How a shortcut is written here

Each shortcut is written with the modifier keys first and the key equivalent last, joined by hyphens, so Cmd-Shift-P means hold Command and Shift together and then press P. You can press the modifiers in any order. All of them need to be down before the final key goes down.

Symbol keys are named by the key a US keyboard prints on them, so you never have to guess whether Shift is part of the combination. Cmd-comma is the comma key. Cmd-plus and Cmd-minus are the equals key and the hyphen key, pressed with Command and no Shift, because LGE accepts the unshifted key in both places. Cmd-right bracket and Cmd-left bracket are the `]` and `[` keys. Cmd-? needs Shift, so it is written Cmd-Shift-slash wherever it appears. An arrow key can also be the final key, as in Cmd-Shift-Right Arrow. Inside the sequence viewport and the classifier read viewer, Cmd-Shift-hyphen, which types an underscore, also works in place of Cmd-minus.

Menu titles appear in **bold** when the text names them, and the bold form is the exact title the app prints, ellipsis included. That matters in one place only, the Customizing shortcuts section at the end, where an exact match is what makes a remapping work.

Menu paths are written as words throughout, as in Settings, under Advanced, rather than with arrows.

## Lungfish Genome Explorer menu

The leftmost menu, named for the app itself, holds the commands that act on the whole application rather than on a project. These four work whenever LGE is the front application, whether or not a project is open.

| Action | Shortcut | Origin |
|---|---|---|
| Settings... | Cmd-comma | Standard macOS |
| Hide Lungfish Genome Explorer | Cmd-H | Standard macOS |
| Hide Others | Cmd-Opt-H | Standard macOS |
| Quit Lungfish Genome Explorer | Cmd-Q | Standard macOS |

The same menu also carries **About**, **Check for Updates...**, and **Show All**, and none of the three has a shortcut. [Getting LGE](../01-foundations/06-the-lungfish-project.md#getting-lge) explains what Check for Updates does and when it is available.

Pressing Cmd-Q while operations are running, such as an import that has not finished, opens a sheet titled "Quit with 1 Operation Running?", or the count of operations. Return chooses **Don't Quit**, the safe default. Click **Cancel Operations and Quit** to cancel the running operations and quit.

## File menu

Project-level commands. All four rows need a project window open and in front.

| Action | Shortcut | Origin |
|---|---|---|
| New Project | Cmd-N | Standard macOS |
| Open Project Folder... | Cmd-O | Standard macOS |
| Close | Cmd-W | Standard macOS |
| Import Center... | Cmd-Shift-I | LGE's own |

**Import Center...** opens the window for bringing files into the project you have open. The File menu explains the absence of Save in its own words under **About Saving...**, which has no shortcut of its own. The menu's other items, **Open Recent**, the **Export** submenu with its seven export commands and its **Provenance** submenu, and **Manage Project Storage...**, have no shortcuts. The seventh export command, **12S Result...**, opens the format list for the 12S amplicon result in front, the same list the result window's Export button offers.

## Edit menu

Standard Mac editing. These six work in whatever text field, table, or viewport selection has focus, so click into the thing you mean to edit first.

| Action | Shortcut | Origin |
|---|---|---|
| Undo | Cmd-Z | Standard macOS |
| Redo | Cmd-Shift-Z | Standard macOS |
| Cut | Cmd-X | Standard macOS |
| Copy | Cmd-C | Standard macOS |
| Paste | Cmd-V | Standard macOS |
| Select All | Cmd-A | Standard macOS |

The Find submenu at the bottom of the Edit menu holds three more, all of them standard. **Find...** is Cmd-F, **Find Next** is Cmd-G, and **Find Previous** is Cmd-Shift-G. **Delete** sits just above Select All with no shortcut.

## View menu

The panels that frame the main viewport, plus the zoom commands. These need a project window in front. The sidebar runs down the left, the Inspector down the right, and the Document Inspector is a separate window listing the descriptive [metadata](../../GLOSSARY.md#metadata) of the selected [bundle](../../GLOSSARY.md#bundle), meaning the folder LGE treats as one data item.

| Action | Shortcut | Origin |
|---|---|---|
| Show Sidebar | Ctrl-Cmd-S | Standard macOS |
| Show Inspector | Cmd-Opt-I | LGE's own |
| Focus Viewer | Cmd-Opt-F | LGE's own |
| Restore Side Panes | Ctrl-Cmd-Opt-F | LGE's own |
| Provenance Inspector | Cmd-Opt-V | LGE's own |
| AI Assistant | Cmd-Opt-A | LGE's own |
| Show Drawer | Ctrl-Cmd-B | LGE's own |
| Show Distance Matrix | Ctrl-Cmd-M | LGE's own |
| Enter Full Screen | Ctrl-Cmd-F | Standard macOS |

**Focus Viewer** hides both the sidebar and the Inspector so the viewport fills the window, and **Restore Side Panes** brings both back. **Document Inspector** has no shortcut, because macOS keeps Cmd-Opt-D for showing and hiding the Dock. **AI Assistant** reveals the Inspector's Assistant tab. **Provenance Inspector** reveals the Inspector's Provenance tab, which lists every tool run that produced the selected result. In that tab each run and each step is a button. Press Space or Return on one to open or close it, Right Arrow to open it, and Left Arrow to close it.

**Show Drawer** opens the table drawer along the bottom of the viewport, and **Make Drawer Taller** and **Make Drawer Shorter**, which have no shortcut, change its height one step at a time. With the drawer's top edge selected, the Up and Down Arrow keys do the same. On a multiple sequence alignment the drawer is a pane with two tabs, **Annotations** and **Distances**, and Show Drawer opens it on whichever tab was showing last. **Show Distance Matrix** opens the same pane on its Distances tab, and only an alignment enables it. The **View > Distance Matrix** submenu beside it holds the matrix commands, none of which has a shortcut.

The Sidebar, Inspector, Drawer and Distance Matrix rows change their own titles as you use them. When the panel is showing, the menu reads **Hide Sidebar**, **Hide Inspector**, **Hide Drawer** or **Hide Distance Matrix** instead, and the same shortcut does the hiding. The shortcut never changes.

The four zoom commands act on the viewport. All four are greyed out whenever nothing zoomable is on screen, meaning no sequence display and no multiple sequence alignment, such as while a read bundle or a classifier result is selected. In the taxonomy sunburst, **Zoom to Fit** returns to the full chart, as [Inside a classifier result window](#inside-a-classifier-result-window) describes.

| Action | Shortcut | Origin |
|---|---|---|
| Zoom In | Cmd-plus | LGE's own |
| Zoom Out | Cmd-minus | LGE's own |
| Zoom to Fit | Cmd-0 | LGE's own |
| Zoom Reset (10kb) | Cmd-1 | LGE's own |

**Zoom Reset (10kb)** sets the view to a 10,000 base window centred on where you are, which is a working scale for reading genes rather than whole chromosomes.

The **Content Text Size** submenu is a different thing entirely and is the answer when the app's own interface text is too small to read comfortably. It changes the size of LGE's labels, tables, and panel text across the whole application, and it leaves the scientific viewport's own zoom alone.

| Action | Shortcut | Origin |
|---|---|---|
| Content Text Size > Larger | Cmd-Opt-plus | LGE's own |
| Content Text Size > Smaller | Cmd-Opt-minus | LGE's own |
| Content Text Size > Default | Cmd-Opt-0 | LGE's own |

Adding Opt turns a viewport zoom command into a text size command.

The rest of the View menu acts on particular viewports.

| Action | Shortcut | Where it acts |
|---|---|---|
| Expand All | Cmd-Shift-Right Arrow | Taxonomy, EsViritu, NVD, and BLAST results tables |
| Collapse All | Cmd-Shift-Left Arrow | Taxonomy, EsViritu, NVD, and BLAST results tables |
| Next Sample | Cmd-right bracket | TaxTriage result window |
| Previous Sample | Cmd-left bracket | TaxTriage result window |
| All Samples | Cmd-Shift-0 | TaxTriage result window |
| Show as RNA (U instead of T) | Cmd-Shift-U | Sequence viewport |

The taxonomy table is the tree of organism names a [classifier](../../GLOSSARY.md#classifier), a program that names the organism each read came from, produces, and its two rows need the table to have focus. With it focused, Opt-Right Arrow expands the selected row and everything beneath it. The three sample rows work only when a run of TaxTriage, one of LGE's classifiers, holds more than one sample. **Show as RNA** redraws the sequence with uracil in place of thymine and shows a checkmark while it is on. **Reset View Settings to Defaults** has no shortcut.

## Sequence menu

Commands that act on the sequence currently on screen. All six need a sequence viewer open and in front, and all six are greyed out when none is. **Copy Visible Region as FASTA** and **Extract Visible Region...** take the region the viewport is showing, or the range you have selected inside it if you have made one.

| Action | Shortcut | Origin |
|---|---|---|
| Reverse Complement... | Cmd-Shift-R | LGE's own |
| Translate... | Cmd-Shift-T | LGE's own |
| Go to Location... | Cmd-L | LGE's own |
| Go to Gene... | Cmd-Opt-G | LGE's own |
| Copy Visible Region as FASTA | Cmd-Shift-C | LGE's own |
| Extract Visible Region... | Cmd-Shift-E | LGE's own |

These are LGE's own bindings and they do not match what other sequence viewers use for the same commands.

**Go to Location...** accepts a plain coordinate such as `32000000`, or a range written as chromosome, colon, start, hyphen, end. Type `chr6:32000000-32100000` to land on the human MHC region, where `chr6` stands for the sequence name your own file uses, which may differ.

**Go to Gene...** matches gene names from the bundle's [GFF](../../GLOSSARY.md#gff) or GenBank annotation, and finds nothing when the open file has none. It takes Cmd-Opt-G rather than Cmd-G because **Find Next** already uses Cmd-G, and two commands cannot share the same keys.

**Copy Visible Region as FASTA** puts [FASTA](../../GLOSSARY.md#fasta) text on the clipboard. **Extract Visible Region...** opens a dialog and saves a new bundle into the project's `Extractions/` folder. **Add Annotation...**, **Edit Annotation...**, **Delete Annotation**, and **Find ORFs...**, which finds open reading frames, sit at the bottom of the menu with no shortcuts. The two annotation editing commands act on the annotation selected in the annotation table below the sequence.

## Selection menu

Commands that act on whatever you have selected in the sidebar or in a result table. The menu has two submenus, **Sidebar Item** and **Table Row**, and one command of its own, **Show in Inspector**. Every item here is the same command the right-click menu of that row offers, so you never need the mouse to reach one.

| Action | Shortcut | Origin |
|---|---|---|
| Sidebar Item > New Folder... | Cmd-Shift-N | Standard macOS (Finder) |
| Sidebar Item > Duplicate | Cmd-D | Standard macOS (Finder) |
| Sidebar Item > Move to Trash | Cmd-Delete | Standard macOS (Finder) |
| Sidebar Item > Select Siblings | Cmd-Shift-A | LGE's own |
| Show in Inspector | Cmd-Opt-S | LGE's own |

The **Sidebar Item** submenu works while the sidebar list has focus, so click a sidebar row first. Its items are greyed out whenever they do not apply to the selected rows, so **Open Bundle** stays disabled on a folder and **Reassemble...** stays disabled on anything that is not an assembly. Cmd-Shift-N New Folder, Cmd-D Duplicate, and Cmd-Delete Move to Trash carry the meanings Finder gives them. Cmd-Delete moves the selected rows to the Trash, and inside a text field it keeps its usual meaning of deleting to the start of the line, because the sidebar command is disabled while a text field has focus. **Select Siblings** selects every item beside the selected one in the same folder, which is the quick way to pick every barcode of a run.

The **Table Row** submenu works while a result table has focus, such as the taxonomy table of a classifier result or the annotation table below a sequence. It holds the commands those tables offer on a right-click, from **Extract Reads...** and **Verify with BLAST...** to the copy commands and the NCBI and PubMed links, and each table enables only the ones it supports.

**Show in Inspector** sits on its own because it means the same thing everywhere. It reveals the Inspector and shows the selected sidebar item, variant, chromosome, or tree node there.

## Tools menu

This row works whenever a project window is in front.

| Action | Shortcut | Origin |
|---|---|---|
| Plugin Manager... | Cmd-Shift-B | LGE's own |

The Plugin Manager installs and removes [plugin packs](../../GLOSSARY.md#plugin-pack). B is not a mnemonic.

The **Genotype Review** submenu of the Tools menu holds four more, plus a **Selected Cell** submenu for the comparison matrix. They act on the genotype result window described in [Inside the genotype result window](#inside-the-genotype-result-window), and they stay greyed out until a sample is selected there.

| Action | Shortcut | Origin |
|---|---|---|
| Mark Sample Reviewed | Cmd-R | LGE's own |
| Mark Sample Confirmed | Cmd-K | LGE's own |
| Flag Sample for Review | Cmd-Shift-F | LGE's own |
| Sample Detail… | Cmd-Shift-O | LGE's own |

Nothing else in the Tools menu has a shortcut, including **Call Variants...**, **Workflow Library...**, **Haplotype Definitions...**, the **Search Online Databases** submenu, and every individual tool.

## Operations menu

This row works whenever a project window is in front.

| Action | Shortcut | Origin |
|---|---|---|
| Show Operations Panel | Cmd-Shift-P | LGE's own |
| Selected Operation, Copy CLI Command | Cmd-Opt-C | LGE's own |
| Selected Operation, View Log | Cmd-Opt-L | LGE's own |
| Selected Operation, Reveal Output Files | Cmd-Opt-O | LGE's own |

The [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) lists every operation you started. **Clear Completed** and **Cancel All Operations** sit below it without shortcuts, and **Cancel All Operations** stays greyed out until something cancellable is actually running.

The **Selected Operation** submenu carries the same commands as the panel's right-click menu, from **Copy CLI Command** to **Clear Selected Operation**. Its items work only while the Operations window is in front and a row is selected, and each one is greyed out when it does not apply to that row, so **View Log** stays disabled until the operation has written a log line. Three of them have shortcuts. The rest, such as **Copy Log**, **Reveal Log in Finder**, **Run Again...** and **Copy Failure Report**, are chosen from the menu.

## Window menu

Both rows act on the front window.

| Action | Shortcut | Origin |
|---|---|---|
| Minimize | Cmd-M | Standard macOS |
| New Window for Current Project | Cmd-Opt-N | LGE's own |

**New Window for Current Project** opens a second window onto the same project so you can keep two views side by side, and it is greyed out until a project is open. **Zoom** and **Bring All to Front** have no shortcuts.

## Help menu

This row works whenever LGE is the front application.

| Action | Shortcut | Origin |
|---|---|---|
| Lungfish Genome Explorer Help | Cmd-Shift-slash (Cmd-?) | Standard macOS |

Press Command, Shift, and the slash key together, which is what a question mark takes on a US keyboard. The other Help items open documents rather than commands and carry no shortcuts. They are **Getting Started**, **Demo Projects…**, **VCF Variants Guide**, **AI Assistant Guide**, **Documentation**, **Release Notes**, and **Report an Issue...**. **Demo Projects…** opens the list of downloadable practice projects that [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) describes.

## Inside the sequence viewport

Click into the sequence display itself before pressing any of these, because they reach the display only while it has focus.

The left and right arrow keys move the view sideways by 100 bases each press, a fixed step that does not change with the zoom level. The up and down arrows zoom in and out rather than scrolling, which is the opposite of what most document windows do and is worth a moment to get used to. Cmd-C copies the current selection and Cmd-A selects the whole sequence, the same thing the Edit menu's own Copy and Select All do from here. Cmd-plus, Cmd-minus, and Cmd-0 zoom in, zoom out, and zoom to fit, and the equals and underscore keys work in place of plus and minus.

The Escape key does one of two things, decided by whether the sequencing reads over the view are still being fetched. While they are loading, Escape cancels that load, which is the way out of a region carrying very many reads that is taking a long time. When nothing is loading, Escape clears the current selection instead.

The coordinate ruler above the sequence takes Cmd-0 for zoom to fit and Cmd-1 for the 10 kilobase reset, matching the View menu.

In the annotation table below the sequence, the up and down arrows move the selection and Return or Enter does what a double-click does. On the Annotations tab, selecting a row already recentres the viewport on it. On the Variants tab, selecting a row updates the Inspector and leaves the viewport where it is, so press Return to recentre the viewport on the selected variant.

Every command the annotation table offers on a right-click also works without the mouse. With a row selected, **Selection > Table Row** holds the copy, extract and open commands for it, **Sequence > Edit Annotation...** and **Sequence > Delete Annotation** act on the selected annotation, and **Selection > Show in Inspector** (Cmd-Opt-S) shows it in the Inspector. VoiceOver lists the same commands as actions on the row, under the names the right-click menu uses with the submenu name in front, such as `Copy: Copy Name`, and lists the Profiles, Group Presets, haploid-mode and export buttons' menus as actions on those buttons.

The chromosome list on the left of a reference bundle and the sequence table of a multi-sequence FASTA file follow the same pattern. The up and down arrows move the selection, Return or Enter jumps to the selected chromosome or opens the selected sequence, and **Selection > Table Row** holds the copy and extract commands for the selected rows.

When several sequences are stacked, the track header on the left shows a disclosure triangle beside each sequence that has annotations. Press Tab until the header has focus, which draws a focus ring around a track, then Up Arrow and Down Arrow move the ring between tracks and Space or Return shows or hides that track's annotations. **View > Show Annotations for Selected Track**, which reads Hide Annotations for Selected Track while the annotations are shown, does the same for the focused track, or for the active sequence when the header does not have focus.

## Inside the BAM alignment viewport

The BAM alignment viewport is the sequence viewport of a reference bundle that carries alignment tracks, such as the reference bundle inside a mapping result that [Reading an Alignment](../04-alignments/02-reading-an-alignment.md) opens. It is the same display, so every key in [Inside the sequence viewport](#inside-the-sequence-viewport) works here too. Click into the display first. The left and right arrows pan by 100 bases, the up and down arrows zoom, Cmd-plus, Cmd-minus, and Cmd-0 zoom in, zoom out, and zoom to fit, and Cmd-C and Cmd-A copy and select. Escape is most useful here, because this is where reads load. While they are being fetched Escape cancels the load, and otherwise it clears the selection.

The read displays inside the TaxTriage, EsViritu, and NVD result windows are this same viewport, so the same keys apply there.

## Inside the classifier read viewer

The NAO-MGS result window shows the reads behind one hit in a compact read viewer, a small alignment display of its own. It takes Cmd-plus, Cmd-minus, and Cmd-0 for zoom in, zoom out, and zoom to fit. Click into that viewer first. It offers the same three commands on a right-click menu, beside **Center View Here**, so you can see them without remembering them, and it accepts the equals key for plus and the underscore or hyphen key for minus. Pinching on a trackpad zooms it too.

## Inside the MSA viewport

A multiple sequence alignment, meaning several sequences stacked so that matching positions line up in columns, takes Cmd-C to copy the selection and Cmd-A to select the whole alignment once you have clicked into it. The arrow keys move the selection one position at a time, and holding Shift while pressing them extends the selection rather than moving it. On a trackpad, pinching zooms the alignment.

The distance matrix on the Distances tab under the alignment has keys of its own once you click into it. The arrow keys move between cells, Shift with an arrow extends the selection, Opt with an arrow moves the focus without changing the selection, and Space adds or removes the focused cell. Return shows the focused pair in the alignment, Cmd-A selects every cell, Cmd-C copies the selected block with its sequence names, and Escape clears the selection. [Aligning Sequences](../02-sequences/04-aligning-sequences.md#pairwise-identity) describes the matrix.

## Inside the genotype result window

The genotype result window shows the alleles LGE [called](../../GLOSSARY.md#call) for each sample. Cmd-F, which is **Edit > Find...**, moves the cursor into its quick filter search field, and with that field focused, Escape clears it.

The four **Genotype Review** commands in the Tools menu work once a sample is selected in the window's Review lens, or a call is selected in a MiSeq result, and stay greyed out otherwise. Cmd-R marks the sample reviewed, Cmd-K marks it confirmed, Cmd-Shift-F flags it for review, and Cmd-Shift-O opens its Sample Detail sheet.

The comparison matrix inside that window, where each cell is one allele in one sample, has three review commands that hold Cmd and Opt together. They live in **Tools > Genotype Review > Selected Cell**, and they work only while the matrix has keyboard focus and a selection, so click a cell first. Cmd-Opt-P marks the selected cell a false positive, Cmd-Opt-X marks it a false negative, and Cmd-Opt-R clears the review mark. Edit Comment… and Remove Comments sit in the same Selected Cell menu with no shortcut, because Cmd-Opt-M belongs to macOS as Minimize All. All five also appear on the matrix's right-click menu. VoiceOver lists the commands that apply to a row, such as Select Supported Cells, Mark False Positive, Add Comment…, Hide Selected Row, and Show Only Selected Row, as actions on that row, and the **Columns** pull-down lists its items as actions on the button.

The known-allele overview, which draws a reference allele's gene, CDS, and exon blocks, is reachable from the keyboard. Tab moves into a lane that has blocks, and the Left Arrow and Right Arrow keys move between its blocks and show each block's details. Return or Space highlights the focused block, and Escape clears the highlight. VoiceOver reads each block as a button, and pressing a block highlights it, and a **Clear Highlight** action appears while it is highlighted.

## Inside a classifier result window

The TaxTriage sample shortcuts live in the View menu, listed above. In the taxonomy sunburst, the circular chart of nested organism groups, Escape steps back up one level, from the group you zoomed into to the broader group around it, and Cmd-0 returns to the full chart in one press. Cmd-0 there is **View > Zoom to Fit**, which LGE hands to the chart. Click the chart first. VoiceOver offers the chart a Zoom Into Selected Group action and a Zoom Out to Parent Group action, one level up, while each applies. Select the group by choosing its row in the taxonomy table, which selects the same group in the chart.

In the taxonomy table, with a row selected, **Selection > Table Row** holds **Extract Reads...**, **Verify with BLAST...**, **Copy Name**, and the NCBI and PubMed links for that taxon, and **View > Expand All** (Cmd-Shift-Right Arrow) and **View > Collapse All** (Cmd-Shift-Left Arrow) open and close the whole tree. VoiceOver lists the row's right-click commands as actions on the row.

Every result table in a classifier window answers **Selection > Table Row**. Click a row first, because the items work only while the table has focus. That covers the EsViritu detection list, the NVD contig list, the NAO-MGS and TaxTriage taxon tables, the 12S target and unresolved tables, the tree node table, and the BLAST results table that opens below any of them. Each table enables only the commands it supports, so **Copy Name** works in all of them, **Extract Reads...** in the classifier tables, and **Verify with BLAST...** wherever a row can be checked against NCBI. In NAO-MGS that item opens the read count popover, in place of the fixed 20, 50, and all-reads choices the right-click menu once listed. The same commands are VoiceOver actions on every row, under the same names.

The EsViritu, NVD, and BLAST results tables are outlines, so **View > Expand All** (Cmd-Shift-Right Arrow) and **View > Collapse All** (Cmd-Shift-Left Arrow) work in them while they have focus. The NAO-MGS and TaxTriage tables are flat lists, so those two items stay greyed out there. In NAO-MGS, each accession button in the detail pane also offers **Copy Accession** as a VoiceOver action.

The menus that open from a button have VoiceOver actions too. The BLAST table lists **Show** or **Hide** for each optional column on its header, and the 12S window does the same for the imported metadata columns on its **Sample Columns** button, with **Import Metadata...** beside them. The 12S Export button lists its three formats. **File > Export > 12S Result...** has no shortcut, shows the same three formats as a sheet on the result window, with buttons named **Export CSV**, **Export TSV**, and **Export Excel Workbook**, and stays greyed out until a 12S result is in front.

## Inside the sidebar

Right-clicking in the sidebar opens a context menu, and four of its commands print shortcuts. **New Folder...** is Cmd-Shift-N, **Duplicate** is Cmd-D, **Move to Trash**, which reads **Move N Items to Trash** for several items, is Cmd-Delete, and **Select Siblings** is Cmd-Shift-A. The same four live in **Selection > Sidebar Item**, so they work whenever the sidebar list has focus, with no menu open, and **Selection > Show in Inspector** (Cmd-Opt-S) reveals the selected item in the Inspector from there too.

One more works whenever the sidebar list has focus and appears in no menu. Delete or Forward Delete moves the selected items to the Trash. Moving an item to the Trash removes it from the project, and recovering it means retrieving it from the Trash yourself.

## What LGE does not bind

A user of another sequence viewer will reach for these and find them missing or different.

- **Cmd-S** does nothing, because LGE saves every change as you make it.
- **The arrow keys inside a viewport** zoom and pan the display rather than scrolling it.
- **Zoom to selection, annotate, and BLAST** have no shortcuts at all. Reach them from the menu bar or a right-click menu.

No two menu-bar shortcuts share a key combination.

## Mouse and trackpad

Shortcuts are not the only way to drive LGE. Scrolling moves the viewport along the sequence, pinching on a trackpad zooms the sequence, MSA, and classifier read viewports, holding Cmd or Opt while scrolling zooms the sequence viewport, and right-clicking almost anything in the sidebar or a result table opens a context menu of the operations that apply to it. When a shortcut slips your mind, the menu bar prints it, and a context menu prints the ones that belong to it.

## Memorizing combinations

A few patterns repeat, and knowing them beats memorizing every row one at a time. This section uses combination and [chord](../../GLOSSARY.md#chord) for the same thing, a set of keys pressed together.

Cmd-Shift-letter usually opens or toggles a panel, which is where **Show Operations Panel**, **Plugin Manager...**, and **Import Center...** come from. For the Sequence menu commands, Cmd-Shift-letter performs the action on the visible region instead, which covers Extract, Copy, Translate, and Reverse Complement. Cmd-Opt-letter targets the inspectors and a few window-level commands, which is **Show Inspector**, **Show in Inspector**, **AI Assistant**, **Provenance Inspector**, **Focus Viewer**, and **New Window for Current Project**. **Go to Gene...** is the exception, on Cmd-Opt-G only because Find Next holds Cmd-G.

The Sidebar breaks the first pattern. It toggles with Ctrl-Cmd-S rather than Cmd-Shift-S, because Control is what the macOS standard uses for that particular panel.

## Where Escape does something

Escape does a different job in each window.

| Where | What Escape does |
|---|---|
| Sequence or BAM alignment viewport, reads loading | Cancels the read load |
| Sequence or BAM alignment viewport, nothing loading | Clears the current selection |
| Position field of the coordinate ruler | Restores the display and leaves the field |
| Genotype quick filter field | Clears the field |
| Taxonomy sunburst, zoomed in | Steps back up one level |
| Taxonomy sunburst, at the full chart | Clears the selection |
| A hover tooltip panel | Closes the panel |
| Manage Project Storage sheet | Closes the sheet |
| Distance matrix under an alignment | Clears the cell selection |

## Customizing shortcuts

Any LGE menu item can be remapped from System Settings, which is a macOS feature rather than an LGE one and works the same way for every application. Open System Settings, click Keyboard, then Keyboard Shortcuts, then App Shortcuts. Click the plus button and choose Lungfish Genome Explorer from the application list. A preview build appears under its own name, such as Lungfish Preview, so pick the name printed in that copy's own menu bar, and use Other to browse for the app when it is not listed.

Type the menu title into the Menu Title field exactly, including any trailing ellipsis. `Reverse Complement...` and `Translate...` both end in a single ellipsis character rather than three periods, and an entry with three periods will not match the menu item. Type an ellipsis with Opt-semicolon on a US keyboard, or copy the title straight from the menu. Click into the Keyboard Shortcut field, press the new combination, then click Add. Quit LGE with Cmd-Q and reopen it for the override to take effect. Deleting the entry from the same panel restores the built-in shortcut.

## Index of every shortcut

Sorted by the final key, letters and numbers first in alphabetical order with Delete and Escape filed under D and E, then symbol keys, then arrow keys. Each row names where the shortcut works, because several combinations mean different things in different windows.

| Shortcut | Action | Where |
|---|---|---|
| Cmd-0 | Zoom to Fit | View menu, sequence and BAM alignment viewports, coordinate ruler |
| Cmd-0 | Zoom to fit | Classifier read viewer |
| Cmd-0 | Zoom to Fit, returning to the full chart | View menu, taxonomy sunburst |
| Cmd-Opt-0 | Content Text Size, Default | View menu |
| Cmd-Shift-0 | All Samples | View menu, TaxTriage result window |
| Cmd-1 | Zoom Reset (10kb) | View menu, coordinate ruler |
| Cmd-A | Select All | Edit menu, sequence viewport, MSA viewport |
| Cmd-Opt-A | AI Assistant | View menu |
| Cmd-Shift-A | Sidebar Item, Select Siblings | Selection menu, sidebar list |
| Cmd-Shift-B | Plugin Manager... | Tools menu |
| Ctrl-Cmd-B | Show Drawer | View menu |
| Cmd-C | Copy | Edit menu, sequence viewport, MSA viewport |
| Cmd-Opt-C | Selected Operation, Copy CLI Command | Operations menu |
| Cmd-Shift-C | Copy Visible Region as FASTA | Sequence menu |
| Cmd-D | Sidebar Item, Duplicate | Selection menu, sidebar list |
| Cmd-Delete | Sidebar Item, Move to Trash | Selection menu, sidebar list |
| Delete | Move to Trash | Sidebar list |
| Cmd-Shift-E | Extract Visible Region... | Sequence menu |
| Escape | Cancel read load or clear selection | Sequence and BAM alignment viewports |
| Escape | Clear the quick filter field | Genotype quick filter field |
| Escape | Step back up one level | Taxonomy sunburst |
| Cmd-F | Find... | Edit menu, genotype result window's quick filter field |
| Cmd-Shift-F | Flag Sample for Review | Tools menu, Genotype Review |
| Cmd-Opt-F | Focus Viewer | View menu |
| Ctrl-Cmd-F | Enter Full Screen | View menu |
| Ctrl-Cmd-Opt-F | Restore Side Panes | View menu |
| Cmd-G | Find Next | Edit menu |
| Cmd-Shift-G | Find Previous | Edit menu |
| Cmd-Opt-G | Go to Gene... | Sequence menu |
| Cmd-H | Hide Lungfish Genome Explorer | Application menu |
| Cmd-Opt-H | Hide Others | Application menu |
| Cmd-Opt-I | Show Inspector | View menu |
| Cmd-Shift-I | Import Center... | File menu |
| Cmd-K | Mark Sample Confirmed | Tools menu, Genotype Review |
| Cmd-L | Go to Location... | Sequence menu |
| Cmd-Opt-L | Selected Operation, View Log | Operations menu |
| Cmd-M | Minimize | Window menu |
| Ctrl-Cmd-M | Show Distance Matrix | View menu |
| Cmd-N | New Project | File menu |
| Cmd-Opt-N | New Window for Current Project | Window menu |
| Cmd-Shift-N | Sidebar Item, New Folder... | Selection menu, sidebar list |
| Cmd-O | Open Project Folder... | File menu |
| Cmd-Opt-O | Selected Operation, Reveal Output Files | Operations menu |
| Cmd-Shift-O | Sample Detail… | Tools menu, Genotype Review |
| Cmd-Opt-P | Selected Cell, Mark False Positive | Tools menu, Genotype Review, genotype comparison matrix |
| Cmd-Shift-P | Show Operations Panel | Operations menu |
| Cmd-Q | Quit Lungfish Genome Explorer | Application menu |
| Cmd-R | Mark Sample Reviewed | Tools menu, Genotype Review |
| Cmd-Opt-R | Selected Cell, Clear Review | Tools menu, Genotype Review, genotype comparison matrix |
| Cmd-Shift-R | Reverse Complement... | Sequence menu |
| Ctrl-Cmd-S | Show Sidebar | View menu |
| Cmd-Opt-S | Show in Inspector | Selection menu, sidebar list and result tables |
| Cmd-Shift-T | Translate... | Sequence menu |
| Cmd-Shift-U | Show as RNA (U instead of T) | View menu |
| Cmd-V | Paste | Edit menu |
| Cmd-Opt-V | Provenance Inspector | View menu |
| Cmd-W | Close | File menu |
| Cmd-X | Cut | Edit menu |
| Cmd-Opt-X | Selected Cell, Mark False Negative | Tools menu, Genotype Review, genotype comparison matrix |
| Cmd-Z | Undo | Edit menu |
| Cmd-Shift-Z | Redo | Edit menu |
| Cmd-comma | Settings... | Application menu |
| Cmd-plus | Zoom In | View menu, sequence and BAM alignment viewports, classifier read viewer |
| Cmd-Opt-plus | Content Text Size, Larger | View menu |
| Cmd-minus | Zoom Out | View menu, sequence and BAM alignment viewports, classifier read viewer |
| Cmd-Opt-minus | Content Text Size, Smaller | View menu |
| Cmd-left bracket | Previous Sample | View menu, TaxTriage result window |
| Cmd-right bracket | Next Sample | View menu, TaxTriage result window |
| Cmd-Shift-slash | Lungfish Genome Explorer Help | Help menu |
| Arrow keys | Pan sideways, zoom up and down | Sequence and BAM alignment viewports |
| Arrow keys | Move the selection, Shift extends it | MSA viewport |
| Arrow keys | Move between cells, Shift extends, Opt moves the focus only | Distance matrix |
| Return | Show the focused pair in the alignment | Distance matrix |
| Space | Add or remove the focused cell | Distance matrix |
| Return | Recentre the viewport on the selected row | Annotation table |
| Return | Jump to the selected chromosome | Chromosome list |
| Return | Open the selected sequence | FASTA collection table |
| Space or Return | Show or hide the focused track's annotations | Track header |
| Up and Down arrows | Move the focus ring between tracks | Track header |
| Opt-Right Arrow | Expand the selected row recursively | Taxonomy table |
| Cmd-Shift-Right Arrow | Expand All | View menu, outline result tables |
| Cmd-Shift-Left Arrow | Collapse All | View menu, outline result tables |

## Accessibility

VoiceOver, the screen reader built into macOS, reads every LGE menu item with its shortcut. Inspector rows publish their right-click commands as VoiceOver actions, so Reveal in Finder, Copy Command, or Remove Attachment is reachable from the VoiceOver Actions menu (VO-Command-Space) without a mouse. Turn it on with Cmd-F5, adding fn on a laptop keyboard whose F5 key is a media key, then press Ctrl-Opt-M to move into the menu bar. Full Keyboard Access, in System Settings under Keyboard, lets Tab move between controls and Space activate the one with focus. When interface text is too small, use **View > Content Text Size**, where Cmd-Opt-plus enlarges LGE's own text everywhere, Cmd-Opt-minus shrinks it, and the Default item restores it. That is separate from the viewport zoom and from macOS display scaling.

## Next

See [CLI Reference](cli-reference.md), which is for people who type commands in a terminal window instead of clicking, or [Troubleshooting](troubleshooting.md) when a shortcut does not appear to work.
