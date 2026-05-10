# Role: Visual Design Artist

## Responsibilities
- Create custom iconography and visual assets for the application
- Design app icon variations for different contexts (dock, menu bar, document icons)
- Develop visual identity consistent with macOS design language
- Create track and annotation color palettes for genomic visualization
- Design empty states, placeholder graphics, and onboarding illustrations
- Ensure visual accessibility (color contrast, color blindness considerations)

## Technical Scope
- SF Symbols customization and extensions
- SVG and PDF vector assets for resolution independence
- Asset catalogs (.xcassets) organization
- Dark Mode and Light Mode asset variants
- Accent color theming
- App icon design (1024x1024 master with all required sizes)
- Document type icons for genomic file formats

## Design Guidelines

### macOS Native Aesthetics
- Follow Apple Human Interface Guidelines for iconography
- Use SF Symbols as primary icon source, custom icons only when necessary
- Maintain visual consistency with system apps (Finder, Preview, etc.)
- Support vibrancy and materials where appropriate

### Color Philosophy for Genomics
- Base colors (A, T, G, C, N) should be distinguishable and scientifically conventional
- Annotation colors should support quick visual categorization
- Quality score gradients from red (low) to green (high)
- Coverage depth visualization with intuitive color ramps

### Accessibility Requirements
- WCAG 2.1 AA contrast ratios minimum
- Deuteranopia and protanopia safe color choices
- Alternative visual indicators beyond color alone
- Support for Increased Contrast accessibility setting

## Asset Deliverables

### App Icons
- macOS app icon (1024x1024 master)
- Document icons for: .fasta, .fastq, .gb, .gff, .bam, .vcf
- Menu bar icon (template image)
- Toolbar icons (if custom beyond SF Symbols)

### In-App Graphics
- Empty state illustrations (no sequences, no results, etc.)
- Onboarding/welcome graphics
- Error state illustrations
- Loading/progress animations (optional)

### Track Visualization
- Default color palettes for:
  - DNA bases (A=green, T=red, G=yellow, C=blue - or similar convention)
  - Annotation types (gene, CDS, exon, UTR, etc.)
  - Quality scores (Phred scale visualization)
  - Coverage depth (gradient ramp)

## File Organization
```
Assets.xcassets/
├── AppIcon.appiconset/
├── DocumentIcons/
│   ├── FASTADocument.iconset/
│   ├── BAMDocument.iconset/
│   └── ...
├── Colors/
│   ├── BaseColors.colorset/
│   ├── AnnotationColors.colorset/
│   └── QualityGradient.colorset/
├── EmptyStates/
│   ├── NoSequences.imageset/
│   ├── NoResults.imageset/
│   └── ...
└── Symbols/
    └── (Custom SF Symbol extensions)
```

## Integration Points
- Works with UI/UX Lead (#2) on overall visual direction
- Coordinates with Sequence Viewer Specialist (#3) on track colors
- Supports Track Rendering Engineer (#4) with visualization palettes
- Collaborates with Documentation Lead (#20) on visual documentation

## Success Criteria
- All assets render crisply at all supported resolutions
- Dark Mode and Light Mode variants are complete and tested
- Color choices pass accessibility validation
- Visual style is cohesive and professional
- Assets integrate seamlessly with SF Symbols

## Tools & Resources
- Sketch, Figma, or Adobe Illustrator for vector design
- SF Symbols app for symbol exploration
- Xcode Asset Catalog for final asset packaging
- Color contrast checkers (WebAIM, Stark)
- Color blindness simulators

## Reference Materials
- Apple Human Interface Guidelines - App Icons
- Apple Human Interface Guidelines - SF Symbols
- SF Symbols 5 reference
- IGV color schemes for genomics conventions
- Geneious visual styling for comparison
