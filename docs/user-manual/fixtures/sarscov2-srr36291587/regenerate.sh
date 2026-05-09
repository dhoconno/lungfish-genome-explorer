#!/usr/bin/env bash
set -euo pipefail
LUNGFISH=${LUNGFISH:-./build/Release/Lungfish.app/Contents/MacOS/lungfish-cli}
OUT=${OUT:-./fixture-tmp}
mkdir -p "$OUT"

# Resolve the QIASeqDIRECT-SARS2 primer scheme. Try the shipped-app layout
# first; fall back to the swift-package build bundle layout used by the
# `.build/{debug,release}/lungfish-cli` binaries.
LUNGFISH_DIR=$(cd "$(dirname "$LUNGFISH")" && pwd)
SHIPPED_PRIMER_PATH="$LUNGFISH_DIR/../Resources/LungfishGenomeBrowser_LungfishApp.bundle/Contents/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers"
SPM_PRIMER_PATH="$LUNGFISH_DIR/LungfishGenomeBrowser_LungfishApp.bundle/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers"
if [ -d "$SHIPPED_PRIMER_PATH" ]; then
    PRIMER_SCHEME="$SHIPPED_PRIMER_PATH"
elif [ -d "$SPM_PRIMER_PATH" ]; then
    PRIMER_SCHEME="$SPM_PRIMER_PATH"
else
    echo "Could not locate QIASeqDIRECT-SARS2.lungfishprimers next to $LUNGFISH" >&2
    echo "Tried:" >&2
    echo "  $SHIPPED_PRIMER_PATH" >&2
    echo "  $SPM_PRIMER_PATH" >&2
    exit 1
fi

"$LUNGFISH" fetch ncbi MN908947.3 --fetch-format fasta --save-to "$OUT/MN908947.3.fasta"
"$LUNGFISH" fetch sra download SRR36291587 --output-dir "$OUT" --use-toolkit
"$LUNGFISH" bundle create --fasta "$OUT/MN908947.3.fasta" --name MN908947.3 --output-dir "$OUT" --compress
"$LUNGFISH" map "$OUT/SRR36291587_1.fastq" "$OUT/SRR36291587_2.fastq" \
    --reference "$OUT/MN908947.3.fasta" \
    --paired --preset sr --sample-name SRR36291587 -o "$OUT/mapping"
"$LUNGFISH" bam adopt-mapping --bundle "$OUT/MN908947.3.lungfishref" --mapping-result "$OUT/mapping" --name "minimap2 mapping"
# Primer-trim and call iVar / LoFreq from the manifest's first alignment track:
TRACK_ID=$(jq -r '.alignments[0].id' "$OUT/MN908947.3.lungfishref/manifest.json")
"$LUNGFISH" bam primer-trim --bundle "$OUT/MN908947.3.lungfishref" --alignment-track "$TRACK_ID" \
    --scheme "$PRIMER_SCHEME" \
    --name primer-trimmed
TRIMMED_ID=$(jq -r '.alignments[] | select(.name == "primer-trimmed") | .id' "$OUT/MN908947.3.lungfishref/manifest.json")
"$LUNGFISH" variants call --bundle "$OUT/MN908947.3.lungfishref" --alignment-track "$TRIMMED_ID" --caller ivar --name "iVar variants" --ivar-primer-trimmed
"$LUNGFISH" variants call --bundle "$OUT/MN908947.3.lungfishref" --alignment-track "$TRACK_ID" --caller lofreq --name "LoFreq variants"
