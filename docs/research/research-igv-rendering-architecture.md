# IGV Rendering Architecture: Technical Analysis for Lungfish Genome Browser

## Executive Summary

This document analyzes how IGV (Integrative Genomics Viewer) handles the display of massive
numbers of genomic features and annotations. The analysis covers both the Java desktop application
(igvteam/igv) and the JavaScript web implementation (igvteam/igv.js), which share the same
conceptual architecture. The findings here are intended to inform the rendering strategy for the
Lungfish Genome Browser.

---

## 1. Visibility Window: When Features Are Shown vs Hidden

### Concept

IGV's most fundamental rendering optimization is the **visibility window** (`visibilityWindow`).
This is a genomic distance threshold (in base pairs) that determines whether a track attempts to
load and display individual features at all.

- If the currently viewed region is **larger** than the visibility window, the track shows either
  nothing (blank with a "Zoom in to see features" message) or switches to a pre-computed
  coverage/density representation.
- If the currently viewed region is **smaller** than the visibility window, individual features
  are loaded and rendered.

### Implementation (Java Desktop)

In `AbstractTrack.java`:
```java
protected int visibilityWindow = VISIBILITY_WINDOW;  // default = -1 (disabled)
```

In `FeatureTrack.java`, the decision method:
```java
// isShowFeatures() -- the core zoom decision
double windowSize = frame.getEnd() - frame.getOrigin();
int vw = getVisibilityWindow();
return (vw <= 0 || windowSize <= vw);
// vw <= 0 means "always show features" (no limit)
// otherwise, only show when viewed region <= visibility window
```

### Default Thresholds

| Track Type         | Default Visibility Window |
|--------------------|--------------------------|
| Alignments (DNA)   | 30 kb                    |
| Alignments (RNA)   | 300 kb                   |
| Third-gen (long)   | 1,000 kb (1 Mb)          |
| Variants           | 1 Mb                     |
| Annotations/Genes  | Whole chromosome (no limit, or -1) |

### Auto-Estimation for Indexed Files

For large indexed files (e.g., dbSNP), igv.js can estimate a safe visibility window using:
```
estimated_window = file_megabytes / genomic_megabases
```
This uses Tabix index metadata to prevent browser freezing from loading too many features.

### Lungfish Implication

Annotation/gene tracks in IGV have **no visibility window by default** -- they always show
features. The visibility window is primarily for alignment and variant tracks. For a genome browser
focused on annotations, you will need your own thresholds or use the density/individual switching
approach described in section 2.

---

## 2. Individual Features vs Density/Coverage Display

### The Two-Mode Rendering Architecture

IGV's `FeatureTrack.render()` method has a critical branching point:

```java
showFeatures = isShowFeatures(context.getReferenceFrame());
if (showFeatures) {
    // Restore the previous display mode if we were showing coverage
    if (lastFeatureMode != null) {
        super.setDisplayMode(lastFeatureMode);
        lastFeatureMode = null;
    }
    renderFeatures(context, renderRect);
} else if (coverageRenderer != null) {
    // Save current mode, switch to COLLAPSED for coverage view
    if (getDisplayMode() != DisplayMode.COLLAPSED) {
        if (!(this instanceof VariantTrack)) {
            lastFeatureMode = getDisplayMode();
            super.setDisplayMode(DisplayMode.COLLAPSED);
        }
    }
    renderCoverage(context, renderRect);
}
```

Key behaviors:
1. When zoomed out past the visibility window, IGV **remembers** the user's display mode
   (`lastFeatureMode`) and temporarily switches to COLLAPSED for coverage rendering.
2. When the user zooms back in, it **restores** the previous display mode.
3. The `coverageRenderer` uses a `FeatureDensityRenderer` that draws a bar chart of feature
   counts per bin.

### Density Renderer Details

From `FeatureDensityRenderer.java`:
- Density is computed as counts per megabase: `score * 1000000 / locScale`
- Rendered as cyan bars on a white background
- Each pixel column represents one bin (bin width = basepairs per pixel)
- A black baseline marks the bottom

### Pre-Computed Data Tiling

IGV uses a **pyramidal multi-resolution data tiling** approach (described in the 2013
Bioinformatics paper):

- The genome is divided into tiles at each zoom level
- First level: single tile covering the entire genome
- Each subsequent level doubles the tile count per chromosome
- Tiles subdivide into bins matching the screen pixel width at that resolution
- Lower zoom levels (typically 7) are pre-computed for performance
- Higher zoom levels compute dynamically (they cover small regions)
- Human genome requires ~23 zoom levels for base-pair resolution
- **Critical insight**: A single tile at the lowest resolution has the same memory footprint as a
  tile at the highest resolution

