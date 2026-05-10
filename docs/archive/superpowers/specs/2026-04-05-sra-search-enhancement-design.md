# SRA Search Enhancement — Design Spec

**Date:** 2026-04-05
**Branch:** `sra-search-enhancement`
**Status:** Draft

## Problem Statement

The Database Browser's SRA/ENA search has three critical bugs and several missing features:

1. **Title/Organism/All-Fields search is broken for SRA data.** The ENA source routes all queries through `ENAService.searchReads(term:)`, which calls the ENA Portal API `/filereport?accession=<term>`. This endpoint only accepts accession values — free-text queries, `[Title]` qualifiers, and `[Organism]` qualifiers all return HTTP 400 or zero results.

2. **Multi-accession paste fails.** Pasting 150 accessions from an NCBI SRA Run Selector CSV into the search field sends the entire blob as a single accession query, which fails.

3. **No CSV file import.** Users who download `SraAccList.csv` from NCBI have no way to import the accession list directly.

4. **Missing search scopes.** BioProject and Author are common SRA search patterns but are not available as primary search scopes. Platform, Strategy, and size filters are missing from the advanced filter panel for SRA searches.

## Design

### 1. Two-Step Search for Non-Accession SRA Queries

**Routing logic in `DatabaseBrowserViewModel.performSearch()`:**

When source is `.ena`:
- **Single accession detected** (input matches `^[SED]RR\d+$` or `^[SED]RX\d+$` or `^[SED]RS\d+$` or `^PRJ[A-Z]{2}\d+$`): Use current direct ENA filereport path (no change).
- **Everything else** (title, organism, all-fields, author, bioproject, free text): Use two-step path:
  1. NCBI ESearch (`db=sra`, term with appropriate field qualifier) → returns SRA UIDs
  2. NCBI EFetch (`db=sra`, rettype=runinfo, retmode=csv) → converts UIDs to SRR accessions
  3. Batch ENA `/filereport` lookup for those accessions → returns `ENAReadRecord` with FASTQ URLs

**Field qualifier mapping (in `buildSearchTerm` for SRA):**

| SearchScope | ESearch qualifier |
|-------------|-------------------|
| `.all` | No qualifier (NCBI default) |
| `.accession` | No qualifier |
| `.title` | `[Title]` |
| `.organism` | `[Organism]` |
| `.bioProject` | `[BioProject]` |
| `.author` | `[Author]` |

**Progress reporting:**
- Phase 1: "Searching NCBI SRA..." (ESearch)
- Phase 2: "Resolving accessions..." (EFetch)
- Phase 3: "Loading FASTQ details 42/150..." (batch ENA filereport)

### 2. Multi-Accession Paste Detection

In `performSearch()`, before the normal search path, detect multi-accession input:

1. Split `searchText` by newlines, commas, tabs, or whitespace.
2. Filter for strings matching SRA accession patterns: `^[SED]RR\d+$`.
3. If ≥2 valid accessions detected → enter batch mode.
4. Batch mode bypasses ESearch entirely — goes straight to batch ENA filereport.
5. Results populate the table progressively.

**Accession pattern detection** (also recognizes study/experiment/sample accessions):
```
SRR\d+, ERR\d+, DRR\d+          — run accessions (primary)
SRX\d+, ERX\d+, DRX\d+          — experiment accessions
SRS\d+, ERS\d+, DRS\d+          — sample accessions
SRP\d+, ERP\d+, DRP\d+          — study/project accessions
PRJNA\d+, PRJEB\d+, PRJDB\d+   — BioProject accessions
```

For study/project accessions, use `ENAService.searchReadsByStudy()` instead of individual lookups.

### 3. CSV File Import

**UI:** Add an "Import List" button (SF Symbol: `doc.badge.plus`) next to the search field. Visible only when source is `.ena`.

**File handling:**
- `NSOpenPanel` accepting `.csv` and `.txt` files.
- Parse logic:
  - If first line contains `acc` (header): skip header, read remaining lines as accessions.
  - Otherwise: treat each non-empty line as a potential accession.
  - Strip whitespace, validate against accession regex.
  - Ignore lines that don't match (comments, blank lines, other columns).
- After parsing: trigger batch mode with the extracted accessions.

**Edge cases:**
- File with 0 valid accessions → show alert: "No valid SRA accessions found in file."
- File with >1000 accessions → show confirmation dialog: "Import N accessions? This may take a few minutes."

### 4. Batch ENA Lookup Engine

New method in `ENAService`:

```swift
public func searchReadsBatch(
    accessions: [String],
    concurrency: Int = 10,
    progress: @Sendable (Int, Int) -> Void
) async throws -> [ENAReadRecord]
```

