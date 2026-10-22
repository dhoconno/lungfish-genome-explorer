#!/usr/bin/env bash
# portable-tier.sh - the Linux tier for LungfishPortable and LungfishHTC (CHTC program, lane K0).
#
# What it does, in order:
#   1. Cross-builds lungfish-htc for aarch64-swift-linux-musl with the swift.org toolchain and its Static Linux SDK.
#   2. Runs the XCTest hello tests of LungfishPortableTests and LungfishHTCTests in an arm64 Swift container pinned by
#      digest. The Static Linux SDK ships neither XCTest nor Swift Testing, so no test target can be cross-built for
#      musl. The tests build and run on glibc inside the container instead.
#   3. Runs the static aarch64 binary in an arm64 Debian container pinned by digest, on a file whose SHA-256 it must
#      reproduce. Debian is glibc, so a binary that quietly needs the musl loader or the Swift runtime fails there.
#   4. Cross-builds the x86_64 release binary, prints its file type, size and SHA-256 and writes a tier record.
#
# Containers run under Apple `container` when it is installed and under `docker` otherwise. Every pin (toolchain, SDK,
# images) lives in scripts/linux/toolchain.json. Output goes to build/linux-tier/ (logs, artifacts, record.json).
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

if command -v container >/dev/null 2>&1; then
  runtime=container
else
  runtime=docker
  docker info >/dev/null 2>&1 || die "neither Apple container nor a running Docker was found"
fi

# run_arm64 <image reference> <host directory> <command...>: runs in an arm64 container with the directory at /work.
run_arm64() {
  local image="$1" host="$2"
  shift 2
  case "$runtime" in
    container) container run --rm --arch arm64 --volume "$host:/work" --workdir /work "$image" "$@" ;;
    docker) docker run --rm --platform linux/arm64 --volume "$host:/work" --workdir /work "$image" "$@" ;;
  esac
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
  "$swift_bin" build -c release --swift-sdk "$sdk_id" --triple "$1" --product lungfish-htc --scratch-path "$scratch"
}

bin_dir() {   # bin_dir <triple>
  "$swift_bin" build -c release --swift-sdk "$sdk_id" --triple "$1" --scratch-path "$scratch" --show-bin-path | tail -n 1
}

# The root package cannot build the two test targets alone, because a Linux test product holds every test target of
# its package. This view package declares only the Portable and HTC targets, cut from the root Package.swift so the
# two never drift, next to copies of their sources and tests.
prepare_view_package() {
  local dir
  for dir in Sources/LungfishPortable Sources/LungfishHTC Tests/LungfishPortableTests Tests/LungfishHTCTests; do
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
    products: [.executable(name: "lungfish-htc", targets: ["LungfishHTC"])],
    dependencies: [
        {crypto},
    ],
    targets: [
{root[start:end]}    ]
)''')
PY
}

smoke_static_binary() {   # smoke_static_binary <bin directory>
  local smoke="$work/smoke" output expected
  mkdir -p "$smoke"
  printf abc > "$smoke/abc.txt"
  cp "$1/lungfish-htc" "$smoke/lungfish-htc"
  output="$(run_arm64 "$(pin containers.smoke.image)@$(pin containers.smoke.digest)" "$smoke" ./lungfish-htc abc.txt)"
  echo "$output"
  expected="$(sha256_of "$smoke/abc.txt")"
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -d' ' -f1)" = "$expected" ] || die "the container's digest differs from shasum ($expected)"
}

mkdir -p "$logs" "$artifacts"

step cross-build-aarch64 cross_build aarch64-swift-linux-musl
aarch64_dir="$(bin_dir aarch64-swift-linux-musl)"
cp "$aarch64_dir/lungfish-htc" "$artifacts/lungfish-htc-aarch64-linux-musl"

prepare_view_package
step xctest-in-arm64-swift-container run_arm64 "$(pin containers.xctest.image)@$(pin containers.xctest.digest)" "$pkg" swift test
grep -E "^Test Case '.*' (passed|failed)" "$logs/xctest-in-arm64-swift-container.log"

step static-binary-in-arm64-debian-container smoke_static_binary "$aarch64_dir"
cat "$logs/static-binary-in-arm64-debian-container.log"

step cross-build-x86_64 cross_build x86_64-swift-linux-musl
x86_dir="$(bin_dir x86_64-swift-linux-musl)"
cp "$x86_dir/lungfish-htc" "$artifacts/lungfish-htc-x86_64-linux-musl"

for arch in x86_64 aarch64; do
  file_path="$artifacts/lungfish-htc-$arch-linux-musl"
  echo "$arch: $(file "$file_path" | sed 's/^[^:]*: //')"
  echo "$arch: $(size_of "$file_path") bytes, sha256 $(sha256_of "$file_path")"
done

python3 -I - "$work/record.json" "$repo" "$toolchain_name" "$sdk_id" "$runtime" "$artifacts" <<'PY'
import hashlib, json, os, subprocess, sys, time
record, repo, toolchain, sdk, runtime, artifacts = sys.argv[1:7]
def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
pins = json.load(open(os.path.join(repo, "scripts/linux/toolchain.json")))
out = {
    "tool": "scripts/linux/portable-tier.sh",
    "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "commit": subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip(),
    "toolchain": toolchain, "staticSDK": sdk, "containerRuntime": runtime,
    "containers": pins["containers"], "exitStatus": 0,
    "artifacts": {name: {"bytes": os.path.getsize(os.path.join(artifacts, name)), "sha256": digest(os.path.join(artifacts, name))}
                  for name in sorted(os.listdir(artifacts))},
}
json.dump(out, open(record, "w"), indent=2)
PY
echo "== tier passed, record at $work/record.json"
