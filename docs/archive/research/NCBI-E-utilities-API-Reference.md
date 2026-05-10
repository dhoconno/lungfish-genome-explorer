# NCBI Entrez E-utilities API Reference

## Executive Summary

This document provides comprehensive guidance on using NCBI's Entrez Programming Utilities (E-utilities) for programmatic access to three key biological databases: Nucleotide (GenBank), Genome, and sequences from organisms in the Viruses taxonomy. The E-utilities provide a stable, standardized interface for searching, retrieving, and linking biological data across NCBI's 41 Entrez databases.

---

## Table of Contents

1. [E-utilities Overview](#e-utilities-overview)
2. [API Key and Rate Limiting](#api-key-and-rate-limiting)
3. [Database Reference](#database-reference)
   - [Nucleotide Database (nuccore)](#1-nucleotide-database-nuccore)
   - [Genome Database (genome)](#2-genome-database-genome)
   - [Assembly Database (assembly)](#3-assembly-database-assembly)
   - [Accessing Viral Sequences](#4-accessing-viral-sequences)
4. [Core E-utilities](#core-e-utilities)
5. [Best Practices for Bulk Downloads](#best-practices-for-bulk-downloads)
6. [Code Examples](#code-examples)
7. [Troubleshooting](#troubleshooting)

---

## E-utilities Overview

### Base URL

All E-utility requests use the base URL:
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/
```

### Available Utilities

| Utility | Endpoint | Purpose |
|---------|----------|---------|
| **EInfo** | `einfo.fcgi` | Get database statistics and field information |
| **ESearch** | `esearch.fcgi` | Search a database and retrieve UIDs |
| **EFetch** | `efetch.fcgi` | Download full records in specified formats |
| **ESummary** | `esummary.fcgi` | Retrieve document summaries |
| **ELink** | `elink.fcgi` | Find related records across databases |
| **EPost** | `epost.fcgi` | Upload UIDs to History Server |
| **ESpell** | `espell.fcgi` | Get spelling suggestions |
| **EGQuery** | `egquery.fcgi` | Global search across all databases |
| **ECitMatch** | `ecitmatch.cgi` | Match citations to PMIDs |

### Required Parameters for All Requests

Every E-utility request should include:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `tool` | Application name (no spaces) | `tool=lungfish_browser` |
| `email` | Contact email address | `email=developer@example.com` |
| `api_key` | API key for higher rate limits (optional but recommended) | `api_key=ABCD1234...` |

---

## API Key and Rate Limiting

### Rate Limits

| Access Type | Rate Limit | Notes |
|-------------|------------|-------|
| **Without API Key** | 3 requests/second | Per IP address |
| **With API Key** | 10 requests/second | Per API key (shared across all users of that key) |
| **Enhanced Access** | Negotiated | Contact info@ncbi.nlm.nih.gov with justification |

### How to Obtain an API Key

1. Create a free NCBI account at https://www.ncbi.nlm.nih.gov/account/
2. Sign in and click your username in the upper right corner
3. Navigate to **Settings** > **API Key Management**
4. Click **Create an API Key**
5. Copy and securely store the generated key

**Note:** Only one API key is allowed per NCBI account.

### Using the API Key

Add the `api_key` parameter to any E-utility request:

```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=human[orgn]&api_key=YOUR_API_KEY
```

### Recommended Request Timing

| Guideline | Details |
|-----------|---------|
| **Delay Between Requests** | Without API key: 334ms minimum (1/3 second). With API key: 100ms minimum |
| **Large Jobs Timing** | Run between 9:00 PM and 5:00 AM Eastern Time on weekdays, or on weekends |
| **Concurrent Requests** | Allowed, but rate limit applies to request initiation, not execution duration |

### Rate Limit Behavior

- Rate limiting applies when NCBI receives the request, not during execution
- Multiple concurrent requests are permitted if initiation rate stays under the limit
- If limits are exceeded, HTTP 429 errors are returned
- The same API key used from multiple computers shares the rate limit

---

## Database Reference

### 1. Nucleotide Database (nuccore)

The Nucleotide database contains all sequence data from GenBank, EMBL, and DDBJ (members of the International Nucleotide Sequence Databases Collaboration).

#### Database Parameter

```
db=nuccore
```

**Note:** `db=nucleotide` also works and is equivalent to `nuccore`.

#### ESearch Examples

**Basic search:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=human[orgn]+AND+BRCA1[gene]
```

**Search with date range:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=bacteria[orgn]+AND+2024[pdat]
```

**Search by accession:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=NC_000001[accn]
```

#### Key Search Fields

| Field Code | Full Name | Description | Example |
|------------|-----------|-------------|---------|
| `ALL` | All Fields | Searches all indexed terms | `cancer[ALL]` |
| `ACCN` | Accession | Sequence accession number | `NC_000001[ACCN]` |
| `PACC` | Primary Accession | Excludes secondary accessions | `NC_000001[PACC]` |
| `ORGN` | Organism | Scientific/common names, all taxonomy levels | `human[ORGN]` |
| `PORG` | Primary Organism | Primary organism only | `Homo sapiens[PORG]` |
| `GENE` | Gene Name | Gene identifiers | `BRCA1[GENE]` |
| `PROT` | Protein Name | Protein identifiers | `insulin[PROT]` |
| `TITL` | Title | Words in definition line | `chromosome[TITL]` |
| `KYWD` | Keyword | Submitter keywords | `complete genome[KYWD]` |
| `AUTH` | Author | Publication authors | `Smith[AUTH]` |
| `JOUR` | Journal | Journal abbreviations | `Nature[JOUR]` |
| `SLEN` | Sequence Length | Numeric length | `1000:5000[SLEN]` |
| `DIV` | Division | Record division (19 categories) | `PRI[DIV]` (primates) |
| `PDAT` | Publication Date | Submission date | `2024[PDAT]` |
| `MDAT` | Modification Date | Last update | `2024/01:2024/12[MDAT]` |
| `BIOS` | BioSample | Sample identifiers | `SAMN12345678[BIOS]` |
| `GPRJ` | BioProject | Project accession | `PRJNA12345[GPRJ]` |
| `STRN` | Strain | Organism strain | `K-12[STRN]` |
| `ISOL` | Isolate | Isolate identifier | `patient1[ISOL]` |
| `PROP` | Properties | Record properties | `refseq[PROP]` |

#### EFetch: Return Types and Modes

| Format | rettype | retmode | Output |
|--------|---------|---------|--------|
| **FASTA** | `fasta` | `text` | FASTA sequence |
| **TinySeq XML** | `fasta` | `xml` | Minimal XML with sequence |
| **GenBank flat file** | `gb` | `text` | Full GenBank format |
| **GenBank XML** | `gb` | `xml` | GBSeq XML format |
| **GenBank with parts** | `gbwithparts` | `text` | CON records with sequences |
| **Feature table** | `ft` | `text` | Tab-delimited features |
| **CDS FASTA (nucleotide)** | `fasta_cds_na` | `text` | Coding sequences as nucleotides |
| **CDS FASTA (protein)** | `fasta_cds_aa` | `text` | Coding sequences as amino acids |
| **ASN.1 text** | (null) | `text` | Text ASN.1 |
| **ASN.1 binary** | (null) | `asn.1` | Binary ASN.1 |
| **Native XML** | `native` | `xml` | Full XML |
| **Accession list** | `acc` | `text` | Convert GIs to accessions |
| **SeqID list** | `seqid` | `text` | Convert GIs to SeqIDs |

#### EFetch Examples

**Fetch FASTA by accession:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NC_000001&rettype=fasta&retmode=text
```

**Fetch GenBank format:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NC_000001&rettype=gb&retmode=text
```

**Fetch specific region (bases 1000-2000, plus strand):**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NC_000001&rettype=fasta&seq_start=1000&seq_stop=2000&strand=1
```

**Fetch multiple records:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=NC_000001,NC_000002,NC_000003&rettype=fasta
```

#### Sequence-Specific Parameters

| Parameter | Values | Description |
|-----------|--------|-------------|
| `strand` | `1` (plus), `2` (minus) | DNA strand to retrieve |
| `seq_start` | integer | Start coordinate (1-based) |
| `seq_stop` | integer | End coordinate |
| `complexity` | `0-4` | Blob content level |

---

### 2. Genome Database (genome)

**Important Note:** The Entrez Genome database has been redesigned. Records now correspond to species rather than individual chromosome sequences. **EFetch no longer supports direct retrievals from the genome database** (`db=genome`). Use ESummary for metadata or link to nuccore/assembly for sequence data.

#### Database Parameter

```
db=genome
```

#### ESearch Examples

**Search by organism:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=genome&term=Escherichia+coli[orgn]
```

**Search by project type:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=genome&term=bacteria[orgn]+AND+complete[PRJT]
```

#### Key Search Fields

| Field Code | Full Name | Description | Example |
|------------|-----------|-------------|---------|
| `ALL` | All Fields | All searchable terms | `human[ALL]` |
| `ORGN` | Organism | Taxonomy classification | `Homo sapiens[ORGN]` |
| `PRJA` | Project Accession | BioProject accession | `PRJNA12345[PRJA]` |
| `PRJT` | Project Type | Project category | `complete[PRJT]` |
| `DFLN` | Title | Brief description | `chromosome[DFLN]` |
| `DSCR` | Description | Full description | `reference genome[DSCR]` |
| `STAT` | Status | BioProject status | `live[STAT]` |
| `AID` | AssemblyID | Assembly release ID | - |
| `AACC` | Assembly Accession | Full assembly accession | `GCF_000001405[AACC]` |
| `ANAM` | Assembly Name | Assembly name | `GRCh38[ANAM]` |
| `ACCN` | Replicon Accession | Replicon sequence code | - |
| `GENE` | Gene Name | Gene identifiers | `BRCA1[GENE]` |
| `WGSP` | WGS Prefix | Whole genome shotgun prefix | - |
| `STRN` | Strain | Organism strain | `K-12[STRN]` |
| `HOST` | Host | Host organism | `human[HOST]` |

#### Retrieving Genome Data

Since EFetch does not support direct genome retrieval, use this workflow:

1. **Search genome database:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=genome&term=Homo+sapiens[orgn]
```

2. **Get summary (ESummary):**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=genome&id=GENOME_ID
```

3. **Link to assembly or nuccore:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=genome&db=assembly&id=GENOME_ID
```

4. **Fetch sequences from assembly/nuccore:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=LINKED_IDS&rettype=fasta
```

---

### 3. Assembly Database (assembly)

The Assembly database provides access to genome assembly metadata and links to sequence data.

#### Database Parameter

```
db=assembly
```

#### ESearch Examples

**Search by organism:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=assembly&term=Homo+sapiens[ORGN]
```

**Search RefSeq assemblies:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=assembly&term=bacteria[ORGN]+AND+refseq[FILT]
```

**Search by assembly level:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=assembly&term=human[ORGN]+AND+chromosome[ASLV]
```

#### Key Search Fields

| Field Code | Full Name | Description | Example |
|------------|-----------|-------------|---------|
| `ALL` | All Fields | All searchable terms | `human[ALL]` |
| `ASAC` | Assembly Accession | Assembly accession (with/without version) | `GCF_000001405[ASAC]` |
| `ASLV` | Assembly Level | Contig, Scaffold, Chromosome, Complete | `chromosome[ASLV]` |
| `TXID` | Taxonomy ID | NCBI Taxonomy ID | `9606[TXID]` |
| `ORGN` | Organism | Organism names (exploded) | `Homo sapiens[ORGN]` |
| `NAME` | Assembly Name | Assembly name | `GRCh38[NAME]` |
| `DESC` | Description | Assembly description | `primary[DESC]` |
| `COV` | Coverage | Sequencing coverage | `30:100[COV]` |
| `TYPE` | Type | Assembly type | `haploid[TYPE]` |
| `LEN` | Total Length | Genome length in Mbp | `3000:4000[LEN]` |
| `REPL` | Chromosomes | Number of chromosomes | `24[REPL]` |
| `CN50` | Contig N50 | Contig N50 metric | - |
| `SN50` | Scaffold N50 | Scaffold N50 metric | - |
| `INFR` | Infraspecific Name | Strain, breed, cultivar | `K-12[INFR]` |
| `ISOL` | Isolate | Isolate name | - |
| `TECH` | Sequencing Tech | Technology used | `Illumina[TECH]` |
| `FILT` | Filter | Result filters | `refseq[FILT]` |

#### Linking Assembly to Sequences

**Link to RefSeq nucleotide sequences:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=assembly&db=nuccore&id=ASSEMBLY_ID&linkname=assembly_nuccore_refseq
```

**Link to GenBank nucleotide sequences:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=assembly&db=nuccore&id=ASSEMBLY_ID&linkname=assembly_nuccore_insdc
```

---

### 4. Accessing Viral Sequences

**Important Note:** NCBI Virus is a specialized portal for searching viral sequences, but it does not have a dedicated E-utilities database. Viral sequences are accessed through the **nuccore** (Nucleotide) database using taxonomy-based filtering.

#### Taxonomy Information

- **Taxonomy ID for all Viruses:** `10239` (txid10239)
- **Rank:** Superkingdom (Acellular root)
- **Nucleotide sequences available:** ~14.8 million
- **Protein sequences available:** ~64.6 million

#### Searching Viral Sequences

**All viral nucleotide sequences:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=txid10239[orgn]
```

**Specific virus family (e.g., Coronaviridae):**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=Coronaviridae[orgn]
```

**Complete viral genomes:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=txid10239[orgn]+AND+complete+genome[title]
```

**RefSeq viral sequences:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=txid10239[orgn]+AND+refseq[filter]
```

**Viral sequences by host:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=txid10239[orgn]+AND+human[host]
```

#### Fetching Viral Sequences

Use standard nuccore EFetch calls after obtaining IDs:

```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=VIRAL_IDS&rettype=fasta&retmode=text
```

```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=VIRAL_IDS&rettype=gb&retmode=text
```

#### Alternative: NCBI Virus Portal

For interactive access with specialized filtering, use the NCBI Virus portal:
- URL: https://www.ncbi.nlm.nih.gov/labs/virus/vssi/
- Supports virus-specific searches, BLAST, and curated collections
- Download capability through the web interface

---

## Core E-utilities

### ESearch - Database Searching

**Endpoint:** `esearch.fcgi`

**Purpose:** Search an Entrez database and retrieve matching UIDs.

#### Key Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `db` | Yes | pubmed | Target database |
| `term` | Yes | - | Search query (URL-encoded) |
| `retmax` | No | 20 | Maximum records to return (max 10,000) |
| `retstart` | No | 0 | Starting index for pagination |
| `usehistory` | No | n | Set to `y` to store results on History Server |
| `sort` | No | - | Sort order (database-specific) |
| `field` | No | - | Limit entire query to specific field |
| `datetype` | No | - | Date type (pdat, mdat, edat) |
| `reldate` | No | - | Results within N days |
| `mindate` | No | - | Start date (YYYY/MM/DD) |
| `maxdate` | No | - | End date (YYYY/MM/DD) |

#### Response Format

```xml
<?xml version="1.0" encoding="UTF-8"?>
<eSearchResult>
  <Count>1234</Count>
  <RetMax>20</RetMax>
  <RetStart>0</RetStart>
  <IdList>
    <Id>12345678</Id>
    <Id>12345679</Id>
    <!-- ... more IDs ... -->
  </IdList>
  <QueryKey>1</QueryKey>
  <WebEnv>MCID_...</WebEnv>
</eSearchResult>
```

---

### EFetch - Record Retrieval

**Endpoint:** `efetch.fcgi`

**Purpose:** Download full records in specified formats.

#### Key Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `db` | Yes | - | Source database |
| `id` | Yes* | - | Comma-separated UID list |
| `query_key` | Yes* | - | Query key from History Server |
| `WebEnv` | Yes* | - | Web environment from History Server |
| `rettype` | No | - | Record format type |
| `retmode` | No | xml | Output mode (text, xml, json) |
| `retstart` | No | 0 | Starting index |
| `retmax` | No | 20 | Maximum records (max 10,000) |

*Either `id` or `query_key`+`WebEnv` is required.

---

### EPost - Upload UIDs

**Endpoint:** `epost.fcgi`

**Purpose:** Upload a list of UIDs to the History Server.

#### Key Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `db` | Yes | Database name |
| `id` | Yes | Comma-separated UID list |
| `WebEnv` | No | Existing web environment to append to |

#### Response Format

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ePostResult>
  <QueryKey>1</QueryKey>
  <WebEnv>MCID_...</WebEnv>
</ePostResult>
```

---

### ELink - Cross-Database Linking

**Endpoint:** `elink.fcgi`

**Purpose:** Find related records in the same or different databases.

#### Key Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `dbfrom` | Yes | Source database |
| `db` | Yes | Target database(s), comma-separated |
| `id` | Yes* | UID list |
| `cmd` | No | Command mode (neighbor, neighbor_history, etc.) |
| `linkname` | No | Specific link to use |

#### Common Link Names

| Link Name | Description |
|-----------|-------------|
| `assembly_nuccore_refseq` | Assembly to RefSeq nucleotide |
| `assembly_nuccore_insdc` | Assembly to GenBank nucleotide |
| `genome_nuccore` | Genome to nucleotide sequences |
| `nuccore_protein` | Nucleotide to protein |
| `nuccore_gene` | Nucleotide to gene records |

---

### ESummary - Document Summaries

**Endpoint:** `esummary.fcgi`

**Purpose:** Retrieve brief summaries (DocSums) for records.

#### Key Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `db` | Yes | Database name |
| `id` | Yes* | UID list or use query_key+WebEnv |
| `version` | No | Set to `2.0` for enhanced XML |

---

### EInfo - Database Information

**Endpoint:** `einfo.fcgi`

**Purpose:** Get database statistics and available search fields.

#### Usage

**List all databases:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/einfo.fcgi
```

**Get fields for specific database:**
```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/einfo.fcgi?db=nuccore
```

---

## Best Practices for Bulk Downloads

### 1. Use the History Server

For large result sets, always use the History Server to avoid re-transmitting UIDs:

```
# Step 1: Search and store on History Server
esearch.fcgi?db=nuccore&term=bacteria[orgn]&usehistory=y

# Step 2: Parse WebEnv and QueryKey from response

# Step 3: Fetch in batches using History Server
efetch.fcgi?db=nuccore&query_key=1&WebEnv=MCID_...&rettype=fasta&retstart=0&retmax=500
efetch.fcgi?db=nuccore&query_key=1&WebEnv=MCID_...&rettype=fasta&retstart=500&retmax=500
# ... continue until all records retrieved
```

### 2. Batch Size Recommendations

| Operation | Recommended Batch Size | Maximum |
|-----------|------------------------|---------|
| ESearch UIDs | - | 100,000 per request |
| EFetch records | 500 | 10,000 per request |
| ESummary records | 500 | 10,000 per request |
| EPost UIDs | 5,000 | No hard limit, use POST method |

### 3. Pagination Strategy

```python
# Pseudocode for paginated retrieval
total_count = get_count_from_esearch()
batch_size = 500
for start in range(0, total_count, batch_size):
    efetch(retstart=start, retmax=batch_size)
    sleep(0.1)  # 100ms delay with API key
```

### 4. HTTP POST for Large Requests

When sending more than 200 UIDs, use HTTP POST instead of GET:

```python
import requests

url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
data = {
    "db": "nuccore",
    "id": ",".join(uid_list),  # Large list of UIDs
    "rettype": "fasta",
    "retmode": "text",
    "api_key": "YOUR_API_KEY"
}
response = requests.post(url, data=data)
```

### 5. Maintain Web Environment

For multi-step operations, always pass the WebEnv to maintain context:

```
# First call creates WebEnv
esearch.fcgi?db=nuccore&term=human[orgn]&usehistory=y
# Returns WebEnv=MCID_abc123

# Second call uses same WebEnv
elink.fcgi?dbfrom=nuccore&db=protein&query_key=1&WebEnv=MCID_abc123&cmd=neighbor_history
# Returns new QueryKey in same WebEnv

# Third call retrieves from History
efetch.fcgi?db=protein&query_key=2&WebEnv=MCID_abc123&rettype=fasta
```

### 6. Timing Guidelines

| Time Period | Recommendation |
|-------------|----------------|
| Weekdays 5AM-9PM ET | Limit large jobs, use minimal batch sizes |
| Weekdays 9PM-5AM ET | Preferred for large downloads |
| Weekends | Preferred for large downloads |

---

## Code Examples

### Python: Search and Fetch Nucleotide Sequences

```python
import requests
import time
import xml.etree.ElementTree as ET

BASE_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
API_KEY = "YOUR_API_KEY"
EMAIL = "your.email@example.com"

def search_nuccore(query, max_results=100):
    """Search nucleotide database and return UIDs."""
    params = {
        "db": "nuccore",
        "term": query,
        "retmax": max_results,
        "usehistory": "y",
        "api_key": API_KEY,
        "email": EMAIL,
        "tool": "lungfish_browser"
    }
    response = requests.get(f"{BASE_URL}esearch.fcgi", params=params)
    root = ET.fromstring(response.text)

    return {
        "count": int(root.find("Count").text),
        "webenv": root.find("WebEnv").text,
        "query_key": root.find("QueryKey").text,
        "ids": [id_elem.text for id_elem in root.findall(".//Id")]
    }

def fetch_sequences(webenv, query_key, rettype="fasta", batch_size=500):
    """Fetch sequences using History Server in batches."""
    sequences = []
    start = 0

    while True:
        params = {
            "db": "nuccore",
            "query_key": query_key,
            "WebEnv": webenv,
            "rettype": rettype,
            "retmode": "text",
            "retstart": start,
            "retmax": batch_size,
            "api_key": API_KEY,
            "email": EMAIL,
            "tool": "lungfish_browser"
        }
        response = requests.get(f"{BASE_URL}efetch.fcgi", params=params)

        if not response.text.strip():
            break

        sequences.append(response.text)
        start += batch_size
        time.sleep(0.1)  # Rate limiting delay

    return "".join(sequences)

# Example usage
result = search_nuccore("human[orgn] AND BRCA1[gene] AND refseq[filter]")
print(f"Found {result['count']} sequences")

sequences = fetch_sequences(result["webenv"], result["query_key"])
print(sequences[:1000])  # Print first 1000 characters
```

### Python: Fetch by Accession List

```python
def fetch_by_accessions(accessions, rettype="gb"):
    """Fetch records by accession numbers."""
    # Use POST for large lists
    data = {
        "db": "nuccore",
        "id": ",".join(accessions),
        "rettype": rettype,
        "retmode": "text",
        "api_key": API_KEY,
        "email": EMAIL,
        "tool": "lungfish_browser"
    }

    response = requests.post(f"{BASE_URL}efetch.fcgi", data=data)
    return response.text

# Example
accessions = ["NC_000001.11", "NC_000002.12", "NC_000003.12"]
genbank_records = fetch_by_accessions(accessions)
```

### Python: Cross-Database Linking

```python
def get_proteins_from_nucleotide(nuc_id):
    """Get protein sequences linked to a nucleotide record."""
    # Step 1: Link nucleotide to protein
    params = {
        "dbfrom": "nuccore",
        "db": "protein",
        "id": nuc_id,
        "cmd": "neighbor_history",
        "api_key": API_KEY,
        "email": EMAIL
    }
    response = requests.get(f"{BASE_URL}elink.fcgi", params=params)
    root = ET.fromstring(response.text)

    webenv = root.find(".//WebEnv").text
    query_key = root.find(".//QueryKey").text

    # Step 2: Fetch protein sequences
    params = {
        "db": "protein",
        "query_key": query_key,
        "WebEnv": webenv,
        "rettype": "fasta",
        "retmode": "text",
        "api_key": API_KEY,
        "email": EMAIL
    }
    response = requests.get(f"{BASE_URL}efetch.fcgi", params=params)
    return response.text
```

### Command Line (EDirect)

If you have NCBI EDirect tools installed:

```bash
# Search and fetch FASTA
esearch -db nuccore -query "human[orgn] AND BRCA1[gene]" | \
  efetch -format fasta > brca1_sequences.fasta

# Search and fetch GenBank format
esearch -db nuccore -query "NC_000001[accn]" | \
  efetch -format gb > chromosome1.gb

# Link assembly to nucleotide and fetch
esearch -db assembly -query "GCF_000001405.40" | \
  elink -target nuccore -name assembly_nuccore_refseq | \
  efetch -format fasta > grch38_sequences.fasta

# Fetch viral sequences
esearch -db nuccore -query "txid10239[orgn] AND complete genome[title] AND refseq[filter]" | \
  efetch -format fasta > viral_genomes.fasta
```

---

## Troubleshooting

### Common HTTP Error Codes

| Code | Meaning | Solution |
|------|---------|----------|
| 400 | Bad Request | Check parameter syntax and encoding |
| 429 | Too Many Requests | Reduce request rate, use API key |
| 500 | Server Error | Retry after delay |
| 502 | Bad Gateway | NCBI server issue, retry later |

### Common Issues

**Issue: Empty results from EFetch**
- Verify UIDs exist and are valid for the database
- Check that rettype/retmode combination is supported

**Issue: Rate limit errors (429)**
- Add delays between requests (100ms with API key, 334ms without)
- Use History Server to reduce request count
- Run large jobs during off-peak hours

**Issue: Partial results**
- Check `Count` in ESearch response vs. actual results
- Implement pagination with retstart/retmax
- Verify retmax doesn't exceed 10,000

**Issue: WebEnv expired**
- Web environments expire after a period of inactivity
- Re-run the initial search to get a fresh WebEnv

---

## References

### Official NCBI Documentation

- [E-utilities Quick Start](https://www.ncbi.nlm.nih.gov/books/NBK25500/)
- [E-utilities In-Depth Parameters Guide](https://www.ncbi.nlm.nih.gov/books/NBK25499/)
- [E-utilities General Introduction](https://www.ncbi.nlm.nih.gov/books/NBK25497/)
- [E-utilities Sample Applications](https://www.ncbi.nlm.nih.gov/books/NBK25498/)
- [Entrez Direct (EDirect) Command Line Tools](https://www.ncbi.nlm.nih.gov/books/NBK179288/)

### API Key Information

- [New API Keys for E-utilities (NCBI Insights)](https://ncbiinsights.ncbi.nlm.nih.gov/2017/11/02/new-api-keys-for-the-e-utilities/)
- [Enhanced API Key Requests](https://support.nlm.nih.gov/kbArticle/?pn=KA-05318)

### Database-Specific Resources

- [NCBI Taxonomy Browser](https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi)
- [Nucleotide Database Advanced Search](https://www.ncbi.nlm.nih.gov/nuccore/advanced)
- [NCBI Virus Portal](https://www.ncbi.nlm.nih.gov/labs/virus/vssi/)
- [RefSeq Database](https://www.ncbi.nlm.nih.gov/refseq/)

### Additional Tools

- [Biopython Entrez Module](https://biopython.org/docs/dev/Tutorial/chapter_entrez.html)
- [NCBI Datasets](https://www.ncbi.nlm.nih.gov/datasets/) - Modern alternative for genome downloads

---

*Document generated: 2026-02-02*
*Based on NCBI E-utilities documentation and best practices*
