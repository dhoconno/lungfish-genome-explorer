# Classify reads with TaxTriage

Filmed with Lungfish Preview 2026.10.19. The narration is a synthetic voice.

This video shows how to classify sequencing reads with TaxTriage inside Lungfish Genome Explorer, and how to judge what it finds.

The example is one air sample from an airport surveillance study. Choose File, then Search Online Databases, then Search SRA, and enter the run accession SRR35520577. LGE looks up the run and shows its instrument, title and size.

Select the run and click Download Selected. The Import FASTQ sheet reads the platform and pairing from the archive record. The VSP2 Target Enrichment recipe removes duplicates, trims adapters, removes human reads and merges overlapping pairs. These reads are already in the project, imported with this recipe, so we cancel here.

Reads on your own computer come in the same way. Choose File, then Import Center, and under Sequencing Read Files click Import to pick FASTQ files from a folder or a drive. A sample sheet or a Nanopore run folder works too.

Search the sidebar for the run and select it. The cards show about 254 thousand reads after cleanup, and the Inspector on the right lists the archive metadata, such as the study, the sample and the capture strategy.

Under Classification, choose TaxTriage. LGE checks that Nextflow and Docker are ready. Pick the Viral Kraken2 database and keep Illumina as the platform. Skip assembly keeps the run fast, and human reads, taxon 9606, are excluded before references are chosen. Click Run.

The run appears in the Operations panel with its current step and elapsed time. Click Log to see the exact command and each pipeline step as it runs. This sample took about two minutes on a laptop. When it finishes, the result is saved under Analyses in the project.

Each row is an organism, ranked by its TASS score, a confidence value from zero to one based on how the reads align. The Summary tab records the database and settings.

SARS-CoV-2 has 575 reads, but only 2 unique reads. The viewer draws coverage across its genome, and nearly all of it sits in one spot, about 1 percent of the genome.

Tick Include duplicate-marked reads, and the depth jumps to 573. Up close, every read starts at the same position, copies of very few molecules. Colored bases only mean no reference was loaded.

Compare phiX174, the control DNA commonly spiked into Illumina runs. Its 8 reads are all unique and spread across the genome, which is why it scores 0.9. Here it confirms the sequencing worked, not that phage was in the air.

A high read count alone is not a detection. To check a hit, send its reads to BLAST, or take the reads out of LGE and test them with other tools.

Select the SARS-CoV-2 row and click BLAST Verify. LGE sends a sample of its reads, 20 by default, to NCBI BLAST against the core nucleotide database, and tracks the job while it runs. Here, 2 reads match SARS-CoV-2 at 99.5 and 100 percent identity, and 2 reads find no significant hit. Expand a read to see its top matches.

To use the reads elsewhere, click Extract FASTQ. Choose FASTQ or FASTA, then save them as a bundle in the project, save a file, copy them to the clipboard to paste into a web tool, or share them. Here we save a bundle.

The new bundle appears under Extractions with its 2 reads, ready for any other LGE tool or for export.

The database sets the question. Viral holds only RefSeq viral genomes and suits a virus screen like this one. Standard-16 adds bacteria, archaea and human, for a broad pathogen screen. SILVA holds ribosomal RNA genes, for asking which bacteria and eukaryotes are present.

TaxTriage is built and maintained by a team at the Johns Hopkins University Applied Physics Laboratory, and we thank them for it. The paper is in the journal Bioinformatics, and the code and documentation are at github.com/jhuapl-bio/taxtriage.
