#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Build viewport-ready .lungfishref bundles from exact-match minimap2 ONT tracks.
#
# For each target in the NHP genomic minimap2 batch summary:
#   1. Find the exact-match BAM in the GUI-style minimap2 analysis bundle.
#   2. Compute the first and last mapped coordinates.
#   3. Extract a window spanning 1 Mb upstream through 1 Mb downstream.
#   4. Rebase exact-match alignments onto the extracted interval reference.
#   5. Create Extractions/NHP genomic exact-match windows/<target>.lungfishref.
#
# Optional environment overrides:
#   FLANK_BP=1000000
#   OVERWRITE=1
#   SUMMARY_TSV="/path/to/nhp-genomic-to-zhang-pan-genome-minimap2-ont-....summary.tsv"
#   LUNGFISH_CLI="/path/to/lungfish-cli"
#   SAMTOOLS="/path/to/samtools"

PROJECT_ROOT="${PROJECT_ROOT:-/Volumes/iWES_WNPRC/32217-Zhang-et-al-MHC/Zhang-pan-genome.lungfish}"
ANALYSIS_GROUP_DIR="${ANALYSIS_GROUP_DIR:-$PROJECT_ROOT/Analyses/Map NHP genomic FASTA to Zhang pan-genomes}"
EXTRACTIONS_DIR="${EXTRACTIONS_DIR:-$PROJECT_ROOT/Extractions/NHP genomic exact-match windows}"
SUMMARY_TSV="${SUMMARY_TSV:-}"
FLANK_BP="${FLANK_BP:-1000000}"
OVERWRITE="${OVERWRITE:-1}"

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

SAMTOOLS="${SAMTOOLS:-$(command -v samtools || true)}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || die "Required file not found: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "Required directory not found: $1"
}

safe_id_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

reset_manifest_alignments() {
  local manifest="$1"

  if ! plutil -replace alignments -json '[]' "$manifest" 2>/dev/null; then
    plutil -insert alignments -json '[]' "$manifest"
  fi
}

latest_summary_tsv() {
  find "$ANALYSIS_GROUP_DIR" -maxdepth 1 -type f \
    -name 'nhp-genomic-to-zhang-pan-genome-minimap2-ont-*.summary.tsv' \
    ! -name '._*' | sort | tail -1
}

bundle_fasta() {
  local bundle="$1"
  local candidate

  for candidate in \
    "$bundle/genome/sequence.fa.gz" \
    "$bundle/genome/sequence.fasta.gz" \
    "$bundle/genome/sequence.fa" \
    "$bundle/genome/sequence.fasta"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

add_alignment_track_to_bundle() {
  local bundle="$1"
  local target="$2"
  local sample_name="$3"
  local mapped_count="$4"
  local unmapped_count="$5"

  local manifest="$bundle/manifest.json"
  local bam_rel="alignments/$target.bam"
  local bai_rel="$bam_rel.bai"
  local bam_path="$bundle/$bam_rel"
  local file_size
  file_size="$(wc -c < "$bam_path" | tr -d '[:space:]')"
  local added_date
  added_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local track_id="aln_exact_window_$(safe_id_component "$target")"

  reset_manifest_alignments "$manifest"
  plutil -insert alignments.0 -json '{}' "$manifest"
  plutil -insert alignments.0.id -string "$track_id" "$manifest"
  plutil -insert alignments.0.name -string "Exact-match interval BAM" "$manifest"
  plutil -insert alignments.0.format -string "bam" "$manifest"
  plutil -insert alignments.0.source_path -string "$bam_rel" "$manifest"
  plutil -insert alignments.0.index_path -string "$bai_rel" "$manifest"
  plutil -insert alignments.0.added_date -string "$added_date" "$manifest"
  plutil -insert alignments.0.mapped_read_count -integer "$mapped_count" "$manifest"
  plutil -insert alignments.0.unmapped_read_count -integer "$unmapped_count" "$manifest"
  plutil -insert alignments.0.file_size_bytes -integer "$file_size" "$manifest"
  plutil -insert alignments.0.sample_names -json '[]' "$manifest"
  plutil -insert alignments.0.sample_names.0 -string "$sample_name" "$manifest"
}

find_exact_bam() {
  local viewer_bundle="$1"
  find "$viewer_bundle/alignments/filtered" -maxdepth 1 -type f -name '*.bam' ! -name '._*' | sort | head -1
}

reference_length_for_contig() {
  local bam="$1"
  local contig="$2"

  "$SAMTOOLS" view -H "$bam" | awk -v contig="$contig" 'BEGIN { FS = "\t" }
    $1 == "@SQ" {
      sn = ""; ln = "";
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 3) == "SN:") sn = substr($i, 4);
        if (substr($i, 1, 3) == "LN:") ln = substr($i, 4);
      }
      if (sn == contig) {
        print ln;
        exit;
      }
    }'
}

