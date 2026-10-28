#!/usr/bin/env bash
# portable-tier.sh - the Linux tier for LungfishPortable and LungfishExecutor (CHTC program, lane K0).
#
# What it does, in order:
#   1. Cross-builds lungfish-executor for aarch64-swift-linux-musl with the swift.org toolchain and its Static Linux SDK.
#   2. Resolves the packages of a generated test package in an arm64 Swift container pinned by digest (network on), then
#      runs the XCTest hello tests of LungfishPortableTests and LungfishExecutorTests in a second container with the network
#      closed. The Static Linux SDK ships neither XCTest nor Swift Testing, so no test target can be cross-built for
#      musl. The tests build and run on glibc inside the container instead. The launcher tests start the built
#      lungfish-executor as a child, so that first run names the glibc debug build. A second run of ExecutorSignalTests and
#      ExecutorLaunchTests (step xctest-static-binary-in-arm64-swift-container) names the static musl binary of step 1
#      instead, the bytes that ship, and record.json holds that binary's SHA-256 beside the XCTest files'. Both runs unpack
#      the pinned arm64 pigz package (readerTools in toolchain.json) for the decompression tests of ExecutorReaderTests.
#   3. Probes PID 1, the user and the kernel inside the arm64 Debian container (step container-probe) and stops when the
#      process under test would be PID 1.
#   4. Runs the static aarch64 binary in that Debian container, on a file whose SHA-256 it must reproduce. Debian is
#      glibc, so a binary that quietly needs the musl loader or the Swift runtime fails there.
#   5. Cross-builds the x86_64 release binary with scripts/release/linux_executor.py, the build `release.py package`
#      runs (path maps, pinned llvm-objcopy --strip-all), scans the stripped copy with
#      `scan-release-portability.py --binary <copy> --all-labels`, prints the file type, size and SHA-256 of the
#      unstripped and stripped files and writes a tier record.
#
# Containers run under Apple `container` when it is installed and its system answers (`container system status`), and
# under `docker` when that answers (`docker info`). With neither the tier stops with a message naming both. The Apple
# container branch is UNTESTED: it is not installed on the development Mac, and its flags come from the published
# `container run` reference (https://github.com/apple/container, docs/command-reference.md). Every pin (toolchain, SDK,
# images) lives in scripts/linux/toolchain.json. Output goes to build/linux-tier/ (logs, artifacts, record.json).
# The tier assumes no scheduler. It builds and checks a generic static Linux binary, and the HTCondor test job of a
# landing is submitted by hand.
#
# Hardening. Every container runs under one flag list: an init process (--init), so the process under test is never
# PID 1 and an orphan that a test leaves behind goes to the init and not to the test; a non-root user (--user 1000:1000);
# a tmpfs on /tmp with HOME there; and no home folder and no socket mounted. The Debian containers mount their folder
# read-only. Only the resolve container has a network, and only because it fetches the packages. The Apple container
# reference lists no flag that closes a container's network (--network takes a network name), so on that branch
# --offline prints a note and record.json says closedNetwork false.
#
# Evidence: record.json names the runtime and its version, the kernel seen inside each container, the probe of PID 1 and
# the user, the toolchain and SDK with their checksums, the SHA-256 of the XCTest runner and library files, the artifacts' SHA-256, the commit
# and whether the tree was clean. The tier builds the working tree, so a landing runs it on a clean checkout of the named
# commit. Landing evidence counts only when the last line of the output reads `commit <sha> clean`. A run that ends in
# `commit <sha> DIRTY` is a development run and proves nothing about that commit.
#
# Usage: bash scripts/linux/portable-tier.sh            run the tier
#        bash scripts/linux/portable-tier.sh --install  install the pinned toolchain and SDK at user level, no sudo

set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
pins="$repo/scripts/linux/toolchain.json"
work="$repo/build/linux-tier"
scratch="$work/scratch"
pkg="$work/pkg"
logs="$work/logs"
artifacts="$work/artifacts"
cd "$repo"

