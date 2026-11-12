#!/bin/bash
# Build one release's part of the upgrade corpus (scripts/golden/upgrade_check.py).
#
#   bash scripts/golden/build_upgrade_corpus.sh <release tag> <that release's lungfish-cli> [<DMG file>]
#
# Example: bash scripts/golden/build_upgrade_corpus.sh v2026.11.7 \
#     /Volumes/lge_scratch/lge/builds/v2026.11.7/Lungfish.app/Contents/MacOS/lungfish-cli
#
# The DMG of a release is an asset of its GitHub release:
#   gh release download <tag> --pattern '*.dmg' --dir /Volumes/lge_scratch/lge/builds/<tag>/
# Copy the app out of the mounted DMG and take the lungfish-cli inside it. The projects come from
# build_demo_project.py, driven by that CLI, with provenance signing on so that `provenance verify`
# checks a real signature. A project that needs SRA (human-reads, sarscov2-amplicons, pathogen-detection)
# or media outside this checkout (long-reads-and-assembly) is left out.
# The hg002-chr20 inputs of the results project come from the 2026.9.58 demo archives in the golden
# cache when docs/user-manual/fixtures/hg002-chr20 (gitignored) is empty.
set -euo pipefail

TAG="$1"
CLI="$2"
DMG="${3:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORPUS="${UPGRADE_CORPUS:-/Users/Shared/lungfish-golden/cache/upgrade-corpus}"
WORK="${UPGRADE_WORK:-/Volumes/lge_scratch/lge/trust/UPGRADE-CORPUS}/work-$TAG"
IDS="genes-and-sequences,mhc-genotyping,primer-design,twelve-s-metabarcoding,human-mapping-and-variants-results"
ARCHIVES=/Users/Shared/lungfish-golden/cache/demo-archives
FX="$REPO/docs/user-manual/fixtures/hg002-chr20"

if [ ! -f "$FX/GRCh38.chr20.10.0-10.5Mb.fasta" ]; then
    mkdir -p "$FX"
    unzip -q -o -j "$ARCHIVES/lge-demo-human-mapping-and-variants-2026.9.58.zip" "*/Practice Data/hg002-chr20/*" -d "$FX"
    unzip -q -o -j "$ARCHIVES/lge-demo-human-reads-2026.9.58.zip" "*/Practice Data/hg002-chr20/HG002.chr20.10.0-10.5Mb_R*.fastq.gz" -d "$FX"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
export LUNGFISH_PROVENANCE_SIGNING_KEY="lungfish-upgrade-corpus-test-key-v1"
python3 "$REPO/scripts/demo-projects/build_demo_project.py" "$IDS" --cli "$CLI" --out-dir "$WORK/zips" \
    --work-dir "$WORK" --version "${TAG#v}" --no-manifest --no-verify

rm -rf "$CORPUS/$TAG"
for id in ${IDS//,/ }; do
    mkdir -p "$CORPUS/$TAG/$id"
    unzip -q "$WORK/zips/lge-demo-$id-${TAG#v}.zip" -d "$CORPUS/$TAG/$id"
done

python3 "$REPO/scripts/golden/upgrade_check.py" --capture --cli "$CLI" --corpus "$CORPUS" --only "$TAG"

DMG_SHA=""
if [ -n "$DMG" ]; then DMG_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"; fi
cat > "$CORPUS/$TAG/build.json" <<EOF
{"release": "$TAG", "cliVersion": "$("$CLI" --version)", "dmg": "$(basename "${DMG:-none}")", "dmgSha256": "$DMG_SHA", "projects": "$IDS"}
EOF

cd "$CORPUS"
find . -type f ! -name 'SHA256SUMS*' ! -name .DS_Store | sed 's|^\./||' | sort | while IFS= read -r file; do
    shasum -a 256 -- "$file"
done > SHA256SUMS.new
mv SHA256SUMS.new SHA256SUMS
echo "build_upgrade_corpus: $TAG done, $(du -sk "$CORPUS/$TAG" | cut -f1) KB, $(wc -l < SHA256SUMS | tr -d ' ') files listed"
