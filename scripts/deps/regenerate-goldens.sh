#!/usr/bin/env bash
#
# Regenerate the golden outputs declared in scripts/deps/goldens.json.
#
# Each recipe runs its tool from the conda environment the manifest names, with
# that environment's bin directory first on PATH, and writes its declared
# outputs plus a meta.json into <out>/<recipe id>/.
#
# Usage:
#   bash scripts/deps/regenerate-goldens.sh --set 2026.1 --out /tmp/goldens-2026.1
#   bash scripts/deps/regenerate-goldens.sh --set 2026.1 --out /tmp/g --only sarscov2-flagstat,sarscov2-idxstats
#
# Compare the result against the committed goldens with:
#   python3 scripts/deps/diff_goldens.py --recipes scripts/deps/goldens.json \
#       --candidate /tmp/goldens-2026.1 --set 2026.1

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
recipes="${script_dir}/goldens.json"

conda_root="${LUNGFISH_CONDA_ROOT:-${HOME}/.lungfish/conda}"
storage_root="${LUNGFISH_STORAGE_ROOT:-${HOME}/.lungfish}"
registry_json="${storage_root}/databases/metagenomics-db-registry.json"

dependency_set=""
out_dir=""
only=""
print_command=0

usage() {
    echo "usage: $(basename "$0") --set <id> --out <dir> [--only id,...] [--recipes <path>] [--print-command]" >&2
}

# Reject a value-taking flag that was given no value. Without this, `shift 2`
# on a one-element argument list aborts under `set -u` with an opaque message,
# or (worse) leaves the variable empty and the run proceeds with a wrong value.
# 64 is EX_USAGE, matching the unknown-argument arm below.
require_value() {
    local flag="$1" remaining="$2"
    if [[ ${remaining} -lt 2 ]]; then
        echo "${flag} requires a value" >&2
        usage
        exit 64
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --set)
            require_value "$1" $#
            dependency_set="$2"
            shift 2
            ;;
        --out)
            require_value "$1" $#
            out_dir="$2"
            shift 2
            ;;
        --only)
            require_value "$1" $#
            only="$2"
            shift 2
            ;;
        --recipes)
            require_value "$1" $#
            recipes="$2"
            shift 2
            ;;
        --print-command)
            # Debug aid: print each recipe's fully expanded command and exit
            # without running anything. Used by scripts/tests to assert that
            # substituted paths are shell-safe.
            print_command=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage
            exit 64
            ;;
    esac
done

if [[ -z "${dependency_set}" || -z "${out_dir}" ]]; then
    usage
    exit 64
fi
if [[ ! -f "${recipes}" ]]; then
    echo "recipe manifest not found: ${recipes}" >&2
    exit 66
fi

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"

# Resolve a named database to its on-disk path via the metagenomics registry.
# The registry stores paths as file:// URLs; strip the scheme and percent-decode.
resolve_database() {
    local name="$1"
    REGISTRY_JSON="${registry_json}" DB_NAME="${name}" python3 - <<'PYTHON'
import json
import os
import sys
import urllib.parse

registry = os.environ["REGISTRY_JSON"]
name = os.environ["DB_NAME"]
if not os.path.isfile(registry):
    sys.stderr.write(f"database registry not found: {registry}\n")
    sys.exit(1)
with open(registry, encoding="utf-8") as handle:
    document = json.load(handle)
for database in document.get("databases", []):
    if database.get("name") != name:
        continue
    path = database.get("path")
    if not path:
        sys.stderr.write(f"database {name!r} has no path (status {database.get('status')!r})\n")
        sys.exit(1)
    if path.startswith("file://"):
        path = urllib.parse.unquote(urllib.parse.urlparse(path).path)
    print(path)
    sys.exit(0)
sys.stderr.write(f"database {name!r} is not registered in {registry}\n")
sys.exit(1)
PYTHON
}

