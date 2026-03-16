// FASTQOperationSchematicDesignSpec.swift
// Visual Design Specification for FASTQ Operations Preview Panel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// This file serves as an implementation-ready specification. All constants,
// colors, and layout values are production values that can be copied directly
// into rendering code. The specification follows the existing Lungfish visual
// language established by ReadTrackRenderer, VariantTrackRenderer, and the
// FASTQ chart views.

import AppKit

// =============================================================================
// SECTION 1: DESIGN TOKENS
// =============================================================================

// MARK: - SchematicLayout

/// Master layout constants for the FASTQ operations schematic preview.
///
/// The schematic panel operates in two size modes:
/// - Compact (200pt tall): fits inside the bottom pane of FASTQDatasetViewController
/// - Expanded (400pt tall): standalone popover or full-height panel
///
/// All values are in points. The coordinate system is flipped (isFlipped = true),
/// matching every other custom NSView in the Lungfish codebase.
enum SchematicLayout {

    // -- Size modes -------------------------------------------------------

    /// Compact mode: embedded in the operations pane.
    static let compactHeight: CGFloat = 200
    /// Expanded mode: standalone detail view.
    static let expandedHeight: CGFloat = 400

    // -- Outer margins ----------------------------------------------------

    /// Horizontal padding from panel edge to content.
    static let horizontalPadding: CGFloat = 16
    /// Vertical padding from panel top/bottom to content.
    static let verticalPadding: CGFloat = 12

    // -- Read geometry ----------------------------------------------------

    /// Standard read rectangle height (compact mode).
    static let readHeightCompact: CGFloat = 10
    /// Standard read rectangle height (expanded mode).
    static let readHeightExpanded: CGFloat = 16
    /// Corner radius of read rounded rects (as fraction of height: 0.25).
    /// Actual value: compact = 2.5pt, expanded = 4pt.
    static let readCornerRadiusFraction: CGFloat = 0.25
    /// Vertical gap between stacked reads.
    static let readStackGap: CGFloat = 2
    /// Horizontal gap between before/after panels.
    static let beforeAfterGap: CGFloat = 24
    /// Width of the directional arrow connecting before and after.
    static let transitionArrowWidth: CGFloat = 40

    // -- Base-level detail ------------------------------------------------

    /// Individual base block width when sequence text is shown.
    static let baseBlockWidth: CGFloat = 10
    /// Base block height (matches read height in expanded mode).
    static let baseBlockHeight: CGFloat = 16
    /// Font size for base letters (SF Mono).
    static let baseFontSize: CGFloat = 10
    /// Threshold: show individual bases when read width > this many points.
    static let baseDetailThreshold: CGFloat = 120
    /// Below this threshold, show abstract colored blocks (no letters).
    static let abstractBlockThreshold: CGFloat = 60

    // -- Quality score bars -----------------------------------------------

    /// Height of quality score bar above/below a read (expanded mode).
    static let qualityBarHeight: CGFloat = 24
    /// Height of quality score bar (compact mode).
    static let qualityBarHeightCompact: CGFloat = 12
    /// Width of individual quality score column.
    static let qualityColumnWidth: CGFloat = 10

    // -- Aggregate indicators ---------------------------------------------

    /// Maximum reads shown in a stack before truncation.
    static let maxVisibleReads: Int = 8
    /// Height of the "and N more..." label area.
    static let truncationLabelHeight: CGFloat = 14

    // -- Operation-specific -----------------------------------------------

    /// Ruler tick height for fixed trim.
    static let rulerTickHeight: CGFloat = 6
    /// Ruler major tick interval (in base positions).
    static let rulerMajorTickInterval: Int = 10
    /// Adapter hatching line spacing (diagonal lines, in points).
    static let adapterHatchSpacing: CGFloat = 4
    /// Adapter hatching line width.
    static let adapterHatchLineWidth: CGFloat = 0.75
    /// Threshold line dash pattern (for length filter).
    static let thresholdDashPattern: [CGFloat] = [4, 3]
    /// Threshold line width.
    static let thresholdLineWidth: CGFloat = 1.5
    /// Drag handle radius (for interactive trim endpoints).
    static let dragHandleRadius: CGFloat = 5
}

// MARK: - SchematicColors

/// Color palette for FASTQ operation schematics.
///
/// Design principles:
/// 1. Use NSColor semantic colors where possible (auto light/dark mode).
/// 2. Use system colors (systemBlue, systemRed, etc.) for categorical encoding.
/// 3. Supplement color with shape/pattern for colorblind accessibility.
/// 4. Maintain consistency with ReadTrackRenderer base colors (A/T/G/C).
///
/// All colors are defined as NSColor for AppKit compatibility. Convert to
/// CGColor at draw time via `.cgColor`.
enum SchematicColors {

    // -- Read body --------------------------------------------------------

