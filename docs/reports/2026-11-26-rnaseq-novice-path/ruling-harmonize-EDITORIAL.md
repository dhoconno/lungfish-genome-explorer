EDITORIAL verdict: RULED. One disk figure per row, "Installed" for a ready set, short refusals only while Download is off, plain progress lines. Calls used: 30 of 40.

1. Keep the section title "RNA-seq Reference Sets" (RNASeqReferenceSetsSection.swift:32) and the four row titles (ReferenceSetCatalog.swift:54,58,62,66) unchanged.
2. Set the description at ReferenceSetCatalog.swift:82 to "Genome, genes and salmon index for counting bulk RNA-seq reads."
3. lge-lane: make the size line one figure, the disk space used once installed. Add a per-entry byte count stored as 18_600_000_000, 15_000_000_000, 10_900_000_000 and 13_500_000_000, and print it with LungfishFormatters.formatBytes as "18.6 GB", "15 GB", "10.9 GB" and "13.5 GB".
4. lge-lane: the size figure has no label, download size, memory or time. Use the Kraken size Text style (PluginManagerView.swift:1067-1069) with help tag "Disk space this set uses once installed".
5. lge-lane: a ready set reads "Installed" in place of "Ready to count" (RNASeqReferenceSetsSection.swift:97), with help tag "Plugin Manager cannot remove a reference set yet."
6. A set that is not installed shows no state words beyond its Download button. If UX's layout draws a state line, that line reads exactly "Not installed".
7. A set present without its index shows "Partly installed. Download adds the missing salmon index." Its Download help tag is "Add the missing salmon index and finish the install".
8. The Download help tag for a set that is not installed is "Download and install this reference set". The Cancel help tag is "Cancel this install".
9. Memory refusal, shown only while Download is off for memory: "Counting needs 6 GB of memory, more than this Mac has. Count on a Linux computer instead, as the RNA-seq chapter of the manual shows." Print GiB with "%.0f", as formatDatabaseRAM does.
10. Pack refusal in the app, shown only while Download is off for the pack: "Install the RNA-Seq Analysis pack first, on the Packs tab." The CLI error at ReferenceSetInstall.swift:28 stays as it is.
11. lge-lane: download lines read "Downloading the genome, <done> of <total>", "Downloading the genes, <done> of <total>" and "Downloading the salmon index, <done> of <total>". Print both figures with LungfishFormatters.formatBytes. With no total, the line ends "<done> so far".
12. The set-build stage line reads "Building the reference set. This can take a while." Keep "Starting…", "Unpacking and checking the salmon index", "Building the salmon index, which takes about an hour" and every Operations row string.
13. lge-lane: re-pin RNASeqReferenceCatalogModelTests.swift:87-88 and :121-134, and pin every new string in items 2 to 12.
14. documentation-lead: in the same landing, change the manual lines that quote the old words, 11-rna-seq/02-counting-bulk-reads.md:149 and :155 and 01-foundations/07-plugin-packs.md:269. That last line names only two of the four sets.
15. lge-walker: after the landing, check that the tab shows 18.6 GB, 15 GB, 10.9 GB and 13.5 GB and that no row says "kept".
16. Open question for lge-ruling (UX and EDITORIAL): the preflight disk and memory refusal ends in CLI commands (ReferenceSetInstall.swift:55-56), and that sentence is the row's failure line in the app. It is not ruled here.

## Question: what exact words should the RNA-seq reference rows show to a bench scientist new to RNA-seq?

Inputs: the brief (BRIEF.md:3-53, with its table corrected to the measured disk figures at BRIEF.md:34-41), both screenshots, and the owner direction the coordinator relayed on 2026-11-27: "The only thing a user will care about is how much disk space it will use. That is all we should show." Under that direction the size line carries one figure. Refusal words appear only in the state where Download is off. All paths below are in the worktree at the brief's commit (head 4ed9cbb03).

### What the rows say now, and why it fails

- The size line is `needWords`, RNASeqReferenceCatalogModel.swift:83-91. For a set with a served index it reads "Download about N GB with the salmon index, about 18 GB kept, 6.0 GB of memory" (pinned at RNASeqReferenceCatalogModelTests.swift:125-126). "Kept" is the word the owner did not understand (BRIEF.md:5).
- "About 18 GB kept" is the same for every row, but galah measured 15.0 GB for mouse, 10.9 GB for rhesus and 13.5 GB for cynomolgus (BRIEF.md:36-39). For three of the four rows the figure is false, too high by up to 65% for rhesus. Severity is UX's call (this is not a scientific number). EDITORIAL reads it as a false figure, and this ruling removes it.
- The Kraken2 row prints its size with `LungfishFormatters.formatBytes` (PluginManagerView.swift:1067) and its RAM with `formatDatabaseRAM`, which prints GiB with "%.0f GB RAM" (PluginManagerView.swift:1270-1276). Both are short captions with no sentence.
- The Cancel help tag says "Finished downloads are kept for the next Download" (RNASeqReferenceSetsSection.swift:95). That is only partly true. The genome and GTF are reused (ReferenceSetInstall.swift:214-215), but a finished index archive is deleted when the function leaves, including on a cancel (:191), and a partial file is deleted too (:219). These words mislead without changing a result (S3). The new tag drops the claim.