- Uses `TaskGroup` with max concurrency via a semaphore pattern (10 concurrent requests).
- Calls existing `searchReads(term:)` for each accession.
- Calls `progress(completed, total)` after each successful lookup.
- Individual failures logged as warnings but don't abort the batch.
- Results collected in order (matched to input accession order).
- Rate limiting: respects ENA's existing 50 req/s throttle in `makeRequest`.

### 5. Updated Search Scopes

**Primary scopes** (in the scope pulldown menu):

| Scope | Icon | Placeholder text |
|-------|------|-----------------|
| All Fields | `magnifyingglass` | "Search SRA..." |
| Accession | `number` | "SRR123456, PRJNA..." |
| Organism | `leaf` | "e.g., SARS-CoV-2" |
| Title | `text.quote` | "e.g., air monitoring..." |
| BioProject | `folder` | "e.g., PRJNA989177" |
| Author | `person.text.rectangle` | "e.g., Smith J" |

**Note:** BioProject scope accepts both `PRJNAxxxxx` format and bare project IDs. When a BioProject accession is detected, the two-step path uses `[BioProject]` qualifier for ESearch.

### 6. SRA-Specific Advanced Filters

When source is `.ena`, the `advancedFiltersGrid` shows SRA-relevant filters instead of the GenBank-oriented ones (Gene, Journal, Molecule Type are not applicable to SRA runs):

**SRA advanced filters:**

| Filter | SRA ESearch field | UI control |
|--------|-------------------|------------|
| Platform | `[Platform]` | Picker: Any, ILLUMINA, OXFORD_NANOPORE, PACBIO_SMRT, ION_TORRENT, ULTIMA, ELEMENT, BGISEQ |
| Strategy | `[Strategy]` | Picker: Any, WGS, AMPLICON, RNA-Seq, WXS, Targeted-Capture, OTHER |
| Layout | `[Layout]` | Picker: Any, PAIRED, SINGLE |
| Min Mbases | `[Mbases]` range | TextField (number) |
| Publication Date | `[Publication Date]` | Date range (From/To) |

These filters are appended as AND clauses to the ESearch query in step 1 of the two-step path. For direct accession lookups (batch mode), these filters are applied client-side to the returned `ENAReadRecord` results.

### 7. NCBI SRA ESearch + EFetch Integration

New methods in `NCBIService` (or a new `SRASearchService` if cleaner):

```swift
/// Search SRA database via ESearch, returning SRA UIDs.
public func sraESearch(term: String, retmax: Int, retstart: Int) async throws -> (uids: [String], totalCount: Int)

/// Fetch run accessions from SRA UIDs via EFetch runinfo CSV.
public func sraEFetchRunAccessions(uids: [String]) async throws -> [String]
```

**`sraESearch`:** Standard NCBI ESearch call with `db=sra`. Returns UIDs and total count.

**`sraEFetchRunAccessions`:** Calls EFetch with `db=sra&rettype=runinfo&retmode=csv`, parses the CSV response to extract the `Run` column (SRR accession). Chunks UIDs into groups of 200 per request (EFetch UID limit).

### 8. Search Flow Diagrams

**Non-accession SRA search (Title, Organism, All Fields, BioProject, Author):**
```
User enters query + selects scope
    → buildSearchTerm() adds field qualifier
    → sraESearch(term) → SRA UIDs + totalCount
    → sraEFetchRunAccessions(uids) → [SRR accessions]
    → searchReadsBatch(accessions) → [ENAReadRecord]
    → convert to SearchResultRecord → display in table
```

**Single accession search:**
```
User enters "SRR35517702" with Accession scope
    → detect single accession pattern
    → searchReads(term: "SRR35517702") → [ENAReadRecord]  (current path, unchanged)
```

**Multi-accession paste or CSV import:**
```
User pastes/imports multiple accessions
    → detect multi-accession input (≥2 matching accession regex)
    → searchReadsBatch(accessions) → [ENAReadRecord]
    → convert to SearchResultRecord → display in table
```

## Test Strategy

### Test Fixture Datasets

Tiny paired-end Illumina datasets for fast, reliable tests:

| Accession | Reads | FASTQ size | Platform | Notes |
|-----------|-------|------------|----------|-------|
| DRR028938 | 631 | ~39 KB each | HiSeq 2500 | Primary mock fixture |
| DRR051810 | 270 | ~17 KB each | HiSeq 2000 | Secondary mock fixture |
| SRR35517702 | 4.4M | ~180 MB each | NovaSeq 6000 | Title search verification only (not downloaded) |

**Known study for BioProject/title search testing:**
- BioProject: PRJNA989177 (CDC Traveler-Based Genomic Surveillance, 25,501 runs)
- Title: "Genomic sequencing of viruses from environmental air monitoring in international airports."