    /// Default read fill: light blue-gray, matches ReadTrackRenderer.forwardReadColor.
    static let readFill = NSColor(red: 0.69, green: 0.77, blue: 0.87, alpha: 1.0)
    /// Default read stroke.
    static let readStroke = NSColor(red: 0.55, green: 0.65, blue: 0.77, alpha: 1.0)
    /// Selected/highlighted read fill.
    static let readSelected = NSColor.selectedContentBackgroundColor
    /// Filtered-out/rejected read fill (desaturated, low opacity).
    static let readFilteredOut = NSColor(white: 0.70, alpha: 0.40)
    /// Filtered-out read stroke.
    static let readFilteredOutStroke = NSColor(white: 0.55, alpha: 0.40)
    /// Error base highlight fill (before correction).
    static let readError = NSColor(red: 0.95, green: 0.30, blue: 0.25, alpha: 0.25)
    /// Error base outline.
    static let readErrorStroke = NSColor.systemRed
    /// Corrected base highlight fill (after correction).
    static let readCorrected = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 0.25)
    /// Corrected base outline.
    static let readCorrectedStroke = NSColor.systemGreen

    // -- R1 / R2 distinction ----------------------------------------------

    /// Read 1 fill: blue tint (matches ReadTrackRenderer.firstInPairColor).
    static let r1Fill = NSColor(red: 0.45, green: 0.45, blue: 0.85, alpha: 1.0)
    /// Read 1 stroke.
    static let r1Stroke = NSColor(red: 0.35, green: 0.35, blue: 0.70, alpha: 1.0)
    /// Read 2 fill: red tint (matches ReadTrackRenderer.secondInPairColor).
    static let r2Fill = NSColor(red: 0.85, green: 0.45, blue: 0.45, alpha: 1.0)
    /// Read 2 stroke.
    static let r2Stroke = NSColor(red: 0.70, green: 0.35, blue: 0.35, alpha: 1.0)
    /// R1 label text.
    static let r1Label = NSColor(red: 0.30, green: 0.30, blue: 0.75, alpha: 1.0)
    /// R2 label text.
    static let r2Label = NSColor(red: 0.75, green: 0.30, blue: 0.30, alpha: 1.0)

    // -- Base colors (matches ReadTrackRenderer exactly) ------------------

    /// Adenine: green.
    static let baseA = NSColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 1.0)
    /// Thymine: red.
    static let baseT = NSColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 1.0)
    /// Cytosine: blue.
    static let baseC = NSColor(red: 0.0, green: 0.0, blue: 0.8, alpha: 1.0)
    /// Guanine: amber/gold.
    static let baseG = NSColor(red: 1.0, green: 0.7, blue: 0.0, alpha: 1.0)
    /// Unknown/N: gray.
    static let baseN = NSColor.gray

    /// Returns the color for a given nucleotide character.
    static func colorForBase(_ base: Character) -> NSColor {
        switch base {
        case "A", "a": return baseA
        case "T", "t": return baseT
        case "C", "c": return baseC
        case "G", "g": return baseG
        default: return baseN
        }
    }

    // -- Quality score gradient -------------------------------------------
    // Five-stop gradient matching FastQC convention:
    //   Q < 10  : red zone
    //   Q 10-20 : orange zone
    //   Q 20-30 : yellow-green zone
    //   Q 30-40 : green zone
    //   Q >= 40 : deep green

    /// Returns a quality score color for Phred score 0-42.
    /// Colorblind-safe: also uses bar height as a redundant channel.
    static func colorForQuality(_ phred: Int) -> NSColor {
        let q = max(0, min(42, phred))
        let t = CGFloat(q) / 42.0

        // Piecewise linear interpolation through 5 stops.
        // Stop 0 (Q=0):  (0.85, 0.20, 0.18) -- muted red
        // Stop 1 (Q=10): (0.95, 0.60, 0.15) -- orange
        // Stop 2 (Q=20): (0.90, 0.85, 0.20) -- gold
        // Stop 3 (Q=30): (0.40, 0.78, 0.30) -- green
        // Stop 4 (Q=42): (0.15, 0.58, 0.22) -- deep green
        struct Stop { let position: CGFloat; let r: CGFloat; let g: CGFloat; let b: CGFloat }
        let stops: [Stop] = [
            Stop(position: 0.0,       r: 0.85, g: 0.20, b: 0.18),
            Stop(position: 10.0/42.0, r: 0.95, g: 0.60, b: 0.15),
            Stop(position: 20.0/42.0, r: 0.90, g: 0.85, b: 0.20),
            Stop(position: 30.0/42.0, r: 0.40, g: 0.78, b: 0.30),
            Stop(position: 1.0,       r: 0.15, g: 0.58, b: 0.22),
        ]

        var r: CGFloat = stops[0].r
        var g: CGFloat = stops[0].g
        var b: CGFloat = stops[0].b
        for i in 1..<stops.count {
            guard t <= stops[i].position || i == stops.count - 1 else { continue }
            let span = max(0.0001, stops[i].position - stops[i-1].position)
            let local = (t - stops[i-1].position) / span
            let clamped = min(max(local, 0), 1)
            r = stops[i-1].r + (stops[i].r - stops[i-1].r) * clamped
            g = stops[i-1].g + (stops[i].g - stops[i-1].g) * clamped
            b = stops[i-1].b + (stops[i].b - stops[i-1].b) * clamped
            break
        }
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // -- Adapter ----------------------------------------------------------

    /// Adapter region fill: distinct purple with hatching overlay.
    static let adapterFill = NSColor(red: 0.65, green: 0.40, blue: 0.80, alpha: 0.35)
    /// Adapter region stroke.
    static let adapterStroke = NSColor(red: 0.55, green: 0.30, blue: 0.70, alpha: 0.80)
    /// Adapter hatch line color (drawn as diagonal lines over the fill).
    static let adapterHatch = NSColor(red: 0.50, green: 0.25, blue: 0.65, alpha: 0.50)

    // -- Trim regions -----------------------------------------------------

    /// 5-prime trim region fill.
    static let trimRegionFill = NSColor(white: 0.50, alpha: 0.20)
    /// 3-prime trim region fill (same as 5-prime for visual consistency).
    static let trimRegionStroke = NSColor(white: 0.40, alpha: 0.50)
    /// Trim cursor line.
    static let trimCursorLine = NSColor.systemOrange

    // -- Contaminant match ------------------------------------------------

    /// Contaminant k-mer match highlight.
    static let contaminantMatchFill = NSColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 0.30)
    /// Contaminant match stroke.
    static let contaminantMatchStroke = NSColor.systemRed
    /// Rejection X mark color.
    static let rejectionMark = NSColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.80)

    // -- Overlap (paired-end merge) ---------------------------------------

    /// Overlap region fill (where R1 and R2 align).
    static let overlapFill = NSColor(red: 0.55, green: 0.40, blue: 0.80, alpha: 0.30)
    /// Overlap region stroke.
    static let overlapStroke = NSColor(red: 0.50, green: 0.35, blue: 0.75, alpha: 0.70)

    // -- Duplicate grouping -----------------------------------------------

    /// Colors for duplicate groups (up to 5 distinct groups shown).
    static let duplicateGroupColors: [NSColor] = [
        NSColor.systemBlue,
        NSColor.systemTeal,
        NSColor.systemIndigo,
        NSColor.systemPurple,
        NSColor.systemCyan,
    ]

    // -- Structural / chrome ----------------------------------------------

    /// Panel background: matches controlBackgroundColor for native feel.
    static let panelBackground = NSColor.controlBackgroundColor
    /// Section divider.
    static let sectionDivider = NSColor.separatorColor
    /// Arrow fill (transition arrow between before/after).
    static let transitionArrow = NSColor.tertiaryLabelColor
    /// "Before" label.
    static let beforeLabel = NSColor.secondaryLabelColor
    /// "After" label.
    static let afterLabel = NSColor.secondaryLabelColor
    /// Truncation label ("and N more...").
    static let truncationLabel = NSColor.tertiaryLabelColor
}

// MARK: - SchematicTypography

