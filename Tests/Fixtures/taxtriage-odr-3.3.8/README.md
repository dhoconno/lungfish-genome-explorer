# TaxTriage 3.3.8 organism discovery report fixture

A trimmed per-sample result folder from TaxTriage (jhuapl-bio/taxtriage v3.3.8,
revision e10bfebda32a62711f38a4e23ab03b61725a9675).

Source: public SRA run SRR12486983 (human corneal metagenome with HSV-1), run in
LGE with the Standard-16 Kraken2 database and `--remove_taxids 9606`.

- `SRR12486983/report/SRR12486983.odr.txt` is the header plus 5 unmodified rows of
  the per-sample organism discovery report (ODR): Bradyrhizobium sp. WCU1 (TASS 100),
  Human alphaherpesvirus 1 (93), Kocuria sp. BT304 (92), Acinetobacter radioresistens
  (72, below the 75.0 threshold) and Chimpanzee herpesvirus strain 105640 (6).
- `SRR12486983/combine/SRR12486983.combined.gcfmap.tsv` holds the matching
  accession lines from the same run.

No BAM is included, so `build-db taxtriage` skips the samtools read-count pass.
