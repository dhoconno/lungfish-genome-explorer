# Virtual Sequence System: Detailed Implementation Specification

This companion document to `virtual-sequence-system-plan.md` contains the exact code
changes, file paths, line numbers, and test specifications for each phase. It is designed
to survive context compaction and provide all necessary detail to resume work.

---

## Phase 1: Critical Correctness Fixes

### 1.1 Orient + Trim Materialization Bug

**Files to modify:**

**A. `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`**

In `run()` method, after `parseCutadaptInfoFile` (around line 395), add logic to adjust
trim positions for RC'd reads when the input bundle has an orient map:

```
// After trimPositionsByBarcode is populated:
// 1. Check if input bundle has an orient-map.tsv (parent was an orient step)
// 2. Load orient map: readID → "+" or "-"
// 3. For each entry in trimPositionsByBarcode where orient == "-":
//    Swap trim_5p and trim_3p
// This makes trim positions relative to ROOT orientation, not oriented orientation.
```

Also in the parent trim chaining section (around line 402), when loading parentTrimMap,
check if the parent bundle also has an orient-map.tsv and load it for propagation.

**B. `Sources/LungfishApp/Services/FASTQDerivativeService.swift`**

In `materializeDatasetFASTQ` `.demuxedVirtual` case (line 1778):
- After extracting reads from root FASTQ and applying trims
- Check manifest lineage for orient operations
- If orient in lineage, load orient map from parent chain
- Apply RC to reads marked "-" AFTER trimming

In `materializeDatasetFASTQ` `.trim` case (line 1683):
- Same issue: if parent was orientMap, trims are relative to oriented sequence
- Must apply orientation during materialization

**C. `Sources/LungfishIO/Formats/FASTQ/FASTQDerivedBundleManifest.swift` (or FASTQDerivatives.swift)**

Add to `.demuxedVirtual` payload:
```swift
case demuxedVirtual(
    barcodeID: String,
    readIDListFilename: String,
    previewFilename: String,
    trimPositionsFilename: String?,
    orientMapFilename: String?  // NEW: inherited from parent orient step
)
```

This is a schema change — requires schemaVersion bump (done in 1.4).

**Test specifications:**
- Test: RC'd read with asymmetric trims materializes correctly
- Test: Forward read with trims materializes correctly (no change)
- Test: Multi-step chain Root→Orient→Demux→Demux materializes correctly
- Test: Orient map propagation through trim chaining
- Test: Mixed forward+RC reads in same barcode bin

### 1.2 PE Interleaved Read ID Collisions

**Files to modify:**

**A. `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`**

`parseCutadaptInfoFile` — add mate detection. Cutadapt info file includes the full
header. For PE reads, detect /1 or /2 suffix, or " 1:N:0" vs " 2:N:0" in header.

Trim positions TSV: change format to 4 columns:
```
read_id\tmate\ttrim_5p\ttrim_3p
```
Where mate = 0 (single), 1 (R1), 2 (R2).

**B. `Sources/LungfishApp/Services/FASTQDerivativeService.swift`**

`extractAndTrimReads` — change trimMap key to `(readID, mate)` tuple or `readID#mate`
string key. When iterating FASTQ records, detect mate from header.

**C. `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift`**

`FASTQTrimPositionFile` — add mate column support. The `load` method should detect
whether file has 3 or 4 columns (backward compatible with existing 3-column files).

**Test specifications:**
- Test: Interleaved PE with different R1/R2 trims → both mates trimmed correctly
- Test: Single-end reads with mate=0 → backward compatible
- Test: 3-column legacy trim file loads correctly
- Test: 4-column new format loads correctly
- Test: Duplicate read IDs with different mates don't collide

### 1.3 parseCutadaptInfoFile 5'/3' Heuristic

**File:** `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`

**Current code (line ~1411):**
```swift
if seqBefore.count < seqAfter.count {
    info.trim5p = max(info.trim5p, seqBefore.count + matchedSeq.count)
} else {
    let trim3pStart = seqBefore.count
    ...
}
```

