#!/bin/bash
# build-image.sh builds the Lungfish tool image that CHTC jobs run in (CHTC program C4, lane I IMAGE).
#
# It is the executable of a CHTC build job (build-image.sub, +IsBuildJob = true). A build job cannot build from a
# definition file (C0-SLICE0.md:64), so this is C0's sandbox route. It builds a sandbox from the base image pinned by
# digest, installs the tools from the two repository locks with no solve, writes the image's tool manifest, and builds
# the SIF from the sandbox.
#
# Inputs, all in the job's scratch folder (HTCondor flattens the transfer_input_files names there):
#   lge-tools-linux-64-explicit.txt     Sources/LungfishWorkflow/Resources/ManagedTools/, checked against its pinned SHA-256
#   trim_galore-linux-64-explicit.txt   the same folder, installed in its own prefix, checked the same way
#   lungfish-executor                   the stripped x86-64 Linux executor. It runs `image-manifest` once inside the
#                                       sandbox and is deleted right after, so it is never baked in (Q-C3-5 A)
#
# Outputs, every one listed in transfer_output_files and always present (empty after a failed build, so HTCondor
# does not hold the job):
#   lge-tools.sif, image-manifest.json, build-info.txt, installed.explicit.txt, tool-versions.txt
#
# The last lines on stdout are LGE_IMAGE_<KEY>=<value> (see step_record) and end with LGE_IMAGE_STATUS=ok or
# LGE_IMAGE_STATUS=failed step=<step>. Exit status 0 is a good build, 1 a failed build and 64 a usage error.
# The SIF leaves the node under the fixed name lge-tools.sif. The name that carries its digest,
# lge-tools-<first 12 hex of the SIF SHA-256>.sif, is printed as LGE_IMAGE_SIF_NAME and applied on /staging by the
# lane after it checks the hash, as C0 did.
#
# build-image.sh --print-pins prints the pins and the step order and exits, with no build and no network.
# Test hooks used by scripts/tests/test_chtc_image_build.py are LGE_APPTAINER, LGE_BUILD_DIR and LGE_INPUT_DIR.
set -u

# ---- Pins. --print-pins prints these values and the build below reads the same variables. ----
# The base is the linux/amd64 manifest of mambaorg/micromamba 2.9.0-debian12-slim, the digest C0 built from.
BASE_DIGEST="sha256:bba1fff35268813383cb9f92816e862b7580ae2e9493a5ea2d824938c060fe98"
BASE_IMAGE="mambaorg/micromamba@${BASE_DIGEST}"
BASE_URI="docker://${BASE_IMAGE}"
LOCK_FOLDER="Sources/LungfishWorkflow/Resources/ManagedTools"
LOCK_TOOLS="${LOCK_FOLDER}/lge-tools-linux-64-explicit.txt"
LOCK_TOOLS_SHA256="e76f03ec49a9841e13a5fb97e629752b1402690db86315cc4afe50d06638cbb5"
LOCK_TRIM="${LOCK_FOLDER}/trim_galore-linux-64-explicit.txt"
LOCK_TRIM_SHA256="451e1a92edf4b665c8180fb17fedd6caefd40d6ba4de14e78325ad7b40ecec5a"
# The Trim Galore lock has its own prefix, since it pins libgcc, libgomp and libzlib builds of its own.
TOOLS_PREFIX="/opt/lge/env"
TRIM_PREFIX="/opt/lge/trim_galore"
MANIFEST_PATH="/opt/lungfish/image-manifest.json"
EXECUTOR_INPUT_NAME="lungfish-executor"
EXECUTOR_BUILD_ONLY="/opt/lungfish/lungfish-executor.build-only"
# The executables of third-party-tools-lock.linux-64.json. A name the manifest does not resolve fails the build.
REQUIRED_TOOL_IDS="clumpify.sh bbduk.sh bbmerge.sh repair.sh tadpole.sh reformat.sh bbmap.sh mapPacBio.sh java fastp deacon bgzip tabix seqkit trim_galore pigz"
UTILITIES="dirname basename readlink"
UTILITY_DIRECTORIES="/usr/bin /bin"
SIF_SCRATCH_NAME="lge-tools.sif"
# The order the build runs its steps in. executor_remove follows image_manifest with nothing between them.
STEPS="inputs sandbox utilities locks install_tools install_trim_galore clean installed_lists executor_copy image_manifest executor_remove manifest_check environment sif verify record"

