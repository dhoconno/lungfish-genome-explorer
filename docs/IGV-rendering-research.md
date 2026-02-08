# IGV Rendering Research: VCF Variants and BAM Reads

## Comprehensive Analysis for Lungfish Genome Browser Implementation

---

## Part 1: VCF Variant Rendering in IGV

### 1.1 Display Modes

IGV provides three display modes for VCF variant tracks:

| Mode | Description | Default |
|------|-------------|---------|
| **COLLAPSED** | All variant calls in a single row; genotypes not displayed | No |
| **SQUISHED** | Multiple rows with compressed height; genotypes displayed | No |
| **EXPANDED** | Full-size rows; all genotypes displayed | Yes (default) |

Height parameters (from igv.js source):
- `expandedVariantHeight`: 10px per variant row
- `squishedVariantHeight`: 2px per variant row
- `expandedCallHeight`: 10px per genotype row
- `squishedCallHeight`: 1px per genotype row

Total pixel height formula:
```
TOP_MARGIN + nVariantRows * (variantHeight + vGap) + (nGenotypes + 1) * (callHeight + vGap)
```

### 1.2 Variant Type Color Schemes

#### Structural Variant Colors (from igv.js source)

| Variant Type | Color | Hex |
|-------------|-------|-----|
| DEL (Deletion) | Red | `#ff2101` |
| INS (Insertion) | Dark Blue | `#001888` |
| DUP (Duplication) | Green | `#028401` |
| INV (Inversion) | Teal | `#008688` |
| CNV (Copy Number) | Purple | `#8931ff` |
| BND (Breakend) | Brown | `#891100` |

These are configurable via the `colorTable` property which maps INFO field values to colors.

#### Allele Frequency Coloring (Default Mode)

When `colorBy` is set to "AF" (the default), variant bars display as stacked allele frequency indicators:
- Reference allele portion: height = `(1 - af) * h` (rendered in blue)
- Alternate allele portion: height = `af * h` (rendered in red)
- Default reference color: Blue
- Default alternate color: Red

Alternatively, users can switch to "Allele Fraction" mode which calculates frequency from the loaded samples rather than from VCF annotations.

#### Genotype Colors

| Genotype | Color | RGB |
|----------|-------|-----|
| Homozygous Reference | Light Gray | `rgb(200, 200, 200)` |
| Heterozygous | Blue | `rgb(34, 12, 253)` |
| Homozygous Alternate | Cyan | `rgb(17, 248, 254)` |
| No Call | Near White | `rgb(225, 225, 225)` / `rgb(250, 250, 250)` |
| No Genotype Data | Pink-Gray | `rgb(200, 180, 180)` |

### 1.3 Multi-Allelic Sites

- Multi-allelic sites are displayed at the same genomic position
- In EXPANDED mode, variants at the same position may occupy multiple variant rows
- The `expandGenotype()` function converts numeric allele indices to readable format
  (e.g., "0/1" becomes "REF/ALT1", displayed with "|" separator for phased genotypes)
- Allele frequency bars show the combined alternate allele frequency

### 1.4 Variant Frequency and Quality Display

- **Allele Frequency Bars**: Stacked vertical bars where the height of each colored
  portion is proportional to allele frequency
- **Filtered Variants**: Variants that fail filters receive alpha transparency to visually
  de-emphasize them
- **Quality**: Not directly rendered as a visual element; accessible via tooltip/popup

### 1.5 Zoom Level Behavior

- **Fully Zoomed Out**: Variants not loaded. Message: "Zoom in to see features"
- **Within Visibility Window**: Variants rendered as colored rectangles
  - Minimum width enforced at 3 pixels
  - Gaps added between adjacent variants when width exceeds 5 pixels
- **Zoomed In**: Individual variant sites become distinguishable; at base-pair resolution,
  the specific allele change is visible
- Visibility window scales with sample count (more samples = smaller default window)
- Can be set to -1 for unlimited (loads entire file; not recommended for large files)

### 1.6 Tooltip/Popup Information

