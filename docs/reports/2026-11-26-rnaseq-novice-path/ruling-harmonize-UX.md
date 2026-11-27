# UX ruling: RNA-seq reference rows in Plugin Manager > Databases (2026-11-27)

Seat UX. Model claude-opus-5-5, effort not named in the prompt. Code at 4ed9cbb03 (worktree vigorous-easley-016cc5). This ruling is revised for the owner's direction of 2026-11-27 ("how much disk space it will use. That is all we should show") and for the corrected disk figures in the brief.

## 1. Placement: inside the List
- The four rows become the last `Section` of the `List` in `databaseList` (`PluginManagerView.swift:922-969`). The header is "RNA-seq Reference Sets" in the tool headers' style (`:959-962`), and each row gets `.listRowBackground(Color.lungfishCardBackground)` (`:956`).
- **Why.** Today the section is a fixed-height block below the list (`RNASeqReferenceSetsSection.swift:22-28`, `PluginManagerView.swift:811`).
  - The Kraken2 list shrinks to a two-row scroll pane. In `databases-tab-idle.jpg` only EuPathDB46 and half of Greengenes show, and the recommended PlusPF-16 is out of view.
  - The tab has two scroll areas and two row styles.
- **ARCH trap** (`ruling-ARCH.md:66`). The List is drawn only when the metagenomics catalog has rows (`PluginManagerView.swift:805-809`), so a section nested in it would be hidden while that catalog loads or is empty.
  - The fix is to draw `databaseList` every time.
  - When `viewModel.databases.isEmpty`, its first row is a small spinner and "Loading database catalog..." (the words at `:887`), in place of the tool sections. The RNA-seq section follows that row.
  - The full-height placeholder (`:882-892`) leaves this tab. This keeps what the trap protects.
- `.task` and `.onReceive` (`RNASeqReferenceSetsSection.swift:51-54`) must still run once for the section, not once per row, after the move into a List section. ARCH decides where they go.
- **File size.** `PluginManagerView.swift` has 1283 lines against a baseline of 1283 (`scripts/ratchets/file-size.baseline:39`). Folding `:804-811` into one call saves about six lines, which pays for the loading row and the section call.

## 2. Row anatomy, in the order of DatabaseRow (`PluginManagerView.swift:1033-1170`)
1. **Status icon.** Use the shapes at `:1175-1199`:
   - `.ready`: a sage dot.
   - `.notInstalled`: a grey ring.
   - `.setWithoutIndex`: a creamsicle dot, as for `.corrupt`.
   - While installing: a small spinner, 20 by 20.
2. **Name.** `entry.title` in `.headline` (`:1042-1043`), not `.body` (`RNASeqReferenceSetsSection.swift:60`). It gets no Recommended or Update badge, since the banner sizes Kraken2 only (`ruling-UX.md:45`, trap 6).
3. **Size line.** One figure: the disk space the set uses once installed.
   - It sits where the Kraken2 size sits (`PluginManagerView.swift:1070-1072`): caption, secondary colour, formatted by `LungfishFormatters.formatBytes`, which is decimal (`LungfishFormatters.swift:28-29`).
   - It is the same figure in every state, and it shows no RAM figure, no download size and no time.
   - The figures come from galah's measurement: human 18.6 GB, mouse 15.0 GB, rhesus 10.9 GB, cynomolgus 13.5 GB. Pin them per catalog entry as measured bytes, because the catalog's fields do not add up to them (`ReferenceSetCatalog.swift:54-68`; for human, 0.97 GB of downloads plus 10.5 GB unpacked is not 18.6 GB). ARCH names the field.
   - The "RAM" that was asked about is `memoryNeedBytes`, the peak memory of a count, 6.0 GiB with a served index (`ReferenceSetCatalog.swift:24-26`). It is not Kraken2's memory to load a database. Under the owner's direction it shows only in the refusal below.