/// Font specifications for the schematic panel.
///
/// Sequence text always uses SF Mono for fixed-width alignment.
/// Labels use the system font (SF Pro) for readability.
enum SchematicTypography {

    // -- Sequence text ----------------------------------------------------

    /// Monospaced font for individual base letters.
    static func sequenceFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    /// Compact mode sequence font (when bases are visible).
    static let sequenceFontCompact = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    /// Expanded mode sequence font.
    static let sequenceFontExpanded = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    // -- Labels -----------------------------------------------------------

    /// Read ID/header label.
    static let readIdFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    /// Section label ("Before", "After").
    static let sectionLabelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Operation title.
    static let operationTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Parameter annotation (e.g. "Q >= 20", "trim 5 bp").
    static let parameterFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    /// Truncation label ("and 1,234 more reads...").
    static let truncationFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    /// Ruler position numbers.
    static let rulerFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)

    // -- Zoom-dependent base display rules --------------------------------

    /// When to show actual nucleotide letters vs abstract colored blocks.
    ///
    /// - Read width >= 120pt: Show individual base letters with colors.
    /// - Read width 60-120pt: Show colored blocks (no letters), 1px per base.
    /// - Read width < 60pt: Solid colored bar (read fill color only).
    ///
    /// This matches the zoom-tier philosophy of ReadTrackRenderer (base / packed / coverage).
    enum BaseDisplayMode {
        case letters    // Individual A/T/G/C characters
        case blocks     // Colored rectangles per base, no text
        case solid      // Single solid read bar
    }

    static func baseDisplayMode(readWidthPt: CGFloat) -> BaseDisplayMode {
        if readWidthPt >= SchematicLayout.baseDetailThreshold { return .letters }
        if readWidthPt >= SchematicLayout.abstractBlockThreshold { return .blocks }
        return .solid
    }
}


// =============================================================================
// SECTION 2: READ REPRESENTATION
// =============================================================================

// MARK: - Read Drawing Specification

/// Specification for drawing a single sequencing read.
///
/// ## Shape
/// Rounded rectangle with corner radius = 0.25 * height.
/// - Compact: 10pt tall, 2.5pt corners
/// - Expanded: 16pt tall, 4pt corners
///
/// ## Strand/Direction Indicator
/// A small chevron (>) or (<) is drawn at the 3' end of the read:
/// - Forward strand: right-pointing chevron at right edge
/// - Reverse strand: left-pointing chevron at left edge
/// The chevron is 4pt wide, centered vertically, drawn in the read stroke color.
/// This is NOT an arrowhead on the rectangle itself; the read remains a
/// rounded rect. The chevron sits inside the read body, inset 2pt from the edge.
///
/// Accessibility note: strand is encoded by both color AND chevron direction,
/// satisfying the "shape + color" redundancy requirement.
///
/// ## R1 vs R2 Distinction
/// - R1 reads use `SchematicColors.r1Fill` (blue tint)
/// - R2 reads use `SchematicColors.r2Fill` (red tint)
/// - A small "R1" or "R2" label (7pt, SF Mono, bold) is drawn at the leading
///   edge of the read, inset 3pt, in the corresponding label color
/// - When the read is too narrow for text (< 40pt), the label is omitted
///   but the color distinction remains
///
/// ## Read ID/Header
/// Shown only in expanded mode when a single read is featured (e.g., quality
/// trim detail view). Drawn above the read as a single truncated line in
/// `SchematicTypography.readIdFont`. Color: `NSColor.secondaryLabelColor`.
/// Maximum display width: read width minus 8pt padding.
///
/// ## Quality Score Visualization
/// Drawn as a row of vertical bars immediately above (or below) the read.
/// Each bar represents one base position.
/// - Bar height: proportional to Phred score (0-42 mapped to 0-qualityBarHeight)
/// - Bar color: from `SchematicColors.colorForQuality(phred)`
/// - Bar width: `SchematicLayout.qualityColumnWidth` (10pt)
///
/// Accessibility: quality is encoded by BOTH color AND height, ensuring
/// colorblind users can still read the quality profile by bar height alone.
///
/// When the read is too narrow to show individual quality bars, a single
/// horizontal gradient strip is drawn instead (low quality left = warm,
/// high quality right = cool), with a horizontal mean-quality line overlay.
enum ReadDrawingSpec {

    /// Draws a single read rounded rect.
    ///
    /// Implementation sketch (not a complete render function):
    /// ```
    /// let rect = CGRect(x: x, y: y, width: readWidth, height: readHeight)
    /// let radius = readHeight * SchematicLayout.readCornerRadiusFraction
    /// let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    /// context.setFillColor(fillColor)
    /// context.addPath(path)
    /// context.fillPath()
    /// context.setStrokeColor(strokeColor)
    /// context.setLineWidth(0.5)
    /// context.addPath(path)
    /// context.strokePath()
    /// ```
    ///
    /// Strand chevron (forward example):
    /// ```
    /// let chevronX = rect.maxX - 6
    /// let chevronMidY = rect.midY
    /// context.move(to: CGPoint(x: chevronX, y: chevronMidY - 3))
    /// context.addLine(to: CGPoint(x: chevronX + 3, y: chevronMidY))
    /// context.addLine(to: CGPoint(x: chevronX, y: chevronMidY + 3))
    /// context.setStrokeColor(strokeColor)
    /// context.setLineWidth(1.0)
    /// context.strokePath()
    /// ```
    static let placeholder = true
}


// =============================================================================
// SECTION 3: OPERATION-SPECIFIC SCHEMATICS
// =============================================================================

// MARK: - 1. Subsample

/// ## Subsample: Input stack -> output subset
///
/// ### Layout (Before panel)
/// - 8 reads stacked vertically, full opacity, uniform width.
/// - Reads have subtle alternating lightness (odd rows 2% darker) for visual count.
///
/// ### Layout (After panel)
/// - Same 8 read slots, but only N reads remain at full opacity.
/// - The "removed" reads transition to `SchematicColors.readFilteredOut` (ghosted).
///
/// ### Selection Visualization
/// Random selection is shown by which reads remain fully opaque.
/// The selected reads get a brief pulse (opacity 1.0 -> 1.15 -> 1.0, clamped)
/// to draw attention. Non-selected reads fade to ghost state.
///
/// ### Parameter Binding
/// - Proportion slider (0.0 - 1.0): controls how many of the 8 visible reads
///   remain. E.g., 0.25 = 2 of 8 remain, 0.50 = 4 of 8 remain.
/// - Count mode: shows "N / total" label below the after panel.
///
/// ### Annotation
/// - "Before" label (left), "After" label (right)
/// - Proportion or count displayed as bold parameter text centered below arrow
/// - A small dice icon (SF Symbol "die.face.5") drawn next to the arrow to
///   indicate randomness, as a supplement to color-based selection.
///
/// ### Accessibility
/// - Selected reads retain full opacity AND gain a subtle left-edge accent bar
///   (2pt wide, systemBlue). Non-selected reads lose the accent AND fade.
/// - Pattern: color + opacity + accent bar (triple redundancy).
enum SubsampleSchematic {
    static let maxPreviewReads = 8
    static let accentBarWidth: CGFloat = 2
    static let accentBarColor = NSColor.systemBlue
    static let ghostOpacity: CGFloat = 0.25
}

