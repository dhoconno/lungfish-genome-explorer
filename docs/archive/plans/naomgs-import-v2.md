# NAO-MGS Import v2 — Proper Bundle Architecture

## Current State (broken)
- Import creates a sorted BAM + BAI in `Imports/naomgs-{token}/`
- No JSON manifest → sidebar shows raw files instead of a single entity
- NaoMgsResultViewController displays but taxonomy table is empty (no data wired)
- Reference sequences not fetched from GenBank
- Clicking the BAM in sidebar shows QuickLook preview of BAI instead of alignment viewer

## Required Architecture

### 1. Bundle Structure
The import should produce a `.lungfishref` bundle (or a new `.lungfishnaomgs` bundle type):

```
naomgs-{sampleName}.lungfishref/
  manifest.json              ← standard BundleManifest
  {sampleName}.sorted.bam    ← sorted indexed BAM from SAM conversion
  {sampleName}.sorted.bam.bai
  virus_hits.json             ← serialized NaoMgsResult for fast reload
  references/                 ← auto-downloaded GenBank reference FASTAs
    KU162869.1.fasta
    MT791000.1.fasta
    ...
```

### 2. Sidebar Appearance
- Show as single item with "N" icon (like K/E/T for other classifiers)
- `isInternalSidecarFile` must hide .bai, .json, references/ from sidebar
- Double-clicking opens NaoMgsResultViewController

### 3. Taxonomy Table Population
The NaoMgsResultViewController.configure(result:) receives NaoMgsResult with:
- virusHits: [NaoMgsVirusHit] — 440K+ records
- taxonSummaries: [NaoMgsTaxonSummary] — 274 taxa

The table should show taxonSummaries sorted by hitCount. The current code
has the data model but the table isn't loading because configure() isn't
being called at the right time or the data isn't flowing to the table.

### 4. Reference Auto-Retrieval
For each unique `prim_align_genome_id_all` accession in the hits:
1. Fetch FASTA from GenBank: `efetch.fcgi?db=nucleotide&id={accession}&rettype=fasta`
2. Store in `references/` within the bundle
3. Use for alignment viewer (MiniBAMViewController) when user selects a taxon

Viral genomes are small (3-30kb) so downloads are fast. Can be done
lazily (on first selection) or eagerly (top N accessions during import).

### 5. Existing Reference Download Infrastructure
`MainSplitViewController.downloadReferenceForNakedBundle()` already does:
1. NCBI Assembly search
2. GenBank nucleotide fetch by accession (fallback)
3. Bundle manifest update
4. Viewer reload

This needs to be adapted for NAO-MGS where we have many small viral
references (not one large genome).

## Implementation Steps
1. Create proper bundle during import with manifest.json
2. Serialize NaoMgsResult to virus_hits.json for fast reload
3. Wire NaoMgsResultViewController to load from bundle
4. Add sidebar integration to show single entity with N icon
5. Fetch top accession references from GenBank during import
6. Wire MiniBAMViewController for selected accession