die() { echo "portable-tier: $*" >&2; exit 1; }

pin() {
  python3 -I - "$pins" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d ' '; }

tree_state() {   # prints "<commit> clean" or "<commit> DIRTY". Untracked files do not count.
  local sha changes
  sha="$(git rev-parse HEAD)" || return 1
  changes="$(git status --porcelain --untracked-files=no)" || return 1
  if [ -z "$changes" ]; then echo "$sha clean"; else echo "$sha DIRTY"; fi
}

toolchain_name="$(pin toolchain.name)"
swift_bin="$HOME/Library/Developer/Toolchains/$toolchain_name.xctoolchain/usr/bin/swift"
sdk_id="$(pin staticSDK.id)"

install_pins() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lge-toolchain.XXXXXX")"
  if [ ! -x "$swift_bin" ]; then
    curl -fL --retry 3 -o "$tmp/toolchain.pkg" "$(pin toolchain.url)"
    [ "$(sha256_of "$tmp/toolchain.pkg")" = "$(pin toolchain.sha256)" ] || die "the toolchain package differs from the pinned checksum"
    installer -pkg "$tmp/toolchain.pkg" -target CurrentUserHomeDirectory
  fi
  if ! "$swift_bin" sdk list | grep -qx "$sdk_id"; then
    "$swift_bin" sdk install "$(pin staticSDK.url)" --checksum "$(pin staticSDK.sha256)"
  fi
  rm -rf "$tmp"
}

if [ "${1:-}" = "--install" ]; then
  install_pins
  exit 0
fi
[ $# -eq 0 ] || die "usage: portable-tier.sh [--install]"

[ -x "$swift_bin" ] || die "toolchain $toolchain_name is not installed. Run: bash scripts/linux/portable-tier.sh --install"
"$swift_bin" sdk list | grep -qx "$sdk_id" || die "Static Linux SDK $sdk_id is not installed. Run: bash scripts/linux/portable-tier.sh --install"
case "$work" in
  *,*) die "the checkout path holds a comma, which the container --mount option cannot take: $work" ;;
esac

# Pick the container runtime once. Apple container counts only when its system answers, so an installed but stopped
# container system falls back to Docker. With neither answering the tier stops, so it never reports a pass with no run.
runtime=""
if command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1; then
  runtime=container
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  runtime=docker
else
  die "no container runtime answered. Tried Apple container ('container system status') and Docker ('docker info')"
fi

runtime_version() {
  case "$runtime" in
    container) container --version ;;
    docker) docker version --format '{{.Server.Version}}' ;;
  esac
}
runtime_version_text="$(runtime_version | sed -n 1p)" || die "could not read the version of $runtime"
[ -n "$runtime_version_text" ] || die "$runtime printed no version"
echo "runtime $runtime $runtime_version_text"

swift_version="$("$swift_bin" --version 2>&1 | sed -n 1p)" || die "could not read the Swift version of $swift_bin"

# The commit and the tree state at the start. The record counts as clean only when the end state is the same.
state_start="$(tree_state)" || die "cannot read the git state of $repo"

xctest_image="$(pin containers.xctest.image)@$(pin containers.xctest.digest)"
smoke_image="$(pin containers.smoke.image)@$(pin containers.smoke.digest)"