// MARK: - 2. Quality Trim

/// ## Quality Trim: Single read with quality profile
///
/// ### Layout (single read, expanded)
/// - One read drawn full width across the panel.
/// - Quality score bars drawn ABOVE the read (rising upward).
/// - Each bar colored by Phred score via `SchematicColors.colorForQuality`.
/// - A horizontal threshold line drawn at the height corresponding to the
///   quality threshold parameter (e.g., Q=20).
///
/// ### Trim Visualization
/// - A vertical "trim cursor" line (orange, 1.5pt) drops from the threshold
///   intersection point to the read body.
/// - Bases to the left/right of the cursor (depending on trim direction) are
///   in the "trimmed" zone.
/// - The trimmed region of the read transitions to `SchematicColors.trimRegionFill`
///   (gray overlay at 20% opacity) with diagonal hatching.
/// - The trimmed quality bars also fade to 30% opacity.
///
/// ### Trim Direction Modes
/// - "Cut Right (3')": cursor scans from right, trimming rightward.
/// - "Cut Front (5')": cursor scans from left, trimming leftward.
/// - "Cut Both": two cursors, one from each end.
/// - "Cut Tail": sliding window algorithm; cursor at the window boundary.
///
/// ### Parameter Binding
/// - Quality threshold slider (Q=0 to Q=42): moves the horizontal threshold
///   line up/down, which repositions the trim cursor.
/// - Window size (for sliding window mode): shown as a bracket below the
///   quality bars spanning the window width.
///
/// ### Annotation
/// - Threshold line labeled "Q >= {value}" at its right edge.
/// - Trimmed base count shown as "{N} bp trimmed" below the trimmed region.
/// - Retained base count shown as "{N} bp retained" below the kept region.
enum QualityTrimSchematic {
    static let thresholdLineColor = NSColor.systemOrange
    static let thresholdLineWidth: CGFloat = 1.5
    static let thresholdLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    static let windowBracketColor = NSColor.systemBlue
    static let windowBracketLineWidth: CGFloat = 1.0
    static let trimmedOverlayOpacity: CGFloat = 0.20
    static let trimmedBarOpacity: CGFloat = 0.30
}

// MARK: - 3. Adapter Trim

/// ## Adapter Trim: Read with adapter region identified and removed
///
/// ### Layout (Before)
/// - Single read at full width.
/// - The adapter region (typically at the 3' end) is highlighted with:
///   1. `SchematicColors.adapterFill` background
///   2. Diagonal hatching overlay (45-degree lines, 4pt spacing, 0.75pt wide)
///   3. A distinct purple stroke outlining the adapter boundary
/// - If bases are visible (expanded, wide enough), the adapter sequence is
///   shown in its own color, with a small alignment diagram below showing
///   the adapter reference aligned to the read.
///
/// ### Layout (After)
/// - The same read, but the adapter region has been "cut away".
/// - The adapter portion slides right and fades out (animation).
/// - A small scissor icon (SF Symbol "scissors") is drawn at the cut point.
/// - The remaining read body tightens to fill space.
///
/// ### Adapter Alignment Detail (expanded mode only)
/// Drawn below the read when in expanded mode:
/// - Two rows of text: read sequence on top, adapter sequence below.
/// - Matching bases connected by vertical bars (|).
/// - Mismatches shown as spaces or dots.
/// - Alignment region highlighted with `SchematicColors.overlapFill`.
///
/// ### Parameter Binding
/// - Auto-detect mode: adapter region position determined from data.
/// - Manual mode: user-specified adapter sequence shown as reference below read.
/// - Mismatch tolerance shown as "up to N mismatches" annotation.
enum AdapterTrimSchematic {
    static let hatchAngle: CGFloat = .pi / 4  // 45 degrees
    static let scissorIconSize: CGFloat = 14
    static let alignmentRowGap: CGFloat = 2
    static let alignmentMatchBarColor = NSColor.secondaryLabelColor
    static let alignmentMatchBarWidth: CGFloat = 0.5
}

// MARK: - 4. Fixed Trim

/// ## Fixed Trim: Read with ruler and shaded trim regions
///
/// ### Layout
/// - Single read drawn full width.
/// - A ruler bar drawn ABOVE the read with tick marks at every base position
///   (or every 5/10 positions at smaller scales).
/// - Major ticks at every 10th position with position labels.
/// - Minor ticks at every position (expanded) or every 5th (compact).
///
/// ### Trim Regions
/// - The 5' end has a shaded overlay covering exactly N bases (parameter).
/// - The 3' end has a shaded overlay covering exactly M bases (parameter).
/// - Shading: `SchematicColors.trimRegionFill` with a dashed border.
/// - The boundary between trimmed and retained is marked by a bold vertical
///   line in `SchematicColors.trimCursorLine` (orange).
///
/// ### Drag Handles
/// - Small circular drag handles (5pt radius) at each trim boundary.
/// - Handle fill: white with 1pt stroke in trim cursor color.
/// - Dragging a handle adjusts the corresponding trim parameter.
/// - The ruler labels dynamically update as handles move.
///
/// ### Annotation
/// - "5' trim: {N} bp" label left-aligned above the 5' region.
/// - "3' trim: {M} bp" label right-aligned above the 3' region.
/// - "Retained: {total - N - M} bp" centered above the kept region.
///
/// ### Parameter Binding
/// - 5' trim count (integer >= 0): controls left shaded region width.
/// - 3' trim count (integer >= 0): controls right shaded region width.
enum FixedTrimSchematic {
    static let rulerHeight: CGFloat = 18
    static let rulerBackgroundColor = NSColor(white: 0.95, alpha: 1.0)
    static let rulerTickColor = NSColor.secondaryLabelColor
    static let majorTickWidth: CGFloat = 1.0
    static let minorTickWidth: CGFloat = 0.5
    static let dragHandleFill = NSColor.white
    static let dragHandleStroke = NSColor.systemOrange
    static let dragHandleStrokeWidth: CGFloat = 1.5
}

