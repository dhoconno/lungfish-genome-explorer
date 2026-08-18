#!/usr/bin/env bash
#
# Provision an isolated storage root from the current dependency manifest and
# run the regression tiers against it.
#
# The point of the isolated root is that the manifest, not the developer's
# accumulated ~/.lungfish, decides what the tests run against. A sweep that
# verified against the real root would happily pass with a tool the manifest no
# longer pins, because that tool is still sitting in the developer's conda root
# from some earlier release.
#
# Usage:
#   bash scripts/deps/verify.sh --tier 1|2|3|all [options]
#
# Options:
#   --tier <1|2|3|all>   which regression tier(s) to run (default: 1)
#   --root <dir>         isolated storage root (default: $HOME/.lungfish-verify)
#   --seed-from <dir>    APFS-clone an existing root's conda/ and databases/
#                        into an empty --root, so provisioning reconciles a few
#                        environments instead of downloading tens of gigabytes
#   --filter <regex>     override the tier 1 swift test filter
#   --keep               (accepted for symmetry; the root is always kept)
#   --dry-run            print the resolved plan line and exit 0
#
# Tiers:
#   1   conformance suites via full-suite-gate.sh --require-tools (no skips)
#   2   regenerate the golden outputs and diff them against the committed set
#   3   the manual end-to-end pipeline runner (network and database heavy)
#
# Exit codes:
#   0   the requested tier(s) passed
#   1   a tier failed
#   2   tier 2 found golden drift (diff_goldens.py exit 2)
#   3   tier 2 has no committed goldens for this dependency set yet
#   64  bad arguments
#   65  the dependency plan was not empty after provisioning
#
# NEVER point --root at the real ~/.lungfish: provisioning reinstalls
# environments to match the manifest, which would rewrite the developer's root.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
cd "${repo_root}"

manifest="Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"

tier="1"
storage_root="${LUNGFISH_VERIFY_ROOT:-${HOME}/.lungfish-verify}"
seed_from=""
filter=""
keep=0
dry_run=0

# The tier 1 default filter. This must name the same suites as the
# toolset-conformance job in .github/workflows/ci.yml, so that a local sweep
# and CI check the same thing; scripts/tests/test_verify_script.py asserts the
# two strings are equal.
default_tier1_filter='Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineIntegrationTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests|FASTQIngestionPipelineTests|FASTQBatchImporterRecipeIntegrationTests|GenotypeWorkbookManagedRuntimeProbeTests|FASTQOperationRoundTripTests|FastqGenotypingCommandTests|PrimerTrimThenIVarTests|ExtractReadsByIdBAMProcessTests'

# The packs the conformance suites need, matching the CI job's provisioning.
conformance_packs=(
    read-mapping
    assembly
    phylogenetics
    multiple-sequence-alignment
    metagenomics
    full-length-mhc-genotyping
    variant-calling
)

usage() {
    sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'
}

# Reject a value-taking flag that was given no value. Without this, `shift 2`
# on a one-element argument list aborts under `set -u` with an opaque message,
# or leaves the variable empty and the run proceeds against a wrong target.
# 64 is EX_USAGE, matching the unknown-argument arm below.
require_value() {
    local flag="$1" remaining="$2"
    if [[ ${remaining} -lt 2 ]]; then
        echo "${flag} requires a value" >&2
        exit 64
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)
            require_value "$1" $#
            tier="$2"
            shift 2
            ;;
        --root)
            require_value "$1" $#
            storage_root="$2"
            shift 2
            ;;
        --seed-from)
            require_value "$1" $#
            seed_from="$2"
            shift 2
            ;;
        --filter)
            require_value "$1" $#
            filter="$2"
            shift 2
            ;;
        --keep)
            keep=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
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

# Validate the tier before doing any work, so a typo fails in a second rather
# than after twenty minutes of provisioning.
case "${tier}" in
    1|2|3|all) ;;
    *)
        echo "error: --tier must be one of 1, 2, 3, all (got: ${tier})" >&2
        exit 64
        ;;
esac

if [[ ! -f "${manifest}" ]]; then
    echo "dependency manifest not found: ${manifest}" >&2
    exit 66
fi

dependency_set="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencySet"])' "${manifest}")"
manifest_hash="$(shasum -a 256 "${manifest}" | cut -d' ' -f1)"

echo "verify: set=${dependency_set} manifest=${manifest_hash} root=${storage_root} tier=${tier}"

if [[ ${dry_run} -eq 1 ]]; then
    exit 0
fi

