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
