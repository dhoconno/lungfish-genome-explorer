# iVar Converter Parity Fixture

Source iVar TSV from running the Lungfish pipeline on SRR36291587 against
MN908947.3. Reference FASTA and GFF3 are committed alongside.

The parity test runs the upstream `ivar_variants_to_vcf.py` and the Swift
converter on the same TSV, then diffs the outputs.

`ivar_variants_to_vcf.py` is vendored in this directory rather than fetched
at test time, so the test is hermetic and does not depend on network access
or CI provisioning.

- Source: https://github.com/nf-core/viralrecon/blob/928d1437b478e484ec2d9b7a4e686d18782928c9/bin/ivar_variants_to_vcf.py
- Pinned commit: `928d1437b478e484ec2d9b7a4e686d18782928c9` (nf-core/viralrecon, 2025-09-24)

The script requires `numpy`, `biopython`, `scipy`, and `pandas` on the
`python3` used to run it (`pip install numpy biopython scipy pandas`).

The test runs automatically whenever `python3` is available and skips (or
fails under `LUNGFISH_REQUIRE_TOOLS=1`) when it is not; there is no longer
an env-var gate. To run it directly:

```bash
swift test --filter IVarConverterViralReconParity
```

To point at a different copy of the script (for example while testing an
upstream update before re-vendoring it), set `LUNGFISH_IVAR_TO_VCF_PY`:

```bash
LUNGFISH_IVAR_TO_VCF_PY=/path/to/ivar_variants_to_vcf.py swift test --filter IVarConverterViralReconParity
```

To re-vendor a newer upstream commit, download the file at the new commit,
replace `ivar_variants_to_vcf.py` in this directory, and update the source
URL and pinned commit above.