### Lungfish Implication

For annotation tracks, consider a three-tier approach:
1. **Whole chromosome / very zoomed out**: Show density histogram (feature count per bin)
2. **Medium zoom** (< visibility window): Show individual features as packed rectangles
3. **High zoom** (gene level): Show full gene structure with exons/UTRs/introns

---

## 3. Display Modes: COLLAPSED, SQUISHED, EXPANDED

### Enum Definition

```java
enum DisplayMode {
    COLLAPSED,   // All features on a single row
    SQUISHED,    // Features packed into rows, half-height
    EXPANDED     // Features packed into rows, full-height
}
```

### Row Height Constants

| Mode      | Java Desktop (IGVFeatureRenderer) | igv.js Default |
|-----------|----------------------------------|----------------|
| EXPANDED  | BLOCK_HEIGHT = 14px              | 30px per row   |
| SQUISHED  | BLOCK_HEIGHT / 2 = 7px           | 15px per row   |
| COLLAPSED | Single row                       | 30px total     |

Additional rendering heights in Java:
```java
static final int BLOCK_HEIGHT = 14;       // Full coding exon height
static final int THIN_BLOCK_HEIGHT = 6;   // UTR height
static final int NON_CODING_HEIGHT = 8;   // Non-coding region height
```

### Mode Behavior Summary

**COLLAPSED**: All features rendered on a single line. Overlapping features are drawn on top of
each other. Best for seeing overall feature density at a glance. Used automatically when zoomed out
past the visibility window.

**SQUISHED**: Features packed into the minimum number of rows (using the packing algorithm). Each
feature rendered at half-height. Labels are NOT shown. Best for viewing many features compactly.

**EXPANDED**: Features packed into rows like SQUISHED, but at full height. Feature labels/names
ARE shown. Best for detailed inspection of individual features.

### Automatic Mode Switching

IGV does NOT automatically switch between COLLAPSED/SQUISHED/EXPANDED based on feature count.
The user explicitly selects the mode from a right-click menu. However, IGV DOES automatically
switch between "feature mode" and "coverage mode" based on the visibility window (as described
in section 2).

The `lastFeatureMode` mechanism ensures the user's preference is preserved:
```java
// When switching to coverage (zoomed out):
lastFeatureMode = getDisplayMode();  // save EXPANDED/SQUISHED
super.setDisplayMode(DisplayMode.COLLAPSED);

// When switching back to features (zoomed in):
super.setDisplayMode(lastFeatureMode);  // restore user preference
lastFeatureMode = null;
```

### Lungfish Implication

Consider auto-switching display modes based on feature density. IGV leaves this to the user, but
an improved approach could be:
- Auto-EXPANDED when < 50 features in view
- Auto-SQUISHED when 50-500 features in view
- Auto-COLLAPSED or density when > 500 features in view

---

## 4. Feature Packing / Stacking Algorithm

### The Greedy Interval Packing Algorithm

Both Java and JavaScript implementations use the same core algorithm. The igv.js version is
cleaner and more illustrative:

```javascript
function pack(featureList, maxRows) {
    maxRows = maxRows || Number.MAX_SAFE_INTEGER
    const rows = []
    featureList.sort(function (a, b) {
        return a.start - b.start
    })
    rows.push(-1000)  // sentinel: first row is always available

    for (let feature of featureList) {
        let r = 0
        const len = Math.min(rows.length, maxRows)
        for (r = 0; r < len; r++) {
            if (feature.start >= rows[r]) {
                feature.row = r    // assign to this row
                rows[r] = feature.end  // update row's rightmost endpoint
                break
            }
        }
        feature.row = r
        rows[r] = feature.end
    }
}
```

### Algorithm Steps

1. **Sort** all features by start position (left to right on genome)
2. **Maintain** an array `rows[]` where each entry is the rightmost endpoint of that row
3. **For each feature**, scan rows from top to bottom:
   - Find the first row where `feature.start >= rows[r]` (no overlap)
   - Assign the feature to that row
   - Update the row's endpoint to `feature.end`
4. **If no row fits**, create a new row (unless maxRows is reached)

This is a classic **first-fit decreasing** interval scheduling algorithm, O(n * k) where n is
features and k is rows.

### Java Desktop Enhancements

The Java version (`PackedFeatures.java`) adds:

**Bucket-based organization**: Features are grouped into buckets by start position, with a
PriorityQueue ordering features by length (longest first within each bucket):
```java
Comparator pqComparator = (row1, row2) ->
    (row2.getEnd() - row2.getStart()) - (row1.getEnd() - row1.getStart());
```