**Fix:** Use the adapter name (column 7) to determine direction:
```swift
let adapterName = String(cols[7])
// Adapter names from createAdapterConfiguration include directional info:
// For linked adapters: "barcode_5p;...barcode_3p" — cutadapt reports each arm separately
// For non-linked: adapter name matches the FASTA entry name
// Check if adapter name contains known 5' or 3' indicators
let is5Prime = adapterName.contains("_5p") || adapterName.hasSuffix("_front")
    || adapterName.hasSuffix("_fwd")
let is3Prime = adapterName.contains("_3p") || adapterName.hasSuffix("_rc")
    || adapterName.hasSuffix("_rev")
```

Also check how adapter FASTA entries are named in `createAdapterConfiguration` and
ensure the names carry directional information that can be parsed back.

**Test specifications:**
- Test: Symmetric barcode at read midpoint → correct direction assignment
- Test: 5' adapter with long seqBefore → not misclassified as 3'
- Test: Linked adapter with separate 5'/3' info lines → both parsed correctly
- Test: Short read where adapter spans majority → correct classification

### 1.4 Schema Versioning

**File:** `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift`

**A. Add schemaVersion to manifest:**
```swift
public struct FASTQDerivedBundleManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2  // bumped for orient map in payload
    public let schemaVersion: Int
    // ... existing fields
}
```

In `init`, default to `currentSchemaVersion`. In `init(from decoder:)`, use
`decodeIfPresent` with default of 1 for backward compatibility.

**B. Add unknown-case fallback to enums:**

`FASTQDerivativePayload`:
```swift
case unknown(String)  // Graceful degradation for unrecognized payload types
```

Custom `init(from decoder:)` that catches `DecodingError` and falls back to `.unknown`.

`FASTQDerivativeOperationKind`:
```swift
case unknown(String)
```

Custom `init(from decoder:)` using `singleValueContainer` with fallback.

**Test specifications:**
- Test: Manifest with schemaVersion=1 loads correctly (backward compat)
- Test: Manifest with schemaVersion=2 loads correctly
- Test: Manifest with unknown payload type decodes as .unknown
- Test: Manifest with unknown operation kind decodes as .unknown
- Test: Manifest from future version (schemaVersion=99) loads without crash
- Test: Round-trip encode/decode preserves all fields

---

## Phase 2: Robustness Fixes

### 2.1 Streaming Info File Parsing

**File:** `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`

Replace `parseCutadaptInfoFile` implementation:
```swift
private func parseCutadaptInfoFile(_ url: URL) -> [String: [(readID: String, ...)]] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
    defer { try? handle.close() }

    // Read line-by-line using a buffer
    var buffer = Data()
    let chunkSize = 65536
    var readInfos: [String: ReadTrimInfo] = [:]

    while true {
        let chunk = handle.readData(ofLength: chunkSize)
        if chunk.isEmpty { break }
        buffer.append(chunk)
        // Process complete lines from buffer...
    }
    // Process remaining buffer...
}
```

### 2.2 Streaming extractAndTrimReads

**File:** `Sources/LungfishApp/Services/FASTQDerivativeService.swift`

Replace the `var outputContent = ""` accumulation pattern (line 1962) with:
```swift
// Use FileHandle for streaming writes
FileManager.default.createFile(atPath: plainURL.path, contents: nil)
let writeHandle = try FileHandle(forWritingTo: plainURL)
defer { try? writeHandle.close() }

for try await record in reader.records(from: extractedURL) {
    let line = "@\(header)\n\(trimmedSeq)\n+\n\(trimmedQual)\n"
    writeHandle.write(line.data(using: .utf8)!)
}
```

### 2.3 Atomic Sidecar Writes

**Files:**
- `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift` — `FASTQTrimPositionFile.write`, `FASTQOrientMapFile.write`
- `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift` — inline TSV writes

