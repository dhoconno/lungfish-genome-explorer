#!/usr/bin/env bash
# Populate the manual's demo project from the committed fixtures. Idempotent.
#
# Environment variables:
#   LUNGFISH_CLI        path to the lungfish-cli binary
#   LUNGFISH_DEMO_ROOT  directory that holds the project (default ~/Desktop/lge-docs)
#   LUNGFISH_KRAKEN_DB  installed Kraken 2 database name (default Viral)
#
# The project store only exists once it has been created in the app (File >
# New Project). This script refuses to run against a project that does not
# have one yet.
#
# The SARS-CoV-2 fixture commits no reads. They are fetched once into
# <build-dir>/_scratch/sra and reused on every later run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$(cd "$HERE/.." && pwd)"
CLI="${LUNGFISH_CLI:-/Users/dho/Documents/lungfish-genome-explorer/.build/debug/lungfish-cli}"
ROOT="${LUNGFISH_DEMO_ROOT:-$HOME/Desktop/lge-docs}"
KRAKEN_DB="${LUNGFISH_KRAKEN_DB:-Viral}"
P="$ROOT/LGE Manual Demo.lungfish"
BUILD_DIR="${P%.lungfish}.build"
SCRATCH="$BUILD_DIR/_scratch"
SRA="$SCRATCH/sra"

if [ ! -f "$P/.project.db" ]; then
  echo "###### build-demo-project.sh"
  echo "   ERROR: no project store at $P"
  echo "   Create the project in the app first: File > New Project, name it"
  echo "   \"LGE Manual Demo\", and save it under $ROOT (move the folder there"
  echo "   afterwards if it was saved elsewhere, or set Where to that folder"
  echo "   in the save dialog). Close the project in the app, then run this"
  echo "   script again to populate it."
  exit 2
fi

mkdir -p "$SRA"
exec > >(tee -a "$BUILD_DIR/build.log") 2>&1

STEP_START=0
step() {
  STEP_START=$(date +%s)
  echo
  echo "== $1 ($(date +%H:%M:%S))"
}
step_end() {
  echo "   step took $(( $(date +%s) - STEP_START ))s"
}
done_if() {
  if [ -e "$1" ]; then
    echo "   exists, skipping: $1"
    return 0
  fi
  return 1
}

echo "###### build-demo-project.sh $(date '+%Y-%m-%d %H:%M:%S')"
echo "   cli     $CLI"
echo "   project $P"
echo "   kraken  $KRAKEN_DB"

# ---------------------------------------------------------------------------
step "0 SARS-CoV-2 reads (fetched, not committed)"
if done_if "$SRA/SRR36291587_2.fastq"; then
  :
else
  "$CLI" fetch sra download SRR36291587 --output-dir "$SRA" --use-toolkit
fi
R1="$SRA/SRR36291587_1.fastq"
R2="$SRA/SRR36291587_2.fastq"
step_end

# ---------------------------------------------------------------------------
step "1 reads"
# `import-fastq` pairs R1 with R2 only for underscore-delimited names
# (_R1_001, _R1, _1). The hg002-chr20 and human-mito fixtures use
# dot-delimited .R1/.R2, which the detector reads as two single-end
# samples. A sample sheet states the pairing explicitly and also gives
# each sample the short name the manual refers to.
SHEET="$SCRATCH/samplesheet.csv"
{
  echo "sample,r1,r2"
  echo "HG002,$FX/hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz,$FX/hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz"
  echo "HG002-chrM,$FX/human-mito/HG002.chrM_R1.fastq.gz,$FX/human-mito/HG002.chrM_R2.fastq.gz"
} > "$SHEET"

done_if "$P/Imports/HG002.lungfishfastq" || "$CLI" import-fastq --samplesheet "$SHEET" \
  --project "$P" --platform illumina --no-optimize-storage
done_if "$P/Imports/SRR36291587.lungfishfastq" || "$CLI" import-fastq --project "$P" \
  --platform illumina --no-optimize-storage "$R1" "$R2"
step_end

