#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Batch minimap2 ONT-mode analysis for the Zhang pan-genome Lungfish project.
#
# Maps:
#   All_Mamu_genomic.lungfishref -> every Zhang pan-genome haplotype starting MM
#   All_Mafa_genomic.lungfishref -> every Zhang pan-genome haplotype starting MF
#
# Each mapping result is staged as a viewer-ready .lungfishref bundle, then an
# exact-match filtered BAM track is added with `lungfish-cli bam filter`.
#
# Optional environment overrides:
#   THREADS=14
#   RUN_STAMP=2026-04-24Tbatch
#   SUMMARY_TSV="/path/to/summary.tsv"
#   CREATE_EXACT_TRACKS=0
#   LUNGFISH_CLI="/path/to/lungfish-cli"

PROJECT_ROOT="${PROJECT_ROOT:-/Volumes/iWES_WNPRC/32217-Zhang-et-al-MHC/Zhang-pan-genome.lungfish}"
ZHANG_DIR="${ZHANG_DIR:-$PROJECT_ROOT/Zhang pan-genomes}"
GENOMIC_FASTA_DIR="${GENOMIC_FASTA_DIR:-$PROJECT_ROOT/NHP MHC Genomic FASTA}"
ANALYSIS_GROUP_DIR="${ANALYSIS_GROUP_DIR:-$PROJECT_ROOT/Analyses/Map NHP genomic FASTA to Zhang pan-genomes}"

MAMU_DB="${MAMU_DB:-$GENOMIC_FASTA_DIR/All_Mamu_genomic.lungfishref}"
MAFA_DB="${MAFA_DB:-$GENOMIC_FASTA_DIR/All_Mafa_genomic.lungfishref}"

RUN_STAMP="${RUN_STAMP:-$(date +%Y-%m-%dT%H-%M-%S)}"
SUMMARY_TSV="${SUMMARY_TSV:-$ANALYSIS_GROUP_DIR/nhp-genomic-to-zhang-pan-genome-minimap2-ont-$RUN_STAMP.summary.tsv}"
THREADS="${THREADS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
CREATE_EXACT_TRACKS="${CREATE_EXACT_TRACKS:-1}"

REPO_DIR="${REPO_DIR:-/Users/dho/Documents/lungfish-genome-explorer}"
LOCAL_CLI="$REPO_DIR/.build/debug/lungfish-cli"

if [[ -n "${LUNGFISH_CLI:-}" ]]; then
  LUNGFISH=("$LUNGFISH_CLI")
elif command -v lungfish-cli >/dev/null 2>&1; then
  LUNGFISH=("$(command -v lungfish-cli)")
elif [[ -x "$LOCAL_CLI" ]]; then
  LUNGFISH=("$LOCAL_CLI")
else
  LUNGFISH=(swift run --package-path "$REPO_DIR" lungfish-cli)
fi

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_dir() {
  [[ -d "$1" ]] || die "Required directory not found: $1"
}

bundle_name() {
  local base
  base="$(basename "$1")"
  printf '%s' "${base%.lungfishref}"
}

safe_id_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

replace_or_insert_string() {
  local file="$1"
  local key="$2"
  local value="$3"

  if ! plutil -replace "$key" -string "$value" "$file" 2>/dev/null; then
    plutil -insert "$key" -string "$value" "$file"
  fi
}

reset_manifest_alignments() {
  local manifest="$1"

  if ! plutil -replace alignments -json '[]' "$manifest" 2>/dev/null; then
    plutil -insert alignments -json '[]' "$manifest"
  fi
}

next_analysis_dir() {
  local stamp
  stamp="$(date +%Y-%m-%dT%H-%M-%S)"
  local candidate="$ANALYSIS_GROUP_DIR/minimap2-ont-$stamp"
  local suffix=1

  while [[ -e "$candidate" ]]; do
    candidate="$ANALYSIS_GROUP_DIR/minimap2-ont-$stamp-$suffix"
    suffix=$((suffix + 1))
  done

  printf '%s' "$candidate"
}

write_analysis_metadata() {
  local output_dir="$1"
  local created
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '{\n  "created" : "%s",\n  "isBatch" : false,\n  "tool" : "minimap2"\n}\n' \
    "$created" > "$output_dir/analysis-metadata.json"
}

