# Structural cDNA Routing for Full-Length ONT MHC Genotyping

## Scope

This design applies only to newly generated full-length ONT MHC genotype bundles and their viewport, candidate artifacts, and two-sheet workbook. It does not migrate old bundles or alter vestigial genotyping workflows.

## Problem

The production cohort alignment maps each reference allele onto each consensus cluster. The current known-genotype gate accepts a zero-SNP/zero-ordinary-indel cDNA alignment without proving that the cDNA and cluster cover one another end to end. A full cDNA embedded within a longer genomic cluster can therefore be removed from candidate discovery as a known cDNA genotype. Splice gaps can also be represented by `N` and are currently excluded from the ordinary-indel count. Separately, the unmatched normalization path trims a cluster to the closest mapped interval before candidate classification, destroying terminal extension evidence.

## Structural policy

Reference molecule class must come from the annotated reference catalog, not from reference length alone. The current cDNA length threshold remains available only as a compatibility fallback when older reference metadata lacks molecule class.

One shared policy governs cohort and reciprocal orientations:

- A compatible cDNA relationship has zero SNP substitutions and at least 95% cDNA-reference coverage.
- A structural segment is meaningful at 20 bases or longer. This reuses the existing minimum intron-gap threshold.
- A known cDNA genotype requires compatible cDNA coverage, near end-to-end mutual coverage, no terminal cluster flank of 20 bases or more, no internal cluster-side `D`/`N` segment of 20 bases or more in cohort orientation, and no corresponding query-side `I`/soft-clipped extension of 20 bases or more in reciprocal orientation.
- A cDNA extension relationship requires compatible cDNA coverage plus at least one meaningful terminal flank or internal cluster-side structural segment. Ordinary indels shorter than 20 bases do not prevent extension classification. SNP substitutions do prevent `_ext` classification.
- An alignment missing more than 5% of the cDNA reference is neither a known cDNA genotype nor sufficient evidence for `extensionOf`.
- Exact genomic-reference behavior remains unchanged. A zero-SNP genomic relationship remains eligible as a known genotype under the existing indel rules.

Coverage, leading and trailing flanks, internal structural gaps, SNPs, ordinary indels, identity, score, strand, and molecule class must be retained in compact summaries. Candidate rendering must not reread BAM locators.

## Routing and sequence identity

A structurally extended cDNA cluster is routed into the candidate stage even though it has a high-identity cDNA relationship. Unmatched clusters continue into the same candidate stage.

The complete consensus sequence, oriented to the selected biological strand, is the canonical candidate sequence. Closest-hit interval coordinates and the legacy interval-trimmed sequence may remain metadata, but they cannot define candidate identity, the deduplicated unmatched FASTA, reciprocal mapping input, full-length Excel sequence, or GenBank source sequence. UTR/CDS trimming is a later explicit derivation.

## Joint cDNA and genomic interpretation

Every compatible structural cDNA reference retained by the cohort alignment is recorded deterministically in `extensionOf`; a single best cDNA hit must not erase equally compatible homologous records.

Genomic evidence and cDNA evidence have separate roles:

- cDNA evidence establishes extension relationships and supplies the `_ext` base allele name.
- the best unambiguous genomic relationship resolves locus and supplies the closest-reference alignment used for lifted features, consequence comments, and genomic comparison.
- exact genomic known-genotype evidence continues to win over candidate classification.
- when equally ranked genomic evidence conflicts across loci, the candidate may use a cDNA-derived locus only when all retained compatible cDNA records agree. Otherwise it is un-nameable because locus assignment is ambiguous.

The candidate JSON schema is advanced for new bundles and stores `extensionOf` interpretations together with the selected genomic interpretation. Existing readers remain able to decode schema-2 bundles; no old output is rewritten.

## Artifacts and UI

For an extension candidate:

- the provisional name ends in `_ext`;
- GenBank COMMENT fields identify all `extensionOf` references and the selected genomic closest reference;
- the candidate facts rail exposes both interpretations without loading raw BAM evidence;
- the `Unmatched Alleles` workbook tab includes an `Extension Of` field;
- both `Full-Length FASTA Sequence` and `UTR-Trimmed FASTA Sequence` remain present as separate Excel columns;
- the candidate GenBank record remains CDS-bounded/UTR-trimmed while the full-length FASTA remains available separately.

All artifact manifest entries and provenance describe the structural policy, resolved defaults, reference molecule classification, full and trimmed sequence checksums, exact inputs/outputs, runtime, exit status, and timing as required by the repository provenance contract.

## Required regressions

1. A 3 kb consensus containing a complete internal 1 kb cDNA plus genomic/intronic sequence is an extension candidate and retains all 3 kb.
2. `500=1000N500=`-style cohort evidence is structural extension evidence, not a known cDNA genotype.
3. A true end-to-end cDNA match remains known.
4. A cDNA relationship missing roughly 10% of the reference is neither known nor `_ext`.
5. Multiple compatible cDNA references are all retained while unambiguous genomic evidence resolves locus.
6. An exact genomic match remains known.
7. Reverse-strand structural candidates preserve the full reverse-complemented consensus.
8. Candidate JSON, GenBank, two-sheet workbook, viewport facts, manifest, and provenance agree on `extensionOf`, selected genomic evidence, and full versus trimmed sequences.