# ---------------------------------------------------------------------------
step "2 references"
# `import fasta -o` takes the PROJECT directory and writes into its own
# "Reference Sequences" subfolder. It also sanitises the bundle filename,
# so "chr20 10.0-10.5Mb" becomes chr20_10.0-10.5Mb.lungfishref.
REFDIR="$P/Reference Sequences"
mkdir -p "$REFDIR"
done_if "$REFDIR/HBB.lungfishref" || "$CLI" import fasta "$FX/hbb-gene/NG_000007.3.gb" --name HBB -o "$P"
done_if "$REFDIR/chr20_10.0-10.5Mb.lungfishref" || "$CLI" import fasta "$FX/hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta" --name "chr20 10.0-10.5Mb" -o "$P"
# The unaligned primate mitochondrial genomes sit in the project as a reference
# bundle so the MAFFT chapter's sidebar route can be followed; the alignment
# below is still built from the fixture file.
done_if "$REFDIR/primate-mito.lungfishref" || "$CLI" import fasta "$FX/primate-mito/primate-mito.fasta" --name "primate-mito" -o "$P"
# `import fasta` has no organism flag and writes the display name into
# source.organism, so patch the manifest to the real organism afterwards.
python3 - "$REFDIR/chr20_10.0-10.5Mb.lungfishref/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("source", {})["organism"] = "Homo sapiens"
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
step_end

