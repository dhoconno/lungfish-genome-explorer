#!/usr/bin/env bash
# launcher-tier.sh - the plain launcher's Docker tier (C5 lane LAUNCH M3, ruling BIOQA-c5 point 5, decision D6).
#
# A machine with Docker and no Apptainer runs a batch's run-local.sh with --runtime docker. That needs the batch's
# Apptainer image as a Docker image for linux/amd64, and on an arm64 Mac the x86_64 executor then runs under Docker's
# emulator. This script makes that image and runs the launcher, and writes each fact into the tier's record.json.
#
#   image      Checks the SIF against the size and SHA-256 that Sources/LungfishWorkflow/Resources/CHTCImage/image.json
#              pins, finds the SIF's one squashfs system partition in its descriptors, and mounts that partition
#              read-only in a helper container pinned by digest. The loop mount needs --privileged; the helper has no
#              network and only the SIF's folder, read-only. The helper checks that /.singularity.d/env/90-environment.sh
#              is the file scripts/chtc/image/build-image.sh writes, lists the binfmt_misc entries of Docker's Linux
#              machine (the emulator that runs x86_64 binaries), and streams the tree into
#              `docker import --platform linux/amd64` as lge-tools:<first 12 of the SHA-256>, with PATH, LC_ALL and LANG
#              set as that environment file sets them under Apptainer. The record gets the SIF's name, size and SHA-256,
#              the Docker image ID, Docker's version, what `docker info` says about emulation and the binfmt_misc entries.
#   run        Runs `sh <batch>/run-local.sh --runtime docker --image <image> --data <data> --jobs 1`, times it, and
#              records under runs.<label> the launcher's exit, the wall seconds and, for each sample of jobs.tsv, the run
#              record's outcome and exit code, its self-check (the executor SHA-256 and size the record holds against the
#              plan's executor entry), the steps that did not succeed and the executor's refusal sentence from
#              logs/<sample>.err. The run passes only when the launcher exits 0, each record exits 0 and each self-check
#              equals the plan's pin (BIOQA-c5 point 5). A run past 60 minutes is a stop (D6). Emulated wall time never
#              sizes a request on any pool. A sample of jobs.tsv that already holds result/ is refused, since
#              run-local.sh skips it and exits 0 and the record would describe an earlier run. The record's folder
#              is made before the launcher starts.
#   partition  Prints the byte offset and length of the SIF's squashfs system partition.
#
# Exit codes: 0 done (run: passed), 1 run ended and did not pass, 2 refused before any container ran, 64 usage.
#
# Usage: bash scripts/linux/launcher-tier.sh image --sif <file> --record <file>
#        bash scripts/linux/launcher-tier.sh run --batch <folder> --data <folder> --image <name> --record <file> --label <name>
#        bash scripts/linux/launcher-tier.sh partition --sif <file>
# Every path is absolute.

set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
pins="$repo/Sources/LungfishWorkflow/Resources/CHTCImage/image.json"
helper="quay.io/nf-core/ubuntu@sha256:19bc204df71f4086020b609089ebf49b332c2e373ec31e3512644b8ad9615001"
tools_path="/opt/lge/env/bin:/opt/lge/trim_galore/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
stop_seconds=3600

usage() {
  [ $# -eq 0 ] || echo "launcher-tier: $*" >&2
  sed -n '/^# Usage:/,/^# Every path/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}
refuse() { echo "launcher-tier: $*" >&2; exit 2; }
sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }
pin() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["sif"][sys.argv[2]])' "$pins" "$1"; }

