#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

task9_suite=""
task9_base_sha=""
task9_implementation_sha=""
task9_report=""
task9_argument_error=""

while (($#)); do
  case "$1" in
    --suite)
      if (($# < 2)); then
        task9_argument_error="Missing value for --suite"
        shift
        continue
      fi
      task9_suite="${2-}"
      shift 2
      ;;
    --base-sha)
      if (($# < 2)); then
        task9_argument_error="Missing value for --base-sha"
        shift
        continue
      fi
      task9_base_sha="${2-}"
      shift 2
      ;;
    --implementation-sha)
      if (($# < 2)); then
        task9_argument_error="Missing value for --implementation-sha"
        shift
        continue
      fi
      task9_implementation_sha="${2-}"
      shift 2
      ;;
    --report)
      if (($# < 2)); then
        task9_argument_error="Missing value for --report"
        shift
        continue
      fi
      task9_report="${2-}"
      shift 2
      ;;
    *)
      task9_argument_error="Unknown argument: $1"
      shift
      ;;
  esac
done

if task9_caller_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  task9_caller_root="$(pwd -P)"
fi
case "$task9_suite" in
  ci-focused|focused|scientific|full)
    task9_artifact_suite="$task9_suite"
    ;;
  *)
    task9_artifact_suite="unknown"
    ;;
esac
task9_output_directory="$task9_caller_root/.build/project-storage-skip-comparison"
if [[ -z "$task9_report" ]]; then
  task9_report="$task9_output_directory/$task9_artifact_suite-report.json"
elif [[ "$task9_report" != /* ]]; then
  task9_report="$task9_caller_root/$task9_report"
fi

task9_base_log="$task9_output_directory/$task9_artifact_suite-base.log"
task9_base_status="$task9_output_directory/$task9_artifact_suite-base-status.json"
task9_implementation_log="$task9_output_directory/$task9_artifact_suite-implementation.log"
task9_implementation_status="$task9_output_directory/$task9_artifact_suite-implementation-status.json"

task9_policy="$task9_caller_root/scripts/verification/project-storage-task9-skip-policy.json"
task9_comparator="$task9_caller_root/scripts/verification/compare_project_storage_skips.py"
task9_root_subshell_level="$BASH_SUBSHELL"
task9_report_finalized=0

task9_write_failure_report() {
  local task9_error="$1"
  python3 - \
    "$task9_report" \
    "$task9_error" \
    "$task9_base_log" \
    "$task9_base_status" \
    "$task9_implementation_log" \
    "$task9_implementation_status" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
error = sys.argv[2]
base_log = Path(sys.argv[3])
base_status = Path(sys.argv[4])
implementation_log = Path(sys.argv[5])
implementation_status = Path(sys.argv[6])


def ensure_artifacts(log_path, status_path):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if not log_path.exists():
        log_path.write_bytes(b"")
    try:
        status = json.loads(status_path.read_text(encoding="utf-8"))
        valid_status = all(
            isinstance(status[key], int)
            for key in ("swiftStatus", "teeStatus")
        )
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        valid_status = False
    if not valid_status:
        status_path.write_text(
            '{\n  "swiftStatus": 125,\n  "teeStatus": 125\n}\n',
            encoding="utf-8",
        )


def status_value(path, key):
    try:
        return int(json.loads(path.read_text(encoding="utf-8"))[key])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return 125


def raw_metadata(log_path, status_path):
    data = log_path.read_bytes()
    return {
        "path": str(log_path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "swiftStatus": status_value(status_path, "swiftStatus"),
        "teeStatus": status_value(status_path, "teeStatus"),
    }


ensure_artifacts(base_log, base_status)
ensure_artifacts(implementation_log, implementation_status)
try:
    report = json.loads(report_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    report = {"schemaVersion": 1}
report.update(
    {
        "passed": False,
        "error": error,
        "rawLogs": {
            "base": raw_metadata(base_log, base_status),
            "implementation": raw_metadata(
                implementation_log,
                implementation_status,
            ),
        },
    }
)
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

task9_finalize_on_exit() {
  local task9_status=$?
  if [[ "$BASH_SUBSHELL" != "$task9_root_subshell_level" ]]; then
    return "$task9_status"
  fi
  trap - EXIT
  set +e
  if declare -F task9_cleanup >/dev/null; then
    task9_cleanup
  fi
  if [[ "$task9_status" -ne 0 && "$task9_report_finalized" -ne 1 ]]; then
    task9_write_failure_report \
      "runner infrastructure failure (exit status $task9_status)"
  fi
  exit "$task9_status"
}
trap task9_finalize_on_exit EXIT

mkdir -p "$task9_output_directory"
mkdir -p "$(dirname "$task9_report")"
: >"$task9_report"
: >"$task9_base_log"
: >"$task9_implementation_log"
printf '{\n  "swiftStatus": 125,\n  "teeStatus": 125\n}\n' \
  >"$task9_base_status"
printf '{\n  "swiftStatus": 125,\n  "teeStatus": 125\n}\n' \
  >"$task9_implementation_status"

task9_emit_preflight_report() {
  local task9_error="$1"
  if [[ -f "$task9_comparator" && -f "$task9_policy" ]]; then
    python3 \
      "$task9_comparator" \
      --policy "$task9_policy" \
      --base-log "$task9_base_log" \
      --implementation-log "$task9_implementation_log" \
      --base-swift-status 125 \
      --base-tee-status 125 \
      --implementation-swift-status 125 \
      --implementation-tee-status 125 \
      --report "$task9_report" \
      >/dev/null 2>&1 || true
  fi
  task9_write_failure_report "runner preflight failed: $task9_error"
  task9_report_finalized=1
}

task9_fail_preflight() {
  local task9_error="$1"
  task9_emit_preflight_report "$task9_error"
  echo "project-storage skip runner failed: $task9_error" >&2
  exit 2
}

if [[ -n "$task9_argument_error" ]]; then
  task9_fail_preflight "$task9_argument_error"
fi

case "$task9_suite" in
  ci-focused)
    task9_swift_test_argv=(
      swift test --no-parallel --filter
      'ProjectStorageScannerLargeTreeTests|ProjectStorageScannerTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests|ProjectStorageAutomaticCleanupServiceTests|ProjectStoragePerformanceTests|ProjectTempCleanupTests'
    )
    ;;
  focused)
    task9_swift_test_argv=(
      swift test --no-parallel --filter
      'ProjectStorageScannerLargeTreeTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageScannerTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests|ProjectStorageCleanupExecutorTests|ProjectStorageAutomaticCleanupServiceTests|ProjectTempCleanupTests|ProjectStoragePerformanceTests'
    )
    ;;
  scientific)
    task9_swift_test_argv=(
      swift test --no-parallel --filter
      'ProjectTempDirectoryTests|GenotypeWorkbookRevisionServiceTests|FullLengthONTMHCGenotypingPipelineTests|ONTBarcodeDemuxGenotypingPipelineTests|ProjectStorage'
    )
    ;;
  full)
    task9_swift_test_argv=(swift test --no-parallel)
    ;;
  *)
    task9_fail_preflight "Unsupported --suite: $task9_suite"
    ;;
esac

task9_validate_sha() {
  local task9_value="$1"
  [[ ${#task9_value} -eq 40 ]]
  [[ "$task9_value" != *[!0-9a-f]* ]]
  git -C "$task9_caller_root" cat-file -e "${task9_value}^{commit}"
}

if ! task9_validate_sha "$task9_base_sha" >/dev/null 2>&1; then
  task9_fail_preflight "invalid or unavailable base SHA"
fi
if ! task9_validate_sha "$task9_implementation_sha" >/dev/null 2>&1; then
  task9_fail_preflight "invalid or unavailable implementation SHA"
fi
if [[ "$(git -C "$task9_caller_root" rev-parse "${task9_implementation_sha}^")" != "$task9_base_sha" ]]; then
  task9_fail_preflight "implementation SHA is not a direct child of base SHA"
fi
if [[ -n "$(git -C "$task9_caller_root" status --porcelain)" ]]; then
  task9_fail_preflight "caller worktree is not clean"
fi
if ! task9_policy_base="$(
  python3 \
    "$task9_comparator" \
    --policy "$task9_policy" \
    --print-baseline-sha
)"; then
  task9_fail_preflight "policy validation failed"
fi
if [[ "$task9_policy_base" != "$task9_base_sha" ]]; then
  task9_fail_preflight "policy baselineSHA differs from base SHA"
fi

task9_temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/storage-task9-skip.XXXXXX")"
task9_worktree="$task9_temporary_root/worktree"

task9_cleanup() {
  if [[ -d "$task9_worktree" ]]; then
    git -C "$task9_caller_root" worktree remove --force "$task9_worktree" \
      >/dev/null 2>&1 || true
  fi
  git -C "$task9_caller_root" worktree prune >/dev/null 2>&1 || true
  rm -rf "$task9_temporary_root"
}

task9_run_one() {
  local task9_label="$1"
  local task9_sha="$2"
  local task9_local_log="$task9_temporary_root/$task9_label.log"
  local task9_local_status="$task9_temporary_root/$task9_label-status.json"
  local task9_run_status=125

  : >"$task9_local_log"
  printf \
    '{\n  "swiftStatus": 125,\n  "teeStatus": 125\n}\n' \
    >"$task9_local_status"

  if git -C "$task9_caller_root" worktree add --detach \
    "$task9_worktree" "$task9_sha"; then
    if (
      cd "$task9_worktree" || exit 125
      set -o pipefail
      set +e
      "${task9_swift_test_argv[@]}" 2>&1 | tee "$task9_local_log"
      task9_pipeline_status=("${PIPESTATUS[@]}")
      task9_swift_status="${task9_pipeline_status[0]}"
      task9_tee_status="${task9_pipeline_status[1]}"
      set -e
      printf \
        '{\n  "swiftStatus": %s,\n  "teeStatus": %s\n}\n' \
        "$task9_swift_status" \
        "$task9_tee_status" \
        >"$task9_local_status"
      [[ "$task9_swift_status" -eq 0 && "$task9_tee_status" -eq 0 ]]
    ); then
      task9_run_status=0
    else
      task9_run_status=$?
    fi
  else
    task9_run_status=125
  fi

  cp "$task9_local_log" \
    "$task9_output_directory/$task9_suite-$task9_label.log" \
    || task9_run_status=125
  cp "$task9_local_status" \
    "$task9_output_directory/$task9_suite-$task9_label-status.json" \
    || task9_run_status=125
  if [[ -d "$task9_worktree" ]]; then
    git -C "$task9_caller_root" worktree remove --force "$task9_worktree" \
      || task9_run_status=125
  fi
  git -C "$task9_caller_root" worktree prune \
    || task9_run_status=125
  return "$task9_run_status"
}

task9_status_value() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)[sys.argv[2]])
PY
}

if task9_run_one "base" "$task9_base_sha"; then
  task9_base_run_status=0
else
  task9_base_run_status=$?
fi

if [[ "$task9_base_run_status" -ne 0 ]]; then
  : >"$task9_implementation_log"
  printf \
    '{\n  "swiftStatus": 125,\n  "teeStatus": 125\n}\n' \
    >"$task9_implementation_status"
else
  if task9_run_one "implementation" "$task9_implementation_sha"; then
    task9_implementation_run_status=0
  else
    task9_implementation_run_status=$?
  fi
fi

task9_base_swift_status="$(
  task9_status_value "$task9_base_status" swiftStatus
)"
task9_base_tee_status="$(
  task9_status_value "$task9_base_status" teeStatus
)"
task9_implementation_swift_status="$(
  task9_status_value "$task9_implementation_status" swiftStatus
)"
task9_implementation_tee_status="$(
  task9_status_value "$task9_implementation_status" teeStatus
)"

set +e
python3 \
  "$task9_comparator" \
  --policy "$task9_policy" \
  --base-log "$task9_base_log" \
  --implementation-log "$task9_implementation_log" \
  --base-swift-status "$task9_base_swift_status" \
  --base-tee-status "$task9_base_tee_status" \
  --implementation-swift-status "$task9_implementation_swift_status" \
  --implementation-tee-status "$task9_implementation_tee_status" \
  --report "$task9_report"
task9_comparison_status=$?
set -e
if [[ -f "$task9_report" ]]; then
  if python3 - "$task9_report" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
if not isinstance(report.get("passed"), bool):
    raise SystemExit(1)
PY
  then
    task9_report_finalized=1
  fi
fi
exit "$task9_comparison_status"
