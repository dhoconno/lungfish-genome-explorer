# Add GFF3 support to `lungfish fetch ncbi --fetch-format`

**Severity:** blocks the documentation rewrite for `05-variants/01-calling-variants-from-amplicons`
**Component:** `Sources/LungfishCLI/Commands/FetchCommand.swift`
**Filed:** 2026-05-09 by the documentation effort

## Problem

The pilot variants chapter (`docs/user-manual/chapters/04-variants/01-reads-to-variants.md`,
moving to `05-variants/01-calling-variants-from-amplicons`) needs to teach the
reader to download a SARS-CoV-2 reference and its annotations together, and
attach them to a Lungfish reference bundle so that the iVar codon-merge
behaviour can be demonstrated against a real GFF3.

Today's options are all unsatisfying:

1. `lungfish fetch ncbi MN908947.3 --fetch-format genbank` — works, returns
   an annotated GenBank record. But `lungfish bundle create` does not
   accept a GenBank input directly; it takes `--fasta` plus optional
   `--annotation` files. So GenBank → bundle still needs a separate
   conversion step that the chapter has to teach.
2. `lungfish fetch genome GCF_009858895.2` — downloads FASTA + GFF3
   together via NCBI Datasets, but it switches the chromosome ID from
   `MN908947.3` (GenBank, the field-canonical accession in published
   SARS-CoV-2 work) to `NC_045512.2` (RefSeq). Every external reference,
   primer scheme coordinate set, and published variant table is keyed on
   `MN908947.3`, so switching the fixture's reference ID has cascading
   consequences for the chapter and for tool compatibility.
3. Telling the reader to `curl` the GFF3 from NCBI manually — breaks the
   chapter's "everything happens through Lungfish" framing and bypasses
   provenance tracking.

The right product fix is to let `fetch ncbi` return GFF3 for nucleotide
accessions, which NCBI's E-utilities already serves natively.

## What `fetch ncbi` accepts today

`Sources/LungfishCLI/Commands/FetchCommand.swift` line 91-100:

```swift
switch fetchFormat.lowercased() {
case "genbank", "gb":
    ncbiFormat = .genbank
case "fasta", "fa":
    ncbiFormat = .fasta
case "xml":
    ncbiFormat = .xml
default:
    throw CLIError.unsupportedFormat(format: fetchFormat)
}
```

## Proposed change

Add GFF3 as a `--fetch-format` value, and wire it through to the existing
NCBI fetch infrastructure.

### CLI surface

```bash
# New: download annotation as GFF3
lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to MN908947.3.gff3

# Existing: still works
lungfish fetch ncbi MN908947.3 --fetch-format fasta --save-to MN908947.3.fasta
lungfish fetch ncbi MN908947.3 --fetch-format genbank --save-to MN908947.3.gb
```

Acceptance: passing `--fetch-format gff3` (or `gff`) for a nucleotide
accession returns a valid GFF3 file that `lungfish bundle create
--annotation` accepts.

### How NCBI serves it

NCBI E-utilities returns GFF3 from the `nuccore` (a.k.a. nucleotide)
database via `efetch` with `rettype=gff3`. Example URL:

```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=MN908947.3&rettype=gff3&retmode=text
```

This returns the same annotation set that the GenBank record carries,
emitted as GFF3. No additional API key, rate-limit class, or auth needed
beyond what the existing `fetch ncbi` paths use.

### Implementation sketch

1. Add `case .gff3` to whatever enum represents `NCBIFormat` (or extend
   the string-to-format mapping at line 91-100).
2. Add the `gff3` and `gff` aliases to the `fetchFormat.lowercased()`
   switch.
3. Extend the `fileFormat(forFetchFormat:)` helper at line 328 so saved
   files get a `.gff3` extension and the right MIME / `FileFormat`
   classification.
4. Confirm whether the existing NCBI fetcher can pass `rettype=gff3` to
   `efetch` directly. If the fetcher today is hardcoded to text/FASTA/GB,
   teach it the GFF3 rettype the same way it knows about XML.
5. Provenance sidecar (`Sources/LungfishWorkflow/Provenance/...`):
   record the resolved fetch format and the output checksum, same as
   the existing FASTA / GenBank paths.

