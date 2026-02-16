# Working with VCF Variants

## What are VCF Files?

VCF (Variant Call Format) is the standard file format for genetic variation data. A VCF file records differences between sequenced DNA and a reference genome:

- **SNPs**: Single base changes (e.g., A to G)
- **Insertions**: Added DNA bases
- **Deletions**: Removed DNA bases
- **MNPs**: Multiple adjacent base changes
- **Complex variants**: Combinations of the above

## Importing VCF Data

### During NCBI Genome Download

When creating a new genome bundle from NCBI:

1. Open the **Download Center**
2. Search for your organism and select an assembly
3. Check **Include VCF files** in the download options
4. Click **Download and Build Bundle**

The pipeline automatically:
- Downloads the VCF file
- Parses all variants into a SQLite database
- Maps chromosome names between the VCF and reference genome
- Indexes variants for fast region-based queries

### Chromosome Name Mapping

VCF files may use different chromosome names than the reference genome (e.g., "1" vs. "chr1"). Lungfish automatically resolves this by matching chromosomes with identical lengths, creating aliases so variants display correctly.

## Viewing Variants

### Variant Display

Variants appear as colored markers in the genome viewer:

- **SNPs**: Single-base marks
- **Insertions**: Upward markers
- **Deletions**: Downward markers

Variant visibility adapts to zoom level:
- **Zoomed out**: Variant density bars
- **Medium zoom**: Individual markers visible
- **Zoomed in**: Full variant details with allele information

### Interacting with Variants

- **Hover** over a variant to see position, alleles, type, and quality
- **Click** a variant to center the view and select it in the table

## Searching Variants

### Using the AI Assistant

The AI Assistant provides the most powerful way to search variants. Open it with **Shift+Cmd+A** or the toolbar sparkles button.

**Find variants by type:**
- "Find all SNPs on chromosome 1"
- "Show me deletions in the current view"

**Find variants by region:**
- "What variants are between position 1000000 and 2000000 on chr7?"
- "Find variants in the current view"

**Connect variants to genes:**
- "Are there any variants in the TP53 gene?"
- "Find SNPs within 10 kb of MYC"

### Variant Statistics

Ask the AI: "Show me variant statistics" to get:
- Total variant count across all chromosomes
- Breakdown by type (SNP, insertion, deletion, MNP, complex)
- Variant density per chromosome

## Position Conventions

**Important**: VCF files use 1-based coordinates (the first base is position 1), while Lungfish stores positions internally as 0-based. This conversion is automatic — positions displayed to users follow the 1-based convention that genomicists expect.

## Multi-Allelic Sites

Some positions have multiple alternate alleles (e.g., both A to G and A to T). These are stored with comma-separated alleles in the ALT field (e.g., "G,T").

## Connecting Variants to Genes

A typical workflow for exploring functional variants:

1. **Navigate to a gene**: "Navigate to APOE gene"
2. **Check for variants**: "What variants are in this gene?"
3. **Filter by type**: "Show only SNPs here"
4. **Get literature context**: "Search PubMed for APOE variants"

### Variant Impact

Variants in different gene regions have different potential impacts:
- **Exonic variants**: Within coding regions — potentially highest impact
- **Intronic variants**: Within genes but outside exons
- **Promoter variants**: Upstream of gene start — may affect expression
- **Intergenic variants**: Between genes — regulatory or neutral

## Tips

- Specify chromosome names when searching for faster results
- Use the AI Assistant for complex multi-step queries
- Large VCF files (>1 million variants) may take several minutes to import
- If variants don't appear, check that the bundle includes a variant database