### The ruled strings (old, then new, with source)

| Where | Source | Now | Ruled |
|---|---|---|---|
| Section title | RNASeqReferenceSetsSection.swift:32 | "RNA-seq Reference Sets" | unchanged |
| Row titles | ReferenceSetCatalog.swift:54,58,62,66 | "Human, GRCh38 with GENCODE 50" and the other three | unchanged |
| Description | ReferenceSetCatalog.swift:82 | "Genome, genes and salmon index for counting bulk reads." | "Genome, genes and salmon index for counting bulk RNA-seq reads." |
| Size line, human | RNASeqReferenceCatalogModel.swift:83-91 | "Download about 7 GB with the salmon index, about 18 GB kept, 6.0 GB of memory" | "18.6 GB" |
| Size line, mouse | same | "Download about 5 GB …, about 18 GB kept, 6.0 GB of memory" | "15 GB" |
| Size line, rhesus | same | "Download about 6 GB …, about 18 GB kept, 6.0 GB of memory" | "10.9 GB" |
| Size line, cynomolgus | same | "Download about 7 GB …, about 18 GB kept, 6.0 GB of memory" | "13.5 GB" |
| Size help tag | new | none | "Disk space this set uses once installed" |
| Ready state | RNASeqReferenceSetsSection.swift:97 | "Ready to count" | "Installed" |
| Ready help tag | new | none | "Plugin Manager cannot remove a reference set yet." |
| Not installed | RNASeqReferenceSetsSection.swift:102-107 | Download button only | Download button only. If UX draws a state line, "Not installed" |
| Set without index, visible | new | no visible words | "Partly installed. Download adds the missing salmon index." |
| Download help, not installed | RNASeqReferenceSetsSection.swift:110-112 | "Download the genome, genes and salmon index, and build the set" | "Download and install this reference set" |
| Download help, set without index | RNASeqReferenceSetsSection.swift:113-115 | "The set is here without its salmon index. Download gets the served index." | "Add the missing salmon index and finish the install" |
| Cancel help | RNASeqReferenceSetsSection.swift:95 | "Cancel this install. Finished downloads are kept for the next Download." | "Cancel this install" |
| Memory refusal, served index | RNASeqReferenceCatalogModel.swift:74-80 | "Counting needs about 6.0 GB of memory, more than this Mac has. Count on a Linux machine instead, as the RNA-seq chapter of the manual shows." | "Counting needs 6 GB of memory, more than this Mac has. Count on a Linux computer instead, as the RNA-seq chapter of the manual shows." |
| Memory refusal, built index | same | "Building the salmon index needs about 16.6 GB of memory, …" | "Building the salmon index needs 17 GB of memory, more than this Mac has. Count on a Linux computer instead, as the RNA-seq chapter of the manual shows." |
| Pack refusal | RNASeqReferenceCatalogModel.swift:94-96 (reads ReferenceSetInstall.swift:28) | "Install the RNA-Seq Analysis pack first, on the Packs tab of Plugin Manager. It holds salmon and gffread." | "Install the RNA-Seq Analysis pack first, on the Packs tab." (the app's own string, the CLI error unchanged) |
| Start | RNASeqReferenceCatalogModel.swift:130 | "Starting…" | unchanged |
| Genome and GTF download | ReferenceSetInstall.swift:155 | "Downloading <file name>, N MB of M MB" or "… of unknown" | "Downloading the genome, <done> of <total>" and "Downloading the genes, <done> of <total>", or "…, <done> so far" |
| Index download | ReferenceSetInstall.swift:189 | "Downloading the salmon index <long zip name>, N MB of M MB" | "Downloading the salmon index, <done> of <total>" |
| Set build stage | ReferenceSetInstall.swift:159 | "Building the reference set from the genome and the genes" | "Building the reference set. This can take a while." |
| Index unpack stage | ReferenceSetInstall.swift:192 | "Unpacking and checking the salmon index" | unchanged |
| Index build stage | ReferenceSetInstall.swift:173 | "Building the salmon index, which takes about an hour" | unchanged (built route only) |
| Operations row | RNASeqReferenceCatalogModel.swift:121,122,150,156 | title, "Downloading <title>", "<title> is ready to count", "Could not install <title>" | unchanged (brief, BRIEF.md:53) |

### Reasons

- Titles stay. The Operations row title is built from `entry.title` (RNASeqReferenceCatalogModel.swift:121, pinned at RNASeqReferenceCatalogModelTests.swift:46), and the brief keeps the Operations row (BRIEF.md:53). "Reference set" is also the term the quantify pane uses ("Download a reference set in Plugin Manager to count these reads.", RNASeqReferenceCatalogModelTests.swift:143). The titles put the organism first on purpose (ReferenceSetCatalog.swift:16).
- Description. A bench scientist does not know "bulk reads", but does know "bulk RNA-seq". The new text is 63 characters. That is shorter than the Greengenes description, which fits on one line in databases-tab-idle.jpg, and the Kraken description has lineLimit(1) (PluginManagerView.swift:1088).
- One bare figure, as the owner directed, in the Kraken size position ("36.51 GB" in the screenshot). The stored value follows the brief's precision. If the manager stored the exact du byte count, formatBytes would print two decimals, as 6_787_666_720 prints "6.79 GB", which is less plain. The figure counts the set, the unpacked index and the kept genome and GTF (BRIEF.md:41). The help tag says what the figure is without a word on the row.
- "Installed" is the Kraken row's word (PluginManagerView.swift:1214). When the install ends, the Operations row still says "is ready to count" (RNASeqReferenceCatalogModel.swift:150).
- "Partly installed" names the state at ReferenceSetCatalog.swift:37-38. Download in that state runs the whole install again and reuses what is there (ReferenceSetInstall.swift:118-119). Then it either downloads the served index or builds one (:169-174), so "adds" is true either way.
- Memory figures. Counting checks 6_445_798_776 bytes (SalmonQuantRoute+Reads.swift:11) and a local index build checks 17_780_281_048 (SalmonIndexNeed.swift:18). The Kraken RAM rule prints them as "6 GB" and "17 GB". BRIEF.md:44 says about 6 GB.
- Each refusal appears only while Download is off. The `.disabled` test at RNASeqReferenceSetsSection.swift:108 reads the same `memoryRefusal(entry)` and `toolsMissing` as the words at :39. Where the words sit is UX's call.
- Pack refusal. In the app the reader is already in Plugin Manager, so "of Plugin Manager" and the tool names are dropped. The CLI keeps its fuller sentence.
- Set-build stage. No fraction is reported during the set build (ReferenceSetInstall.swift:42-43), and the model clears the bar (RNASeqReferenceCatalogModel.swift:146). For most of an install, then, the row shows only words (BRIEF.md:46). "This can take a while." tells the reader the install has not stopped, and it invents no time.
- Progress figures use formatBytes. The current `megabytes` (ReferenceSetInstall.swift:253-255) would print the mouse index archive as "4399 MB". The zip file name is about 80 characters and was dropped.

### What I measured

- I ran `swift -e` with `ByteCountFormatter.string(fromByteCount:countStyle: .file)`, which is the call inside `LungfishFormatters.formatBytes` (LungfishFormatters.swift:28-30). Results: 18_600_000_000 printed "18.6 GB", 15_000_000_000 "15 GB", 10_900_000_000 "10.9 GB", 13_500_000_000 "13.5 GB", 6_787_666_720 "6.79 GB", 412_345_678 "412.3 MB", 1_204_000_000 "1.2 GB", 4_398_536_780 "4.4 GB" and 76_000_000 "76 MB". With `"%.0f GB"` of bytes / 1_073_741_824, 6_445_798_776 printed "6 GB" and 17_780_281_048 printed "17 GB".
- I added up the download bytes for each set from the catalog (ReferenceSetCatalog.swift:54-68): 6.79, 5.26, 6.17 and 6.83 GB. These match BRIEF.md:36-39.
- The free disk the preflight asks for is the archive plus the unpacked index plus 16 GB (ReferenceSetInstall.swift:197-205). That comes to 32.3 GB for human, 29.1 for mouse, 29.7 for rhesus and 31.5 for cynomolgus, which matches BRIEF.md:43. By the owner's direction the rows do not show it, and the preflight refuses before any byte downloads (ReferenceSetInstall.swift:141). Its words are item 16.

### Not checked, with confidence

- I did not find the Kraken download progress words, so I did not check that the progress lines match their shape (medium).
- I did not read whether the progress words reach the Operations row's detail through CLIManagedToolsRunner. The brief says they do (medium-high).
- I did not verify that the RNA-seq chapter of the manual shows a Linux route. The claim is carried over from the current words (medium).
- I did not measure the disk use of a set whose index was built on the Mac, the route taken when this Mac's salmon build differs from the served one (ReferenceSetInstall.swift:140, :173). Confidence that the figure holds there is medium.
- No build and no app run, so I saw none of the new strings on screen. I counted only the description's length.
- I checked the ruled strings against STYLE.md by hand (no em dash, semicolon, colon inside a sentence, or "!", STYLE.md:11-17, 81-82). I did not run the linter.
- EXPERT-PANEL.md has no EDITORIAL checklist rows. Its fields are SWIFT, ARCH, BIO, UX and QA (EXPERT-PANEL.md:40-77), so this ruling rests on STYLE.md and the brief.
- The feature route table (paired reads, moved project, replaced file, export and reopen) does not apply. This ruling sets words only and changes no result.