### Edge cases to handle

- **Empty GFF3.** Some accessions (raw sequencing reads, short
  oligos) do not have annotations and NCBI returns just the GFF3
  header. The CLI should succeed but warn that no features were
  returned, so the chapter can teach this honestly.
- **Multi-accession fetches.** `fetch ncbi A B C --fetch-format gff3
  --save-to combined.gff3` should concatenate as the FASTA path does
  today, with a comment header separating each accession's records.
- **`bundle create` accepting the result.** Confirm `lungfish bundle
  create --fasta foo.fasta --annotation foo.gff3` still works with
  the GFF3 produced by this path. (It accepts GFF3 today via the
  `--annotation` flag, so the format must round-trip cleanly through
  whatever annotation parser the bundle creator uses.)

### Tests to add

Mirror the existing `FetchNCBIProvenanceTests`:

- `FetchNCBIGFF3Tests`:
  - `testFetchSARSGFF3Succeeds` — fetch `MN908947.3` GFF3, assert
    file is non-empty, parses as valid GFF3 (header `##gff-version 3`,
    at least one feature row).
  - `testFetchGFF3SidecarRecordsFormat` — provenance sidecar records
    `--fetch-format gff3`, output checksum and size, and the resolved
    NCBI URL with `rettype=gff3`.
  - `testFetchEmptyGFF3WarnsButSucceeds` — fetch an accession known
    to have no features, assert exit 0 with a warning on stderr.
  - `testBundleCreateRoundtrip` — fetch a SARS-CoV-2 GFF3, pass it
    to `bundle create --annotation`, assert the bundle's manifest
    records the annotation track.

## Why this matters for the documentation

The pilot chapter teaches "from accession to annotated bundle to VCF" as
a single coherent procedure. The codon-merging behaviour at SARS-CoV-2
N-gene position 28881 only fires when the bundle has annotations
attached. Without GFF3 support in `fetch ncbi`, the chapter has to
either:

- skip the annotation step (and the codon teaching moment disappears,
  which the focus groups identified as the chapter's strongest
  pedagogical hook), or
- ship `MN908947.3.gff3` as a static file the reader does not download
  (which breaks the "every step happens through Lungfish" goal and means
  the chapter cannot be reproduced from scratch by a fresh reader), or
- swap the canonical reference to `NC_045512.2` (which breaks
  compatibility with the QIASeqDIRECT-SARS2 primer scheme that ships
  with Lungfish, which is keyed on `MN908947.3`).

Adding GFF3 to `fetch ncbi` resolves the chapter's blocker cleanly, and
opens the same capability to every other chapter that wants to teach
"reference + annotations" workflows for any organism with a GenBank-style
nucleotide record.

## Acceptance criteria

- [ ] `lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to
  MN908947.3.gff3` writes a valid GFF3 file.
- [ ] `gff` is accepted as an alias for `gff3`.
- [ ] Provenance sidecar records the format and output checksum.
- [ ] `lungfish bundle create --fasta MN908947.3.fasta --annotation
  MN908947.3.gff3 --name MN908947.3 --output-dir ./` produces a bundle
  whose manifest lists at least one annotation track.
- [ ] `lungfish variants call` against that bundle's BAM produces a
  codon-merged iVar VCF (the N-gene 28881-28883 trio collapses into
  one row).
- [ ] Tests in `FetchNCBIGFF3Tests` pass.
- [ ] `docs/user-manual/fixtures/sarscov2-srr36291587/regenerate.sh`
  is updated to fetch the GFF3 and pass it to `bundle create`.

## Out of scope

- GFF3 fetch from EBI / Ensembl alternates. Same `fetch ncbi`
  command, NCBI source only. EBI/Ensembl can be a separate ticket.
- GenBank → GFF3 conversion locally. The chapter relies on NCBI's
  pre-rendered GFF3, not on Lungfish synthesizing one from a `.gb`.
- `lungfish fetch genome` already does FASTA + GFF3 for assembly
  accessions; this ticket extends `fetch ncbi` to nucleotide
  accessions so we are not forced to switch reference IDs.