# run_arm64 [--ro] [--offline] <image reference> <host directory> <command...>: runs in an arm64 container with the
# directory at /work. One flag list serves both runtimes. Both CLIs take run, --rm, --init, --platform, --user, --tmpfs,
# --env, --mount and --workdir. --ro mounts the directory read-only. --offline closes the network, which only Docker can
# do (--network none).
run_arm64() {
  local mount_extra="" image host tmpfs
  local network=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ro) mount_extra=",readonly"; shift ;;
      --offline)
        if [ "$runtime" = docker ]; then
          network=(--network none)
        else
          echo "note: the Apple container reference lists no flag that closes the network, so this container keeps it" >&2
        fi
        shift ;;
      *) break ;;
    esac
  done
  image="$1"
  host="$2"
  shift 2
  # Docker mounts a tmpfs noexec, and SwiftPM runs the compiled manifest from the temporary directory, so Docker gets
  # the exec option. The Apple container reference takes a bare path for --tmpfs.
  tmpfs=/tmp
  [ "$runtime" != docker ] || tmpfs=/tmp:rw,exec,nosuid,nodev,size=2g
  "$runtime" run --rm --init --platform linux/arm64 --user 1000:1000 --tmpfs "$tmpfs" --env HOME=/tmp \
    ${network[@]+"${network[@]}"} \
    --mount "type=bind,source=$host,target=/work$mount_extra" --workdir /work "$image" "$@"
}

# step <name> <command...>: runs one command, keeps its output in logs/<name>.log and shows the tail if it fails.
step() {
  local name="$1"
  shift
  echo "== $name"
  if ! "$@" > "$logs/$name.log" 2>&1; then
    tail -n 40 "$logs/$name.log" >&2
    die "step $name failed, see $logs/$name.log"
  fi
}

cross_build() {   # cross_build <triple>
  "$swift_bin" build -c release --swift-sdk "$sdk_id" --triple "$1" --product lungfish-executor --scratch-path "$scratch"
}

bin_dir() {   # bin_dir <triple>
  "$swift_bin" build -c release --swift-sdk "$sdk_id" --triple "$1" --scratch-path "$scratch" --show-bin-path | tail -n 1
}

# The root package cannot build the two test targets alone, because a Linux test product holds every test target of
# its package. This view package declares only the Portable, Executor and CLungfishExecutor targets, cut from the root Package.swift so the
# two never drift, next to copies of their sources and tests.
prepare_view_package() {
  local dir
  for dir in Sources/LungfishPortable Sources/LungfishExecutor Sources/CLungfishExecutor Tests/LungfishPortableTests Tests/LungfishExecutorTests; do
    mkdir -p "$pkg/$dir"
    rsync -a --delete "$repo/$dir/" "$pkg/$dir/"
  done
  cp "$repo/Package.resolved" "$pkg/Package.resolved"
  python3 -I - "$repo/Package.swift" > "$pkg/Package.swift" <<'PY'
import re, sys
root = open(sys.argv[1]).read()
start = root.index("        // MARK: - LungfishPortable")
end = root.index("        // MARK: - LungfishCore")
crypto = re.search(r'\.package\(url: "https://github\.com/apple/swift-crypto\.git"[^\n]*\)', root).group(0)
print(f'''// swift-tools-version: 6.2
// Generated by scripts/linux/portable-tier.sh from the root Package.swift. Do not edit.
import PackageDescription

let package = Package(
    name: "LungfishPortableTier",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "lungfish-executor", targets: ["LungfishExecutor"])],
    dependencies: [
        {crypto},
    ],
    targets: [
{root[start:end]}    ]
)''')
PY
}

# The probe of PID 1. Under an init process /proc/1/comm names the init. When the container command itself is PID 1 the
# name is sh, swift, swift-test or lungfish-executor, and a test process in that place would inherit the orphaned descendant
# of a setsid child and have to reap it. K3 runs the same probe on a machine that has Apple container before it writes a
# signal test, and records what it printed.
container_probe() {   # container_probe <host directory>
  local probe pid1 uid
  probe="$(run_arm64 --ro --offline "$smoke_image" "$1" sh -c 'echo "pid1=$(cat /proc/1/comm)"; echo "uid=$(id -u)"; echo "kernel=$(uname -r)"')" || return 1
  echo "$probe"
  pid1="$(printf '%s\n' "$probe" | sed -n 's/^pid1=//p')"
  uid="$(printf '%s\n' "$probe" | sed -n 's/^uid=//p')"
  [ -n "$pid1" ] || { echo "the probe printed no PID 1 name" >&2; return 1; }
  [ "$uid" = 1000 ] || { echo "the probe ran as uid $uid and not 1000" >&2; return 1; }
  case "$pid1" in
    sh|swift|swift-test|lungfish-executor)
      echo "PID 1 is $pid1, so the container has no init process and the process under test would be PID 1" >&2
      return 1 ;;
  esac
}

