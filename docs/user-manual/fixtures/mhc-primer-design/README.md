# Macaque MHC class I sequences for primer design

Public genomic sequences of rhesus macaque (Macaca mulatta) MHC class I genes, used by the
primer design chapters and the Primer Design demo project. Every record is a full-length
genomic DNA submission to the INSDC from the Biomedical Primate Research Centre (BPRC),
Rijswijk, the Netherlands (2019), fetched from ENA with
`https://www.ebi.ac.uk/ena/browser/api/fasta/<accession>` and checked against its EMBL
record (length and `/allele` qualifier) on 2026-09-26. Headers keep the accession as the
sequence ID and the allele name in the description.

| File | Records | What it is for |
|---|---|---|
| `mamu-a1-panel.fasta` | 12 | Mamu-A1 alleles from 12 lineages, 2,920 to 2,943 bases, exon 1 to exon 8. Aligned, they are the input for a tiled amplicon scheme and for a single PCR assay across exons 2 and 3. |
| `mamu-a1-001-lineage.fasta` | 4 | Mamu-A1*001 lineage alleles, the sequences a lineage-detection qPCR assay must detect. |
| `mamu-class-i-exclusion.fasta` | 15 | Eleven other Mamu-A1 lineages plus the A2, A3, A4 and B paralogs, the sequences that assay must not detect. |

| Accession | Allele | Length | Files |
|---|---|---|---|
| LR699574.1 | Mamu-A1*001:01:01:01 | 2,933 | panel, lineage |
| LR701148.1 | Mamu-A1*001:01:01:02 | 2,933 | panel, lineage |
| LR744011.1 | Mamu-A1*001:05:01:01 | 2,960 | lineage |
| LR723086.1 | Mamu-A1*001:06:01:01 | 2,959 | lineage |
| LR699565.1 | Mamu-A1*002:01:01:01 | 2,924 | panel, exclusion |
| LR701150.1 | Mamu-A1*003:06:01:01 | 2,920 | panel, exclusion |
| LR699573.1 | Mamu-A1*008:01:01:01 | 2,921 | panel, exclusion |
| LR701151.1 | Mamu-A1*011:01:01:01 | 2,943 | panel, exclusion |
| LR701152.1 | Mamu-A1*012:01:01:01 | 2,921 | panel, exclusion |
| LR701153.1 | Mamu-A1*016:01:01:01 | 2,924 | panel, exclusion |
| LR721684.1 | Mamu-A1*019:01:01:01 | 2,931 | panel, exclusion |
| LR699576.1 | Mamu-A1*023:01:01:01 | 2,931 | panel, exclusion |
| LR699575.1 | Mamu-A1*025:01:01:01 | 2,940 | panel, exclusion |
| LR699578.1 | Mamu-A1*041:01:01:01 | 2,925 | panel, exclusion |
| LR699579.1 | Mamu-A1*055:01:01:01 | 2,922 | exclusion |
| LR699584.1 | Mamu-A2*05:04:01:01 | 3,092 | exclusion |
| LR699586.1 | Mamu-A3*13:02:01:01 | 2,933 | exclusion |
| LR699723.1 | Mamu-A4*14:03:01:01 | 2,920 | exclusion |
| LR699592.1 | Mamu-B*001:01:01:01 | 2,858 | exclusion |

Twelve alleles is a teaching size. A working laboratory scheme would include every allele
seen in the colony and published alleles from the same population of origin.

## Licence and attribution

INSDC records are freely available under the ENA terms of use
(https://www.ebi.ac.uk/about/terms-of-use). Allele names follow the IPD-MHC NHP nomenclature;
cite IPD-MHC as the nomenclature authority (Maccari et al. 2017, Nucleic Acids Research,
doi:10.1093/nar/gkw1050).

## Reproduce

```sh
for acc in LR699574.1 LR701148.1 ...; do
  curl -sf "https://www.ebi.ac.uk/ena/browser/api/fasta/$acc"
done
```

The accession lists for each file are in the tables above.