print_pins() {
  printf '%s\n' \
    "base_image=$BASE_IMAGE" \
    "base_digest=$BASE_DIGEST" \
    "base_uri=$BASE_URI" \
    "build_route=sandbox" \
    "lock_tools=$LOCK_TOOLS" \
    "lock_tools_sha256=$LOCK_TOOLS_SHA256" \
    "lock_tools_prefix=$TOOLS_PREFIX" \
    "lock_trim_galore=$LOCK_TRIM" \
    "lock_trim_galore_sha256=$LOCK_TRIM_SHA256" \
    "lock_trim_galore_prefix=$TRIM_PREFIX" \
    "manifest_path=$MANIFEST_PATH" \
    "executor_input=$EXECUTOR_INPUT_NAME" \
    "executor_build_only_path=$EXECUTOR_BUILD_ONLY" \
    "required_tool_ids=$REQUIRED_TOOL_IDS" \
    "utilities=$UTILITIES" \
    "utility_directories=$UTILITY_DIRECTORIES" \
    "sif_scratch_name=$SIF_SCRATCH_NAME" \
    "sif_name_pattern=lge-tools-<first 12 hex of the SIF SHA-256>.sif" \
    "steps=$STEPS"
}

usage() {
  echo "usage: build-image.sh [--print-pins]"
}

if [ "$#" -gt 1 ]; then
  echo "build-image.sh: too many arguments" >&2
  usage >&2
  exit 64
fi
case "${1:-}" in
  "") ;;
  --print-pins) print_pins; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "build-image.sh: unknown argument $1" >&2; usage >&2; exit 64 ;;
esac

# The check that runs inside the sandbox on the finished manifest, with the sandbox's own Python.
IFS= read -r -d '' MANIFEST_CHECK <<'PY' || true
import json
import os
import sys

manifest_path, tools_prefix, trim_prefix = sys.argv[1:4]
required = sys.argv[4:]
with open(manifest_path, "rb") as handle:
    manifest = json.load(handle)
problems = []
if manifest.get("schemaVersion") != 1:
    problems.append("schemaVersion is %r, not 1" % (manifest.get("schemaVersion"),))
if manifest.get("platform") != "linux-64":
    problems.append("platform is %r, not linux-64" % (manifest.get("platform"),))
by_id = {}
for tool in manifest.get("tools", []):
    by_id.setdefault(tool["id"], []).append(tool)
for name in required:
    rows = by_id.get(name)
    if not rows:
        problems.append("the manifest lists no tool %s" % name)
    elif len(set((row["version"], row["build"]) for row in rows)) != 1:
        problems.append("the manifest lists %s at more than one version or build" % name)
folders = set(os.path.dirname(by_id[name][0]["path"]) for name in ("bgzip", "clumpify.sh", "reformat.sh") if name in by_id)
if len(folders) > 1:
    problems.append("bgzip, clumpify.sh and reformat.sh are not in one folder (%s)" % ", ".join(sorted(folders)))
for name, prefix in (("java", tools_prefix), ("trim_galore", trim_prefix)):
    for row in by_id.get(name, []):
        if not row["path"].startswith(prefix + "/bin/"):
            problems.append("%s is at %s, not under %s/bin" % (name, row["path"], prefix))
if problems:
    for problem in problems:
        sys.stderr.write("manifest check failed: " + problem + "\n")
    sys.exit(1)
print("manifest check ok: %d tools, %d required ids resolve at one version each" % (len(manifest["tools"]), len(required)))
PY

APPTAINER="${LGE_APPTAINER:-apptainer}"
WORK="${LGE_BUILD_DIR:-${_CONDOR_SCRATCH_DIR:-$PWD}}"
INPUT_DIR="${LGE_INPUT_DIR:-$WORK}"
WORK=$(cd "$WORK" && pwd) || exit 1
INPUT_DIR=$(cd "$INPUT_DIR" && pwd) || exit 1
cd "$WORK" || exit 1
SANDBOX="$WORK/sandbox"
SIF="$WORK/$SIF_SCRATCH_NAME"
LOG="$WORK/build-stdout.txt"
INFO="$WORK/build-info.txt"
: > "$LOG"
: > "$INFO"
export APPTAINER_TMPDIR="$WORK/apptmp" APPTAINER_CACHEDIR="$WORK/appcache"
mkdir -p "$APPTAINER_TMPDIR" "$APPTAINER_CACHEDIR"
umask 022