prepare_viewer_bundle() {
  local source_bundle="$1"
  local viewer_bundle="$2"
  local mapped_bam="$3"
  local mapped_bai="$4"
  local source_track_id="$5"
  local sample_name="$6"
  local mapped_reads="$7"
  local unmapped_reads="$8"

  case "$viewer_bundle" in
    "$ANALYSIS_GROUP_DIR"/minimap2-ont-*/*.lungfishref) ;;
    *) die "Refusing to remove unexpected viewer bundle path: $viewer_bundle" ;;
  esac

  rm -rf "$viewer_bundle"
  mkdir -p "$viewer_bundle/alignments"

  for item in genome annotations variants tracks; do
    if [[ -e "$source_bundle/$item" ]]; then
      ln -s "$source_bundle/$item" "$viewer_bundle/$item"
    fi
  done

  local manifest="$viewer_bundle/manifest.json"
  cp "$source_bundle/manifest.json" "$manifest"
  if [[ -f "$source_bundle/.viewstate.json" ]]; then
    cp "$source_bundle/.viewstate.json" "$viewer_bundle/.viewstate.json"
  fi
  reset_manifest_alignments "$manifest"

  local origin_path="$source_bundle"
  local project_prefix="$PROJECT_ROOT/"
  if [[ "$source_bundle" == "$project_prefix"* ]]; then
    origin_path="@/${source_bundle#$project_prefix}"
  fi
  replace_or_insert_string "$manifest" origin_bundle_path "$origin_path"

  local source_bam_rel="alignments/$source_track_id.sorted.bam"
  local source_bai_rel="$source_bam_rel.bai"
  local viewer_bam="$viewer_bundle/$source_bam_rel"
  local viewer_bai="$viewer_bundle/$source_bai_rel"

  cp -f "$mapped_bam" "$viewer_bam"
  cp -f "$mapped_bai" "$viewer_bai"

  local file_size
  file_size="$(wc -c < "$viewer_bam" | tr -d '[:space:]')"
  local added_date
  added_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  plutil -insert alignments.0 -json '{}' "$manifest"
  plutil -insert alignments.0.id -string "$source_track_id" "$manifest"
  plutil -insert alignments.0.name -string "minimap2 ONT Mapping" "$manifest"
  plutil -insert alignments.0.format -string "bam" "$manifest"
  plutil -insert alignments.0.source_path -string "$source_bam_rel" "$manifest"
  plutil -insert alignments.0.index_path -string "$source_bai_rel" "$manifest"
  plutil -insert alignments.0.added_date -string "$added_date" "$manifest"
  plutil -insert alignments.0.mapped_read_count -integer "$mapped_reads" "$manifest"
  plutil -insert alignments.0.unmapped_read_count -integer "$unmapped_reads" "$manifest"
  plutil -insert alignments.0.file_size_bytes -integer "$file_size" "$manifest"
  plutil -insert alignments.0.sample_names -json '[]' "$manifest"
  plutil -insert alignments.0.sample_names.0 -string "$sample_name" "$manifest"
}

patch_mapping_sidecars() {
  local output_dir="$1"
  local source_bundle="$2"
  local viewer_bundle="$3"

  local mapping_result="$output_dir/mapping-result.json"
  [[ -f "$mapping_result" ]] || die "Missing mapping result: $mapping_result"

  replace_or_insert_string "$mapping_result" sourceReferenceBundlePath "$source_bundle"
  replace_or_insert_string "$mapping_result" viewerBundlePath "$(basename "$viewer_bundle")"

  local provenance="$output_dir/mapping-provenance.json"
  if [[ -f "$provenance" ]]; then
    replace_or_insert_string "$provenance" sourceReferenceBundlePath "$source_bundle"
    replace_or_insert_string "$provenance" viewerBundlePath "$(basename "$viewer_bundle")"
  fi
}

run_mapping_for_target() {
  local query_bundle="$1"
  local target_bundle="$2"

  local query_name
  query_name="$(bundle_name "$query_bundle")"
  local target_name
  target_name="$(bundle_name "$target_bundle")"
  local output_dir
  output_dir="$(next_analysis_dir)"
  local viewer_bundle="$output_dir/$target_name.lungfishref"
  local source_track_id="aln_minimap2_ont_$(safe_id_component "$target_name")"

  [[ ! -e "$output_dir" ]] || die "Output directory already exists: $output_dir"

  printf '\n[%s] Mapping %s to %s with minimap2 map-ont\n' "$(date '+%H:%M:%S')" "$query_name" "$target_name"
  "${LUNGFISH[@]}" map "$query_bundle" \
    --reference "$target_bundle" \
    --mapper minimap2 \
    --preset map-ont \
    --output-dir "$output_dir" \
    --sample-name "$query_name" \
    --threads "$THREADS" \
    --no-color

  local mapped_bam="$output_dir/$query_name.sorted.bam"
  local mapped_bai="$mapped_bam.bai"
  [[ -s "$mapped_bam" ]] || die "Expected BAM was not created: $mapped_bam"
  [[ -s "$mapped_bai" ]] || die "Expected BAM index was not created: $mapped_bai"
  write_analysis_metadata "$output_dir"

  local mapping_result="$output_dir/mapping-result.json"
  local mapped_reads
  mapped_reads="$(plutil -extract mappedReads raw -o - "$mapping_result")"
  local unmapped_reads
  unmapped_reads="$(plutil -extract unmappedReads raw -o - "$mapping_result")"

  prepare_viewer_bundle \
    "$target_bundle" \
    "$viewer_bundle" \
    "$mapped_bam" \
    "$mapped_bai" \
    "$source_track_id" \
    "$query_name" \
    "$mapped_reads" \
    "$unmapped_reads"

  patch_mapping_sidecars "$output_dir" "$target_bundle" "$viewer_bundle"

  if [[ "$CREATE_EXACT_TRACKS" == "1" ]]; then
    printf '[%s] Creating exact-match filtered track for %s\n' "$(date '+%H:%M:%S')" "$target_name"
    "${LUNGFISH[@]}" bam filter \
      --mapping-result "$output_dir" \
      --alignment-track "$source_track_id" \
      --output-track-name "Exact matches" \
      --mapped-only \
      --primary-only \
      --exact-match \
      --no-color
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$target_name" "$query_name" "$output_dir" "$viewer_bundle" "$source_track_id" >> "$SUMMARY_TSV"
}

require_dir "$PROJECT_ROOT"
require_dir "$ZHANG_DIR"
require_dir "$MAMU_DB"
require_dir "$MAFA_DB"
mkdir -p "$ANALYSIS_GROUP_DIR"

MM_REFS=()
while IFS= read -r ref; do
  MM_REFS+=("$ref")
done < <(find "$ZHANG_DIR" -maxdepth 1 -type d -name 'MM*.lungfishref' ! -name '._*' | sort)

MF_REFS=()
while IFS= read -r ref; do
  MF_REFS+=("$ref")
done < <(find "$ZHANG_DIR" -maxdepth 1 -type d -name 'MF*.lungfishref' ! -name '._*' | sort)

total_refs=$((${#MM_REFS[@]} + ${#MF_REFS[@]}))
[[ "$total_refs" -eq 20 ]] || die "Expected 20 MM/MF Zhang reference bundles, found $total_refs"

printf 'target\tquery\toutput_dir\tviewer_bundle\tsource_track_id\n' > "$SUMMARY_TSV"

printf 'Project: %s\n' "$PROJECT_ROOT"
printf 'Output:  one GUI-style %s/minimap2-ont-<timestamp> directory per mapping\n' "$ANALYSIS_GROUP_DIR"
printf 'Summary: %s\n' "$SUMMARY_TSV"
printf 'CLI:     %s\n' "${LUNGFISH[*]}"
printf 'Threads: %s\n' "$THREADS"
printf 'Preset:  minimap2 map-ont\n'
printf 'Targets: %s MM, %s MF\n' "${#MM_REFS[@]}" "${#MF_REFS[@]}"

for ref in "${MM_REFS[@]}"; do
  run_mapping_for_target "$MAMU_DB" "$ref"
done

for ref in "${MF_REFS[@]}"; do
  run_mapping_for_target "$MAFA_DB" "$ref"
done

printf '\nBatch complete.\n'
printf 'Summary: %s\n' "$SUMMARY_TSV"