smoke_static_binary() {   # runs the static binary on abc.txt in the read-only smoke folder and compares its digest
  local smoke="$work/smoke" output expected
  output="$(run_arm64 --ro --offline "$smoke_image" "$smoke" ./lungfish-executor abc.txt)"
  echo "$output"
  expected="$(sha256_of "$smoke/abc.txt")"
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -d' ' -f1)" = "$expected" ] || die "the container's digest differs from shasum ($expected)"
}

mkdir -p "$logs" "$artifacts" "$work/smoke"

step cross-build-aarch64 cross_build aarch64-swift-linux-musl
aarch64_dir="$(bin_dir aarch64-swift-linux-musl)"
cp "$aarch64_dir/lungfish-executor" "$artifacts/lungfish-executor-aarch64-linux-musl"

prepare_view_package

# The decompression tests of ExecutorReaderTests need a pigz, which the Swift container lacks (lane K3B). The tier fetches
# the pinned arm64 package once, checks its SHA-256 and puts it in the package folder. Each test container unpacks it under
# its /tmp and runs the tests with LUNGFISH_PIGZ and LUNGFISH_REQUIRE_TOOLS=1, so a missing pigz fails and never skips.
pigz_deb="$(pin readerTools.pigz.package)"
pigz_sha="$(pin readerTools.pigz.sha256)"
mkdir -p "$work/downloads" "$pkg/tools"
if [ ! -f "$work/downloads/$pigz_deb" ] || [ "$(sha256_of "$work/downloads/$pigz_deb")" != "$pigz_sha" ]; then
  curl -fL --retry 3 -o "$work/downloads/$pigz_deb" "$(pin readerTools.pigz.url)"
fi
[ "$(sha256_of "$work/downloads/$pigz_deb")" = "$pigz_sha" ] || die "the pigz package differs from the pinned checksum"
cp "$work/downloads/$pigz_deb" "$pkg/tools/$pigz_deb"
with_pigz="dpkg-deb -x /work/tools/$pigz_deb /tmp/pigz-root && export LUNGFISH_PIGZ=$(pin readerTools.pigz.unpackedPath) LUNGFISH_REQUIRE_TOOLS=1 && \$LUNGFISH_PIGZ --version"

step resolve-in-arm64-swift-container run_arm64 "$xctest_image" "$pkg" swift package resolve
# The launcher's tests start the built lungfish-executor as a child (tally-r2 K3-1), so the container builds the product
# first and names it to the tests.
step xctest-in-arm64-swift-container run_arm64 --offline "$xctest_image" "$pkg" sh -c \
  "$with_pigz && "'swift build --disable-automatic-resolution --product lungfish-executor && LUNGFISH_EXECUTOR_BINARY="$(swift build --disable-automatic-resolution --show-bin-path)/lungfish-executor" swift test --disable-automatic-resolution'
grep -E "^Test Case '.*' (passed|failed)" "$logs/xctest-in-arm64-swift-container.log"
# SwiftPM 6.4 builds a Linux test target as a test runner plus a shared library (<Target>-test-runner and <Target>.so
# under .build/out/Products). Older layouts build one .xctest file. Every one of these files goes into the record.
test_binary_args=()
# find -H searches a .build that is a link, as on the scratch disk. Plain find stops at a link given as the start.
while IFS= read -r test_file; do
  test_binary_args+=("testBinary.file=${test_file#"$repo"/}|$(size_of "$test_file")|$(sha256_of "$test_file")")
done < <(find -H "$pkg/.build" -type f \( -name '*-test-runner' -o -name '*Tests.so' -o -name '*.xctest' \) | sort)
[ "${#test_binary_args[@]}" -gt 0 ] || die "swift test left no test runner, test library or .xctest file under $pkg/.build"

