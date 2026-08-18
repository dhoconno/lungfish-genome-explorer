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

usage() {
    echo "usage: $(basename "$0") --set <id> --out <dir> [--only id,...] [--recipes <path>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --set)
            dependency_set="${2:-}"
            shift 2
            ;;
        --out)
            out_dir="${2:-}"
            shift 2
            ;;
        --only)
            only="${2:-}"
            shift 2
            ;;
        --recipes)
            recipes="${2:-}"
            shift 2
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
# Done in python so paths containing spaces or regex metacharacters survive.
expand_command() {
    local template="$1" recipe_out="$2" db_path="$3" inputs_joined="$4"
    TEMPLATE="${template}" RECIPE_OUT="${recipe_out}" DB_PATH="${db_path}" \
    INPUTS="${inputs_joined}" REPO_ROOT="${repo_root}" CONDA_ROOT="${conda_root}" python3 - <<'PYTHON'
import os
import re

template = os.environ["TEMPLATE"]
repo_root = os.environ["REPO_ROOT"]
conda_root = os.environ["CONDA_ROOT"]
inputs = [value for value in os.environ["INPUTS"].split("\n") if value]

replacements = {"{out}": os.environ["RECIPE_OUT"]}
if os.environ.get("DB_PATH"):
    replacements["{db}"] = os.environ["DB_PATH"]
for index, relative in enumerate(inputs):
    replacements[f"{{in{index}}}"] = os.path.join(repo_root, relative)

# Any remaining {name} placeholder names a helper tool from another recipe's
# environment (for example {samtools} inside the minimap2 recipe): resolve it to
# that tool's absolute path under the conda root.
def helper(match):
    name = match.group(1)
    return os.path.join(conda_root, "envs", name, "bin", name)

for placeholder, value in replacements.items():
    template = template.replace(placeholder, value)
print(re.sub(r"\{([a-z0-9_.-]+)\}", helper, template), end="")
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
    TOOL_VERSION="$6" WALL_SECONDS="$7" python3 - <<'PYTHON'
import datetime
import json
import os

record = {
    "dependencySet": os.environ["DEPENDENCY_SET"],
    "recipeID": os.environ["RECIPE_ID"],
    "tool": os.environ["TOOL"],
    "environment": os.environ["ENV_NAME"],
    "toolVersion": os.environ["TOOL_VERSION"],
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "wallTimeSeconds": int(os.environ["WALL_SECONDS"]),
}
with open(os.environ["META_PATH"], "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PYTHON
}

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
        sys.stderr.write(f"unknown recipe ids: {', '.join(sorted(unknown))}\n")
        sys.exit(1)
    ids = [value for value in ids if value in wanted]
print("\n".join(ids))
PYTHON
)"

if [[ -z "${recipe_ids}" ]]; then
    echo "no recipes selected" >&2
    exit 64
fi

failures=0

while IFS= read -r recipe_id; do
    [[ -n "${recipe_id}" ]] || continue

    fields="$(recipe_fields "${recipe_id}")"
    eval "${fields}"

    env_bin="${conda_root}/envs/${recipe_env}/bin"
    if [[ ! -d "${env_bin}" ]]; then
        echo "SKIP ${recipe_id}: environment not installed: ${env_bin}" >&2
        failures=$((failures + 1))
        continue
    fi

    db_path=""
    if [[ -n "${recipe_database}" ]]; then
        if ! db_path="$(resolve_database "${recipe_database}")"; then
            echo "SKIP ${recipe_id}: could not resolve database ${recipe_database}" >&2
            failures=$((failures + 1))
            continue
        fi
    fi

    recipe_out="${out_dir}/${recipe_id}"
    rm -rf "${recipe_out}"
    mkdir -p "${recipe_out}"

    expanded="$(expand_command "${recipe_command}" "${recipe_out}" "${db_path}" "${recipe_inputs}")"

    echo "RUN  ${recipe_id}"
    start_seconds="$(date +%s)"
    status=0
    PATH="${env_bin}:${PATH}" bash -o pipefail -c "${expanded}" || status=$?
    end_seconds="$(date +%s)"

    if [[ ${status} -ne 0 ]]; then
        echo "FAIL ${recipe_id}: command exited ${status}" >&2
        echo "     ${expanded}" >&2
        failures=$((failures + 1))
        continue
    fi

    tool_version="$(installed_tool_version "${recipe_env}" "${recipe_tool}")"

    write_meta "${recipe_out}/meta.json" "${dependency_set}" "${recipe_id}" \
        "${recipe_tool}" "${recipe_env}" "${tool_version}" "$((end_seconds - start_seconds))"

    echo "OK   ${recipe_id} (${recipe_tool} ${tool_version:-unknown})"
done <<< "${recipe_ids}"

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} recipe(s) failed or were skipped" >&2
    exit 1
fi

echo "wrote goldens to ${out_dir}"
