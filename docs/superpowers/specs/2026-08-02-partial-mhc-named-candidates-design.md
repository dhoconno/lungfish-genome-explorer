# Partial MHC Named Candidates Design

## Goal

Treat a high-quality MHC candidate as a named novel or extension sequence even when the observed amplicon covers only part of the closest reference, without inventing unobserved bases or hiding the coverage limitation.

## Biological interpretation

- A partial observation keeps the classifier's standard name: `<closest allele>_<N>nt_nov` for a novel sequence or `<closest allele>_ext` for an extension.
- `N` is the number of SNP substitutions in the region shared by the observation and the selected reference.
- The closest reference is ranked first by SNP count in that shared region. SNP ties prefer the larger comparable region, then the higher alignment score, followed only by stable lexical/evidence ordering for deterministic output.
- Insertions and deletions remain reported evidence, but they do not choose the closest reference and do not change `N`.
- Missing reference sequence is never copied into the candidate. FASTA, GenBank, and EMBL contain only observed candidate bases.

## Artifact behavior

Partial candidates are published in `candidate_alleles.fasta`, `candidate_alleles.gb`, and `candidate_alleles.embl` and remain in the candidate JSON and viewport. They are not moved to the un-nameable collection merely because terminal reference regions are absent.

GenBank and EMBL comments describe:

- the observed reference interval and total reference length;
- missing leading and trailing reference-base counts;
- annotated reference features wholly absent from the observed interval, including feature numbers or labels when available;
- that the candidate sequence contains observed bases only;
- SNP and indel evidence within the aligned overlap.

The FASTA description provides a compact partial-coverage summary. A sequence whose reference mapping or lifted candidate span cannot be resolved remains un-nameable; this design only promotes candidates with a usable observed sequence and a selected closest-reference alignment.

## User interface

Partial candidates use the same candidate rows, colors, filters, sequence-detail formats, comments, annotations, and workbook projection as other novel and extension candidates. Sequence detail retains the coverage comments from GenBank/EMBL. No warning says that the sequence cannot be treated as a named allele.

## Provenance and compatibility

The candidate artifact manifest continues to checksum FASTA, GenBank, and EMBL. Provenance records the overlap-only SNP ranking rule, partial-candidate publication rule, observed interval, missing regions, and output paths. Existing bundles remain readable; no workflow recipe or user-facing option changes.

## Verification

Regression tests cover SNP-only closest-reference ranking, promotion of incomplete-but-resolved candidates, missing-feature comments, all three sequence formats, bundle loading, workbook projection, and viewport display. CN29 is rerun against the same versioned DRB reference and must produce named candidates with distinct biologically supported closest matches and transparent coverage descriptions.