**Minimum feature spacing**: A constant `MINIMUM_FEATURE_SPACING` (in basepairs) ensures visual
separation between features in the same row:
```java
nextStart = currentRow.end + FeatureTrack.MINIMUM_FEATURE_SPACING;
```

**Strand grouping**: Optional grouping by strand before packing:
```java
if (groupByStrand) {
    List<T> posFeatures = new ArrayList<>();
    List<T> negFeatures = new ArrayList<>();
    for (T f : features) {
        if (f instanceof IGVFeature &&
            ((IGVFeature) f).getStrand() == Strand.NEGATIVE) {
            negFeatures.add(f);
        } else {
            posFeatures.add(f);
        }
    }
    // Pack each strand independently, then combine
}
```

**Lazy re-packing**: Packing only re-executes when the display mode actually changes:
```java
if (this.displayMode == null ||
    this.groupByStrand != groupByStrand ||
    (this.displayMode == COLLAPSED && displayMode != COLLAPSED) ||
    (this.displayMode != COLLAPSED && displayMode == COLLAPSED)) {
    // re-pack
}
```

### maxRows Limits

| Implementation | Default maxRows |
|---------------|-----------------|
| Java Desktop  | 1,000,000       |
| igv.js        | 500 (annotation tracks), 1000 (featureTrack default) |

### Lungfish Implication

The greedy first-fit packing algorithm is simple and effective. Key improvements to consider:
- Use **pixel-based spacing** instead of basepair-based spacing (so spacing looks consistent at
  all zoom levels)
- Consider **re-packing only when zoom changes significantly** (not on every pan)
- Cache packed results per zoom level range

---

## 5. Feature Rendering at Different Zoom Levels

### Multi-Level Detail Rendering

IGV renders features with progressively more detail as the user zooms in. Here is the complete
zoom-level rendering hierarchy:

#### Level 1: Whole Genome / Whole Chromosome (very zoomed out)
- **Annotations**: Density histogram (FeatureDensityRenderer) or nothing
- **Cytobands**: Chromosome ideogram with colored bands (CytobandRenderer)
- **Alignments**: Pre-computed coverage plot only
- **Individual features**: NOT shown

#### Level 2: Large Region (100kb - 1Mb range)
- **Annotations**: Simple colored rectangles (no gene structure)
- **Feature labels**: NOT shown (insufficient pixel space)
- **Strand arrows**: NOT shown
- **Features**: Packed into rows if EXPANDED/SQUISHED

#### Level 3: Medium Region (10kb - 100kb range)
- **Gene structure visible**: Exons as thick blocks, introns as thin connecting lines
- **UTRs**: Drawn at reduced height (THIN_BLOCK_HEIGHT = 6px vs BLOCK_HEIGHT = 14px)
- **Strand arrows**: Drawn every 30 pixels along features > 6px wide
- **Feature labels**: Shown when > 10 pixels per feature
- **Labels**: Truncated at 60 characters with ellipsis

#### Level 4: Gene Level (1kb - 10kb range)
- **Full gene structure**: Exons, introns, UTRs with distinct heights
- **All labels shown**
- **Strand direction arrows**: Chevron-style arrows spaced along intron lines

