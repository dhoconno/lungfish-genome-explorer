# HBB RefSeqGene fixture

The RefSeqGene record for the human beta-globin locus on chromosome 11,
fetched with `rettype=gbwithparts` so the full gene, mRNA, CDS, and exon
feature table is present rather than a bare sequence. Supports the
sequence-viewing, annotation, extraction, and translation chapters.
Sickle cell disease (HbS, Glu6Val at HBB amino acid 6, which is codon 7
of the coding sequence, dbSNP rs334) is the
example that shows why a reader would look at this record.

## Genome

`NG_000007.3`, Homo sapiens beta globin region (HBB@), RefSeqGene on
chromosome 11, 81,706 bp, GenBank flatfile (`.gb`), not FASTA. A
RefSeqGene region record covers the whole beta-globin gene cluster, not
only HBB. The file also carries HBE1, HBG2, HBG1, BGLT3, HBBP1, and HBD
alongside HBB itself, which is expected and is what "region record"
means. The sequence and coordinates are used as published, nothing is
renamed or shifted.

HBB itself sits at `70545..72152` (gene span) with a spliced CDS at
`join(70595..70686,70817..71039,71890..72018)`, protein `NP_000509.1`
(147 codons before the stop, starts `MVHLTPEEKSAV...`). Codon 7 of that
CDS (GAG, Glu, CDS positions 19 to 21) is the site of the classic sickle
mutation (GAG to GTG, `c.20A>T`, HbS, rs334). It is called Glu6Val because
the mature protein loses its first methionine, so amino acid 6 of the
mature chain is codon 7 of the CDS. Clinical notation, which counts the
methionine, writes it `p.Glu7Val`. The manual's translation-chapter example reads that codon out
of this fixture rather than fabricating a synthetic sequence.

## Sources

This record comes from NCBI Nucleotide `NG_000007.3`, fetched via NCBI eutils
efetch with the full feature table resolved. The `rettype=gbwithparts`
parameter (rather than plain `gbwithparts`-less `gb`) is what makes
CDS/mRNA/exon feature locations resolve against real sequence instead
of leaving a `CONTIG` join() placeholder.

The URL was checked live (`HTTP 200`) on 2026-09-06.

## License and citation

RefSeq records are produced by NCBI, a U.S. government agency, and are
public domain (no usage restriction) in the United States. Check your
local jurisdiction if redistributing outside the U.S.

Cite:

```bibtex
@article{oleary2016refseq,
  author  = {O'Leary, Nuala A. and Wright, Mathew W. and Brister, J. Rodney
             and Ciufo, Stacy and Haddad, Diana and McVeigh, Rich
             and Rajput, Bhanu and Robbertse, Barbara and Smith-White, Brian
             and Ako-Adjei, Danso and Astashyn, Alexander and Badretdin, Azat
             and Bao, Yiming and Blinkova, Olga and Brover, Vyacheslav
             and Chetvernin, Vyacheslav and Choi, Jinna and Cox, Eric
             and Ermolaeva, Olga and Farrell, Catherine M. and Goldfarb, Tamara
             and Gupta, Tripti and Haft, Daniel and Hatcher, Eneida
             and Hlavina, Wratko and Joardar, Vinita S. and Kodali, Vamsi K.
             and Li, Wenjun and Maglott, Donna and Masterson, Patrick
             and McGarvey, Kelly M. and Murphy, Michael R. and O'Neill, Kathleen
             and Pujar, Shashikant and Rangwala, Sanjida H. and Rausch, Daniel
             and Riddick, Lillian D. and Schoch, Conrad and Shkeda, Andrei
             and Storz, Susan S. and Sun, Hanzhen and Thibaud-Nissen, Francoise
             and Tolstoy, Igor and Tully, Raymond E. and Vatsan, Anjana R.
             and Wallin, Craig and Webb, David and Wu, Wendy
             and Landrum, Melissa J. and Kimchi, Avi and Tatusova, Tatiana
             and DiCuccio, Michael and Kitts, Paul and Murphy, Terence D.
             and Pruitt, Kim D.},
  title   = {Reference sequence (RefSeq) database at NCBI: current status,
             taxonomic expansion, and functional annotation},
  journal = {Nucleic Acids Research},
  year    = {2016},
  volume  = {44},
  number  = {D1},
  pages   = {D733--D745},
  doi     = {10.1093/nar/gkv1189}
}
```