cleanup() {
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

size_of() {
  wc -c < "$1" | tr -d ' '
}

# ---- Steps. Each prints its reason to the build log and returns non-zero on failure. ----

check_lock() {
  local file got
  file="$INPUT_DIR/$(basename "$1")"
  if [ ! -s "$file" ]; then
    echo "ERROR: the lock $(basename "$1") is missing from $INPUT_DIR"
    return 1
  fi
  got=$(sha256_of "$file")
  if [ "$got" != "$2" ]; then
    echo "ERROR: $(basename "$1") has SHA-256 $got and the script pins $2. Copy the lock from $1 at the lane's commit."
    return 1
  fi
  echo "lock $(basename "$1") sha256 $got matches its pin"
}

step_inputs() {
  local executor="$INPUT_DIR/$EXECUTOR_INPUT_NAME"
  if ! "$APPTAINER" --version >/dev/null 2>&1; then
    echo "ERROR: $APPTAINER does not run on this node"
    return 1
  fi
  check_lock "$LOCK_TOOLS" "$LOCK_TOOLS_SHA256" || return 1
  check_lock "$LOCK_TRIM" "$LOCK_TRIM_SHA256" || return 1
  if [ ! -s "$executor" ]; then
    echo "ERROR: the executor input $executor is missing or empty"
    return 1
  fi
  EXECUTOR_SHA256=$(sha256_of "$executor")
  echo "executor input $EXECUTOR_INPUT_NAME sha256 $EXECUTOR_SHA256 size $(size_of "$executor"), used for the manifest step only"
}

step_sandbox() {
  "$APPTAINER" build --sandbox "$SANDBOX" "$BASE_URI"
}

# Runs one wrapper utility by absolute path inside the sandbox, so PATH plays no part.
run_utility() {
  case "$1" in
    dirname) "$APPTAINER" exec --no-home --cleanenv "$SANDBOX" "$2/dirname" /a/b ;;
    basename) "$APPTAINER" exec --no-home --cleanenv "$SANDBOX" "$2/basename" /a/b ;;
    readlink) "$APPTAINER" exec --no-home --cleanenv "$SANDBOX" "$2/readlink" -f / ;;
  esac
}

expected_utility_output() {
  case "$1" in
    dirname) echo "/a" ;;
    basename) echo "b" ;;
    readlink) echo "/" ;;
  esac
}

# The job wrapper needs dirname, basename and readlink in /usr/bin or /bin (design section 3 and 4). Checked first,
# so a base image without them fails the build in a minute and not after the installs.
step_utilities() {
  local utility directory got found
  for utility in $UTILITIES; do
    found=""
    for directory in $UTILITY_DIRECTORIES; do
      got=$(run_utility "$utility" "$directory" 2>/dev/null)
      if [ "$got" = "$(expected_utility_output "$utility")" ]; then
        found="$directory/$utility"
        break
      fi
    done
    if [ -z "$found" ]; then
      echo "ERROR: the base image holds no working $utility in $UTILITY_DIRECTORIES"
      return 1
    fi
    echo "utility $utility works at $found"
  done
}

step_locks() {
  mkdir -p "$SANDBOX/opt/lge" "$SANDBOX/opt/lungfish" || return 1
  cp "$INPUT_DIR/$(basename "$LOCK_TOOLS")" "$INPUT_DIR/$(basename "$LOCK_TRIM")" "$SANDBOX/opt/lge/"
}

conda_create() {
  "$APPTAINER" exec --writable --no-home --cleanenv --env MAMBA_ROOT_PREFIX=/opt/conda "$SANDBOX" \
    /usr/bin/micromamba create -y --no-rc -p "$1" --file "/opt/lge/$2"
}

step_install_tools() {
  conda_create "$TOOLS_PREFIX" "$(basename "$LOCK_TOOLS")"
}

step_install_trim_galore() {
  conda_create "$TRIM_PREFIX" "$(basename "$LOCK_TRIM")"
}

step_clean() {
  "$APPTAINER" exec --writable --no-home --cleanenv --env MAMBA_ROOT_PREFIX=/opt/conda "$SANDBOX" \
    /usr/bin/micromamba clean -a -y
}

