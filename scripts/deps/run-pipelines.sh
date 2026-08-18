#!/usr/bin/env bash
#
# Tier 3 pipeline runner (manual): runs the full TaxTriage and/or EsViritu
# pipelines end to end against a live SRA accession and diffs the resulting
# report schemas against the committed mini fixtures.
#
# This is network- and database-heavy (Nextflow/Docker for TaxTriage, a
# multi-GB EsViritu database) and is NOT part of CI. It is run manually
# during a dependency sweep; see docs/release/dependency-sweep.md.
#
# Usage:
#   bash scripts/deps/run-pipelines.sh --which taxtriage|esviritu|all --out <dir> [--accession SRR35517702]
#
# Steps:
#   1. Fetch reads for the accession with the managed sra-tools fasterq-dump
#      into <out>/reads/, then subsample to 50k pairs with the managed
#      seqkit (seqkit sample -n 50000 -s 11). The subsample command and seed
#      are recorded in <out>/reads/meta.json.
#   2. Run the requested pipeline(s) via the lungfish-cli subcommands.
#   3. Structurally diff the pipeline outputs against Tests/Fixtures/taxtriage-mini
#      and Tests/Fixtures/esviritu-mini using scripts/deps/pipeline-goldens.json
#      recipes (kind "tsv-header", compareColumns [] -- headers only, so only
#      schema drift fails the diff). Value-level differences are printed as
#      informational output, not failures.
#   4. Emit <out>/tier3-report.md summarizing what ran and the diff result.
#
# Exit codes:
#   0   pipeline(s) ran and the header-only diff found no schema drift
#   1   a pipeline command failed
#   2   the header-only diff found schema drift
#   64  bad arguments
#   66  a required input (fixture, manifest, database) was not found
#
# This script does not install tools or databases. Provision them first with:
#   lungfish-cli tools update --apply --yes --required-only
#   lungfish-cli conda install --pack metagenomics
#   lungfish-cli conda db download Viral
#   lungfish-cli esviritu download-db

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

conda_root="${LUNGFISH_CONDA_ROOT:-${HOME}/.lungfish/conda}"
cli_bin="${LUNGFISH_CLI_BIN:-${repo_root}/.build/debug/lungfish-cli}"
goldens_manifest="${script_dir}/pipeline-goldens.json"
diff_script="${script_dir}/diff_goldens.py"

which_target=""
out_dir=""
accession="SRR35517702"
subsample_reads=50000
subsample_seed=11

usage() {
    cat <<'EOF'
usage: run-pipelines.sh --which taxtriage|esviritu|all --out <dir> [options]

Run the tier 3 (manual) TaxTriage and/or EsViritu pipelines end to end
against a live SRA accession, then structurally diff the outputs against
the committed mini fixtures. Network- and database-heavy; not run in CI.

Required:
  --which <taxtriage|esviritu|all>   which pipeline(s) to run
  --out <dir>                        output directory (created if needed)

Options:
  --accession <SRR...>    SRA accession to fetch (default: SRR35517702)
  --cli <path>            path to lungfish-cli (default: .build/debug/lungfish-cli)
  -h, --help              print this help and exit 0

Examples:
  bash scripts/deps/run-pipelines.sh --which all --out /tmp/tier3
  bash scripts/deps/run-pipelines.sh --which taxtriage --out /tmp/tier3 --accession SRR35517702

Provision tools and databases first:
  lungfish-cli tools update --apply --yes --required-only
  lungfish-cli conda install --pack metagenomics
  lungfish-cli conda db download Viral
  lungfish-cli esviritu download-db

Output:
  <out>/reads/             fetched + subsampled reads, meta.json
  <out>/taxtriage/         TaxTriage results (if run)
  <out>/esviritu/          EsViritu results (if run)
  <out>/diff/              structural diff candidate directory
  <out>/tier3-report.md    summary report
EOF
}