# The same launcher tests again, against the static musl binary that ships and not the glibc debug build above, so descriptor
# hygiene through static Foundation, stdin, the environment, exit codes, the ru_maxrss unit, the deadline and the step record
# are exercised on musl (lane K3, fix 5). The test process is still the glibc build and the binary under test is the shipped
# one. The copy sits in the mounted package folder, which the container sees at /work.
static_name=lungfish-executor-static-musl
cp "$aarch64_dir/lungfish-executor" "$pkg/$static_name"
step xctest-static-binary-in-arm64-swift-container run_arm64 --offline "$xctest_image" "$pkg" sh -c \
  "$with_pigz && LUNGFISH_EXECUTOR_BINARY=/work/$static_name swift test --disable-automatic-resolution --filter ExecutorSignalTests --filter ExecutorLaunchTests --filter ExecutorReaderTests --filter RunPlanTests --filter ImageManifestCommandTests"
grep -E "^Test Case '.*' (passed|failed)" "$logs/xctest-static-binary-in-arm64-swift-container.log"
test_binary_args+=("testBinary.staticExecutor=$static_name|$(size_of "$pkg/$static_name")|$(sha256_of "$pkg/$static_name")")

printf abc > "$work/smoke/abc.txt"
cp "$aarch64_dir/lungfish-executor" "$work/smoke/lungfish-executor"
step container-probe container_probe "$work/smoke"
cat "$logs/container-probe.log"
step static-binary-in-arm64-debian-container smoke_static_binary
cat "$logs/static-binary-in-arm64-debian-container.log"

# The kernel each image ran on. Docker Desktop and Apple container both run containers in a Linux VM, so this is the
# VM's kernel and not the Mac's.
step kernel-in-arm64-swift-container run_arm64 --ro --offline "$xctest_image" "$pkg" uname -r
step kernel-in-arm64-debian-container run_arm64 --ro --offline "$smoke_image" "$work/smoke" uname -r
kernel_xctest="$(tail -n 1 "$logs/kernel-in-arm64-swift-container.log")"
kernel_smoke="$(tail -n 1 "$logs/kernel-in-arm64-debian-container.log")"
echo "kernel xctest $kernel_xctest, smoke $kernel_smoke"
probe_pid1="$(sed -n 's/^pid1=//p' "$logs/container-probe.log")"
probe_uid="$(sed -n 's/^uid=//p' "$logs/container-probe.log")"
probe_kernel="$(sed -n 's/^kernel=//p' "$logs/container-probe.log")"

# The x86-64 executor is built by the release's own build script, the one `release.py package` calls, so the tier
# builds the way a package builds: the pins above, the scratch and checkout path maps, and the pinned llvm-objcopy
# --strip-all. The stripped copy then passes the one-file scan with --all-labels, under which user-home and
# repository-root fail too, so a new build-machine path fails here at landing and not in the middle of a package
# (QA's FC-Q2 ruling). A plain --binary pass is never evidence for this file.
# Its stripped file is not a package's: the module hashes and build ID follow the scratch folder's path
# (build/linux-tier/scratch here, build/linux-executor/scratch in a package). The tier checks the same code and
# strings. The gate for the shipped bytes is QC18 item 4's /proc/self/exe equality.
lge_version="$(python3 scripts/release/release_version.py --root "$repo")" || die "could not read the LGE version"
x86_stage="$work/executor-x86_64"
rm -rf "$x86_stage"
step cross-build-x86_64 python3 scripts/release/linux_executor.py build --triple x86_64-swift-linux-musl \
  --scratch-path "$scratch" --output "$x86_stage" --lge-version "$lge_version" --lge-commit "${state_start%% *}"
