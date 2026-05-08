---
title: Lungfish User Manual
---

# Hello, Lungfish

Welcome to the user manual. This page exists to prove the Material theme is
wired to the Lungfish brand tokens: Cream background, Deep Ink text,
Creamsicle H1 bar, Space Grotesk headings, Inter body, IBM Plex Mono code.

## What you will find here

The manual is organised into three parts: **Foundations** (file formats and
concepts), **Working with the app** (Sequences, Alignments, Variants,
Classification, Assembly, Downloads), and **Reference** (keyboard map,
troubleshooting, glossary, appendices).

## Variants

- [From Reads to Variants](chapters/04-variants/01-reads-to-variants.md). End-to-end SARS-CoV-2 workflow from NCBI accession through two side-by-side variant tracks.

## A code sample, for font verification

```python
def read_fastq(path):
    """Stream records from a FASTQ file."""
    with open(path) as f:
        yield from parse(f)
```

Tagline: *Seeing the invisible. Informing action.*
