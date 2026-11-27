# Evidence: the human reference install and a count on galah (2026-11-26)

Run on galah (Mac Studio, 64 GB) from the branch `claude/rnaseq-novice-path-6417ad`. The CLI was the Debug `lungfish-cli` of 75925afbc, which is the command the Plugin Manager row runs. The storage root was `/Volumes/lge_scratch/lge/rnaseq/lge-installs/novice-path/root`, a fresh root whose `conda` links to the locked salmon 2.11.0 and gffread environments of `rs-lock`.

## The GUI was not walked

The Debug app was built (`scripts/build-app.sh --without-linux-executor`) and launched on that root. The computer-use grant for `com.lungfish.browser.debug` came back `user_denied` with no one at galah, so the run used the CLI equivalent, as the task allows. The pane and row words are pinned by `RNASeqReferenceCatalogModelTests`, `RNASeqQuantDialogTests` and `CLIImportRunnerTests`. A walk of Plugin Manager > Databases and the empty count pane is still owed.

## Install

```
lungfish-cli rnaseq install-reference --default human/gencode-50 --storage-root <root> --format json
```

- Started 22:27, ended 23:30 CST. 3,771 s wall, peak resident 19.8 GB, exit 0.
- Events: `start`, one `progress` stream over the two downloads (EBI served about 0.7 MB/s), `log` "Building the reference set from the genome and the genes", `log` "Building the salmon index, which takes about an hour", then `complete` "Ready to count with the reference set homo_sapiens-GRCh38-gencode50-lge-c287524e9a53" with the set and index paths as outputs.
- Both downloads matched the row's sha256 pins. They are kept in `rnaseq-reference-downloads/human-gencode-50/` (925 MB).
- Set `homo_sapiens-GRCh38-gencode50-lge-c287524e9a53` (6.7 GB). Index `salmon-2.11.0-k31-genome-decoys` (9.8 GB). In all, 17.4 GB is kept, so the row now says about 18 GB.
- A second run of the same command printed `complete` in 1.7 s, downloading and building nothing.

## Count

The sample is SRR896663 (SEQC, Universal Human Reference RNA, GSE47774), the first 1,000,000 read pairs of each mate. R1 sha256 `4f4fbfec…0c6`, R2 `0f193f91…689`. It was imported with `lungfish-cli import fastq --pairing paired` as one bundle, `SRR896663_1M.lungfishfastq`, in `~/LGE-GUI-Walk/novice-path/RNAseq-demo.lungfish`.

```
lungfish-cli rnaseq quant <bundle> --project <project> --set homo_sapiens-GRCh38-gencode50-lge-c287524e9a53 --storage-root <root>
```

- 34.5 s, exit 0, result `Analyses/RNA-seq_counts.lungfishrnaseq` with its provenance.
- `rnaseq quality`: library size 1,000,000, mapping rate 85.28%, library type IU, 852,806 counted, rRNA 0.85%.
- 78,479 genes. The top genes are MT-CO1 (ENSG00000198804), EEF1A1, MT-ND4, a lncRNA, MT-RNR2 and GAPDH, as expected for UHRR.

## Not run

- The mouse install. Its two files were downloaded and checked against GENCODE's MD5SUMS and sizes before the sha256 pin, but the set and index were not built.
- A GUI walk of the new section and pane. It needs the owner at galah to approve computer use.

## Rhesus and cynomolgus macaque (2026-11-27)

The owner asked for the two macaques after the first cut. The catalog gained each species' default row of P5-REFS, `rhesus/ensembl-116` (Mmul_10, Ensembl 116) and `cynomolgus/refseq-GCF_037993035.2` (T2T-MFA8v1.1, RefSeq RS_2025_03). Both were installed on galah, one after the other, with the Debug `lungfish-cli` of the working tree on 64ec2cf7f and the same storage root as above.

| | Rhesus | Cynomolgus |
|---|---|---|
| Install | 08:15 to 08:55 CST, 2,427 s, peak resident 18.9 GB, exit 0 | 08:55 to 09:25 CST, 1,769 s, peak resident 21.5 GB, exit 0 |
| Set | `macaca_mulatta-Mmul_10-ensembl116-lge-3f0fee25ce9e` (1.5 GB), 35,433 genes, 0 without features | `macaca_fascicularis-T2T-MFA8v1.1-refseqrs_2025_03-lge-b514efeeb33d` (2.8 GB), 33,980 genes, 6,617 without features |
| Index | `salmon-2.11.0-k31-genome-decoys` (7.9 GB) | `salmon-2.11.0-k31-genome-decoys` (8.9 GB) |
| Downloads kept | 851 MB | 910 MB |
| Sample | GSE304256 SRR34827382 (blood), first 1,000,000 pairs | GSE225770 SRR23580178 (CD8+ T cells), first 1,000,000 pairs |
| Count | 25 s, mapping 78.92%, IU, rRNA 11.78%, 35,223 genes | 28 s, mapping 67.30%, IU, rRNA 8.98%, 33,166 genes |
| Top genes | LSU rRNA, HBE1, HBA, CD74, B2M, ACTB | an rRNA LOC, ACTB, B2M, a C_region LOC, TMSB4X, FOS |

The events of each were `start`, the download progress, the two `log` steps and `complete`, as for human. Both downloads of each matched their sha256 pins.

The cynomolgus T2T set has 6,617 genes without features and no mitochondrial genes, as REFSET-T2T-NOT-BUILT predicted. The genome FASTA has no mitochondrial record. `cynomolgus/ensembl-107` has 37 MT genes, so the manual names it for mitochondrial counts.

The 21.5 GB cynomolgus peak and the 19.8 GB human peak are above the 16.6 GB that `SalmonIndexNeed` checks. galah's 64 GB covered both. The model is unchanged here and is a follow-up.

The four 1M-pair cuts are in `/Volumes/lge_scratch/lge/rnaseq/lge-installs/novice-path/macaque-reads/` (R1/R2 sha256 `b8a8ad64…`/`ac9f30b4…` rhesus, `c6e42ef7…`/`ec5f905c…` cynomolgus). The results are `RNA-seq_counts-2` (rhesus) and `RNA-seq_counts-3` (cynomolgus) in the project above.