tail -n 1 "$logs/cross-build-x86_64.log"
cp "$x86_stage/unstripped/lungfish-executor-x86_64-swift-linux-musl" "$artifacts/lungfish-executor-x86_64-linux-musl"
cp "$x86_stage/LinuxExecutor/x86_64/lungfish-executor" "$artifacts/lungfish-executor-x86_64-linux-musl-stripped"
step scan-x86_64-stripped-all-labels python3 scripts/release/scan-release-portability.py \
  --binary "$artifacts/lungfish-executor-x86_64-linux-musl-stripped" --all-labels
tail -n 1 "$logs/scan-x86_64-stripped-all-labels.log"

for name in x86_64-linux-musl x86_64-linux-musl-stripped aarch64-linux-musl; do
  file_path="$artifacts/lungfish-executor-$name"
  echo "$name: $(file "$file_path" | sed 's/^[^:]*: //')"
  echo "$name: $(size_of "$file_path") bytes, sha256 $(sha256_of "$file_path")"
done

state_end="$(tree_state)" || die "cannot read the git state of $repo"
commit="${state_start%% *}"
if [ "$state_start" = "$state_end" ] && [ "${state_end##* }" = "clean" ]; then
  tree_clean=true
  verdict=clean
else
  tree_clean=false
  verdict=DIRTY
fi
closed_network=false
[ "$runtime" != docker ] || closed_network=true

python3 -I - "$work/record.json" "$repo" "$artifacts" \
  "commit=$commit" "treeClean=$tree_clean" "wallSeconds=$SECONDS" \
  "runtime.name=$runtime" "runtime.version=$runtime_version_text" "closedNetwork=$closed_network" \
  "kernel.xctest=$kernel_xctest" "kernel.smoke=$kernel_smoke" \
  "containerProbe.pid1=$probe_pid1" "containerProbe.uid=$probe_uid" "containerProbe.kernel=$probe_kernel" \
  "toolchain.name=$toolchain_name" "toolchain.identifier=$(pin toolchain.identifier)" \
  "toolchain.sha256=$(pin toolchain.sha256)" "toolchain.swiftVersion=$swift_version" \
  "staticSDK.id=$sdk_id" "staticSDK.sha256=$(pin staticSDK.sha256)" \
  "${test_binary_args[@]}" \
  :: "$0" "$@" <<'PY'
import hashlib, json, os, sys, time

args = sys.argv[1:]
mark = args.index("::")
record, repo, artifacts = args[:3]
pairs, script_argv = args[3:mark], args[mark + 1:]

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def put(tree, dotted, value):
    keys = dotted.split(".")
    for key in keys[:-1]:
        tree = tree.setdefault(key, {})
    tree[keys[-1]] = value

numbers, flags = {"wallSeconds", "containerProbe.uid"}, {"treeClean", "closedNetwork"}
pins = json.load(open(os.path.join(repo, "scripts/linux/toolchain.json")))
out = {"tool": "scripts/linux/portable-tier.sh", "argv": script_argv, "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
for pair in pairs:
    key, _, value = pair.partition("=")
    if key == "testBinary.file":
        path, size, sha = value.split("|")
        out.setdefault("testBinary", {}).setdefault("files", []).append({"path": path, "bytes": int(size), "sha256": sha})
        continue
    if key == "testBinary.staticExecutor":
        path, size, sha = value.split("|")
        out.setdefault("testBinary", {})["staticExecutor"] = {
            "path": path, "bytes": int(size), "sha256": sha, "step": "xctest-static-binary-in-arm64-swift-container"}
        continue
    put(out, key, int(value) if key in numbers else (value == "true") if key in flags else value)
out["containers"] = pins["containers"]
out["readerTools"] = pins["readerTools"]
out["artifacts"] = {name: {"bytes": os.path.getsize(os.path.join(artifacts, name)),
                           "sha256": digest(os.path.join(artifacts, name))}
                    for name in sorted(os.listdir(artifacts))}
out["exitStatus"] = 0
with open(record, "w") as handle:
    json.dump(out, handle, indent=2)
    handle.write("\n")
PY
echo "== tier passed, record at $work/record.json"
echo "commit $commit $verdict"
