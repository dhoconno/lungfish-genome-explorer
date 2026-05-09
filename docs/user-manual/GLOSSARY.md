# Glossary

**Ownership:** Bioinformatics Educator only.

Terms appear in alphabetical order. Each entry is a one-sentence definition, followed by an explicit anchor ID in `{#anchor-id}` form so chapters can deep-link from inline references and the in-app Help system can resolve term lookups directly to this page. Anchor IDs match the `glossary_refs:` slugs declared in chapter frontmatter.

## A

**Alias map** {#alias-map}. The internal table Lungfish consults during VCF import to recognise that two reference accessions (for example, the GenBank record `MN908947.3` and the RefSeq record `NC_045512.2`) name the same underlying sequence, so a VCF keyed against one resolves cleanly to a project bundle keyed against the other. See also: VCF, reference bundle.

**Alignment** {#alignment}. The mapping of one read against a reference genome, recorded as one row in a BAM file with a position, strand, CIGAR string, and quality scores. See also: BAM, mapping.

**Allele frequency** {#allele-frequency}. The proportion of sequencing reads at a position that carry the alternate base. A clinical isolate usually shows allele frequencies near 0 or 1; a mixed-population sample (for example, wastewater) shows a full spectrum.

**Amplicon** {#amplicon}. A target region of a genome amplified by PCR, used as the unit of an amplicon-based sequencing protocol such as ARTIC or QIASeqDIRECT. A run produces many overlapping amplicons that together tile the region of interest.

**Assembly bundle** {#assembly-bundle}. A `.lungfishref` bundle that holds a de novo assembly produced inside the project, typically by SPAdes or MEGAHIT, and lives under the project's `Assemblies/` folder. The internal structure is identical to a reference bundle; only the folder placement distinguishes the two. See also: reference bundle, bundle.

## B

**BAI** {#bai}. The companion index file for a BAM that lets viewers jump to a specific reference position without reading the whole file; conventionally named `<sample>.bam.bai` and kept in the same folder as the BAM. See also: BAM.

**BAM** {#bam}. The binary, indexed form of the SAM alignment format, with one row per aligned read and a header listing reference contigs; Lungfish always reads and writes BAMs rather than SAMs because of size and random-access requirements. See also: BAI, alignment, CIGAR.

**BAQ** {#baq}. Base Alignment Quality, samtools' per-base recalibration that lowers the quality of bases sitting near indel-prone regions; useful for shotgun random-fragment data and counterproductive for amplicon data, which is why Lungfish disables BAQ (`-B`) for amplicon variant calling. See also: pileup.

**Barcode** {#barcode}. A short oligonucleotide sequence (typically 8 to 24 bases) ligated onto a sample's reads during library prep so that pooled samples can be sorted back to their wells after multiplexed sequencing; ONT runs identify barcodes during basecalling and write one subfolder per barcode. See also: basecaller.

**Basecaller** {#basecaller}. The program that converts a sequencer's raw signal into base-called reads with quality scores; for Oxford Nanopore data, Guppy and Dorado are the two basecallers in current use, and the model used to call a run determines which Medaka model is appropriate downstream. See also: simplex read, duplex read.

**BLAST (Basic Local Alignment Search Tool)** {#blast}. NCBI's nucleotide and protein sequence search service that ranks database entries by local-alignment score against a query, used in Lungfish to verify a classifier's hit by sending a representative read to NCBI's `nt` database. See also: e-value, percent identity, query coverage.

**Bundle** {#bundle}. A folder that the macOS Finder shows as a single icon with an extension and that Lungfish treats as one logical object, with a manifest, primary data files, optional indexes and annotations, and a `provenance/` subfolder. Lungfish bundle types include `.lungfishref` for references and assemblies and `.lungfishprimers` for primer schemes. See also: reference bundle, assembly bundle, primer scheme.

## C

**CIGAR** {#cigar}. A compact string in each BAM row that describes, base by base, how the read aligns to the reference: `M` for aligned positions, `I` and `D` for insertions and deletions, `S` for soft-clipped ends, and `H` for hard-clipped ends. See also: BAM, soft-clip.

**Clade** {#clade}. A group on a phylogenetic tree consisting of one internal node and every tip descended from it; the unit a phylogeneticist points to when claiming "these isolates share a recent common ancestor". See also: phylogram.

**Codon** {#codon}. A run of three consecutive bases inside a protein-coding gene that together encode one amino acid. Three adjacent SNPs falling inside one codon describe one amino acid change, not three; iVar can group them into a single VCF row when given a GFF annotation. See also: VCF.

**Conda** {#conda}. A package manager that handles compiled non-Python dependencies cleanly, used in Lungfish to install bioinformatics tools from the bioconda channel into per-tool environments under `~/.lungfish/conda`. See also: micromamba, plugin pack.

**Consensus FASTA** {#consensus-fasta}. The reference sequence with high-confidence sample variants applied in place; positions with insufficient evidence are masked as `N`. The format Pangolin and Nextclade expect for SARS-CoV-2 lineage assignment, and the format used for GISAID and NCBI surveillance submissions. See also: VCF, allele frequency.

**Contig** {#contig}. A contiguous stretch of assembled sequence emitted by an assembler, representing the longest path through the assembly graph that the algorithm could resolve unambiguously; one assembly bundle holds many contigs, ranked by length in the assembly viewport. See also: assembly bundle, N50.

**Contig (in a reference)** {#contig-reference}. One named sequence in a multi-record FASTA; in `.lungfishref` bundles the contig list comes from FASTA headers and matches the BAM, VCF, and GFF3 contig fields.

**Coordinate** {#coordinate}. A 1-based position on a reference, named as `chrom:position` (for example, `MN908947.3:21618`). Lungfish presents 1-based inclusive coordinates to the user everywhere; underlying file formats may use 0-based half-open (BED) or 1-based inclusive (VCF, GFF3, SAM/BAM displayed). See also: chromosome.

**Coverage** {#coverage}. The number of reads that align across a given reference position; used interchangeably with depth in this manual. See also: pileup.

## D

**Depth** {#depth}. Synonym for coverage in this manual. The number of reads stacked at one reference position. See also: coverage.

**Duplex read** {#duplex-read}. An Oxford Nanopore read produced by basecalling both strands of the same DNA molecule and reconciling them into a single high-accuracy consensus; duplex Q30+ approximates Illumina-grade accuracy and is the basis for modern Medaka-duplex models. See also: simplex read, basecaller.

## E

**E-value** {#e-value}. The number of database alignments of equal or better score expected by chance for a given query length and database size; in BLAST results, smaller is better, with values at or below `1e-30` indicating an essentially unmistakable match for a typical viral read. See also: BLAST, percent identity.

**ENA (European Nucleotide Archive)** {#ena}. The European mirror of the SRA, hosted at EMBL-EBI; one of three INSDC partners (with NCBI SRA and DDBJ) that share deposited sequencing data. Lungfish downloads SRA runs from ENA first because ENA serves pre-converted FASTQs directly, and falls back to the NCBI SRA Toolkit when ENA is unavailable. See also: SRA.

## F

**FAI (FASTA index)** {#fai}. A small text index file (typically `<sequence>.fasta.fai`) produced by `samtools faidx` that lets tools jump to a specific position in a FASTA without reading the whole file; required for variant calling and many other reference-keyed operations. See also: FASTA.

**FASTA** {#fasta}. A plain-text format for nucleotide or protein sequences, with each record introduced by a `>` header line followed by sequence lines containing the bases. Lungfish accepts plain FASTA, multi-record FASTA, and bgzipped FASTA at every reference picker. See also: FAI, FASTQ.

**FASTQ** {#fastq}. A plain-text format for sequencing reads, with each read taking exactly four lines: a `@`-prefixed header, the read sequence, a `+` separator, and a same-length quality string in the standard ASCII offset 33 encoding. The input format for every workflow that starts from raw sequencing data. See also: paired-end, Phred score.

**FILTER (in a VCF)** {#filter}. The seventh standard VCF column, holding either `PASS` (the row cleared every filter the caller applied) or a semicolon-separated list of named filter flags the row failed (such as `ft` for failed allele-frequency threshold or `sb` for strand-bias rejection). See also: VCF, INFO, FORMAT.

**FLAG (in a BAM)** {#flag}. A bitwise integer field in each BAM row encoding facts about the read in twelve canonical bits: paired, properly paired, unmapped, mate unmapped, reverse strand, mate reverse strand, first of pair, second of pair, secondary alignment, low quality, duplicate, supplementary alignment. The decoded value `99` is the sum of bits 1+2+32+64. See also: BAM, supplementary alignment.

**FORMAT (in a VCF)** {#format}. The ninth standard VCF column, declaring a colon-separated list of keys (such as `GT:DP:AF`) that describe the per-sample payload columns following it. See also: VCF, INFO.

## G

**Genotype** {#genotype}. A compact notation for which alleles are observed at a variant position, conventionally diploid-style `0/1` (heterozygous) or `1/1` (homozygous alternate). For a single-organism viral isolate, confidently-called variants are nearly always `1/1`.

**GFF (General Feature Format)** {#gff}. A tab-separated table format for genomic features (genes, CDS, mature peptides, regulatory elements). GFF3 is the current spec; Lungfish accepts GFF3 paired with a FASTA at bundle creation. See also: FASTA, reference bundle.

## I

**INFO (in a VCF)** {#info}. The eighth standard VCF column, holding semicolon-separated `KEY=VALUE` pairs of per-row metadata such as depth (`DP`), allele frequency (`AF`), strand bias (`SB`), and per-allele depths (`AD`). See also: VCF, FILTER, FORMAT.

**INSDC (International Nucleotide Sequence Database Collaboration)** {#insdc}. The three-way partnership of NCBI (USA), EMBL-EBI (Europe), and DDBJ (Japan) that mirrors deposited nucleotide sequences and assigns a single globally-unique accession to each record; ENA, NCBI SRA, and DDBJ Sequence Read Archive are the SRA tier of this partnership. See also: ENA, SRA.

**Inspector** {#inspector}. The right-hand pane of a Lungfish project window that shows context-sensitive metadata and analysis actions for whatever is selected in the sidebar or main viewport. Toggle with `Cmd-Opt-I`. See also: sidebar, project.

**IQ-TREE** {#iqtree}. A maximum-likelihood phylogenetic inference program with a built-in ModelFinder step and ultrafast bootstrap support estimation, used by Lungfish to produce `.lungfishtree` bundles from MSA bundles. See also: MSA, phylogram, support value.

## L

**Lineage** {#lineage}. A named subgroup within a viral species, defined by a characteristic set of variants and assigned by a domain-specific tool (Pangolin for SARS-CoV-2, Nextclade for many viruses). Lungfish does not assign lineages itself; it produces consensus FASTAs that downstream tools call lineages from. See also: consensus FASTA.

## M

**MAFFT** {#mafft}. A multiple sequence alignment program that auto-selects an algorithm by input size and is the default aligner Lungfish runs when producing a `.lungfishmsa` bundle. See also: MSA.

**Mapper** {#mapper}. A program that places sequencing reads onto a reference genome and emits an alignment file (BAM); Lungfish ships minimap2, BWA-MEM2, Bowtie2, and BBMap. See also: alignment, mapping.

**Mapping** {#mapping}. The act of finding, for each read, the reference position where it best fits and recording the alignment in a BAM. See also: alignment, mapper.

**MAPQ (mapping quality)** {#mapq}. A per-read confidence score in each BAM row, encoding how unambiguously the mapper placed the read at the recorded position; 0 means no confidence (the read fits multiple places equally well), 60 is the maximum for most mappers and means the placement is well above the second-best alternative. See also: BAM, mapper.

**Methods export** {#methods-export}. The Lungfish provenance export that emits a plain-prose Markdown paragraph naming each tool and its resolved version in the order the workflow ran them, suitable for pasting into a paper's methods section. See also: provenance sidecar.

**Micromamba** {#micromamba}. A small standalone bootstrap that speaks the conda protocol without requiring a full Anaconda installation, used by Lungfish as the engine for plugin pack installs. See also: conda, plugin pack.

**MSA (Multiple Sequence Alignment)** {#msa}. A rectangular arrangement of two or more related sequences in which each column represents an inferred homologous position, with `-` gap characters padding insertions; in Lungfish stored as a `.lungfishmsa` bundle. See also: MAFFT.

## N

**N50** {#n50}. A summary statistic for a set of assembled contigs: the length such that contigs of at least that length together hold half of the assembly's total bases; a higher N50 indicates a less fragmented assembly. See also: contig, assembly bundle.

**NAO-MGS** {#nao-mgs}. A metagenomic surveillance pipeline tuned for wastewater pathogen monitoring, distributed by the Nucleic Acid Observatory and run inside Lungfish through the Classification wizard or imported through `lungfish nao-mgs import`; results are stored as a time-series keyed by sample date and site. See also: surveillance series, sample date.

**Newick** {#newick}. A compact parenthesised text format for phylogenetic trees, with branch lengths after colons and optional support values at internal nodes; the lingua franca for moving trees between FigTree, iTOL, ete3, and Lungfish. See also: phylogram.

## O

**Operations Panel** {#operations-panel}. The bottom pane of a Lungfish project window that lists every long-running operation with a status, timestamp, log link, and provenance disclosure, and that serves as the project's audit trail. Toggle with `Cmd-Shift-P` or by clicking the footer status chip. See also: provenance, project.

**Orient Reads** {#orient-reads}. A Lungfish operation that aligns ONT reads against a reference and flips reverse-strand reads so every read in the bundle ends up in the same orientation, useful for amplicon protocols and consensus building. See also: basecaller, simplex read.

## P

**Paired-end** {#paired-end}. A sequencing protocol that reads each DNA fragment from both ends, producing two reads per fragment; the two halves of a pair travel as separate FASTQ files with `_1`/`_2` or `_R1`/`_R2` suffixes. See also: FASTQ, single-end.

**Phred score** {#phred-score}. A logarithmic per-base quality value defined as `Q = -10 * log10(P)` where P is the error probability; Q20 = 1% error, Q30 = 0.1% error, Q40 = 0.01% error. Encoded in FASTQ files as ASCII characters offset by 33 (so `!` = Q0, `F` = Q37). See also: FASTQ.

**Phylogram** {#phylogram}. A phylogenetic tree drawn so that branch length is proportional to the inferred amount of evolutionary change (substitutions per site); the default tree-viewport layout in Lungfish. See also: clade, IQ-TREE.

**Percent identity** {#percent-identity}. In a BLAST or other pairwise alignment, the fraction of aligned positions where the query and the subject sequence agree, calculated only over the aligned region; read together with query coverage to gauge how much of the read aligned and how well. See also: BLAST, query coverage.

**Pileup** {#pileup}. The column of bases observed at one reference position across every read that covers it, together with their qualities and strands; the unit of evidence a variant caller weighs at each position. See also: coverage, variant-caller.

**Plugin pack** {#plugin-pack}. A themed group of related bioinformatics tools that Lungfish installs on demand into per-tool conda environments, named for the workflow it supports (for example, `read-mapping`, `variant-calling`, `assembly`). See also: conda, micromamba.

**Primer** {#primer}. A short oligonucleotide, typically 18 to 30 bases, that binds a specific position on a target genome and primes DNA synthesis from that position; the building block of every amplicon protocol. See also: amplicon, primer scheme.

**Primer scheme** {#primer-scheme}. The set of primer coordinate pairs that define an amplicon protocol, listing where each forward and reverse primer binds on the reference. In Lungfish, a primer scheme is packaged as a `.lungfishprimers` bundle that carries the BED coordinates, the primer sequences in FASTA, and provenance.

**Primer trim** {#primer-trim}. The step that removes primer-derived bases from the ends of aligned reads in amplicon data, so those bases do not contaminate variant calls. In Lungfish the trim runs as a BAM-level operation using `ivar trim` against a selected primer scheme. See also: amplicon, primer scheme.

**Project** {#project}. A folder on disk that holds every input, output, bundle, and provenance record for one Lungfish analysis, with a fixed top-level layout of `Imports/`, `Downloads/`, `Reference Sequences/`, `Assemblies/`, and `Primer Schemes/`. The folder is the project; nothing important lives outside it. See also: bundle, sidebar.

**Provenance** {#provenance}. The record Lungfish keeps alongside every download and every operation describing where a file came from or how it was produced, including source URL or accession, exact tool version, full command line, input checksums, and output checksums. See also: Operations Panel.

**Provenance sidecar** {#provenance-sidecar}. The JSON file Lungfish writes alongside every output (or into a bundle's `provenance/` subdirectory), recording the workflow name, resolved command, input and output checksums, runtime identity, and per-step exit status for one operation. See also: provenance, methods export.

## Q

**Query coverage** {#query-coverage}. In a BLAST result, the fraction of the query sequence that participated in the alignment to the subject; a high percent identity over only a fraction of the read is much weaker evidence than a moderate identity over most of the read. See also: BLAST, percent identity.

## R

**Read length** {#read-length}. The number of bases in a sequencing read; Illumina reads are typically 75-300 bp (fixed per run), Oxford Nanopore reads range from 1 kb to 100 kb (variable per run with mean 5-15 kb), PacBio HiFi reads are 10-25 kb. See also: FASTQ.

**Reference bundle** {#reference-bundle}. A `.lungfishref` bundle stored under a project's `Reference Sequences/` folder, containing a primary FASTA, an index, optional annotations such as GFF3 or GTF, any tracks attached to that reference (alignments, variants, classifications), and a manifest. See also: bundle, assembly bundle.

**Reference genome** {#reference-genome}. A specific, community-agreed sequence used as the comparison point for samples; for SARS-CoV-2 the standard reference is `MN908947.3` (the Wuhan-Hu-1 isolate). Variants are described relative to a chosen reference, so reference choice affects which variants are reported and at what positions. See also: reference bundle.

**REF, ALT** {#ref-alt}. REF is the base or bases present in the reference genome at a variant position; ALT is the base or bases observed in the sample. A one-base REF and one-base ALT describe a SNP; longer REF or ALT describe insertions and deletions.

**Representative read** {#representative-read}. A single sequencing read selected from the set of reads a classifier assigned to a particular taxon, used as the BLAST query when verifying that taxon assignment; Lungfish lists candidates longest first because longer reads carry more BLAST signal. See also: BLAST.

**Reproducibility** {#reproducibility}. The property that a workflow re-run with the same inputs, the same plugin pack version, and the same Lungfish build produces output that matches the original by checksum (bit-identical) or by content (logically equivalent); the provenance sidecar carries every field needed to verify this. See also: provenance sidecar.

## S

**Sample date** {#sample-date}. The collection date Lungfish uses to position a classification result on a surveillance series's time axis, sourced in priority order from an explicit wizard or metadata entry, then a recognised date pattern in the FASTQ filename, then the FASTQ file's modification timestamp. See also: NAO-MGS, surveillance series.

**Shotgun sequencing** {#shotgun}. A library preparation strategy in which sample nucleic acid is fragmented at random and sequenced without targeted amplification; each read lands at an essentially arbitrary position on the genome. Shotgun data does not require primer trimming. See also: amplicon.

**Sidebar** {#sidebar}. The left-hand pane of a Lungfish project window that shows the project's contents as a folder tree with five fixed top-level folders (`Imports/`, `Downloads/`, `Reference Sequences/`, `Assemblies/`, `Primer Schemes/`). Toggle with `Cmd-Shift-S`. See also: project, Inspector.

**Simplex read** {#simplex-read}. An Oxford Nanopore read produced by basecalling one strand of a DNA molecule passing through a pore once; modern R10.4.1 simplex with super-accuracy basecallers achieves Q20+ per-base quality. See also: duplex read, basecaller.

**Single-end** {#single-end}. A sequencing protocol that reads each DNA fragment from one end only, producing one FASTQ file per sample; common for Oxford Nanopore and for some Illumina shotgun protocols. See also: FASTQ, paired-end.

**Soft-clip** {#soft-clip}. A flag in a BAM record (the `S` letter in a CIGAR string) marking bases at the start or end of a read that are present in the record but excluded from pileup, coverage, and variant calling; primer trimming works by soft-clipping primer-derived bases rather than deleting them. See also: primer trim, CIGAR.

**SRA (Sequence Read Archive)** {#sra}. The NCBI public archive of raw sequencing reads, identified by accession numbers that start with `SRR` for runs and `SRP` for projects. Lungfish downloads SRA reads via the ENA mirror first and falls back to the SRA Toolkit if ENA refuses. See also: ENA.

**Strand** {#strand}. Whether a read aligned to the reference as sequenced (forward) or as its reverse complement (reverse); recorded as a flag bit in every BAM row. See also: strand bias.

**Strand bias** {#strand-bias}. A pattern where reads supporting a variant come predominantly from one strand of the reference, often as an artifact of primer placement in amplicon protocols rather than a genuine biological signal. Variant callers apply a strand-bias filter to flag suspect calls; for amplicon data the filter is usually disabled because the imbalance is structural. See also: amplicon.

**Supplementary alignment** {#supplementary-alignment}. A secondary record for a read that maps in pieces (split-read or chimeric alignment), with the full read mapped at the primary position and supplementary records covering the other pieces; flag bit 2048 marks supplementary alignments. See also: BAM, FLAG.

**Support value** {#support-value}. A number annotated at an internal node of a phylogenetic tree giving the percentage of bootstrap or replicate trees that recovered that exact split; values above 95 indicate a well-supported clade and values below 70 should not be relied on. See also: IQ-TREE, phylogram.

**Surveillance series** {#surveillance-series}. A folder under a project's `Imports/NAO-MGS/` directory that gathers classification results from one wastewater site over time, identified by site and matrix and storing one Parquet file per sample keyed by collection date. See also: NAO-MGS, sample date.

## T

**Tabix** {#tabix}. A position-aware index for a bgzipped tab-delimited genomic file (typically `.vcf.gz` or `.bed.gz`), conventionally named with a `.tbi` suffix and kept beside the data file, that lets viewers and callers fetch records for a region without scanning the whole file. See also: VCF.

## V

**Variant-caller** {#variant-caller}. The program that compares aligned reads to a reference and emits a VCF describing positions where the sample differs. Lungfish ships three viral-focused callers: LoFreq for short-read viral data, iVar for primer-trimmed amplicon data, and Medaka for Oxford Nanopore data.

**VCF (Variant Call Format)** {#vcf}. A tab-separated file format that lists positions in a reference genome where a sample differs, with per-call confidence and metadata. See also: REF, ALT, genotype, allele frequency.