# ---------------------------------------------------------------------------
step "3 mapping and variants"
CHR20=$(ls -d "$REFDIR"/*chr20*.lungfishref | head -1)
echo "   bundle $CHR20"
done_if "$P/Analyses/mapping-HG002" || "$CLI" map --paired --mapper minimap2 --preset sr \
  --reference "$FX/hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta" \
  --sample-name HG002 -o "$P/Analyses/mapping-HG002" \
  "$FX/hg002-chr20/HG002.chr20.10.0-10.5Mb_R1.fastq.gz" "$FX/hg002-chr20/HG002.chr20.10.0-10.5Mb_R2.fastq.gz"

MANIFEST="$CHR20/manifest.json"
track_named() {
  [ -f "$MANIFEST" ] || return 1
  /usr/bin/python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
for a in m.get("alignments") or []:
    if a.get("name")==sys.argv[2]:
        print(a.get("id")); break
' "$MANIFEST" "$1"
}
variant_named() {
  [ -f "$MANIFEST" ] || return 1
  /usr/bin/python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
for v in m.get("variants") or []:
    if v.get("name")==sys.argv[2]:
        print(v.get("id")); break
' "$MANIFEST" "$1"
}

if [ -z "$(track_named 'HG002 minimap2')" ]; then
  "$CLI" bam adopt-mapping --bundle "$CHR20" --mapping-result "$P/Analyses/mapping-HG002" \
    --name "HG002 minimap2" --track-id hg002-minimap2
else
  echo "   alignment track exists, skipping adopt-mapping"
fi
TRACK_ID="$(track_named 'HG002 minimap2')"
echo "   alignment track id: ${TRACK_ID:-<none>}"

if [ -n "$TRACK_ID" ]; then
  if [ -z "$(variant_named 'HG002 bcftools')" ]; then
    "$CLI" variants call --bundle "$CHR20" --alignment-track "$TRACK_ID" --caller bcftools --name "HG002 bcftools"
  else
    echo "   bcftools track exists, skipping"
  fi
  if [ -z "$(variant_named 'HG002 LoFreq')" ]; then
    "$CLI" variants call --bundle "$CHR20" --alignment-track "$TRACK_ID" --caller lofreq --name "HG002 LoFreq"
  else
    echo "   LoFreq track exists, skipping"
  fi
else
  echo "   no alignment track id resolved, skipping variant calling"
fi
step_end

# ---------------------------------------------------------------------------
step "4 assembly"
# The assembly lives under Analyses/ because the app's sidebar lists analyses
# from that folder alone (AnalysesFolder.listAnalyses recognises the run by its
# assembly-result.json). A top-level Assemblies/ folder would never appear as
# an assembly in the app, and the manual says no such folder exists.
if [ -d "$P/Assemblies/HG002-chrM" ] && [ ! -d "$P/Analyses/HG002-chrM" ]; then
  mkdir -p "$P/Analyses"
  mv "$P/Assemblies/HG002-chrM" "$P/Analyses/HG002-chrM"
  rmdir "$P/Assemblies" 2>/dev/null || true
fi
done_if "$P/Analyses/HG002-chrM" || "$CLI" assemble --assembler spades --read-type illumina-short-reads \
  --paired --name HG002-chrM -o "$P/Analyses/HG002-chrM" \
  "$FX/human-mito/HG002.chrM_R1.fastq.gz" "$FX/human-mito/HG002.chrM_R2.fastq.gz"
step_end

# ---------------------------------------------------------------------------
step "5 alignment and tree"
MSA=$(find "$P" -maxdepth 3 -name '*.lungfishmsa' | head -1)
if [ -z "$MSA" ]; then
  "$CLI" align mafft --name "Primate mitochondria" --project "$P" "$FX/primate-mito/primate-mito.fasta"
  MSA=$(find "$P" -maxdepth 3 -name '*.lungfishmsa' | head -1)
else
  echo "   MSA exists, skipping: $MSA"
fi
echo "   msa $MSA"
TREE=$(find "$P" -maxdepth 3 -name '*.lungfishtree' | head -1)
if [ -z "$TREE" ] && [ -n "$MSA" ]; then
  MSADIR=$(dirname "$MSA")
  "$CLI" tree infer iqtree "$MSA" --project "$P" \
    --output "$P/Phylogenetic Trees/Primate mitochondria.lungfishtree" --name "Primate mitochondria"
else
  echo "   tree exists or no MSA, skipping"
fi
step_end

# ---------------------------------------------------------------------------
step "6 classification"
# `conda classify --profile` exits 64 when Kraken 2 succeeds but Bracken
# produces no profile. On the Viral database this fixture resolves to a
# single species, which is exactly that case. The Kraken 2 report and
# per-read output are still written and are what the manual screenshots,
# so treat a missing Bracken profile as a warning rather than a failure.
if done_if "$P/Analyses/kraken2-SRR36291587"; then
  :
else
  set +e
  "$CLI" conda classify --db "$KRAKEN_DB" --profile --paired \
    -o "$P/Analyses/kraken2-SRR36291587" "$R1" "$R2"
  CLASSIFY_STATUS=$?
  set -e
  if [ -f "$P/Analyses/kraken2-SRR36291587/classification.kreport" ]; then
    if [ "$CLASSIFY_STATUS" -ne 0 ]; then
      echo "   note: classify exited $CLASSIFY_STATUS but the Kraken 2 report was written."
      if [ ! -f "$P/Analyses/kraken2-SRR36291587/classification.bracken" ]; then
        echo "   note: no Bracken profile. Expected on a single-species Viral result."
      fi
    fi
  else
    echo "   ERROR: classify exited $CLASSIFY_STATUS and wrote no Kraken 2 report."
    exit "$CLASSIFY_STATUS"
  fi
fi
step_end

# ---------------------------------------------------------------------------
step "7 NVD import"
if find "$P/Analyses" -maxdepth 1 -name 'nvd-demo*' 2>/dev/null | grep -q .; then
  echo "   exists, skipping"
else
  "$CLI" import nvd "$FX/nvd-demo/results" -o "$P/Analyses" --name nvd-demo
fi
step_end

# ---------------------------------------------------------------------------
step "8 Viral Recon (manual, needs Docker Desktop running)"
if docker info >/dev/null 2>&1; then
  echo "   Docker is running."
else
  echo "   Docker is NOT running. Start Docker Desktop before the manual step."
fi
echo "   Viral Recon is not run by this script. Run it once from the app's"
echo "   Tools > Variant Calling > Viral Recon (SARS-CoV-2) wizard on the SRR36291587 sample."
echo "   See README.md in this directory."
step_end

# ---------------------------------------------------------------------------
step "9 additional human and classification documentation fixtures"
# Only creates missing outputs. Safe to run the helper on an open demo because
# these CLI import paths do not mutate .project.db. No live project rebuild.
python3 "$HERE/extend-demo-fixtures.py" ont hifi barcode ont-run flye amplicon nao czid 12s benchmark sra sra-import mhc-simulated hello-workflow
step_end

echo
echo "== done ($(date +%H:%M:%S))"
