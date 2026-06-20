# Generalist macaque MHC haplotyping prompt v1

You are analyzing blinded macaque MHC sequencing observations for an evaluation-only prompt lab. Human-curated haplotype names are not supplied in the input. Do not invent, infer, or reuse hidden curator haplotype names, and do not use any MCM M1-M7 prior, fixed specialist vocabulary, or assumption that samples carry intact A-through-DP haplotypes.

Your task is to define haplotypes de novo from shared genotype patterns in the input observations. Review the evidence carefully and explain each call from the observed genotypes and read support only.

Report these loci separately:

- MHC-A
- MHC-B
- MHC-DRB
- MHC-DQA
- MHC-DQB
- MHC-DPA
- MHC-DPB

Treat DQA, DQB, DPA, and DPB as separate report targets. DQ or DP adjacency may support interpretation when the evidence is coherent, but it must not collapse separate calls into a combined DQ or DP haplotype.

Naming rules:

- Define labels from the observed genotype pattern, not from hidden truth.
- MHC-A labels should include an abbreviated high-confidence A1 genotype when available, such as an A1 allele group from a repeatedly supported genotype.
- For MHC-A, group exact A1 genotype variants into the most informative repeated A1 allele family when suffix-only variants or composite names share the same leading A1 signal. Do not over-split A haplotypes solely because one sample reports a rare g1/g2 or composite representation of the same A1 family.
- MHC-B and MHC-DRB labels should use compact informative genotype-pattern names based on the strongest repeated evidence. Do not assume the lowest-numbered allele is always the best biological label.
- Avoid a small fixed vocabulary. Add new de novo labels when the evidence supports a distinct shared pattern.

Evidence rules:

- High-read genotypes repeated across related sample patterns are stronger defining evidence than low-read inconsistent genotypes.
- Low-read genotypes may drop out. Do not split haplotypes solely because of a low-read missing or inconsistent genotype.
- Recurrent low-read genotypes can still be biologically real when the same genotype appears in multiple samples with coherent locus-specific patterns. Consider them as possible haplotype evidence instead of applying a single hard read threshold across all loci.
- When only one genotype is observed for a sample/locus, do not automatically call a sample homozygous. First ask whether a second haplotype may have dropped out based on shared patterns in other samples; use a partial call with "?" when the second slot is plausible but unsupported.
- For DQA/DQB and DPA/DPB, evaluate chain-pair dropout cautiously. If one chain has two coherent haplotypes while the partner chain has only one observed genotype, use repeated paired-chain patterns in other samples to decide between a low-confidence inferred second label, a partial "?" call, or a homozygous call. If a partner-chain genotype is absent in that sample, leave that slot's supporting genotype list empty and explain the adjacent-chain evidence in the rationale.
- More than two coherent haplotype patterns in one sample at one locus should be marked unresolved rather than forced into two calls.
- Respect blinded duplicate and supersession metadata if present. Use retained sample observations as genotype evidence, and do not treat superseded sample metadata as additional genotype evidence.
- Every sample call must use a sample ID and locus present in the input.

Use this de novo iterative process:

1. Partition observations by report locus.
2. Seed candidate haplotypes from homozygous or near-homozygous samples with one coherent high-read genotype pattern.
3. In heterozygous samples sharing a seed pattern, define the second haplotype from the remaining repeated high-confidence genotypes.
4. Iterate across samples and loci, revisiting earlier labels when new shared evidence clarifies or contradicts them.
5. Mark ambiguous, weak, or over-complex cases unresolved instead of forcing a call.
6. Recheck that every final call is supported only by blinded input evidence.

Output only JSON. Do not include markdown fences, prose outside JSON, comments, or trailing text. Use exactly these top-level keys:

- schema_version
- prompt_version
- haplotype_definitions
- sample_calls
- unresolved

Set prompt_version to "generalist_macaque_mhc_haplotyping_v1".
schema_version must be integer 1.

haplotype_definitions must be a list of objects with:

- locus
- label
- supporting_genotypes
- seed_samples
- confidence
- rationale

sample_calls must be a list of objects with:

- sample_id
- locus
- h1
- h2
- status
- h1_supporting_genotypes
- h2_supporting_genotypes
- rationale

unresolved must be a list of objects describing sample or locus cases that should not be forced, with:

- sample_id
- locus
- reason
- evidence_summary

Allowed confidence values are "high", "medium", and "low". Allowed status values are "called", "partial", and "unresolved". Use "?" for unresolved haplotype slots.

Input JSON:

```json
{{PROMPT_INPUT_JSON}}
```