// MARK: - 5. Length Filter

/// ## Length Filter: Multiple reads with threshold lines
///
/// ### Layout
/// - 6-8 reads of varying widths, stacked vertically.
/// - Reads are drawn proportional to their simulated lengths.
/// - Two vertical dashed threshold lines:
///   - Left line: minimum length threshold
///   - Right line: maximum length threshold
/// - Reads that fall entirely within the thresholds remain full opacity.
/// - Reads shorter than min or longer than max fade to ghost state.
///
/// ### Threshold Lines
/// - Dashed pattern: 4on, 3off (SchematicLayout.thresholdDashPattern).
/// - Color: `NSColor.systemOrange` for both lines.
/// - Width: 1.5pt.
/// - Small triangular handles at top/bottom of each line for dragging.
/// - Labels: "min: {N} bp" and "max: {M} bp" drawn at the top of each line.
///
/// ### Passing/Failing Indication
/// - Passing reads: full opacity, left-edge accent bar (green, 2pt).
/// - Failing reads: ghost opacity, left-edge accent bar (red, 2pt).
/// - Small checkmark (green) or X (red) icon at the right edge of each read.
///
/// ### Accessibility
/// - Pass/fail encoded by: color (green/red accent) + icon (checkmark/X) +
///   opacity (full/ghost). Triple redundancy.
///
/// ### Parameter Binding
/// - Min length slider: moves left threshold line.
/// - Max length slider: moves right threshold line.
enum LengthFilterSchematic {
    static let previewReadCount = 7
    static let passAccentColor = NSColor.systemGreen
    static let failAccentColor = NSColor.systemRed
    static let passIconName = "checkmark.circle.fill"
    static let failIconName = "xmark.circle.fill"
    static let iconSize: CGFloat = 10
    static let thresholdHandleSize: CGFloat = 8
}

// MARK: - 6. Contaminant Filter

/// ## Contaminant Filter: Reads with k-mer match visualization
///
/// ### Layout (Before)
/// - 6-8 reads stacked. One or two are "contaminated" (randomly chosen for
///   illustration purposes).
/// - Contaminated reads have highlighted regions showing k-mer matches:
///   scattered short segments (5-8pt each) colored with
///   `SchematicColors.contaminantMatchFill` and stroked with
///   `SchematicColors.contaminantMatchStroke`.
/// - The k-mer match density is shown as a mini sparkline below each
///   contaminated read (optional, expanded mode only).
///
/// ### Layout (After)
/// - Contaminated reads slide downward into a "Rejected" zone below a
///   horizontal divider line.
/// - Clean reads remain in place, compacting upward.
/// - A red "X" mark (16pt) is drawn over each rejected read.
///
/// ### K-mer Match Detail (expanded mode)
/// When a contaminated read is hovered or selected:
/// - The matching k-mer segments glow (animated pulsing border).
/// - A small reference sequence fragment is drawn below, showing the
///   contaminant genome region that matched.
///
/// ### Annotation
/// - "Clean: {N}" and "Contaminated: {M}" labels in the after panel.
/// - Contaminant reference name (e.g., "PhiX") shown in the rejected zone.
///
/// ### Parameter Binding
/// - K-mer size: shown as "k={value}" annotation.
/// - Threshold: "match >= {pct}%" annotation.
enum ContaminantFilterSchematic {
    static let kmerSegmentMinWidth: CGFloat = 5
    static let kmerSegmentMaxWidth: CGFloat = 12
    static let rejectionZoneHeight: CGFloat = 40
    static let rejectionZoneFill = NSColor(red: 0.95, green: 0.90, blue: 0.90, alpha: 1.0)
    static let rejectionDividerColor = NSColor.systemRed.withAlphaComponent(0.3)
    static let xMarkSize: CGFloat = 16
    static let xMarkLineWidth: CGFloat = 2.5
}

// MARK: - 7. Error Correction

/// ## Error Correction: Read with bases highlighted and corrected
///
/// ### Layout (Before)
/// - Single read with individual bases shown (expanded mode).
/// - Error bases are marked with:
///   1. A red dashed rectangle outline around the error base block.
///   2. The base letter in bold red.
///   3. A small downward-pointing triangle below the base (marking it).
///
/// ### Layout (After)
/// - Same read, but error bases now show:
///   1. A green solid rectangle outline around the corrected base block.
///   2. The new (corrected) base letter in bold green.
///   3. A small upward-pointing triangle below the base (marking correction).
///   4. A subtle green glow effect (3pt gaussian shadow) around the block.
///
/// ### Evidence Panel (expanded mode only)
/// Drawn below the read:
/// - A mini histogram of k-mer frequencies for the error position.
/// - The original k-mer shown above, the corrected k-mer shown below.
/// - Frequency bars: original (red, short) vs corrected (green, tall).
///
/// ### Animation
/// - Error bases blink briefly (red outline pulses 2x) before transitioning
///   to the corrected state.
/// - Corrected bases fade from red -> green outline over 0.3s.
///
/// ### Parameter Binding
/// - K-mer size for correction shown as annotation.
/// - Minimum k-mer frequency threshold shown.
enum ErrorCorrectionSchematic {
    static let errorOutlineDash: [CGFloat] = [2, 2]
    static let errorOutlineWidth: CGFloat = 1.5
    static let correctedOutlineWidth: CGFloat = 1.5
    static let correctedGlowRadius: CGFloat = 3.0
    static let correctedGlowColor = NSColor.systemGreen.withAlphaComponent(0.30)
    static let errorTriangleSize: CGFloat = 4
    static let correctedTriangleSize: CGFloat = 4
}

// MARK: - 8. Deinterleave

