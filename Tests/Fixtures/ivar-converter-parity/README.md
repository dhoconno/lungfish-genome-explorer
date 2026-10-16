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

The script needs `numpy`, `biopython`, `scipy` and `pandas`. The test runs it under the `ivar-oracle` Python of the golden environment lock (`Tests/Fixtures/golden-environment/README.md`), never the `python3` on PATH. `python3 scripts/golden/environment.py provision` builds that environment at `/Users/Shared/lungfish-golden/storage`, and the test looks under the conda root of the managed storage and then there.

When the environment is not installed the test skips with its reason, and under `LUNGFISH_REQUIRE_TOOLS=1` it fails. A script that exits non-zero under a working Python is a failure on any machine. To run it directly:

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
