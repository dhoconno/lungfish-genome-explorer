# Getting Started with Lungfish Genome Browser

Welcome to Lungfish, a native macOS application for visualizing and exploring genomic data. This guide will help you get up and running quickly.

## System Requirements

- macOS 26 (Tahoe) or later
- Internet connection for downloading reference genomes from NCBI

## First Launch

When you open Lungfish, you will see a clean interface with:

- **Toolbar**: Quick access to common actions including the Download Center
- **Sidebar**: Chromosome list (visible once a bundle is loaded)
- **Main Viewer**: The genome visualization area
- **Status Bar**: Current bundle and position information

The app is built around **genome bundles** — self-contained packages that include a reference genome sequence, annotations (genes, transcripts, exons), and optionally variant data (SNPs, indels).

## Opening an Existing Bundle

If you already have a `.lungfish` or `.lungfishbundle` file:

1. Choose **File > Open** (Cmd+O)
2. Navigate to your bundle file
3. Click **Open**

The viewer loads with:
- A **chromosome sidebar** listing all chromosomes/contigs
- The **main viewer** showing the selected chromosome
- A **coordinate toolbar** displaying your current position and zoom level

## Creating a New Bundle from NCBI

Lungfish can download and process reference genomes directly from NCBI. This is the recommended way to start with a new organism.

### Step 1: Open the Download Center

Click the **Download Center** button in the toolbar, or choose **File > Download Center**.

### Step 2: Search for a Genome

1. Select the **Genome Download** tab
2. Enter an organism name (e.g., "mouse", "human", "rhesus macaque")
3. Click **Search** or press Enter

Results display matching assemblies with:
- Scientific name and common name
- Assembly accession (e.g., GCF_000001405.40)
- Assembly name, release date, and total size

### Step 3: Download and Build

1. Select an assembly from the results
2. Click **Download Genome**
3. Choose components to include:
   - **FASTA sequence** (required) — the reference genome
   - **GFF3 annotations** (recommended) — gene features, exons, transcripts
   - **VCF variants** (optional) — known genetic variants
4. Choose a destination folder
5. Click **Start Download**

The build process:
- Compresses the genome with bgzip and creates a `.fai` index
- Converts GFF3 annotations to BigBed format for fast random access
- Creates a SQLite database for instant annotation search
- Parses VCF variants into a searchable database (if included)
- Packages everything into a single `.lungfish` bundle

Build times vary by genome size — typically 5-15 minutes.

### Step 4: Open Your Bundle

Once the build completes, click **Open Bundle** to start exploring.

## Navigating the Genome

### Chromosome Sidebar

- **Click any chromosome** to jump to it at full zoom-out
- **Search bar** at top to filter chromosomes by name
- **Sort**: By name, size, or original order
- **Filter**: Show or hide unplaced contigs and scaffolds

### Coordinate Toolbar

The toolbar shows your current position and zoom level:

- **Type coordinates** directly: click the field, enter `chr1:1000000-2000000`, press Enter
- **Zoom in/out**: Toolbar buttons, trackpad pinch, or Cmd+Plus / Cmd+Minus
- **Pan**: Click and drag, or scroll gesture

### Zoom Levels

Lungfish automatically adjusts the display based on zoom:

**Density view (>50,000 bp/pixel)**: Annotations shown as histogram bars indicating feature density. Useful for identifying gene-dense vs. gene-sparse regions.

**Squished view (500-50,000 bp/pixel)**: Annotations shown as compact boxes packed into rows. Gene names appear when space permits.

**Expanded view (<500 bp/pixel)**: Full annotation detail — exons as thick blocks, introns as thin lines, strand direction indicators. The sequence track appears showing individual colored bases (A=green, C=blue, G=yellow, T=red).

The sequence track only loads for regions smaller than 500 kb to maintain performance.

## Working with Annotations

### Annotation Table Drawer

Open the bottom drawer to see a spreadsheet-like view of all annotations:

- **Click any row** to navigate to that feature
- **Sort** by clicking column headers
- **Search** using the search bar at the top of the drawer

### Searching Annotations

The search bar uses an SQLite full-text index for instant results:

- Type a gene name, accession, or keyword (e.g., "BRCA1", "kinase")
- Results filter live as you type
- Partial matches work ("BRCA" finds "BRCA1", "BRCA2")
- Case-insensitive

### Filtering by Type

Use the chip-based filter above the annotation table to toggle feature types:

- Click a chip (e.g., "gene", "mRNA", "exon") to show/hide that type
- Common approach: hide "exon" to reduce clutter, show only "mRNA" for transcripts

## Extracting Sequence

Lungfish supports two extraction workflows:

### 1) Extract the visible viewport region

- Navigate and zoom to the interval you want.
- Use **Sequence > Extract Visible Region…** to open the extraction sheet.
- Or use **Sequence > Copy Visible Region as FASTA** for a one-click copy.

### 2) Extract a specific annotation

- Right-click an annotation in the viewer or annotation table.
- Choose **Extract Sequence…**.
- In the extraction sheet, optionally add 5' / 3' flanking bases before exporting.

Notes:

- Manual drag-to-select sub-regions of the viewport is not used for extraction.
- Region extractions always use the currently visible coordinates.

## Quick Tips

### Keyboard Shortcuts

- **Cmd+O**: Open bundle
- **Cmd+Plus / Cmd+Minus**: Zoom in / out
- **Cmd+F**: Focus search field
- **Shift+Cmd+A**: Open AI Assistant

### Performance Tips

- Use chromosome filters to hide unplaced contigs
- Close the annotation drawer when not actively using it
- Zoom out slowly — the density view gives context before diving in
- Let downloads complete fully before building bundles

### Troubleshooting

**Annotations not appearing?** Check that GFF3 was included in the download. Verify you're zoomed in enough (some features hide at low zoom). Check feature type filters.

**Sequence not showing?** Zoom in more — sequence only appears at less than 500 bp/pixel for regions under 500 kb.

**Search not finding genes?** Try searching by accession (e.g., "XM_012345678") instead of gene name. Some assemblies use only accession numbers.