/// ## Deinterleave: Single column of alternating R1/R2 -> two columns
///
/// ### Layout (Before)
/// - Single column of reads, alternating R1 (blue) and R2 (red).
/// - Each read labeled "R1" or "R2" at its leading edge.
/// - Reads connected by faint mate-pair arcs (thin curved lines connecting
///   each R1 to its R2 mate, drawn in `NSColor.tertiaryLabelColor`).
///
/// ### Layout (After)
/// - Two columns side by side.
/// - Left column: all R1 reads (blue tint), labeled "R1 file".
/// - Right column: all R2 reads (red tint), labeled "R2 file".
/// - Mate-pair arcs now bridge across the two columns horizontally.
///
/// ### Animation
/// - R2 reads slide rightward from the interleaved column to the R2 column.
/// - R1 reads compact upward in the left column as gaps close.
/// - Duration: 0.4s with ease-in-out, staggered by 0.05s per read.
///
/// ### Annotation
/// - Column headers: "Interleaved" (before), "R1 file" / "R2 file" (after).
/// - Mate pair indices shown as faint numbers (1, 2, 3...) at right edge.
enum DeinterleaveSchematic {
    static let matePairArcColor = NSColor.tertiaryLabelColor
    static let matePairArcLineWidth: CGFloat = 0.5
    static let columnHeaderFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let columnGap: CGFloat = 16
    static let matePairLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)
}

// MARK: - 9. Deduplicate

/// ## Deduplicate: Stack of reads with duplicates highlighted and collapsed
///
/// ### Layout (Before)
/// - 8 reads stacked. Duplicate groups are identified by matching left-edge
///   accent bars of the same color (from `SchematicColors.duplicateGroupColors`).
/// - Example: reads 1, 4, 7 are duplicates (all have blue accent bars and a
///   subtle left-margin colored dot). Reads 2, 5 are duplicates (teal accent).
///   Reads 3, 6, 8 are unique (no accent bar).
///
/// ### Layout (After)
/// - Duplicates collapse: only one representative per group remains.
/// - The representative read gains a small badge "x3" (or "x2") at its right
///   edge, indicating how many duplicates it represented.
/// - Removed duplicates fade to ghost state and slide behind the representative.
///
/// ### Duplicate Group Visualization
/// - Each group gets a distinct color from `duplicateGroupColors` (up to 5).
/// - A faint connecting line (0.5pt, dashed) links members of each group
///   in the before panel.
/// - Unique reads have no accent and are drawn in standard read colors.
///
/// ### Annotation
/// - "Before: {N} reads" and "After: {M} unique" labels.
/// - "{N - M} duplicates removed" centered below the arrow.
///
/// ### Accessibility
/// - Duplicate groups distinguished by: color + left accent bar + connecting
///   line + group badge number. Quadruple redundancy.
enum DeduplicateSchematic {
    static let groupAccentWidth: CGFloat = 3
    static let groupConnectorDash: [CGFloat] = [2, 3]
    static let groupConnectorWidth: CGFloat = 0.5
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold)
    static let badgeBackgroundColor = NSColor(white: 0.92, alpha: 1.0)
    static let badgeCornerRadius: CGFloat = 3
}

// MARK: - 10. Merge Paired-End

/// ## Merge PE: Two overlapping reads sliding together
///
/// ### Layout (Before)
/// - R1 (blue) drawn left-aligned, extending rightward.
/// - R2 (red) drawn right-aligned, extending leftward.
/// - The two reads are vertically offset by 1 read-height + 4pt gap.
/// - The overlap region is highlighted with `SchematicColors.overlapFill`
///   in both reads (a vertical stripe where they share genomic positions).
/// - Dotted vertical alignment lines connect the overlap boundaries.
///
/// ### Layout (After)
/// - A single merged read, drawn in a blended purple
///   (`NSColor.systemPurple` at 0.7 alpha) to indicate the merge.
/// - The merged read is the union of R1 and R2 spans.
/// - The former overlap region is drawn with a subtle gradient where
///   blue transitions to red (left to right through the overlap).
/// - A small "merged" label badge at the right edge.
///
/// ### Animation
/// - R2 slides leftward (and upward) to overlap R1.
/// - Overlap region brightens as reads converge.
/// - At full overlap, both reads dissolve into the single merged read.
/// - Duration: 0.5s, ease-in-out.
///
/// ### Overlap Detail (expanded mode)
/// When space permits:
/// - Base-level alignment shown in the overlap zone.
/// - Matching bases: gray bars.
/// - Consensus resolution: the higher-quality base is chosen (shown in bold).
/// - Quality scores from both reads shown as stacked mini-bars.
///
/// ### Parameter Binding
/// - Minimum overlap: shown as a labeled bracket under the overlap region.
/// - Mismatch tolerance: "max {N} mismatches" annotation.
enum MergePESchematic {
    static let mergedReadColor = NSColor.systemPurple.withAlphaComponent(0.70)
    static let mergedReadStroke = NSColor.systemPurple.withAlphaComponent(0.85)
    static let overlapAlignmentLineColor = NSColor.tertiaryLabelColor
    static let overlapAlignmentLineDash: [CGFloat] = [1, 2]
    static let overlapBracketColor = NSColor.systemBlue
    static let mergedBadgeText = "merged"
    static let mergedBadgeFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
}


// =============================================================================
// SECTION 4: ANIMATION SPECIFICATIONS
// =============================================================================

// MARK: - SchematicAnimation

/// Animation timing and easing specifications.
///
/// All animations use Core Animation (CABasicAnimation / CAKeyframeAnimation)
/// or SwiftUI `.animation()` modifiers when hosted in SwiftUI.
///
/// General principle: animations should be quick and purposeful. They communicate
/// the semantic meaning of the operation (e.g., "these reads are being removed")
/// rather than serving as decoration.
enum SchematicAnimation {

    // -- Duration ---------------------------------------------------------

    /// Standard transition duration for before -> after.
    static let standardDuration: CFTimeInterval = 0.35
    /// Slow transition (for complex operations like merge PE).
    static let slowDuration: CFTimeInterval = 0.50
    /// Fast transition (for simple parameter adjustments).
    static let fastDuration: CFTimeInterval = 0.20
    /// Stagger delay between sequential read animations.
    static let staggerDelay: CFTimeInterval = 0.04

    // -- Easing -----------------------------------------------------------