# Reject a value-taking flag that was given no value. Without this, `shift 2`
# on a one-element argument list aborts under `set -u` with an opaque message,
# or leaves the variable empty and the run proceeds against a wrong target.
# 64 is EX_USAGE, matching the unknown-argument arm below.
require_value() {
    local flag="$1" remaining="$2"
    if [[ ${remaining} -lt 2 ]]; then
        echo "${flag} requires a value" >&2
        usage >&2
        exit 64
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --which)
            require_value "$1" $#
            which_target="$2"
            shift 2
            ;;
        --out)
            require_value "$1" $#
            out_dir="$2"
            shift 2
            ;;
        --accession)
            require_value "$1" $#
            accession="$2"
            shift 2
            ;;
        --cli)
            require_value "$1" $#
            cli_bin="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ -z "${which_target}" || -z "${out_dir}" ]]; then
    echo "error: --which and --out are required" >&2
    usage >&2
    exit 64
fi

case "${which_target}" in
    taxtriage|esviritu|all) ;;
    *)
        echo "error: --which must be one of taxtriage, esviritu, all (got: ${which_target})" >&2
        exit 64
        ;;
esac

run_taxtriage=0
run_esviritu=0
case "${which_target}" in
    taxtriage) run_taxtriage=1 ;;
    esviritu) run_esviritu=1 ;;
    all) run_taxtriage=1; run_esviritu=1 ;;
esac

if [[ ! -f "${goldens_manifest}" ]]; then
    echo "pipeline goldens manifest not found: ${goldens_manifest}" >&2
    exit 66
fi
if [[ ! -f "${diff_script}" ]]; then
    echo "diff_goldens.py not found: ${diff_script}" >&2
    exit 66
fi

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
reads_dir="${out_dir}/reads"
diff_candidate_dir="${out_dir}/diff"
mkdir -p "${reads_dir}" "${diff_candidate_dir}"

sra_tools_bin="${conda_root}/envs/sra-tools/bin"
seqkit_bin="${conda_root}/envs/seqkit/bin"

echo "==> Fetching reads for ${accession} with fasterq-dump"
PATH="${sra_tools_bin}:${PATH}" fasterq-dump \
    --split-files \
    --outdir "${reads_dir}" \
    "${accession}"

r1_full="${reads_dir}/${accession}_1.fastq"
r2_full="${reads_dir}/${accession}_2.fastq"
r1_sub="${reads_dir}/${accession}_1.subsampled.fastq"
r2_sub="${reads_dir}/${accession}_2.subsampled.fastq"

echo "==> Subsampling to ${subsample_reads} pairs (seed ${subsample_seed}) with seqkit sample"
PATH="${seqkit_bin}:${PATH}" seqkit sample -n "${subsample_reads}" -s "${subsample_seed}" "${r1_full}" -o "${r1_sub}"
PATH="${seqkit_bin}:${PATH}" seqkit sample -n "${subsample_reads}" -s "${subsample_seed}" "${r2_full}" -o "${r2_sub}"

cat > "${reads_dir}/meta.json" <<EOF
{
  "accession": "${accession}",
  "fetchCommand": "fasterq-dump --split-files --outdir ${reads_dir} ${accession}",
  "subsampleCommand": "seqkit sample -n ${subsample_reads} -s ${subsample_seed}",
  "subsampleReads": ${subsample_reads},
  "subsampleSeed": ${subsample_seed}
}
EOF

report_lines=()
report_lines+=("# Tier 3 pipeline report")
report_lines+=("")
report_lines+=("Accession: ${accession}")
report_lines+=("Subsample: ${subsample_reads} pairs, seed ${subsample_seed}")
report_lines+=("")

pipeline_failures=0

