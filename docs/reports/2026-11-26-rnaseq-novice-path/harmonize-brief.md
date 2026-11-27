# Brief: harmonize the RNA-seq reference rows in Plugin Manager > Databases (2026-11-27)

## The owner's words

"I don't understand why those downloads don't look like the other ones in the interface and I don't understand the text about space 'kept'. Have editorial agents improve the text so it is simpler and have the UI experts harmonize these downloads with others in the same interface."

## What to look at

- Screenshots of the Debug app, taken today:
  - `databases-tab-idle.jpg` (beside this brief) shows the Kraken2 rows above and the four RNA-seq rows below.
  - `databases-tab-installing.jpg` shows the Mouse row installing.
- The code is at commit 4ed9cbb03 of branch `claude/rnaseq-novice-path-6417ad`.
- The other downloads on the tab, the Kraken2 rows: `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`.
  - `private struct DatabaseRow` starts at about line 1009: a status icon, the name with Recommended and Update badges, a line with size and RAM, the description, a tracking line, and an action area for Download, progress, Cancel and Remove.
  - The database list (`databaseList`) is about line 920 on. It is a `List` with `Section`s by tool, and the section titles come from `tool.databaseSectionTitle`.
  - The "Recommended for your system" banner is about line 861.
- The RNA-seq rows: `Sources/LungfishApp/Views/PluginManager/RNASeqReferenceSetsSection.swift`.
  - Each row is its own rounded card, outside the `List`. It has a title, a description, and a long line from `needWords`.
  - Download is `.borderedProminent`. "Ready to count" is green text.
  - Refusals show as one caption line below all the rows.
- Their words and state: `Sources/LungfishApp/Views/PluginManager/RNASeqReferenceCatalogModel.swift`, which holds `needWords`, `memoryRefusal(_:)`, `toolsRefusal`, and the progress and stage messages from the CLI.
- The stage lines come from `Sources/LungfishWorkflow/RNASeq/ReferenceSetInstall.swift`:
  - "Building the reference set from the genome and the genes"
  - "Unpacking and checking the salmon index"
  - "Building the salmon index, which takes about an hour", only when no served index matches
  - "Downloading <file>, N MB of M MB"
- The catalog: `Sources/LungfishWorkflow/RNASeq/ReferenceSetCatalog.swift`.
  - The facts per entry are the title, `downloadBytes` (genome and GTF), `servedIndex.archiveBytes` and `servedIndex.unpackedBytes`, and `memoryNeedBytes` (6.0 GiB for a count with a served index).
  - The description is "Genome, genes and salmon index for counting bulk reads."
- Pinned words in tests: `Tests/LungfishAppTests/RNASeqReferenceCatalogModelTests.swift`.

## Facts the text may use

| Set | Download in all | Disk once installed |
|---|---|---|
| Human | 6.8 GB | 18.6 GB |
| Mouse | 5.3 GB | 15.0 GB |
| Rhesus | 6.2 GB | 10.9 GB |
| Cynomolgus | 6.8 GB | 13.5 GB |

Download in all is the genome, the GTF and the index archive. Disk once installed is the set, the unpacked index and the kept genome and GTF, all in decimal GB, measured on galah with du on 2026-11-27. The figures were corrected after this brief was first written.

- During the install, about 29 to 33 GB must be free.
- Counting needs about 6 GB of memory. A Mac with less has Download off.
- The install also needs the RNA-Seq Analysis pack (salmon and gffread). Without it, Download is off and the words name the pack.
- An install from LabKey took about 35 minutes for mouse on galah. Most of it is building the set (gffread), and the 4.4 GB index downloads at about 8 MB/s.
- A set cannot be removed from the app yet (backlog RNASEQ-CATALOG-MORE-ROWS).

## Rules

- Read AGENTS.md and `docs/user-manual/STYLE.md` for house wording: plain words, no jargon a bench scientist would not know, and no invented figures.
- Read only. Edit no code. Write one file, named in your prompt.
- The manager implements your ruling, keeps the CLI command and the Operations row as they are, and pins the final words in tests.
