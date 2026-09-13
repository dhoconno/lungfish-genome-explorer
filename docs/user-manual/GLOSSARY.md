# Glossary

**Ownership:** Bioinformatics Educator only.

Terms appear in alphabetical order. Each entry is a one-sentence definition, followed by an explicit anchor ID in `{#anchor-id}` form so chapters can deep-link from inline references and the in-app Help system can resolve term lookups directly to this page. Anchor IDs match the `glossary_refs:` slugs declared in chapter frontmatter.

## A

**Absolute path**{#absolute-path}. A file's full address written from the top of the disk down, beginning with a slash as in `/Users/you/Documents/reads.fastq`, so it names the same file whatever folder a command is run from, unlike a bare filename that only works in the folder holding it. See also working directory, PATH, shell.

**Accession**{#accession}. The permanent identifier a public sequence database assigns to one record, such as the RefSeqGene record `NG_000007.3`. The trailing number after the dot is a version that increments when a curator revises the deposited sequence, so a published coordinate should always name the version it was measured against. See also INSDC, reference genome.

**Adapter**{#adapter}. The short synthetic DNA sequence that library preparation attaches to each end of a fragment so the instrument can bind and read it, which appears at the end of a read whenever the fragment was shorter than the read length and the instrument read straight through it. See also library prep, FASTQ, fastp.

**Advisory lock**{#advisory-lock}. A claim one process takes on a file to tell other cooperating processes to wait, enforced only because every one of them checks it rather than by the operating system refusing access, which is how Lungfish Genome Explorer stops two installs from writing to one conda root at the same time. See also conda, plugin pack.

**AI assistant**{#ai-assistant}. The Inspector's Assistant tab, which answers questions about the active dataset through a bring-your-own-key AI provider. It interprets and explains, and it does not modify your project.

**Alias map**{#alias-map}. The internal table Lungfish consults during VCF import to recognise that two reference accessions (for example, the GenBank record `MN908947.3` and the RefSeq record `NC_045512.2`) name the same underlying sequence, so a VCF keyed against one resolves cleanly to a project bundle keyed against the other. See also VCF, reference bundle.

**Alias table**{#alias-table}. The fixed list built into Lungfish Genome Explorer that maps the many spellings one tool answers to, such as `bwa`, `bwa-mem`, and `bwa-mem2`, onto a single upstream citation, consulted by `provenance bibliography` when it turns a run's recorded steps into a reference list. See also citation, provenance sidecar, DOI.

**Alignment**{#alignment}. The mapping of one read against a reference genome, recorded as one row in a BAM file with a position, strand, CIGAR string, and quality scores. See also BAM, mapping.

**Alignment column**{#alignment-column}. One vertical slice through a multiple sequence alignment, holding one residue or one gap character from every row, taken to represent a single inferred homologous position across all the aligned sequences. See also MSA, gap, homologous.

**Alignment track**{#alignment-track}. One named BAM attached to a reference bundle and drawn as its own read stack and coverage curve in the alignment viewport, so a bundle can carry several alignments side by side, whether of different read sets or of one read set before and after trimming. See also BAM, reference bundle, mapping.

**Allele**{#allele}. One of the alternative sequences a locus can carry, and the unit an MHC genotyping run actually measures, distinct from a haplotype, which is a set of alleles across several linked loci. See also haplotype, MHC, locus, allele target.

**Allele depth**{#allele-depth}. The pair of read counts a caller writes in a VCF's per-sample `AD` field, giving the number of reads supporting the reference allele and the number supporting the alternate, so a value of `20,33` at a depth of 53 means a third more reads carried the change than carried the reference. Lungfish Genome Explorer derives a per-sample allele frequency from this pair whenever a filter asks for one, which is why a per-sample `AF` clause matches nothing on a caller that writes no `AD`. See also allele frequency, depth, FORMAT.

**Allele frequency**{#allele-frequency}. The proportion of sequencing reads at a position that carry the alternate base. A clinical isolate usually shows allele frequencies near 0 or 1. A mixed-population sample (for example, wastewater) shows a full spectrum.

**Allele target**{#allele-target}. One reference sequence in the allele library an MHC genotyping run matches reads against, named by its FASTA record name and forming one row of the genotype matrix, so a read either matches an allele target exactly over the sequenced stretch or contributes nothing to it. See also allele, genotype matrix, retained read.

**Allele-specific annotation**{#allele-specific-annotation}. A per-row VCF statistic that GATK computes separately for each alternate allele rather than pooling them, written with an `AS_` prefix such as `AS_QD`, so a position carrying two different alternate alleles gets one quality figure for each instead of one blended figure for both. Lungfish Genome Explorer always requests these in a joint-genotyping run. See also INFO, joint genotyping, GenotypeGVCFs.

**Alternate read**{#alternate-read}. One read carrying a base at some position other than the base the reference genome holds there, so the count of alternate reads divided by the total depth at that position is the allele frequency a variant caller reports. See also allele frequency, depth, REF, ALT.

**Alu element**{#alu-element}. The most abundant repeated sequence in the human genome, a roughly 300-base insertion present in about a million copies and making up over a tenth of the genome, so a shotgun library from human DNA carries recognisable Alu sequence in a small but steady percentage of its reads. See also sequence motif, shotgun sequencing.

**Amplicon**{#amplicon}. A target region of a genome amplified by PCR, used as the unit of an amplicon-based sequencing protocol such as ARTIC or QIASeqDIRECT. A run produces many overlapping amplicons that together tile the region of interest.

**Amplicon dropout**{#amplicon-dropout}. The failure of one amplicon in a tiled protocol to amplify, so no reads cover the stretch of genome it should have carried and a variant caller reports nothing there, which is indistinguishable from a genuinely unchanged region unless you read the per-amplicon coverage table. See also amplicon, coverage, mosdepth.

**Annotation track**{#annotation-track}. One named set of features stored together inside a reference bundle and drawn as a single layer in the annotation lane of the sequence viewport, carrying both a display name and a stable track ID, so a GenBank import creates one named Imported Annotations and a bundle can hold several tracks at once. See also reference bundle, GFF, sequence viewport.

**API access**{#api-access}. A stored key from an outside AI provider that lets Lungfish Genome Explorer send a question to that provider's service over the internet, which a few optional features require and which nothing in a genotyping run needs. See also AI assistant.

**API key**{#api-key}. The long secret string an outside service issues so it can tell which account a request belongs to and which account to bill for it, held by Lungfish Genome Explorer in the macOS Keychain rather than in a project folder. See also AI assistant, API access, Keychain.

**Argument**{#argument}. Any one of the words typed after a program's name at a command line, whether a flag, a value belonging to a flag, or a filename, and the whole run of them is that command's argument list. See also command-line flag, positional argument, argv.

**argv**{#argv}. The command you typed split into its separate words, recorded in a provenance sidecar as a list so the exact invocation can be read back without guessing where one argument ended and the next began. See also provenance sidecar, command-line flag, exit status.

**Assembler**{#assembler}. A program that reconstructs a genome from the overlaps between a sample's own reads, with no reference to guide it, emitting a set of contigs rather than a finished genome. See also de novo assembly, contig, assembly bundle.

**Assembly bundle**{#assembly-bundle}. A `.lungfishref` bundle that holds a de novo assembly produced inside the project, typically by SPAdes or MEGAHIT, and lives under the project's `Analyses/` folder alongside every other result. The internal structure is identical to a reference bundle, and only the folder placement distinguishes the two. See also reference bundle, bundle.

**Assembly graph**{#assembly-graph}. The structure an assembler builds before it emits any sequence, in which every stretch of sequence the reads agree on is a node and every observed overlap between two such stretches is an edge, so that emitting contigs amounts to walking the unambiguous paths through it and stopping wherever the graph branches. See also contig, de novo assembly, N50.

**Audit log**{#audit-log}. The record of analyst actions a genotype result keeps inside its `annotations.json` sidecar, written out as its own sheet in an exported workbook and as its own CSV in a LabKey export, so a reviewed result carries the trail of who changed what alongside the calls themselves. See also override, provenance, genotype result bundle.

## B

**BAI**{#bai}. The companion index file for a BAM that lets viewers jump to a specific reference position without reading the whole file. It is conventionally named `<sample>.bam.bai` and kept in the same folder as the BAM. See also BAM.

**BAM**{#bam}. The binary, indexed form of the SAM alignment format, with one row per aligned read and a header listing reference contigs. Lungfish always reads and writes BAMs rather than SAMs because of size and random-access requirements. See also BAI, alignment, CIGAR.

**BAQ**{#baq}. Base Alignment Quality, samtools' per-base recalibration that lowers the quality of bases sitting near indel-prone regions. It is useful for shotgun random-fragment data and counterproductive for amplicon data, which is why Lungfish disables BAQ (`-B`) for amplicon variant calling. See also pileup.

**Barcode**{#barcode}. A short oligonucleotide sequence (typically 8 to 24 bases) ligated onto a sample's reads during library prep so that pooled samples can be sorted back to their wells after multiplexed sequencing. ONT runs identify barcodes during basecalling and write one subfolder per barcode. See also basecaller.

**Barcode kit**{#barcode-kit}. The named set of barcode sequences a sequencing kit uses to tag samples, which Lungfish reads to demultiplex a run. See also barcode, demultiplex.

**Barcode scout**{#barcode-scout}. A command-line step that scans a subset of a read set against a barcode kit and reports how many reads hit each barcode, writing a `scout-result.json` that marks each barcode accepted, rejected, or undecided, so a wrong kit is caught before a full demultiplex is run. See also barcode kit, demultiplex.

**Basecaller**{#basecaller}. The program that converts a sequencer's raw signal into base-called reads with quality scores. For Oxford Nanopore data, Guppy and Dorado are the two basecallers in current use, and the model used to call a run sets which Medaka model is appropriate downstream. See also simplex read, duplex read.

**bbduk**{#bbduk}. A read-filtering and trimming program from the BBTools suite that matches a supplied sequence against reads as k-mers, used in Lungfish Genome Explorer for read-level primer trimming with a literal primer sequence and for contaminant filtering. See also k-mer, Hamming distance, primer trim.

**bbmerge**{#bbmerge}. The BBTools program that joins the two mates of a paired-end read into one longer fragment wherever they overlap, run automatically before mapping in an MHC genotyping workflow so that amplicons longer than a single mate can still be spanned end to end. See also read merging, paired-end, allele target.

**BCF**{#bcf}. The compact binary form of VCF, holding the same rows and header but packed for machines. Lungfish Genome Explorer reads an imported BCF with a CSI index beside it, but stores the variant tracks it writes as a bgzip-compressed VCF with a tabix index under the bundle's `variants/` folder, alongside a SQLite sidecar that indexes the same rows. See also VCF, CSI, tabix.

**bcftools**{#bcftools}. A command-line toolkit for reading and writing VCF and BCF files that also contains a variant caller, whose `mpileup` and `call` subcommands together model which genotype best explains the reads at each position, making it a reasonable general caller for a sample with a fixed small number of genome copies. It ships in Lungfish Genome Explorer's Required Setup pack rather than the Variant Calling pack, so it is available in every project. See also variant-caller, mpileup, VCF, genotype.

**BED**{#bed}. A plain-text table listing regions of a genome, one region per line, giving a contig name, a start coordinate, an end coordinate, and usually a name for the region. A primer scheme stores its primer positions as a BED file inside its `.lungfishprimers` bundle. See also primer scheme, contig.

**bedGraph**{#bedgraph}. A four-column plain-text coverage format giving a sequence name, a start, an end, and one numeric value for that interval, which Lungfish Genome Explorer both reads and writes, and which is the readable alternative when a BigWig cannot be opened. See also BED, BigWig, coverage.

**Benchmark VCF**{#benchmark-vcf}. A variant call set produced independently of the reads under study and treated as an answer key, such as the Genome in a Bottle small-variant benchmark for HG002 that this manual compares its own calls against. See also VCF, variant-caller.

**bgzip**{#bgzip}. A compression program from HTSlib that writes a gzip-compatible file in independently compressed blocks, so a reader with an index can jump straight to one region instead of decompressing everything before it, which is why a `.vcf.gz` inside a bundle is bgzipped rather than plain-gzipped. See also tabix, VCF.

**BigBed**{#bigbed}. A binary, indexed form of BED holding genomic intervals for fast region queries, which Lungfish Genome Explorer recognizes by its `.bb` or `.bigbed` extension but cannot open, since the format registry marks it detection only with no in-process reader. See also BED, BigWig, format registry.

**BigWig**{#bigwig}. A binary, indexed format holding one numeric value per genomic position, used for coverage and signal tracks, which Lungfish Genome Explorer recognizes by its `.bw` or `.bigwig` extension but cannot open, since the format registry marks it detection only with no in-process reader. Convert it to bedGraph outside the app if you need to see it. See also bedGraph, BigBed, format registry.

**BioSample**{#biosample}. An NCBI record describing one biological sample. Lungfish can export a BioSample submission TSV from a project's sample metadata. See also sample metadata.

**Bit score**{#bit-score}. The strength of a single sequence alignment expressed on a normalised scale that does not shift with the size of the database it was found in, so unlike an e-value it stays comparable between two searches run at different times or against different collections, and it rises with both the length and the quality of the match. See also BLAST, e-value, percent identity.

**BLAST (Basic Local Alignment Search Tool)**{#blast}. NCBI's nucleotide and protein sequence search service that ranks database entries by local-alignment score against a query, used in Lungfish to verify a classifier's hit by sending a representative read to NCBI's `nt` database. See also e-value, percent identity, query coverage.

**Boolean**{#boolean}. A value that is either true or false and nothing else, written in JSON as the bare words `true` and `false`, which is the shape of the role flags on a primer scheme's reference accessions. See also JSON, manifest.

**Bootstrap**{#bootstrap}. A way of measuring confidence in a phylogenetic grouping by rebuilding the tree many times from alignments resampled column by column and reporting, as a percentage, how often each grouping came back. IQ-TREE's ultrafast bootstrap is the fast approximation Lungfish Genome Explorer exposes. See also support value, IQ-TREE, SH-aLRT.

**BQSR (Base Quality Score Recalibration)**{#bqsr}. The GATK preprocessing step that corrects systematic errors in a sequencer's per-base quality scores by modelling them against a set of known-variant sites, run in Lungfish through `lungfish gatk bqsr` ahead of germline calling. See also VCF, HaplotypeCaller.

**Bracken**{#bracken}. A companion program to Kraken 2 that re-estimates how abundant each species really was, by redistributing the reads Kraken 2 parked at a broad rank down onto the species those reads most likely came from, using how much the database's reference genomes overlap one another. Lungfish Genome Explorer always runs it after a Kraken 2 classification started from the dialog, and its numbers appear as the taxonomy table's Bracken column. See also Kraken 2, read classification, clade count, taxon.

**Branch length**{#branch-length}. The number attached to one branch of a phylogenetic tree, in the default phylogram drawing the estimated substitutions per site accumulated along that branch, so a long branch means a lot of inferred change rather than a long span of time. See also phylogram, cladogram, topology.

**Bundle**{#bundle}. A folder that the macOS Finder shows as a single icon with an extension and that Lungfish treats as one logical object, with a manifest, primary data files, optional indexes and annotations, and a `provenance/` subfolder. Lungfish bundle types include `.lungfishref` for references and assemblies and `.lungfishprimers` for primer schemes. See also reference bundle, assembly bundle, primer scheme.

**Bundle migration**{#bundle-migration}. The process of bringing a bundle written by an older Lungfish Genome Explorer up to the current manifest layout, performed by `lungfish-cli project migrate`, which scans a project, leaves current bundles untouched, fills a missing browser summary in a reference manifest after backing the original up, and reports without rewriting any schema for which no safe transformer exists. See also bundle, manifest, schema version, provenance sidecar.

**Byte offset**{#byte-offset}. A count of characters from the very start of a file to a given point in it, so an offset of 19 means the point sits just after the nineteenth character, which is how a FASTA index records where each sequence begins. See also FAI, FASTA.

## C

**Cache**{#cache}. A copy of a folder a continuous integration service keeps between jobs so the next job can restore it instead of downloading everything again, which is how a job that provisions bioinformatics tools avoids repeating a long install on every run. See also continuous integration, offline pack, plugin pack.

**Call**{#call}. The identification a tool commits to after weighing the read evidence at one position or one locus, so an allele call names the allele the genotyping run believes the sample carries and a variant call names a position where the sample differs from the reference. A call is a best guess with evidence behind it rather than a measurement, which is why a genotype result offers a way to mark one reviewed or confirmed. See also allele, genotype, variant-caller.

**camelCase**{#camel-case}. A way of spelling a multi-word name by running the words together and capitalising each one after the first, as in `schemaVersion`, which is the convention the alignment and tree bundle manifests use. See also snake_case, manifest, JSON.

**Canonical accession**{#canonical-accession}. The accession a primer scheme's coordinates were written against, marked `canonical` in the bundle manifest and the name an alignment's contig must match, directly or through an equivalent accession, for a trim to find its primers. See also accession, equivalent accession, primer scheme.

**Capped database**{#capped-database}. A reference database deliberately shrunk to a target memory size by discarding most of its stored sequence fragments, so a machine too small to hold the full collection can still run the classifier against it. The cost falls on sensitivity, since a read the full collection would have named at species level is more often left unclassified or reported at a broader rank, and the loss is heaviest for whichever organism the sample is actually full of. See also Kraken 2, minimizer, read classification.

**cDNA**{#cdna}. A DNA copy made from a messenger RNA transcript, so it holds the joined coding stretches of a gene without the intervening non-coding stretches a genomic sequence carries, which makes a cDNA record of the same allele shorter than its genomic counterpart. See also CDS, allele target.

**CDS (coding sequence)**{#cds}. The portion of a gene that is translated into protein. Lungfish can annotate a best-match CDS on a sequence. See also open reading frame, reading frame.

**Checkout**{#checkout}. The step at the start of a continuous integration job that copies a repository's tracked files onto the runner, written on GitHub Actions as `uses: actions/checkout@v4` and on CircleCI as the bare step `checkout`, without which the job has no files to work on. See also repository, runner, continuous integration.

**Checksum**{#checksum}. A short fingerprint computed from a file's exact bytes, recorded by Lungfish as SHA-256 in every provenance record so two people can confirm they hold the identical file. See also provenance, reproducibility.

**Chimera**{#chimera}. An artificial sequence formed when two real templates join during PCR, so the result looks like a single genuine molecule while belonging to no organism, which is why a metabarcoding run checks its unmatched sequences for chimeras before anyone reports them as a new species. See also metabarcoding, vsearch, amplicon.

**Chord**{#chord}. A set of keys pressed together as one shortcut, such as Command and Shift and P, used interchangeably with combination in this manual. See also key equivalent, modifier key.

**CIGAR**{#cigar}. A compact string in each BAM row that describes, base by base, how the read aligns to the reference. It writes `M` for aligned positions, `I` and `D` for insertions and deletions, `S` for soft-clipped ends, and `H` for hard-clipped ends. See also BAM, soft-clip.

**Circular consensus sequencing (CCS)**{#circular-consensus-sequencing}. The PacBio protocol that circularises a DNA fragment, reads it repeatedly, and reports the consensus of those passes as one read, which is why HiFi reads carry both long lengths and Q30+ quality strings. A HiFi read's quality is a consensus confidence, not a raw signal measurement. See also read length, Phred score.

**Citation**{#citation}. The formal reference to the paper or project page that describes a bioinformatics tool, owed to that tool's authors whenever it contributed a number to a published result, and printed for one finished run by `lungfish-cli provenance bibliography`. See also DOI, alias table, provenance sidecar.

**Clade**{#clade}. A group on a phylogenetic tree consisting of one internal node and every tip descended from it. It is the unit a phylogeneticist points to when claiming "these isolates share a recent common ancestor". See also phylogram.

**Clade count**{#clade-count}. The number of reads a classifier assigned to one taxon together with every taxon beneath it in the hierarchy, reported as the Reads column of the taxonomy table and set against the Direct count, which holds only the reads assigned to that exact taxon and no lower. A family row with a large clade count and a Direct count of zero means every one of those reads was resolved to something more specific. See also taxon, taxonomic rank, kreport, Bracken.

**Cladogram**{#cladogram}. A phylogenetic tree drawn with every tip at the same depth so that only the branching order is shown and branch lengths carry no meaning. It is one of the two layouts the Lungfish Genome Explorer tree viewport offers, useful when one very long branch would otherwise squash the rest. See also phylogram, topology, clade.

**Clair3**{#clair3}. A deep-learning variant caller for Oxford Nanopore reads, run in Lungfish as an alternative to Medaka for ONT variant calling. It reads the sorted BAM directly and takes a model path matched to the basecaller. See also variant-caller, Medaka.

**Class I MHC**{#class-i-mhc}. The group of MHC genes whose proteins are carried on nearly every cell in the body and display fragments of the proteins that cell is making internally, which is how an infected or altered cell is recognized. In a macaque genotyping result these are the loci named MHC-A, MHC-B, and their relatives. See also MHC, class II MHC, locus.

**Class II MHC**{#class-ii-mhc}. The group of MHC genes whose proteins are carried on a smaller set of immune cells and display fragments the cell has taken in from outside it. In a macaque genotyping result these are the loci named MHC-DP, MHC-DQ, and MHC-DR and their subunits. See also MHC, class I MHC, locus.

**Classifier**{#classifier}. Software that decides which organism each read in a sequencing run came from, by comparing the read against a database of known genomes, so that a FASTQ of mixed reads becomes a list of the organisms present and how many reads support each. Kraken 2, EsViritu, TaxTriage, and NAO-MGS are the classifiers Lungfish Genome Explorer runs. See also read classification, taxon, Kraken 2.

**Clumpify**{#clumpify}. A program from the BBTools suite that reorders reads so that reads sharing sequence content sit next to each other, and that can collapse those matching reads into one, which is what backs the Remove Duplicates operation in Lungfish Genome Explorer. See also PCR duplicate, optical duplicate, read clumping.

**Clustering**{#clustering}. Grouping near-identical reads into representative consensus sequences before genotyping, used for full-length ONT MHC amplicons. See also pbAA, savONT.

**Codon**{#codon}. A run of three consecutive bases inside a protein-coding gene that together encode one amino acid. Three adjacent SNPs falling inside one codon describe one amino acid change, not three. iVar can group them into a single VCF row when given a GFF annotation. See also VCF.

**Cohort**{#cohort}. A set of samples genotyped and compared together, presented across the columns of the genotype comparison matrix. See also genotype matrix.

**CombineGVCFs**{#combinegvcfs}. The GATK tool that merges several per-sample GVCFs into one combined GVCF held in a single file, which Lungfish Genome Explorer chooses over GenomicsDB for cohorts of 50 samples or fewer because a single file is simpler to move and inspect at that scale. See also GVCF, GenomicsDB, joint genotyping, GenotypeGVCFs.

**Command-line flag**{#command-line-flag}. A named option typed after a command with two leading hyphens, such as `--to-format fasta`, which either carries a value after it or stands alone as a switch that is simply present or absent. See also positional argument, subcommand.

**Commit**{#commit}. One saved snapshot of a repository, identified by a forty-character string that names that snapshot and no other, which is why pinning a pipeline to a commit rather than to a release tag fixes exactly which code will run. See also repository, pinned, reproducibility.

**Conda**{#conda}. A package manager that handles compiled non-Python dependencies cleanly, used in Lungfish to install bioinformatics tools from the bioconda channel into per-tool environments under `~/.lungfish/conda`. See also micromamba, plugin pack.

**Consensus FASTA**{#consensus-fasta}. The reference sequence with high-confidence sample variants applied in place, where positions with insufficient evidence are masked as `N`. The format Pangolin and Nextclade expect for SARS-CoV-2 lineage assignment, and the format used for GISAID and NCBI surveillance submissions. See also VCF, allele frequency.

**Consensus sequence**{#consensus-sequence}. A single sequence built from a multiple sequence alignment by taking each column's most common residue, with columns whose rows disagree too weakly or are too heavily gapped written as a mask character instead of a base. See also MSA, alignment column, conservation.

**Consequence**{#consequence}. The predicted effect of one variant on the protein a gene encodes, written as a controlled term such as `missense_variant` for a change that swaps one amino acid or `synonymous_variant` for one that leaves the protein unchanged. Lungfish Genome Explorer shows it in the Variants tab's own `Consequence` column and in the Inspector, and it appears only where an annotation supplies it, since no caller writes it on its own. See also AA change, GFF, variant-caller.

**Conservation**{#conservation}. At one alignment column, the share of the non-gap rows that carry that column's most common residue, so a column where every row agrees scores 1 and a column split evenly between two residues scores 0.5. See also alignment column, MSA.

**Container**{#container}. A packaged copy of a program together with the libraries and files it needs to run, so the program behaves identically on every machine that runs the package, which is how a published pipeline guarantees that its results do not depend on whose computer produced them. See also Docker, Nextflow, plugin pack.

**Contig**{#contig}. A contiguous stretch of assembled sequence emitted by an assembler, representing the longest path through the assembly graph that the algorithm could resolve unambiguously. One assembly bundle holds many contigs, ranked by length in the assembly viewport. See also assembly bundle, N50.

**Contig (in a reference)**{#contig-reference}. One named sequence in a multi-record FASTA. In `.lungfishref` bundles the contig list comes from FASTA headers and matches the BAM, VCF, and GFF3 contig fields.

**Continuous integration**{#continuous-integration}. A service that runs a fixed set of commands on a freshly created machine each time a change reaches a shared repository, reports whether every command succeeded, and then discards the machine, so that nothing installed during one job survives into the next unless it is deliberately cached. See also offline pack, dependency set, provenance sidecar.

**Coordinate**{#coordinate}. A 1-based position on a reference, named as `chrom:position` (for example, `MN908947.3:21618`). Lungfish presents 1-based inclusive coordinates to the user everywhere. Underlying file formats may use 0-based half-open (BED) or 1-based inclusive (VCF, GFF3, SAM/BAM displayed). See also chromosome.

**Coverage**{#coverage}. The number of reads that align across a given reference position, used interchangeably with depth in this manual. See also pileup.

**Coverage breadth**{#coverage-breadth}. The fraction of reference positions covered by at least one read, reported per contig in a mapping run's `mapping-result.json` and distinct from depth, which counts how many reads sit over a position rather than whether any do. See also coverage, mapping.

**CRAM**{#cram}. A further-compressed alignment format that stores only how each read differs from the reference rather than the read's full sequence, so it needs that exact reference present to be read back. Lungfish Genome Explorer reads a CRAM and accepts one at `lungfish-cli import bam`, but writes its own alignments as BAM. See also BAM, SAM.

**CSI (coordinate-sorted index)**{#csi}. The alternative index format for a BAM, a BCF, or a compressed VCF whose reference sequence is longer than the 512-megabase limit a BAI index can address, serving the same purpose of letting a viewer jump straight to a chosen position. Lungfish Genome Explorer writes BAI for the BAMs it produces and reads a CSI that arrives beside an imported BAM. See also BAI, BAM.

**CSV (comma-separated values)**{#csv}. A plain text table whose columns are separated by commas, one row per line, with any field containing a comma wrapped in quotation marks, readable by every spreadsheet and by any analysis script without a special library. See also TSV, long format, XLSX.

**Ct (cycle threshold)**{#ct}. The qPCR cycle number at which a sample's amplification signal crosses the detection threshold. A lower Ct means more starting template, so for a viral diagnostic a low Ct predicts a higher viral fraction in the sequencing reads and a smaller host-removal rate.

**cutadapt**{#cutadapt}. A program that finds a short known sequence inside a read and either trims it away or uses it to sort the read, tolerating a set fraction of mismatched bases so it still matches when the sequencing was imperfect, and the default engine behind demultiplexing in Lungfish Genome Explorer. See also barcode, demultiplex, adapter.

**CZ-ID**{#cz-id}. A hosted metagenomics service used through a web browser, whose exported taxon report Lungfish Genome Explorer imports as a taxonomy result and stores as a `.lungfishtax` bundle under the project's `Classifications/` folder, since LGE reads a CZ-ID result but never runs one. See also read classification, Import Center, taxon.

## D

**dbSNP**{#dbsnp}. The NCBI catalogue of human genetic variants that have already been observed and named, distributed as a large VCF per reference build and used by GATK as a known-sites resource so that expected human variation is not mistaken for sequencing error. Lungfish Genome Explorer neither ships nor downloads it, so you fetch it yourself from the Broad Institute's public GATK resource bundle. See also known sites, BQSR, VCF.

**De Bruijn graph**{#de-bruijn-graph}. The particular kind of assembly graph that short-read assemblers such as SPAdes and MEGAHIT build, in which every k-mer taken from the reads is a point and two points are joined whenever one k-mer's tail overlaps the next one's head, so that a stretch the reads agree on forms an unbranching path and a sequencing error or a repeat forms a fork the assembler has to resolve before it can emit a contig. See also assembly graph, k-mer, contig, de novo assembly.

**De novo assembly**{#de-novo-assembly}. Reconstructing a sample's sequence from the overlaps between its own reads alone, with no reference genome used at any point, which is what lets an assembly report sequence that no database holds and what makes its output a set of contigs rather than a genome laid out in reference coordinates. See also assembly graph, contig, assembly bundle, mapping.

**Deacon**{#deacon}. A host-depletion program that matches a read's minimizers against a prebuilt index and drops the read when enough of them hit, used in Lungfish Genome Explorer for both human read removal and ribosomal RNA removal. See also host depletion, minimizer, ribosomal RNA.

**Deduplicated reference**{#deduplicated-reference}. A curated FASTA in which every record is one known marker sequence labelled with the species it belongs to and identical sequences have been collapsed to a single record, which is the reference form 12S amplicon matching requires so that one sequence shared by several species is recognised as shared rather than counted repeatedly. See also 12S, metabarcoding, FASTA.

**Demixing**{#demixing}. Solving for the blend of known viral lineages whose combined mutation profile best explains the allele frequencies measured in one sample, which is how Freyja reports several lineages with a proportion each instead of picking a single name. See also Freyja, lineage, lineage barcode, allele frequency.

**Demultiplex**{#demultiplex}. Separating a mixed sequencing run into per-sample read sets by their barcode. See also barcode, barcode kit.

**Dependency set**{#dependency-set}. The exact list of tool versions and builds one Lungfish Genome Explorer release was built and tested against, named by a version string such as `2026.2` and recorded both in the tool lock manifest and in every provenance record, so a run can be checked against the toolset it was meant to use. See also plugin pack, provenance sidecar, reproducibility.

**Depth**{#depth}. Synonym for coverage in this manual. The number of reads stacked at one reference position. See also coverage.

**Derived bundle**{#derived-bundle}. A reference bundle built from a selection taken out of something already in the project, most often a set of contigs picked from an assembly, which holds the selected sequences with a fresh FASTA index and carries a Derived Subset metadata block naming the assembler, the source, and the sequences that were chosen. See also reference bundle, assembly bundle, contig, provenance.

**Determinism**{#determinism}. The property of a command that running it again on the same inputs with the same settings produces the same output, which for a genomics tool usually holds at a fixed thread count and often stops holding when the thread count changes, so a claim of determinism in this manual means two runs were actually compared rather than that the tool is expected to behave. See also thread, reproducibility, provenance sidecar.

**Dialog**{#dialog}. The settings window Lungfish Genome Explorer opens before a run, holding the controls for one operation and a Run button, which is what a menu item ending in an ellipsis opens. See also Operations Panel, wizard.

**Directed acyclic graph**{#directed-acyclic-graph}. A set of boxes joined by one-way arrows in which no path of arrows ever leads back to the box it started from, which is the shape a Workflow Builder drawing must have so that the runner can always work out an order in which every step's input is ready before that step runs. See also node port, workflow bundle.

**Docker**{#docker}. The container software that nf-core pipelines run their tool steps inside, installed on a Mac as the separate Docker Desktop application rather than through the Lungfish Genome Explorer Plugin Manager, and the only execution profile the Viral Recon wizard will accept. See also container, nf-core, Nextflow.

**DOI**{#doi}. The digital object identifier of a published article, the permanent string beginning `10.` that a journal prints on the first page and that resolves at `https://doi.org/` even after the journal moves its website, which is why a bibliography cites it rather than a URL. See also citation, alias table.

**Download Center**{#download-center}. An older name for the Operations Panel that survives in some documentation and in the source as an alias. Downloads from NCBI and the SRA report as rows in the Operations Panel, which is the place to look when a download does not appear where you expected it. See also Operations Panel, SRA.

**Duplex read**{#duplex-read}. An Oxford Nanopore read produced by basecalling both strands of the same DNA molecule and reconciling them into a single high-accuracy consensus. Duplex Q30+ approximates Illumina-grade accuracy and is the basis for modern Medaka-duplex models. See also simplex read, basecaller.

**Duplicate rate**{#duplicate-rate}. The share of an alignment's records that duplicate marking flagged as copies of another record, read as a judgement on the library rather than on the sequencing, so a few percent on a PCR-free shotgun library is healthy while a fifth or more means the library was amplified from too few distinct starting molecules. See also PCR duplicate, mark duplicates, library prep.

## E

**Edit distance**{#edit-distance}. The number of single-base substitutions, insertions, and deletions separating an aligned read from the reference stretch it sits on, written into the read's optional `NM` tag by the mapper, so a read with `NM` of 0 matches the reference perfectly and is what the zero-mismatch alignment filter keeps. See also BAM, percent identity, alignment.

**EMBL (sequence format)**{#embl}. The European Nucleotide Archive's annotated flat-file sequence format, the counterpart to GenBank, which Lungfish Genome Explorer accepts at `lungfish-cli import fasta` and converts into a reference bundle on import. See also GenBank, ENA, reference bundle.

**ENA (European Nucleotide Archive)**{#ena}. The European mirror of the SRA, hosted at EMBL-EBI, and one of three INSDC partners (with NCBI SRA and DDBJ) that share deposited sequencing data. Lungfish downloads SRA runs from ENA first because ENA serves pre-converted FASTQs directly, and falls back to the NCBI SRA Toolkit when ENA is unavailable. See also SRA.

**Environment variable**{#environment-variable}. A named value the shell hands to every program it starts, used by Lungfish Genome Explorer to relocate managed storage with `LUNGFISH_STORAGE_ROOT` and `LUNGFISH_CONDA_ROOT`, which it reads together, and to supply an NCBI account key with `NCBI_API_KEY`. See also continuous integration, conda.

**Equivalent accession**{#equivalent-accession}. A second accession listed in a primer scheme manifest as naming the same sequence as the canonical one, so an alignment mapped to either identifier resolves against the same scheme. See also accession, canonical accession, alias map.

**Error correction**{#error-correction}. A stage some assemblers run before building their graph, in which reads are compared against each other and a base that only one read carries where its neighbours agree on another is rewritten, on the reasoning that a base seen once is more likely a sequencing mistake than a real difference. SPAdes runs it by default and the assembly sheet's Skip error correction toggle turns it off. See also de Bruijn graph, de novo assembly, read.

**EsViritu**{#esviritu}. A read classifier built around a curated collection of viral genomes, which reports not only how many reads matched each virus but how much of that virus's genome those reads covered, shipped in Lungfish Genome Explorer's `metagenomics` plugin pack and run from **Tools > Classification > EsViritu...**. See also read classification, coverage breadth, plugin pack.

**E-value**{#e-value}. The number of database alignments of equal or better score expected by chance for a given query length and database size. In BLAST results, smaller is better, with values at or below `1e-30` indicating an essentially unmistakable match for a typical viral read. See also BLAST, percent identity.

**Executable**{#executable}. The program file a tool actually runs as, named at the command line and recorded in a provenance sidecar, which often differs from the tool's display name, as IQ-TREE's `iqtree3` and Clair3's `run_clair3.sh` do. See also managed environment, provenance sidecar, PATH.

**Exit status**{#exit-status}. The number a command hands back to the shell when it finishes, where zero means it succeeded and any other value means it stopped for a reason the command defines, which is what a script tests to decide whether to carry on. See also command-line flag, subcommand.

**Exon**{#exon}. One of the stretches of a gene that survives splicing and contributes to the mature transcript, so a protein-coding sequence split across three exons is written in a GenBank record as a `join()` of three ranges. See also CDS, GFF.

**Extraction**{#extraction}. A bundle pulled out of a larger dataset by a Lungfish operation, either a chosen set of reads taken from a FASTQ or BAM or a chosen stretch of a reference sequence, written into the project's `Extractions/` folder with its own provenance sidecar. See also bundle, project, provenance sidecar.

## F

**FAI (FASTA index)**{#fai}. A small text index file (typically `<sequence>.fasta.fai`) produced by `samtools faidx` that lets tools jump to a specific position in a FASTA without reading the whole file. It is required for variant calling and many other reference-keyed operations. See also FASTA.

**Failure report**{#failure-report}. The block Lungfish Genome Explorer assembles the moment an operation fails, holding the operation title, the command that ran, the error message, the error detail, and the log, written to a file under `~/Library/Logs/` in a build-named folder beneath `Operations/Failures` and reachable from the failed row's right-click menu. See also Operations Panel, provenance sidecar, exit status.

**FASTA**{#fasta}. A plain-text format for nucleotide or protein sequences, with each record introduced by a `>` header line followed by sequence lines containing the bases. Lungfish accepts plain FASTA, multi-record FASTA, and bgzipped FASTA at every reference picker. See also FAI, FASTQ.

**fastp**{#fastp}. A fast read-preprocessing program that trims low-quality bases with a sliding window, detects and removes adapters, and trims a fixed number of bases from either read end, and that backs four of the six Trimming and Filtering operations in Lungfish Genome Explorer. See also adapter, sliding-window trimming, Phred score.

**FASTQ**{#fastq}. A plain-text format for sequencing reads, with each read taking exactly four lines. Those lines are a `@`-prefixed header, the read sequence, a `+` separator, and a same-length quality string in the standard ASCII offset 33 encoding. The input format for every workflow that starts from raw sequencing data. See also paired-end, Phred score.

**FILTER (in a VCF)**{#filter}. The seventh standard VCF column, holding `PASS` where the row cleared every filter the caller applied, a semicolon-separated list of the named filter flags it failed, or a bare `.` where no filter was applied at all. Flag names are caller-specific and are declared in the file's own header, so LoFreq writes names such as `min_dp_10` and `sb_fdr` while iVar writes `ft` and `bq`. See also VCF, INFO, FORMAT.

**Filter profile**{#filter-profile}. A named set of smart-filter tokens applied together to a variant track, either one of the four built into Lungfish (Clinical, Research, QC, High Confidence) or a combination the user assembles and saves per bundle. See also smart-filter token, VCF.

**Fixture**{#fixture}. An example data file that ships with this manual so a reader can follow a procedure against the same data it was written for, kept under `docs/user-manual/fixtures/` in the manual's repository. See also demo project.

**FLAG (in a BAM)**{#flag}. A bitwise integer field in each BAM row encoding facts about the read in twelve canonical bits. Those bits are paired, properly paired, unmapped, mate unmapped, reverse strand, mate reverse strand, first of pair, second of pair, secondary alignment, low quality, duplicate, and supplementary alignment. The decoded value `99` is the sum of bits 1+2+32+64. See also BAM, supplementary alignment.

**Flagstat**{#flagstat}. The per-category tally `samtools flagstat` produces by decoding the FLAG field of every record in a BAM, giving counts for total, primary, secondary, supplementary, mapped, properly paired, and singleton records, and shown in the alignment Inspector as a collapsed Flag Statistics list. See also FLAG, BAM, primary alignment.

**Fluidigm sample barcode**{#fluidigm-sample-barcode}. The sample-identifying sequence carried between the fixed CS1 and CS2 primer sequences in a library built with Fluidigm Access Array primers, which Lungfish Genome Explorer reads to split one bulk Oxford Nanopore bundle into per-sample bundles of the insert lying between those two primers. See also barcode, demultiplex, amplicon.

**FORMAT (in a VCF)**{#format}. The ninth VCF column, declaring a colon-separated list of keys that describe the per-sample payload columns following it, such as the `GT:PL:AD` that bcftools writes. The column is optional, and LoFreq output has no FORMAT and no sample column at all. See also VCF, INFO.

**Format registry**{#format-registry}. Lungfish Genome Explorer's internal catalog of the file formats it recognizes, holding for each one a display name, its filename extensions, whether the app can read it, whether the app can write it, and a category that decides where the format appears in a file picker. Two entries, BigWig and BigBed, are marked detection only, meaning the extension is recognized but no reader exists. See also BigWig, BigBed.

**Freyja**{#freyja}. A tool that estimates the relative abundance of each viral lineage in a mixed sample (typically wastewater) by demixing the sample's variant and depth profiles against known lineage definitions, run in Lungfish through `lungfish freyja demix`. See also lineage, consensus FASTA.

## G

**Gap**{#gap}. The `-` character an aligner writes into one row of a multiple sequence alignment at a column where that sequence has no residue, standing for an insertion in the other sequences or a deletion in this one, and letting rows of unequal length share a rectangular grid. See also alignment column, MSA.

**GC content**{#gc-content}. The percentage of bases in a sequence or a read set that are G or C rather than A or T, reported by Lungfish as one of the nine FASTQ summary cards, and a property of the source organism rather than of the sequencing run, so a figure far from the expected value usually means another species is present. See also read, quality control.

**GenBank (sequence format)**{#genbank}. NCBI's annotated flat-file sequence format, carrying the bases together with feature annotations and curator notes in one record, recognized by the extensions `.gb`, `.gbk`, `.genbank`, and `.gbff`. Lungfish Genome Explorer converts an imported GenBank record into a FASTA plus a GFF3 annotation track, keeping the original record in a database inside the bundle. See also FASTA, GFF, EMBL, reference bundle.

**Genetic code**{#genetic-code}. The mapping from codons to amino acids. Lungfish lets you pick the code (for example the vertebrate mitochondrial code) when translating a sequence. See also codon, reading frame.

**GenomicsDB**{#genomicsdb}. GATK's on-disk multi-sample variant store that scales joint genotyping to large cohorts better than a single combined GVCF. Lungfish builds one with `GenomicsDBImport` when a cohort exceeds 50 samples. See also GVCF, joint genotyping.

**Genotype**{#genotype}. A compact notation for which alleles are observed at a variant position, written diploid-style as `0/1` (heterozygous) or `1/1` (homozygous alternate), where `0` is the reference allele and `1` the first alternate. The Lungfish Genome Explorer iVar pipeline writes the bare haploid `1` instead, which is the honest notation for an organism carrying one genome copy. See also heterozygous, homozygous, FORMAT.

**Genotype matrix**{#genotype-matrix}. The Lungfish Genome Explorer result window that presents genotype calls as allele-target rows by sample columns, alongside a cohort summary and per-sample evidence, and it is not one of the five genomic viewport classes. See also allele target, cohort, retained read.

**Genotype quality**{#genotype-quality}. The confidence a variant caller reports in the genotype it chose at one position, written as the per-sample `GQ` field on a Phred scale where 20 means a one in a hundred chance the chosen genotype is wrong and 99 is the usual ceiling, so it answers a different question from QUAL, which asks only whether any variant exists there. See also genotype, FORMAT, Phred score.

**Genotype result bundle**{#genotype-result-bundle}. The folder an MHC genotyping run writes, carrying the `.lungfishgenotype` extension and holding the per-sample and per-allele read counts as CSV tables, an Excel workbook of the same figures, the run statistics, a sorted and indexed BAM of just the retained reads, and a provenance record of exactly how it was made. See also retained read, genotype matrix, provenance.

**GenotypeGVCFs**{#genotypegvcfs}. The GATK tool that turns combined per-sample GVCF evidence into finished genotype calls, deciding at each position which alleles each sample carries and how confident that call is, and the second and final step of every joint-genotyping run Lungfish Genome Explorer builds. See also GVCF, joint genotyping, CombineGVCFs, GenomicsDB.

**Germline variant**{#germline}. A difference from the reference genome that a person inherited from their parents and therefore carries in every cell of their body, as opposed to a somatic variant that arose in one tissue during their lifetime, which is why a germline caller may assume every position carries the same fixed number of genome copies. See also variant-caller, ploidy, genotype.

**GFA (Graphical Fragment Assembly)**{#gfa}. A tab-separated text format for assembly graphs in which each `S` line carries one sequence segment and each `L` line records an overlap between two segments, so a GFA holds the branching structure an assembler resolved rather than only the sequences it emitted. hifiasm writes its assembly as GFA rather than FASTA, and Lungfish Genome Explorer converts the primary contig graph to FASTA before the assembly viewport can list it. See also assembly graph, contig, unitig.

**GFF (General Feature Format)**{#gff}. A tab-separated table format for genomic features (genes, CDS, mature peptides, regulatory elements). GFF3 is the current spec. Lungfish accepts GFF3 paired with a FASTA at bundle creation. See also FASTA, reference bundle.

**Glob**{#glob}. A file-name pattern in which `*` stands for any run of characters, so a step that searches for `*.lungfish-provenance.json` matches every file whose name ends that way, used by continuous integration steps that collect artifacts. See also continuous integration, provenance sidecar.

**Grounded answer**{#grounded-answer}. A reply from the AI assistant that rests on a lookup the assistant actually ran against your loaded data, so it names your bundle, your organism, and your coordinates, as opposed to one written from the model's general reading with nothing from your project in it. The status line naming a lookup while the assistant works is the first sign that a reply is grounded. See also AI assistant, bundle.

**GTF (gene transfer format)**{#gtf}. An older relative of GFF3 that uses the same nine tab-separated columns with a different attribute syntax, which Lungfish Genome Explorer reads and converts on import. The format registry marks GTF read only, since the app never writes one back out. See also GFF, format registry.

**GVCF (genomic VCF)**{#gvcf}. A VCF variant that records, at every position rather than only at variant sites, the confidence that the sample matches the reference, so per-sample GVCFs can later be combined and genotyped together. It is the form GATK HaplotypeCaller emits by default in Lungfish. See also VCF, joint genotyping, GenomicsDB.

## H

**Half-open**{#half-open}. A way of writing an interval in which the end number names the first position left out rather than the last position included, so a BED row reading 27 and 51 covers 24 bases and subtracting the two numbers gives the length directly. See also zero-based, BED, coordinate.

**Hamming distance**{#hamming-distance}. The number of positions at which two sequences of the same length differ, used by bbduk as the mismatch tolerance when deciding whether a stretch of a read matches a supplied primer or contaminant sequence. See also bbduk, k-mer, primer trim.

**Haplogroup**{#haplogroup}. A branch of the human maternal family tree, defined by the set of mitochondrial positions its members share and named with a letter and digits such as H or U5b, so a mitochondrial call set that recovers a coherent haplogroup marker set is evidence the calling worked. See also mitochondrial genome, SNV.

**Haplotype**{#haplotype}. A set of alleles across linked loci that are inherited together as one block, because the loci sit close enough on a chromosome that they rarely separate. A genotyping run observes alleles rather than haplotypes, so a haplotype call is an interpretation built on top of the allele calls. See also allele, MHC, locus.

**Hard filter**{#hard-filter}. A fixed list of arithmetic tests applied to statistics a variant caller already wrote into each VCF row, with no training step and no model, so a row failing any test is labelled in its FILTER column rather than removed. GATK publishes a recommended list for human germline work and Lungfish Genome Explorer ships it as the default preset of `lungfish-cli gatk filter`. See also FILTER, quality by depth, strand odds ratio, VCF.

**Heterozygous**{#heterozygous}. Carrying two different alleles at one position, one on each copy of a chromosome, written `0/1` in a VCF genotype field. See also homozygous, genotype.

**HG002**{#hg002}. A human DNA sample from the Genome in a Bottle project whose true sequence is known to high confidence, distributed openly and used throughout this manual as the human example, so a result computed from it can be checked against a published answer. See also reference genome, benchmark.

**Home folder**{#home-folder}. The folder on a Mac named after your account, holding your Documents, Downloads, and Desktop, written as `~` at a command line, so a path beginning `~/.lungfish` names a hidden folder inside it. See also PATH, conda, managed environment.

**Homologous**{#homologous}. Descended from the same position in a shared ancestral sequence, which is what a column of a multiple sequence alignment claims about the residues stacked in it, and which is an inference from similarity rather than something the data states directly. See also alignment column, MSA.

**Homopolymer**{#homopolymer}. A run of the same base repeated, such as `AAAAAA`, which nanopore basecalling resolves poorly because the electrical signal barely changes as each identical base passes through the pore, making homopolymer length the single largest source of insertion and deletion errors in Oxford Nanopore reads. See also basecaller, indel, Medaka.

**Homozygous**{#homozygous}. Carrying the same allele on both copies of a chromosome at one position, written `0/0` for the reference allele and `1/1` for the alternate. See also heterozygous, genotype.

## I

**Host depletion**{#host-depletion}. The removal of reads that came from the organism the sample was taken from rather than from the organism being studied, done before analysis both to save work on reads no one will look at and to keep a patient's own genome out of a shared dataset. See also Deacon, decontamination.

**Host name**{#host-name}. The name a Mac answers to on the network, recorded in a project lock so a reader can tell which computer took it, and printed in the read-only banner and in the lock error messages. It is not stable, because the name changes when the network changes, which is why Lungfish Genome Explorer compares an opaque machine identifier first and falls back to the host name only for older records that lack one. See also project lock, process id, project.

**Immunogenetics**{#immunogenetics}. The study of genetic variation in immune-system loci such as the MHC, and the domain of Lungfish's amplicon genotyping feature. See also MHC.

**Import Center**{#import-center}. The tabbed import window opened with **File > Import Center...** (`Cmd-Shift-I`), holding one tab per data kind (Sequencing Reads, Alignments, Variants, Classification Results, Reference Sequences, Application Exports) and one card per import inside each tab, every card a drop target. See also reference bundle, provenance.

**Indel**{#indel}. A variant that inserts bases the reference lacks or deletes bases the reference has, rather than substituting one base for another, written in a VCF as a REF and ALT of different lengths. Indels are harder to call than substitutions because reads spanning one can often be aligned in more than one equally good way, and some callers report none at all by default. See also SNV, REF and ALT, variant-caller.

**INFO (in a VCF)**{#info}. The eighth standard VCF column, holding semicolon-separated `KEY=VALUE` pairs of per-row metadata such as depth (`DP`), allele frequency (`AF`), strand bias (`SB`), and per-allele depths (`AD`). See also VCF, FILTER, FORMAT.

**INSDC (International Nucleotide Sequence Database Collaboration)**{#insdc}. The three-way partnership of NCBI (USA), EMBL-EBI (Europe), and DDBJ (Japan) that mirrors deposited nucleotide sequences and assigns a single globally-unique accession to each record. ENA, NCBI SRA, and DDBJ Sequence Read Archive are the SRA tier of this partnership. See also ENA, SRA.

**Insert size**{#insert-size}. The length of the original DNA fragment that a paired-end read pair came from, measured end to end including both reads. When the insert is shorter than twice the read length the two mates overlap and can be merged. See also paired-end, read length.

**Inspector**{#inspector}. The right-hand pane of a Lungfish project window that shows context-sensitive metadata and analysis actions for whatever is selected in the sidebar or main viewport. Toggle with `Cmd-Opt-I`. See also sidebar, project.

**Interleaved FASTQ**{#interleaved-fastq}. A single FASTQ file holding a paired-end run with the two mates of each fragment written as consecutive records, forward then reverse, rather than split across an R1 and an R2 file. Lungfish stores a paired-end sample inside its bundle as one interleaved file, and offers Interleave and Deinterleave as explicit operations on files outside a bundle. See also paired-end, FASTQ.

**Internal node**{#internal-node}. Any point on a phylogenetic tree where branches meet, standing for an inferred common ancestor that was never sequenced and no longer exists. A tree of five tips can hold at most three of them. See also tip, clade, topology.

**Interval list**{#interval-list}. A file naming the stretches of a reference genome a GATK command should restrict itself to, written either as a BED table of contig, start, and end, as a Picard-style `.interval_list`, or as a bare contig name, and passed to Lungfish Genome Explorer's GATK commands with `--intervals` so both steps of a joint-genotyping run read the same restricted region. See also BED, contig, joint genotyping.

**IPD-MHC**{#ipd-mhc}. The Immuno Polymorphism Database's MHC section, the reference catalogue of named MHC alleles for non-human species, whose FASTA record names an MHC genotyping run copies through unchanged into its calls, and whose group records fold together alleles that cannot be told apart over the stretch a short amplicon sequences. See also allele target, MHC, allele.

**IQ-TREE**{#iqtree}. A maximum-likelihood phylogenetic inference program with a built-in ModelFinder step and ultrafast bootstrap support estimation, used by Lungfish to produce `.lungfishtree` bundles from MSA bundles. See also MSA, phylogram, support value.

**IUPAC ambiguity code**{#iupac-ambiguity-code}. A single letter standing for two or more possible bases at one position, defined by the International Union of Pure and Applied Chemistry so that uncertainty can be written inside a sequence rather than alongside it. `R` means A or G, `Y` means C or T, `M` means A or C, `K` means G or T, `S` means C or G, `W` means A or T, and `N` means any base at all. See also consensus sequence, consensus FASTA, pileup.

**iVar**{#ivar}. A toolkit written for amplicon sequencing data that soft-clips primer bases out of an aligned BAM using a primer scheme's BED coordinates and can then call variants from the trimmed result, shipped inside Lungfish Genome Explorer's Variant Calling pack. See also primer trim, primer scheme, soft-clip, variant-caller.

## J

**Joint genotyping**{#joint-genotyping}. The GATK step that calls genotypes across a whole cohort at once by combining per-sample GVCFs and running `GenotypeGVCFs`, rather than genotyping each sample in isolation, run in Lungfish through `lungfish gatk joint-genotype`. See also GVCF, GenomicsDB.

**JSON (JavaScript Object Notation)**{#json}. A plain text data format that stores named fields and lists in a shape a program reads directly, used across Lungfish Genome Explorer for provenance sidecars, annotation files, and the summaries every command-line exporter prints. See also provenance sidecar, annotation.

## K

**Key equivalent**{#key-equivalent}. The single letter, digit, or symbol at the end of a macOS keyboard shortcut, held to the modifier keys that come before it, which is the term Apple's own frameworks use for the value a menu item stores and the term the Lungfish Genome Explorer source uses when it defines one. See also modifier key.

**Keychain**{#keychain}. The macOS system store for passwords and other secrets, unlocked by your login, which is where Lungfish Genome Explorer writes an AI provider's API key so that the key survives a restart without ever entering a `.lungfish` project folder. See also API key, AI assistant.

**Kilobase**{#kilobase}. A thousand bases of sequence, written kb, the unit amplicon lengths are usually quoted in once they pass a few hundred bases. See also amplicon, read length.

**k-mer**{#k-mer}. A substring of exactly k bases taken from a longer sequence, the unit several tools match on because comparing short fixed-length words is far faster than comparing whole sequences. bbduk spots a primer in a read by looking for the primer's k-mers. See also bbduk, minimizer, Hamming distance.

**Known sites**{#known-sites}. A catalogue of reference positions where human variation is already documented, supplied to GATK as one or more indexed VCF files so that steps such as BQSR can set those positions aside before treating any remaining mismatch as a sequencing error. The standard resources are dbSNP and the curated Mills indel set, and Lungfish Genome Explorer's `gatk bqsr` accepts them through a repeatable `--known-sites` option. See also dbSNP, BQSR, VCF.

**Kraken 2**{#kraken2}. A read classifier that assigns each read to a taxon by matching the read's minimizers against a database of reference genomes, chosen for breadth rather than depth and run in Lungfish Genome Explorer from **Tools > Classification > Kraken2...**, usually with Bracken estimating abundances from its assignments afterwards. See also read classification, minimizer, lowest common ancestor, taxon.

**Kreport**{#kreport}. The summary file Kraken 2 writes beside its per-read output, holding one row per taxon with the percentage of reads under it, its clade count, its direct count, a one-letter rank code, its numeric taxonomy identifier, and its name indented by depth. LGE always asks Kraken 2 for minimizer data, so its kreports carry eight columns, with two minimizer counts inserted after the direct count and the taxonomy identifier in the seventh column. It is the file the taxonomy viewport reads, and the file `lungfish-cli import kraken2` takes when you bring in a classification produced elsewhere. See also Kraken 2, clade count, taxon, taxonomic rank.

## L

**L50**{#l50}. A summary statistic for a set of assembled contigs, giving the smallest number of contigs whose lengths together reach half of the assembly's total bases, so that an L50 of 1 means one contig holds half the assembly and a large L50 describes a fragmented one. It counts contigs where N50 measures a length, and the two move in opposite directions as an assembly improves. See also N50, contig, assembly bundle.

**LabKey**{#labkey}. A laboratory data management platform. Lungfish can export genotype results as LabKey-ready CSV files.

**Left alignment**{#left-alignment}. The convention of writing an insertion or deletion at the leftmost position that describes the same change, so that one biological indel inside a repeated stretch, which could equally be written at several positions, always appears at the same coordinate whichever caller produced it. Lungfish Genome Explorer applies it with `lungfish-cli gatk leftalign`. See also indel, normalization, VCF.

**Lens**{#lens}. One of the alternative views a Lungfish Genome Explorer result window offers over the same underlying data, chosen from a control at the top of the window, so that the genotype viewport's Review lens presents one sample at a time for checking while its comparison lens shows every sample at once as a grid. See also viewport, genotype.

**Library layout**{#library-layout}. The archive field recording whether a sequencing run read each fragment from one end or from both, reported as SINGLE or PAIRED, which is how an SRA search can be restricted to runs whose reads come in mate pairs. See also paired-end, single-end, SRA.

**Library prep**{#library-prep}. The bench procedure that turns extracted nucleic acid into a form a sequencing instrument can read, and the step that decides whether reads land at random positions (shotgun), at designed primer coordinates (amplicon), or on probe-selected regions (target enrichment). See also amplicon, shotgun, target enrichment.

**Library strategy**{#library-strategy}. The archive field recording what a sequencing library was built to do, with values such as WGS for whole-genome shotgun, AMPLICON for targeted PCR product, WXS for whole-exome capture, and RNA-Seq for transcript sequencing. See also amplicon, shotgun, SRA.

**Lineage**{#lineage}. A named subgroup within a viral species, defined by a characteristic set of variants and assigned by a domain-specific tool (Pangolin for SARS-CoV-2, Nextclade for many viruses). LGE assigns lineages only through the Viral Recon pipeline, which runs Pangolin and Nextclade on the consensus it builds. Its other consensus paths produce FASTAs that downstream tools call lineages from. See also consensus FASTA.

**Lineage barcode**{#lineage-barcode}. The table Freyja consults during demixing, recording which mutations define each named viral lineage, installed as a dated snapshot alongside the tool so that lineages named after that date cannot be reported until the snapshot is refreshed. See also Freyja, demixing, lineage.

**Linkage**{#linkage}. Whether two changes sit on the same physical DNA molecule and so travel together, which read-level data can only show when one read spans both, so a caller that reports two changes at nearby positions is usually saying nothing at all about whether they are linked. See also phase, haplotype, phase set.

**Local reassembly**{#local-reassembly}. The strategy a variant caller such as GATK HaplotypeCaller uses in stretches where the reads look unsettled, discarding the original alignment across that stretch, rebuilding the candidate sequences from the reads themselves, and rescoring every read against those candidates, which mainly repays its cost around indels because an aligner placing one read at a time often puts the same insertion in slightly different spots on different reads. See also variant-caller, indel, alignment.

**Locus**{#locus}. The place on a chromosome where one particular gene sits, so that the alternative sequences a population carries at that place are its alleles. MHC genotyping reports one group of calls per locus, and which loci appear depends on the allele library a run used. See also allele, MHC, allele target.

**LoFreq**{#lofreq}. A variant caller that builds an error model from the base and mapping qualities of the reads and reports a position when the alternate reads are more numerous than that error model alone would produce, which lets it find variants present in a small fraction of the reads without assuming any fixed number of genome copies. Its default output carries no genotype or sample column and reports no indels unless indel calling is switched on. See also variant-caller, allele frequency, INFO.

**Long format**{#long-format}. A table shape in which each row records one single fact, such as one sample's read count for one allele target, rather than one row per sample with a column per allele, which makes the table taller and narrower and is the shape a database loads most easily. See also CSV, LabKey, pivot workbook.

**Lowest common ancestor**{#lowest-common-ancestor}. The most specific taxon that every organism matching a read belongs to, which a classifier reports instead of guessing when a read's sequence fits several relatives equally well, so a read shared across a whole genus is labelled with the genus rather than with one of its species. See also taxon, taxonomic rank, read classification.

## M

**MAFFT**{#mafft}. A multiple sequence alignment program that auto-selects an algorithm by input size and is the default aligner Lungfish runs when producing a `.lungfishmsa` bundle. See also MSA.

**Managed environment**{#managed-environment}. The private folder conda builds for one tool under `~/.lungfish/conda`, holding that tool and the libraries it depends on, so two tools needing different versions of the same library never collide, with the Plugin Manager's Installed tab listing one row per managed environment. See also conda, plugin pack.

**Manifest**{#manifest}. The small structured text file at the top of a Lungfish Genome Explorer bundle that names what the bundle holds, so a primer scheme's `manifest.json` names the protocol, the reference accessions its coordinates were written against, and the primer and amplicon counts, and a program reads it instead of guessing from the folder's contents. See also bundle, primer scheme, JSON.

**Mapper**{#mapper}. A program that places sequencing reads onto a reference genome and emits an alignment file (BAM). Lungfish ships minimap2, BWA-MEM2, Bowtie2, and BBMap. See also alignment, mapping.

**Mapping**{#mapping}. The act of finding, for each read, the reference position where it best fits and recording the alignment in a BAM. See also alignment, mapper.

**Mapping preset**{#mapping-preset}. A named bundle of mapper settings tuned for one kind of input, chosen alongside the mapper itself, where minimap2 offers `sr` for short reads, `map-ont`, `map-hifi`, and `map-pb` for long reads, `asm5` for assembled contigs, and `splice` for spliced alignment, while BBMap offers a standard and a PacBio mode. See also mapper, mapping.

**Mapping quality**{#mapping-quality}. The aligner's confidence that it placed a read at the right position, which is a judgement about the whole read and is separate from the per-base Phred score describing how well each base was read. It is recorded per read in a BAM as MAPQ. See also MAPQ, Phred score, mapper.

**MAPQ (mapping quality)**{#mapq}. A per-read confidence score in each BAM row, encoding how unambiguously the mapper placed the read at the recorded position. A value of 0 means no confidence (the read fits multiple places equally well), 60 is the maximum for most mappers and means the placement is well above the second-best alternative. See also BAM, mapper.

**Mark duplicates**{#mark-duplicates}. The step that finds BAM rows sharing a start and end position, which are usually PCR copies of one original fragment, and flags the extras so a variant caller counts them once, run in Lungfish as `samtools markdup` through `lungfish-cli bam markdup`. The step is inappropriate for amplicon data, where every fragment is designed to start at the same place. See also BAM, FLAG.

**Materialization**{#materialization}. The step that rebuilds a virtual bundle's full read file from its stored manifest, run automatically as the first stage of any operation that needs the actual reads and cleared away when that operation ends, or performed deliberately with `lungfish-cli fastq materialize` when a program outside Lungfish Genome Explorer needs a plain FASTQ. See also virtual bundle, bundle.

**Maximum likelihood**{#maximum-likelihood}. The method IQ-TREE uses to choose a phylogenetic tree, which scores every candidate tree by how probable it makes the observed alignment columns under an assumed substitution model and keeps the highest-scoring one. See also IQ-TREE, substitution model, topology.

**MCM (Mauritian cynomolgus macaque)**{#mcm}. A macaque population descended from a small founding group, which left it carrying only a handful of MHC haplotypes where other macaque populations carry many, making it the standard dataset for teaching and testing haplotype assignment. See also haplotype, MHC, immunogenetics.

**Medaka**{#medaka}. Oxford Nanopore's own variant caller and consensus tool, which scores reads against a neural-network model named for the pore chemistry and basecaller version that produced them, run in Lungfish Genome Explorer from the Call Variants dialog against a FASTQ rebuilt from the chosen alignment rather than against the BAM. See also Clair3, basecaller, variant-caller.

**Metabarcoding**{#metabarcoding}. Identifying which species are present in a mixed sample by matching a short marker amplicon (such as 12S) against a reference of known sequences. See also 12S.

**Metadata**{#metadata}. The descriptive fields recorded about a data item rather than the sequence data itself, such as when a sample was collected, which instrument read it, and which reference it was mapped against, held in a bundle's manifest and shown in the Document Inspector. See also bundle, sample metadata, manifest.

**Metagenomics**{#metagenomics}. The study of all the nucleic acid present in a mixed sample at once, rather than of one cultured organism, which is the setting read classification was built for and the reason its tools ask for large reference databases and a great deal of memory. See also read classification, metabarcoding, shotgun.

**Methods export**{#methods-export}. The Lungfish provenance export that emits a short Markdown document with a Methods heading, a Computational Analysis section naming each successful step's tool and resolved version in the order they ran, a tool versions table, an input file list with checksums, and a reproducibility paragraph, written as a draft to edit before it goes into a paper. See also provenance sidecar.

**MHC (Major Histocompatibility Complex)**{#mhc}. The gene-dense immune region whose proteins hold up fragments of what is inside a cell for the immune system to inspect, the most variable region of a vertebrate genome, and the target of the amplicon genotyping workflows in this manual. See also haplotype, immunogenetics, class I MHC, class II MHC.

**Micromamba**{#micromamba}. A small standalone bootstrap that speaks the conda protocol without requiring a full Anaconda installation, used by Lungfish as the engine for plugin pack installs. See also conda, plugin pack.

**miniBAM**{#minibam}. A compact read-pileup panel drawn inside a result's detail pane, showing the reads that landed on one reference accession without opening the full alignment viewport, used in Lungfish Genome Explorer to put the read evidence for one taxon beside the number that summarises it. See also BAM, pileup, coverage.

**minimap2**{#minimap2}. A general-purpose read mapper that finds, for each read, the reference position where it fits best, used inside Lungfish Genome Explorer both as a mapper you run directly and as the alignment step hidden inside EsViritu's viral detection. See also mapping, alignment, BAM.

**Minimizer**{#minimizer}. The smallest k-mer within a sliding window of a sequence, picked as a compact fingerprint so a tool can match reads quickly without comparing every base. Kraken 2 classifies on minimizers and Deacon counts minimizer hits to flag host reads. See also Kraken 2, Deacon.

**MinKNOW**{#minknow}. The control software that runs an Oxford Nanopore sequencer, calls bases as the run proceeds, and writes the reads out as numbered FASTQ chunks under a `fastq_pass` folder, placing each barcode's reads in its own subfolder when the library was barcoded. See also basecaller, barcode, unclassified reads.

**MiSeq**{#miseq}. A benchtop Illumina sequencing instrument that reads each DNA fragment from both ends at up to about 250 bases per end, the usual platform for a short-amplicon MHC genotyping panel, and the reason such a run merges its read pairs before mapping so that amplicons longer than one read can still be spanned end to end. See also paired-end, read merging, amplicon.

**Mitochondrial genome**{#mitochondrial-genome}. The small circular DNA molecule carried inside the mitochondrion, the compartment that supplies a cell's chemical energy, separate from the nuclear chromosomes and present in many copies per cell, the human one being the 16,569-base record `NC_012920.1` known as the revised Cambridge Reference Sequence. See also reference genome, accession.

**Modifier key**{#modifier-key}. A key that changes what another keypress means while it is held down, which on macOS means Command, Option (labelled Alt on some keyboards), Shift, and Control, and which Lungfish Genome Explorer combines with a key equivalent to form every keyboard shortcut it defines. See also key equivalent.

**mosdepth**{#mosdepth}. A fast coverage-depth calculator that reports how many reads sit over each position of a genome, run inside the nf-core/viralrecon pipeline to produce both a whole-genome depth table and a per-amplicon one, the second of which is what reveals amplicon dropout. See also coverage, depth, amplicon dropout.

**mpileup**{#mpileup}. The samtools and bcftools subcommand that walks a reference position by position and reports, for each one, the stack of read bases covering it together with their qualities, which is the raw summary a variant caller then judges. Its flags change what the caller sees, so the depth cap and base-quality floor a pileup is built with are part of why two callers on one alignment disagree. See also pileup, bcftools, variant-caller.

**MSA (Multiple Sequence Alignment)**{#msa}. A rectangular arrangement of two or more related sequences in which each column represents an inferred homologous position, with `-` gap characters padding insertions. Lungfish stores one as a `.lungfishmsa` bundle. See also MAFFT.

**Multi-allelic**{#multi-allelic}. Describing one VCF row that lists more than one alternative to the reference base at the same position, written with the alternates separated by a comma in the ALT column, as in an ALT of `G,AGG`. Some tools read only the first alternate of such a row, which is why `lungfish-cli gatk leftalign --split-multi-allelics` exists to break one into a row per allele. See also VCF, REF and ALT, left alignment.

**MultiQC**{#multiqc}. A reporting tool that gathers the quality output of every step of a pipeline run into one browsable HTML page, so a reader checks a whole run in one place instead of opening a report per tool, and the nf-core/viralrecon run writes one that Lungfish Genome Explorer catalogues as Full Run Report. See also nf-core, FastQC.

## N

**N50**{#n50}. A summary statistic for a set of assembled contigs, giving the length such that contigs of at least that length together hold half of the assembly's total bases. A higher N50 means a less fragmented assembly. See also contig, assembly bundle.

**Nanopore sequencing**{#nanopore-sequencing}. The Oxford Nanopore method that reads a DNA strand by drawing it through a protein pore and measuring how the ionic current changes as each stretch of bases passes through, which puts no ceiling on read length and yields reads tens of thousands of bases long, at the cost of a per-base error rate far higher than a short-read instrument's. Flye and hifiasm both accept these reads, and Flye accepts nothing else. See also basecaller, read length, circular consensus sequencing.

**NAO-MGS**{#nao-mgs}. A wastewater metagenomic surveillance pipeline from SecureBio that runs externally and whose `virus_hits_final.tsv(.gz)` output Lungfish imports (it does not run the pipeline) through `lungfish nao-mgs import` or the Import Center, presenting one run's viral taxa in a sortable table with a taxon detail pane and BLAST verification workflow. See also BLAST.

**NCBI (National Center for Biotechnology Information)**{#ncbi}. The American public repository for sequence data, which issues the accessions Lungfish Genome Explorer matches primer schemes against and serves the reference sequences a scheme's provenance record checksums. See also accession, RefSeq, SRA.

**Negative control**{#negative-control}. A sample carrying no template on purpose, prepared and sequenced alongside the real specimens so that any organism appearing in it must have come from the reagents, the laboratory, or the sequencing run rather than from a specimen, which is what makes it the reference point for judging contamination across a batch. See also TaxTriage, read classification, samplesheet.

**Newick**{#newick}. A compact parenthesised text format for phylogenetic trees, with branch lengths after colons and optional support values at internal nodes. It is the common format for moving trees between FigTree, iTOL, ete3, and Lungfish. See also phylogram.

**Nextflow**{#nextflow}. A language and runner for describing an analysis as a set of steps and the files that flow between them, which then executes those steps in the right order and inside containers, shipped with the Required Setup pack and used by Lungfish Genome Explorer to run the nf-core/viralrecon pipeline. See also nf-core, container, run bundle.

**nf-core**{#nf-core}. A community that curates, versions, and tests openly published Nextflow pipelines to a common standard, so a pipeline named by release runs the same steps for everyone who runs that release, and Lungfish Genome Explorer supports one of them, nf-core/viralrecon, pinned at release 3.0.0. See also Nextflow, container.

**Node port**{#node-port}. A labelled connection point on the edge of a Workflow Builder node, carrying a direction and a data type, so that LGE accepts a connection only between two ports whose types match and refuses one that would join, for example, a reads port to an alignments port. See also directed acyclic graph, workflow bundle.

**Novel variant**{#novel-variant}. A call absent from the catalogue of variation it was compared against, reported by Picard's metrics step as `NOVEL_SNPS` and `NOVEL_INDELS`, and worth reading with suspicion rather than excitement because in a well-studied human sample most genuine variation is already catalogued. See also dbSNP, transition to transversion ratio, VCF.

**nt database**{#nt-database}. NCBI's general nucleotide collection, holding the sequence records deposited with the public archives across every organism rather than a curated selection, which makes it much broader than the database any read classifier installs locally and is why Lungfish Genome Explorer searches it rather than a smaller one when verifying a classification. Every BLAST verification uses it, and neither the popover nor the command line offers a way to search a different database. See also BLAST, accession, RefSeq.

**NVD (Novel Virus Diagnostics)**{#nvd}. An external Snakemake wastewater-surveillance pipeline that assembles reads into contigs and BLASTs each contig, whose `*_blast_concatenated.csv(.gz)` output Lungfish imports (it does not run the pipeline) through `lungfish nvd import` or the Import Center and presents as a contig-keyed browser of best and secondary BLAST hits. See also contig, BLAST.

## O

**OCI layout**{#oci-layout}. The Open Container Initiative's standard directory shape for a container image, holding an `oci-layout` file, an `index.json`, and a set of content-addressed blobs, which `lungfish-cli bundle export` writes as a deterministic tarball so a reference bundle can travel as one verifiable artifact. See also reference bundle, checksum, provenance.

**Offline pack**{#offline-pack}. A directory holding a copy of one plugin pack's already-installed conda environments together with a manifest and its own provenance record, written by `lungfish conda offline-export` so the tools can be moved to a machine with no network access and installed there with `lungfish conda offline-install`. See also plugin pack, conda, continuous integration.

**ONT (Oxford Nanopore Technologies)**{#ont}. The maker of the long-read sequencers whose runs LGE's amplicon genotyping and nanopore chapters work with, which read a DNA strand by pulling it through a pore and measuring the current that passes. See also nanopore sequencing, read length, MinKNOW.

**Open reading frame**{#open-reading-frame}. A stretch of codons from a start to a stop with no internal stop, a candidate protein-coding region Lungfish can auto-detect. See also reading frame, CDS.

**Operations Panel**{#operations-panel}. A separate Lungfish window that lists every long-running operation of the current session with its state, elapsed time, command line, and log, and that offers Clear Completed and a per-row context menu. Open it with **Operations > Show Operations Panel** (`Cmd-Shift-P`). The durable audit trail lives in the provenance sidecars rather than in the panel. See also provenance, project.

**Optical duplicate**{#optical-duplicate}. A read counted twice because one cluster on the flowcell was read as two neighbouring clusters during imaging, rather than because the fragment was copied during amplification, which is why it is recognised by how close two clusters sit rather than by sequence alone. See also PCR duplicate, clumpify.

**ORF (open reading frame)**{#orf}. A stretch of sequence running from a start codon to an in-frame stop codon without interruption, so it could in principle encode a protein. Lungfish finds ORFs and stores them as an annotation track, but ORF length is only a weak proxy for a real gene. See also codon.

**Orient Reads**{#orient-reads}. A Lungfish operation that aligns ONT reads against a reference and flips reverse-strand reads so every read in the bundle ends up in the same orientation, useful for amplicon protocols and consensus building. See also basecaller, simplex read.

**Outgroup**{#outgroup}. A sequence included in a phylogenetic analysis because you are confident it falls outside the group under study, used to place the root so the rest of the tree can be read as a sequence of descent. See also rooting, topology, clade.

**Override**{#override}. A genotype call an analyst replaced by hand in the result window, stored in the result's annotation sidecar alongside the original call, the reason, and the author, so an exported workbook or LabKey file reports the reviewed call while still carrying the pipeline's own. See also audit log, genotype matrix, genotype result bundle.

## P

**Paired-end**{#paired-end}. A sequencing protocol that reads each DNA fragment from both ends, producing two reads per fragment. The two halves of a pair travel as separate FASTQ files with `_1`/`_2` or `_R1`/`_R2` suffixes. See also FASTQ, single-end.

**Pangenome**{#pangenome}. All the reference sequences a tool's database holds, treated as one combined mapping target rather than as separate genomes, which is how EsViritu compares reads against its whole viral collection in a single pass. See also reference genome, mapping, EsViritu.

**PATH**{#path}. The list of folders a shell searches, in order, when you type a program's name without a folder, so a program installed outside those folders can only be run by typing its full path. Lungfish Genome Explorer releases add nothing to it, which is why `lungfish-cli` must be called by its full path in a script. See also shell, command-line flag, continuous integration.

**Pathoplexus**{#pathoplexus}. An open pathogen-genome database Lungfish can search and import reference sequences from.

**pbAA**{#pbaa}. A read-clustering tool that derives high-accuracy amplicon consensus sequences, one of the clustering options for full-length ONT MHC genotyping. See also clustering, savONT.

**PCR (Polymerase Chain Reaction)**{#pcr}. The laboratory reaction that makes millions of copies of one chosen stretch of DNA, using a pair of primers to mark where copying starts and stops, which is what produces the amplicons an amplicon sequencing run reads. See also amplicon, primer, PCR duplicate.

**PCR duplicate**{#pcr-duplicate}. A read that is a copy of another read because both came from the same original DNA fragment amplified during library preparation, so the two carry one observation between them rather than two. Amplicon protocols produce identical read starts by design, so duplicates there are expected rather than artifacts. See also optical duplicate, mark duplicates, clumpify.

**p-distance**{#p-distance}. The simplest genetic distance between two aligned sequences, the proportion of positions at which they differ, with no model correction. One of the distance models Lungfish's `msa distance` can compute. See also MSA.

**Percent identity**{#percent-identity}. In a BLAST or other pairwise alignment, the fraction of aligned positions where the query and the subject sequence agree, calculated only over the aligned region. Read it together with query coverage to gauge how much of the read aligned and how well. See also BLAST, query coverage.

**PHA4GE**{#pha4ge}. The Public Health Alliance for Genomic Epidemiology, whose sample-description specification fixes the field names LGE writes into a bundle's `metadata.csv`, settling what the columns are called without restricting what a user types into them. See also sample metadata, BioSample.

**Phase (in GFF3)**{#phase}. The eighth column of a GFF3 feature line, saying which base of a codon the feature begins on as 0, 1, or 2, and written as a dot on every row where the question does not apply, which is most of them. See also GFF, reading frame, CDS.

**Phase set**{#phase-set}. A stretch of a chromosome within which a phasing tool worked out which copy each variant sits on and is internally consistent, identified by the per-sample `PS` field that every variant in the set shares, so two variants carrying different `PS` values tell you nothing about each other even though both are phased. See also read-backed phasing, haplotype, FORMAT.

**PhiX**{#phix}. The small bacteriophage genome Illumina spikes into a sequencing run as a control, which is never part of the sample's biology and so is a standard thing to filter out, and which Lungfish Genome Explorer ships as the default reference for contaminant filtering. See also bbduk, decontamination.

**Phred score**{#phred-score}. A logarithmic per-base quality value defined as `Q = -10 * log10(P)` where P is the error probability. Q20 = 1% error, Q30 = 0.1% error, Q40 = 0.01% error. Encoded in FASTQ files as ASCII characters offset by 33 (so `!` = Q0, `F` = Q37). See also FASTQ.

**Phylogram**{#phylogram}. A phylogenetic tree drawn so that branch length is proportional to the inferred amount of evolutionary change (substitutions per site). It is the default tree-viewport layout in Lungfish. See also clade, IQ-TREE.

**Picard**{#picard}. A collection of tools for manipulating high-throughput sequencing files that is bundled inside GATK4 rather than installed separately, so its commands such as `CreateSequenceDictionary`, `MarkDuplicates`, and `CollectVariantCallingMetrics` are invoked through the `gatk` binary. Picard commands spell their options in capitals with double dashes, which is why a GATK command line can mix `-R` and `--SEQUENCE_DICTIONARY` styles. See also sequence dictionary, mark duplicates.

**Pileup**{#pileup}. The column of bases observed at one reference position across every read that covers it, together with their qualities and strands. It is the unit of evidence a variant caller weighs at each position. See also coverage, variant-caller.

**Pinned**{#pinned}. Locked to one exact version rather than left to take whatever the latest release happens to be, which is what Lungfish Genome Explorer does for every managed tool, every plugin pack tool, every external pipeline, and every reference database except the NCBI taxonomy. See also dependency set, tool lock manifest, reproducibility.

**Pipeline**{#pipeline}. One analysis run as a chain of steps that hand their output to each other, so that starting a mapping run in Lungfish Genome Explorer produces a single Operations Panel row covering the index, the alignment, the sort, and the index of the result. See also Operations Panel, workflow, provenance.

**Pivot workbook**{#pivot-workbook}. A workbook with samples across columns and allele targets down rows. All genotype Excel entry points now write one layout with All and Filtered matrices, optional real Haplotype Calls, and Export Metadata. These are literal report cells, not Excel pivot tables. See also XLSX, genotype matrix, long format.

**Plate map**{#plate-map}. The grid of sample positions that came off one sequencing run, named for the physical multi-well plate the samples were prepared in, and the layout a genotype result window uses so that a row of the screen matches a row of the bench plate. Referred to as a plate throughout the genotyping chapters. See also genotype, sample metadata.

**Ploidy**{#ploidy}. The number of copies of each chromosome an organism carries, which is two for a human and one for a virus or a bacterium, and which decides what genotypes a caller is allowed to propose at a position. A caller assuming two copies will force a viral sample into `0/1` and `1/1` genotypes that mean nothing, which is why a haploid genome is usually called with an explicit ploidy setting. See also genotype, heterozygous, variant-caller.

**Plugin pack**{#plugin-pack}. A themed group of related bioinformatics tools that Lungfish installs on demand into per-tool conda environments, named for the workflow it supports (for example, `read-mapping`, `variant-calling`, `assembly`). See also conda, micromamba.

**Positional argument**{#positional-argument}. A value typed at a fixed place in a command with no name in front of it, so its meaning comes from where it sits rather than from a label, which is how most commands take their input file. See also command-line flag, subcommand.

**Post-install hook**{#post-install-hook}. A follow-up command a plugin pack declares for itself and Lungfish runs after the pack's tools are installed, such as downloading the lineage data a surveillance tool needs, with the count of hooks shown on the pack's card in the Plugin Manager. See also plugin pack.

**Preprint**{#preprint}. An article posted to a public server such as bioRxiv before it has been through peer review, which is a legitimate citation for a tool whose paper never reached a journal, though some journals restrict how a preprint may be cited. See also citation, DOI.

**Primary alignment**{#primary-alignment}. The one record a mapper designates as a read's real placement, so counting primary alignments counts reads rather than records and gives a total that matches the input FASTQ even when the mapper also emitted secondary or supplementary rows for the same reads. See also secondary alignment, supplementary alignment, flagstat.

**Primer**{#primer}. A short oligonucleotide, typically 18 to 30 bases, that binds a specific position on a target genome and primes DNA synthesis from that position. It is the building block of every amplicon protocol. See also amplicon, primer scheme.

**Primer pool**{#primer-pool}. The numbered PCR reaction one primer belongs to, recorded in column 5 of a primer scheme's BED file, which a tiling design alternates between 1 and 2 so that overlapping neighbouring amplicons are amplified in separate tubes and cannot compete for the same template. See also primer scheme, tiling, amplicon.

**Primer scheme**{#primer-scheme}. The set of primer coordinate pairs that define an amplicon protocol, listing where each forward and reverse primer binds on the reference. In Lungfish, a primer scheme is packaged as a `.lungfishprimers` bundle that carries the BED coordinates, a manifest naming the protocol and the reference accessions it was designed against, an optional FASTA of the primer sequences, and provenance. See also primer, BED, primer trim.

**Primer trim**{#primer-trim}. The step that removes primer-derived bases from the ends of aligned reads in amplicon data, so those bases do not contaminate variant calls. In Lungfish the trim runs as a BAM-level operation using `ivar trim` against a selected primer scheme. See also amplicon, primer scheme.

**Process**{#process}. One running copy of a program, which macOS starts, gives a number to, and ends when the program quits, so one application opened twice is two processes and a command-line tool that finishes is a process that no longer exists. See also process id, project lock, shell.

**Process id**{#process-id}. The number macOS gives one running process, written `pid` in a project lock record and in Lungfish Genome Explorer's lock messages, which identifies that one run rather than the program in general. Typing the number into Activity Monitor's search field is how a reader checks whether the process is still running. See also process, project lock, stale lock.

**Project**{#project}. A `.lungfish` directory bundle that holds every input, output, bundle, and provenance record for one Lungfish analysis, with a top-level layout of `Imports/`, `Downloads/`, `Reference Sequences/`, `Primer Schemes/`, `Extractions/`, `Haplotype Definitions/`, and `Analyses/`, plus a hidden `.project.db` catalog and a `metadata.json`. Only the app creates the project store, so a folder built by `lungfish-cli` alone opens read only. See also bundle, sidebar, project lock.

**Project lock**{#project-lock}. The record Lungfish writes inside a project bundle naming the user, host, process, app version, and time of whoever currently holds it, so the app and the CLI can coordinate access to a project on shared storage. A lock left behind by a crashed process is called stale and is cleared through an explicit recovery that archives the old record. See also project.

**Project store**{#project-store}. The hidden `.project.db` index Lungfish Genome Explorer keeps inside a project folder listing everything the project holds, which only the app creates. A folder built by `lungfish-cli` alone has none, so the app opens it read only with no lock banner, which is what tells that case apart from a locked project. See also project, project lock, bundle.

**Properly paired**{#properly-paired}. The state of a paired-end read whose mate was placed on the same reference sequence at the separation and orientation the library preparation implies, marked by FLAG bit 2 and counted as its own row in a flagstat report, so a fraction well below the mapped fraction points at a library or reference problem rather than at poor sequencing. See also FLAG, paired-end, flagstat.

**Provenance**{#provenance}. The record Lungfish keeps alongside every download and every operation describing where a file came from or how it was produced, including source URL or accession, exact tool version, full command line, input checksums, and output checksums. See also Operations Panel.

**Provenance sidecar**{#provenance-sidecar}. The JSON file Lungfish writes alongside every output (or into a bundle's `provenance/` subdirectory), recording the workflow name, resolved command, input and output checksums, runtime identity, and per-step exit status for one operation. See also provenance, methods export.

**Provider fallback**{#provider-fallback}. The rule by which Lungfish Genome Explorer tries the next configured AI provider when the one before it cannot answer, working through your chosen default first and then Anthropic, OpenAI, and Google Gemini with the default removed. A provider with an empty key field is skipped before any request is made, and a question that fails partway may already have reached one company before the next receives it. See also AI assistant, API key.

**Push**{#push}. Sending saved changes from your own copy of a repository up to the shared copy everyone works from, which is the event a continuous integration service watches for when it decides to start a job. See also repository, continuous integration, runner.

## Q

**Quality binning**{#quality-binning}. The lossy compression step that rounds each base's Phred score to one of a small set of values before the reads are stored, offered by Lungfish at import as Illumina 4-level, 8-level, or None. Illumina instruments from the NovaSeq onward already report binned scores in hardware, so binning such a run discards little that was not already lost. See also Phred score, FASTQ.

**Quality by depth**{#quality-by-depth}. A VCF statistic written as `QD`, giving a row's quality score divided by the depth of reads supporting the variant, so it measures confidence per read rather than in total and stops a deep position from accumulating a high score out of many individually unconvincing reads. GATK's recommended hard filter marks a row whose `QD` falls below 2. See also hard filter, INFO, depth.

**Quality control**{#quality-control}. The step of judging whether a set of reads is fit to analyse before anything is computed from it, which in Lungfish has no separate screen and is read instead from the nine summary cards and three sparkline charts the FASTQ viewport shows for every read bundle. See also Phred score, sparkline, GC content.

**Query coverage**{#query-coverage}. In a BLAST result, the fraction of the query sequence that participated in the alignment to the subject. A high percent identity over only a fraction of the read is much weaker evidence than a moderate identity over most of the read. See also BLAST, percent identity.

## R

**Read**{#read}. One fragment of DNA reported by a sequencing instrument, stored as a string of bases beside an equal-length string of per-base quality scores, and written as one four-line record in a FASTQ file. See also FASTQ, read length, Phred score.

**Read classification**{#read-classification}. Assigning each read in a sequencing run to the organism it most likely came from, by comparing the read against a reference database of known genomes, which turns a FASTQ into a census of the taxa present and the share of reads at each one. See also taxon, taxonomic rank, lowest common ancestor, metagenomics.

**Read clumping**{#read-clumping}. The reordering of a read file so that reads sharing sequence content sit next to each other, which lets a general-purpose compressor find far more repetition and shrink the stored file. Lungfish applies it at import as the "Optimize storage" option, using BBTools clumpify or Trim Galore, and the reordering means the stored bundle no longer matches the source file's read order. See also FASTQ.

**Read group**{#read-group}. A labelled block written into a BAM header as an `@RG` line, naming the identifier, sample, library, sequencing platform, and platform unit a set of reads came from, which Lungfish Genome Explorer fills in for every mapping run so that tools grouping reads by sample, such as joint variant callers, can do so. See also BAM, mapping.

**Read identifier**{#read-identifier}. The name a sequencer gives one read, written on the FASTQ record's first line after the `@` character and running up to the first space, which for an Illumina run encodes the instrument, run, flowcell, lane, tile, and position of the cluster that produced it. See also FASTQ, read length.

**Read length**{#read-length}. The number of bases in a sequencing read. Illumina reads are typically 75-300 bp (fixed per run), Oxford Nanopore reads range from 1 kb to 100 kb (variable per run with mean 5-15 kb), PacBio HiFi reads are 10-25 kb. See also FASTQ.

**Read merging**{#read-merging}. Joining the two mates of a paired-end read into one longer sequence, possible only when the DNA fragment was shorter than the two reads combined so that the mates overlap in the middle, where the doubly measured bases also let the merger correct disagreements between the two reads. See also paired-end, insert size, interleaved FASTQ.

**Read orientation**{#read-orientation}. Which of the two DNA strands a read was sequenced from, since a fragment can be read from either end and the two forms carry the same information written backwards and complemented. Tools that compare a read to a reference by exact containment, such as 12S amplicon matching, see only the form they are given, so reads are turned to a common orientation with `lungfish-cli fastq orient` before matching. See also reverse complement, strand, 12S.

**Read-backed phasing**{#read-backed-phasing}. Working out which copy of a chromosome each allele of a heterozygous variant sits on by finding single reads or read pairs that span two nearby variants at once, since a read comes from one physical DNA molecule and so reports the two alleles it covers as travelling together. Phased genotypes are written with an upright bar, as `0|1` rather than `0/1`. See also phase set, haplotype, genotype.

**Reading frame**{#reading-frame}. One of the three ways to divide a nucleotide sequence into codons on a given strand, selected when translating a sequence to protein. See also genetic code, codon.

**Reads per billion**{#reads-per-billion}. An abundance figure, abbreviated RPB and reported per contig by the NVD viewport, calculated as the reads mapping to that contig divided by the sample's total read count and multiplied by a billion, so that contigs from libraries sequenced to different depths can be compared on one scale. See also NVD, contig, read.

**Reads per million**{#reads-per-million}. An abundance figure, abbreviated RPM and reported per taxon by CZ-ID and by the taxon reports Lungfish Genome Explorer imports from it, calculated as the reads assigned to that taxon divided by the sample's total read count and multiplied by a million, so that taxa from libraries sequenced to different depths can be compared on one scale. See also CZ-ID, reads per billion, taxon, read.

**Recalibration table**{#recalibration-table}. The plain-text report GATK's `BaseRecalibrator` writes describing how far each reported base quality score sits from the error rate actually observed, broken down by read group, original score, sequence context, and cycle position, which the following `ApplyBQSR` step then reads to rewrite the quality scores in the BAM. Its first block lists every argument the run used, making it the quickest way to confirm which known-sites files were read. See also BQSR, known sites, Phred score.

**REF, ALT**{#ref-alt}. REF is the base or bases present in the reference genome at a variant position. ALT is the base or bases observed in the sample. A one-base REF and one-base ALT describe a SNP. A longer REF or ALT describes an insertion or a deletion.

**Reference bundle**{#reference-bundle}. A `.lungfishref` bundle stored under a project's `Reference Sequences/` folder, containing a primary FASTA, an index, optional annotations such as GFF3 or GTF, any tracks attached to that reference (alignments, variants, classifications), and a manifest. See also bundle, assembly bundle.

**Reference genome**{#reference-genome}. A specific, community-agreed sequence used as the comparison point for samples. For SARS-CoV-2 the standard reference is `MN908947.3` (the Wuhan-Hu-1 isolate). Variants are described relative to a chosen reference, so reference choice affects which variants are reported and at what positions. See also reference bundle.

**Reference manager**{#reference-manager}. A program such as Zotero, EndNote, or Paperpile that stores references and formats them into a journal's required style, which takes a software citation typed in by hand because the bibliography command prints plain text rather than an importable file. See also citation, DOI.

**RefSeq**{#refseq}. The curated subset of NCBI's sequence records, holding one reviewed, non-redundant record per sequence rather than every entry submitters deposited, recognisable by accession prefixes such as `NC_`, `NG_`, and `NM_` for records and `GCF_` for assemblies. See also accession, INSDC, RefSeqGene.

**RefSeqGene**{#refseqgene}. An NCBI RefSeq record covering one gene or gene cluster as a curated slice of a chromosome, given its own coordinate system starting at 1 and its own accession (for example `NG_000007.3` for the human beta-globin cluster), so gene-focused work does not have to carry whole-chromosome coordinates. See also accession, reference genome.

**Regular expression**{#regular-expression}. A compact pattern language for describing text to search for rather than spelling out the exact text, where writing a plain word already means "contains this anywhere" and square brackets such as `[GA]` mean "any one of these characters here". See also read identifier, sequence motif.

**Repeat masking**{#repeat-masking}. Marking the stretches of a genome that a repeat-finding program judged repetitive, written in a FASTA as lowercase bases, which carry the same meaning as their uppercase equivalents and need no action from a reader. See also FASTA, Alu element.

**Report slot**{#report-slot}. One of the two allele positions a genotype report gives each locus, written `H1` and `H2` in an exported matrix, which hold the two alleles a diploid animal can carry at that locus. See also locus, allele, genotype matrix.

**Repository**{#repository}. The folder of files a version-control system tracks, holding the project's code together with the history of every change made to it, and the unit a continuous integration service checks out onto a runner. See also push, checkout, continuous integration.

**Representative reads**{#representative-read}. The sample of reads (default 20, up to 50 from the popover) that Lungfish automatically selects from a taxon's assigned reads and submits to NCBI BLAST during verification, drawn as some of the longest reads plus a random fill so the sample is neither one unrepresentative corner of the data nor picked one read at a time by the user, except in the NAO-MGS viewport, which instead spreads its picks across quarters of the reference genome. See also BLAST, nt database.

**Reproducibility**{#reproducibility}. The property that a workflow re-run with the same inputs, the same plugin pack version, and the same Lungfish build produces output that matches the original by checksum (bit-identical) or by content (logically equivalent). The provenance sidecar carries every field needed to verify this. See also provenance sidecar.

**Required Setup pack**{#required-setup-pack}. The one plugin pack Lungfish installs as a unit and cannot run without, shown in the Plugin Manager as Third-Party Tools, holding the seventeen everyday utilities the rest of the app assumes are present, among them samtools, bcftools, htslib, fastp, Deacon, seqkit, BBTools, Nextflow, and Snakemake. See also plugin pack, managed environment.

**Residual**{#residual}. The leftover disagreement between the mutation profile a fitted answer predicts and the profile actually measured in the data, reported by Freyja on the `resid` line of a demix result, where smaller means the lineage mixture explains the sample better and the figure is most useful compared across samples processed the same way. See also demixing, Freyja.

**Retained read**{#retained-read}. In an MHC genotyping run, a read whose alignment spanned an allele target from its first base to its last with no substitutions, indels aside, and which therefore counts towards that allele target's support. Reads failing any part of that test are discarded rather than counted weakly, so the retained fraction of a run is far smaller than a mapping workflow would report. See also allele target, genotype matrix, bbmerge.

**Reverse complement**{#reverse-complement}. The sequence read from the opposite DNA strand, obtained by reading the bases backwards and swapping each for its pairing partner (A for T, C for G), so reading frames -1, -2, and -3 are the three frames counted along it and Lungfish runs the transformation from **Sequence > Reverse Complement...**. See also strand, reading frame.

**Ribosomal RNA (rRNA)**{#ribosomal-rna}. The structural RNA of the ribosome, which is by far the most abundant RNA in a cell, so an RNA sequencing library that was not depleted of it returns mostly ribosomal reads and very little of whatever else was in the sample. See also Deacon, decontamination.

**RID (Request ID)**{#rid}. The identifier NCBI assigns to one BLAST submission the moment it accepts the job, such as `9WZYE9M0014`, which both Lungfish Genome Explorer and NCBI's own site use to collect the result later, so a run that times out locally is still recoverable from the browser link built around its RID. See also BLAST, nt database.

**Rooting**{#rooting}. Choosing which point on a phylogenetic tree stands for the oldest ancestor, which is what turns a statement about who groups with whom into a statement about which lineage came first. IQ-TREE produces unrooted trees, so rooting in Lungfish Genome Explorer is the separate **Re-root Here** step. See also outgroup, topology, internal node.

**RPKMF**{#rpkmf}. Reads per kilobase of reference per million filtered reads, the abundance figure EsViritu reports for each detected virus, which divides out both the length of the reference genome and the size of the sequencing library so that a long virus and a short one, or a deep run and a shallow one, can be compared against each other. See also EsViritu, coverage, read.

**Run accession**{#run-accession}. The identifier naming one pass of one sequencing library through one instrument in a public read archive, written `SRR`, `ERR`, or `DRR` followed by digits according to which INSDC partner took the deposit, and the only accession level that resolves directly to FASTQ files. See also accession, SRA, INSDC.

**Run bundle**{#run-bundle}. A `.lungfishrun` folder Lungfish Genome Explorer writes before it launches a workflow, recording the pipeline name, the requested release, the executor, the inputs, every parameter, and the outputs that must receive provenance, so the run can be described or repeated without being rerun first. See also Nextflow, provenance, run record.

**Run record**{#run-record}. The provenance a single Lungfish operation left behind, read in the Inspector's Provenance section as seven blocks (Run Summary, Warnings, Lineage, Files & Outputs, Invocation & Options, Runtime, and Raw JSON) and stored on disk as one provenance sidecar. See also provenance sidecar, workflow lineage.

**Runner**{#runner}. The machine a continuous integration service creates to run one job, rented from the service rather than owned by you, chosen by a label such as `macos-26` on GitHub Actions or by an image name on other services, and discarded when the job finishes. See also continuous integration, checkout, cache.

## S

**SAM (Sequence Alignment Map)**{#sam}. The plain-text alignment format holding one row per aligned read, of which BAM is the compressed binary equivalent. Lungfish Genome Explorer reads and writes SAM, but its mapping pipeline never leaves one behind, sorting and indexing every alignment into a BAM and deleting the intermediate text file. See also BAM, CRAM, BAI.

**Sample metadata**{#sample-metadata}. Structured per-sample fields (collection date, source, and so on) imported from a CSV or TSV sheet and attached to samples in a project. See also BioSample.

**Sample sheet**{#sample-sheet}. A CSV listing one sequencing sample per row with the sample's name and the paths to its read files, used at import to pair reads and name bundles explicitly instead of matching mate suffixes in filenames. Lungfish requires the columns `sample`, `r1`, and `r2`, and carries any further columns through as per-sample metadata. See also sample metadata, paired-end.

**Samplesheet**{#samplesheet}. The CSV a Nextflow pipeline reads to learn which samples to run, written as one header line and one line per sample carrying the sample name, the path to each read file, and the sequencing platform, which is how a headless TaxTriage run declares more than one sample at a time and which Lungfish Genome Explorer writes into every TaxTriage result folder. See also TaxTriage, Nextflow, sample sheet.

**samtools**{#samtools}. The standard toolkit for reading and writing alignment files, whose subcommands index a BAM, count its records, build a pileup, and call a consensus from one, and which Lungfish Genome Explorer installs and runs for you behind the alignment surfaces rather than asking you to type it. See also BAM, pileup, consensus sequence, mpileup.

**savONT**{#savont}. A clustering option for full-length ONT MHC amplicons, an alternative to pbAA. See also clustering, pbAA.

**Scaffold**{#scaffold}. A run of contigs an assembler has placed in order and orientation relative to one another using paired-end reads that bridge the gaps between them, written as one sequence in which each unresolved gap appears as a run of `N` characters of the estimated length. Lungfish Genome Explorer builds an assembly bundle from the contigs rather than the scaffolds, so a scaffold file sits in the run folder but is not what the assembly viewport shows. See also contig, paired-end, assembly bundle.

**Schema version**{#schema-version}. The number recorded inside a structured Lungfish Genome Explorer file saying which layout it was written to, carried by a bundle manifest as its format version and by a project lock record as `schemaVersion`, so a newer program can tell whether it is reading a file it fully understands. See also manifest, bundle migration, project lock.

**Secondary alignment**{#secondary-alignment}. An extra record reporting another place a read could plausibly have come from, marked by FLAG bit 256 and produced in quantity by repeated regions, which Lungfish Genome Explorer excludes from a mapping run's BAM by default because the duplicate rows inflate read counts. See also FLAG, primary alignment, supplementary alignment.

**seqkit**{#seqkit}. A general-purpose toolkit for FASTA and FASTQ manipulation, used in Lungfish Genome Explorer for the read-length filter and for several sequence statistics. See also FASTQ, read length.

**Sequence dictionary**{#sequence-dictionary}. A small `.dict` file written beside a reference FASTA listing every contig in it with that contig's length and checksum, which GATK requires before it will read the reference and which Lungfish Genome Explorer does not create for you, so a first GATK run against a bare FASTA fails naming the missing file. See also FASTA, reference genome, contig.

**Sequence motif**{#sequence-motif}. A short run of bases whose presence in a read is the thing being looked for, such as a primer footprint, a restriction site, or a repeat, matched against the read's sequence rather than against its name. See also read identifier, regular expression, Alu element.

**Sequence viewport**{#sequence-viewport}. The centre pane of a Lungfish project window when a reference bundle is open, drawing one sequence along a horizontal axis as three stacked lanes rather than three separate panes, with the numbered position ruler on top, the bases in the middle, and the annotation features as coloured blocks below. See also reference bundle, annotation track, Inspector.

**SH-aLRT**{#sh-alrt}. The Shimodaira-Hasegawa approximate likelihood ratio test, a fast branch-support measure IQ-TREE reports as a percentage at each internal node. Read it alongside bootstrap support, with values at or above 80 treated as reliable. See also support value, IQ-TREE.

**Shannon entropy**{#shannon-entropy}. A measure of how varied a stretch of sequence is, running from 0 when one base repeats to 1 when all four appear in even proportion, used by the low-complexity filter to score a read window by window so that a repeat inside an otherwise ordinary read is still caught. See also bbduk, k-mer.

**Shearing**{#shearing}. Breaking DNA into fragments at no fixed position, by physical or enzymatic means, which is how a shotgun library is made and the opposite of the numbered pieces an amplicon protocol produces. See also shotgun sequencing, amplicon, library prep.

**Shell**{#shell}. The program that reads what you type at a terminal prompt and runs it, holding the `PATH` it searches for programs and the environment variables it hands to each one it starts. See also PATH, environment variable, exit status.

**Shotgun sequencing**{#shotgun}. A library preparation strategy in which sample nucleic acid is fragmented at random and sequenced without targeted amplification. Each read lands at an essentially arbitrary position on the genome. Shotgun data does not require primer trimming. See also amplicon.

**Sidebar**{#sidebar}. The left-hand pane of a Lungfish project window that shows the project's contents as a folder tree, with a search field above it and a synthetic Analyses group prepended whenever the project holds results. Toggle with `Ctrl-Cmd-S`. See also project, Inspector.

**Simplex read**{#simplex-read}. An Oxford Nanopore read produced by basecalling one strand of a DNA molecule passing through a pore once. Modern R10.4.1 simplex with super-accuracy basecallers achieves Q20+ per-base quality. See also duplex read, basecaller.

**Single-end**{#single-end}. A sequencing protocol that reads each DNA fragment from one end only, producing one FASTQ file per sample, and common for Oxford Nanopore and for some Illumina shotgun protocols. See also FASTQ, paired-end.

**Singleton read**{#singleton-read}. A read from a paired-end run whose mate is no longer present in the file, usually because an upstream filtering step discarded one member of the pair, and which a repair operation sets aside as unpaired rather than discarding. See also paired-end, interleaved FASTQ.

**Sliding-window trimming**{#sliding-window-trimming}. A quality-trimming method that averages the quality scores of a small run of neighbouring bases and cuts the read where that average first falls below a threshold, so a single miscalled base does not truncate an otherwise good read. See also fastp, Phred score.

**Smart cohort**{#smart-cohort}. A named, saved filter over the samples of a genotype result, stored inside the result bundle so it can be reapplied later, seeded with four defaults on a run that carried haplotype analysis and with none on a genotype-only run. See also cohort, genotype matrix.

**Smart-filter token**{#smart-filter-token}. One of the named filter chips revealed by the Presets button above the Variants tab, such as PASS, SNV, or DP >= 10, that applies a common variant filter with a single click and appears only when the loaded track carries the field it needs. See also filter profile, FILTER.

**snake_case**{#snake-case}. A naming style in which lowercase words are joined by underscores, as in `primer_count`, used for every key in a primer scheme manifest. See also JSON, manifest.

**Snakemake**{#snakemake}. A workflow language and runner in which an analysis is written as a set of rules, each naming its input files, its output files, and the command that turns one into the other, so the runner works out the order for itself, pinned by Lungfish Genome Explorer at version 9.25.2 and emitted as a `Snakefile` by the Snakemake Workflow provenance export. See also Nextflow, provenance sidecar, container.

**SNV (single-nucleotide variant)**{#snv}. A variant in which one reference base is read as one different base, written in a VCF as a REF and an ALT that are each a single character, and the commonest kind of difference between any two genomes. See also indel, REF and ALT, VCF.

**Soft-clip**{#soft-clip}. A flag in a BAM record (the `S` letter in a CIGAR string) marking bases at the start or end of a read that are present in the record but excluded from pileup, coverage, and variant calling. Primer trimming works by soft-clipping primer-derived bases rather than deleting them. In 12S amplicon matching the word names the same shape of thing without a BAM, the read's own bases hanging past each end of the matched reference stretch, which the Min Soft Clip setting counts to reject reads that only graze the target instead of containing it. See also primer trim, CIGAR, 12S.

**Sparkline**{#sparkline}. A small chart drawn without axes or labels, sized to sit inside a strip rather than to be read precisely, of which Lungfish draws three under a FASTQ bundle's summary cards, labelled Length Dist., Q / Position, and Q Score Dist., with a click on any one opening the full-size chart in a popover. See also quality control, FASTQ.

**Spike-in control**{#spike-in-control}. A known sequence added deliberately to a sequencing library so that its behaviour in the results reports on how the run itself performed, the commonest being the bacteriophage phiX genome that Illumina protocols add to improve the instrument's base calling. A handful of phiX reads turning up in a classification report is expected rather than a sign of contamination. See also read classification, Kraken 2.

**Spliced feature**{#spliced-feature}. An annotated feature built from several separate pieces of sequence with the intervening stretches left out, which a single start and a single end cannot record, so LGE preserves the original GenBank location string alongside it. See also GFF, GenBank, exon.

**SRA (Sequence Read Archive)**{#sra}. The NCBI public archive of raw sequencing reads, identified by accession numbers that start with `SRR` for runs and `SRP` for projects. Lungfish downloads SRA reads via the ENA mirror first and falls back to the SRA Toolkit if ENA refuses. See also ENA.

**Stale lock**{#stale-lock}. A project lock whose owning process is no longer running on this machine, which Lungfish Genome Explorer treats as safe to replace, so `project lock` overwrites one without complaint and `project unlock` removes one belonging to the current user without needing `--force`. Because a command-line lock's owning process exits the moment the command finishes, a lock taken that way is stale almost immediately. See also project lock, advisory lock, project.

**Standard error**{#stderr}. The output channel a command-line program writes its progress notes and error messages to, kept separate from its results, which is why a genotyping run bundle stores one error log per tool it invoked. See also exit status, shell, provenance sidecar.

**Standard error**{#standard-error}. The second output channel a command-line program writes to, carrying its error messages and progress notes while its actual results go to the first channel, written `stderr` in tool documentation and in provenance records. Keeping the two apart is what lets a script save a result to a file while still showing the reader what went wrong. See also exit status, shell, provenance sidecar.

**Strand**{#strand}. Whether a read aligned to the reference as sequenced (forward) or as its reverse complement (reverse), recorded as a flag bit in every BAM row. See also strand bias.

**Strand bias**{#strand-bias}. A pattern where reads supporting a variant come predominantly from one strand of the reference, often as an artifact of primer placement in amplicon protocols rather than a genuine biological signal. Variant callers apply a strand-bias filter to flag suspect calls. For amplicon data the filter is usually disabled because the imbalance is structural. See also amplicon.

**Strand odds ratio**{#strand-odds-ratio}. A VCF statistic written as `SOR`, scoring how lopsidedly the reads supporting a variant came from one strand of the DNA rather than from both, with a higher number meaning a more lopsided split. A real variant should be seen about equally from both strands, so GATK's recommended hard filter marks a substitution whose `SOR` exceeds 3 and an indel whose `SOR` exceeds 10. See also strand bias, hard filter, INFO.

**Structural variation**{#structural-variation}. A difference between two genomes large enough to move, duplicate, invert, or delete a whole block of sequence rather than change individual bases, conventionally taken to mean anything from about fifty bases upward. Reference mapping reports these only indirectly, through reads whose ends fail to align and read pairs landing implausibly far apart, whereas an assembly reconstructs the rearranged sequence outright. See also de novo assembly, soft-clip, contig.

**Subcommand**{#subcommand}. The word typed after a command-line program's name that picks which operation runs, as `convert` does in `lungfish-cli convert`, and which may itself carry further subcommands beneath it. See also command-line flag, positional argument.

**Sublineage**{#sublineage}. A viral lineage nested inside another one, named by extending the parent's name with a further number, so BQ.1.19 carries every mutation that defines BQ.1 plus the additional ones that distinguish it, which is why closely related sublineages are the hardest pairs for a demixing tool to tell apart. See also lineage, demixing.

**Subsampling**{#subsampling}. Drawing a smaller set of reads at random from a larger one, so the smaller set keeps the composition of the original without anyone choosing which reads survive, used to make a fast test slice or to cut two libraries to a common depth before comparing them. See also FASTQ, read length.

**Substitution model**{#substitution-model}. The set of assumed rates at which one base or residue changes into another, which a maximum-likelihood method needs before it can score a tree. IQ-TREE's default `MFP` setting is an instruction to test many models and use the best-fitting one rather than a model itself. See also maximum likelihood, IQ-TREE.

**Supplementary alignment**{#supplementary-alignment}. A secondary record for a read that maps in pieces (split-read or chimeric alignment), with the full read mapped at the primary position and supplementary records covering the other pieces. Flag bit 2048 marks supplementary alignments. See also BAM, FLAG.

**Support value**{#support-value}. A number annotated at an internal node of a phylogenetic tree giving the percentage of bootstrap or replicate trees that recovered that exact split. Values above 95 indicate a well-supported clade and values below 70 should not be relied on. See also IQ-TREE, phylogram.

**Switch**{#switch}. A command-line flag that carries no value after it, so it is either typed or left out and never takes a word of its own, as `--compress` and `--force` do on the Lungfish Genome Explorer commands that accept them. See also command-line flag, subcommand.

**Symlink**{#symlink}. A file that holds nothing but the path of another file or folder, so opening it opens the target instead, of which macOS keeps one at `/tmp` pointing at `/private/tmp`, giving one folder two spellings that some Lungfish Genome Explorer commands compare as though they were different places. See also working directory.

## T

**Tabix**{#tabix}. A position-aware index for a bgzipped tab-delimited genomic file (typically `.vcf.gz` or `.bed.gz`), conventionally named with a `.tbi` suffix and kept beside the data file, that lets viewers and callers fetch records for a region without scanning the whole file. See also VCF.

**Table drawer**{#table-drawer}. The panel that slides up from the bottom edge of a reference bundle viewport carrying one tab per kind of table, Annotations, Variants, and Samples, which opens by itself whenever the loaded bundle holds an annotation or variant track. It starts 250 points tall, resizes by dragging its top edge, and remembers the height you set. See also reference bundle, variant track, sequence viewport.

**Tarball**{#tarball}. A single file holding a whole folder tree, produced by the `tar` program and conventionally named with a `.tar` ending, which is the shape `lungfish-cli bundle export` is meant to write a reference bundle into. See also OCI layout, bundle, checksum.

**Target enrichment**{#target-enrichment}. A library preparation that pulls chosen regions out of a randomly sheared sample using complementary probes, so reads concentrate on the targets without carrying primer sequence at their ends and without needing a primer trim. See also library prep, amplicon, shotgun.

**TASS score**{#tass-score}. The single number TaxTriage reports for each organism it calls, folding read support, how those reads spread across the organism's reference genome, and agreement between the pipeline's steps into one value that a reviewer can sort on, which Lungfish Genome Explorer expands as the Taxonomic Assignment Scoring System and reads in three bands with 0.80 and 0.40 as the boundaries. It is a repeatable ranking rather than a calibrated probability that the organism is present. See also TaxTriage, read classification, coverage breadth.

**Taxon**{#taxon}. Any named group on the tree of life, at any level of the naming hierarchy, so *Homo sapiens*, *Streptococcus*, and *Coronaviridae* are each one taxon, and a classifier's answer for a single read is the name of one of them. See also taxonomic rank, lowest common ancestor, read classification.

**Taxon report**{#taxon-report}. The tab-separated table a hosted metagenomics service such as CZ-ID hands back at the end of a run, holding one row per taxon it detected alongside that taxon's read counts, reads per million, percent identity, alignment length, and e-value, which Lungfish Genome Explorer imports and converts into its own classification format. See also CZ-ID, taxon, kreport, read classification.

**Taxonomic rank**{#taxonomic-rank}. The level of the biological naming hierarchy a taxon belongs to, running from domain down through phylum, class, order, family, and genus to species, which is what a classifier's result table reports in its Rank column and what each ring of a sunburst chart stands for. See also taxon, clade, read classification.

**Taxonomy identifier**{#taxonomy-id}. The number NCBI's Taxonomy database assigns to one taxon, such as `28875` for Rotavirus A, which classifiers and surveillance pipelines report instead of a name because the number is stable while names are revised, so a result table often has to resolve the numbers into names before a reader can use it. See also taxon, taxonomic rank, accession.

**TaxTriage**{#taxtriage}. A pathogen-detection workflow run as a Nextflow pipeline inside a container, which classifies reads against an installed Kraken 2 database and scores each organism it reports for confidence, opened in Lungfish Genome Explorer from **Tools > Classification > TaxTriage...**. See also read classification, Nextflow, container, Kraken 2.

**Thread**{#thread}. One parallel worker inside a running program, so a tool given eight threads divides its work into eight streams that run at once on different processor cores, which usually finishes sooner and can change the output in small ways when the streams finish in a different order. See also determinism, wall time.

**Tiling**{#tiling}. An amplicon design in which many primer pairs produce overlapping amplicons laid end to end, so that together they cover a whole region of interest rather than one locus. See also amplicon, primer scheme.

**Tip**{#tip}. The end point of a branch on a phylogenetic tree, standing for one of the sequences that went in, so five aligned sequences give five tips and a missing tip means an input was dropped. See also internal node, clade, topology.

**Tool lock manifest**{#tool-lock-manifest}. The file inside Lungfish Genome Explorer that records the exact version, license, and source of every tool one release installs, which is where the version numbers in the Tool Bibliography and Tool Versions appendices both come from and which governs when the two disagree. See also dependency set, pinned, plugin pack.

**Topology**{#topology}. The branching pattern of a phylogenetic tree, meaning which tips group with which and in what order, considered apart from the branch lengths. It is the tree's main claim and the part a support value measures confidence in. See also tip, internal node, support value, branch length.

**Transformer**{#transformer}. A piece of code inside Lungfish Genome Explorer that rewrites a bundle manifest from one schema version into another, so a bundle written by an older release can be brought up to the current layout. `lungfish-cli project migrate` reports a bundle as unsupported when no transformer exists for its schema version, and leaves it untouched rather than guessing. See also bundle migration, schema version, manifest.

**Transition to transversion ratio**{#transition-transversion-ratio}. The count of substitutions that swapped a base for the other one of the same chemical shape, meaning A for G or C for T, divided by the count that swapped between shapes, written `TITV` in Picard's metrics output. Genuine human variation runs at roughly 2 to 3 because transitions arise more readily in biology, while random sequencing error has no such preference and produces a ratio near 0.5, which makes the figure a fast check on whether a call set is real. See also SNV, dbSNP, novel variant.

**TSV (tab-separated values)**{#tsv}. A plain text table whose columns are separated by tab characters, one row per line, readable by any spreadsheet and by most analysis scripts, and the format `lungfish-cli gatk variants-to-table` writes when it flattens a VCF for use outside the genomics tools. See also VCF, CSV.

**12S**{#twelve-s}. A short mitochondrial 12S rRNA amplicon used to identify vertebrate species. Lungfish matches merged 12S reads exactly against a deduplicated reference FASTA. See also metabarcoding.

**Two-bit (2bit)**{#two-bit}. A packed binary sequence format from the UCSC genome browser that stores each base in two bits, recognized by Lungfish Genome Explorer's format registry by its `.2bit` extension as an import candidate rather than a viewable track. See also FASTA, format registry.

## U

**UMI (unique molecular identifier)**{#umi}. A short random barcode added to each original DNA molecule before amplification, so that PCR copies of one molecule can be recognised as copies rather than counted as independent observations. Where a protocol places a UMI at a fixed position at the read start, Trim Fixed Bases is the operation that removes it. See also barcode, mark duplicates.

**Unclassified reads**{#unclassified-reads}. The reads a barcoded Oxford Nanopore run produced whose barcode the basecaller could not read confidently, which MinKNOW collects in a folder named `unclassified` beside the numbered barcode folders and which the run-folder importer skips unless you ask for them. See also barcode, MinKNOW, demultiplex.

**Unitig**{#unitig}. A stretch of sequence that every read covering it agrees on and that the assembly graph joins to its neighbours in only one way, so it is the longest piece an assembler can emit without making a choice. Contigs are then built by choosing paths that link unitigs together, which is why an assembler's unitig graph is more fragmented and more trustworthy than its contig set. See also assembly graph, contig, GFA.

## V

**Variable site**{#variable-site}. A column of a multiple sequence alignment where the rows do not all carry the same residue, counted in an MSA bundle's manifest as `variableSiteCount`, whose value depends entirely on how distant the aligned sequences are and carries no threshold of its own. See also MSA, alignment column, gap.

**Variant track**{#variant-track}. One named set of variant calls stored inside a reference bundle, written as a bgzip-compressed VCF with a tabix index and a SQLite copy of the same rows that the Variants tab queries when you sort or filter. A bundle can hold several, and when it does they all load into the one table at once with the Source column naming which track each row came from. See also reference bundle, table drawer, VCF.

**Variant-caller**{#variant-caller}. The program that compares aligned reads to a reference and emits a VCF describing positions where the sample differs. Lungfish offers five viral callers (LoFreq for short-read viral data, iVar for primer-trimmed amplicon data, Medaka and Clair3 for Oxford Nanopore data, and bcftools as a general cross-check) plus two GATK germline options for human work. See also pileup, VCF.

**Variant-only bundle**{#variant-only-bundle}. A `.lungfishref` bundle built around one or more imported VCFs and holding no reference sequence of its own, which is what Lungfish Genome Explorer creates when you import a VCF with no reference bundle open and name the result at the Name Imported Variant Bundle prompt. It records the ploidy it assumed under an Import Settings group and tries to fetch a matching reference from NCBI in the background. See also reference bundle, variant track, VCF.

**VCF (Variant Call Format)**{#vcf}. A tab-separated file format that lists positions in a reference genome where a sample differs, with per-call confidence and metadata. See also REF, ALT, genotype, allele frequency.

**Viewport**{#viewport}. The main display area in the middle of the Lungfish Genome Explorer window, which shows whatever bundle is selected in the sidebar and takes a different form for each kind of result, among them the sequence, taxonomy, alignment, assembly, and variant shapes. See also Inspector, bundle.

**Virtual bundle**{#virtual-bundle}. A read bundle that stores a short manifest naming its parent bundle and the operation to apply rather than a second copy of the reads, keeping only a preview of about a thousand reads on disk, so that many subsets of one sample cost about as much storage as one. See also materialization, bundle, subsampling.

**vsearch**{#vsearch}. An open-source toolkit for comparing and clustering nucleotide sequences, used by Lungfish Genome Explorer to screen a 12S run's unmatched sequence clusters for chimeras and to turn reads to a common orientation against a reference. See also chimera, read orientation, 12S.

## W

**Wall time**{#wall-time}. The real elapsed time a run took from start to finish, as a clock on the wall would measure it, which is longer than the processor time when a run waits on disk and shorter than the summed processor time when it uses several cores at once. See also threads, provenance.

**Wastewater Surveillance pack**{#wastewater-surveillance}. The Lungfish Genome Explorer plugin pack that installs Freyja together with iVar, minimap2, Pangolin, and Nextclade, marked Experimental in the Plugin Manager and installing a build of Freyja that runs natively on Apple Silicon. See also plugin pack, Freyja, demixing.

**Workflow bundle**{#workflow-bundle}. A `.lungfishflow` folder under a project's `Workflows` folder holding one Workflow Builder chain, with the drawing and every parameter in `workflow.json`, a copy in `graph.json`, one line per save in `versions/history.json`, a `provenance.json` naming the LGE version and the checksum of each written file, and a `runs/<run-id>/` folder for each time the chain was run. See also directed acyclic graph, node port, provenance.

**Workflow engine**{#workflow-engine}. A program that reads a description of an analysis, works out which step must happen before which other step, and then runs them in that order, of which Lungfish Genome Explorer drives two, Nextflow pinned at version 26.04.6 and Snakemake pinned at version 9.25.2. See also Nextflow, Snakemake, workflow package.

**Workflow Library**{#workflow-library}. The window opened with **Tools > Workflow Library...** that lists every specialized workflow and every linked workflow package as a card with an Enabled switch, and which is the only place a specialized workflow can be turned on before its Tools menu item stops reading `(not enabled)`. See also workflow package, plugin pack.

**Workflow lineage**{#workflow-lineage}. The ordered chain of tool invocations a Lungfish run record holds, shown as the Lineage block of the Inspector's Provenance section, where each numbered step expands to its own command, inputs, outputs, exit status, and wall time. Distinct from a viral lineage, which names a subgroup of a virus species. See also run record, provenance sidecar.

**Workflow package**{#workflow-package}. A `.lungfishflowpkg` folder holding a Nextflow or Snakemake pipeline together with a `manifest.json` that names the workflow, gives it a version and a category, declares which engine runs it, and declares the input bundle types it requires and the output bundle types it produces, from which Lungfish Genome Explorer generates the run form. A package is linked into the Workflow Library rather than copied into a project, and it can be enabled only when its runner is Nextflow or Snakemake and its manifest declares a required reference input, a required reads input, and at least one output. See also workflow engine, run bundle, bundle.

**Working directory**{#working-directory}. The folder a Terminal window is sitting in when a command is typed, which decides where relative paths point and where a command writes by default, and which the command `pwd` prints. See also symlink, exit status.

**Wrapper**{#wrapper}. A program that builds another program's command line and runs it for you, which is what Lungfish Genome Explorer does every time a dialog setting becomes a flag on samtools, iVar, or an assembler. See also argument, command-line flag, provenance sidecar.

## X

**XLSX**{#xlsx}. The Excel workbook format, a ZIP package of worksheet XML. Genotype exports are immutable one-way reports containing All and Filtered matrices, optional real Haplotype Calls, and Export Metadata. Filtering does not remove data from All. See also pivot workbook, CSV, genotype result bundle.

## Y

**YAML**{#yaml}. A plain text format that records settings as indented `key: value` lines, where the indentation shows which setting belongs inside which, used by every continuous integration service for the file that describes a job. See also continuous integration, JSON.

## Z

**Zero-based**{#zero-based}. A numbering convention in which the first base of a sequence is numbered 0 rather than 1, used by BED and bedGraph, so converting a zero-based half-open start into the one-based inclusive form the LGE window shows means adding 1 to it. See also half-open, BED, coordinate.