mapped_span() {
  local bam="$1"

  "$SAMTOOLS" view -F 4 "$bam" | awk 'BEGIN { FS = "\t"; OFS = "\t" }
    function ref_len(cigar,    rest, token, len, op, total) {
      total = 0;
      rest = cigar;
      while (match(rest, /[0-9]+[MIDNSHP=X]/)) {
        token = substr(rest, RSTART, RLENGTH);
        len = token + 0;
        op = substr(token, length(token), 1);
        if (op == "M" || op == "D" || op == "N" || op == "=" || op == "X") {
          total += len;
        }
        rest = substr(rest, RSTART + RLENGTH);
      }
      return total;
    }
    {
      if (!($3 in seen)) {
        seen[$3] = 1;
        contig_count++;
        contig = $3;
      }
      start = $4;
      end = $4 + ref_len($6) - 1;
      if (count == 0 || start < min_start) min_start = start;
      if (count == 0 || end > max_end) max_end = end;
      count++;
    }
    END {
      if (count == 0) exit 2;
      if (contig_count != 1) exit 3;
      print contig, min_start, max_end, count;
    }'
}

rebase_exact_bam_to_interval() {
  local source_bam="$1"
  local contig="$2"
  local interval_start="$3"
  local interval_end="$4"
  local interval_name="$5"
  local output_bam="$6"

  local interval_length=$((interval_end - interval_start + 1))
  local unsorted_bam="${output_bam%.bam}.unsorted.bam"
  local offset=$((interval_start - 1))

  {
    printf '@HD\tVN:1.6\tSO:unsorted\n'
    printf '@SQ\tSN:%s\tLN:%s\n' "$interval_name" "$interval_length"
    "$SAMTOOLS" view -H "$source_bam" | awk '$1 == "@RG" || $1 == "@PG" || $1 == "@CO" { print }'
    "$SAMTOOLS" view -F 4 "$source_bam" "$contig:$interval_start-$interval_end" | \
      awk -v old_contig="$contig" -v new_contig="$interval_name" -v offset="$offset" \
        'BEGIN { FS = "\t"; OFS = "\t" }
         {
           if ($3 == old_contig) {
             $3 = new_contig;
             $4 = $4 - offset;
           }
           if ($7 == old_contig) {
             $7 = "=";
           } else if ($7 != "*" && $7 != "=") {
             $7 = new_contig;
           }
           if ($8 > 0) {
             $8 = $8 - offset;
           }
           print;
         }'
  } | "$SAMTOOLS" view -b -o "$unsorted_bam" -

  "$SAMTOOLS" sort -o "$output_bam" "$unsorted_bam"
  rm -f "$unsorted_bam"
  "$SAMTOOLS" index "$output_bam"
}

extract_interval_fasta() {
  local source_fasta="$1"
  local contig="$2"
  local interval_start="$3"
  local interval_end="$4"
  local interval_name="$5"
  local output_fasta="$6"

  "$SAMTOOLS" faidx "$source_fasta" "$contig:$interval_start-$interval_end" | \
    awk -v interval_name="$interval_name" 'BEGIN { wrote = 0 }
      /^>/ {
        print ">" interval_name;
        wrote = 1;
        next;
      }
      { print }
      END {
        if (wrote == 0) exit 2;
      }' > "$output_fasta"
  "$SAMTOOLS" faidx "$output_fasta"
}