# Guard against the one mistake that would be expensive: pointing the isolated
# root at the developer's real managed storage, which provisioning would
# rewrite to match the manifest.
real_root="$(cd "${HOME}" && pwd)/.lungfish"
resolved_root="${storage_root}"
case "${resolved_root}" in
    "~"/*) resolved_root="${HOME}/${resolved_root#\~/}" ;;
esac
if [[ "$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "${resolved_root}")" \
      == "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${real_root}")" ]]; then
    echo "error: --root must not be the real managed storage root (${real_root})" >&2
    echo "       verify.sh reinstalls environments to match the manifest." >&2
    exit 64
fi

mkdir -p "${storage_root}"
storage_root="$(cd "${storage_root}" && pwd)"

export LUNGFISH_STORAGE_ROOT="${storage_root}"
# The golden regenerator resolves environments from LUNGFISH_CONDA_ROOT, which
# defaults to ~/.lungfish/conda rather than deriving from the storage root, so
# it has to be pointed at the isolated root explicitly or tier 2 would measure
# the developer's environments.
export LUNGFISH_CONDA_ROOT="${storage_root}/conda"

# Seed the isolated root from an existing one. On APFS `cp -Rc` clones blocks
# rather than copying them, so a 21 GB conda root is seeded in seconds and
# costs no additional disk until the reconciler rewrites an environment.
#
# /bin/cp by absolute path: a GNU coreutils `cp` earlier on PATH has no -c.
#
# Only an empty root is seeded. Re-seeding a root that already has environments
# would overwrite whatever the last run reconciled, silently undoing the
# manifest alignment this script exists to establish.
seed_root() {
    local source_root="$1"
    source_root="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "${source_root}")"

    if [[ ! -d "${source_root}" ]]; then
        echo "error: --seed-from directory not found: ${source_root}" >&2
        exit 66
    fi

    local component
    for component in conda databases; do
        local source="${source_root}/${component}"
        local destination="${storage_root}/${component}"
        [[ -d "${source}" ]] || continue
        if [[ -e "${destination}" ]]; then
            echo "seed: ${component} already present in ${storage_root}, leaving it alone"
            continue
        fi
        echo "seed: cloning ${source} -> ${destination}"
        if /bin/cp -Rc "${source}" "${destination}" 2>/dev/null; then
            continue
        fi
        # A wholesale clone can fail on the package cache, whose directories may
        # carry a setgid bit that cp cannot reproduce. Fall back to cloning the
        # parts that matter: envs and bin. The package cache is deliberately not
        # reconstructed -- micromamba re-downloads any package it needs, and
        # skipping it costs a little network rather than correctness.
        echo "seed: wholesale clone failed, cloning envs/bin only" >&2
        rm -rf "${destination}"
        mkdir -p "${destination}"
        local sub
        for sub in envs bin etc; do
            [[ -d "${source}/${sub}" ]] || continue
            /bin/cp -Rc "${source}/${sub}" "${destination}/${sub}"
        done
    done
}

if [[ -n "${seed_from}" ]]; then
    seed_root "${seed_from}"
fi

echo "==> Building lungfish-cli"
swift build --product lungfish-cli >/dev/null
cli="${repo_root}/.build/debug/lungfish-cli"

echo "==> Provisioning ${storage_root} from ${manifest}"
# Idempotent: the reconciler compares the receipt and the installed conda-meta
# records against the manifest and only works the difference.
"${cli}" tools update --apply --yes --required-only

for pack in "${conformance_packs[@]}"; do
    echo "==> conda install --pack ${pack}"
    "${cli}" conda install --pack "${pack}"
done

# These two are best effort: a database that is already present is a no-op, and
# a download failure is reported by the tier that actually needs the database
# rather than aborting provisioning for the tiers that do not.
"${cli}" conda db download Viral || echo "warn: conda db download Viral failed" >&2
"${cli}" conda db install-managed deacon-panhuman || echo "warn: conda db install-managed deacon-panhuman failed" >&2

# The plan must be empty after provisioning. A non-empty plan means the root
# does not match the manifest, so anything the tiers then measure is measuring
# the wrong dependency set. `tools update --plan` exits 10 when work is pending.
echo "==> Confirming the dependency plan is empty"
plan_status=0
plan_output="$("${cli}" tools update --plan 2>&1)" || plan_status=$?
if [[ ${plan_status} -ne 0 ]]; then
    echo "verify: plan not empty after provisioning (exit ${plan_status})" >&2
    echo "${plan_output}" >&2
    exit 65
fi
echo "${plan_output}"

run_tier1() {
    echo "==> Tier 1: conformance suites (no skips allowed)"
    bash scripts/full-suite-gate.sh --require-tools --filter "${filter:-${default_tier1_filter}}"
}

run_tier2() {
    echo "==> Tier 2: golden regeneration and diff"
    local out=".build/goldens-${dependency_set}"
    rm -rf "${out}"
    bash scripts/deps/regenerate-goldens.sh --set "${dependency_set}" --out "${out}"

    local diff_status=0
    python3 scripts/deps/diff_goldens.py \
        --recipes scripts/deps/goldens.json \
        --candidate "${out}" \
        --set "${dependency_set}" || diff_status=$?

    if [[ ${diff_status} -eq 3 ]]; then
        # Exit 3 means there is no committed golden set for this dependency set
        # yet, which is the expected state the first time a sweep runs at a new
        # set. Copying the candidate in is a deliberate review step, not
        # something this script should do on the sweep's behalf.
        echo "verify: goldens missing for set ${dependency_set}; review ${out} and copy in deliberately" >&2
        return 3
    fi
    return ${diff_status}
}

run_tier3() {
    echo "==> Tier 3: end-to-end pipelines"
    bash scripts/deps/run-pipelines.sh --which all --out ".build/pipelines-${dependency_set}"
}

# Capture the tier's status rather than letting `set -e` abort on it, so the
# "keeping <root>" line below still prints on a failing run. Without the
# `|| tier_status=$?` the script would exit at the first failing tier and the
# caller would lose the reminder that the provisioned root is still there.
tier_status=0
case "${tier}" in
    1) run_tier1 || tier_status=$? ;;
    2) run_tier2 || tier_status=$? ;;
    3) run_tier3 || tier_status=$? ;;
    all)
        # Stop at the first failing tier: tier 2's goldens are meaningless if
        # tier 1 says the tools themselves are wrong.
        run_tier1 && run_tier2 && run_tier3 || tier_status=$?
        ;;
esac

if [[ ${keep} -eq 1 ]]; then
    echo "verify: --keep given; ${storage_root} retained"
else
    # The root is always retained: it is expensive to build and reusing it is
    # what makes a second sweep run fast. --keep exists so a caller can say so
    # explicitly, and this line documents the default for everyone else.
    echo "verify: keeping ${storage_root} for reuse (pass --root to change)"
fi

exit ${tier_status}
