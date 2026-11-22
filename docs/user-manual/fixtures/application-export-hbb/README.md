# Application export of the HBB region

A small export folder in the shape a sequence library application writes when you export a record, for the import of an application export. It holds the human beta-globin (HBB) region as a GenBank record, one variant as a VCF and a one-row index as a CSV. The same three files are also in one zip, since the importer takes a folder, an archive or a single file.

This is not a file set from a vendor application. A script, `make.py`, cut it from the public record NG_000007.3 (the record of the `hbb-gene/` fixture) and wrote the VCF and the index from rows typed into the script by hand. For this kind the importer sorts files by their type and not by the program that wrote them, so the kind you name only labels the collection. The kinds `alignment-tree` and `phylogenetics-result-set` are the exception, since they look for alignments and trees first. This set uses the neutral kind `sequence-design-library`.

| File | What it holds | Bytes |
| --- | --- | --- |
| `hbb-sequence-library/HBB_region.gb` | A GenBank record of 3,000 bases, positions 70,001 to 73,000 of NG_000007.3, with 42 features | 19,739 |
| `hbb-sequence-library/HBB_region.vcf` | One variant, the sickle variant rs334 | 296 |
| `hbb-sequence-library/index.csv` | A one-row index of the library | 128 |
| `hbb-sequence-library.zip` | The same three files as one archive | 4,078 |

The set serves chapter 02-sequences/06, the import of an application export.

## Source

The sequence is `NG_000007.3`, the RefSeqGene record "Homo sapiens beta globin region (HBB@)" of NCBI, 81,706 bases. The `hbb-gene/` fixture holds the whole record and the script `fetch.sh` there fetches it from NCBI. `make.py` in this folder, which uses the Python standard library only, took bases 70,001 to 73,000, shifted each feature by 70,000 and left out every feature that crosses the cut. It also writes the VCF and the index, whose rows are fixed text in the script. Rebuild with `python3 -I make.py <NG_000007.3 GenBank file of hbb-gene/> <new folder>`. A rebuild on 2026-11-21 from `hbb-gene/NG_000007.3.gb` was byte equal for `HBB_region.gb`, `HBB_region.vcf` and `index.csv`. The script was named `fx5_build.py` when it cut these files, and that name is still in its first lines and in the comment of `HBB_region.gb`. Position p of `HBB_region` is position p + 70,000 of NG_000007.3. The rs334 line follows dbSNP (`NM_000518.5(HBB):c.20A>T`).

## License

RefSeq records are produced by NCBI, a United States government agency, and carry no usage restriction in the United States. Check your own jurisdiction before you redistribute outside the United States. The cut, the VCF and the index are LGE's work from that record, and they and `make.py` are under LGE's MIT licence. Both allow shipping this folder.

## Citation

```bibtex
@article{oleary2016refseq,
  author  = {O'Leary, Nuala A. and Wright, Mathew W. and Brister, J. Rodney and others},
  title   = {Reference sequence (RefSeq) database at NCBI: current status, taxonomic expansion, and functional annotation},
  journal = {Nucleic Acids Research},
  year    = {2016},
  volume  = {44},
  number  = {D1},
  pages   = {D733--D745},
  doi     = {10.1093/nar/gkv1189}
}

@article{sherry2001dbsnp,
  author  = {Sherry, Stephen T. and Ward, Minghong H. and Kholodov, Michael and others},
  title   = {dbSNP: the NCBI database of genetic variation},
  journal = {Nucleic Acids Research},
  year    = {2001},
  volume  = {29},
  number  = {1},
  pages   = {308--311},
  doi     = {10.1093/nar/29.1.308}
}
```

## Size

The data files total 24,241 bytes (24 KB) in 4 files, and `make.py` is 5,200 bytes. The largest is `HBB_region.gb` at 19,739 bytes. Both caps are far off. `SHA256SUMS` lists the SHA-256 of every file but itself and this README.

## Internal consistency

On the cut, the HBB gene runs from 545 to 2,152 and its coding sequence is `join(595..686,817..1039,1890..2018)`, which is 444 bases for 147 amino acids and the stop codon. The sickle codon, codon 7 of the coding sequence (bases 19 to 21), is `GAG` at positions 613 to 615. The VCF puts the variant at position 614 with reference `A` and alternate `T`, which is `c.20A>T`, and the base at 614 of the record is `A`. The cut keeps 1 gene, 1 mRNA, 1 CDS, 37 misc_feature and 2 mat_peptide features, 42 in all, and the imported bundle reports 42 annotation features.

The importer turns `HBB_region.gb` into the reference bundle `HBB_region.lungfishref`. It recognises `HBB_region.vcf` as a variant track and `index.csv` as a report, routes neither, and keeps both as binary artifacts with one warning each. The zip gives the same result and the same two warnings.

## Check

These commands ran in a scratch project with the `lungfish-cli` of Lungfish Preview 2026.11.15. Each ended with exit 0. Create the project folder first (`mkdir demo.lungfish`).

```sh
lungfish-cli import application-export sequence-design-library hbb-sequence-library --project demo.lungfish --collection-name "HBB sequence library"
lungfish-cli import application-export sequence-design-library hbb-sequence-library.zip --project demo.lungfish --collection-name "HBB sequence library zip"
```
