#!/usr/bin/env python3
"""Semantically validate every supported Lungfish release authority."""

from __future__ import annotations

import argparse
import ast
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys


REQUIRED_FILES = (
    "config/release-contract.json",
    "scripts/release/release.py",
    "scripts/release/build-notarized-dmg.sh",
    "scripts/release/check-sparkle-build-number.py",
    "scripts/release/run-nightly-prerelease.sh",
    "scripts/release/nightly_prerelease_release.py",
    "scripts/build-app.sh",
    "docs/release/sparkle-updates.md",
    "docs/release/NEXT-RELEASE-HANDOFF.md",
    ".codex/agents/release-agent.md",
    "agents/definitions/codex/release-agent.md",
    "SKILLS.md",
    ".github/workflows/ci.yml",
    "scripts/tests/test_sparkle_release_packaging.py",
    "scripts/tests/test_release_smoke.py",
    "scripts/full-suite-gate.sh",
    "scripts/testing/run-macos-xcui.sh",
    "scripts/tests/test_full_suite_gate_tiers.py",
)

PUBLIC_COMMANDS = ("debug", "doctor", "package", "publish")
PUBLIC_COMMAND_LINES = (
    "python3 scripts/release/release.py debug",
    "python3 scripts/release/release.py doctor [--profile PATH]",
    "python3 scripts/release/release.py package preview|stable",
    "python3 scripts/release/release.py publish preview|stable [--profile PATH]",
)
PRIMARY_AUTHORITIES = (
    ".codex/skills/releasing-lungfish/SKILL.md",
    ".codex/agents/release-agent.md",
    "agents/definitions/codex/release-agent.md",
    "docs/release/sparkle-updates.md",
    "docs/release/NEXT-RELEASE-HANDOFF.md",
    "SKILLS.md",
    "README.md",
)
CHANNEL_AUTHORITIES = (
    ".codex/skills/releasing-lungfish/SKILL.md",
    ".codex/agents/release-agent.md",
    "agents/definitions/codex/release-agent.md",
    "docs/release/sparkle-updates.md",
    "docs/release/NEXT-RELEASE-HANDOFF.md",
)

DEBUG_AUTHORITIES = (
    ".codex/skills/releasing-lungfish/SKILL.md",
    "SKILLS.md",
    "README.md",
)
HELPER_PATH = re.compile(
    r"(?:\./)?scripts/(?:"
    r"build-app\.sh|smoke-test-debug-app\.sh|full-suite-gate\.sh|"
    r"release/build-notarized-dmg\.sh)",
    re.IGNORECASE,
)

