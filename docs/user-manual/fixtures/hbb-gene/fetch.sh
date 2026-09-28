#!/usr/bin/env bash
# Fetch the HBB RefSeqGene record (beta-globin locus, chromosome 11) from
# NCBI, with the full feature table (gene/mRNA/CDS/exon) so the sequence,
# annotation, extraction, and translation chapters have real features to
# work with. Sickle cell (HbS, Glu6Val, rs334) is the example.
set -euo pipefail
cd "$(dirname "$0")"

# rettype=gbwithparts pulls the GenBank flatfile WITH the contig parts
# resolved, so CDS/mRNA/exon feature locations point at real sequence
# rather than a CONTIG join() remote-span placeholder.
curl -sL "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NG_000007.3&rettype=gbwithparts&retmode=text" > NG_000007.3.gb

du -sh NG_000007.3.gb
grep -c "     gene " NG_000007.3.gb
grep -c "     mRNA " NG_000007.3.gb
grep -c "     CDS " NG_000007.3.gb
grep -c "     exon " NG_000007.3.gb
