# Genotype Palette and View Toggle Design

## Goal

Make LGE annotation workflows usable without leaving the app by exposing both quick color palettes in the genotype matrix inspector, letting haplotyped bundles switch into the genotype matrix view, remembering that choice per analysis bundle, and allowing haplotype definition colors to be customized.

## Palette Inspector

The genotype matrix annotation inspector will show two visible quick-pick sections at the same time:

- `mcm`: the existing 8 canonical MCM/Budde colors (`Absent`, `M1`-`M7`).
- `generic`: a 64-color OKLCH/OKLab-derived palette optimized for perceptual separation without reserving the MCM colors.

The existing palette target control (`Fill`, `Text`, `Border`) remains unchanged. Clicking any swatch in either section applies that color to the selected matrix row, column, or cell targets using the current target channel.

## Haplotype/Genotype View Toggle

When a genotype result has haplotyping results, the inspector will include a compact button that toggles the main summary viewport between the haplotyping/outline view and the genotype matrix view. The default remains haplotyping when haplotyping exists. If the user toggles a specific analysis bundle to the genotype matrix, that preference is saved in the bundle annotation sidecar and restored next time that bundle is opened.

The toggle is only a view preference. It does not change genotype calls, haplotype calls, workbook contents, or filtering thresholds.

## Haplotype Definition Colors

Haplotype definitions already store `colorTokenIndex`; this remains for backward compatibility and for canonical MCM defaults. Add an optional per-haplotype color override, stored as an annotation color. Rendering will use the override when present, otherwise it will use the existing token index/default assignment.

The haplotype definition editor will show per-haplotype color controls:

- the current effective color chip,
- `mcm` swatches,
- `generic` swatches,
- an Apple Color Picker override.

MCM reference bundles still default to MCM colors, but users can override them explicitly. Overrides are expected to be rare, so the UI should be compact and subordinate to the existing haplotype name/diagnostic allele editing controls.

## Persistence

- Matrix styles and comments continue to use `GenotypeAnnotationSidecar`.
- The per-bundle summary view preference will be added to `GenotypeAnnotationSidecar.Settings`.
- Haplotype color overrides will be encoded in `GenotypeHaplotypeDefinition` alongside `colorTokenIndex`. Missing overrides decode as `nil`, preserving existing bundles.

## Testing

Tests should cover:

- inspector exposes 8 `mcm` colors and 64 `generic` colors,
- swatches from either palette apply to the selected matrix style target,
- haplotyped results default to the haplotyping view,
- toggling to genotype matrix persists in the sidecar and restores for the same bundle,
- haplotype definitions decode old JSON without color overrides,
- haplotype definitions encode/decode color overrides,
- haplotype effective colors prefer overrides over token colors.