# Substitute {in0}, {out}, {db}, and {tool} placeholders into a recipe command.
#
# Substituted values are made shell-safe so a path containing spaces, quotes, or
# other metacharacters cannot split into extra words or inject shell syntax when
# the result is handed to `bash -c`. Quoting is context sensitive because several
# recipes embed a placeholder inside a single-quoted fragment (a `sed` script, an
# inline `python3 -c` program):
#
#   bare            {out}/x.tsv        -> shlex.quote, becoming '/path/x.tsv'
#   single-quoted   sed 's#{out}/##'   -> escaped for that context, no new quotes
#
# Wrapping a bare placeholder in your own quotes in a recipe would nest quotes and
# break the command, so recipes always write placeholders bare or inside an
# existing single-quoted fragment.
expand_command() {
    local template="$1" recipe_out="$2" db_path="$3" inputs_joined="$4"
    TEMPLATE="${template}" RECIPE_OUT="${recipe_out}" DB_PATH="${db_path}" \
    INPUTS="${inputs_joined}" REPO_ROOT="${repo_root}" CONDA_ROOT="${conda_root}" python3 - <<'PYTHON'
import os
import re
import shlex

template = os.environ["TEMPLATE"]
repo_root = os.environ["REPO_ROOT"]
conda_root = os.environ["CONDA_ROOT"]
inputs = [value for value in os.environ["INPUTS"].split("\n") if value]

values = {"out": os.environ["RECIPE_OUT"]}
if os.environ.get("DB_PATH"):
    values["db"] = os.environ["DB_PATH"]
for index, relative in enumerate(inputs):
    values[f"in{index}"] = os.path.join(repo_root, relative)


def inside_single_quotes(text, position):
    """True when `position` in `text` falls inside a single-quoted fragment."""
    return text.count("'", 0, position) % 2 == 1


def resolve(name):
    """The raw value for a placeholder name, resolving helper tools by convention."""
    if name in values:
        return values[name]
    # Any other {name} names a helper tool from another recipe's environment
    # (for example {samtools} inside the minimap2 recipe).
    return os.path.join(conda_root, "envs", name, "bin", name)


def substitute(match):
    value = resolve(match.group(1))
    if inside_single_quotes(template, match.start()):
        # Already inside single quotes: close, emit an escaped quote for any
        # literal quote in the value, and reopen, adding no unbalanced quotes.
        return value.replace("'", "'\\''")
    return shlex.quote(value)


print(re.sub(r"\{([a-z0-9_.-]+\d*)\}", substitute, template), end="")
PYTHON
}

# Emit one recipe's fields as shell assignments, so values containing spaces,
# quotes, or pipes survive the trip through the shell intact.
recipe_fields() {
    local recipe_id="$1"
    RECIPES="${recipes}" ID="${recipe_id}" python3 - <<'PYTHON'
import json
import os
import shlex

with open(os.environ["RECIPES"], encoding="utf-8") as handle:
    manifest = json.load(handle)
recipe = next(r for r in manifest["goldens"] if r["id"] == os.environ["ID"])
fields = {
    "recipe_env": recipe["env"],
    "recipe_tool": recipe["tool"],
    "recipe_command": recipe["command"],
    "recipe_inputs": "\n".join(recipe.get("inputs", [])),
    "recipe_database": recipe.get("database", ""),
}
for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
PYTHON
}