Hovering over a variant site displays:
- **Variant Attributes block**: All INFO fields from the VCF
- Position (chromosome:position)
- Reference allele
- Alternate allele(s)
- Quality score
- Filter status
- Allele frequency
- Per-sample genotype information (GT, AD, DP, GQ, etc.)

Hovering over a genotype call displays sample-specific FORMAT fields.

### 1.7 Custom Coloring

The `color` property accepts:
- A static color string
- A function that takes a variant object and returns a color
- The `colorBy` property references an INFO field for automatic coloring
- `colorTable` maps specific INFO field values to colors (auto-generated if omitted)

---

## Part 2: BAM Read Rendering in IGV

### 2.1 Zoom Level Rendering Tiers

#### Tier 1: Fully Zoomed Out (Beyond Visibility Window)

- **Visibility Window Defaults** (varies by experiment type):
  - Standard sequencing: 30 kb
  - RNA-seq: 300 kb
  - Third-generation (long read): 1,000 kb
- Track is blank with message: "Zoom in to see alignments"
- Coverage track may still be visible if loaded separately

#### Tier 2: Within Visibility Window (Overview)

- **Coverage Histogram**: Bar chart showing read depth at each locus
  - Default coverage track height: 50px (igv.js) / configurable
  - Default color: `rgb(150, 150, 150)` (gray)
  - Autoscaling enabled by default
  - Mismatch coloring triggered at positions where mismatches exceed the
    allele-fraction threshold (default 20% of quality-weighted reads)
- **Read Rectangles**: Horizontal bars packed into rows
  - Reads appear as solid rectangles without individual base detail
  - Direction arrow on one end indicates strand orientation
  - Colors applied based on selected color-by mode

#### Tier 3: Zoomed In (Base-Level Detail)

- Threshold: `bpPerPixel <= 0.1` AND block height >= 8 pixels
- Individual bases rendered as colored letters within read rectangles
- Matching bases: displayed in the same color as the read background
- Mismatched bases: colored by nucleotide identity with quality-based transparency
- Font scales to minimum 10px

### 2.2 Read Color Schemes

#### Default Colors

| Element | Color | Value |
|---------|-------|-------|
| Default alignment | Light gray | `rgb(185, 185, 185)` |
| Positive strand | Pink | `rgba(230, 150, 150, 0.75)` |
| Negative strand | Light blue | `rgba(150, 150, 230, 0.75)` |
| Selected read | Red | `red` |
| Highlighted read | Green | `#00ff00` |

#### Color-By Options

IGV supports the following `colorBy` modes:

1. **none** - Default gray for all reads
2. **strand** - Positive strand pink, negative strand blue
3. **firstOfPairStrand** - Both mates colored by the strand of the "first in pair" mate
4. **pairOrientation** - Colors indicate relative orientation of mates:
   - LR (normal FR): Gray (default/expected)
   - RL (reverse-forward): Green (suggests duplication/inversion)
   - RR (reverse-reverse): Dark blue (suggests inversion)
   - LL (forward-forward): Teal (suggests inversion)
5. **tlen** (insert size) - Colors indicate template length abnormality:
   - Normal: Gray
   - Too close (smaller than expected): Blue
   - Too far (larger than expected): Red
6. **unexpectedPair** - Combination of pairOrientation and tlen; only abnormal pairs colored
7. **tag:TAGNAME** - Color by any SAM tag value
8. **basemod** / **basemod2** - Color by base modifications (e.g., methylation)

#### Insert Size Thresholds

- Computed automatically from the loaded file's insert size distribution
- Can be manually specified:
  - `minTLEN`: Pairs below this value colored blue
  - `maxTLEN`: Pairs above this value colored red
- Useful for detecting: deletions (red/too far), insertions/duplications (blue/too close)

#### Pair Orientation Structural Variant Detection

| Orientation | Color | Suggests |
|-------------|-------|----------|
| LR (FR) | Gray | Normal |
| RL (RF) | Green | Tandem duplication |
| RR | Dark blue | Inversion |
| LL (FF) | Teal | Inversion |
| Inter-chromosomal | Mate chromosome color | Translocation |