## Committed files

| File | Size |
| --- | --- |
| `NG_000007.3.gb` | 144 KB |

Total committed is 144 KB, well under both the 10 MB per-file cap and the
50 MB fixture-set cap.

## Feature counts

Counted directly from the GenBank flatfile. Run this command.

`grep -c "     <feature> " NG_000007.3.gb`

The counts are below.

| Feature | Count |
| --- | --- |
| `gene` | 8 |
| `mRNA` | 5 |
| `CDS` | 5 |
| `exon` | 13 |

Eight genes because the record spans the whole beta-globin cluster
(HBE1, HBG2, HBG1, BGLT3, HBBP1, HBD, HBB, plus the upstream
pseudogene OR51AB1P), five of which (HBE1, HBG2, HBG1, HBD, HBB) carry
an mRNA and a spliced three-exon CDS. BGLT3 is a long non-coding RNA
and HBBP1 is a processed pseudogene, so neither has a CDS.

## Import check

Verified the record imports through the CLI (which accepts GenBank
directly, not only FASTA):

```
lungfish-cli import fasta docs/user-manual/fixtures/hbb-gene/NG_000007.3.gb --name HBB -o /tmp/hbb-import-check
```

Output:

```
✓ Reference Import
  Summary
    Name        : HBB
    Sequences   : 1
    Total length: 81.7 kb
    Bundle      : HBB.lungfishref
    Sequences: NG_000007
✓ Reference import complete: HBB (1 sequences, 81.7 kb)
```

A `HBB.lungfishref` bundle appeared under
`Reference Sequences/HBB.lungfishref/` with `genome/`, `annotations/`,
`metadata/`, `tracks/`, `variants/`, and `provenance/` subfolders as
expected. The command's own summary line reports sequences and total
length but not a feature count, so the feature count was read from the
bundle's `manifest.json`:

```json
"annotations" : [
  {
    "annotation_type" : "gene",
    "feature_count" : 102,
    "name" : "Imported Annotations"
  }
]
```

**102 annotation features imported.** This is more than the 8+5+5+13 =
31 gene/mRNA/CDS/exon count above because the GenBank feature table
also carries `misc_feature` (59, mostly protein domain and modified-
residue annotations), `regulatory` (7), `mat_peptide` (2), `ncRNA` (1),
`mobile_element` (1), and `misc_RNA` (1) records, all of which the
importer carried into `annotations/imported_annotations.gff3`
(confirmed by `awk -F'\t' '{print $3}' imported_annotations.gff3 | sort
| uniq -c`, which totals 102 feature lines). The `/tmp` check bundle
was not committed to this fixture directory.

## Internal consistency

The GenBank flatfile's own feature-type tallies (8 gene, 5 mRNA, 5 CDS,
13 exon) and the imported GFF3's tallies for those same four types (8,
5, 5, 13) match exactly, confirming the CLI's GenBank-to-GFF3
conversion preserves every gene, transcript, coding, and exon feature
in the source record. The extra 71 features in the 102 total are other
GenBank feature types (misc_feature, regulatory, mat_peptide, ncRNA,
mobile_element, misc_RNA) that the four grep patterns above do not
count, not evidence of double-counting or drift.

## Regenerating

```bash
bash docs/user-manual/fixtures/hbb-gene/fetch.sh
```

Needs network access to `eutils.ncbi.nlm.nih.gov`. No conda tools or
managed environment are required, this fixture is a single flatfile
fetched over HTTPS.
