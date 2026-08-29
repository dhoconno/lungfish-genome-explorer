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

# Guard against the one mistake that would be expensive: pointing the isolated
# root at the developer's real managed storage, which provisioning would
# rewrite to match the manifest.
#
# Checked BEFORE the --dry-run return, not after. --dry-run is what a developer
# reaches for to see what a command would do, so it is exactly where a bad --root
# should be caught; returning 0 first meant the rehearsal blessed a plan the real
# run would refuse.
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

if [[ ${dry_run} -eq 1 ]]; then
    exit 0
fi

mkdir -p "${storage_root}"
# Fully resolve the root (symlinks included) so registry rewriting compares like
# with like: seed_root realpaths the source, and a storage root reached through
# a symlink would otherwise never match a source-root prefix.
storage_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${storage_root}")"

export LUNGFISH_STORAGE_ROOT="${storage_root}"

# LUNGFISH_CONDA_ROOT is deliberately NOT exported process-wide.
#
# regenerate-goldens.sh needs it, because it defaults the conda root to
# ~/.lungfish/conda rather than deriving it from the storage root, so tier 2
# sets it on that command alone (see run_tier2).
#
# Exporting it globally breaks tier 1. Several NativeToolRunnerTests build stub
# executables under a temporary home and construct a runner with that home, but
# CoreToolLocator.condaRoot(homeDirectory:) resolves through
# ManagedStorageConfigStore.currentCondaRootURL(), which consults
# LUNGFISH_CONDA_ROOT from the process environment and ignores the injected
# home. With the variable set, those tests silently run the real seqkit instead
# of their stub and fail with "unknown command short-output".
conda_root_for_goldens="${storage_root}/conda"
parity_python_root="${storage_root}/parity-python"

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

    rewrite_database_registry "${source_root}"
}

