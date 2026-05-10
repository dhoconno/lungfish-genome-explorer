# Bioinformatics Domain Expert Review — 2026-03-21

## Executive Summary
The Lungfish codebase demonstrates strong software engineering with thoughtful concurrency design, well-documented coordinate conventions, and solid coverage of core genomic data types. However, several findings range from scientifically impactful issues in the translation engine and variant model to missing features that bioinformaticians would expect.

---

## 1. DATA MODEL CORRECTNESS

### 1.1 Coordinate system — CORRECT
- Consistently uses 0-based half-open intervals internally (BED convention)
- VCF 1-based positions correctly converted via `zeroBasedStart`/`zeroBasedEnd`
- GFF3 1-based correctly converted on read/write
- **No action needed**

### 1.2 VCFVariant model duplication — HIGH
- **Files**: `LungfishCore/Models/VariantTrack.swift` + `LungfishIO/Formats/VCF/VCFReader.swift`
- Two distinct `VCFVariant` types with incompatible schemas (UUID vs String IDs, `reference` vs `ref`, `sampleData` dict vs structured `VCFGenotype`)
- Core model loses structured genotype info (phasing, hom/het classification)
- **Fix**: Consolidate into single type in Core with IO's richer genotype model

### 1.3 VCF coordinates — CORRECT (no bug after analysis)

### 1.4 Multi-allelic variant misclassification — MEDIUM
- **File**: `VariantTrack.swift:143-159`
- `variantType` only examines first ALT allele; mixed-type multi-allelic sites misclassified
- **Fix**: Check all alternates, classify mixed types as `complex`

### 1.5 Missing AnnotationType cases — MEDIUM
- Missing: `tRNA`, `rRNA`, `pseudogene`, `mobile_element` (mapped to `.region` fallback)
- **Fix**: Add at least tRNA, rRNA, pseudogene, mobile_element as distinct cases

### 1.6 AlignedRead lacks barcode/UMI tags — MEDIUM
- No `BC`, `RX`/`OX`, `CB`, `CR`/`CY` tag parsing
- **Fix**: Add optional barcode/UMI fields, parse in SAMParser

---

## 2. FILE FORMAT HANDLING

### 2.1 FASTAReader loads entire file into memory — HIGH
- `parseFile()` calls `handle.readToEnd()` — 3.2GB human genome needs ~6.4GB RAM
- **Fix**: Use `url.lines` async sequence (like VCF/GFF3 readers already do)

### 2.2 GFF3 multi-parent attributes not split — MEDIUM
- `Parent=mRNA1,mRNA2` stored as single string, breaks alternative splicing representation
- **Fix**: Split comma-separated attribute values

### 2.3 No GTF format support — HIGH
- GTF (GFF2) is extremely common (GENCODE, Ensembl) with different delimiter syntax
- **Fix**: Add GTF reader or auto-detect in GFF3Reader

### 2.4 VCF reader doesn't handle bgzipped files — HIGH
- Most production VCFs are `.vcf.gz` + tabix-indexed
- **Fix**: Add bgzip decompression or shell to `bcftools view`

### 2.5 GenBank qualifier continuation missing spaces — LOW
- Multi-line `/note` qualifiers concatenated without whitespace
- **Fix**: Add space between continuation lines for non-translation qualifiers

### 2.6 BED toAnnotation() missing chromosome field — MEDIUM
- `chrom` available but not passed to SequenceAnnotation
- **Fix**: Add `chromosome: chrom` to initializer call

---

## 3. PIPELINE ARCHITECTURE

### 3.1 SPAdes defaults — CORRECT (solid bioinformatics defaults)

### 3.2 SPAdes --careful/--isolate conflict — MEDIUM
- No validation preventing incompatible flag combination
- **Fix**: Add validation in `validateInputs()`; note SPAdes 4.0 deprecated --careful

### 3.3 Demultiplexing pipeline — EXCELLENT (no issues)

---

## 4. CLI DESIGN

### 4.1 Missing critical CLI commands — HIGH
Missing: `view`, `index`, `translate`, `search`, `extract`, `orf`, `restriction`, `align`, `diff`
- **Fix**: At minimum add `translate`, `extract`, `search` exposing existing plugins

### 4.2 Missing assembly stats (N90, L50, L90) — LOW

### 4.3 Convert command missing BED/VCF/GFF3 input — MEDIUM

---

## 5. SCIENTIFIC ACCURACY

### 5.1 Only 4 of 33 NCBI genetic codes — MEDIUM
- Missing tables 4-6, 12, 13 important for parasitology/vector biology
- **Fix**: Add at least tables 4, 5, 6, 12, 13

### 5.2 Yeast mitochondrial code missing ATA=Met — CRITICAL
- **File**: `CodonTable.swift:124-132`
- ATA should encode Met in yeast mitochondria, currently mistranslated as Ile
- **Fix**: Add `table["ATA"] = "M"` to `yeastMitoTranslations`

### 5.3 Oversimplified molecular weight — LOW
### 5.4 Wallace Tm only (no nearest-neighbor) — LOW
### 5.5 isPalindromic ignores IUPAC codes — LOW
### 5.6 Only 16 restriction enzymes — MEDIUM
### 5.7 ORF finder reports overlapping ORFs — LOW

---

## 6. PLUGIN SYSTEM

### 6.1 Duplicate Strand/SequenceAlphabet types — HIGH
- LungfishPlugin defines own types with different raw values and missing IUPAC support
- **Fix**: Import and re-export Core types, remove duplicates

### 6.2 Missing plugins — MEDIUM
- Priority additions: Primer Design, CpG Island Finder, BLAST Integration

### 6.3 No progress/cancellation in plugin API — LOW

---

## PRIORITY SUMMARY

| Priority | Count | Key Items |
|----------|-------|-----------|
| **Critical** | 1 | Yeast mito codon table (5.2) |
| **High** | 6 | FASTA memory (2.1), GTF support (2.3), bgzip VCF (2.4), VCFVariant duplication (1.2), CLI commands (4.1), Plugin type duplication (6.1) |
| **Medium** | 9 | Multi-allelic (1.4), annotation types (1.5), barcode tags (1.6), GFF3 multi-parent (2.2), BED chromosome (2.6), SPAdes validation (3.2), convert formats (4.3), genetic codes (5.1), restriction DB (5.6) |
| **Low** | 7 | GenBank spaces (2.5), assembly stats (4.2), mol weight (5.3), Tm (5.4), IUPAC palindrome (5.5), ORF overlap (5.7), plugin progress (6.3) |
