import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / ".ci-python" / "bin" / "python"


class ReleaseBuilderFixture:
    def __init__(self, case: unittest.TestCase):
        self.case = case
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        self.events = self.root / "events.log"
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

    def cleanup(self):
        self.temporary.cleanup()

    @property
    def builder(self):
        return self.repo / "scripts" / "release" / "build-notarized-dmg.sh"

    def _copy_repository_inputs(self):
        paths = (
            "scripts/release/build-notarized-dmg.sh",
            "scripts/release/release_contract.py",
            "scripts/release/release_cache_security.py",
            "scripts/release/release_target_security.py",
            "scripts/release/release-candidate-receipt.py",
            "scripts/check-package-resolved-consistency.sh",
            "config/release-contract.json",
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
        self._write(self.repo / "Package.resolved", '{"pins":[],"version":2}\n')
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
        real_receipt = release_dir / "release-candidate-receipt-real.py"
        (release_dir / "release-candidate-receipt.py").replace(real_receipt)
        self._write_executable(
            release_dir / "release-candidate-receipt.py",
            r"""
            #!/bin/bash
            set -eu
            printf 'receipt:%s:%s\n' "$1" "$*" >>"$BUILDER_EVENTS"
            "$BUILDER_PYTHON" "$(dirname "$0")/release-candidate-receipt-real.py" "$@"
            printf 'receipt:%s:ok\n' "$1" >>"$BUILDER_EVENTS"
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
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --scratch-path) scratch="$2"; shift 2 ;;
                    --release-dir) release="$2"; shift 2 ;;
                    --archive-path) archive="$2"; shift 2 ;;
                    --derived-data-path) derived="$2"; shift 2 ;;
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
                    --derived-data-path "$derived"
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
            self.bin / "xcodebuild",
            r"""
            #!/bin/bash
            set -eu
            if [ "${1:-}" = -version ]; then
                printf 'Xcode 26.4.1\nBuild version 17F90\n'
                exit 0
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
                echo '26.0'
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
            """,
            "gh": 'printf \'gh:%s\\n\' "$*" >>"$BUILDER_EVENTS"\nexit 0\n',
            "security": 'printf \'security:%s\\n\' "$*" >>"$BUILDER_EVENTS"\nexit 0\n',
            "file": "echo 'Mach-O 64-bit executable arm64'\n",
            "ditto": 'printf \'ditto:%s\\n\' "$*" >>"$BUILDER_EVENTS"\nif [ "${1:-}" = -c ]; then : >"${@: -1}"; else cp -R "$1" "$2"; fi\n',
            "hdiutil": 'printf \'hdiutil:%s\\n\' "$*" >>"$BUILDER_EVENTS"\ntarget="${@: -1}"\n[ ! -e "$target" ] || exit 73\n: >"$target"\n',
        }.items():
            self._write_executable(self.bin / name, f"#!/bin/bash\nset -eu\n{body}")

    def _adapt_canonical_tools_for_fixture(self):
        """Redirect only this disposable builder copy to explicit test doubles."""
        source = self.builder.read_text(encoding="utf-8")
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
                "LUNGFISH_RELEASE_SCRATCH_ROOT": str(self.scratch_root),
                "LUNGFISH_SPARKLE_PUBLIC_ED_KEY": "public-test-key",
                "BUILDER_DOCTOR_FAIL": "1" if doctor_fail else "0",
                "BUILDER_CODESIGN_COUNT": str(self.root / "codesign-count"),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        if extra_env:
            environment.update(extra_env)
        command = [
            "/bin/bash",
            str(self.builder),
            "--release-dir",
            str(release or self.release),
            "--archive-path",
            str(archive or self.archive),
            "--derived-data-path",
            str(derived or self.derived),
            *arguments,
        ]
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
                "--scratch-path",
                str(
                    json.loads(
                        (self.release / "unsigned-candidate-receipt.json").read_text()
                    )["build"]["scratchPath"]
                ),
            ],
            cwd=self.repo,
            env={
                **os.environ,
                "PATH": f"{self.bin}:{os.environ['PATH']}",
                "BUILDER_EVENTS": str(self.events),
                "BUILDER_CODESIGN_COUNT": str(self.root / "codesign-count"),
                "PYTHONDONTWRITEBYTECODE": "1",
            },
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

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

    def test_package_only_needs_no_credentials_and_stops_before_private_or_remote_tools(
        self,
    ):
        result = self.fixture.run(
            "--package-only",
            "--channel",
            "preview",
            extra_env={
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
        self.assertEqual(info["CFBundleIdentifier"], "com.lungfish.browser")
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
        self.assertTrue(Path(scratch).is_absolute())
        self.assertTrue(scratch.startswith(str(self.fixture.scratch_root) + os.sep))
        self.assertIn(f"-Xlinker -oso_prefix -Xlinker {scratch}/", swift)
        smoke = [line for line in events if line.startswith("smoke:")]
        self.assertEqual(
            smoke, [f"smoke:portability:{scratch}", f"smoke:complete:{scratch}"]
        )
        receipt = next(line for line in events if line.startswith("receipt:create:"))
        self.assertIn(f"--scratch-path {scratch}", receipt)

    def test_xcode_archive_cannot_resolve_or_embed_derived_data_path(self):
        result = self.fixture.run("--package-only", "--channel", "stable")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = next(
            line
            for line in self.fixture.event_lines()
            if line.startswith("xcodebuild:")
        )
        self.assertIn("-disableAutomaticPackageResolution", archive)
        self.assertIn(
            f"-ffile-prefix-map={self.fixture.derived}=/xcode-derived", archive
        )
        self.assertIn(
            f"-fdebug-prefix-map={self.fixture.derived}=/xcode-derived", archive
        )
        derived_alias = str(self.fixture.derived).removeprefix("/private")
        if derived_alias != str(self.fixture.derived):
            self.assertIn(f"-ffile-prefix-map={derived_alias}=/xcode-derived", archive)
            self.assertIn(f"-fdebug-prefix-map={derived_alias}=/xcode-derived", archive)

    def test_lockfile_divergence_fails_without_repair_or_archive(self):
        xcode_lock = (
            self.fixture.repo
            / "Lungfish.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        xcode_lock.parent.mkdir(parents=True)
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
                "repositoryKey": Path(receipt["build"]["scratchPath"]).parent.name,
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
                "repositoryKey": Path(receipt["build"]["scratchPath"]).parent.name,
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
            "repositoryKey": Path(receipt["build"]["scratchPath"]).parent.name,
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
        codesign = events.index(
            next(
                line
                for line in events
                if line.startswith("codesign:")
                and "--sign - --timestamp=none" not in line
            )
        )
        self.assertTrue(adhoc_seals)
        self.assertLess(max(adhoc_seals), complete)
        self.assertLess(complete, receipt_create)
        self.assertLess(complete, receipt)
        self.assertLess(receipt, codesign)
        self.assertEqual(sum(line.startswith("xcodebuild:") for line in events), 1)
        self.assertEqual(sum(line.startswith("swift:") for line in events), 1)

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