Pattern: Write to `url.appendingPathExtension("tmp")`, then `FileManager.moveItem`.

### 2.4 Tool Version Recording

**File:** `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift`

Add to `FASTQDerivativeOperation`:
```swift
public var toolVersion: String?
```

**File:** `Sources/LungfishWorkflow/Tools/NativeToolRunner.swift` (or equivalent)

Add version caching: on first tool invocation, run `tool --version`, parse output,
cache in actor state. Populate `toolVersion` in operations that use external tools.

### 2.5 Unify Trim Position Formats

**Decision:** Unify on the absolute coordinate model `(trimStart, trimEnd)`.

**File:** `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`

In `parseCutadaptInfoFile`, compute absolute coordinates from the cutadapt info file:
```
trimStart = trim5p  // bases removed from start
trimEnd = readLength - trim3p  // exclusive end after 3' trim
```

Write the TSV with absolute coordinates matching `FASTQTrimPositionFile` format.

Add `#format` header line for format detection:
```
#format lungfish-trim-v2
read_id    mate    trim_start    trim_end
```

`FASTQTrimPositionFile.load` detects format by checking for `#format` header.
Legacy files (no header, or header `read_id\ttrim_5p\ttrim_3p`) are loaded as v1
format and converted.

### 2.6 Random Seed + Silent try? Fix

Add `randomSeed: UInt64?` to `FASTQDerivativeOperation`.
Replace `try?` with `try` on trim position writes, propagating errors.

---

## Phase 3: Annotation Infrastructure

### 3.1 Read Annotations TSV Format

**New file:** `Sources/LungfishIO/Formats/FASTQ/ReadAnnotationFile.swift`

```swift
public enum ReadAnnotationFile {
    public struct Annotation: Sendable, Equatable {
        public let readID: String
        public let mate: Int  // 0=single, 1=R1, 2=R2
        public let annotationType: String  // "barcode_5p", "adapter_3p", etc.
        public let start: Int  // 0-based inclusive in ROOT sequence
        public let end: Int    // 0-based exclusive
        public let strand: Character  // '+' or '-'
        public let label: String  // "BC1001", "VNP adapter"
        public let metadata: [String: String]  // Additional key-value pairs
    }

    public static let filename = "read-annotations.tsv"

    /// Load annotations from TSV file
    public static func load(from url: URL) throws -> [Annotation]

    /// Load annotations for specific read IDs (streaming, memory-efficient)
    public static func load(from url: URL, readIDs: Set<String>) throws -> [Annotation]

    /// Write annotations to TSV file (atomic)
    public static func write(_ annotations: [Annotation], to url: URL) throws

    /// Merge parent annotations with new annotations for a set of read IDs
    public static func mergeAndFilter(
        parentURL: URL?,
        newAnnotations: [Annotation],
        readIDs: Set<String>
    ) throws -> [Annotation]
}
```

### 3.2 Annotation Generation in Pipeline

**File:** `Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift`

After cutadapt runs and trim positions are parsed, generate annotations:
- For each read with a matched barcode:
  - `barcode_5p` annotation at the 5' match position
  - `barcode_3p` annotation at the 3' match position
  - Label = barcode ID (e.g., "BC1001")
  - Metadata includes kit name, error rate, adapter sequence

**File:** `Sources/LungfishApp/Services/FASTQDerivativeService.swift`