if [[ ${run_taxtriage} -eq 1 ]]; then
    echo "==> Running TaxTriage"
    taxtriage_out="${out_dir}/taxtriage"
    mkdir -p "${taxtriage_out}"
    taxtriage_status=0
    "${cli_bin}" taxtriage run \
        --input "${r1_sub}" \
        --input2 "${r2_sub}" \
        --sample "${accession}" \
        --output "${taxtriage_out}" \
        || taxtriage_status=$?

    if [[ ${taxtriage_status} -ne 0 ]]; then
        echo "FAIL TaxTriage: exit ${taxtriage_status}" >&2
        report_lines+=("## TaxTriage: FAILED (exit ${taxtriage_status})")
        pipeline_failures=$((pipeline_failures + 1))
    else
        mkdir -p "${diff_candidate_dir}/taxtriage-multiqc-confidences" "${diff_candidate_dir}/taxtriage-combine-gcfmap"
        cp "${taxtriage_out}/report/multiqc_data/multiqc_confidences.txt" \
            "${diff_candidate_dir}/taxtriage-multiqc-confidences/multiqc_confidences.txt" 2>/dev/null || true
        cp "${taxtriage_out}"/combine/*.combined.gcfmap.tsv \
            "${diff_candidate_dir}/taxtriage-combine-gcfmap/" 2>/dev/null || true
        report_lines+=("## TaxTriage: OK")
        report_lines+=("Output: ${taxtriage_out}")
    fi
    report_lines+=("")
fi

if [[ ${run_esviritu} -eq 1 ]]; then
    echo "==> Running EsViritu"
    esviritu_out="${out_dir}/esviritu"
    mkdir -p "${esviritu_out}"
    esviritu_status=0
    "${cli_bin}" esviritu detect \
        --input "${r1_sub}" "${r2_sub}" \
        --paired \
        --sample "${accession}" \
        --output "${esviritu_out}" \
        || esviritu_status=$?

    if [[ ${esviritu_status} -ne 0 ]]; then
        echo "FAIL EsViritu: exit ${esviritu_status}" >&2
        report_lines+=("## EsViritu: FAILED (exit ${esviritu_status})")
        pipeline_failures=$((pipeline_failures + 1))
    else
        mkdir -p "${diff_candidate_dir}/esviritu-detected-virus-info" "${diff_candidate_dir}/esviritu-virus-coverage-windows"
        cp "${esviritu_out}"/*.detected_virus.info.tsv \
            "${diff_candidate_dir}/esviritu-detected-virus-info/${accession}.detected_virus.info.tsv" 2>/dev/null || true
        cp "${esviritu_out}"/*.virus_coverage_windows.tsv \
            "${diff_candidate_dir}/esviritu-virus-coverage-windows/${accession}.virus_coverage_windows.tsv" 2>/dev/null || true
        report_lines+=("## EsViritu: OK")
        report_lines+=("Output: ${esviritu_out}")
    fi
    report_lines+=("")
fi

echo "==> Structural diff against mini fixtures (headers only)"
diff_status=0
diff_output="$(python3 "${diff_script}" \
    --recipes "${goldens_manifest}" \
    --candidate "${diff_candidate_dir}" \
    --set "tier3-${accession}" \
    2>&1)" || diff_status=$?

echo "${diff_output}"
report_lines+=("## Structural diff (schema only)")
report_lines+=("")
report_lines+=('```')
report_lines+=("${diff_output}")
report_lines+=('```')
report_lines+=("")

if [[ ${diff_status} -eq 0 ]]; then
    report_lines+=("Result: no schema drift detected.")
elif [[ ${diff_status} -eq 2 ]]; then
    report_lines+=("Result: schema drift detected (see table above). Value-level differences are informational and do not fail this run; a header change means a parser update is needed.")
else
    report_lines+=("Result: diff could not run cleanly (exit ${diff_status}); see output above.")
fi

printf '%s\n' "${report_lines[@]}" > "${out_dir}/tier3-report.md"
echo "==> Wrote ${out_dir}/tier3-report.md"

if [[ ${pipeline_failures} -gt 0 ]]; then
    exit 1
fi
if [[ ${diff_status} -eq 2 ]]; then
    exit 2
fi
exit 0