### 2.3 Paired-End Read Rendering

- **"View as pairs" mode**: Connected by a thin line at row midpoint between mates
- Connector line color follows alignment coloring rules (configurable via `pairConnectorColor`)
- **Ctrl+click / Cmd+click**: Highlights a read and its mate in matching colors
  (click again to clear)
- **Discordant pairs**: Colored differently based on the active color-by mode
- **Inter-chromosomal mates**: Each read colored by the chromosome of its mate

### 2.4 Mismatch Display

#### Coverage Track Mismatches

- **Threshold**: Default 20% of quality-weighted reads (configurable per-track or globally)
- When threshold exceeded at a position:
  - Bar is subdivided and colored by nucleotide (A, C, G, T)
  - Each nucleotide's portion proportional to its count
- When below threshold: entire bar is solid gray
- Quality weighting can be disabled (checkbox in preferences)

#### Read-Level Mismatches

- Matching bases: rendered in the same color as the read (or gray)
- Mismatched bases: rendered in nucleotide-specific colors:
  - **A (Adenine)**: Green - `rgb(0, 150, 0)` (general) / `rgb(0, 255, 0)` (SAM)
  - **C (Cytosine)**: Blue - `rgb(0, 0, 255)`
  - **G (Guanine)**: Orange - `rgb(209, 113, 5)`
  - **T (Thymine)**: Red - `rgb(255, 0, 0)`
  - **N**: Gray - `rgb(128, 128, 128)` / `rgb(182, 182, 182)`

#### Base Quality Transparency

Mismatched bases receive alpha transparency inversely proportional to phred quality score:
- Quality < 5: alpha = 0.1 (nearly transparent, strongly de-emphasized)
- Quality 5-20: linearly interpolated from 0.1 to 1.0
- Quality >= 20: alpha = 1.0 (fully opaque)
- Alpha values rounded to nearest 0.1 increment

Configurable thresholds:
- `baseQualityMinAlpha`: quality at which maximum transparency applied (default: 5)
- `baseQualityMaxAlpha`: quality above which no transparency applied (default: 20)

### 2.5 Insertion and Deletion Rendering

#### Insertions

- Rendered as purple "I" markers: `rgb(138, 94, 161)`
- Shape: vertical rectangle with horizontal bars at top and bottom (plus-sign style)
- Multi-base insertions: count label displayed when block width exceeds text width
- When zoomed in sufficiently, the size of the insertion is labeled

#### Deletions

- Rendered as black horizontal lines at row midpoint
- Color: `black`
- Optional count labels for multi-base deletions
- Visible as gaps in the read with connecting line

#### Skipped Regions (e.g., RNA-seq introns)

- Color: `rgb(150, 170, 170)`
- Rendered as thin lines connecting exonic blocks

### 2.6 Read Packing Algorithm

#### Packing Strategy

- Reads are packed into rows to minimize vertical screen space
- Algorithm: greedy left-to-right assignment
  - For each read, find the first row where it does not overlap any existing read
  - Minimum spacing: 5 bp between reads in the same row (MIN_ALIGNMENT_SPACING)
  - Packing uses genome coordinates (basepairs), not pixel coordinates
- "Re-pack alignments" option available via right-click menu to restore optimal packing

#### Display Modes

| Mode | Row Height | Description |
|------|-----------|-------------|
| EXPANDED | 14px | Default; reads spaced for easy observation |
| SQUISHED | 3px | Densely packed; for high-coverage viewing |
| FULL | 14px | One alignment per row (not practical for high coverage) |

#### Grouping

Reads can be grouped by:
- Strand
- Pair orientation
- Mate chromosome
- Chimeric status
- Supplementary alignment status
- Read order (first/second in pair)
- SAM tags
- Specific base at a position

Groups are separated by labeled dividers with `groupGap: 10` pixel spacing.

### 2.7 Sorting Options

Available sort criteria (applied at a specified chromosome position):

