# SARS-CoV-2 SRR36291587 chapter fixture

Reference: MN908947.3 (Wuhan-Hu-1, GenBank). Reads: SRR36291587 (QIAseq
Direct SARS-CoV-2, paired-end Illumina, 86,281 read pairs).

Committed artifacts:

- MN908947.3.fasta — 30 KB reference sequence
- MN908947.3.gff3 — NCBI GFF3 annotation (genes, CDS, mat_peptide, stem_loop)
- ivar.expected.vcf — iVar variants from the chapter's workflow, with
  codon merging applied via the bundled GFF3 (the N-gene 28881-28883
  trio collapses into one row)
- lofreq.expected.vcf — LoFreq variants from the chapter's workflow

The GFF3 is fetched from NCBI by the regenerate script via
`lungfish fetch ncbi MN908947.3 --fetch-format gff3` and attached to the
reference bundle with `lungfish bundle create --annotation`. With
annotations attached, the iVar pipeline calls codon-aware variants and
the Lungfish converter merges three adjacent SNPs that fall inside one
codon into a single VCF row.

The 21.7 MB compressed FASTQ from SRA is **not** committed. Run
`./regenerate.sh` to re-derive every artifact from the original
accessions.

License: SRR36291587 is publicly available from the NCBI Sequence Read
Archive. MN908947.3 is publicly available from NCBI GenBank. Both are
in the public domain in the U.S.; check your local jurisdiction.