# Read the installed version of a tool from its environment's conda-meta
# records, rather than shelling out to each tool with its own --version dialect.
installed_tool_version() {
    local env_name="$1" tool="$2"
    CONDA_ROOT="${conda_root}" ENV_NAME="${env_name}" TOOL="${tool}" python3 - <<'PYTHON'
import json
import os
import pathlib

conda_meta = pathlib.Path(os.environ["CONDA_ROOT"], "envs", os.environ["ENV_NAME"], "conda-meta")
tool = os.environ["TOOL"]
version = ""
if conda_meta.is_dir():
    for record in sorted(conda_meta.glob("*.json")):
        try:
            document = json.loads(record.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if document.get("name") == tool:
            version = str(document.get("version", ""))
            break
print(version)
PYTHON
}

# Write the per-recipe meta.json recording how this golden was produced.
write_meta() {
    META_PATH="$1" DEPENDENCY_SET="$2" RECIPE_ID="$3" TOOL="$4" ENV_NAME="$5" \
    TOOL_VERSION="$6" START_SECONDS="$7" END_SECONDS="$8" python3 - <<'PYTHON'
import datetime
import json
import os

elapsed = float(os.environ["END_SECONDS"]) - float(os.environ["START_SECONDS"])
record = {
    "dependencySet": os.environ["DEPENDENCY_SET"],
    "recipeID": os.environ["RECIPE_ID"],
    "tool": os.environ["TOOL"],
    "environment": os.environ["ENV_NAME"],
    "toolVersion": os.environ["TOOL_VERSION"],
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "wallTimeSeconds": round(elapsed, 3),
}
with open(os.environ["META_PATH"], "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PYTHON
}

# Capture the selection separately from the assignment so the selector's exit
# code survives (an assignment always reports the assignment's own status).
select_status=0
recipe_ids="$(ONLY="${only}" RECIPES="${recipes}" python3 - <<'PYTHON'
import json
import os
import sys

with open(os.environ["RECIPES"], encoding="utf-8") as handle:
    manifest = json.load(handle)
ids = [recipe["id"] for recipe in manifest.get("goldens", [])]
only = os.environ.get("ONLY", "").strip()
if only:
    wanted = {value.strip() for value in only.split(",") if value.strip()}
    unknown = wanted - set(ids)
    if unknown:
        # 64 is EX_USAGE: a bad --only value is an argument error, not a run failure.
        sys.stderr.write(f"unknown recipe ids: {', '.join(sorted(unknown))}\n")
        sys.exit(64)
    ids = [value for value in ids if value in wanted]
print("\n".join(ids))
PYTHON
)" || select_status=$?

if [[ ${select_status} -ne 0 ]]; then
    exit "${select_status}"
fi
if [[ -z "${recipe_ids}" ]]; then
    echo "no recipes selected" >&2
    exit 64
fi

failures=0
skips=0

while IFS= read -r recipe_id; do
    [[ -n "${recipe_id}" ]] || continue

    fields="$(recipe_fields "${recipe_id}")"
    eval "${fields}"

    if [[ ${print_command} -eq 1 ]]; then
        # Expand only. The database is resolved when available but never
        # required, so this stays usable on a machine without the databases.
        db_path=""
        if [[ -n "${recipe_database}" ]]; then
            db_path="$(resolve_database "${recipe_database}" 2>/dev/null || true)"
        fi
        expand_command "${recipe_command}" "${out_dir}/${recipe_id}" "${db_path}" "${recipe_inputs}"
        echo
        continue
    fi

    env_bin="${conda_root}/envs/${recipe_env}/bin"
    if [[ ! -d "${env_bin}" ]]; then
        echo "SKIP ${recipe_id}: environment not installed: ${env_bin}" >&2
        skips=$((skips + 1))
        continue
    fi

    db_path=""
    if [[ -n "${recipe_database}" ]]; then
        if ! db_path="$(resolve_database "${recipe_database}")"; then
            echo "SKIP ${recipe_id}: could not resolve database ${recipe_database}" >&2
            skips=$((skips + 1))
            continue
        fi
    fi

    recipe_out="${out_dir}/${recipe_id}"
    rm -rf "${recipe_out}"
    mkdir -p "${recipe_out}"

    expanded="$(expand_command "${recipe_command}" "${recipe_out}" "${db_path}" "${recipe_inputs}")"

    echo "RUN  ${recipe_id}"
    # python rather than `date +%s.%N`, which is GNU-only and prints a literal
    # "N" on macOS/BSD.
    start_seconds="$(python3 -c 'import time; print(time.time())')"
    status=0
    PATH="${env_bin}:${PATH}" bash -o pipefail -c "${expanded}" || status=$?
    end_seconds="$(python3 -c 'import time; print(time.time())')"

    if [[ ${status} -ne 0 ]]; then
        echo "FAIL ${recipe_id}: command exited ${status}" >&2
        echo "     ${expanded}" >&2
        failures=$((failures + 1))
        continue
    fi

    tool_version="$(installed_tool_version "${recipe_env}" "${recipe_tool}")"

    write_meta "${recipe_out}/meta.json" "${dependency_set}" "${recipe_id}" \
        "${recipe_tool}" "${recipe_env}" "${tool_version}" "${start_seconds}" "${end_seconds}"

    echo "OK   ${recipe_id} (${recipe_tool} ${tool_version:-unknown})"
done <<< "${recipe_ids}"

if [[ ${print_command} -eq 1 ]]; then
    exit 0
fi

# A skip means the machine lacks a tool environment or database, which is an
# environment gap rather than a tool regression, so it gets its own exit code
# (3) to keep it distinguishable from a recipe that actually failed (1).
if [[ ${failures} -gt 0 ]]; then
    echo "${failures} recipe(s) failed, ${skips} skipped" >&2
    exit 1
fi
if [[ ${skips} -gt 0 ]]; then
    echo "${skips} recipe(s) skipped: tool environment or database not installed" >&2
    exit 3
fi

echo "wrote goldens to ${out_dir}"