partition_of() {   # partition_of <sif>: prints "<offset> <length>" or exits 3
  python3 -I - "$1" <<'PY'
import os, struct, sys
path = sys.argv[1]
# SIF layout (apptainer sif v2, format "01"): a 128-byte global header, then fixed 585-byte descriptors.
with open(path, "rb") as f:
    head = f.read(128)
    if len(head) < 128 or head[32:42] != b"SIF_MAGIC\0":
        sys.exit("launcher-tier: %s is not a SIF file." % os.path.basename(path))
    _free, total, desc_offset, _desc_size, _data_offset, _data_size = struct.unpack_from("<6q", head, 80)
    file_size = os.fstat(f.fileno()).st_size
    found = []
    f.seek(desc_offset)
    for _ in range(total):
        raw = f.read(585)
        if len(raw) < 585:
            break
        kind, used, _id, _group, _link, offset, length, _padded = struct.unpack_from("<i?IIIqqq", raw, 0)
        fs_type, part_type = struct.unpack_from("<ii", raw, 201)
        # 0x4004 is a data partition, file system 1 squashfs, partition type 2 the primary system partition.
        if used and kind == 0x4004 and fs_type == 1 and part_type == 2:
            found.append((offset, length))
if len(found) != 1:
    sys.exit("launcher-tier: %s holds %d squashfs system partitions, not one." % (os.path.basename(path), len(found)))
offset, length = found[0]
if offset < 128 or length <= 0 or offset + length > file_size:
    sys.exit("launcher-tier: the squashfs partition of %s lies outside the file." % os.path.basename(path))
print(offset, length)
PY
}

sub=${1:-}
[ $# -gt 0 ] && shift
sif="" record="" batch="" data="" image="" label=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sif | --record | --batch | --data | --image | --label)
      [ $# -ge 2 ] || usage "$1 needs a value."
      case "$1" in
        --sif) sif=$2 ;; --record) record=$2 ;; --batch) batch=$2 ;;
        --data) data=$2 ;; --image) image=$2 ;; --label) label=$2 ;;
      esac
      shift 2 ;;
    *) usage "unknown argument $1." ;;
  esac
done
absolute() { case "$2" in /*) ;; *) usage "$1 must be an absolute path, not $2." ;; esac; }
need() { [ -n "$2" ] || usage "$sub needs $1."; }

case "$sub" in
  partition)
    need --sif "$sif"; absolute --sif "$sif"
    [ -f "$sif" ] || refuse "There is no file $sif."
    partition_of "$sif" || exit 2
    exit 0 ;;
  image)
    need --sif "$sif"; need --record "$record"; absolute --sif "$sif"; absolute --record "$record" ;;
  run)
    need --batch "$batch"; need --data "$data"; need --image "$image"; need --record "$record"; need --label "$label"
    absolute --batch "$batch"; absolute --data "$data"; absolute --record "$record"
    case "$label" in *[!a-z0-9-]* | "") usage "--label takes lower-case letters, digits and hyphens, not $label." ;; esac ;;
  "") usage ;;
  *) usage "unknown step $sub." ;;
esac

helper_run() {   # helper_run <command>: runs one sh command in the helper with the SIF's partition args $1 $2 $3
  docker run --rm --privileged --network none --platform linux/amd64 --volume "$folder:/in:ro" "$helper" \
    sh -c "$1" sh "$offset" "$length" "$file"
}

image_step() {
  [ -f "$sif" ] || refuse "There is no file $sif."
  local name want_sha want_size size sha parts work tag started image_id arch version
  name=$(pin fileName); want_sha=$(pin sha256); want_size=$(pin size)
  size=$(size_of "$sif")
  [ "$size" = "$want_size" ] || refuse "The image $sif has $size bytes, not the $want_size that image.json pins for $name."
  sha=$(sha256_of "$sif")
  [ "$sha" = "$want_sha" ] || refuse "The image $sif has the SHA-256 $sha, not the $want_sha that image.json pins for $name."
  parts=$(partition_of "$sif") || exit 2
  offset=${parts% *}; length=${parts#* }
  folder=$(cd "$(dirname "$sif")" && pwd); file=$(basename "$sif")
  docker info >/dev/null 2>&1 || refuse "Docker does not answer (docker info)."
  work=$(dirname "$record"); mkdir -p "$work"
  tag="lge-tools:${sha:0:12}"
  docker info --format '{{json .}}' > "$work/docker-info.json"
  mount_line='mkdir -p /rootfs && mount -t squashfs -o "ro,loop,offset=$1,sizelimit=$2" "/in/$3" /rootfs'

  echo "== the image's environment file"
  helper_run "$mount_line && cat /rootfs/.singularity.d/env/90-environment.sh" > "$work/90-environment.sh"
  printf '#!/bin/sh\nexport PATH=/opt/lge/env/bin:/opt/lge/trim_galore/bin:$PATH\nexport LC_ALL=C.UTF-8\nexport LANG=C.UTF-8\n' \
    > "$work/90-environment.expected"
  cmp -s "$work/90-environment.sh" "$work/90-environment.expected" ||
    refuse "The image's /.singularity.d/env/90-environment.sh is not the one build-image.sh writes, so the Docker image's PATH would differ from Apptainer's (see $work/90-environment.sh)."

  echo "== binfmt_misc entries of Docker's Linux machine"
  helper_run '[ -e /proc/sys/fs/binfmt_misc/status ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    for entry in /proc/sys/fs/binfmt_misc/*; do echo "== ${entry##*/}"; cat "$entry"; done' > "$work/binfmt.txt"

  echo "== import as $tag"
  started=$(date +%s)
  helper_run "$mount_line && tar -C /rootfs --numeric-owner -cf - ." 2>"$work/helper-tar.err" |
    docker import --platform linux/amd64 --change "ENV PATH=$tools_path" --change "ENV LC_ALL=C.UTF-8" \
      --change "ENV LANG=C.UTF-8" - "$tag" > "$work/import.out"
  image_id=$(docker image inspect --format '{{.Id}}' "$tag")
  arch=$(docker image inspect --format '{{.Architecture}}' "$tag")
  version=$(docker version --format '{{.Server.Version}}')

  python3 -I - "$record" "$name" "$size" "$sha" "$tag" "$image_id" "$arch" "$version" "$helper" "$offset" "$length" \
    "$work/docker-info.json" "$work/binfmt.txt" "$(( $(date +%s) - started ))" <<'PY'