step_installed_lists() {
  local prefix
  : > "$WORK/installed.explicit.txt"
  for prefix in "$TOOLS_PREFIX" "$TRIM_PREFIX"; do
    echo "# prefix $prefix" >> "$WORK/installed.explicit.txt"
    "$APPTAINER" exec --no-home --cleanenv "$SANDBOX" \
      /usr/bin/micromamba list -p "$prefix" --explicit --md5 >> "$WORK/installed.explicit.txt" || return 1
  done
  cp "$WORK/installed.explicit.txt" "$SANDBOX/opt/lge/installed.explicit.txt"
}

step_executor_copy() {
  cp "$INPUT_DIR/$EXECUTOR_INPUT_NAME" "$SANDBOX$EXECUTOR_BUILD_ONLY" || return 1
  chmod 0755 "$SANDBOX$EXECUTOR_BUILD_ONLY"
}

# The image's one tool manifest, written by the repository's own executor (ARCH-r3 ruling 3). The executor prints
# `sha256 <hex> size <bytes> tools <count>`, and the file's own hash and size must agree with that line.
step_image_manifest() {
  local line sha size
  line=$("$APPTAINER" exec --writable --no-home --cleanenv "$SANDBOX" "$EXECUTOR_BUILD_ONLY" image-manifest \
    --conda-prefix "$TOOLS_PREFIX" --conda-prefix "$TRIM_PREFIX" --output "$MANIFEST_PATH") || {
    echo "ERROR: lungfish-executor image-manifest failed"
    return 1
  }
  echo "image-manifest said: $line"
  set -- $line
  if [ "$#" -ne 6 ] || [ "$1" != "sha256" ] || [ "$3" != "size" ] || [ "$5" != "tools" ]; then
    echo "ERROR: the image-manifest line is not 'sha256 <hex> size <bytes> tools <count>'"
    return 1
  fi
  sha=$2
  size=$4
  MANIFEST_TOOLS=$6
  MANIFEST_SHA256=$(sha256_of "$SANDBOX$MANIFEST_PATH")
  MANIFEST_SIZE=$(size_of "$SANDBOX$MANIFEST_PATH")
  if [ "$MANIFEST_SHA256" != "$sha" ] || [ "$MANIFEST_SIZE" != "$size" ]; then
    echo "ERROR: the manifest file has sha256 $MANIFEST_SHA256 and size $MANIFEST_SIZE, the executor said $sha and $size"
    return 1
  fi
  cp "$SANDBOX$MANIFEST_PATH" "$WORK/image-manifest.json"
}

# Deletes the executor and then looks for any file of that name, so the image never holds it (Q-C3-5 A).
step_executor_remove() {
  local stray
  rm -f "$SANDBOX$EXECUTOR_BUILD_ONLY"
  if [ -e "$SANDBOX$EXECUTOR_BUILD_ONLY" ]; then
    echo "ERROR: the build-only executor is still in the sandbox"
    return 1
  fi
  stray=$(find "$SANDBOX" -name 'lungfish-executor*' 2>/dev/null | head -n 1)
  if [ -n "$stray" ]; then
    echo "ERROR: the image would hold the executor at $stray"
    return 1
  fi
  echo "the build-only executor is deleted and no lungfish-executor file remains in the sandbox"
}

step_manifest_check() {
  # shellcheck disable=SC2086
  "$APPTAINER" exec --no-home --cleanenv "$SANDBOX" "$TOOLS_PREFIX/bin/python3" -I -c "$MANIFEST_CHECK" \
    "$MANIFEST_PATH" "$TOOLS_PREFIX" "$TRIM_PREFIX" $REQUIRED_TOOL_IDS
}

step_environment() {
  printf '#!/bin/sh\nexport PATH=%s/bin:%s/bin:$PATH\nexport LC_ALL=C.UTF-8\nexport LANG=C.UTF-8\n' \
    "$TOOLS_PREFIX" "$TRIM_PREFIX" > "$SANDBOX/.singularity.d/env/90-environment.sh" || return 1
  chmod -R a+rX "$SANDBOX/opt/lge" "$SANDBOX/opt/lungfish"
}

step_sif() {
  rm -f "$SIF"
  "$APPTAINER" build "$SIF" "$SANDBOX"
}