# Repoint the cloned metagenomics database registry at the isolated root.
#
# The registry records each database as an absolute file:// URL. A clone copies
# the database files but leaves every URL pointing back into the source root, so
# without this the isolated root would look provisioned while every database
# lookup -- including the one regenerate-goldens.sh uses to resolve {db} -- read
# the developer's real files. That would quietly defeat the entire point of
# verifying against an isolated root.
#
# Only entries whose files actually came across are rewritten. An entry whose
# path does not exist under the isolated root keeps its original URL, so the
# CLI reports it as missing rather than as a database that is present but
# unreadable.
rewrite_database_registry() {
    local source_root="$1"
    local registry="${storage_root}/databases/metagenomics-db-registry.json"
    [[ -f "${registry}" ]] || return 0

    REGISTRY="${registry}" SOURCE_ROOT="${source_root}" DEST_ROOT="${storage_root}" python3 - <<'PYTHON'
import json
import os
import pathlib
import urllib.parse
import urllib.request

registry = pathlib.Path(os.environ["REGISTRY"])
source_root = os.environ["SOURCE_ROOT"].rstrip("/")
dest_root = os.environ["DEST_ROOT"].rstrip("/")

document = json.loads(registry.read_text(encoding="utf-8"))
rewritten = 0
skipped = []
still_pointing_at_source = []

for database in document.get("databases", []):
    url = database.get("path")
    if not url or not url.startswith("file://"):
        continue
    path = urllib.parse.unquote(urllib.parse.urlparse(url).path)
    if not (path == source_root or path.startswith(source_root + "/")):
        continue
    candidate = dest_root + path[len(source_root):]
    if not os.path.exists(candidate):
        skipped.append(database.get("name", "?"))
        still_pointing_at_source.append(database.get("name", "?"))
        continue
    database["path"] = urllib.parse.urljoin("file:", urllib.request.pathname2url(candidate))
    rewritten += 1

registry.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
print(f"seed: repointed {rewritten} database path(s) at {dest_root}")
if skipped:
    print(f"seed: left {len(skipped)} database path(s) alone (not cloned): {', '.join(skipped)}")

# Rewriting nothing while entries still resolve under the source root means the
# isolated root is not actually isolated for those databases: the CLI would read
# the developer's real files and the tiers would measure the wrong data.
if rewritten == 0 and still_pointing_at_source:
    print(
        "seed: WARNING: rewrote 0 path(s) but "
        f"{len(still_pointing_at_source)} entry/entries still point under {source_root}: "
        f"{', '.join(still_pointing_at_source)}. "
        "Those databases were not cloned into the isolated root, so verification "
        "would read the source root instead."
    )
PYTHON
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

# Reconcile the pack tools too. The two steps above each leave a gap that only
# shows up on a seeded root:
#
#   --required-only deliberately skips packTools entries, because a pack tool
#   is work the user can defer; and `conda install --pack` treats an existing
#   environment as satisfied, so it never notices that a seeded environment
#   holds a different build than the manifest pins.
#
# Together that let a seeded root keep, for example, whatshap built against
# python 3.12 when the manifest pins the 3.11 build. A full apply closes it.
echo "==> Reconciling pack tools against the manifest"
"${cli}" tools update --apply --yes

# These databases are best effort: a database that is already present is a no-op, and
# a download failure is reported by the tier that actually needs the database
# rather than aborting provisioning for the tiers that do not.
"${cli}" conda db download Viral || echo "warn: conda db download Viral failed" >&2
"${cli}" conda db install-managed deacon-panhuman || echo "warn: conda db install-managed deacon-panhuman failed" >&2
"${cli}" esviritu download-db --no-progress || echo "warn: esviritu download-db failed" >&2

# The plan must hold no work that would change what the tiers measure. A pending
# environment install, reinstall, removal, or bootstrap update means the root does
# not match the manifest, so anything the tiers then measure is the wrong
# dependency set.
#
# Advisory database updates are the deliberate exception. Provisioning downloads
# the databases the tiers need but does not chase every optional index the
# manifest happens to pin, so an advisory update is routinely still outstanding
# on a correctly provisioned root. `tools update --plan` exits 10 for any pending
# work at all, advisory included, which made the exit-10 gate below fail a root
# that was in fact aligned. The plan is therefore read from --json and judged on
# its contents rather than on the exit status.
echo "==> Confirming the dependency plan is empty"
plan_status=0
plan_json="$("${cli}" tools update --plan --json 2>/dev/null)" || plan_status=$?
# Exit 10 means "work is pending", which is what the JSON is then inspected to
# classify. Any other non-zero status is the CLI itself failing (bad root,
# unreadable manifest, crash), which is a different problem entirely.
if [[ ${plan_status} -ne 0 && ${plan_status} -ne 10 ]]; then
    echo "verify: 'tools update --plan --json' failed (exit ${plan_status})" >&2
    echo "${plan_json}" >&2
    exit 65
fi

gate_status=0
PLAN_JSON="${plan_json}" python3 - <<'PYTHON' || gate_status=$?
import json
import os
import sys

try:
    plan = json.loads(os.environ["PLAN_JSON"])
except json.JSONDecodeError as error:
    print(f"verify: could not parse the plan JSON: {error}", file=sys.stderr)
    raise SystemExit(2)

blocking = []
for key in ("installEnvironments", "reinstallEnvironments", "removeEnvironments"):
    entries = plan.get(key) or []
    if entries:
        blocking.append(f"{key}: {len(entries)}")
if plan.get("bootstrapUpdate"):
    blocking.append("bootstrapUpdate: 1")

database_updates = plan.get("databaseUpdates") or []
required = [entry for entry in database_updates if entry.get("policy") == "required"]
advisory = [entry for entry in database_updates if entry.get("policy") != "required"]
if required:
    blocking.append(f"required database updates: {len(required)}")

if blocking:
    print("verify: plan not empty after provisioning: " + ", ".join(blocking), file=sys.stderr)
    print(json.dumps(plan, indent=2, sort_keys=True), file=sys.stderr)
    raise SystemExit(1)

# Advisory updates do not change the dependency set the tiers measure, so they are
# reported and the run continues.
if advisory:
    names = ", ".join(entry.get("id", "?") for entry in advisory)
    print(f"verify: {len(advisory)} advisory database update(s) outstanding, continuing: {names}")
else:
    print("verify: dependency plan is empty")
PYTHON

if [[ ${gate_status} -ne 0 ]]; then
    exit 65
fi

provision_parity_python() {
    # The vendored viralrecon oracle runs via `/usr/bin/env python3`. Its
    # packages are test fixtures, not user-facing managed tools, so keep them
    # outside the dependency receipt and below this verifier's isolated root.
    # This mirrors the CI conformance setup while preventing a developer's
    # Homebrew Python packages from making a local sweep pass accidentally.
    echo "==> Provisioning isolated Python dependencies for iVar parity"
    python3 -m venv "${parity_python_root}" || return $?
    "${parity_python_root}/bin/python" -m pip install --upgrade pip || return $?
    "${parity_python_root}/bin/python" -m pip install numpy biopython scipy pandas || return $?
    "${parity_python_root}/bin/python" -c 'import numpy, Bio, scipy, pandas; print("parity deps OK")' || return $?
}

run_tier1() {
    echo "==> Tier 1: conformance suites (no skips allowed)"
    provision_parity_python || return $?
    PATH="${parity_python_root}/bin:${PATH}" \
        bash scripts/full-suite-gate.sh --require-tools --filter "${filter:-${default_tier1_filter}}" || return $?
}

run_tier2() {
    echo "==> Tier 2: golden regeneration and diff"
    local out=".build/goldens-${dependency_set}"
    rm -rf "${out}"
    # Scoped to this command rather than exported: see the note where
    # conda_root_for_goldens is set.
    LUNGFISH_CONDA_ROOT="${conda_root_for_goldens}" \
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
    # --root is passed explicitly rather than relying on the exported
    # LUNGFISH_STORAGE_ROOT, so the isolated root the tier runs against is visible
    # in the command itself.
    bash scripts/deps/run-pipelines.sh \
        --which all \
        --out ".build/pipelines-${dependency_set}" \
        --root "${storage_root}"
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
