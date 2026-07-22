# MHC unmatched-cluster GenBank implementation plan

1. Add failing model/loader tests for optional candidate and un-nameable GenBank manifest references, checksum/path validation, and exclusion from the eager parsed-artifact byte budget.
2. Preserve selected reciprocal orientation in fresh schema-2 candidate and un-nameable records with backward-compatible decoding.
3. Add tested bounded CIGAR projection and candidate GenBank record construction covering forward/reverse mappings, lifted feature intervals, CDS translation, cDNA gap/exon inference, support/project comments, deterministic ordering, and source-only un-nameable records.
4. Generate and publish both GenBank companions from the full-length MHC candidate staging generation; attach complete transformation provenance and final artifact descriptors.
5. Thread both outputs through bundle publication and CLI-visible artifacts without changing adjacent Lungfish surfaces.
6. Update the candidate viewport schema gates to accept document schemas 1 and 2 while keeping the manifest at schema 1; retain the existing 256 MiB loader budget.
7. Run focused IO, workflow, UI, workbook, pipeline, and CLI tests, then a fresh four-sample CLI analysis. Inspect artifact sizes/contents/provenance, build `Lungfish Debug`, quit older Lungfish instances, and launch the verified debug app.
