import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from scripts.tests.gate_fixtures import make_gate_fixture


ROOT = Path(__file__).resolve().parents[2]
PYTHON = Path(sys.executable)


class ReleaseBuilderFixture:
    def __init__(self, case: unittest.TestCase):
        self.case = case
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        self.events = self.root / "events.log"
        self.gh_state = self.root / "gh-state.json"
        self.scratch_root = self.root / "scratch-root"
        self.release = self.root / "release"
        self.archive = self.root / "archive" / "Lungfish.xcarchive"
        self.derived = self.root / "derived"
        self.repo.mkdir()
        self.bin.mkdir()
        self._copy_repository_inputs()
        self._install_internal_phase_wrappers()
        self._install_external_tools()
        self._adapt_canonical_tools_for_fixture()
        self._git("init", "-q")
        self._git("config", "user.email", "builder@example.test")
        self._git("config", "user.name", "Builder Test")
        self._git("add", ".")
        self._git("commit", "-q", "-m", "fixture")
        self._git("remote", "add", "origin", "https://github.com/example/lungfish.git")

    def cleanup(self):
        self.temporary.cleanup()

    @property
    def builder(self):
        return self.repo / "scripts" / "release" / "build-notarized-dmg.sh"

    def _copy_repository_inputs(self):
        paths = (
            ".gitignore",
            "scripts/release/build-notarized-dmg.sh",
            "scripts/release/release_contract.py",
            "scripts/release/release_cache_security.py",
            "scripts/release/release_cache_fingerprint.py",
            "scripts/release/release_target_security.py",
            "scripts/release/release_repository.py",
            "scripts/release/release_xcode.py",
            "scripts/release/check-sparkle-build-number.py",
            "scripts/release/release-candidate-receipt.py",
            "scripts/release/gate_evidence.py",
            "scripts/release/app_smoke_gate.py",
            "scripts/full-suite-gate.sh",
            "scripts/check-package-resolved-consistency.sh",
            "config/release-contract.json",
            "Package.swift",
            "Lungfish-Info.plist",
            "lungfish-cli.entitlements",
            "scripts/bundle-native-tools.sh",
            "scripts/sanitize-bundled-tools.sh",
            "scripts/setup-worktree.sh",
            "scripts/smoke-test-release-tools.sh",
            "scripts/release/scan-release-portability.py",
        )
        for relative in paths:
            destination = self.repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)

        self._write(
            self.repo / "Sources/LungfishCore/AppVersion.swift",
            'public enum LungfishAppVersion { public static let short = "2026.8.1" }\n',
        )
        shutil.copy2(
            ROOT / "Sources/Lungfish/AppIcon.icns",
            self._parent(self.repo / "Sources/Lungfish/AppIcon.icns"),
        )
        self._write(
            self.repo
            / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json",
            json.dumps(
                {
                    "dependencySet": "test",
                    "bootstrap": {
                        "micromamba": {
                            "version": "2.9.0-0",
                            "sha256": {"osx-arm64": "a" * 64},
                        }
                    },
                },
                sort_keys=True,
            )
            + "\n",
        )
        fixture_package_resolved = '{"pins":[],"version":2}\n'
        self._write(self.repo / "Package.resolved", fixture_package_resolved)
        self._write(
            self.repo
            / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            fixture_package_resolved,
        )
        self._write(self.repo / "Lungfish.xcodeproj/project.pbxproj", "// fixture\n")
        self._write(self.repo / "lungfish-cli.entitlements", "<plist/>\n")
        self._write(self.repo / ".gitignore", "build/\n")
        self._write(
            self.repo / "docs/release-notes/2026.8.1.md",
            """
            # Lungfish 2026.8.1
            Channel: Stable
            Previous versioned release: v2026.7.1
            Stable baseline: v2026.7.1
            Dependency set: test
            ## Dependency versions
            ## Included preview releases
            """,
        )

    def _install_internal_phase_wrappers(self):
        release_dir = self.repo / "scripts" / "release"
        self._write_executable(
            release_dir / "check-sparkle-build-number.py",
            r"""
            #!/usr/bin/python3
            import os
            from pathlib import Path
            import sys

            events = Path(os.environ["BUILDER_EVENTS"])
            count = sum(
                line.startswith("sparkle-gate:")
                for line in events.read_text(encoding="utf-8").splitlines()
            ) + 1
            with events.open("a", encoding="utf-8") as handle:
                handle.write(f"sparkle-gate:{' '.join(sys.argv[1:])}\n")
            if os.environ.get("BUILDER_SPARKLE_GATE_FAIL_ON_CALL") == str(count):
                raise SystemExit(64)
            """,
        )
        real_receipt = release_dir / "release-candidate-receipt-real.py"
        (release_dir / "release-candidate-receipt.py").replace(real_receipt)
        self._write_executable(
            release_dir / "release-candidate-receipt.py",
            r"""
            #!/bin/bash
            set -eu
            if [ -n "${BUILDER_EVENTS:-}" ]; then
                printf 'receipt:%s:%s\n' "$1" "$*" >>"$BUILDER_EVENTS"
            fi
            "${BUILDER_PYTHON:-python3}" "$(dirname "$0")/release-candidate-receipt-real.py" "$@"
            if [ -n "${BUILDER_EVENTS:-}" ]; then
                printf 'receipt:%s:ok\n' "$1" >>"$BUILDER_EVENTS"
            fi
            """,
        )
        self._write_executable(
            release_dir / "release-doctor.py",
            r"""
            #!/bin/bash
            set -eu
            printf 'doctor:%s\n' "$*" >>"$BUILDER_EVENTS"
            if [ "${BUILDER_DOCTOR_FAIL:-0}" = 1 ]; then
                echo 'FAIL fixture doctor' >&2
                exit 1
            fi
            scratch=
            release=
            archive=
            derived=
            remote=origin
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --scratch-path) scratch="$2"; shift 2 ;;
                    --release-dir) release="$2"; shift 2 ;;
                    --archive-path) archive="$2"; shift 2 ;;
                    --derived-data-path) derived="$2"; shift 2 ;;
                    --remote) remote="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            if [ -n "$scratch" ]; then
                repo=$(cd "$(dirname "$0")/../.." && pwd)
                "$BUILDER_PYTHON" "$(dirname "$0")/release_target_security.py" \
                    --project-root "$repo" \
                    --home "$HOME" \
                    --scratch-root "$LUNGFISH_RELEASE_SCRATCH_ROOT" \
                    --scratch-path "$scratch" \
                    --release-dir "$release" \
                    --archive-path "$archive" \
                    --derived-data-path "$derived" \
                    --remote "$remote"
            fi
            echo 'PASS fixture doctor'
            """,
        )
        self._write_executable(
            self.repo / "scripts/sanitize-bundled-tools.sh",
            r"""
            #!/bin/bash
            set -eu
            [ "$1" = --adhoc-seal ]
            shift
            macos="$1"
            tools="$2"
            mkdir -p "$tools" "$(dirname "$tools")/ManagedTools"
            cat >"$tools/micromamba" <<'EOF'
            #!/bin/sh
            echo 'micromamba 2.9.0-0'
            EOF
            chmod 755 "$tools/micromamba"
            printf '{"tools":[{"name":"micromamba","version":"2.9.0-0"}]}\n' >"$tools/tool-versions.json"
            printf '%s\n' '- micromamba: 2.9.0-0' >"$tools/VERSIONS.txt"
            cp "$BUILDER_MANAGED_MANIFEST" "$(dirname "$tools")/ManagedTools/third-party-tools-lock.json"
            printf 'sanitize\n' >>"$BUILDER_EVENTS"
            codesign --force --sign - --timestamp=none "$macos/Lungfish"
            codesign --force --sign - --timestamp=none "$macos/lungfish-cli"
            codesign --force --sign - --timestamp=none "$tools/micromamba"
            """,
        )
        self._write_executable(
            self.repo / "scripts/smoke-test-release-tools.sh",
            r"""
            #!/bin/bash
            set -eu
            phase=complete
            scratch=
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --portability-only) phase=portability ;;
                    --allowed-swiftpm-fallback) scratch="$2"; shift ;;
                esac
                shift
            done
            printf 'smoke:%s:%s\n' "$phase" "$scratch" >>"$BUILDER_EVENTS"
            echo 'PASS fixture smoke'
            """,
        )

    def _install_external_tools(self):
        self._write_executable(
            self.bin / "git",
            r"""
            #!/bin/bash
            set -eu
            if [ "${1:-}" = ls-remote ] && [ "${2:-}" = --tags ]; then
                fixture_remote=$(/usr/bin/git config --get "lungfish.fixtureRemote.${3:-}" || true)
                if [ -n "$fixture_remote" ]; then
                    shift 3
                    exec /usr/bin/git ls-remote --tags "$fixture_remote" "$@"
                fi
            fi
            exec /usr/bin/git "$@"
            """,
        )
        self._write_executable(
            self.bin / "xcodebuild",
            r"""
            #!/bin/bash
            set -eu
            if [ "${1:-}" = -version ]; then
                printf 'Xcode 26.4.1\nBuild version 17F90\n'
                exit 0
            fi
            if [ -n "${BUILDER_EXPECT_DEVELOPER_DIR:-}" ] \
                && [ "${DEVELOPER_DIR:-}" != "$BUILDER_EXPECT_DEVELOPER_DIR" ]; then
                exit 91
            fi
            printf 'xcodebuild:%s\n' "$*" >>"$BUILDER_EVENTS"
            archive=
            build=1
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -archivePath) archive="$2"; shift ;;
                    CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;;
                esac
                shift
            done
            app="$archive/Products/Applications/Lungfish.app"
            mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle"
            printf 'unsigned-app\n' >"$app/Contents/MacOS/Lungfish"
            chmod 755 "$app/Contents/MacOS/Lungfish"
            "$BUILDER_PYTHON" - "$app/Contents/Info.plist" "$build" <<'PY'
            import plistlib, sys
            with open(sys.argv[1], 'wb') as handle:
                plistlib.dump({
                    'CFBundleDisplayName': 'Lungfish Genome Explorer',
                    'CFBundleName': 'Lungfish',
                    'CFBundleIdentifier': 'com.lungfish.browser',
                    'CFBundleExecutable': 'Lungfish',
                    'CFBundleShortVersionString': '2026.8.1',
                    'CFBundleVersion': sys.argv[2],
                    'LungfishReleaseChannel': 'stable',
                    'SUFeedURL': 'https://example.test/appcast.xml',
                }, handle, sort_keys=True)
            PY
            """,
        )
        self._write_executable(
            self.bin / "xcrun",
            r"""
            #!/bin/bash
            set -eu
            if [ "${1:-}" = swift ] && [ "${2:-}" = --version ]; then
                echo 'Apple Swift version 6.2 (swiftlang-test)'
                exit 0
            fi
            if [ "${1:-}" = --sdk ]; then
                if [ "${3:-}" = --show-sdk-build-version ]; then
                    echo '25A100'
                else
                    echo '26.0'
                fi
                exit 0
            fi
            if [ "${1:-}" = swift ] && [ "${2:-}" = build ]; then
                printf 'swift:%s\n' "$*" >>"$BUILDER_EVENTS"
                scratch=
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = --scratch-path ]; then scratch="$2"; shift; fi
                    shift
                done
                mkdir -p "$scratch/arm64-apple-macosx/release"
                printf '#!/bin/sh\necho lungfish-cli test\n' >"$scratch/arm64-apple-macosx/release/lungfish-cli"
                chmod 755 "$scratch/arm64-apple-macosx/release/lungfish-cli"
                exit 0
            fi
            printf 'xcrun:%s\n' "$*" >>"$BUILDER_EVENTS"
            if [ "${1:-}" = notarytool ] && [ "${2:-}" = submit ] \
                && [[ "${3:-}" = *.dmg ]] \
                && [ "${BUILDER_FAIL_DMG_PHASE:-}" = notary ]; then
                exit 78
            fi
            if [ "${1:-}" = stapler ] && [ "${2:-}" = staple ] \
                && [[ "${3:-}" = *.dmg ]] \
                && [ "${BUILDER_FAIL_DMG_PHASE:-}" = staple ]; then
                exit 79
            fi
            exit 0
            """,
        )
        self._write_executable(
            self.bin / "uname",
            '#!/bin/sh\n[ "${1:-}" = -m ] && echo arm64 || /usr/bin/uname "$@"\n',
        )
        for name, body in {
            "codesign": r"""
                printf 'codesign:%s\n' "$*" >>"$BUILDER_EVENTS"
                if [[ " $* " == *" --sign - "* ]]; then
                    exit 0
                fi
                if [ "${BUILDER_CODESIGN_MUTATE:-0}" = 1 ] \
                    && [[ " $* " == *" --sign "* ]]; then
                    target="${@: -1}"
                    if [ -d "$target" ]; then
                        target="$target/Contents/MacOS/Lungfish"
                    fi
                    printf '\nfixture-developer-id-mutation\n' >>"$target"
                    count_file="$BUILDER_CODESIGN_COUNT"
                    count=0
                    if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
                    count=$((count + 1))
                    printf '%s\n' "$count" >"$count_file"
                    if [ "${BUILDER_CODESIGN_FAIL_AT:-0}" = "$count" ]; then
                        exit 77
                    fi
                fi
                target="${@: -1}"
                if [ "${BUILDER_NONDETERMINISTIC_DMG:-0}" = 1 ] \
                    && [[ "$target" = *.dmg ]] \
                    && [[ " $* " == *" --sign "* ]]; then
                    printf 'fixture-dmg-signature:%s\n' "$(wc -l <"$BUILDER_EVENTS")" >>"$target"
                fi
            """,
            "security": 'printf \'security:%s\\n\' "$*" >>"$BUILDER_EVENTS"\nexit 0\n',
            "file": "echo 'Mach-O 64-bit executable arm64'\n",
            "ditto": 'printf \'ditto:%s\\n\' "$*" >>"$BUILDER_EVENTS"\nif [ "${1:-}" = -c ]; then : >"${@: -1}"; else cp -R "$1" "$2"; fi\n',
            "hdiutil": r"""
                printf 'hdiutil:%s\n' "$*" >>"$BUILDER_EVENTS"
                case "${1:-}" in
                    create)
                        target="${@: -1}"
                        source=
                        while [ "$#" -gt 0 ]; do
                            if [ "$1" = -srcfolder ]; then source="$2"; shift; fi
                            shift
                        done
                        [ ! -e "$target" ] || exit 73
                        printf 'fixture-dmg\n' >"$target"
                        rm -rf "${target}.fixture-app"
                        cp -R "$source" "${target}.fixture-app"
                        ;;
                    attach)
                        dmg="${@: -1}"
                        mountpoint=
                        while [ "$#" -gt 0 ]; do
                            if [ "$1" = -mountpoint ]; then mountpoint="$2"; shift; fi
                            shift
                        done
                        mkdir -p "$mountpoint"
                        fixture="${dmg}.fixture-app"
                        if [ ! -d "$fixture" ]; then
                            fixture="${BUILDER_REMOTE_DMG_FIXTURE:-}"
                        fi
                        cp -R "$fixture"/. "$mountpoint"/
                        ;;
                    detach)
                        if [ "${BUILDER_FAIL_DETACH:-0}" = 1 ]; then
                            printf 'mounted-sentinel\n' >"$2/mounted-sentinel.txt"
                            exit 81
                        fi
                        ;;
                    *) exit 64 ;;
                esac
            """,
        }.items():
            self._write_executable(self.bin / name, f"#!/bin/bash\nset -eu\n{body}")

        self._write_executable(
            self.bin / "shasum",
            r"""
            target="${@: -1}"
            if [ -n "${BUILDER_FORGED_SHA256:-}" ] \
                && [[ "$target" = *.dmg || "$target" = *.xml ]]; then
                printf '%s  %s\n' "$BUILDER_FORGED_SHA256" "$target"
                printf 'shasum-spoof:%s\n' "$*" >>"$BUILDER_EVENTS"
                exit 0
            fi
            exec /usr/bin/shasum "$@"
            """,
        )

        self._write_executable(
            self.bin / "generate_appcast",
            r"""
            #!/bin/bash
            set -eu
            original_args="$*"
            output=
            directory="${@: -1}"
            while [ "$#" -gt 0 ]; do
                if [ "$1" = -o ]; then output="$2"; shift; fi
                shift
            done
            dmg=$(find "$directory" -maxdepth 1 -name '*.dmg' -type f -print -quit)
            digest=$(shasum -a 256 "$dmg" | awk '{print $1}')
            printf 'fixture-appcast:%s\n' "$digest" >"$output"
            printf 'generate_appcast:%s\n' "$original_args" >>"$BUILDER_EVENTS"
            """,
        )
        self._write_executable(
            self.bin / "gh",
            r"""
            #!/usr/bin/env python3
            import hashlib
            import json
            import os
            from pathlib import Path
            import re
            import shutil
            import sys

            arguments = sys.argv[1:]
            expected_repository = os.environ.get("BUILDER_EXPECTED_GH_REPO")
            require_explicit_repository = os.environ.get("BUILDER_REQUIRE_EXPLICIT_GH_REPO") == "1"
            if arguments[:1] == ["--repo"]:
                if len(arguments) < 3 or expected_repository and arguments[1] != expected_repository:
                    raise SystemExit(89)
                arguments = arguments[2:]
            elif require_explicit_repository:
                raise SystemExit(90)
            with Path(os.environ["BUILDER_EVENTS"]).open("a", encoding="utf-8") as handle:
                handle.write("gh:" + " ".join(arguments) + "\n")
            state_path = Path(os.environ["BUILDER_GH_STATE"])
            state = json.loads(state_path.read_text()) if state_path.exists() else {"releases": {}}
            releases = state["releases"]
            asset_store = state_path.parent / "gh-assets"
            asset_store.mkdir(exist_ok=True)

            def save():
                state_path.write_text(json.dumps(state, sort_keys=True), encoding="utf-8")

            def asset(path):
                path = Path(path)
                data = path.read_bytes()
                stored = asset_store / f"{len(list(asset_store.iterdir()))}-{path.name}"
                shutil.copy2(path, stored)
                return {
                    "name": path.name,
                    "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                    "size": len(data),
                    "storedPath": str(stored),
                }

            if arguments[:2] != ["release", "view"] and arguments[:2] != ["release", "create"] \
                    and arguments[:2] != ["release", "edit"] and arguments[:2] != ["release", "upload"] \
                    and arguments[:2] != ["release", "download"]:
                raise SystemExit(64)
            if expected_repository and os.environ.get("GH_REPO") != expected_repository:
                raise SystemExit(89)
            if os.environ.get("BUILDER_REJECT_GH_HOST") == "1" and os.environ.get("GH_HOST"):
                raise SystemExit(91)
            action = arguments[1]
            tag = arguments[2]
            if action == "view":
                release = releases.get(tag)
                if release is None:
                    raise SystemExit(1)
                if "--jq" not in arguments:
                    if "--json" in arguments:
                        print(json.dumps(release))
                    raise SystemExit(0)
                expression = arguments[arguments.index("--jq") + 1]
                fields = {
                    ".targetCommitish": release["targetCommitish"],
                    ".isPrerelease": str(release["isPrerelease"]).lower(),
                    ".isDraft": str(release["isDraft"]).lower(),
                }
                if expression in fields:
                    print(fields[expression])
                    raise SystemExit(0)
                match = re.search(r'select\(\.name == "([^"]+)"\)', expression)
                selected = [item for item in release["assets"] if match and item["name"] == match.group(1)]
                if "@tsv" in expression:
                    for item in selected:
                        print(f'{item["digest"]}\t{item["size"]}')
                elif ".digest" in expression:
                    for item in selected:
                        print(item["digest"])
                raise SystemExit(0)
            if action == "create":
                if tag.startswith("sparkle-") and os.environ.get("BUILDER_FAIL_FEED_CREATE") == "1":
                    raise SystemExit(88)
                target = arguments[arguments.index("--target") + 1]
                release = {
                    "targetCommitish": target,
                    "isPrerelease": "--prerelease" in arguments,
                    "isDraft": False,
                    "assets": [],
                }
                if len(arguments) > 3 and not arguments[3].startswith("--"):
                    release["assets"].append(asset(arguments[3]))
                releases[tag] = release
                save()
                raise SystemExit(0)
            release = releases.get(tag)
            if release is None:
                raise SystemExit(1)
            if action == "edit":
                release["targetCommitish"] = arguments[arguments.index("--target") + 1]
                save()
                raise SystemExit(0)
            if action == "upload":
                interrupted = tag + ":" + Path(arguments[3]).name
                if os.environ.get("BUILDER_FAIL_MUTABLE_ASSET") == interrupted:
                    print("injected mutable interruption: " + interrupted, file=sys.stderr)
                    raise SystemExit(93)
                if tag.startswith("sparkle-") and os.environ.get("BUILDER_FAIL_FEED_UPLOAD") == "1":
                    raise SystemExit(92)
                replacement = asset(arguments[3])
                existing = [item for item in release["assets"] if item["name"] == replacement["name"]]
                if existing and "--clobber" not in arguments:
                    raise SystemExit(1)
                release["assets"] = [item for item in release["assets"] if item["name"] != replacement["name"]]
                release["assets"].append(replacement)
                save()
                raise SystemExit(0)
            pattern = arguments[arguments.index("--pattern") + 1]
            destination = Path(arguments[arguments.index("--dir") + 1])
            selected = [item for item in release["assets"] if item["name"] == pattern]
            if len(selected) != 1:
                raise SystemExit(1)
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(selected[0]["storedPath"], destination / pattern)
            fixture = os.environ.get("BUILDER_REMOTE_DMG_FIXTURE")
            if fixture:
                shutil.copytree(
                    fixture,
                    destination / f"{pattern}.fixture-app",
                    symlinks=True,
                )
            """,
        )

    def _adapt_canonical_tools_for_fixture(self):
        """Redirect only this disposable builder copy to explicit test doubles."""
        source = self.builder.read_text(encoding="utf-8")
        # The real graphical gate is replaced only in this disposable fixture.
        # Its retained records exercise receipts, and never count as GUI evidence.
        self._write(self.repo / "scripts/release/app-smoke-fixture.py", "\n".join([
            "import argparse, json, os, pathlib, subprocess, sys",
            "sys.path.insert(0, " + repr(str(ROOT)) + ")",
            "from scripts.tests.gate_fixtures import make_app_smoke_fixture",
            "p=argparse.ArgumentParser()",
            "[p.add_argument('--'+key, required=True) for key in ('root','app','channel','output','derived-data')]",
            "a=p.parse_args()",
            "if os.environ.get('BUILDER_FAIL_APP_SMOKE'): raise SystemExit(94)",
            "commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=a.root,text=True).strip()",
            "make_app_smoke_fixture(pathlib.Path(a.output), {'commit':commit,'clean':True}, pathlib.Path(a.app), pathlib.Path(a.root)/'config/release-contract.json')",
            "",
        ]))
        source = source.replace('/scripts/release/app_smoke_gate.py', '/scripts/release/app-smoke-fixture.py')
        # Production Python helpers are bound to the front-door interpreter.
        # These two fixture doubles are intentionally Bash scripts, so retain
        # their executable shebangs in the disposable copy.
        source = source.replace(
            '"$RELEASE_PYTHON" "$RELEASE_DOCTOR_SCRIPT"',
            '"$RELEASE_DOCTOR_SCRIPT"',
        )
        source = source.replace(
            '"$RELEASE_PYTHON" "$CANDIDATE_RECEIPT_SCRIPT"',
            '"$CANDIDATE_RECEIPT_SCRIPT"',
        )
        for canonical, replacement in {
            "/usr/bin/codesign": self.bin / "codesign",
            "/usr/bin/ditto": self.bin / "ditto",
            "/usr/bin/hdiutil": self.bin / "hdiutil",
            "/usr/bin/xcrun": self.bin / "xcrun",
        }.items():
            source = source.replace(canonical, str(replacement))
        self.builder.write_text(source, encoding="utf-8")

    def run(
        self,
        *arguments,
        doctor_fail=False,
        release=None,
        archive=None,
        derived=None,
        extra_env=None,
        coordinated=True,
        include_output_paths=True,
    ):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bin}:{environment['PATH']}",
                "BUILDER_EVENTS": str(self.events),
                "BUILDER_PYTHON": str(PYTHON),
                "BUILDER_MANAGED_MANIFEST": str(
                    self.repo
                    / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
                ),
                "LUNGFISH_RELEASE_CACHE_ROOT": str(self.scratch_root),
                "LUNGFISH_RELEASE_SCRATCH_ROOT": str(self.scratch_root),
                "LUNGFISH_RELEASE_PYTHON": str(PYTHON),
                "LUNGFISH_SPARKLE_PUBLIC_ED_KEY": "public-test-key",
                "BUILDER_DOCTOR_FAIL": "1" if doctor_fail else "0",
                "BUILDER_CODESIGN_COUNT": str(self.root / "codesign-count"),
                "BUILDER_GH_STATE": str(self.gh_state),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        if extra_env:
            environment.update(extra_env)
        if coordinated:
            environment["LUNGFISH_RELEASE_COORDINATOR_CAPABILITY"] = "a" * 64
        command = ["/bin/bash", str(self.builder)]
        channel = arguments[arguments.index("--channel") + 1] if "--channel" in arguments else "stable"
        staging = Path(tempfile.mkdtemp(prefix="gates-", dir=self.root)) / "evidence"
        manifest = make_gate_fixture(staging, {"clean": True, "commit": self._git("rev-parse", "HEAD").stdout.strip()}, channel,
                                     json.loads((self.repo / "config/release-contract.json").read_text())["gates"]["focusedReleaseTests"])
        command += ["--gate-manifest", str(manifest), "--gate-manifest-sha256", hashlib.sha256(manifest.read_bytes()).hexdigest()]

        if include_output_paths:
            command.extend(
                [
                    "--release-dir",
                    str(release or self.release),
                    "--archive-path",
                    str(archive or self.archive),
                ]
            )
        command.extend(arguments)
        if derived is not None:
            command[2:2] = ["--derived-data-path", str(derived)]
        return subprocess.run(
            command,
            cwd=self.repo,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def event_lines(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def verify_receipt(self, *, channel="stable"):
        return subprocess.run(
            [
                str(PYTHON),
                str(self.repo / "scripts/release/release-candidate-receipt-real.py"),
                "verify",
                "--app",
                str(self.release / "Lungfish.app"),
                "--receipt",
                str(self.release / "unsigned-candidate-receipt.json"),
                "--channel",
                channel,
                "--cache-root",
                str(self.scratch_root),
            ],
            cwd=self.repo,
            env={
                **os.environ,
                "PATH": f"{self.bin}:{os.environ['PATH']}",
                "BUILDER_EVENTS": str(self.events),
                "BUILDER_CODESIGN_COUNT": str(self.root / "codesign-count"),
                "PYTHONDONTWRITEBYTECODE": "1",
                "LUNGFISH_RELEASE_CACHE_ROOT": str(self.scratch_root),
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def prepare_remote_tag(
        self,
        tag="v2026.8.1",
        *,
        remote_name="origin",
        github_url="https://github.com/example/lungfish.git",
    ):
        remote = self.root / f"{remote_name}.git"
        subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
        self._git("config", f"lungfish.fixtureRemote.{remote_name}", str(remote))
        existing = self._git("remote").stdout.splitlines()
        if remote_name in existing:
            self._git("remote", "set-url", remote_name, github_url)
        else:
            self._git("remote", "add", remote_name, github_url)
        self._git("tag", "-a", tag, "-m", f"fixture {tag}")
        self._git("push", "-q", str(remote), tag)

    def _git(self, *arguments):
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    @staticmethod
    def _parent(path):
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    @classmethod
    def _write(cls, path, contents):
        cls._parent(path).write_text(
            textwrap.dedent(contents).lstrip(), encoding="utf-8"
        )

    @classmethod
    def _write_executable(cls, path, contents):
        cls._write(path, contents)
        path.chmod(0o755)


class ReleaseBuilderPhaseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ReleaseBuilderFixture(self)

    def tearDown(self):
        self.fixture.cleanup()

    def _stable_resume_args(self, fixture=None):
        selected = fixture or self.fixture
        return (
            "--resume-candidate",
            str(selected.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "stable",
            "--github-release-tag",
            "v2026.8.1",
            "--sparkle-generate-appcast",
            str(selected.bin / "generate_appcast"),
        )

    def test_stable_gui_failure_blocks_candidate_receipt_and_package_success(self):
        result = self.fixture.run("--package-only", "--channel", "stable",
                                  extra_env={"BUILDER_FAIL_APP_SMOKE": "1"})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.fixture.release / "unsigned-candidate-receipt.json").exists())
        self.assertNotIn("Unsigned package complete", result.stdout)

    def test_package_only_needs_no_credentials_and_stops_before_private_or_remote_tools(
        self,
    ):
        result = self.fixture.run(
            "--package-only",
            "--channel",
            "preview",
            extra_env={
                "PATH": f"{self.fixture.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                "SPARKLE_GENERATE_APPCAST": str(self.fixture.bin / "must-not-run"),
                "SPARKLE_ED_KEY_FILE": str(self.fixture.root / "private-key"),
            },
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.fixture.event_lines()
        self.assertTrue(
            any("doctor:--mode package --channel preview" in line for line in events)
        )
        package_seals = [line for line in events if line.startswith("codesign:")]
        self.assertTrue(package_seals)
        self.assertTrue(
            all("--sign - --timestamp=none" in line for line in package_seals)
        )
        self.assertFalse(any("Developer ID" in line for line in package_seals))
        self.assertFalse(any(line.startswith(("security:", "gh:")) for line in events))
        self.assertFalse(any("notarytool" in line for line in events))
        app = self.fixture.release / "Lungfish Preview.app"
        receipt = self.fixture.release / "unsigned-candidate-receipt.json"
        metadata = self.fixture.release / "package-metadata.txt"
        self.assertTrue(app.is_dir())
        self.assertTrue(receipt.is_file())
        self.assertTrue(metadata.is_file())
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleIdentifier"], "com.lungfish.browser.preview")
        self.assertEqual(info["LungfishReleaseChannel"], "preview")
        self.assertEqual(info["SUPublicEDKey"], "public-test-key")
        self.assertTrue(info["SUFeedURL"].endswith("/sparkle-beta/appcast-beta.xml"))
        self.assertEqual(info["CFBundleIconFile"], "AppIcon")
        self.assertEqual(info["CFBundleIconName"], "AppIcon")
        self.assertTrue((app / "Contents/Resources/AppIcon.icns").is_file())

        before = len(events)
        rejected_identity = self.fixture.run(
            "--package-only",
            "--channel",
            "preview",
            "--signing-identity",
            "Developer ID Application: Must Not Be Read (PRIVATE)",
        )
        self.assertEqual(rejected_identity.returncode, 64)
        self.assertIn("cannot accept credential", rejected_identity.stderr)
        self.assertEqual(self.fixture.event_lines()[before:], [])

    def test_direct_credentialed_prepare_resume_and_recovery_require_release_coordinator(
        self,
    ):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        credentialed = (
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "stable",
            "--github-release-tag",
            "v2026.8.1",
            "--sparkle-generate-appcast",
            str(self.fixture.bin / "generate_appcast"),
        )
        cases = (
            ("prepare", (*credentialed, "--defer-remote-publish")),
            ("resume", self._stable_resume_args()),
            (
                "recovery",
                (*self._stable_resume_args(), "--recover-existing-release"),
            ),
        )

        for label, arguments in cases:
            with self.subTest(label=label):
                result = self.fixture.run(*arguments, coordinated=False)

                self.assertEqual(result.returncode, 64)
                self.assertIn("scripts/release/release.py", result.stderr)

    def test_package_phase_is_unsigned_fail_only_and_shares_one_deterministic_scratch(
        self,
    ):
        result = self.fixture.run("--package-only", "--channel", "stable")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.fixture.event_lines()
        archive = next(line for line in events if line.startswith("xcodebuild:"))
        self.assertIn("CODE_SIGNING_ALLOWED=NO", archive)
        self.assertIn("CODE_SIGNING_REQUIRED=NO", archive)
        swift = next(line for line in events if line.startswith("swift:"))
        scratch = swift.split("--scratch-path ", 1)[1].split()[0]
        derived = archive.split("-derivedDataPath ", 1)[1].split()[0]
        self.assertTrue(Path(scratch).is_absolute())
        self.assertTrue(scratch.startswith(str(self.fixture.scratch_root) + os.sep))
        self.assertEqual(Path(scratch).name, "swiftpm")
        self.assertEqual(Path(derived).name, "derived-data")
        self.assertEqual(Path(scratch).parent, Path(derived).parent)
        self.assertIn(f"-Xlinker -oso_prefix -Xlinker {scratch}/", swift)
        smoke = [line for line in events if line.startswith("smoke:")]
        self.assertEqual(
            smoke, [f"smoke:portability:{scratch}", f"smoke:complete:{scratch}"]
        )
        receipt = next(line for line in events if line.startswith("receipt:create:"))
        self.assertIn(f"--scratch-path {scratch}", receipt)
        payload = json.loads(
            (self.fixture.release / "unsigned-candidate-receipt.json").read_text()
        )
        self.assertEqual(payload["cache"]["fingerprint"], Path(scratch).parent.name)

    def test_direct_builder_defaults_to_scoped_output_and_preserves_siblings(self):
        other = self.fixture.repo / "build/Release/stable" / ("f" * 40)
        other.mkdir(parents=True)
        sentinel = other / "preserve.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.fixture.repo,
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()

        result = self.fixture.run(
            "--package-only",
            "--channel",
            "stable",
            include_output_paths=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        scoped = self.fixture.repo / "build/Release/stable" / commit
        self.assertTrue((scoped / "unsigned-candidate-receipt.json").is_file())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_explicit_broad_legacy_release_root_is_rejected_without_cleanup(self):
        broad = self.fixture.repo / "build/Release"
        broad.mkdir(parents=True, exist_ok=True)
        sentinel = broad / "legacy-preserve.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")

        result = self.fixture.run(
            "--package-only",
            "--channel",
            "stable",
            release=broad,
            archive=broad / "Lungfish.xcarchive",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unrecognized repository output", result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_resume_rejects_broad_legacy_marker_before_signing(self):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        broad = self.fixture.repo / "build/Release"
        shutil.copytree(self.fixture.release, broad, dirs_exist_ok=True)
        receipt_path = broad / "unsigned-candidate-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        marker = broad / ".lungfish-release-output"
        marker.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "outputType": "lungfish-release-output",
                    "repositoryKey": receipt["cache"]["fields"]["repository"]["key"],
                    "releaseDir": str(broad),
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        marker.chmod(0o600)
        sentinel = broad / "preserve.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")
        self.fixture.events.write_text("", encoding="utf-8")
        arguments = list(self._stable_resume_args())
        arguments[1] = str(receipt_path)

        result = self.fixture.run(*arguments)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact channel/commit", result.stdout + result.stderr)
        self.assertFalse(
            any(
                line.startswith("codesign:")
                for line in self.fixture.event_lines()
            )
        )
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_builder_exports_the_shared_canonical_xcode_selection(self):
        default = Path("/Applications/Xcode.app/Contents/Developer")
        developer_dir = (
            default.resolve()
            if default.is_dir()
            else Path(
                subprocess.run(
                    ["xcode-select", "-p"],
                    text=True,
                    stdout=subprocess.PIPE,
                    check=True,
                ).stdout.strip()
            ).resolve()
        )
        alias = self.fixture.root / "selected-developer"
        alias.symlink_to(developer_dir, target_is_directory=True)

        result = self.fixture.run(
            "--package-only",
            "--channel",
            "stable",
            extra_env={
                "DEVELOPER_DIR": str(alias),
                "BUILDER_EXPECT_DEVELOPER_DIR": str(developer_dir),
            },
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_xcode_archive_cannot_resolve_or_embed_derived_data_path(self):
        result = self.fixture.run("--package-only", "--channel", "stable")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = next(
            line
            for line in self.fixture.event_lines()
            if line.startswith("xcodebuild:")
        )
        self.assertIn("-disableAutomaticPackageResolution", archive)
        derived = archive.split("-derivedDataPath ", 1)[1].split()[0]
        self.assertIn(f"-ffile-prefix-map={derived}=/xcode-derived", archive)
        self.assertIn(f"-fdebug-prefix-map={derived}=/xcode-derived", archive)
        derived_alias = str(derived).removeprefix("/private")
        if derived_alias != str(derived):
            self.assertIn(f"-ffile-prefix-map={derived_alias}=/xcode-derived", archive)
            self.assertIn(f"-fdebug-prefix-map={derived_alias}=/xcode-derived", archive)

    def test_lockfile_divergence_fails_without_repair_or_archive(self):
        xcode_lock = (
            self.fixture.repo
            / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        xcode_lock.parent.mkdir(parents=True, exist_ok=True)
        xcode_lock.write_text('{"pins":[{"identity":"different"}],"version":2}\n')
        original = xcode_lock.read_bytes()

        result = self.fixture.run("--package-only")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Package.resolved divergence", result.stderr)
        self.assertEqual(xcode_lock.read_bytes(), original)
        self.assertTrue(
            any(line.startswith("doctor:") for line in self.fixture.event_lines())
        )
        self.assertFalse(
            any(line.startswith("xcodebuild:") for line in self.fixture.event_lines())
        )

    def test_doctor_failure_preserves_existing_output_and_creates_no_scratch(self):
        self.fixture.release.mkdir()
        sentinel = self.fixture.release / "keep.txt"
        sentinel.write_text("keep\n")

        result = self.fixture.run("--package-only", doctor_fail=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL fixture doctor", result.stderr)
        self.assertTrue(
            any(line.startswith("doctor:") for line in self.fixture.event_lines())
        )
        self.assertEqual(sentinel.read_text(), "keep\n")
        self.assertFalse(self.fixture.scratch_root.exists())

    def test_existing_unrelated_archive_is_rejected_without_deleting_sentinel(self):
        archive = self.fixture.root / "unrelated.xcarchive"
        archive.mkdir()
        sentinel = archive / "do-not-delete.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")

        result = self.fixture.run("--package-only", archive=archive)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
        self.assertFalse(
            any(line.startswith("xcodebuild:") for line in self.fixture.event_lines())
        )

    def test_unmarked_unrelated_xcode_archive_shape_is_preserved(self):
        archive = self.fixture.root / "plausible-but-unrelated.xcarchive"
        other_app = archive / "Products/Applications/Other.app/Contents"
        other_app.mkdir(parents=True)
        unrelated_plist = other_app / "Info.plist"
        unrelated_plist.write_text("not even a plist\n", encoding="utf-8")

        result = self.fixture.run("--package-only", archive=archive)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            unrelated_plist.read_text(encoding="utf-8"), "not even a plist\n"
        )
        self.assertFalse(
            any(line.startswith("xcodebuild:") for line in self.fixture.event_lines())
        )

    def test_builder_records_private_archive_marker_for_its_own_retry(self):
        first = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        receipt = json.loads(
            (self.fixture.release / "unsigned-candidate-receipt.json").read_text()
        )
        marker = self.fixture.archive / ".lungfish-release-archive.json"
        self.assertEqual(
            json.loads(marker.read_text(encoding="utf-8")),
            {
                "outputType": "lungfish-xcarchive",
                "repositoryKey": receipt["cache"]["fields"]["repository"]["key"],
                "schemaVersion": 1,
            },
        )
        self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)

        second = self.fixture.run("--package-only", "--channel", "stable")

        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)

    def test_builder_records_private_path_bound_release_marker(self):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        receipt = json.loads(
            (self.fixture.release / "unsigned-candidate-receipt.json").read_text()
        )
        marker = self.fixture.release / ".lungfish-release-output"

        self.assertEqual(
            json.loads(marker.read_text(encoding="utf-8")),
            {
                "outputType": "lungfish-release-output",
                "releaseDir": str(self.fixture.release),
                "repositoryKey": receipt["cache"]["fields"]["repository"]["key"],
                "schemaVersion": 1,
            },
        )
        self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
        self.assertFalse(marker.is_symlink())

    def test_relocated_receipt_and_candidate_never_authorize_sibling_cleanup(self):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        source_receipt = self.fixture.release / "unsigned-candidate-receipt.json"
        source_app = self.fixture.release / "Lungfish.app"
        source_marker = self.fixture.release / ".lungfish-release-output"

        for copy_marker in (False, True):
            with self.subTest(copy_marker=copy_marker):
                relocated = self.fixture.root / f"relocated-{int(copy_marker)}"
                relocated.mkdir()
                shutil.copytree(source_app, relocated / "Lungfish.app")
                shutil.copy2(source_receipt, relocated / source_receipt.name)
                if copy_marker:
                    shutil.copy2(source_marker, relocated / source_marker.name)
                signed = relocated / "signed"
                signed.mkdir()
                sentinel = signed / "valuable-user-data.txt"
                sentinel.write_text("preserve\n", encoding="utf-8")
                (self.fixture.root / "codesign-count").unlink(missing_ok=True)
                events_before = len(self.fixture.event_lines())

                resumed = self.fixture.run(
                    "--resume-candidate",
                    str(relocated / source_receipt.name),
                    "--signing-identity",
                    "Developer ID Application: Test (TEAMID)",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "fixture",
                    "--defer-remote-publish",
                    "--channel",
                    "stable",
                    extra_env={
                        "BUILDER_CODESIGN_MUTATE": "1",
                        "BUILDER_CODESIGN_FAIL_AT": "1",
                    },
                )

                self.assertNotEqual(
                    resumed.returncode, 0, resumed.stdout + resumed.stderr
                )
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
                new_events = self.fixture.event_lines()[events_before:]
                self.assertFalse(
                    any("--mode credentials" in line for line in new_events)
                )
                self.assertFalse(
                    any(line.startswith("codesign:") for line in new_events)
                )

    def test_resume_release_marker_must_be_exact_private_and_path_bound(self):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        receipt_path = self.fixture.release / "unsigned-candidate-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        marker = self.fixture.release / ".lungfish-release-output"
        valid = {
            "schemaVersion": 1,
            "outputType": "lungfish-release-output",
            "repositoryKey": receipt["cache"]["fields"]["repository"]["key"],
            "releaseDir": str(self.fixture.release),
        }
        cases = {
            "wrong schema": {**valid, "schemaVersion": 2},
            "wrong output type": {**valid, "outputType": "other-output"},
            "wrong repository": {**valid, "repositoryKey": "f" * 64},
            "wrong path": {**valid, "releaseDir": str(self.fixture.root)},
            "public mode": valid,
            "symlink": valid,
        }
        for label, payload in cases.items():
            with self.subTest(label=label):
                marker.unlink(missing_ok=True)
                target = self.fixture.release / "forged-release-marker.json"
                target.unlink(missing_ok=True)
                serialized = json.dumps(payload) + "\n"
                if label == "symlink":
                    target.write_text(serialized, encoding="utf-8")
                    target.chmod(0o600)
                    marker.symlink_to(target)
                else:
                    marker.write_text(serialized, encoding="utf-8")
                    marker.chmod(0o644 if label == "public mode" else 0o600)
                signed = self.fixture.release / "signed"
                signed.mkdir(exist_ok=True)
                sentinel = signed / "valuable-user-data.txt"
                sentinel.write_text("preserve\n", encoding="utf-8")
                events_before = len(self.fixture.event_lines())

                resumed = self.fixture.run(
                    "--resume-candidate",
                    str(receipt_path),
                    "--signing-identity",
                    "Developer ID Application: Test (TEAMID)",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "fixture",
                    "--defer-remote-publish",
                    "--channel",
                    "stable",
                )

                self.assertNotEqual(
                    resumed.returncode, 0, resumed.stdout + resumed.stderr
                )
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
                new_events = self.fixture.event_lines()[events_before:]
                self.assertFalse(
                    any("--mode credentials" in line for line in new_events)
                )
                self.assertFalse(
                    any(line.startswith("codesign:") for line in new_events)
                )

    def test_archive_marker_must_be_private_exact_and_repository_bound(self):
        repository_key = hashlib.sha256(str(self.fixture.repo).encode()).hexdigest()
        valid = {
            "schemaVersion": 1,
            "outputType": "lungfish-xcarchive",
            "repositoryKey": repository_key,
        }
        cases = {
            "wrong schema": {**valid, "schemaVersion": 2},
            "wrong output type": {**valid, "outputType": "other-xcarchive"},
            "wrong repository": {**valid, "repositoryKey": "f" * 64},
            "public mode": valid,
            "symlink": valid,
        }
        for index, (label, payload) in enumerate(cases.items()):
            with self.subTest(label=label):
                archive = self.fixture.root / f"forged-{index}.xcarchive"
                other_app = archive / "Products/Applications/Other.app/Contents"
                other_app.mkdir(parents=True)
                unrelated_plist = other_app / "Info.plist"
                unrelated_plist.write_text("preserve\n", encoding="utf-8")
                marker = archive / ".lungfish-release-archive.json"
                marker_payload = json.dumps(payload) + "\n"
                if label == "symlink":
                    target = archive / "forged-marker.json"
                    target.write_text(marker_payload, encoding="utf-8")
                    target.chmod(0o600)
                    marker.symlink_to(target)
                else:
                    marker.write_text(marker_payload, encoding="utf-8")
                    marker.chmod(0o644 if label == "public mode" else 0o600)

                result = self.fixture.run("--package-only", archive=archive)

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    unrelated_plist.read_text(encoding="utf-8"), "preserve\n"
                )
                self.assertFalse(
                    any(
                        line.startswith("xcodebuild:")
                        for line in self.fixture.event_lines()
                    )
                )

    def test_existing_unrelated_release_and_derived_targets_fail_closed(self):
        for label, overrides in (
            ("release", {"release": self.fixture.root / "unrelated-release"}),
            ("derived", {"derived": self.fixture.root / "unrelated-derived"}),
        ):
            with self.subTest(label=label):
                target = overrides[label]
                target.mkdir()
                sentinel = target / "do-not-delete.txt"
                sentinel.write_text("preserve\n", encoding="utf-8")

                result = self.fixture.run("--package-only", **overrides)

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
                self.assertFalse(
                    any(
                        line.startswith("xcodebuild:")
                        for line in self.fixture.event_lines()
                    )
                )

    def test_repository_scratch_is_rejected_before_build_or_creation(self):
        scratch = self.fixture.repo / "Sources/unsafe-release-scratch"

        result = self.fixture.run("--package-only", "--scratch-path", str(scratch))

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(scratch.exists())
        self.assertFalse(
            any(line.startswith("xcodebuild:") for line in self.fixture.event_lines())
        )

    def test_symlinked_release_target_is_rejected_without_replacing_link(self):
        outside = self.fixture.root / "outside-release"
        outside.mkdir()
        sentinel = outside / "do-not-delete.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")
        release_link = self.fixture.root / "release-link"
        release_link.symlink_to(outside, target_is_directory=True)

        result = self.fixture.run("--package-only", release=release_link)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(release_link.is_symlink())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
        self.assertFalse(
            any(line.startswith("xcodebuild:") for line in self.fixture.event_lines())
        )

    def test_non_archive_suffix_and_alias_archive_are_rejected_without_cleanup(self):
        for archive in (
            self.fixture.root / "not-an-archive",
            self.fixture.root / "alias-parent/../aliased.xcarchive",
        ):
            with self.subTest(archive=archive):
                actual = archive.resolve(strict=False)
                actual.mkdir(parents=True)
                sentinel = actual / "do-not-delete.txt"
                sentinel.write_text("preserve\n", encoding="utf-8")

                result = self.fixture.run("--package-only", archive=archive)

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
                self.assertFalse(
                    any(
                        line.startswith("xcodebuild:")
                        for line in self.fixture.event_lines()
                    )
                )

    def test_overlapping_release_and_derived_targets_fail_before_cleanup(self):
        self.fixture.release.mkdir()
        sentinel = self.fixture.release / "do-not-delete.txt"
        sentinel.write_text("preserve\n", encoding="utf-8")

        result = self.fixture.run("--package-only", derived=self.fixture.release)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
        self.assertFalse(
            any(line.startswith("xcodebuild:") for line in self.fixture.event_lines())
        )

    def test_default_flow_smokes_and_verifies_exact_candidate_before_codesign(self):
        result = self.fixture.run(
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self.fixture.event_lines()
        complete = events.index(
            next(line for line in events if line.startswith("smoke:complete:"))
        )
        adhoc_seals = [
            index
            for index, line in enumerate(events)
            if line.startswith("codesign:") and "--sign - --timestamp=none" in line
        ]
        receipt_create = events.index(
            next(line for line in events if line.startswith("receipt:create:"))
        )
        receipt = events.index("receipt:verify:ok")
        sparkle_gate = events.index(
            next(line for line in events if line.startswith("sparkle-gate:"))
        )
        codesign = events.index(
            next(
                line
                for line in events
                if line.startswith("codesign:")
                and "--sign - --timestamp=none" not in line
            )
        )
        credential_doctors = [
            index
            for index, line in enumerate(events)
            if line.startswith("doctor:") and "--mode credentials" in line
        ]
        archive = events.index(
            next(line for line in events if line.startswith("xcodebuild:"))
        )
        self.assertTrue(adhoc_seals)
        self.assertEqual(len(credential_doctors), 2)
        self.assertLess(credential_doctors[0], archive)
        self.assertLess(max(adhoc_seals), complete)
        self.assertLess(complete, receipt_create)
        self.assertLess(receipt_create, credential_doctors[1])
        self.assertLess(credential_doctors[1], receipt)
        self.assertLess(receipt, sparkle_gate)
        self.assertLess(sparkle_gate, codesign)
        self.assertLess(complete, receipt)
        self.assertLess(receipt, codesign)
        self.assertEqual(sum(line.startswith("xcodebuild:") for line in events), 1)
        self.assertEqual(sum(line.startswith("swift:") for line in events), 1)

    def test_feed_advance_during_signing_aborts_before_publication(self):
        self.fixture.prepare_remote_tag()
        result = self.fixture.run(
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "stable",
            "--sparkle-generate-appcast",
            str(self.fixture.bin / "generate_appcast"),
            extra_env={"BUILDER_SPARKLE_GATE_FAIL_ON_CALL": "4"},
        )

        self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
        events = self.fixture.event_lines()
        self.assertTrue(
            any(
                line.startswith("codesign:") and "--sign - --timestamp=none" not in line
                for line in events
            )
        )
        self.assertFalse(any(line.startswith("generate_appcast:") for line in events))
        self.assertFalse(
            any(
                line.startswith(("gh:release create", "gh:release upload"))
                for line in events
            )
        )

    def test_resume_never_rebuilds_and_rejects_payload_change_before_codesign(self):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        app_executable = self.fixture.release / "Lungfish.app/Contents/MacOS/Lungfish"
        app_executable.write_text("changed\n")
        before = len(self.fixture.event_lines())

        resumed = self.fixture.run(
            "--resume-candidate",
            str(self.fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
        )

        self.assertNotEqual(resumed.returncode, 0)
        new_events = self.fixture.event_lines()[before:]
        self.assertFalse(
            any(
                line.startswith(("xcodebuild:", "swift:", "codesign:"))
                for line in new_events
            )
        )
        self.assertTrue(any(line.startswith("receipt:verify:") for line in new_events))

    def test_resume_uses_receipt_bound_scratch_for_signed_portability_scan(self):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        receipt_path = self.fixture.release / "unsigned-candidate-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        expected_scratch = receipt["build"]["scratchPath"]
        events_before_resume = len(self.fixture.event_lines())

        resumed = self.fixture.run(
            "--resume-candidate",
            str(receipt_path),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
        )

        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        resume_smokes = [
            line
            for line in self.fixture.event_lines()[events_before_resume:]
            if line.startswith("smoke:")
        ]
        self.assertTrue(resume_smokes)
        self.assertTrue(
            all(line.endswith(f":{expected_scratch}") for line in resume_smokes),
            resume_smokes,
        )

    def test_failed_mutating_codesign_preserves_receipt_candidate_and_retry_succeeds(
        self,
    ):
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        candidate = self.fixture.release / "Lungfish.app"
        before = {
            path.relative_to(candidate): path.read_bytes()
            for path in candidate.rglob("*")
            if path.is_file()
        }
        receipt_before = self.fixture.verify_receipt()
        self.assertEqual(
            receipt_before.returncode,
            0,
            receipt_before.stdout + receipt_before.stderr,
        )

        failed = self.fixture.run(
            "--resume-candidate",
            str(self.fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
            extra_env={
                "BUILDER_CODESIGN_MUTATE": "1",
                "BUILDER_CODESIGN_FAIL_AT": "1",
            },
        )

        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        after_failure = {
            path.relative_to(candidate): path.read_bytes()
            for path in candidate.rglob("*")
            if path.is_file()
        }
        self.assertEqual(after_failure, before)
        verified_after_failure = self.fixture.verify_receipt()
        self.assertEqual(
            verified_after_failure.returncode,
            0,
            verified_after_failure.stdout + verified_after_failure.stderr,
        )

        (self.fixture.root / "codesign-count").unlink(missing_ok=True)
        events_before_retry = len(self.fixture.event_lines())
        retried = self.fixture.run(
            "--resume-candidate",
            str(self.fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--defer-remote-publish",
            "--channel",
            "stable",
            extra_env={"BUILDER_CODESIGN_MUTATE": "1"},
        )

        self.assertEqual(retried.returncode, 0, retried.stdout + retried.stderr)
        retry_events = self.fixture.event_lines()[events_before_retry:]
        self.assertFalse(
            any(line.startswith(("xcodebuild:", "swift:")) for line in retry_events)
        )
        verified_after_retry = self.fixture.verify_receipt()
        self.assertEqual(
            verified_after_retry.returncode,
            0,
            verified_after_retry.stdout + verified_after_retry.stderr,
        )

    def test_late_dmg_failures_clean_bounded_artifacts_and_resume_without_rebuild(self):
        for failed_phase in ("notary", "staple"):
            with self.subTest(failed_phase=failed_phase):
                fixture = ReleaseBuilderFixture(self)
                self.addCleanup(fixture.cleanup)
                packaged = fixture.run("--package-only", "--channel", "stable")
                self.assertEqual(
                    packaged.returncode, 0, packaged.stdout + packaged.stderr
                )
                candidate = fixture.release / "Lungfish.app"
                candidate_before = {
                    path.relative_to(candidate): path.read_bytes()
                    for path in candidate.rglob("*")
                    if path.is_file()
                }
                resume_args = (
                    "--resume-candidate",
                    str(fixture.release / "unsigned-candidate-receipt.json"),
                    "--signing-identity",
                    "Developer ID Application: Test (TEAMID)",
                    "--team-id",
                    "TEAMID",
                    "--notary-profile",
                    "fixture",
                    "--defer-remote-publish",
                    "--channel",
                    "stable",
                )

                failed = fixture.run(
                    *resume_args,
                    extra_env={
                        "BUILDER_CODESIGN_MUTATE": "1",
                        "BUILDER_FAIL_DMG_PHASE": failed_phase,
                    },
                )

                self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
                dmg = fixture.release / "Lungfish-2026.8.1-arm64.dmg"
                self.assertTrue(dmg.is_file())
                self.assertEqual(
                    {
                        path.relative_to(candidate): path.read_bytes()
                        for path in candidate.rglob("*")
                        if path.is_file()
                    },
                    candidate_before,
                )
                self.assertEqual(fixture.verify_receipt().returncode, 0)
                receipt_path = fixture.release / "unsigned-candidate-receipt.json"
                package_metadata = fixture.release / "package-metadata.txt"
                receipt_before = receipt_path.read_bytes()
                package_metadata_before = package_metadata.read_bytes()
                bounded_sentinel = fixture.release / "do-not-clean.txt"
                bounded_sentinel.write_text("preserve\n", encoding="utf-8")
                signed_sentinel = fixture.release / "signed/do-not-merge.txt"
                signed_sentinel.write_text("stale\n", encoding="utf-8")
                (fixture.release / "Lungfish-app-notary.zip").write_text(
                    "stale\n", encoding="utf-8"
                )
                (fixture.release / "release-metadata.txt").write_text(
                    "stale\n", encoding="utf-8"
                )
                before_retry = len(fixture.event_lines())

                retried = fixture.run(
                    *resume_args,
                    extra_env={"BUILDER_CODESIGN_MUTATE": "1"},
                )

                self.assertEqual(retried.returncode, 0, retried.stdout + retried.stderr)
                retry_events = fixture.event_lines()[before_retry:]
                self.assertFalse(
                    any(
                        line.startswith(("xcodebuild:", "swift:"))
                        for line in retry_events
                    )
                )
                self.assertEqual(
                    sum(line.startswith("hdiutil:") for line in retry_events), 1
                )
                self.assertEqual(
                    {
                        path.relative_to(candidate): path.read_bytes()
                        for path in candidate.rglob("*")
                        if path.is_file()
                    },
                    candidate_before,
                )
                self.assertEqual(fixture.verify_receipt().returncode, 0)
                self.assertEqual(receipt_path.read_bytes(), receipt_before)
                self.assertEqual(package_metadata.read_bytes(), package_metadata_before)
                self.assertEqual(
                    bounded_sentinel.read_text(encoding="utf-8"), "preserve\n"
                )
                self.assertEqual(signed_sentinel.read_text(encoding="utf-8"), "stale\n")
                self.assertFalse((fixture.release / "Lungfish-app-notary.zip").exists())
                self.assertNotEqual(
                    (fixture.release / "release-metadata.txt").read_text(
                        encoding="utf-8"
                    ),
                    "stale\n",
                )

    def test_corrective_higher_build_test_channel_drill_recovers_each_mutable_stage(self):
        # All release/tool/network surfaces are local doubles. This demonstrates
        # publication continuity, not installed Sparkle client or schema behavior.
        from scripts.tests.test_sparkle_build_number_gate import SparkleBuildNumberGateTests
        floor = SparkleBuildNumberGateTests()
        self.assertNotEqual(floor.run_gate("42", "42").returncode, 0)
        self.assertEqual(floor.run_gate("43", "42").returncode, 0)
        for failed_asset in ("sparkle-beta:appcast-beta.xml", "sparkle-beta:Lungfish-2026.8.1-arm64.md", "sparkle-alpha:appcast-alpha.xml"):
            with self.subTest(failed_asset=failed_asset):
                fixture = ReleaseBuilderFixture(self)
                try:
                    evidence = fixture.root / "installed-bad-build-42.json"
                    bad_bytes = b'{"installedBuild":42,"promotionPaused":true,"fixture":true}\n'
                    evidence.write_bytes(bad_bytes)
                    notes = fixture.repo / "docs/release-notes/2026.8.1.md"
                    notes.write_text(notes.read_text().replace("Channel: Stable", "Channel: Preview"))
                    fixture._git("add", str(notes))
                    fixture._git("commit", "-q", "-m", "local corrective Preview fixture")
                    fixture.prepare_remote_tag()
                    packaged = fixture.run("--package-only", "--channel", "preview", extra_env={"LUNGFISH_BUILD_NUMBER": "43"})
                    self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
                    candidate = fixture.release / "Lungfish Preview.app"
                    info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
                    self.assertEqual(info["CFBundleVersion"], "43")
                    self.assertTrue(info["SUFeedURL"].endswith("/sparkle-beta/appcast-beta.xml"))
                    resume = list(self._stable_resume_args(fixture))
                    resume[resume.index("stable")] = "preview"
                    failed = fixture.run(*resume, extra_env={"BUILDER_FAIL_MUTABLE_ASSET": failed_asset})
                    self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
                    self.assertIn("injected mutable interruption", failed.stderr)
                    receipt = fixture.release / "unsigned-candidate-receipt.json"
                    receipt_before = receipt.read_bytes()
                    before_retry = len(fixture.event_lines())
                    recovered = fixture.run(*resume, "--recover-existing-release")
                    self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
                    self.assertEqual(receipt.read_bytes(), receipt_before)
                    self.assertEqual(evidence.read_bytes(), bad_bytes)
                    state = json.loads(fixture.gh_state.read_text())["releases"]
                    primary = {a["name"]: a for a in state["sparkle-beta"]["assets"]}
                    legacy = {a["name"]: a for a in state["sparkle-alpha"]["assets"]}
                    self.assertIn("Lungfish-2026.8.1-arm64.md", primary)
                    self.assertEqual(primary["appcast-beta.xml"]["digest"], legacy["appcast-alpha.xml"]["digest"])
                    retry = fixture.event_lines()[before_retry:]
                    self.assertFalse(any(line.startswith(("xcodebuild:", "swift:")) or "notarytool submit" in line for line in retry))
                finally:
                    fixture.cleanup()

    def test_immutable_release_recovery_reuses_exact_dmg_without_signing_or_notarizing(
        self,
    ):
        self.fixture.prepare_remote_tag()
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        resume = (
            "--resume-candidate",
            str(self.fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "stable",
            "--github-release-tag",
            "v2026.8.1",
            "--sparkle-generate-appcast",
            str(self.fixture.bin / "generate_appcast"),
        )
        failed = self.fixture.run(
            *resume,
            extra_env={
                "BUILDER_FAIL_FEED_CREATE": "1",
                "BUILDER_NONDETERMINISTIC_DMG": "1",
            },
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        dmg = self.fixture.release / "Lungfish-2026.8.1-arm64.dmg"
        immutable_bytes = dmg.read_bytes()
        before_retry = len(self.fixture.event_lines())

        recovered = self.fixture.run(
            *resume,
            "--recover-existing-release",
            extra_env={"BUILDER_NONDETERMINISTIC_DMG": "1"},
        )

        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertEqual(dmg.read_bytes(), immutable_bytes)
        retry_events = self.fixture.event_lines()[before_retry:]
        self.assertFalse(
            any(line.startswith(("xcodebuild:", "swift:")) for line in retry_events)
        )
        self.assertFalse(
            any(
                line.startswith("codesign:") and " --sign " in f" {line} "
                for line in retry_events
            )
        )
        self.assertFalse(any("notarytool submit" in line for line in retry_events))
        self.assertFalse(
            any(line.startswith("hdiutil:create") for line in retry_events)
        )
        self.assertFalse(
            any(line.startswith("gh:release upload v2026.8.1") for line in retry_events)
        )
        all_events = self.fixture.event_lines()
        self.assertEqual(
            sum(line.startswith("gh:release create v2026.8.1") for line in all_events),
            1,
        )
        self.assertEqual(
            sum(
                line.startswith("gh:release upload sparkle-stable")
                and "appcast-stable.xml" in line
                for line in all_events
            ),
            1,
        )

    def test_immutable_release_recovery_downloads_and_extracts_missing_local_artifacts(
        self,
    ):
        self.fixture.prepare_remote_tag()
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        resume = (
            "--resume-candidate",
            str(self.fixture.release / "unsigned-candidate-receipt.json"),
            "--signing-identity",
            "Developer ID Application: Test (TEAMID)",
            "--team-id",
            "TEAMID",
            "--notary-profile",
            "fixture",
            "--channel",
            "stable",
            "--github-release-tag",
            "v2026.8.1",
            "--sparkle-generate-appcast",
            str(self.fixture.bin / "generate_appcast"),
        )
        failed = self.fixture.run(
            *resume,
            extra_env={"BUILDER_FAIL_FEED_CREATE": "1"},
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        dmg = self.fixture.release / "Lungfish-2026.8.1-arm64.dmg"
        immutable_bytes = dmg.read_bytes()
        fixture_contents = Path(f"{dmg}.fixture-app")
        remote_fixture_contents = self.fixture.root / "remote-dmg.fixture-app"
        shutil.copytree(fixture_contents, remote_fixture_contents, symlinks=True)
        dmg.unlink()
        shutil.rmtree(fixture_contents)
        shutil.rmtree(self.fixture.release / "signed")
        before_retry = len(self.fixture.event_lines())

        recovered = self.fixture.run(
            *resume,
            "--recover-existing-release",
            extra_env={"BUILDER_REMOTE_DMG_FIXTURE": str(remote_fixture_contents)},
        )

        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertEqual(dmg.read_bytes(), immutable_bytes)
        self.assertTrue(
            (
                self.fixture.release / "signed/Lungfish.app/Contents/MacOS/Lungfish"
            ).is_file()
        )
        retry_events = self.fixture.event_lines()[before_retry:]
        self.assertTrue(
            any(
                line.startswith("gh:release download v2026.8.1")
                for line in retry_events
            )
        )
        self.assertTrue(
            any(
                line.startswith("hdiutil:attach ") and " -readonly " in f" {line} "
                for line in retry_events
            )
        )
        self.assertFalse(
            any(line.startswith("hdiutil:create") for line in retry_events)
        )
        self.assertFalse(any("notarytool submit" in line for line in retry_events))
        self.assertFalse(
            any(
                line.startswith("codesign:") and " --sign " in f" {line} "
                for line in retry_events
            )
        )

    def test_recovery_rejects_signed_parent_symlink_before_feed_mutation(self):
        self.fixture.prepare_remote_tag()
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        resume = self._stable_resume_args()
        failed = self.fixture.run(*resume, extra_env={"BUILDER_FAIL_FEED_CREATE": "1"})
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        signed_parent = self.fixture.release / "signed"
        shutil.rmtree(signed_parent)
        outside = self.fixture.root / "outside-signed"
        outside.mkdir()
        sentinel = outside / "sentinel.txt"
        sentinel.write_text("unchanged\n", encoding="utf-8")
        signed_parent.symlink_to(outside, target_is_directory=True)
        before = len(self.fixture.event_lines())

        recovered = self.fixture.run(*resume, "--recover-existing-release")

        self.assertNotEqual(
            recovered.returncode, 0, recovered.stdout + recovered.stderr
        )
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged\n")
        self.assertFalse((outside / "Lungfish.app").exists())
        retry_events = self.fixture.event_lines()[before:]
        self.assertFalse(
            any(line.startswith("gh:release create sparkle-") for line in retry_events)
        )

    def test_recovery_rejects_signed_parent_case_alias(self):
        self.fixture.prepare_remote_tag()
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        resume = self._stable_resume_args()
        failed = self.fixture.run(*resume, extra_env={"BUILDER_FAIL_FEED_CREATE": "1"})
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        shutil.rmtree(self.fixture.release / "signed")
        alias = self.fixture.release / "Signed"
        alias.mkdir()
        if not (self.fixture.release / "signed").exists():
            self.skipTest("fixture filesystem is case-sensitive")

        recovered = self.fixture.run(*resume, "--recover-existing-release")

        self.assertNotEqual(
            recovered.returncode, 0, recovered.stdout + recovered.stderr
        )

    def test_recovery_rejects_hostile_path_hash_for_local_and_downloaded_dmg(self):
        for source in ("local", "downloaded"):
            with self.subTest(source=source):
                fixture = ReleaseBuilderFixture(self)
                self.addCleanup(fixture.cleanup)
                fixture.prepare_remote_tag()
                packaged = fixture.run("--package-only", "--channel", "stable")
                self.assertEqual(
                    packaged.returncode, 0, packaged.stdout + packaged.stderr
                )
                resume = self._stable_resume_args(fixture)
                failed = fixture.run(
                    *resume, extra_env={"BUILDER_FAIL_FEED_CREATE": "1"}
                )
                self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
                dmg = fixture.release / "Lungfish-2026.8.1-arm64.dmg"
                original = dmg.read_bytes()
                digest = hashlib.sha256(original).hexdigest()
                corrupt = bytes([original[0] ^ 1]) + original[1:]
                if source == "local":
                    dmg.write_bytes(corrupt)
                else:
                    state = json.loads(fixture.gh_state.read_text(encoding="utf-8"))
                    asset = state["releases"]["v2026.8.1"]["assets"][0]
                    Path(asset["storedPath"]).write_bytes(corrupt)
                    dmg.unlink()
                before = len(fixture.event_lines())

                recovered = fixture.run(
                    *resume,
                    "--recover-existing-release",
                    extra_env={"BUILDER_FORGED_SHA256": digest},
                )

                self.assertNotEqual(
                    recovered.returncode, 0, recovered.stdout + recovered.stderr
                )
                self.assertFalse(
                    any(
                        line.startswith("gh:release create sparkle-")
                        for line in fixture.event_lines()[before:]
                    )
                )

    def test_failed_recovery_detach_preserves_mounted_private_workspace(self):
        self.fixture.prepare_remote_tag()
        packaged = self.fixture.run("--package-only", "--channel", "stable")
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        resume = self._stable_resume_args()
        failed = self.fixture.run(*resume, extra_env={"BUILDER_FAIL_FEED_CREATE": "1"})
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        shutil.rmtree(self.fixture.release / "signed")
        before = len(self.fixture.event_lines())

        recovered = self.fixture.run(
            *resume,
            "--recover-existing-release",
            extra_env={"BUILDER_FAIL_DETACH": "1"},
        )

        self.assertNotEqual(
            recovered.returncode, 0, recovered.stdout + recovered.stderr
        )
        retained = list(self.fixture.release.glob(".immutable-recovery.*"))
        self.assertEqual(len(retained), 1)
        self.assertTrue((retained[0] / "mount/mounted-sentinel.txt").is_file())
        self.assertFalse(
            any(
                line.startswith("gh:release create sparkle-")
                for line in self.fixture.event_lines()[before:]
            )
        )

    def test_selected_upstream_remote_binds_scratch_tag_and_github_repository(self):
        self.fixture.prepare_remote_tag(
            remote_name="upstream",
            github_url="https://github.com/right/lungfish.git",
        )
        hostile = self.fixture.root / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(hostile)], check=True)
        hostile_url = "https://github.com/wrong/lungfish.git"
        self.fixture._git("config", f"url.{hostile}.insteadOf", hostile_url)
        self.fixture._git("remote", "set-url", "origin", hostile_url)
        remote_args = (
            "--remote",
            "upstream",
            "--github-repository",
            "right/lungfish",
        )

        packaged = self.fixture.run(
            "--package-only", "--channel", "stable", *remote_args
        )
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        completed = self.fixture.run(
            *self._stable_resume_args(),
            *remote_args,
            extra_env={
                "GH_HOST": "mirror.example.test",
                "BUILDER_EXPECTED_GH_REPO": "github.com/right/lungfish",
                "BUILDER_REQUIRE_EXPLICIT_GH_REPO": "1",
                "BUILDER_REJECT_GH_HOST": "1",
            },
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        events = "\n".join(self.fixture.event_lines())
        expected_prefix = "https://github.com/right/lungfish/releases/download/"
        self.assertIn(f"{expected_prefix}v2026.8.1/", events)
        self.assertIn(f"{expected_prefix}sparkle-stable/", events)
        self.assertNotIn("dhoconno/lungfish-genome-explorer", events)
        self.assertNotIn("mirror.example.test", events)

    def test_remote_repository_case_change_preserves_package_recovery_identity(self):
        self.fixture.prepare_remote_tag(
            remote_name="upstream",
            github_url="https://github.com/Right/LungFish.git",
        )
        remote_args = (
            "--remote",
            "upstream",
            "--github-repository",
            "right/lungfish",
        )
        packaged = self.fixture.run(
            "--package-only", "--channel", "stable", *remote_args
        )
        self.assertEqual(packaged.returncode, 0, packaged.stdout + packaged.stderr)
        failed = self.fixture.run(
            *self._stable_resume_args(),
            *remote_args,
            extra_env={"BUILDER_FAIL_FEED_CREATE": "1"},
        )
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)

        self.fixture._git(
            "remote",
            "set-url",
            "upstream",
            "https://github.com/right/lungfish.git",
        )
        recovered = self.fixture.run(
            *self._stable_resume_args(),
            *remote_args,
            "--recover-existing-release",
            extra_env={
                "BUILDER_EXPECTED_GH_REPO": "github.com/right/lungfish",
                "BUILDER_REQUIRE_EXPLICIT_GH_REPO": "1",
            },
        )
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)

    def test_production_credentialed_apple_tools_are_canonical(self):
        source = (ROOT / "scripts/release/build-notarized-dmg.sh").read_text(
            encoding="utf-8"
        )
        for tool in ("codesign", "ditto", "hdiutil", "xcrun"):
            with self.subTest(tool=tool):
                self.assertIn(f"/usr/bin/{tool}", source)

    def test_raw_reuse_flags_fail_with_receipt_migration_guidance(self):
        for flag in ("--reuse-archive", "--reuse-built-cli"):
            with self.subTest(flag=flag):
                result = self.fixture.run("--package-only", flag)
                self.assertEqual(result.returncode, 64)
                self.assertIn("--resume-candidate", result.stderr)


if __name__ == "__main__":
    unittest.main()