build_extraction_bundle() {
  local target="$1"
  local sample_name="$2"
  local viewer_bundle="$3"

  local exact_bam
  exact_bam="$(find_exact_bam "$viewer_bundle")"
  require_file "$exact_bam"

  local span
  if ! span="$(mapped_span "$exact_bam")"; then
    die "Could not derive a single-contig mapped span from $exact_bam"
  fi

  local contig min_start max_end exact_count
  read -r contig min_start max_end exact_count <<< "$span"

  local contig_length
  contig_length="$(reference_length_for_contig "$exact_bam" "$contig")"
  [[ -n "$contig_length" ]] || die "Could not find contig length for $contig in $exact_bam"

  local interval_start=$((min_start - FLANK_BP))
  if (( interval_start < 1 )); then
    interval_start=1
  fi

  local interval_end=$((max_end + FLANK_BP))
  if (( interval_end > contig_length )); then
    interval_end="$contig_length"
  fi

  local interval_name="${target}__${contig}_${interval_start}_${interval_end}"
  local bundle="$EXTRACTIONS_DIR/$target.lungfishref"
  local work_dir="$EXTRACTIONS_DIR/.work-$target"
  local interval_fasta="$work_dir/$target.interval.fa"
  local rebased_bam="$work_dir/$target.bam"

  if [[ -e "$bundle" ]]; then
    if [[ "$OVERWRITE" == "1" ]]; then
      rm -rf "$bundle"
    else
      die "Output bundle already exists: $bundle"
    fi
  fi

  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  local source_fasta
  source_fasta="$(bundle_fasta "$viewer_bundle")" || die "Could not find source FASTA in $viewer_bundle/genome"

  extract_interval_fasta "$source_fasta" "$contig" "$interval_start" "$interval_end" "$interval_name" "$interval_fasta"
  rebase_exact_bam_to_interval "$exact_bam" "$contig" "$interval_start" "$interval_end" "$interval_name" "$rebased_bam"

  "${LUNGFISH[@]}" bundle create \
    --fasta "$interval_fasta" \
    --name "$target" \
    --identifier "$target-nhp-genomic-exact-match-window" \
    --organism "Macaca" \
    --assembly "$contig:$interval_start-$interval_end" \
    --output-dir "$EXTRACTIONS_DIR" \
    --compress \
    --quiet \
    --no-color

  mkdir -p "$bundle/alignments"
  cp -f "$rebased_bam" "$bundle/alignments/$target.bam"
  cp -f "$rebased_bam.bai" "$bundle/alignments/$target.bam.bai"

  local mapped_count
  mapped_count="$("$SAMTOOLS" view -c -F 4 "$bundle/alignments/$target.bam")"
  local unmapped_count
  unmapped_count="$("$SAMTOOLS" view -c -f 4 "$bundle/alignments/$target.bam")"

  add_alignment_track_to_bundle "$bundle" "$target" "$sample_name" "$mapped_count" "$unmapped_count"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$target" \
    "$sample_name" \
    "$contig" \
    "$min_start" \
    "$max_end" \
    "$interval_start" \
    "$interval_end" \
    "$exact_count" \
    "$mapped_count" \
    "$interval_name" \
    "$bundle" >> "$COORDINATES_TSV"

  rm -rf "$work_dir"
}

if [[ -z "$SUMMARY_TSV" ]]; then
  SUMMARY_TSV="$(latest_summary_tsv)"
fi

require_file "$SUMMARY_TSV"
[[ -n "$SAMTOOLS" ]] || die "samtools not found on PATH. Set SAMTOOLS=/path/to/samtools."
mkdir -p "$EXTRACTIONS_DIR"

COORDINATES_TSV="$EXTRACTIONS_DIR/nhp_genomic_exact_match_interval_coordinates.tsv"
printf 'target\tsample\tcontig\tmatched_start\tmatched_end\twindow_start\twindow_end\texact_match_reads\textracted_bam_reads\tinterval_reference\tbundle\n' > "$COORDINATES_TSV"

printf 'Summary: %s\n' "$SUMMARY_TSV"
printf 'Output:  %s\n' "$EXTRACTIONS_DIR"
printf 'Flank:   %s bp\n' "$FLANK_BP"

while IFS=$'\t' read -r target query output_dir viewer_bundle source_track_id; do
  [[ "$target" == "target" ]] && continue
  require_dir "$viewer_bundle"
  printf '[%s] Building extraction bundle for %s\n' "$(date '+%H:%M:%S')" "$target"
  build_extraction_bundle "$target" "$query" "$viewer_bundle"
done < "$SUMMARY_TSV"

printf '\nExtraction bundles complete.\n'
printf 'Coordinates: %s\n' "$COORDINATES_TSV"