### Mock Tests (LungfishCoreTests — fast, no network)

**`SRABatchSearchTests`:**
- `testMultiAccessionDetection` — verify regex parsing of pasted accession lists
- `testCSVParsing` — parse NCBI `SraAccList.csv` format (with header)
- `testCSVParsingPlainText` — parse plain text accession lists (no header)
- `testCSVParsingMixedContent` — lines with non-accession content are filtered out
- `testCSVParsingEmptyFile` — returns empty array
- `testBatchProgressReporting` — verify progress callback counts

**`SRASearchRoutingTests`:**
- `testSingleAccessionDetectsDirectPath` — "SRR35517702" → direct ENA
- `testTitleScopeUsesESearchPath` — title query → two-step
- `testOrganismScopeUsesESearchPath` — organism query → two-step
- `testAllFieldsScopeUsesESearchPath` — free text → two-step
- `testBioProjectScopeUsesESearchPath` — "PRJNA989177" → two-step
- `testAuthorScopeUsesESearchPath` — author query → two-step

**`MockENAService` / `MockNCBIService`:**
- Record real JSON/CSV responses from ENA and NCBI for DRR028938 and DRR051810
- Store as `.json` / `.csv` files in `Tests/Fixtures/sra/`
- Mock services return these recorded responses

### Integration Tests (LungfishIntegrationTests — live API, skippable)

**`SRASearchIntegrationTests`:**
- `testSingleAccessionViaENA` — fetch DRR028938 from live ENA, verify fields
- `testTitleSearchViaTwoStep` — search title "Genomic sequencing of viruses from environmental air monitoring" via NCBI ESearch → verify returns SRR accessions → verify ENA resolves them
- `testOrganismSearch` — search "SARS-CoV-2[Organism]" via ESearch → verify results
- `testBioProjectSearch` — search PRJNA989177 → verify returns runs
- `testBatchThreeAccessions` — batch lookup of 3 tiny accessions
- `testAdvancedFilterPlatform` — search with ILLUMINA platform filter

These tests use real network calls and may be slow or flaky. They should be in a separate test plan or tagged so CI can skip them.

### ViewModel Tests (LungfishAppTests — mock network)

**Additions to `DatabaseBrowserViewModelTests`:**
- `testSearchScopeIncludesBioProjectAndAuthor` — verify new scopes exist
- `testAdvancedFilterCountIncludesSRAFilters` — platform/strategy/layout count in badge
- `testClearFiltersClearsSRAFilters` — reset platform/strategy/layout to `.any`
- `testImportAccessionListSetsSearchText` — CSV import populates search state
- `testBatchModeDetectedFromPastedAccessions` — multi-line input triggers batch

## Files Changed

### New files:
- `Tests/Fixtures/sra/drr028938-ena-response.json` — recorded ENA response
- `Tests/Fixtures/sra/drr051810-ena-response.json` — recorded ENA response
- `Tests/Fixtures/sra/sra-esearch-title-response.json` — recorded NCBI ESearch response
- `Tests/Fixtures/sra/sra-efetch-runinfo.csv` — recorded NCBI EFetch CSV
- `Tests/Fixtures/sra/sample-accession-list.csv` — test CSV with 5 accessions

### Modified files:
- `Sources/LungfishCore/Services/NCBI/NCBIService.swift` — add `sraESearch()`, `sraEFetchRunAccessions()`
- `Sources/LungfishCore/Services/ENA/ENAService.swift` — add `searchReadsBatch()`
- `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift`:
  - `SearchScope` enum: add `.bioProject`, `.author`
  - `DatabaseBrowserViewModel`: add SRA filter properties (platform, strategy, layout, minMbases), CSV import method, multi-accession detection
  - `performSearch()`: add two-step routing for non-accession ENA queries, batch mode
  - `buildSearchTerm()`: handle new scopes with SRA field qualifiers
  - `advancedFiltersGrid`: add SRA-specific filter panel (shown when source is `.ena`)
  - `primarySearchBar`: add "Import List" button
- `Tests/LungfishCoreTests/` — new `SRABatchSearchTests.swift`
- `Tests/LungfishAppTests/DatabaseBrowserViewModelTests.swift` — new scope/filter tests
- `Tests/LungfishIntegrationTests/` — new `SRASearchIntegrationTests.swift`

## Out of Scope

- ENA text search API (alternative to NCBI ESearch) — can be added later as a fallback
- Merging multiple accessions into a single FASTQ bundle — each accession becomes its own bundle
- SRA Toolkit integration for download (existing `SRAService` handles this separately)
- DDBJ as a search backend
