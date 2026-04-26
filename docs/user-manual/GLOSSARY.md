# Glossary

**Ownership:** Bioinformatics Educator only.

Terms appear in alphabetical order. Each entry is a one-sentence definition,
optionally followed by a "see also" cross-reference and a chapter reference.

## A

**Allele frequency.** The proportion of sequencing reads at a position that carry the alternate base. A clinical isolate usually shows allele frequencies near 0 or 1; a mixed-population sample (for example, wastewater) shows a full spectrum.

**Amplicon.** A target region of a genome amplified by PCR, used as the unit of an amplicon-based sequencing protocol such as ARTIC or QIASeqDIRECT. A run produces many overlapping amplicons that together tile the region of interest.

## G

**Genotype.** A compact notation for which alleles are observed at a variant position, conventionally diploid-style `0/1` (heterozygous) or `1/1` (homozygous alternate). For a single-organism viral isolate, confidently-called variants are nearly always `1/1`.

## P

**Primer scheme.** The set of primer coordinate pairs that define an amplicon protocol, listing where each forward and reverse primer binds on the reference. In Lungfish, a primer scheme is packaged as a `.lungfishprimers` bundle that carries the BED coordinates, the primer sequences in FASTA, and provenance.

**Primer trim.** The step that removes primer-derived bases from the ends of aligned reads in amplicon data, so those bases do not contaminate variant calls. In Lungfish the trim runs as a BAM-level operation using `ivar trim` against a selected primer scheme. See also: amplicon, primer scheme.

## R

**REF, ALT.** REF is the base or bases present in the reference genome at a variant position; ALT is the base or bases observed in the sample. A one-base REF and one-base ALT describe a SNP; longer REF or ALT describe insertions and deletions.

## V

**Variant-caller.** The program that compares aligned reads to a reference and emits a VCF describing positions where the sample differs. Lungfish ships three viral-focused callers: LoFreq for short-read viral data, iVar for primer-trimmed amplicon data, and Medaka for Oxford Nanopore data.

**VCF (Variant Call Format).** A tab-separated file format that lists positions in a reference genome where a sample differs, with per-call confidence and metadata. See also: REF, ALT, genotype, allele frequency.
