# Lungfishgenotype Viewport and Inspector Design

## Context

`.lungfishgenotype` bundles currently route from the sidebar to the primary `.xlsx` workbook through QuickLook. That preserves the generated report, but it leaves Lungfish Genome Explorer unable to expose the structured result model, switch user lenses, or use the Inspector for sample-level review. The attached `pbaa.xlsx` example encodes sample identifiers, duplicate sample columns, read-count summaries, manually curated MHC haplotype calls, comments, and a large genotype-count matrix with conditional formatting. The attached `metadata.xlsx` shows the richer sample metadata users want beside calls: animal ID, cohort, species, PCR ID, MiSeq run, amplicon set, Fluidigm barcode, ONT barcode, and comments.

The sprint should not replace the generated workbook. The workbook remains an auditable artifact. The new native viewport should make the bundle useful inside the app and keep provenance visible.

## Users

Analysts need a dense review surface for sample calls, read support, QC flags, comments, and genotype/haplotype evidence. Their first task is to decide whether the result is credible enough to call, annotate, or revisit.

Consumers need a quieter lens that explains the result without requiring them to read the full workbook. Their first task is to understand what was tested, which samples have usable calls, which results need caution, and where provenance and artifacts live.

## MVP

Build a native `.lungfishgenotype` result model from the bundle manifest, retained-demux genotype CSV, sample summary CSV, stats JSON, workbook path, and provenance path. The model should expose:

- Bundle identity: output name, analysis name, created date, artifact URLs.
- Run metrics: total input reads, retained unique reads, assigned/unassigned retained reads, and retained percent where present.
- Sample summaries: per-sample alignment count, unique retained reads, retained percentage, total reads, genotype-call count, top genotype, and QC status.
- Genotype calls: sample, genotype/reference name, passed alignments, unique reads, per-sample retained metrics, and inferred locus/haplotype tokens from genotype names when available.

Add a native genotype result viewport that replaces QuickLook for sidebar `.lungfishgenotype` selection. It should use familiar macOS controls:

- A top summary strip with sample count, total calls, retained reads, and QC status distribution.
- A segmented lens control with Analyst, Consumer, and Artifacts views.
- Analyst view: sortable/filterable sample table plus a detail pane showing calls for the selected sample, read-support metrics, QC flags, inferred loci, and top genotypes.
- Consumer view: compact interpretation cards for run health, sample readiness, strongest calls, cautions, and provenance/artifacts.
- Artifacts view: paths/buttons for workbook, long summary CSV, sample summary CSV, stats JSON, and provenance.

Use the Inspector objects rather than leaving the Inspector blank:

- Add a genotype viewport content mode so the toolbar and provenance policy treat genotype results as scientific content.
- Add a genotype result document state in the Document tab summarizing run metrics, artifact links, sample/call counts, and QC distribution.
- Update Selected Item when a sample or call is selected in the genotype viewport.
- Keep the Provenance tab available and pointed at the final `.lungfishgenotype` bundle.

## QC Rules

The initial QC labels should be deterministic and conservative:

- `review`: no genotype calls or zero retained/assigned evidence.
- `low support`: positive calls exist but either passed alignments are below 20 or unique retained reads are below 5.
- `ok`: evidence meets the thresholds above.

These thresholds are display heuristics only. They should not rewrite calls or block exports.

## Provenance

This is a display feature and must not create, import, transform, export, or wrap scientific data. It should not write new scientific outputs. If future analyst annotations become persisted outputs, that workflow must write full Lungfish provenance into the affected bundle/directory and must preserve final stored payload paths.

## Deferred

Editable analyst annotations, color persistence, workbook round-tripping, sample metadata import from external `.xlsx`, haplotype-call editing, KIR-specific presentation, and clinician-ready PDF/PowerPoint exports are deferred. The MVP should leave obvious seams for those features by keeping parsing, presentation rows, and Inspector document state separate.
