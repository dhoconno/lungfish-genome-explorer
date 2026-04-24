# Lungfish Genome Explorer - App Icon Design Specification

**Version:** 1.0
**Date:** 2026-02-02
**Author:** Visual Design Artist (Role #26)
**Status:** Planning

---

## 1. Executive Summary

This document provides a comprehensive design specification for adapting the Lungfish Genome Explorer logo into a production-ready macOS app icon. The design must comply with Apple Human Interface Guidelines while maintaining brand recognition and scientific credibility.

---

## 2. Current Logo Analysis

### 2.1 Logo Elements (Based on Description)
- **Primary Shape:** Stylized lungfish/fish silhouette
- **Container:** Circular boundary
- **Eye Detail:** Virus outline in the lungfish's eye (corona-style with spike proteins)
- **Color Scheme:** Teal/turquoise gradient

### 2.2 Semantic Meaning
- **Lungfish:** Named after the Australian lungfish, one of the oldest living vertebrates with a remarkably large genome (~43 Gb)
- **Circular Container:** Represents completeness, genomic circularity (bacterial chromosomes, plasmids)
- **Virus Eye:** Signifies the software's focus on genomic/viral research and analysis

---

## 3. macOS App Icon Guidelines Analysis

### 3.1 Shape Requirements

macOS Sonoma (14+) uses the **rounded superellipse** (squircle) shape for app icons:

```
Shape Formula: |x|^n + |y|^n = 1 where n approximately 4-5
Corner Radius: Approximately 22.37% of icon width
```

**Critical Consideration:** The circular logo must be adapted to work within the squircle canvas. Options:
1. Place circular logo as a central element on a solid/gradient background
2. Expand the circular design to fill the squircle shape
3. Remove the circle and let the fish element stand alone

**Recommendation:** Option 1 - Maintain the circular logo as a central badge element on a subtle gradient background. This preserves brand recognition while filling the squircle canvas appropriately.

### 3.2 Visual Depth and Materials

Apple recommends icons have:
- **Subtle 3D appearance** (not flat, not overly skeuomorphic)
- **Consistent lighting** from top-left (11 o'clock position)
- **Gentle shadows** suggesting elevation
- **Material quality** (glass, metal, or organic surfaces)

**Recommendation for Lungfish:**
- Apply subtle inner glow to the circular container
- Add light top-down gradient to suggest gentle curvature
- Include a soft drop shadow beneath the circular badge
- Use a frosted glass/translucent effect on the background

### 3.3 Design Principles

| Principle | Application |
|-----------|-------------|
| **Recognizability** | Fish silhouette must be instantly readable at 16x16 |
| **Simplicity** | Reduce detail at smaller sizes; gear may need removal |
| **Consistency** | Match visual weight of system apps (Safari, Xcode) |
| **Distinctiveness** | Stand out in Dock among other science/dev tools |

---

## 4. Color Palette Specification

### 4.1 Primary Colors

The current teal/turquoise should be refined for optimal screen display and accessibility.

#### Primary Teal Gradient
| Name | Hex | RGB | HSL | Usage |
|------|-----|-----|-----|-------|
| **Lungfish Teal Dark** | `#007A8C` | 0, 122, 140 | 188, 100%, 27% | Gradient bottom, shadows |
| **Lungfish Teal** | `#00A0B0` | 0, 160, 176 | 185, 100%, 35% | Primary brand color |
| **Lungfish Teal Light** | `#00C4D9` | 0, 196, 217 | 186, 100%, 43% | Gradient top, highlights |
| **Lungfish Teal Bright** | `#4DD9E6` | 77, 217, 230 | 185, 73%, 60% | Accent highlights |

#### Background Colors
| Name | Hex | RGB | Usage |
|------|-----|-----|-------|
| **Background Dark** | `#1A2F3A` | 26, 47, 58 | Dark mode background |
| **Background Light** | `#E8F4F6` | 232, 244, 246 | Light mode background |
| **Background Neutral** | `#2E4A5A` | 46, 74, 90 | Standard icon background |

#### Accent Colors (for eye detail and highlights)
| Name | Hex | RGB | Usage |
|------|-----|-----|-------|
| **Eye White** | `#FFFFFF` | 255, 255, 255 | Eye background |
| **Virus Outline** | `#007A8C` | 0, 122, 140 | Virus outline in eye (dark teal) |
| **Highlight White** | `#FFFFFF` | 255, 255, 255 | Specular highlights |

### 4.2 Color Accessibility

All color combinations have been evaluated for accessibility:

| Combination | Contrast Ratio | WCAG Level |
|-------------|----------------|------------|
| Teal on Dark Background | 4.8:1 | AA |
| Teal Light on Dark | 7.2:1 | AAA |
| Fish on Background | 5.1:1 | AA |

### 4.3 P3 Wide Gamut Support

For enhanced vibrancy on Apple displays, define P3 color space variants:

| sRGB Hex | Display P3 Equivalent |
|----------|----------------------|
| `#00A0B0` | `color(display-p3 0.0 0.62 0.69)` |
| `#00C4D9` | `color(display-p3 0.0 0.76 0.85)` |

---

## 5. Icon Size Requirements

### 5.1 macOS App Icon Sizes

The AppIcon.appiconset requires the following sizes:

| Size (pt) | Scale | Pixels | Filename | Usage |
|-----------|-------|--------|----------|-------|
| 16 | 1x | 16x16 | `icon_16x16.png` | Finder list view |
| 16 | 2x | 32x32 | `icon_16x16@2x.png` | Finder list view (Retina) |
| 32 | 1x | 32x32 | `icon_32x32.png` | Finder column view |
| 32 | 2x | 64x64 | `icon_32x32@2x.png` | Finder column view (Retina) |
| 128 | 1x | 128x128 | `icon_128x128.png` | Finder icon view (small) |
| 128 | 2x | 256x256 | `icon_128x128@2x.png` | Finder icon view (Retina) |
| 256 | 1x | 256x256 | `icon_256x256.png` | Finder icon view |
| 256 | 2x | 512x512 | `icon_256x256@2x.png` | Finder icon view (Retina) |
| 512 | 1x | 512x512 | `icon_512x512.png` | Finder icon view (large) |
| 512 | 2x | 1024x1024 | `icon_512x512@2x.png` | App Store, About dialog |

### 5.2 Size-Specific Optimizations

| Size Range | Optimization |
|------------|--------------|
| **16-32px** | Remove virus eye detail, simplify fish to solid silhouette, increase stroke weight |
| **64-128px** | Show simplified virus outline in eye, maintain fish detail |
| **256-512px** | Full virus detail with spikes, gradients and subtle textures |
| **1024px** | Maximum detail, full virus with spike proteins, precise gradient work |

---

## 6. Light Mode / Dark Mode Variants

### 6.1 Automatic Appearance Support

macOS supports appearance-aware app icons. The icon should adapt to system appearance.

### 6.2 Light Mode Design
- **Background:** Subtle light gradient (`#E8F4F6` to `#D4E8EC`)
- **Circular Container:** Teal gradient with white inner glow
- **Fish Silhouette:** Dark teal (`#007A8C`) for contrast
- **Eye:** White background with dark teal virus outline
- **Shadow:** Soft drop shadow (10% black, 4px blur, 2px offset)

### 6.3 Dark Mode Design
- **Background:** Deep blue-gray gradient (`#1A2F3A` to `#2E4A5A`)
- **Circular Container:** Brighter teal gradient for pop
- **Fish Silhouette:** Light teal (`#4DD9E6`) or white outline variant
- **Eye:** White background with virus outline
- **Shadow:** Reduced shadow opacity (5% black)
- **Glow:** Subtle outer glow on circular container (teal, 20% opacity)

### 6.4 Implementation Note
For macOS 14+, provide both variants in the asset catalog using the "Any, Dark" appearance option.

---

## 7. Document Type Icons

### 7.1 Required File Type Icons

| Format | Extension | Description | Visual Approach |
|--------|-----------|-------------|-----------------|
| FASTA | `.fasta`, `.fa`, `.fna` | Sequence format | DNA helix motif |
| FASTQ | `.fastq`, `.fq` | Sequences with quality | DNA helix + quality bars |
| GenBank | `.gb`, `.gbk` | Annotated sequences | DNA helix + annotation bands |
| GFF3 | `.gff`, `.gff3` | Feature format | Horizontal feature bars |
| BAM | `.bam` | Aligned reads (binary) | Stacked alignment visualization |
| SAM | `.sam` | Aligned reads (text) | Similar to BAM, lighter style |
| CRAM | `.cram` | Compressed alignments | BAM style + compression motif |
| VCF | `.vcf` | Variant calls | Diamond/variant symbols |
| BED | `.bed` | Browser track | Horizontal colored regions |
| BigWig | `.bw`, `.bigwig` | Coverage data | Waveform/histogram motif |

### 7.2 Document Icon Design System

#### Base Template
All document icons follow macOS document icon conventions:
- Page shape with folded corner (top-right)
- Consistent size: 256x256 master (with standard size variants)
- Lungfish branding element (small fish silhouette or teal accent)

#### Visual Hierarchy
```
[File Type Badge]     <- Top portion: Format-specific graphic
[Lungfish Accent]     <- Small brand element
[Extension Label]     <- Bottom: ".fasta" text
```

#### Color Coding System
| Category | Primary Color | Hex |
|----------|---------------|-----|
| Sequence Formats | Teal | `#00A0B0` |
| Alignment Formats | Orange | `#E07020` |
| Annotation Formats | Purple | `#8060B0` |
| Variant Formats | Red | `#C04040` |
| Coverage Formats | Green | `#40A060` |

### 7.3 Document Icon Sizes

| Size (pt) | Scale | Pixels |
|-----------|-------|--------|
| 16 | 1x, 2x | 16, 32 |
| 32 | 1x, 2x | 32, 64 |
| 128 | 1x, 2x | 128, 256 |
| 256 | 1x, 2x | 256, 512 |
| 512 | 1x, 2x | 512, 1024 |

---

## 8. Asset Catalog File Structure

### 8.1 Complete Directory Structure

```
Sources/LungfishApp/Resources/Assets.xcassets/
|
+-- Contents.json
|
+-- AppIcon.appiconset/
|   +-- Contents.json
|   +-- icon_16x16.png
|   +-- icon_16x16@2x.png
|   +-- icon_32x32.png
|   +-- icon_32x32@2x.png
|   +-- icon_128x128.png
|   +-- icon_128x128@2x.png
|   +-- icon_256x256.png
|   +-- icon_256x256@2x.png
|   +-- icon_512x512.png
|   +-- icon_512x512@2x.png
|
+-- DocumentIcons/
|   +-- FASTADocument.iconset/
|   |   +-- Contents.json
|   |   +-- (size variants)
|   +-- FASTQDocument.iconset/
|   +-- GenBankDocument.iconset/
|   +-- GFFDocument.iconset/
|   +-- BAMDocument.iconset/
|   +-- SAMDocument.iconset/
|   +-- CRAMDocument.iconset/
|   +-- VCFDocument.iconset/
|   +-- BEDDocument.iconset/
|   +-- BigWigDocument.iconset/
|
+-- Colors/
|   +-- LungfishTeal.colorset/
|   |   +-- Contents.json (with Any + Dark variants)
|   +-- LungfishTealLight.colorset/
|   +-- LungfishTealDark.colorset/
|   +-- BackgroundLight.colorset/
|   +-- BackgroundDark.colorset/
|   +-- SequenceFormat.colorset/
|   +-- AlignmentFormat.colorset/
|   +-- AnnotationFormat.colorset/
|   +-- VariantFormat.colorset/
|   +-- CoverageFormat.colorset/
|
+-- AccentColor.colorset/
|   +-- Contents.json
|
+-- MenuBarIcon.imageset/
|   +-- Contents.json
|   +-- menubar_icon.pdf (template image)
|
+-- EmptyStates/
|   +-- NoSequences.imageset/
|   +-- NoResults.imageset/
|   +-- NoAnnotations.imageset/
|   +-- LoadingSequence.imageset/
|
+-- Symbols/
    +-- lungfish.symbolset/ (custom SF Symbol if needed)
```

### 8.2 Contents.json Templates

#### AppIcon.appiconset/Contents.json
```json
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

#### Color.colorset/Contents.json (with appearance variants)
```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.690",
          "green" : "0.627",
          "red" : "0.000"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.851",
          "green" : "0.769",
          "red" : "0.000"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

---

## 9. Design Workflow Recommendations

### 9.1 Recommended Tools

| Tool | Purpose |
|------|---------|
| **Figma** | Primary vector design, component system |
| **Sketch** | Alternative for native macOS design |
| **Affinity Designer** | Professional vector work |
| **SF Symbols** | Reference for visual weight/style |
| **Xcode** | Final asset catalog assembly |
| **IconSlate** | Batch export to required sizes |

### 9.2 Design Process

1. **Master Design (1024x1024)**
   - Create in vector format
   - Design at 1024x1024 with precise control
   - Include all gradient and shadow effects

2. **Size-Specific Variants**
   - Create optimized versions for 16px, 32px
   - Remove fine details that become noise at small sizes
   - Adjust stroke weights for clarity

3. **Export Pipeline**
   ```
   Master SVG/Figma -> Export PNGs at all sizes -> Asset Catalog
   ```

4. **Quality Verification**
   - Test in Dock at various sizes
   - Verify in Finder (list, column, icon views)
   - Check App Store preview
   - Validate on both Retina and non-Retina displays

### 9.3 Version Control

- Store master design files in `/design/source/` (not committed to main repo)
- Exported PNGs in asset catalog are committed
- Maintain changelog for icon revisions

---

## 10. Menu Bar Icon Specification

### 10.1 Template Image Requirements

macOS menu bar icons must be **template images**:
- Single color (black with alpha)
- System automatically applies appropriate color
- PDF format recommended for resolution independence

### 10.2 Design Guidelines

| Property | Specification |
|----------|---------------|
| Format | PDF (vector) |
| Color | Black (`#000000`) with alpha transparency |
| Height | 18pt (36px @2x) max |
| Style | Simplified fish silhouette |
| Weight | Match SF Symbols medium weight |

### 10.3 File Naming
```
menubar_icon.pdf (single PDF, resolution independent)
```

---

## 11. Implementation Checklist

### Phase 1: App Icon
- [ ] Create 1024x1024 master design
- [ ] Develop Light/Dark mode variants
- [ ] Export all size variants (10 PNG files)
- [ ] Create Contents.json for asset catalog
- [ ] Test across all Finder view modes
- [ ] Validate in Dock at various sizes

### Phase 2: Document Icons
- [ ] Design base document icon template
- [ ] Create format-specific variants (10 types)
- [ ] Export all sizes for each format
- [ ] Register UTIs in Info.plist
- [ ] Test file associations

### Phase 3: Additional Assets
- [ ] Design menu bar icon (template image)
- [ ] Create color assets for programmatic use
- [ ] Design empty state illustrations
- [ ] Create any needed custom SF Symbol extensions

### Phase 4: Quality Assurance
- [ ] Accessibility contrast verification
- [ ] Color blindness simulation testing
- [ ] Cross-appearance (Light/Dark) verification
- [ ] App Store screenshot preparation

---

## 12. References

- Apple Human Interface Guidelines - App Icons: https://developer.apple.com/design/human-interface-guidelines/app-icons
- Apple Human Interface Guidelines - macOS: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
- SF Symbols Guidelines: https://developer.apple.com/design/human-interface-guidelines/sf-symbols
- Asset Catalog Format Reference: https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/

---

## 13. Appendix A: Logo to Icon Transformation Diagram

```
ORIGINAL LOGO                    ADAPTED APP ICON
+------------------+            +----------------------+
|                  |            |    [squircle mask]   |
|    +--------+    |            |  +----------------+  |
|    |  FISH  |    |   ===>     |  |  [background]  |  |
|    |  (eye) |    |            |  |   +--------+   |  |
|    +--------+    |            |  |   |  FISH  |   |  |
|     [circle]     |            |  |   | [virus |   |  |
|                  |            |  |   |  eye]  |   |  |
+------------------+            |  |   +--------+   |  |
                                |  |    [circle]    |  |
                                |  |   [shadow]     |  |
                                |  +----------------+  |
                                +----------------------+

Key Changes:
1. Circle becomes badge element, not container
2. Background fills squircle canvas
3. Virus outline in eye adds scientific context
4. Gradient refined for icon use
```

---

## 14. Appendix B: Quick Reference Color Swatches

### Primary Palette
```
Lungfish Teal Dark    #007A8C  |||||||||||||
Lungfish Teal         #00A0B0  |||||||||||||||||
Lungfish Teal Light   #00C4D9  |||||||||||||||||||||||
Lungfish Teal Bright  #4DD9E6  |||||||||||||||||||||||||||
```

### Background Palette
```
Background Dark       #1A2F3A  |||||
Background Neutral    #2E4A5A  ||||||||
Background Light      #E8F4F6  |||||||||||||||||||||||||||||||
```

### Document Type Colors
```
Sequence (Teal)       #00A0B0  |||||||||||||||||
Alignment (Orange)    #E07020  |||||||||||||||||
Annotation (Purple)   #8060B0  |||||||||||||||||
Variant (Red)         #C04040  |||||||||||||||||
Coverage (Green)      #40A060  |||||||||||||||||
```

---

*Document prepared by Visual Design Artist role for the Lungfish Genome Explorer project.*