For each derivative operation, generate appropriate annotations:
- `adapterTrim` → `adapter_5p`, `adapter_3p` annotations
- `qualityTrim` → `trim_quality_5p`, `trim_quality_3p` annotations
- `fixedTrim` → `trim_fixed_5p`, `trim_fixed_3p` annotations
- `orient` → `orient_rc` annotation (full-read, for RC'd reads only)
- `primerRemoval` → `primer_5p`, `primer_3p` annotations

### 3.3 Full Lineage Propagation

At virtual bundle creation time:
1. Load parent bundle's `read-annotations.tsv` (if exists)
2. Filter to only reads in current bundle's read ID list
3. Add current operation's new annotations
4. Write combined `read-annotations.tsv`

Each leaf bundle is self-contained — no need to walk lineage at materialization time.

### 3.4 ReadAnnotationProvider

**New file:** `Sources/LungfishApp/Services/ReadAnnotationProvider.swift`

```swift
public class ReadAnnotationProvider {
    private let bundleURL: URL
    private var annotationCache: [String: [SequenceAnnotation]] = [:]

    /// Load annotations for a specific read, converting to SequenceAnnotation
    func getAnnotations(readID: String) -> [SequenceAnnotation]

    /// Get all annotation types present in the bundle
    func availableAnnotationTypes() -> [AnnotationType]

    /// Get annotation summary (count by type) for the bundle
    func annotationSummary() -> [(type: String, count: Int)]
}
```

Converts `ReadAnnotationFile.Annotation` → `SequenceAnnotation`:
- `chromosome` = read ID
- `type` = mapped from annotation type string to `AnnotationType` enum
- `intervals` = `[AnnotationInterval(start: a.start, end: a.end)]`
- `name` = label
- `strand` = strand
- `qualifiers` = metadata dict

### 3.5 Viewport Integration

**File:** `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`

When user selects a read in the preview table:
- Load annotations for that read via ReadAnnotationProvider
- Display the read sequence in a mini-viewer (reusing SequenceViewerView)
- Render annotations as colored blocks overlaid on the sequence

### 3.6 Annotation Drawer Integration

**File:** `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift`

Add a new tab or section showing read-level annotations:
- Table: Name, Type, Start, End, Size, Strand
- Filterable by annotation type (chip buttons)
- Click navigates to the annotation position in the read viewer

### 3.7 New AnnotationType Cases

**File:** `Sources/LungfishCore/Models/SequenceAnnotation.swift`

Add to `AnnotationType` enum:
```swift
case barcode_5p, barcode_3p
case adapter_5p, adapter_3p
case primer_5p, primer_3p
case trim_quality, trim_fixed
case orient_marker
case umi_region
case contaminant_match
```

With appropriate default colors (distinct from gene/CDS colors).

---

## Phase 4: FASTA Unification

### 4.1 SequenceRecord Protocol

**New file:** `Sources/LungfishIO/Formats/Common/SequenceRecord.swift`

```swift
public protocol SequenceRecord: Sendable {
    var identifier: String { get }
    var sequence: String { get }
    var recordDescription: String? { get }
}

extension FASTQRecord: SequenceRecord { ... }

public struct FASTARecord: SequenceRecord, Sendable {
    public let identifier: String
    public let sequence: String
    public let recordDescription: String?
}
```

### 4.2 Generalize Operations

**File:** `Sources/LungfishApp/Services/FASTQDerivativeService.swift`

Rename conceptually (or create parallel service) to handle both formats.
Operations that don't need quality scores:
- subset, lengthFilter, searchText, searchMotif, deduplicate, fixedTrim,
  contaminantFilter, orient

These call seqkit which handles both FASTQ and FASTA transparently.

Operations requiring quality scores (FASTQ-only):
- qualityTrim, adapterTrim (quality-aware mode), errorCorrection, PE merge/repair

### 4.3 FASTA Materialization

Same as FASTQ but skip quality line handling. seqkit grep/head/seq work on both formats.

### 4.4 Manifest Extension

Add `sequenceFormat: String?` to `FASTQDerivedBundleManifest`:
```swift
public let sequenceFormat: SequenceFormat?  // .fastq or .fasta, nil = infer from file
```

---

## Phase 5: Extended Metadata

### 5.1 SampleProvenance

**File:** `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift`

Add `SampleProvenance` struct (see plan document for fields).
Add optional `sampleProvenance: SampleProvenance?` to `FASTQDerivedBundleManifest`.

### 5.2 Payload Checksums

Add `payloadChecksum: String?` to manifest. Compute SHA-256 of primary sidecar.
Verify on load with warning (not error) if mismatch.

### 5.3 Referential Integrity

Add `validateReferences(from:) -> [ReferenceError]` to manifest.
Add depth guard (max 50) to lineage traversal.
Add root FASTQ fingerprint (SHA-256 of first 4KB) to IngestionMetadata.

---

## Test Specifications (All Phases)

### Edge Case Tests to Implement

**Trim arithmetic:**
1. Cumulative trims that exactly equal read length → read excluded (0 bases)
2. Cumulative trims that exceed read length → clamped, warning logged
3. Trim 0 from both ends → read unchanged
4. Trim entire 5' end (trim5p = readLength) → empty read excluded
5. Single-base read with no trim → preserved
6. Very long read (1M+ bases) with small trim → correct

**Orientation + trim:**
7. RC'd read with symmetric trims (5p == 3p) → same result either way
8. RC'd read with asymmetric trims → 5p/3p correctly swapped
9. Forward read with trims → no swap
10. Mixed forward+RC reads in same barcode → each handled correctly
11. Orient then quality trim then demux → all three chained correctly
12. Orient with 100% RC'd reads → all trims swapped
13. Orient with 0% RC'd reads → no trims swapped

**Read ID handling:**
14. Read ID with spaces → only first token used
15. Read ID with special characters (!, @, #) → handled correctly
16. Very long read ID (1000+ chars) → no truncation
17. Empty read ID → error or skip
18. Duplicate read IDs in root FASTQ → both extracted
19. PE interleaved with /1 /2 suffixes → mate detection works
20. PE interleaved with " 1:N:0" format → mate detection works
21. PE interleaved with identical headers → mate assigned by position

**File system:**
22. Bundle moved after creation → project-relative @/ path still resolves
23. Root FASTQ deleted → clear error message on materialization
24. Trim-positions.tsv truncated mid-line → error on load, not corrupt data
25. Manifest references nonexistent trim file → error on materialization
26. Very deep nesting (10+ levels of derivatives) → all resolve correctly
27. Bundle path with unicode characters → handled correctly
28. Bundle path with spaces → handled correctly

**Multi-step pipeline:**
29. 2-step pipeline: all bins capture trims for chaining
30. 3-step pipeline: trims chain correctly through all steps
31. Multi-step with one empty barcode bin → skipped gracefully
32. Multi-step where inner step produces 0 results → error message
33. Multi-step with concurrent bins (>maxConcurrentBins) → all get captureTrimsForChaining
34. Multi-step where outer bins are converted to virtual → trim files preserved

**Format compatibility:**
35. Legacy 3-column trim file (no mate column) → loads correctly
36. New 4-column trim file with mate → loads correctly
37. Legacy manifest (no schemaVersion) → loads as version 1
38. Manifest with unknown payload type → decodes as .unknown
39. Manifest with unknown operation kind → decodes as .unknown
40. Mixed v1 and v2 trim files in same project → both handled

**Annotation system:**
41. Read with 0 annotations → no annotation file needed
42. Read with 10+ annotations → all stored and retrievable
43. Annotation spanning entire read → rendered correctly
44. Annotation at position 0 → rendered at read start
45. Annotation at last base → rendered at read end
46. Overlapping annotations of different types → both rendered
47. Annotation inheritance: child has parent + own annotations
48. Annotation inheritance: grandchild has grandparent + parent + own
49. Large annotation file (100K+ reads) → streaming load works
50. Annotation type filtering → correct subset returned

**FASTA-specific:**
51. FASTA subset operation → read IDs extracted correctly
52. FASTA trim operation → sequence trimmed, no quality line
53. FASTA orient operation → RC applied correctly
54. FASTA length filter → works without quality scores
55. Mixed FASTA/FASTQ project → correct format detection