#### Level 5: Base Pair Level (< 0.25 bp/pixel)
- **Amino acid sequences** rendered on coding exons
- **Codon-level detail** with color coding:
  - Green (#83f902) for start codons (M)
  - Red (#ff2101) for stop codons
  - Alternating blue shades for other amino acids
- **Individual nucleotide letters** shown when font size >= 8px
- **Colored base pair bars** when font too small for letters

### Pixel Thresholds (from IGVFeatureRenderer.java)

| Threshold | Value | Effect |
|-----------|-------|--------|
| Minimum feature width for gap | 5 pixels | Below this, no gap drawn between exons |
| Minimum for arrows/details | 6 pixels | Below this, no strand arrows drawn |
| Arrow spacing | 30 pixels | Distance between consecutive strand arrows |
| Label display | > 10 px/feature | Labels only shown when sufficient space |
| Amino acid rendering | < 0.25 bp/pixel | Codon-level detail appears |
| Base pair letters | font >= 8px | Individual nucleotide characters shown |
| Base pair bars | font < 8px | Colored rectangles instead of letters |

### Label Rendering and Collision Detection

igv.js implements label collision avoidance per row:
```javascript
const lastLabelX = options.rowLastLabelX[feature.row] || -Number.MAX_SAFE_INTEGER
if (options.labelAllFeatures || xleft > lastLabelX || selected) {
    options.rowLastLabelX[feature.row] = xright
    // render label
}
```

In COLLAPSED mode with many overlapping features, labels can be rendered at a 45-degree slant:
```javascript
if (this.displayMode === "COLLAPSED" && this.labelDisplayMode === "SLANT") {
    transform = {rotate: {angle: 45}}
}
```

---

## 6. GFF Feature Type Handling

### Hierarchical Feature Model

IGV internally represents genomic features in a **flattened hierarchy**:
- A **gene** or **transcript** is a `BasicFeature` with a list of child `Exon` objects
- Each `Exon` can be marked as coding or non-coding (`isNonCoding()`)
- The feature has `thickStart` and `thickEnd` to define coding region boundaries
- UTRs are computed as: regions outside `[thickStart, thickEnd]` within exons

GFF3's hierarchical structure (gene -> mRNA -> CDS/exon) is **collapsed** by the `GFFCombiner`
into this flat model during parsing:
- Parent-child relationships from the `Parent=` attribute are resolved
- Multiple transcript isoforms under one gene become separate `BasicFeature` objects
- CDS features define the thick (coding) region
- UTR features are inferred from exon vs CDS boundaries

### Feature Type Filtering

igv.js supports filtering specific GFF feature types from display:
```javascript
filterTypes: ['chromosome', 'gene']  // default: hide these types
```

This is significant: by default, **top-level "gene" features are filtered out**. Only the
transcript-level features (mRNA, transcript) and their children are displayed. This prevents
redundant rendering of the gene container and its child transcripts.

### Rendering the Hierarchy

The `drawExons()` method in `IGVFeatureRenderer` handles the visual hierarchy:

1. **Intron line**: A thin horizontal line connects exons across the feature span
2. **Coding exons**: Full-height rectangles (14px) between thickStart and thickEnd
3. **UTR exons**: Half-height rectangles (6px) outside the coding region
4. **Partial UTRs**: When an exon spans the coding boundary, it is split into a coding portion
   (full height) and UTR portion (half height)

```java
// UTR detection within an exon:
if (pCdStart > pStart) {
    // 5' UTR portion - draw at reduced height
}
if (pCdEnd < pEnd) {
    // 3' UTR portion - draw at reduced height
}
```

---

## 7. Downsampling for Dense Data

For alignment tracks with very deep coverage, IGV uses **downsampling**:
- Default sampling window: 50 bases
- Default max reads per window: 100
- Black rectangles mark regions where reads were downsampled

This is primarily for alignment tracks, not annotation tracks. For annotations, the packing
algorithm with maxRows serves a similar purpose by capping the number of displayed rows.

---

## 8. Color Assignment Strategy

### Priority Order (IGVFeatureRenderer.getFeatureColor)

1. Explicit alt-color for negative strand features
2. Explicit track color (user override)
3. Feature's own color if `itemRGB` is enabled
4. Default: gain = red, loss = blue, or strand-based coloring

### Strand-Based Colors

- Positive strand: default blue (rgb(0,0,150))
- Negative strand: altColor (if set)
- No strand: track default color

### Amino Acid Colors

- Start codon (M): bright green (#83f902)
- Stop codon: bright red (#ff2101)
- Other amino acids: alternating blue shades

---

## 9. Track Height and Auto-Sizing

### Height Computation (igv.js)

```javascript
computePixelHeight(features) {
    if (this.displayMode === "COLLAPSED") {
        return this.margin + this.expandedRowHeight
    } else {
        let maxRow = 0
        for (let feature of features) {
            if (feature.row && feature.row > maxRow) {
                maxRow = feature.row
            }
        }
        const rowHeight = ("SQUISHED" === this.displayMode)
            ? this.squishedRowHeight : this.expandedRowHeight
        return this.margin + (maxRow + 1) * rowHeight
    }
}
```

### Auto-Height

igv.js supports `autoHeight: true` with `minHeight` and `maxHeight` bounds. When a track exceeds
its visibility window (zoomed out too far), the track shrinks to `minHeight`. Upon zooming back in,
it expands dynamically based on feature count.

---

## 10. Summary: IGV's Rendering Decision Tree

```
User views a genomic region [start, end]
  |
  |-- Compute windowSize = end - start
  |
  |-- Is windowSize > visibilityWindow?
  |     |
  |     YES --> Show "Zoom in to see features" OR render density histogram
  |     |       (save current display mode as lastFeatureMode)
  |     |       (force COLLAPSED mode for coverage rendering)
  |     |
  |     NO --> Load features for [start - buffer, end + buffer]
  |            |
  |            |-- Pack features into rows (greedy first-fit algorithm)
  |            |   (maxRows = 500-1000, with MINIMUM_FEATURE_SPACING between features)
  |            |
  |            |-- What is the DisplayMode?
  |                 |
  |                 COLLAPSED --> All features on row 0, draw overlapping
  |                 |
  |                 SQUISHED --> Features in packed rows, half-height, no labels
  |                 |
  |                 EXPANDED --> Features in packed rows, full-height, with labels
  |
  |-- For each visible feature:
       |
       |-- Is feature width < 5px? --> Draw simple rectangle
       |
       |-- Does feature have exons?
       |     |
       |     YES --> Draw intron line + exon blocks
       |     |       - Coding exons: full height (14px)
       |     |       - UTR regions: half height (6px)
       |     |       - Strand arrows every 30px on intron lines
       |     |
       |     NO --> Draw single rectangle
       |
       |-- Is bpPerPixel < 0.25? --> Draw amino acid sequences on coding exons
       |
       |-- Is pixelsPerFeature > 10? --> Draw feature label/name
       |
       |-- Is font size >= 8? --> Draw nucleotide letters (SequenceRenderer)
       |-- Is font size < 8? --> Draw colored nucleotide bars
```

---

## 11. Recommendations for Lungfish Genome Browser

Based on this analysis, here are specific recommendations:

### A. Implement a Three-Tier Rendering System

1. **Density tier** (whole chromosome, > 1Mb view): Bar chart showing feature count per bin
2. **Packed feature tier** (1kb - 1Mb view): Individual features as colored rectangles/gene
   structures, packed into rows
3. **Detail tier** (< 1kb view): Full gene structure with labels, strand arrows, and potentially
   sequence-level detail

### B. Adopt the Greedy Packing Algorithm

The first-fit greedy packing algorithm is well-proven and efficient. Implement it with:
- Sort features by start position
- Track rightmost endpoint per row
- Assign each feature to the first row where it fits
- Add minimum pixel spacing (not basepair spacing) between features
- Cap at maxRows (500 is a good default for annotation tracks)
- Cache packed results and re-pack only when zoom changes significantly

### C. Use Pixel-Based Thresholds for Detail Levels

Rather than fixed basepair thresholds, use pixels-per-base and pixels-per-feature:
- `pixelsPerFeature > 10`: Show labels
- `pixelsPerFeature > 5`: Show gene structure (exons/introns)
- `pixelsPerFeature < 5`: Show as simple rectangles
- `pixelsPerBase > 4`: Show strand direction arrows
- `pixelsPerBase > 8`: Show nucleotide letters
- `pixelsPerBase < 8 && > 1`: Show colored nucleotide bars

### D. Filter GFF Feature Types at Parse Time

Follow IGV's approach: filter out top-level container features ("gene", "chromosome") and display
transcript-level features. Build the exon/CDS/UTR structure at parse time using parent-child
relationships, producing a flat list of transcript features with child exon arrays.

### E. Support Display Mode Toggling with Memory

Implement COLLAPSED/SQUISHED/EXPANDED modes with the `lastFeatureMode` pattern so zoom-dependent
mode switching preserves user preferences.

### F. Consider Auto Display Mode (IGV Improvement)

IGV leaves display mode selection entirely to the user. An improved approach:
- Automatically select EXPANDED when few features are visible (< 20)
- Automatically select SQUISHED when many features (20-200)
- Automatically select COLLAPSED when very dense (> 200)
- Allow user override that persists until they reset to "auto"

### G. Implement Label Collision Avoidance

Track the rightmost label position per row. Only render a label if it does not overlap the
previous label in the same row. Consider 45-degree slanted labels for COLLAPSED mode.

---

## Sources

Primary source code examined:
- igvteam/igv (Java desktop): FeatureTrack.java, AbstractTrack.java, PackedFeatures.java,
  IGVFeatureRenderer.java, FeatureDensityRenderer.java, GeneTrackRenderer.java,
  SequenceRenderer.java, CytobandRenderer.java, Track.java, FeatureUtils.java
- igvteam/igv.js (JavaScript): featureTrack.js, featurePacker.js, renderFeature.js

Documentation and papers:
- IGV Desktop documentation (igv.org/doc/desktop)
- igv.js documentation (igv.org/doc/igvjs)
- "Integrative Genomics Viewer (IGV): high-performance genomics data visualization and
  exploration" (Briefings in Bioinformatics, 2013)