| Sort Option | Description |
|------------|-------------|
| BASE | Sort by the read base at the sort position |
| STRAND | Sort by strand orientation (forward/reverse) |
| INSERT_SIZE | Sort by template length (TLEN) |
| MATE_CHR | Sort by chromosome of mate |
| MQ | Sort by mapping quality |
| TAG | Sort by a specified SAM tag value |
| START | Sort by alignment start position |

Sort direction: ASC (ascending) or DESC (descending).

### 2.8 Coverage Depth and Limits

- Track height for coverage: configurable (default 50px in igv.js, 3px minimum axis)
- Shows `showAxis: true` by default with numeric scale
- Coverage represents ALL reads, even when only a subset is displayed due to downsampling
- Autoscaling: adjusts Y-axis to fit maximum depth in view

### 2.9 Soft Clip Display

- Toggled via `showSoftClips` preference (off by default)
- Soft-clipped bases rendered with outline color `rgb(50, 50, 50)`
- Coverage track always ignores soft-clipped bases
- Hard-clipped bases cannot be displayed (not stored in BAM)
- Useful for detecting: adapter contamination, structural variants

---

## Part 3: Performance Considerations

### 3.1 Large VCF File Handling

#### Indexing Strategy

- **Tabix (.tbi)**: Standard index for bgzip-compressed VCF files
  - Maps genomic coordinates to compressed data blocks
  - Enables region-specific queries without loading entire file
  - Limitation: chromosomes up to 512 Mbp (2^29 bases)
- **CSI index**: For chromosomes exceeding 512 Mbp
  - Supports up to 2^31 - 1 bases per reference sequence
  - Supported in IGV since v2.4.x

#### Loading Strategy

- Indexed VCF: only fetches data for the visible region
- Unindexed VCF: entire file loaded into memory (not recommended for large files)
- Visibility window: limits the genomic range that triggers data loading
  - Scales with sample count (more samples = smaller window)
  - Prevents loading too much data at once

#### Best Practices for Large VCF

1. Sort by position
2. Compress with bgzip
3. Index with tabix
4. Split by chromosome for very large files
5. Keep .vcf.gz and .vcf.gz.tbi in the same directory

### 3.2 High Coverage BAM Handling

#### Downsampling Algorithm: Reservoir Sampling

- Default parameters:
  - Sampling window size: 50 base pairs
  - Maximum reads per window: 100
- Algorithm:
  - If read count in window < max: keep all reads
  - If read count > max: probability of keeping any read = max / actual_count
  - Guarantees uniform random sampling within each window

#### Important Notes on Downsampling

- Coverage track shows depth from ALL reads (before downsampling)
- Only the rendered reads are downsampled
- Downsampled regions marked with a black bar (10px height) above alignment rows
- `alignmentStartGap: 5px` spacing before alignment rows begins

#### Adjusting Downsampling

- Decrease visibility window before disabling downsampling (reduces memory)
- Parameters configurable in View > Preferences > Alignments
- Setting sampling depth too high can freeze the browser in deep coverage areas

### 3.3 BAM Indexing

| Index Type | File Extension | Max Chromosome Size | Notes |
|-----------|---------------|-------------------|-------|
| BAI | .bai | 512 Mbp (2^29) | Standard, most common |
| CSI | .csi | 2.15 Gbp (2^31) | For large chromosomes |
| CRAI | .crai | Varies | For CRAM files |

- Index file must have same base name as data file
- IGV uses the index for random access to genomic regions
- Without an index, the entire BAM must be loaded

### 3.4 Memory and Rendering Optimization

- Alignments loaded only within visibility window threshold
- Coordinate-to-pixel conversion: `pixelX = (genomicPos - viewStart) / bpPerPixel`
- Minimum 1-pixel width for coverage bars: `Math.max(1, 1.0 / bpPerPixel)`
- Read packing uses genomic coordinates for efficiency
- Coverage computed incrementally as reads are loaded

---

## Part 4: Implementation Recommendations for Lungfish

Based on this research, here are specific recommendations for implementing VCF variant and
BAM read rendering in the Lungfish genome browser:

### 4.1 VCF Variant Track

