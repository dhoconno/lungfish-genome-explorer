# Pathogen Detection

This is a demo project for Lungfish Genome Explorer (LGE), version {{VERSION}}. It holds the practice data for the manual's classification and pathogen detection chapters, already imported the way each chapter's Before you start section asks. No classification has been run and no result file has been imported, so every result in the project will be one you made.

## What is inside

| Item | What it is |
| --- | --- |
| `Imports/SRR12486983.lungfishfastq` | Corneal tissue from a case of herpes simplex keratitis, 4,819,760 read pairs, fetched through the SRA route as one paired bundle |
| `Imports/SRR12486989.lungfishfastq` | Corneal tissue recorded with Streptococcus agalactiae, 5,440,369 read pairs, the second sample of the TaxTriage batch |
| `Practice Data/nvd-demo/results/` | A minimal NVD results folder, the folder the NVD importer is pointed at |
| `Practice Data/naomgs/virus_hits_final.tsv.gz` | A small five-site NAO-MGS wastewater report in one combined table |
| `Practice Data/czid/minimal_taxon_report.tsv` | A three-row CZ ID taxon report |

The three result files are left as files because importing them is the procedure of their chapters. The reads make up nearly all of the 260 MB download, which is why this project is the largest of the set.

## Where the data came from

SRR12486983 and SRR12486989 belong to NCBI BioProject PRJNA381365, a study of corneal infections in formalin-fixed specimens, sequenced on an Illumina NextSeq 550 with reads of up to 76 bases. SRR12486983 is the pathogen identification example of the Kraken software suite protocol. Both runs are public in the NCBI Sequence Read Archive under NCBI's data use policies. Check your local rules before redistributing the reads. Cite Lu and colleagues (2022), Metagenome analysis using the Kraken software suite, Nature Protocols 17, 2815 to 2839, https://doi.org/10.1038/s41596-022-00738-y.

The NVD folder holds 10 synthetic BLAST hit rows across three samples and four contigs, all SARS-CoV-2, kept with the LGE source for testing the NVD reader. The NAO-MGS and CZ ID reports are small test reports kept with the LGE source. None of the three comes from a real surveillance or clinical run, so read them as examples of the file shapes rather than as findings.

## Chapters that use this project

{{CHAPTERS}}

BLAST Verification starts from a finished Kraken 2 result on SRR12486983 against the Viral database, so run Running Kraken 2 first. Running TaxTriage classifies both runs as one batch.

## A first step to try

1. Open this project with **File > Open Project Folder...**.
2. Download the Kraken 2 Viral database from the Databases tab of **Tools > Plugin Manager...**. It needs about half a gigabyte of memory.
3. Click `SRR12486983` under `Imports` in the sidebar and carry on with Running Kraken 2 from step 2 of its procedure.

## Before you run anything

Plugin packs and databases are installed on your Mac, not stored in a project, so this download carries none. Kraken 2 needs the Metagenomics pack and a Kraken 2 database such as Viral or Standard-16. TaxTriage needs Docker Desktop and a Kraken 2 database. BLAST Verification sends sampled reads to NCBI over the internet, and the NAO-MGS import downloads matched references from NCBI. The NVD and CZ ID imports need nothing extra.