import json, os, sys
(record, name, size, sha, tag, image_id, arch, version, helper, offset, length, info_path, binfmt_path,
 seconds) = sys.argv[1:]
data = json.load(open(record)) if os.path.exists(record) else {}
info = json.load(open(info_path))
text = json.dumps(info).lower()
entries, current = {}, None
for line in open(binfmt_path, errors="replace"):
    line = line.rstrip("\n")
    if line.startswith("== "):
        current = line[3:]
        entries[current] = []
    elif current is not None and line:
        entries[current].append(line)
emulators = {}
for entry, lines in entries.items():
    if entry in ("register", "status"):
        continue
    facts = {"enabled": bool(lines) and lines[0] == "enabled"}
    for line in lines[1:]:
        key, _, value = line.partition(" ")
        facts[key.rstrip(":")] = value
    magic = facts.get("magic", "")
    # An x86_64 ELF: class 64-bit, little-endian, e_machine 0x3e at byte 18.
    facts["runsX86_64"] = magic.startswith("7f454c4602010100") and magic[36:40] == "3e00"
    emulators[entry] = facts
data.update({
    "schemaVersion": 1,
    "tier": "launcher-docker",
    "sif": {"fileName": name, "size": int(size), "sha256": sha, "squashfsOffset": int(offset),
            "squashfsLength": int(length)},
    "dockerImage": {"tag": tag, "id": image_id, "architecture": arch, "helper": helper, "importSeconds": int(seconds)},
    "docker": {"serverVersion": version, "operatingSystem": info.get("OperatingSystem"),
               "architecture": info.get("Architecture"), "kernelVersion": info.get("KernelVersion"),
               "emulatorNamedByDockerInfo": [w for w in ("rosetta", "qemu") if w in text]},
    "binfmtMisc": emulators,
})
with open(record + ".tmp", "w") as out:
    json.dump(data, out, indent=2, sort_keys=True)
    out.write("\n")
os.replace(record + ".tmp", record)
print("image %s %s, emulators %s" % (tag, image_id, ", ".join(sorted(k for k, v in emulators.items() if v["runsX86_64"])) or "none"))
PY
}