    /// Standard easing: ease-in-out (smooth start and end).
    /// CAMediaTimingFunction control points: (0.42, 0.0, 0.58, 1.0)
    static let standardEasing = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0)

    /// Spring-like easing for "snap" effects (e.g., drag handle release).
    /// Slight overshoot: (0.34, 1.56, 0.64, 1.0)
    static let springEasing = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)

    /// Decelerate easing for slide-out effects (filtered reads leaving).
    /// (0.0, 0.0, 0.58, 1.0)
    static let decelerateEasing = CAMediaTimingFunction(controlPoints: 0.0, 0.0, 0.58, 1.0)

    // -- Triggers ---------------------------------------------------------

    /// Animations are triggered by:
    /// 1. Operation selection change (full before -> after transition).
    /// 2. Parameter slider/field change (incremental update, fast duration).
    /// 3. Panel resize (layout reflow, no animation -- immediate).
    ///
    /// Debouncing: parameter changes during continuous slider drag are debounced
    /// at 60fps (16.6ms). Only the final value triggers a full animation.
    static let parameterDebounceInterval: CFTimeInterval = 1.0 / 60.0

    // -- Multi-read stagger -----------------------------------------------

    /// For operations that animate multiple reads (subsample, length filter,
    /// deduplicate, deinterleave):
    /// - Reads animate sequentially with `staggerDelay` between each.
    /// - Total stagger = staggerDelay * (readCount - 1).
    /// - Maximum total stagger capped at 0.30s to prevent sluggish feel.
    static let maxTotalStagger: CFTimeInterval = 0.30

    // -- Specific operation animations ------------------------------------

    /// Subsample: selected reads pulse (opacity overshoot), rejected reads fade.
    /// - Selected: opacity 1.0 -> 1.0 (no visible change, just a 0.1s hold)
    /// - Rejected: opacity 1.0 -> 0.25 over standardDuration, decelerate easing.

    /// Quality trim: cursor sweeps from the trim origin to the trim point.
    /// - Cursor X position animates over slowDuration.
    /// - Trimmed region opacity fades from 1.0 -> 0.3 as cursor passes.

    /// Adapter trim: adapter portion slides rightward and fades.
    /// - Adapter region: translateX 0 -> +40pt, opacity 1.0 -> 0.0
    /// - Duration: standardDuration.

    /// Fixed trim: trim region shading snaps with parameter (fast, no animation
    /// on drag; spring animation on release).

    /// Length filter: failing reads fade out with stagger.

    /// Contaminant filter: contaminated reads slide downward into rejected zone.
    /// - TranslateY: 0 -> rejectionZoneOffset, duration: slowDuration.

    /// Error correction: error bases pulse red, then transition to green.
    /// - Phase 1 (0-0.2s): red outline pulses (2 cycles).
    /// - Phase 2 (0.2-0.5s): outline color transitions red -> green.

    /// Deinterleave: R2 reads slide right, R1 reads compact up.
    /// - R2 translateX: 0 -> columnOffset, staggered.
    /// - R1 translateY: close gaps, staggered.

    /// Deduplicate: duplicate reads slide behind representative and fade.
    /// - TranslateY toward representative, opacity -> 0.

    /// Merge PE: R2 slides left and up, then both dissolve into merged read.
    /// - Phase 1 (0-0.3s): R2 slides into position.
    /// - Phase 2 (0.3-0.5s): both reads cross-dissolve into merged read.
}


// =============================================================================
// SECTION 5: LAYOUT GRID AND COMPOSITION
// =============================================================================

// MARK: - SchematicPanelLayout

/// Overall panel composition and grid system.
///
/// The schematic panel is divided into three horizontal zones:
///
/// ```
/// +------------------------------------------------------------------+
/// |  Operation Title (13pt semibold)                   [Expand btn]  |
/// +------------------------------------------------------------------+
/// |  [Before Panel]   |  ->  |  [After Panel]                        |
/// |                   | arrow|                                        |
/// |  (reads drawn     |      |  (result drawn                        |
/// |   here)           |      |   here)                               |
/// +------------------------------------------------------------------+
/// |  Parameter annotation text (10pt mono)                           |
/// +------------------------------------------------------------------+
/// ```
///
/// In compact mode, the before and after panels share horizontal space 45%/45%
/// with 10% for the transition arrow.
///
/// In expanded mode, the before and after panels are 42%/42% with 16% for
/// the arrow zone (which can include more annotation).
///
/// For single-read operations (quality trim, adapter trim, fixed trim, error
/// correction), the before/after layout is replaced with a single full-width
/// detail view that shows the transformation inline (before state on top,
/// after state below, or trimmed regions overlaid on the same read).
enum SchematicPanelLayout {

    // -- Zone proportions -------------------------------------------------

    /// Before panel width fraction (of total content width).
    static let beforeWidthFractionCompact: CGFloat = 0.45
    static let beforeWidthFractionExpanded: CGFloat = 0.42
    /// Arrow zone width fraction.
    static let arrowWidthFractionCompact: CGFloat = 0.10
    static let arrowWidthFractionExpanded: CGFloat = 0.16
    /// After panel width fraction.
    static let afterWidthFractionCompact: CGFloat = 0.45
    static let afterWidthFractionExpanded: CGFloat = 0.42

    // -- Vertical zones ---------------------------------------------------

    /// Title bar height.
    static let titleBarHeight: CGFloat = 28
    /// Annotation bar height (bottom).
    static let annotationBarHeight: CGFloat = 20
    /// Content area = total height - titleBarHeight - annotationBarHeight

    // -- Arrow drawing ----------------------------------------------------

    /// The transition arrow is a right-pointing chevron (>), not a filled
    /// triangle. This matches the macOS system style.
    /// - Stroke weight: 2pt
    /// - Color: `SchematicColors.transitionArrow`
    /// - Size: 12pt wide, 16pt tall
    /// - Centered vertically and horizontally in the arrow zone.
    static let arrowStrokeWidth: CGFloat = 2
    static let arrowWidth: CGFloat = 12
    static let arrowHeight: CGFloat = 16

    // -- Read positioning within panels -----------------------------------

    /// Reads are top-aligned within each panel with `SchematicLayout.verticalPadding`
    /// from the top of the content area.
    /// Horizontal: reads are left-aligned with `SchematicLayout.horizontalPadding`
    /// from the panel's leading edge.
    /// Read width within a panel: panel width - 2 * horizontalPadding.
    /// For variable-length operations (length filter), reads are proportionally
    /// scaled so the longest read fills the available width.

    // -- Single-read detail layout ----------------------------------------

    /// For operations that show one read in detail:
    /// - Read spans full content width (minus padding).
    /// - Quality bars above: qualityBarHeight tall.
    /// - Ruler (if applicable): rulerHeight tall.
    /// - Read body: readHeight tall.
    /// - Evidence panel below (expanded only): remaining space.
    ///
    /// Vertical stacking order (top to bottom):
    /// 1. Quality bars (if quality trim)
    /// 2. Ruler (if fixed trim)
    /// 3. Read body
    /// 4. Adapter alignment / evidence panel
    static let singleReadQualityGap: CGFloat = 4
    static let singleReadRulerGap: CGFloat = 2
    static let singleReadEvidenceGap: CGFloat = 8
}


