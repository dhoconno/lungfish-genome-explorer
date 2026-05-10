# Lungfish Color Palette

## Primary Accent: Lungfish Orange

The primary accent color throughout the Lungfish GUI is **Lungfish Orange** — a warm, saturated amber-orange that evokes the ancient lineage of the lungfish.

| Usage | Hex | RGB | NSColor |
|-------|-----|-----|---------|
| **Primary accent** | `#D47B3A` | (212, 123, 58) | `NSColor(red: 0.831, green: 0.482, blue: 0.227, alpha: 1.0)` |
| **Accent hover/pressed** | `#BF6C30` | (191, 108, 48) | Darker variant for pressed/hover states |
| **Accent light** | `#E8A06A` | (232, 160, 106) | For subtle highlights, selection backgrounds |
| **Accent ultralight** | `#F5D4B8` | (245, 212, 184) | For very subtle backgrounds, banner fills |

### Where to Use Lungfish Orange
- **Toolbar icons** (active/selected state)
- **Sidebar selection highlight** (accent color)
- **Button tints** (borderedProminent buttons)
- **Progress indicators** and spinners
- **Active tab indicators**
- **App icon** (primary color)
- **Operation status badges** (running state)
- **Chart/graph accent lines**

### How to Reference in Code

```swift
// In SwiftUI
Color("LungfishOrange")       // from Asset Catalog
Color(nsColor: .lungfishOrange)

// In AppKit
NSColor.lungfishOrange         // defined as extension
```

Define in Asset Catalog as `LungfishOrange` with:
- Any Appearance: #D47B3A
- Dark Appearance: #E8A06A (slightly lighter for dark mode contrast)

## Semantic Colors

| Role | Light Mode | Dark Mode | Usage |
|------|-----------|-----------|-------|
| **Primary text** | System label | System label | All primary text |
| **Secondary text** | System secondary label | System secondary label | Captions, subtitles, metadata |
| **Background** | Window background | Window background | Main content areas |
| **Surface** | Control background | Control background | Cards, panels, grouped sections |
| **Divider** | Separator color | Separator color | Section dividers |
| **Success** | System green | System green | Completed operations, valid states |
| **Warning** | System yellow | System yellow | RAM warnings, disk space alerts |
| **Error** | System red | System red | Failed operations, validation errors |

## Classification Tool Colors

Each classification tool has a distinct color to help users identify results at a glance:

| Tool | Hex | Usage |
|------|-----|-------|
| **Kraken2** | `#5B8DEF` (blue) | Taxonomy sunburst, classification badges |
| **EsViritu** | `#7EC47E` (green) | Detection badges, viral coverage bars |
| **TaxTriage** | `#C77DBA` (purple) | Triage confidence indicators |
| **NAO-MGS** | `#E8A06A` (amber) | Surveillance result badges (variant of accent) |

## Chart Color Scales

### Taxonomy Phylum Colors
Use the existing phylum-based coloring in `TaxonomySunburstView.swift`. These are bioinformatics-standard colors derived from the NCBI taxonomy visualization palette.

### Heatmap Scale
For abundance heatmaps (multi-sample views):
- Zero: `#FFFFFF` (white) / `#1E1E1E` (dark mode)
- Low: `#F5D4B8` (accent ultralight)
- Medium: `#D47B3A` (accent primary)
- High: `#8B3A1A` (deep rust)

### Coverage Plots
- Covered regions: Lungfish Orange (`#D47B3A`)
- Uncovered gaps: System red with 30% opacity
- Background: Control background

## Rules

1. **Always use system semantic colors** for text, backgrounds, and standard UI elements
2. **Lungfish Orange** is the sole accent color — do not introduce additional accent hues
3. **Dark mode**: Use Asset Catalog "Any/Dark" variants, not manual `@Environment(\.colorScheme)` checks
4. **Contrast**: All text on Lungfish Orange backgrounds must be white or very dark for WCAG AA compliance
5. **Opacity**: Use opacity variants (0.1, 0.15, 0.3) of accent for subtle backgrounds, never hard-coded grays
6. **SF Symbols**: Use `.foregroundStyle(Color.accentColor)` to automatically pick up the accent
7. **Charts**: Primary data series always uses Lungfish Orange; secondary series use the classification tool colors