run_step() {
  [ -f "$batch/run-local.sh" ] || refuse "The batch folder $batch holds no run-local.sh."
  [ -f "$batch/jobs.tsv" ] || refuse "The batch folder $batch holds no jobs.tsv."
  [ -d "$data" ] || refuse "There is no data folder $data."
  # run-local.sh skips a sample whose result/ exists and still exits 0, so a pass would describe an earlier run.
  local first rest tab
  tab=$(printf '\t')
  while IFS=$tab read -r first rest; do
    case $first in "" | "#"*) continue ;; esac
    [ ! -e "$batch/$first/result" ] ||
      refuse "The sample $first already holds $batch/$first/result/, which run-local.sh skips, so this record would describe an earlier run. Delete that folder or run a fresh copy of the batch."
  done < "$batch/jobs.tsv"
  # The run can take an hour, so make the record's folder before it and not after it.
  mkdir -p "$(dirname "$record")"
  docker image inspect "$image" >/dev/null 2>&1 || refuse "Docker has no image $image."
  local started status=0
  started=$(date +%s)
  echo "== sh run-local.sh --runtime docker --image $image --data $data --jobs 1"
  # From inside the batch folder, as its README.txt says.
  (cd "$batch" && sh ./run-local.sh --runtime docker --image "$image" --data "$data" --jobs 1) || status=$?
  python3 -I - "$record" "$label" "$batch" "$status" "$(( $(date +%s) - started ))" "$image" "$stop_seconds" <<'PY'
import json, os, sys
record, label, batch, status, seconds, image, stop = sys.argv[1:]
data = json.load(open(record)) if os.path.exists(record) else {}
samples = [line.split("\t")[0] for line in open(os.path.join(batch, "jobs.tsv"))
           if line.strip() and not line.startswith("#")]
passed = int(status) == 0 and bool(samples)
rows = []
for sample in samples:
    row = {"sample": sample}
    plan = json.load(open(os.path.join(batch, sample, "plan.json")))
    pin = next((e for e in plan.get("entries", []) if e.get("role") == "executor"), None)
    row["planExecutor"] = {"sha256": pin.get("sha256"), "size": pin.get("size")} if pin else None
    path = os.path.join(batch, sample, "result", "run-record.json")
    if os.path.exists(path):
        run = json.load(open(path))
        executor = run.get("executor") or {}
        row["outcome"], row["exitCode"] = run.get("outcome"), run.get("exitCode")
        row["selfCheck"] = {"sha256": executor.get("sha256"), "size": executor.get("size")}
        row["selfCheckEqualsPlan"] = bool(pin) and (executor.get("sha256"), executor.get("size")) == (
            pin.get("sha256"), pin.get("size"))
        row["siteFacts"] = run.get("siteFacts")
        row["stepsNotSucceeded"] = [{k: s[k] for k in ("id", "kind", "outcome", "exitCode") if k in s}
                                    for s in run.get("steps", []) if s.get("outcome") != "succeeded"]
    else:
        row["runRecord"] = "absent"
    err = os.path.join(batch, "logs", sample + ".err")
    lines = open(err, errors="replace").read().splitlines() if os.path.exists(err) else []
    refusals = [line.strip() for line in lines if "The running executor has SHA-256" in line]
    row["refusal"] = refusals[0] if refusals else None
    passed = passed and row.get("exitCode") == 0 and row.get("selfCheckEqualsPlan") is True
    rows.append(row)
over = int(seconds) > int(stop)
data.setdefault("runs", {})[label] = {
    "image": image, "launcherExit": int(status), "wallSeconds": int(seconds), "overSixtyMinutes": over,
    "passed": bool(passed and not over), "samples": rows,
    "note": "Emulated Docker wall time. It never sizes a request on any pool (BIOQA-c5 point 5).",
}
with open(record + ".tmp", "w") as out:
    json.dump(data, out, indent=2, sort_keys=True)
    out.write("\n")
os.replace(record + ".tmp", record)
print("run %s: launcher exit %s, %s s, %s" % (label, status, seconds, "passed" if passed and not over else "did not pass"))
sys.exit(0 if passed and not over else 1)
PY
}

case "$sub" in
  image) image_step ;;
  run) run_step ;;
esac