SECRET_PATTERNS = (
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"),
    re.compile(r"(?i)(?:token|password|private[_ -]?key)\s*[:=]\s*['\"]?[A-Za-z0-9+/=_-]{24,}"),
    re.compile(r"-----BEGIN (?:OPENSSH|RSA|EC|PRIVATE) PRIVATE KEY-----"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--skill-root", type=Path)
    return parser.parse_args()


def read_text(path: Path, errors: list[str], label: str) -> str:
    if not path.is_file():
        errors.append(f"Missing required repository file: {label}")
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def markdown_section(contents: str, title: str) -> str | None:
    headings = list(
        re.finditer(
            r"^(?P<marks>#{1,6})\s+(?P<title>[^\n#]+?)\s*#*\s*$",
            contents,
            re.MULTILINE,
        )
    )
    matches = [
        heading
        for heading in headings
        if heading.group("title").strip().casefold() == title.casefold()
    ]
    if len(matches) != 1:
        return None
    start_heading = matches[0]
    level = len(start_heading.group("marks"))
    end = next(
        (
            heading.start()
            for heading in headings
            if heading.start() > start_heading.start()
            and len(heading.group("marks")) <= level
        ),
        len(contents),
    )
    return contents[start_heading.start():end]


def exposes_helper_command(contents: str) -> bool:
    command_prefix = re.compile(r"^(?:\$\s*)?(?:bash|sh|python3)\s+", re.IGNORECASE)
    direct_prefix = re.compile(r"^(?:\$\s*)?(?:\./)?scripts/", re.IGNORECASE)
    candidates = re.findall(r"`([^`\n]+)`", contents)
    candidates.extend(
        line.strip()
        for block in re.findall(r"```[^\n]*\n(.*?)```", contents, re.DOTALL)
        for line in block.splitlines()
    )
    candidates.extend(line.strip() for line in contents.splitlines())
    for candidate in candidates:
        if HELPER_PATH.search(candidate) and (
            command_prefix.search(candidate) or direct_prefix.search(candidate)
        ):
            return True
    return False


def load_debug_plan(
    repo_root: Path, errors: list[str]
) -> tuple[list[list[str]], Path] | None:
    release_path = repo_root / "scripts/release/release.py"
    module_name = "_lungfish_release_authority_validator"
    spec = importlib.util.spec_from_file_location(module_name, release_path)
    if spec is None or spec.loader is None:
        errors.append("Release coordinator module could not be loaded for Debug-plan validation")
        return None
    module = importlib.util.module_from_spec(spec)
    release_dir = str(release_path.parent)
    sys.path.insert(0, release_dir)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
        commands, app = module.debug_plan(repo_root)
    except Exception as error:  # noqa: BLE001 - validator reports closed boundary
        errors.append(f"Release coordinator Debug plan could not be evaluated: {error}")
        return None
    finally:
        sys.modules.pop(module_name, None)
        sys.path.remove(release_dir)
    return commands, app


def validate_debug_plan(
    plan: tuple[list[list[str]], Path] | None,
    contract: dict[str, object],
    repo_root: Path,
    errors: list[str],
) -> str:
    if plan is None:
        return ""
    commands, app = plan
    profiles = contract.get("buildProfiles", {})
    debug = profiles.get("debug", {}) if isinstance(profiles, dict) else {}
    filename = debug.get("appBundleFilename") if isinstance(debug, dict) else None
    expected_app = repo_root / "build/Debug" / str(filename)
    valid = (
        len(commands) == 3
        and commands[0] == [
            "swift",
            "test",
            "--filter",
            "ReleaseBuildConfigurationTests",
        ]
        and commands[1] == [
            "/bin/bash",
            str(repo_root / "scripts/build-app.sh"),
            "--debug",
        ]
        and commands[2] == [
            "/bin/bash",
            str(repo_root / "scripts/smoke-test-debug-app.sh"),
            str(expected_app),
            "--compiling-build-dir",
            str(repo_root / ".build"),
        ]
        and app == expected_app
    )
    if not valid:
        errors.append(
            "release.py Debug plan must run the focused static gate, internal Debug assembly, then relocation smoke"
        )
        return ""
    return commands[0][-1]


def validate_debug_authorities(
    texts: dict[str, str],
    contract: dict[str, object],
    static_gate: str,
    errors: list[str],
) -> None:
    profiles = contract.get("buildProfiles", {})
    debug = profiles.get("debug", {}) if isinstance(profiles, dict) else {}
    if not isinstance(debug, dict):
        errors.append("Release contract is missing the Debug build profile")
        return
    expected_markers = (
        f"build/Debug/{debug.get('appBundleFilename', '')}",
        str(debug.get("displayName", "")),
        str(debug.get("bundleName", "")),
        str(debug.get("bundleIdentifier", "")),
        str(debug.get("releaseChannel", "")),
        static_gate,
    )
    contradiction_patterns = (
        r"(?:carries\s+no\s+signature|signature\s*:\s*none)",
        r"debug[^\n.]{0,120}(?:omit|without)[^\n.]{0,40}ad[ -]?hoc",
        r"debug[^\n.]{0,160}(?:not\s+(?:all\s+)?(?:carried|contained)|load[^\n.]*source checkout)",
        r"(?:debug|portability)[^\n.]{0,120}(?:not self-contained|depends on (?:the )?checkout)",
        r"resources?[^\n.]{0,100}(?:load|adjacent)[^\n.]*\.build",
        r"(?:debug|distribution)[^\n.]{0,120}(?:developer id signed and notarized|is notarized)",
        r"(?:debug[^\n.]{0,100})?(?:wrapper|app path)\s*:[^\n]*`?(?:build/Debug/)?Lungfish\.app`?",
        r"debug[^\n.]{0,120}wrapper[^\n.]*Lungfish\.app",
        r"(?:debug[^\n.]{0,100})?(?:visible (?:application )?title|display name)\s*(?:is|:)[^\n]*`?Lungfish(?: Debug)?`?(?:[.\n]|$)",
    )
    for relative in DEBUG_AUTHORITIES:
        text = markdown_section(texts[relative], "Debug build")
        if text is None:
            errors.append(f"{relative} must contain exactly one semantic Debug build section")
            continue
        normalized = " ".join(text.split())
        lowered = normalized.lower()
        for marker in expected_markers:
            if marker and marker.lower() not in lowered:
                errors.append(
                    f"{relative} omits Debug contract/plan semantic value: {marker}"
                )
        required_semantics = (
            (r"ad[ -]?hoc[ -]?signed", "locally ad-hoc signed"),
            (r"(?:not|never) developer id signed", "not Developer ID signed"),
            (r"(?:not|never|non-)[^.;]{0,80}notarized", "not notarized"),
            (r"self-contained", "self-contained"),
            (r"relocat", "relocatable"),
            (r"(?:no|without)[^.;]{0,80}checkout", "no checkout dependency"),
            (r"(?:no|without)[^.;]{0,100}\.build", "no .build dependency"),
            (r"(?:not a release|non-release)", "non-release profile"),
            (r"(?:no|without)[^.;]{0,80}updater", "no updater path"),
            (r"(?:no|without)[^.;]{0,80}publication", "no publication path"),
        )
        for pattern, label in required_semantics:
            if re.search(pattern, lowered) is None:
                errors.append(f"{relative} omits Debug semantic: {label}")
        for pattern in contradiction_patterns:
            if re.search(pattern, text, re.IGNORECASE):
                errors.append(f"{relative} contains a contradictory Debug claim")
                break
        if re.search(r"(?:run the unit tier|after the unit tier passes|--tier\s+unit)", text, re.IGNORECASE):
            errors.append(
                f"{relative} falsely claims release.py debug runs the whole unit tier"
            )


def validate_contract(repo_root: Path, errors: list[str]) -> dict[str, object]:
    path = repo_root / "config/release-contract.json"
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"Release contract could not be parsed: {error}")
        return {}
    expected_channels = {
        "preview": {
            "appBundleFilename": "Lungfish Preview.app",
            "displayName": "Lungfish Genome Explorer Preview",
            "bundleName": "Lungfish Preview",
            "bundleIdentifier": "com.lungfish.browser",
            "releaseChannel": "preview",
            "sparkleRelease": "sparkle-beta",
            "appcastFilename": "appcast-beta.xml",
            "githubPrerelease": True,
            "dmgVolumeName": "Lungfish Preview",
            "legacyBridgeRelease": "sparkle-alpha",
            "legacyBridgeAppcastFilename": "appcast-alpha.xml",
        },
        "stable": {
            "appBundleFilename": "Lungfish.app",
            "displayName": "Lungfish Genome Explorer",
            "bundleName": "Lungfish",
            "bundleIdentifier": "com.lungfish.browser",
            "releaseChannel": "stable",
            "sparkleRelease": "sparkle-stable",
            "appcastFilename": "appcast-stable.xml",
            "githubPrerelease": False,
            "dmgVolumeName": "Lungfish",
            "legacyBridgeRelease": "",
            "legacyBridgeAppcastFilename": "",
        },
    }
    if contract.get("channels") != expected_channels:
        errors.append("Release contract channel wrapper/feed/bundle identity differs from canonical Preview/Stable semantics")
    expected_debug = {
        "appBundleFilename": "Lungfish Debug.app",
        "displayName": "Lungfish Genome Explorer Debug",
        "bundleName": "Lungfish Debug",
        "bundleIdentifier": "com.lungfish.browser.debug",
        "releaseChannel": "debug",
        "isRelease": False,
        "publishable": False,
        "updaterEnabled": False,
    }
    if contract.get("buildProfiles") != {"debug": expected_debug}:
        errors.append(
            "Release contract Debug identity/capabilities differ from the canonical non-release profile"
        )
    toolchain = contract.get("toolchain")
    expected_toolchain = {
        "xcodeMinimum": "26.4.1",
        "xcodeMaximumExclusive": "27.0",
        "swiftMinimum": "6.2",
        "swiftMaximumExclusive": "7.0",
        "sdkMajor": 26,
        "deploymentTarget": "26.0",
        "architecture": "arm64",
        "minimumFreeDiskGiB": 20,
    }
    if toolchain != expected_toolchain:
        errors.append("Release contract toolchain must be Xcode >=26.4.1,<27, Swift >=6.2,<7, SDK 26, deployment 26.0, arm64, and 20 GiB")
    return contract


def command_help(script: Path, arguments: list[str], errors: list[str]) -> str:
    result = subprocess.run(
        [sys.executable, str(script), *arguments],
        cwd=script.parents[2],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        errors.append(f"Release front door help failed for {' '.join(arguments)}: {result.stderr.strip() or result.returncode}")
        return ""
    return result.stdout + result.stderr


def validate_frontdoor(repo_root: Path, errors: list[str]) -> None:
    script = repo_root / "scripts/release/release.py"
    if not script.is_file():
        return
    top = command_help(script, ["--help"], errors)
    match = re.search(r"usage:\s+release\.py.*?\{([^}]+)\}", top, re.DOTALL)
    commands = set(match.group(1).split(",")) if match else set()
    if commands != set(PUBLIC_COMMANDS):
        errors.append(f"Release front door command set must be exactly {', '.join(PUBLIC_COMMANDS)}")
    helps = {name: command_help(script, [name, "--help"], errors) for name in PUBLIC_COMMANDS}
    if "{preview,stable}" not in helps["package"] or "--profile" in helps["package"]:
        errors.append("Package front door must accept only preview|stable plus --repo and remain profile-free")
    if "{preview,stable}" not in helps["publish"] or "--profile" not in helps["publish"]:
        errors.append("Publish front door must accept preview|stable and optional --profile")
    if "--profile" not in helps["doctor"]:
        errors.append("Doctor front door must expose optional --profile")
    combined = "\n".join([top, *helps.values()])
    for retired in (
        "--prepare", "--resume", "--status", "--signing-identity",
        "--notary-profile", "--sparkle-ed-key-file", "--prune-prereleases",
        "--receipt", "--reuse-archive", "--reuse-built-cli",
    ):
        if retired in combined:
            errors.append(f"Release front door still exposes retired public option {retired}")


def validate_authority_texts(
    repo_root: Path,
    skill_root: Path,
    contract: dict[str, object],
    static_gate: str,
    errors: list[str],
) -> None:
    texts: dict[str, str] = {}
    for relative in PRIMARY_AUTHORITIES:
        path = skill_root / "SKILL.md" if relative.startswith(".codex/skills/") else repo_root / relative
        texts[relative] = read_text(path, errors, relative)
    for relative, text in texts.items():
        normalized = " ".join(text.split())
        if exposes_helper_command(text):
            errors.append(
                f"{relative} exposes a low-level helper command outside the release.py front door"
            )
        for command in PUBLIC_COMMAND_LINES:
            if command not in text:
                errors.append(f"{relative} does not document the exact four-command release front door: {command}")
        if re.search(r"release\.py[^\n`]*(?:--prepare|--resume|\bstatus\b)", text, re.IGNORECASE):
            errors.append(f"{relative} documents a retired public --prepare/--resume/status interface")
        if re.search(r"(?:^|\n)\s*(?:source|\.)\s+[^\n]*release\.env", text, re.IGNORECASE):
            errors.append(f"{relative} instructs operators to source retired release.env")
        if re.search(r"\b(?:run|use|invoke|publish with)\b[^\n]{0,100}build-notarized-dmg\.sh", text, re.IGNORECASE):
            errors.append(f"{relative} bypasses the supported release front door with a direct builder instruction")
        for sentence in re.split(r"[.\n]", normalized):
            if re.search(r"(?:automatically|implicitly|by default)[^.;]{0,80}prun", sentence, re.IGNORECASE) and not re.search(r"\b(?:no|never|not|neither)\b", sentence, re.IGNORECASE):
                errors.append(f"{relative} claims release publication performs implicit prune behavior")
                break
        if re.search(r"(?:exactly|requires?|pin(?:ned)? to|select)\s+Xcode\s+26\.4\.1", text, re.IGNORECASE):
            errors.append(f"{relative} incorrectly exact-pins Xcode instead of using the supported range")

    skill_text = texts[".codex/skills/releasing-lungfish/SKILL.md"]
    for marker in ("YYYY.M.PATCH", "docs/release-notes/<version>.md"):
        if marker not in skill_text:
            errors.append(f"Release skill is missing required CalVer policy: {marker}")

    for relative in CHANNEL_AUTHORITIES:
        text = texts[relative]
        normalized = " ".join(text.split())
        for marker, label in (
            ("Lungfish Preview.app", "Preview wrapper"),
            ("Lungfish.app", "Stable wrapper"),
            ("Lungfish Genome Explorer Preview", "Preview display name"),
            ("Lungfish Genome Explorer", "Stable display name"),
            ("sparkle-beta", "Preview feed"),
            ("appcast-beta.xml", "Preview appcast"),
            ("sparkle-stable", "Stable feed"),
            ("appcast-stable.xml", "Stable appcast"),
            ("sparkle-alpha", "legacy Alpha bridge"),
            ("appcast-alpha.xml", "legacy Alpha appcast"),
            ("com.lungfish.browser", "shared bundle identifier"),
            ("side-by-side", "side-by-side installation"),
            ("not fully independent", "shared bundle identifier caveat"),
            ("simultaneous execution is not promised", "simultaneous execution caveat"),
        ):
            if marker.lower() not in normalized.lower():
                errors.append(f"{relative} omits canonical {label} semantics")
        if re.search(r"(?:both|preview and stable)[^\n.]{0,120}Lungfish\.app[^\n.]{0,120}(?:replace|cannot|no side-by-side)", text, re.IGNORECASE):
            errors.append(f"{relative} contains the old same-name replacement claim; Preview and Stable are side-by-side by wrapper path")
        if "Launch Services/defaults/TCC/state are fully independent" in normalized:
            errors.append(f"{relative} falsely claims the shared bundle identifier makes state fully independent")

    agent = texts[".codex/agents/release-agent.md"]
    mirror = texts["agents/definitions/codex/release-agent.md"]
    if agent != mirror:
        errors.append("Release agent copies must be byte-identical")
    validate_debug_authorities(texts, contract, static_gate, errors)


def workflow_job(text: str, name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    return match.group("body") if match else ""


def validate_nightly_command_ast(tree: ast.AST, errors: list[str]) -> None:
    functions = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef) and node.name == "run_common_coordinator"
    ]
    if len(functions) != 1:
        errors.append("Nightly coordinator must define one run_common_coordinator transaction")
        return
    function = functions[0]
    parents = {
        child: parent
        for parent in ast.walk(function)
        for child in ast.iter_child_nodes(parent)
    }
    release_calls: list[tuple[str, ast.Call, list[str]]] = []
    for node in ast.walk(function):
        if not isinstance(node, ast.Call) or not node.args:
            continue
        if not isinstance(node.func, ast.Name) or node.func.id != "run":
            continue
        command = node.args[0]
        if not isinstance(command, (ast.List, ast.Tuple)):
            continue
        command_dump = ast.dump(command, include_attributes=False)
        if "release_coordinator" not in command_dump:
            continue
        tokens = [
            element.value
            for element in command.elts
            if isinstance(element, ast.Constant) and isinstance(element.value, str)
        ]
        public = [token for token in tokens if token in {"package", "publish"}]
        if len(public) == 1:
            release_calls.append((public[0], node, tokens))

    package_calls = [item for item in release_calls if item[0] == "package"]
    publish_calls = [item for item in release_calls if item[0] == "publish"]
    valid = len(package_calls) == 1 and len(publish_calls) == 1
    if valid:
        _, package_call, package_tokens = package_calls[0]
        _, publish_call, publish_tokens = publish_calls[0]
        valid = (
            package_call.lineno < publish_call.lineno
            and package_tokens[:2] == ["package", "preview"]
            and "--profile" not in package_tokens
            and publish_tokens[:3] == ["publish", "preview", "--profile"]
        )
        ancestor = parents.get(package_call)
        while ancestor is not None and not isinstance(ancestor, ast.If):
            ancestor = parents.get(ancestor)
        valid = valid and isinstance(ancestor, ast.If) and ast.unparse(ancestor.test) == "resume_receipt is None"
    if not valid:
        errors.append(
            "Nightly coordinator must call release.py package then publish for preview; recovery skips only package"
        )


def validate_ci_and_nightly(repo_root: Path, errors: list[str]) -> None:
    ci_path = repo_root / ".github/workflows/ci.yml"
    ci = read_text(ci_path, errors, ".github/workflows/ci.yml")
    package = workflow_job(ci, "package-smoke")
    if not package:
        errors.append("CI is missing the package-smoke job")
    else:
        if "matrix:\n        channel: [preview, stable]" not in package:
            errors.append("CI package-smoke must parse both contract channels")
        if "python3 scripts/release/release.py package ${{ matrix.channel }}" not in package:
            errors.append("CI package-smoke must use the supported release.py package front door")
        if "build-notarized-dmg.sh" in package or "--package-only" in package:
            errors.append("CI bypasses the supported front door with a direct builder package path")
        for forbidden in ("--profile", "--signing-identity", "--notary-profile", "gh release"):
            if forbidden in package:
                errors.append(f"CI credentialless package-smoke contains forbidden publication input {forbidden}")
    if "tags:\n      - 'v*'" not in ci or "release-context:" not in ci:
        errors.append("CI must parse release context and gate the exact v* tagged SHA")
    if "release.py package" in ci and "scripts/release/release_xcode.py --shell" not in ci:
        errors.append("CI must resolve the supported Xcode range through release_xcode.py")
    if re.search(r"Xcode_26\.4\.1|Select Xcode 26\.4\.1|xcode-select\s+-s", ci, re.IGNORECASE):
        errors.append("CI exact-pins Xcode 26.4.1 instead of using the contract range and shared resolver")
    if re.search(r"CI requires exactly Xcode 26\.4\.1", ci, re.IGNORECASE):
        errors.append("CI contains an exact Xcode pin contradiction")

    wrapper = read_text(
        repo_root / "scripts/release/run-nightly-prerelease.sh",
        errors,
        "scripts/release/run-nightly-prerelease.sh",
    )
    if "release_xcode.py" not in wrapper or "release.json" not in wrapper:
        errors.append("Nightly wrapper must select supported Xcode and the strict JSON profile")
    if "release.env" in wrapper or re.search(r"(?:^|\n)\s*(?:source|\.)\s+", wrapper):
        errors.append("Nightly wrapper must not source release.env or another shell profile")
    if "build-notarized-dmg.sh" in wrapper:
        errors.append("Nightly wrapper bypasses the supported release front door")

    nightly_path = repo_root / "scripts/release/nightly_prerelease_release.py"
    nightly = read_text(nightly_path, errors, "scripts/release/nightly_prerelease_release.py")
    try:
        tree = ast.parse(nightly)
    except SyntaxError as error:
        errors.append(f"Nightly coordinator Python could not be parsed: {error}")
        tree = ast.parse("")
    validate_nightly_command_ast(tree, errors)
    if "build-notarized-dmg.sh" in nightly:
        errors.append("Nightly coordinator contains a direct builder bypass")
    if "release.env" in nightly or "prune-github-prereleases.py" in nightly:
        errors.append("Nightly coordinator must not source shell credentials or prune implicitly")


def main() -> int:
    args = parse_args()
    default_skill = Path(__file__).resolve().parents[1]
    skill_root = (args.skill_root or default_skill).resolve()
    repo_root = (args.repo_root or default_skill.parents[2]).resolve()
    errors: list[str] = []

    for relative in REQUIRED_FILES:
        if not (repo_root / relative).is_file():
            errors.append(f"Missing required repository file: {relative}")

    contract = validate_contract(repo_root, errors)
    debug_plan = load_debug_plan(repo_root, errors)
    static_gate = validate_debug_plan(debug_plan, contract, repo_root, errors)
    validate_frontdoor(repo_root, errors)
    validate_authority_texts(
        repo_root,
        skill_root,
        contract,
        static_gate,
        errors,
    )
    validate_ci_and_nightly(repo_root, errors)

    for path in skill_root.rglob("*") if skill_root.is_dir() else ():
        if not path.is_file() or path.suffix in {".pyc", ".png", ".jpg"}:
            continue
        contents = path.read_text(errors="replace")
        if any(pattern.search(contents) for pattern in SECRET_PATTERNS):
            errors.append(f"Secret-like content found in skill file: {path.relative_to(skill_root)}")

    if errors:
        print("Lungfish release skill validation failed:", file=sys.stderr)
        for error in dict.fromkeys(errors):
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Lungfish release skill is compatible with {repo_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
