# AI Assistant

## Overview

The Lungfish AI Assistant is a built-in chat interface that helps you explore genome data using natural language. Instead of manually searching menus or typing coordinates, ask questions like "Find all immune-related genes" or "Navigate to BRCA1" and let the AI do the work.

The assistant can:
- **Search** your loaded genome data for genes, variants, and annotations
- **Navigate** the browser to specific genes or genomic regions
- **Analyze** variant statistics and gene details
- **Search PubMed** for relevant scientific literature
- **Answer questions** about what data is loaded and visible

## Setting Up

### Configure an API Key

Before using the AI Assistant, configure at least one AI provider:

1. Open **Lungfish > Settings** (Cmd+,)
2. Go to the **AI Services** tab
3. Choose a provider and enter your API key:
   - **Anthropic Claude** — claude-sonnet-4-5
   - **OpenAI GPT** — gpt-5-mini
   - **Google Gemini** — gemini-2.5-flash
4. Optionally configure fallback providers for redundancy

### Where to Get API Keys

- **Anthropic**: console.anthropic.com
- **OpenAI**: platform.openai.com/api-keys
- **Google AI**: aistudio.google.com/apikey

## Opening the Assistant

Three ways to open the AI Assistant:

1. **Toolbar**: Click the sparkles button
2. **Menu**: View > AI Assistant
3. **Keyboard**: Shift+Cmd+A

The assistant opens as a floating panel that stays visible while you work.

## Example Questions

### Data Exploration
- "What's loaded in my genome bundle?"
- "List all chromosomes and their sizes"
- "How many annotations are on chromosome 1?"

### Gene Search
- "Search for BRCA1 in this genome"
- "Find all kinase genes"
- "What genes are in my current view?"

### Variant Queries
- "Show me variant statistics"
- "Find SNPs on chromosome X"
- "Are there variants in the TP53 gene?"

### Navigation
- "Navigate to the TP53 gene"
- "Go to chr2:50000000-51000000"
- "Take me to the largest chromosome"

### Literature
- "Search PubMed for papers about this organism's evolution"
- "Find recent papers on CRISPR gene editing"

### Combined Queries
- "Find disease genes and check for nearby variants"
- "Search for HOX genes, then navigate to the first one"
- "Find variants near immune genes and search PubMed for relevant papers"

## Available Tools

The assistant has 9 specialized tools:

| Tool | What It Does |
|------|-------------|
| **search_genes** | Find genes by name, symbol, or keyword |
| **search_variants** | Find variants by region, type, or gene proximity |
| **get_variant_statistics** | Get aggregate variant counts and distributions |
| **get_gene_details** | Retrieve detailed gene information (exons, CDS) |
| **get_current_view** | Get the currently visible genomic region |
| **navigate_to_gene** | Jump to a gene's location |
| **navigate_to_region** | Navigate to specific coordinates |
| **list_chromosomes** | List all chromosomes with lengths |
| **search_pubmed** | Search PubMed for scientific papers |

The AI automatically selects and chains these tools based on your question. You don't need to know which tools exist.

## Tips for Better Results

**Be specific about your organism**: "Find HOX genes in this lungfish genome" works better than just "Find HOX genes."

**Ask follow-up questions**: The AI remembers context. Start with "Find genes on chr1" then ask "How many are kinases?"

**Use standard gene symbols**: BRCA1, TP53, APOE work better than full gene names.

**Start broad, then narrow**: "What's loaded?" then "What genes are on chr1?" then "Navigate to the first one."

## Provider Fallback

If your primary provider is unavailable (network issues, rate limits), the assistant automatically falls back to your next configured provider. Configure multiple providers in Settings for uninterrupted access.
