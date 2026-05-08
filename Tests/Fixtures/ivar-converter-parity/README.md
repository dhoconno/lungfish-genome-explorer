# iVar Converter Parity Fixture

Source iVar TSV from running the Lungfish pipeline on SRR36291587 against
MN908947.3. Reference FASTA and GFF3 are committed alongside.

The parity test runs the upstream `ivar_variants_to_vcf.py` (installed
once per CI run from a pinned nf-core/viralrecon commit) and the Swift
converter on the same TSV, then diffs the outputs.

To run the parity test locally:

```bash
LUNGFISH_VIRALRECON_PARITY=1 LUNGFISH_IVAR_TO_VCF_PY=$(pwd)/ivar_variants_to_vcf.py swift test --filter IVarConverterViralReconParity
```
