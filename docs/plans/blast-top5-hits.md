# Enhanced BLAST Verification: Top-5 Hits, LCA Disagreement, Explorer Tools

## Status: Planning

## Summary
Enhance the BLAST verification pipeline to show top-5 hits per query sequence,
detect taxonomic disagreement (potential false positives), search the full
core_nt database, and add explorer tools for working with results.

## Changes

### 1. Top-5 BLAST Hits Per Sequence
- Show top 5 hits by e-value for each query read in an expandable table
- NSOutlineView: parent row = read summary, child rows = individual hits
- Each hit shows: accession, organism, identity%, coverage%, e-value, bit score

### 2. Limit to Top-5 Hits (maxTargetSeqs=5)
- Reduce default maxTargetSeqs from 10 to 5
- Reduces response size and NCBI processing time

### 3. LCA Disagreement Detection
- When top-5 hits for a read don't share the same genus, flag as potential false positive
- Visual indicator: orange warning icon + tinted organism name
- Summary bar shows count of reads with conflicting organisms
- Simple genus extraction: first word of binomial scientific name

### 4. Search All of core_nt (Remove Entrez Filter)
- Remove `txid{N}[Organism:exp]` entrez query filter
- Allows BLAST to find hits from ANY organism, revealing misclassifications
- Will increase search time (~30s → several minutes); update loading text

### 5. Copy Query Sequence as FASTA (Context Menu)
- Right-click a read row → "Copy Sequence as FASTA"
- Copies `>readId\nsequence\n` to clipboard
- Requires storing the query sequence in BlastReadResult

### 6. Export BLAST Results as CSV/TSV
- Export button in the BLAST results drawer tab
- NSSavePanel with CSV/TSV options (beginSheetModal, not runModal)
- Columns: Read ID, Verdict, LCA Flag, Hit Rank, Accession, Organism,
  TaxId, Identity%, Coverage%, E-value, Bit Score, Alignment Length
- One row per hit (not per read), so a read with 5 hits = 5 CSV rows

## Phase Breakdown

### Phase 1: Data Model Changes (LungfishCore)
- Add `taxId: Int?` to BlastHit
- Add `BlastHitSummary` struct (accession, organism, taxId, identity, coverage, evalue, bitScore, alignLength)
- Add `topHits: [BlastHitSummary]` to BlastReadResult
- Add `hasLCADisagreement: Bool` to BlastReadResult
- Add `querySequence: String?` to BlastReadResult (for FASTA copy)
- Change `maxTargetSeqs` default to 5
- Change `entrezQuery` default to nil (search full core_nt)
- Add `lcaDisagreementCount: Int` to BlastVerificationResult

### Phase 2: Service Layer (LungfishCore) — parallel with Phase 3
- Update parseHit to extract taxid from NCBI JSON2
- Update assignVerdict to populate topHits array (top 5 by evalue)
- Implement genus-level LCA disagreement detection
- Remove entrezQuery from request building
- Pass query sequences through to BlastReadResult

### Phase 3: UI (LungfishApp) — parallel with Phase 2
- Migrate BlastResultsDrawerTab from NSTableView to NSOutlineView
- Parent rows: read ID, verdict icon, top-1 hit summary, LCA warning
- Child rows: hits 2-5 with full details
- LCA disagreement column with warning icon
- Context menu: Copy Sequence as FASTA
- Export button: CSV/TSV via NSSavePanel
- Update summary bar with LCA disagreement count

### Phase 4: Tests
- Test topHits population (5 hits sorted by evalue)
- Test LCA disagreement detection (same genus, different genus, single hit)
- Test parseHit extracts taxId
- Test maxTargetSeqs default is 5
- Test entrezQuery defaults to nil
- Test CSV/TSV export format
- Test FASTA copy format

## Key Files
- Sources/LungfishCore/Services/Blast/BlastResult.swift
- Sources/LungfishCore/Services/Blast/BlastService.swift
- Sources/LungfishCore/Services/Blast/BlastVerificationRequest.swift
- Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerTab.swift
- Tests/LungfishCoreTests/Services/BlastServiceTests.swift