# Reads the finished SIF once. The manifest inside it must be the manifest the build wrote.
step_verify() {
  local got
  got=$("$APPTAINER" exec --no-home --cleanenv "$SIF" /usr/bin/sha256sum "$MANIFEST_PATH" | cut -d' ' -f1)
  if [ "$got" != "$MANIFEST_SHA256" ]; then
    echo "ERROR: the manifest inside the SIF has sha256 '$got' and the build wrote $MANIFEST_SHA256"
    return 1
  fi
  echo "the manifest inside the SIF matches"
  "$APPTAINER" exec --no-home --cleanenv "$SIF" bash -c 'echo PATH=$PATH; fastp --version 2>&1; deacon --version 2>&1; seqkit version 2>&1; pigz --version 2>&1; java -version 2>&1; bgzip --version 2>&1 | head -1; python3 --version 2>&1; trim_galore --version 2>&1 | head -3; ls /opt/lge/env/conda-meta | grep -E "^(bbmap|openjdk|fastp|deacon|seqkit|pigz|htslib|python)-"; ls /opt/lge/trim_galore/conda-meta | grep -E "^trim-galore-"' > "$WORK/tool-versions.txt" 2>&1 || true
}

step_record() {
  SIF_SHA256=$(sha256_of "$SIF")
  SIF_SIZE=$(size_of "$SIF")
  case "$SIF_SHA256" in
    *[!0-9a-f]*|"") echo "ERROR: the SIF hash '$SIF_SHA256' is not hexadecimal"; return 1 ;;
  esac
  if [ "${#SIF_SHA256}" -ne 64 ] || [ "$SIF_SIZE" -le 0 ]; then
    echo "ERROR: the SIF hash or size is wrong (sha256 '$SIF_SHA256', size '$SIF_SIZE')"
    return 1
  fi
  SIF_NAME="lge-tools-${SIF_SHA256:0:12}.sif"
  RECORD_LINES=$(printf '%s\n' \
    "LGE_IMAGE_BASE=$BASE_IMAGE" \
    "LGE_IMAGE_LOCK_TOOLS_SHA256=$LOCK_TOOLS_SHA256" \
    "LGE_IMAGE_LOCK_TRIM_GALORE_SHA256=$LOCK_TRIM_SHA256" \
    "LGE_IMAGE_EXECUTOR_SHA256=$EXECUTOR_SHA256" \
    "LGE_IMAGE_MANIFEST_SHA256=$MANIFEST_SHA256" \
    "LGE_IMAGE_MANIFEST_SIZE=$MANIFEST_SIZE" \
    "LGE_IMAGE_MANIFEST_TOOLS=$MANIFEST_TOOLS" \
    "LGE_IMAGE_SIF_NAME=$SIF_NAME" \
    "LGE_IMAGE_SIF_SHA256=$SIF_SHA256" \
    "LGE_IMAGE_SIF_SIZE=$SIF_SIZE")
}

finish_ok() {
  tail -n 60 "$LOG" >> "$INFO"
  printf '%s\nLGE_IMAGE_STATUS=ok\n' "$RECORD_LINES" | tee -a "$INFO"
}

finish_failed() {
  local name
  tail -n 60 "$LOG"
  tail -n 60 "$LOG" >> "$INFO"
  : > "$SIF"
  for name in image-manifest.json installed.explicit.txt tool-versions.txt; do
    [ -e "$WORK/$name" ] || : > "$WORK/$name"
  done
  printf 'LGE_IMAGE_STATUS=failed step=%s\n' "$FAILED_STEP" | tee -a "$INFO"
}

{
  echo "host=$(hostname)"
  echo "date=$(date -u +%FT%TZ)"
  echo "kernel=$(uname -r)"
  echo "apptainer=$("$APPTAINER" --version 2>&1)"
  echo "id=$(id)"
  echo "base=$BASE_IMAGE"
  if [ -r /proc/cpuinfo ]; then grep -m1 'model name' /proc/cpuinfo; fi
  env | grep -i -E "^(apptainer|singularity|tmp|temp|home|xdg)" | sort
} >> "$INFO" 2>&1

FAILED_STEP=""
EXECUTOR_SHA256=""
MANIFEST_SHA256=""
MANIFEST_SIZE=""
MANIFEST_TOOLS=""
RECORD_LINES=""
for step in $STEPS; do
  started=$(date +%s)
  echo "$(date -u +%FT%TZ) step $step"
  if "step_$step" >> "$LOG" 2>&1; then
    echo "step=$step seconds=$(( $(date +%s) - started )) status=ok" >> "$INFO"
  else
    echo "step=$step seconds=$(( $(date +%s) - started )) status=failed" >> "$INFO"
    FAILED_STEP=$step
    break
  fi
done

if [ -z "$FAILED_STEP" ]; then
  finish_ok
  exit 0
fi
finish_failed
exit 1
