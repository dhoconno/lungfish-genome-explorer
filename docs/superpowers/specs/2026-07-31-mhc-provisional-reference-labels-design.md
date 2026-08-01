# Provisional MHC Reference Label Compatibility

## Goal

Allow full-length ONT MHC genotyping to use `.lungfishref` bundles whose allele annotations contain Lungfish provisional fields such as `ext01` and `new01`, without weakening the existing validation of species, locus, separators, or ordinary IPD-style allele fields.

## Accepted names

An allele name must retain the existing `Species-Locus*designation` structure. The designation must begin with a numeric field. Each colon-delimited field may then be either:

- a numeric IPD-style field, optionally ending in an alphabetic expression-status suffix such as `N`; or
- a controlled provisional field matching `ext` plus one or more digits or `new` plus one or more digits.

This accepts examples present in the reported reference bundle:

- `Mamu-E*02:16:ext01`
- `Mamu-E*02:new14:new01`
- `Mamu-E*000:new01`

It continues to reject malformed loci, empty fields, arbitrary words, and provisional fields without a numeric identifier.

## Run behavior

For `.lungfishref` inputs, the workflow will load and validate the MHC reference catalog immediately after resolving the reference FASTA and before it stages or processes sample reads. The validated records will be reused later when the durable catalog projection and provenance step are written. This avoids validating the same reference twice and prevents an invalid reference from wasting sample-processing time.

Plain FASTA behavior is unchanged.

## Provenance and failure handling

Successful runs will continue to record the in-process reference-catalog import step, its resolved cDNA threshold, source files, output projection, timing, and status. A preflight failure will still be captured by the existing failed-run provenance envelope, but it will occur before scientific sample processing begins.

## Tests

- Catalog tests will prove controlled `ext##` and nested `new##` fields are accepted from both annotations and FASTA descriptions.
- Catalog tests will prove lookalike malformed provisional fields remain rejected.
- Pipeline tests will prove reference catalog validation occurs before sample staging and that the prevalidated records are used for the final projection.