4. **Description.** `ReferenceSetCatalog.description` in caption, secondary colour, `.lineLimit(1)` (`:1086-1089`). Editorial owns the words.
5. **Status line.** This is Kraken2's tracking-line slot (`:1091-1094`): caption2, one line.
   - In the normal states it is absent, since the icon and the action already say whether the set is installed.
   - It holds only an exceptional fact, in creamsicle, the colour of the exceeds-RAM text (`:1077-1082`):
     - **Download is off for memory.** One line that names the need, for example "Needs about 6 GB of memory to count, more than this Mac has". Memory comes first, since installing the pack cannot fix it.
     - **Download is off because the pack is missing.** "Install the RNA-Seq Analysis pack first, on the Packs tab." (`ruling-UX.md:44`).
     - **`.setWithoutIndex`.** One line saying that Download finishes the install. Editorial writes it.
   - **Per row, not one line under the section.**
     - The reason sits beside the button it explains.
     - A footer can scroll away from that button in a List.
     - VoiceOver reads the reason with its row.
     - Kraken2's memory note is per row too (`:1079-1083`).
     - A help tag is never the only home of a refusal (design-system README, Where words go, place 3). The Linux pointer (`RNASeqReferenceCatalogModel.swift:78-79`) is dropped from the row.
6. **Action area,** as at `:1204-1253`.
   - **Download.** `.controlSize(.small)` and `.borderedProminent`. It already matches Kraken2 (`RNASeqReferenceSetsSection.swift:103-107` against `PluginManagerView.swift:1246-1250`). The difference on screen is the card, not the button. It is disabled exactly when the status line holds a refusal (`:108`).
   - **Cancel.** `role: .cancel`, small, as it already is (`:90-95`). After a cancel the row reads Download again, with no failure line and no alert.
   - **Ready.** "Installed" in caption, medium weight, sage (`PluginManagerView.swift:1218-1221`), not "Ready to count". Show no Remove, enabled or disabled, until RNASEQ-CATALOG-MORE-ROWS.
   - **Progress,** under the row, 34 points from the leading edge and 8 from the trailing edge (`:1153-1167`).
     - Show the bar only when `fraction` exists (UX 3, E-EP-9).
     - Show the stage message whenever it exists, with or without a bar (`ruling-UX.md:41`), in caption2 on one line.
     - Use `.truncationMode(.middle)` so the "N MB of M MB" end stays in view.
   - **Failure.** Use Kraken2's error row (`:1105-1126`): a creamsicle dot and text, two lines, and Dismiss, which clears `model.failure[id]`. It replaces the danger-coloured line, which has no Dismiss (`RNASeqReferenceSetsSection.swift:75-78`). Add a Dismiss accessibility id. The download and status ids stay, and the section id moves to the header.

## 3. Reuse: one shared layout in a new file
- **Do not reuse DatabaseRow itself.**
  - It is private (`:1009`) and typed on `MetagenomicsDatabaseInfo` (`:1011`).
  - In the ready state it draws Remove (`:1237-1243`) and version tracking (`:1091-1094`), and neither applies to a reference set.
- **Extract its frame into `Views/PluginManager/DatabaseRowLayout.swift`.**
  - The layout takes the icon, name, size, description, status line, action, error row and progress as slots or optional values, and it holds the status dot.
  - Both DatabaseRow and the RNA-seq row draw through it.
  - DatabaseRow passes exactly what it shows today, so the Kraken2 rows do not change. For example, Kraken2 still shows its message only with a bar (`:1153`).
  - With one source, the two row kinds cannot drift apart, and `PluginManagerView.swift` loses about 100 lines below its baseline.
- The RNA-seq row and section stay in `RNASeqReferenceSetsSection.swift`.
- ARCH owns the file split. If ARCH rules that this lane must not touch DatabaseRow, copy the frame instead, add a comment that names `PluginManagerView.swift:1033-1199`, and file a backlog row to extract it.

## 4. What goes
- The card chrome and the section's own frame: `RNASeqReferenceSetsSection.swift:22-28`, `:46-49` and `:83-85`, and the hand-drawn header at `:32-35`.
- The `needWords` line: `:64-66`, model `:82-91`, pinned at `RNASeqReferenceCatalogModelTests.swift:125-128`. The word "kept" goes with it.
- The single refusal line under the rows (`:39-44`) and the combined `memoryRefusal` (model `:66-69`, test `:124`).
- "Ready to count" (`:97-101`). The Operations row's "is ready to count" (model `:150`) stays, as the brief keeps that row.
- The header comment about the RAM badge and the placement outside the list (`:15-17`), rewritten for the new placement.
- Editorial also rewords "kept" in the Cancel help (`:95`) and "served index" in the Download help (`:110-115`).
- The manager pins the four disk figures, "Installed" and both refusal lines in tests, and updates `features.yaml` (UX 7).