1. **Three display modes**: Match IGV's COLLAPSED/SQUISHED/EXPANDED pattern
2. **Allele frequency bars**: Stacked colored bars (blue for ref, red for alt) proportional to AF
3. **SV type colors**: Use IGV's established palette (DEL red, INS dark blue, DUP green, etc.)
4. **Genotype grid**: Below variant bar, one row per sample, colored by zygosity
5. **Minimum 3px width** for variant rectangles; gap when > 5px
6. **Visibility window**: Scale with number of samples in VCF

### 4.2 BAM Alignment Track

1. **Three-tier zoom**: coverage-only -> packed rectangles -> base-level detail
   - Leverage existing three-tier annotation zoom architecture
   - Coverage histogram at fully zoomed out
   - Packed reads at medium zoom
   - Base letters at `bpPerPixel <= 0.1`
2. **Coverage track**: Gray bars with mismatch coloring at 20% threshold
3. **Read packing**: Greedy left-to-right row assignment with 5bp minimum gap
   - Similar to existing annotation row packing but with different gap thresholds
4. **Mismatch rendering**: Base quality transparency (alpha 0.1-1.0 for Q5-Q20)
5. **Indel markers**: Purple "I" for insertions, black line for deletions
6. **Downsampling**: Reservoir sampling (50bp window, 100 reads max)
7. **Color-by modes**: Start with strand and insert size; add pair orientation later

### 4.3 Index Requirements

- VCF: Require tabix (.tbi) or CSI index for files > 1MB
- BAM: Require BAI or CSI index
- Region queries only - never load entire file
- Match existing bgzip FASTA / BigBed pattern for index-based access

### 4.4 Architectural Notes

- Coverage track should be a SEPARATE sub-track rendered above alignments
  (matches existing viewer architecture with separate annotation layers)
- Use existing offscreen tile architecture for coverage histogram caching
- Read packing can reuse the pixel-based row packing from annotation rendering
  (adjust gap threshold from pixel-based to 5bp genomic-based)
- Base quality transparency maps well to existing CGColor cache pattern
  (pre-compute alpha variants of nucleotide colors at 0.1 increments)

---

## Sources

### Official IGV Documentation
- IGV Desktop User Guide: https://igv.org/doc/desktop/
- VCF Track Documentation: https://igv.org/doc/desktop/UserGuide/tracks/vcf/
- Alignment Basics: https://igv.org/doc/desktop/UserGuide/tracks/alignments/viewing_alignments_basics/
- Paired-End Alignments: https://igv.org/doc/desktop/UserGuide/tracks/alignments/paired_end_alignments/
- igv.js Alignment Track API: https://igv.org/doc/igvjs/tracks/Alignment-Track/

### Source Code
- IGV Desktop (Java): https://github.com/igvteam/igv
- igv.js (JavaScript): https://github.com/igvteam/igv.js
- AlignmentTrack.java: https://github.com/igvteam/igv/blob/master/src/main/java/org/broad/igv/sam/AlignmentTrack.java
- Preferences: https://github.com/igvteam/igv/blob/3.0/src/main/resources/org/broad/igv/prefs/preferences.tab

### Academic Papers
- Robinson et al. (2011) "Integrative Genomics Viewer" Nature Biotechnology: https://pmc.ncbi.nlm.nih.gov/articles/PMC3346182/
- Thorvaldsdottir et al. (2013) "IGV: high-performance genomics data visualization": https://pmc.ncbi.nlm.nih.gov/articles/PMC3603213/
- Robinson et al. (2017) "Variant Review with IGV": https://pmc.ncbi.nlm.nih.gov/articles/PMC5678989/

### Community Resources
- Biostars: IGV Colors: https://www.biostars.org/p/99907/
- Griffith Lab IGV Guide: https://genviz.org/module-01-intro/0001/05/01/GenomeBrowsingIGV/
- Illumina SV IGV Tutorial: https://help.dragen.illumina.com/product-guide/dragen-v4.4/dragen-dna-pipeline/sv-calling/sv-igv-tutorial
