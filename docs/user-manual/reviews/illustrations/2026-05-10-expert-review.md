# Illustration Expert Review

Date: 2026-05-10

Scope: 24 fresh documentation illustrations generated from the specification in
`docs/user-manual/reviews/illustrations/illustrations-todo.md`.

Deliverables reviewed:

- `docs/user-manual/assets/illustrations-imagegen/**/*.source.png`
- `docs/user-manual/assets/illustrations-imagegen/**/*.svg`
- `docs/user-manual/assets/illustrations-imagegen/manifest.json`

Review lenses:

- Scientific correctness: genomics coordinates, sequencing reads, Phred scores,
  amplicon primer orientation, alignment/CIGAR, pileups, VCF fields, reference
  bundles, accession anatomy, classification, MSA/tree, and assembly concepts.
- Scientific illustration quality: consistent warm colored-pencil style,
  professional visual hierarchy, label legibility, and fit for user-manual use.
- Asset packaging: each illustration is saved as an individual self-contained
  SVG with its imagegen source embedded.

Findings addressed:

- Regenerated `primer-scheme-diagram` so every `LEFT` primer points right, every
  `RIGHT` primer points left, and primer pairs face inward around each amplicon.
- Regenerated `reference-bundle-anatomy` to remove a misleading GISAID-style
  pseudo-source from the `MN908947.3` reference bundle example. The provenance
  file now shows generic reproducibility fields: command, inputs, checksums, and
  runtime.
- Regenerated `ncbi-accession-anatomy` to label `MN` as the accession prefix
  rather than an accession namespace.
- Adjusted SVG dimensions for `position-coordinates`, `phred-quality-bar`,
  `coverage-histogram`, `pileup-view`, and `primer-scheme-diagram` so the
  accepted imagegen art is not reduced by large wrapper gutters.
- Removed the temporary review contact sheet from the deliverable asset root.

Final status:

- The expert scientific review found the remaining set scientifically usable
  after the primer-orientation and provenance-source fixes.
- The scientific illustration review found the set coherent with the approved
  warm colored-pencil direction after the wrapper composition fixes.
- The deliverable set contains 24 individual SVG files and 24 corresponding
  imagegen source PNG files.
