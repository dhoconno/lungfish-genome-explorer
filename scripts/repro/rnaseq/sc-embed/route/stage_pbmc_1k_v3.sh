#!/bin/bash
# SPDX-License-Identifier: MIT
# Stage 10x's pbmc_1k_v3 outs/ folder for the pin of the cell-map route (ruling ARCH-X4-INPUT
# item 2): the three files of the filtered-matrix tarball, metrics_summary.csv and the graph
# clusters, with a SHA256SUMS file. The tarball must have the bytes of
# Tests/Fixtures/rnaseq/SOURCES.tsv:17, and the matrix the bytes the pin names.
# Usage: stage_pbmc_1k_v3.sh TARBALL METRICS_CSV CLUSTERS_CSV OUT_FOLDER   (OUT ends in .../pbmc_1k_v3/outs)
set -euo pipefail
TARBALL=${1:?filtered-matrix tarball}
METRICS=${2:?metrics_summary.csv}
CLUSTERS=${3:?graphclust clusters.csv}
OUT=${4:?output outs folder}
TAR_SHA=9beae9e7852b2514b4449ecdc5d5a762445289dcfbe5ddb70a44866380b673ce
MTX_SHA=b80e55b5577ca56faa404f08faffbccd024119066ef194aa883708a9fe9170f6
die() { echo "stage_pbmc_1k_v3.sh: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
[ "$(sha "$TARBALL")" = "$TAR_SHA" ] || die "the tarball's sha256 is not $TAR_SHA"
[ "$(basename "$OUT")" = outs ] || die "the output folder must be named outs"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then die "$OUT is not empty"; fi
mkdir -p "$OUT"
tar -xzf "$TARBALL" -C "$OUT" filtered_feature_bc_matrix/matrix.mtx.gz \
  filtered_feature_bc_matrix/features.tsv.gz filtered_feature_bc_matrix/barcodes.tsv.gz
cp "$METRICS" "$OUT/metrics_summary.csv"
cp "$CLUSTERS" "$OUT/clusters.csv"
[ "$(sha "$OUT/filtered_feature_bc_matrix/matrix.mtx.gz")" = "$MTX_SHA" ] || die "matrix.mtx.gz is not $MTX_SHA"
(cd "$OUT" && shasum -a 256 filtered_feature_bc_matrix/barcodes.tsv.gz filtered_feature_bc_matrix/features.tsv.gz \
  filtered_feature_bc_matrix/matrix.mtx.gz metrics_summary.csv clusters.csv) > "$OUT/../SHA256SUMS"
echo "staged $OUT"
cat "$OUT/../SHA256SUMS"
