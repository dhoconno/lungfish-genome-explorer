# Shotlist: From Reads to Variants

This file is a sibling of the chapter, not a published manual page. It exists so the user can capture the chapter's eight screenshots by hand in a deterministic visual state. Each block below corresponds to one `<!-- SHOT: id -->` marker in `01-reads-to-variants.md`, in order.

## How to use this shotlist

- Resize the Lungfish window to 1280x800 before each capture using `Window > Zoom > Custom...` or the resize handle on the bottom-right corner.
- Capture with `Cmd-Shift-4`, then `Space`, then click the Lungfish window. The PNG saves to your Desktop.
- Move each PNG to the path listed under `File:` for that shot. Replace any earlier copy at the same path.
- Confirm each PNG is exactly 1280x800 (or the flagged exception) before committing under `docs/user-manual/assets/screenshots/04-variants/`.

The user already has the working project from running `regenerate.sh`; the shots below assume that project is open and named "From Reads to Variants".

---

### Shot 1: ncbi-download-dialog

**File:** `docs/user-manual/assets/screenshots/04-variants/ncbi-download-dialog.png`

**Window:** Lungfish project window, sized 1280x800.
**Active project:** "From Reads to Variants".
**Sidebar:** project sidebar visible; no item selected yet.
**Action:** choose `File > Download from NCBI > Reference Sequence...`.
**Capture:** dialog open with `MN908947.3` typed into the accession field, `Format` set to `FASTA`, `Download` button enabled and focused, before the click.
**Caption:** "Downloading the SARS-CoV-2 reference from NCBI."

---

### Shot 2: sra-download-dialog

**File:** `docs/user-manual/assets/screenshots/04-variants/sra-download-dialog.png`

**Window:** Lungfish project window, sized 1280x800.
**Active project:** "From Reads to Variants".
**Sidebar:** `Reference Sequences > MN908947.3` already present from Shot 1.
**Action:** choose `File > Download from SRA...`.
**Capture:** dialog open with `SRR36291587` typed into the accession field, `Layout` set to `Auto-detect`, `Download` button enabled, before the click.
**Caption:** "Pulling SRR36291587 from SRA."

---

### Shot 3: mapping-wizard

**File:** `docs/user-manual/assets/screenshots/04-variants/mapping-wizard.png`

**Window:** Lungfish project window, sized 1280x800.
**Active project:** "From Reads to Variants".
**Sidebar:** `MN908947.3` selected so it is the active bundle; both FASTQs visible under `Downloads/`.
**Action:** choose `Tools > Map Reads...` to open the Mapping wizard.
**Capture:** wizard open with both FASTQs paired in the `Reads` section, `Mapper` set to `minimap2`, `Preset` set to `Short read (sr)`, sample name reading the run accession, `Advanced Options` collapsed, `Run` button enabled but not yet clicked.
**Caption:** "Mapping reads to MN908947.3 with minimap2."

---

### Shot 4: primer-trim-dialog

**File:** `docs/user-manual/assets/screenshots/04-variants/primer-trim-dialog.png`

**Window:** Lungfish project window, sized 1280x800.
**Active project:** "From Reads to Variants".
**Sidebar:** `SRR36291587 (minimap2)` alignment track selected under `MN908947.3 > Alignments`; Inspector visible on the right.
**Action:** in the Inspector's `Read Style` section, click `Primer-trim BAM...`.
**Capture:** Primer Trim dialog open with `QIASeqDIRECT-SARS2` chosen in the `Primer scheme` picker, `Advanced Options` collapsed, the auto-populated output track name `SRR36291587 (minimap2) - Primer-trimmed (QIASeqDIRECT-SARS2)` visible, `Run` button enabled but not yet clicked.
**Caption:** "Primer-trimming with the QIASeqDIRECT-SARS2 scheme."

---

### Shot 5: variant-call-dialog-ivar

**File:** `docs/user-manual/assets/screenshots/04-variants/variant-call-dialog-ivar.png`

**Window:** Lungfish project window, sized 1280x800.
**Active project:** "From Reads to Variants".
**Sidebar:** the primer-trimmed alignment track selected under `MN908947.3 > Alignments`; Inspector visible.
**Action:** in the Inspector's `Duplicate Handling` section, click `Call Variants...`, then select `iVar` in the dialog's tool sidebar.
**Capture:** Call Variants dialog open with `iVar` selected on the left, `Inputs` showing the primer-trimmed track, the `This BAM has already been primer-trimmed for iVar` acknowledgement auto-checked and disabled with the caption `Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2`, `iVar Options` expanded showing the four tunables at their defaults, output name `iVar variants`, `Run` not yet clicked.
**Caption:** "Calling variants with iVar against the primer-trimmed alignment."

---

### Shot 6: variant-call-dialog-lofreq

**File:** `docs/user-manual/assets/screenshots/04-variants/variant-call-dialog-lofreq.png`

**Window:** Lungfish project window, sized 1280x800.
**Active project:** "From Reads to Variants".
**Sidebar:** the original `SRR36291587 (minimap2)` track selected (not the primer-trimmed one); Inspector visible.
**Action:** click `Call Variants...` again, then select `LoFreq` in the dialog's tool sidebar.
**Capture:** Call Variants dialog open with `LoFreq` selected on the left, `Inputs` showing the un-trimmed track, no primer-trim acknowledgement, only `Reference` and `Output` rows visible, output name `LoFreq variants`, `Run` not yet clicked.
**Caption:** "Calling variants with LoFreq against the un-trimmed alignment."

---

### Shot 7: variant-tables-side-by-side

**File:** `docs/user-manual/assets/screenshots/04-variants/variant-tables-side-by-side.png`

**Window:** Lungfish project window, sized 1440x900 (wider than the uniform default so both `Caller` rows and the genome track read clearly without wrapping).
**Active project:** "From Reads to Variants".
**Sidebar:** `iVar variants` selected, `LoFreq variants` Cmd-clicked so both tracks are highlighted under `MN908947.3 > Variants`.
**Action:** with both tracks loaded in the variant browser, click the `PASS` chip if needed so `Quality / QC: PASS` is active, then sort the table by `POS` ascending.
**Capture:** variant browser showing both tracks color-coded on the genome track at the top, table at the bottom sorted by `POS` ascending with the `Caller` column visible, the upper rows of the table in view starting near the start of the genome.
**Caption:** "Both VCF tracks open in the variant browser."

---

### Shot 8: cross-caller-comparison

**File:** `docs/user-manual/assets/screenshots/04-variants/cross-caller-comparison.png`

**Window:** Lungfish project window, sized 1440x900 (same wider dimensions as Shot 7 for table legibility).
**Active project:** "From Reads to Variants".
**Sidebar:** both `iVar variants` and `LoFreq variants` still loaded together.
**Action:** scroll the table to position 28881 so the three adjacent N-gene SNPs at 28881, 28882, and 28883 are centered, with the genome track at the top scrolled to the same region.
**Capture:** variant browser with the genome track centered on the 28881-28883 cluster, table rows for both callers at those positions visible together so agreements appear as paired rows and any solo rows read as disagreements; `Caller` column clearly distinguishes iVar from LoFreq.
**Caption:** "Where iVar and LoFreq agree and where they disagree."
