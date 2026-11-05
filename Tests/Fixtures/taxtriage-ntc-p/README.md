# taxtriage-ntc-p

Two sample folders of a real TaxTriage batch, cut for lane TTREADS of Phase 3.2. The batch ran TaxTriage on
225 public SRA virus reads in three samples, with NTC 1 and Water (blank) as negative controls. Water (blank)
failed in the pipeline and is left out.

Each folder holds what `build-db taxtriage` reads.

- `report/<sample>.odr.txt`, the organism discovery report, as the pipeline wrote it.
- `combine/<sample>.combined.gcfmap.tsv`, the references of each organism, as the pipeline wrote it.
- `minimap2/<sample>.<sample>.dwnld.references.bam` and its `.bai`. The records are the pipeline's. The header
  leaves out the `@PG` lines that a Lungfish markdup pass added after the run, since they named local paths.

Influenza A virus (A/New York/392/2004(H3N2)) has eight segments, each a reference of its own. Its reads sit on
segments 2 and 5, and none on segment 4 (NC_007366.1), which is the first reference the gcfmap lists for it.

| Sample | Organism | # Reads Aligned | Primary records by reference |
|---|---|---|---|
| patient | Severe acute respiratory syndrome coronavirus 2 | 33 | NC_045512.2 33 |
| patient | Sewage-associated gemycircularvirus 4 | 1 | NC_026144.1 1 |
| patient | Influenza A virus (A/New York/392/2004(H3N2)) | 3 | NC_007369.1 2, NC_007372.1 1 |
| patient | Bovine coronavirus | 1 | NC_003045.1 1 |
| NTC_1 | Severe acute respiratory syndrome coronavirus 2 | 20 | NC_045512.2 20 |
| NTC_1 | Sewage-associated gemycircularvirus 4 | 1 | NC_026144.1 1 |
| NTC_1 | Influenza A virus (A/New York/392/2004(H3N2)) | 2 | NC_007369.1 2 |

Used by `BuildDbTaxTriageOrganismReadsTests` and `BuildDbTaxTriageOrganismReadsLiveConformanceTests`.
