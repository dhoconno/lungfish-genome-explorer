# Feedback on X01-taxtriage-walkthrough

The video is shared with a collaborator from the LabKey public area and is not on the Videos page.

| # | Date | From | At | Comment | Change | Status |
|---|---|---|---|---|---|---|
| 1 | 2026-10-16 | owner | 1:40 | Long pause after the Operations panel narration | monitor beat cut to 20 s with three segments | changed, render shared 2026-10-16 |
| 2 | 2026-10-16 | owner | end | Explain how SILVA and Standard databases answer other questions | new `databases` beat | changed, render shared 2026-10-16 |
| 3 | 2026-10-16 | owner | end | Acknowledge the TaxTriage team and link to the tool | new `credits` card with the paper DOI and the GitHub repository | changed, render shared 2026-10-16 |
| 4 | 2026-10-16 | owner | 2:40 | Why are there no reference bases in the zoomed pileup | LGE prunes TaxTriage's `download/` folder, which holds the reference FASTA. Narration says no reference was loaded. Fix proposed as a separate task | open (app fix) |
| 5 | 2026-10-16 | owner | end | Credits go last, and the evidence ending should show BLAST and read extraction, not just name them | new `evidence` card, `blast`, `extract` and `extracted` beats, credits moved last | changed, render shared 2026-10-16 |
| 6 | 2026-10-16 | owner | 0:45 | Say that FASTQ files can also come from the computer, not only SRA | new `import-center` beat | changed, render shared 2026-10-16 |
| 7 | 2026-10-16 | filming | 4:00 | BLAST Verify failed on TaxTriage results in Preview 2026.10.19 (no BAM index passed) | fixed in 77cdb0964, the `blast` beat is filmed in a Debug build of that commit and says so | changed, refilm on the next Preview |