// =============================================================================
// SECTION 6: ACCESSIBILITY
// =============================================================================

// MARK: - SchematicAccessibility

/// Accessibility design decisions.
///
/// Every visual encoding uses at least TWO independent channels:
///
/// | Information           | Channel 1          | Channel 2          | Channel 3       |
/// |-----------------------|--------------------|--------------------|-----------------|
/// | Strand direction      | Color (blue/red)   | Chevron direction  | --              |
/// | R1 vs R2              | Color (blue/red)   | Text label         | --              |
/// | Quality score         | Color gradient     | Bar height         | --              |
/// | Pass/fail (filter)    | Color (green/red)  | Icon (check/X)     | Opacity         |
/// | Duplicate group       | Color (5 palette)  | Accent bar + line  | Badge number    |
/// | Adapter region        | Color (purple)     | Hatch pattern      | --              |
/// | Trim region           | Color (gray)       | Hatch pattern      | Opacity         |
/// | Contaminant match     | Color (red)        | X mark icon        | Rejected zone   |
/// | Error/corrected       | Color (red/green)  | Triangle marker    | Outline style   |
///
/// The hatching patterns (adapter, trim) ensure that regions are distinguishable
/// even in grayscale or with color vision deficiency.
///
/// All text uses NSColor.labelColor / .secondaryLabelColor / .tertiaryLabelColor
/// for automatic light/dark mode adaptation.
///
/// VoiceOver: the schematic panel should expose an accessibility description
/// summarizing the operation result (e.g., "Quality trim: 12 bases trimmed from
/// 3-prime end at Q20 threshold. 138 bases retained."). This is set via
/// `setAccessibilityLabel()` on the panel view.
enum SchematicAccessibility {

    /// Minimum contrast ratio for all text: 4.5:1 (WCAG AA).
    /// Achieved by using semantic NSColor text colors exclusively.

    /// Hatching is used for: adapter regions, trim regions.
    /// Hatching parameters are chosen to be visible at both compact and
    /// expanded sizes.

    /// All icons use SF Symbols, which scale with Dynamic Type and support
    /// VoiceOver descriptions natively.

    static let minimumContrastRatio: CGFloat = 4.5
    static let hatchingAlwaysVisible = true
}


// =============================================================================
// SECTION 7: DARK MODE ADAPTATION
// =============================================================================

// MARK: - Dark Mode Notes

/// Dark mode handling is automatic for most elements because:
///
/// 1. All semantic colors (labelColor, secondaryLabelColor, separatorColor,
///    controlBackgroundColor, selectedContentBackgroundColor) adapt automatically.
///
/// 2. System colors (systemBlue, systemRed, systemGreen, etc.) shift their
///    luminance in dark mode. No manual overrides needed.
///
/// 3. Custom colors (base A/T/G/C, read fills) are defined at moderate
///    saturation/brightness and work acceptably in both modes. However, for
///    publication-quality appearance in dark mode, the following adjustments
///    should be applied:
///
///    - Read fills: increase brightness by 10% in dark mode.
///      Detection: `NSApp.effectiveAppearance.name == .darkAqua`
///    - Quality gradient: shift all stops +5% brightness in dark mode.
///    - Hatching lines: increase opacity by 10% in dark mode for visibility.
///    - Ghost reads (filtered out): use alpha 0.30 in dark mode (vs 0.25 light).
///
/// 4. Panel background uses `NSColor.controlBackgroundColor`, which is
///    near-white in light mode and dark gray in dark mode. All content
///    colors are chosen to have sufficient contrast against both.


// =============================================================================
// SECTION 8: IMPLEMENTATION NOTES
// =============================================================================

// MARK: - Implementation Architecture

/// The schematic renderer should follow the `ReadTrackRenderer` / `VariantTrackRenderer`
/// pattern:
///
/// ```swift
/// @MainActor
/// public enum FASTQSchematicRenderer {
///     public static func drawSubsample(
///         context: CGContext,
///         rect: CGRect,
///         isCompact: Bool,
///         proportion: Double,
///         readCount: Int,
///         animationProgress: CGFloat  // 0.0 = before, 1.0 = after
///     ) { ... }
///
///     public static func drawQualityTrim(
///         context: CGContext,
///         rect: CGRect,
///         isCompact: Bool,
///         qualityScores: [Int],
///         threshold: Int,
///         trimMode: QualityTrimMode,
///         animationProgress: CGFloat
///     ) { ... }
///
///     // ... one static method per operation
/// }
/// ```
///
/// Key architectural decisions:
///
/// 1. **Stateless rendering**: All state (animation progress, parameter values)
///    is passed as parameters. The renderer is a pure function from inputs to
///    pixels. This matches the existing renderer pattern and simplifies testing.
///
/// 2. **Animation progress as parameter**: Rather than managing timers internally,
///    the hosting view controller drives a `CADisplayLink` or `NSAnimation` and
///    passes the current progress (0.0-1.0) to the renderer. This allows the
///    same renderer to be used for static screenshots, animated previews, and
///    unit test snapshots.
///
/// 3. **CoreGraphics, not SwiftUI**: The schematics use CGContext drawing to
///    match the rest of the Lungfish rendering pipeline. If a SwiftUI host is
///    needed later, wrap in an NSViewRepresentable.
///
/// 4. **Offscreen rendering for performance**: For complex schematics (many
///    reads, quality bars), render to a CGImage tile and blit. Invalidate only
///    when parameters change.
///
/// 5. **Sample data generation**: The renderer does NOT use real FASTQ data.
///    It generates illustrative sample reads procedurally:
///    - Subsample/length filter: 8 reads with varied lengths.
///    - Quality trim: one read with a realistic quality decay curve.
///    - Error correction: one read with 2-3 marked error positions.
///    This keeps the schematic lightweight and deterministic.

/// ## File Organization
///
/// Recommended file structure:
///
/// ```
/// Sources/LungfishApp/Views/Viewer/
///   FASTQSchematicRenderer.swift          -- All static draw methods
///   FASTQSchematicPreviewView.swift       -- NSView host, animation driver
///   FASTQSchematicSampleData.swift        -- Procedural sample data generation
///   FASTQSchematicColors.swift            -- Color definitions (this spec, refined)
/// ```
///
/// Tests:
///
/// ```
/// Tests/LungfishAppTests/
///   FASTQSchematicRendererTests.swift     -- Snapshot tests for each operation
/// ```
