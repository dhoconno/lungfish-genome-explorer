#!/usr/bin/env python3
"""Generate THIRD-PARTY-NOTICES from sources of truth.

Replaces the old hand-maintained THIRD-PARTY-NOTICES with a file assembled
from three inputs, each a real artifact rather than a human's memory:

1. ``Package.resolved`` -- every SwiftPM dependency actually pinned into the
   app. License text is read from ``.build/checkouts/<name>/LICENSE*`` when
   the package graph has been resolved locally. When it has not (a fresh
   checkout, or CI before a build), the checked-in
   ``scripts/release/notices-overrides.json`` supplies the SPDX id, a
   canonical license URL, and a copyright line instead. A dependency that is
   test-only (never linked into a shipped target) can be marked
   ``"shipped": false`` in the overrides file and is listed separately.
2. ``Sources/LungfishWorkflow/Resources/ManagedTools/bundled-payloads.json``
   -- binaries actually embedded in the app bundle that are not SwiftPM
   dependencies: micromamba (bootstrap) and the Apple Containerization
   kernel/rootfs. The kernel is GPL-2.0 and needs a license notice plus a
   written source offer; both are carried in that manifest so a human only
   edits one place.
3. The managed conda tool list in ``third-party-tools-lock.json`` (tools and
   packTools) -- these are NOT bundled; they are installed on demand into
   ``~/.lungfish``. They get an informational listing, not a bundled-notice
   entry. The table itself is rendered by ``scripts/deps/bump.py`` between
   ``<!-- managed-tools:begin -->`` / ``<!-- managed-tools:end -->`` markers;
   this script reuses that renderer so the format never drifts between the
   two tools.

If a SwiftPM dependency's license text cannot be found in ``.build/checkouts``
and it has no entry in the overrides file, this script FAILS with a clear
message naming the dependency, rather than silently omitting it.

Every URL in the output is pinned (REL-03, D16). A license or source link
that follows a moving branch (``main``, ``master``, ``dev`` and so on) can
change or vanish after a release ships, so the notice would no longer
describe the shipped bytes. Manifests therefore write placeholders that this
script expands from ``Package.resolved``:

- ``{revision}`` in an override's ``licenseUrl`` becomes that dependency's
  pinned commit;
- ``{pin:<identity>}`` anywhere in ``bundled-payloads.json`` becomes the
  pinned commit of the named SwiftPM dependency.

Generation fails if any branch-following GitHub URL survives expansion.
An override may also carry ``licenseElection`` text, which is printed
verbatim for dual-licensed dependencies (zstd: BSD elected over GPL-2.0).

Usage:
    scripts/release/generate-notices.py [--check] [--out PATH]

``--check`` writes to a temp file and diffs against the committed
THIRD-PARTY-NOTICES instead of overwriting it; used as a release gate to
catch drift between the manifest and the generated file.

Stdlib only; no third-party imports.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "deps"))

import bump  # noqa: E402  (reuses render_notices_table for the managed-tools block)

TOOL_LOCK_PATH = ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
BUNDLED_PAYLOADS_PATH = ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/bundled-payloads.json"
OVERRIDES_PATH = ROOT / "scripts/release/notices-overrides.json"
NOTICES_PATH = ROOT / "THIRD-PARTY-NOTICES"
PACKAGE_RESOLVED_PATH = ROOT / "Package.resolved"
CHECKOUTS_DIR = ROOT / ".build" / "checkouts"

LICENSE_CANDIDATES = ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "LICENSE-MIT", "LICENSE.MIT")

BAR = "=" * 80

MOVING_BRANCHES = ("main", "master", "dev", "develop", "trunk", "HEAD")
_BRANCH_ALTERNATION = "|".join(MOVING_BRANCHES)
MOVING_BRANCH_URL_PATTERN = re.compile(
    r"https?://(?:"
    rf"github\.com/[^/\s]+/[^/\s]+/(?:blob|tree|raw)/(?:{_BRANCH_ALTERNATION})(?=[/\s.,);]|$)"
    rf"|raw\.githubusercontent\.com/[^/\s]+/[^/\s]+/(?:{_BRANCH_ALTERNATION})(?=[/\s.,);]|$)"
    r"|[^\s]*/refs/heads/"
    r")[^\s]*"
)
PIN_PLACEHOLDER_PATTERN = re.compile(r"\{pin:([A-Za-z0-9._-]+)\}")


class NoticesGenerationError(RuntimeError):
    """Raised when a dependency's license cannot be resolved from any source."""


def load_json(path: pathlib.Path):
    if not path.is_file():
        raise NoticesGenerationError(f"required manifest is missing: {path}")
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def find_moving_branch_urls(text: str) -> list[str]:
    """Returns every GitHub URL in ``text`` that follows a moving branch."""
    return MOVING_BRANCH_URL_PATTERN.findall(text)


def load_pinned_revisions() -> dict[str, str]:
    """Maps each Package.resolved identity to its pinned commit revision."""
    resolved = load_json(PACKAGE_RESOLVED_PATH)
    revisions = {}
    for pin in resolved.get("pins", []):
        revision = pin.get("state", {}).get("revision")
        if revision:
            revisions[pin["identity"]] = revision
    return revisions


def expand_pin_placeholders(value, revisions: dict[str, str]):
    """Recursively replaces ``{pin:<identity>}`` in strings with pinned commits."""
    if isinstance(value, str):
        def substitute(match: re.Match) -> str:
            identity = match.group(1)
            if identity not in revisions:
                raise NoticesGenerationError(
                    f"placeholder {{pin:{identity}}} names a dependency that is not pinned in Package.resolved"
                )
            return revisions[identity]

        return PIN_PLACEHOLDER_PATTERN.sub(substitute, value)
    if isinstance(value, list):
        return [expand_pin_placeholders(item, revisions) for item in value]
    if isinstance(value, dict):
        return {key: expand_pin_placeholders(item, revisions) for key, item in value.items()}
    return value


def find_checkout_license(identity: str) -> str | None:
    """Look for a LICENSE file under .build/checkouts/<identity>*/."""
    if not CHECKOUTS_DIR.is_dir():
        return None
    candidates = [CHECKOUTS_DIR / identity]
    candidates.extend(sorted(CHECKOUTS_DIR.glob(f"{identity}*")))
    seen = set()
    for checkout_dir in candidates:
        if checkout_dir in seen or not checkout_dir.is_dir():
            continue
        seen.add(checkout_dir)
        for name in LICENSE_CANDIDATES:
            candidate = checkout_dir / name
            if candidate.is_file():
                return candidate.read_text(encoding="utf-8", errors="replace").strip()
    return None


def resolve_swiftpm_dependencies(overrides: dict) -> tuple[list[dict], list[dict]]:
    """Returns (shipped, excluded) dependency entries with resolved license text."""
    resolved = load_json(PACKAGE_RESOLVED_PATH)
    shipped: list[dict] = []
    excluded: list[dict] = []
    missing: list[str] = []

    for pin in resolved.get("pins", []):
        identity = pin["identity"]
        state = pin.get("state", {})
        revision = state.get("revision")
        version = state.get("version") or (revision or "unknown")[:12]
        override = overrides.get(identity)

        if override is not None and override.get("shipped") is False:
            excluded.append(
                {
                    "identity": identity,
                    "location": pin.get("location", ""),
                    "version": version,
                    "reason": override.get("reason", "test-only dependency; not linked into a shipped target"),
                }
            )
            continue

        license_text = find_checkout_license(identity)
        license_id = None
        license_url = None
        copyright_line = None
        license_election = override.get("licenseElection") if override else None

        if license_text is None and override is None:
            missing.append(identity)
            continue
        if override is not None:
            license_id = override.get("license")
            copyright_line = override.get("copyright")
            # The pinned URL is emitted whether or not the full text was found in
            # .build/checkouts, so the committed file carries the same provenance
            # line in every environment (a release build always has checkouts).
            license_url = override.get("licenseUrl")
            if license_url and "{revision}" in license_url:
                if not revision:
                    raise NoticesGenerationError(
                        f"{identity}: licenseUrl uses {{revision}} but Package.resolved has no pinned revision"
                    )
                license_url = license_url.replace("{revision}", revision)

        shipped.append(
            {
                "identity": identity,
                "location": pin.get("location", ""),
                "version": version,
                "license": license_id or "see license text",
                "licenseUrl": license_url,
                "licenseText": license_text,
                "copyright": copyright_line,
                "licenseElection": license_election,
            }
        )

    if missing:
        raise NoticesGenerationError(
            "cannot find license text for SwiftPM dependencies (no .build/checkouts "
            "entry and no scripts/release/notices-overrides.json entry): "
            + ", ".join(sorted(missing))
            + ". Either build the package graph locally (swift build --skip-update) "
            "so .build/checkouts is populated, or add an override entry."
        )

    shipped.sort(key=lambda entry: entry["identity"])
    excluded.sort(key=lambda entry: entry["identity"])
    return shipped, excluded


def render_dependency_section(entry: dict) -> str:
    lines = [BAR, f"{entry['identity']} {entry['version']}", entry["location"], BAR, ""]
    if entry.get("copyright"):
        lines.append(entry["copyright"])
        lines.append("")
    if entry.get("licenseElection"):
        lines.append(f"License election: {entry['licenseElection']}")
        lines.append("")
    if entry.get("licenseText"):
        if entry.get("license") and entry["license"] != "see license text":
            lines.append(f"License: {entry['license']}")
        if entry.get("licenseUrl"):
            lines.append(f"License source: {entry['licenseUrl']}")
        if entry.get("license") != "see license text" or entry.get("licenseUrl"):
            lines.append("")
        lines.append(entry["licenseText"].strip())
    else:
        lines.append(f"License: {entry['license']}")
        if entry.get("licenseUrl"):
            lines.append(f"Full license text: {entry['licenseUrl']}")
    lines.append("")
    return "\n".join(lines)


def render_bundled_payload_section(entry: dict) -> str:
    lines = [BAR, f"{entry['displayName']} {entry['version']}", entry["sourceUrl"], BAR, ""]
    lines.append(f"Bundled at: {entry['path']}")
    lines.append(f"License: {entry['license']}")
    if entry.get("copyright"):
        lines.append(entry["copyright"])
    if entry.get("notes"):
        lines.append("")
        lines.append(entry["notes"])
    if entry.get("sourceOffer"):
        lines.append("")
        lines.append(entry["sourceOffer"])
    lines.append("")
    return "\n".join(lines)


def render_notices(tool_lock: dict, bundled_payloads: dict, shipped_deps: list[dict], excluded_deps: list[dict]) -> str:
    sections = [
        "Lungfish Genome Explorer — Third-Party Notices",
        "=" * 48,
        "",
        "This file is generated by scripts/release/generate-notices.py from",
        "Package.resolved, Sources/LungfishWorkflow/Resources/ManagedTools/",
        "bundled-payloads.json, and third-party-tools-lock.json. Do not hand-edit;",
        "regenerate it instead.",
        "",
        "Lungfish itself is licensed under the MIT License. See LICENSE for details.",
        "",
        BAR,
        "Bundled binary payloads (embedded in the app bundle)",
        BAR,
        "",
    ]

    for entry in bundled_payloads.get("bootstrapBinaries", []):
        sections.append(render_bundled_payload_section(entry))
    for entry in bundled_payloads.get("containerizationPayloads", []):
        sections.append(render_bundled_payload_section(entry))

    sections.append(BAR)
    sections.append("Compiled-in Swift package dependencies (SwiftPM, Package.resolved)")
    sections.append(BAR)
    sections.append("")
    for entry in shipped_deps:
        sections.append(render_dependency_section(entry))

    if excluded_deps:
        sections.append(BAR)
        sections.append("Test-only Swift package dependencies (not linked into the shipped app)")
        sections.append(BAR)
        sections.append("")
        for entry in excluded_deps:
            sections.append(f"- {entry['identity']} {entry['version']} ({entry['location']})")
            sections.append(f"  {entry['reason']}")
        sections.append("")

    sections.append(BAR)
    sections.append("Managed tools (installed on demand, NOT bundled with the app)")
    sections.append(BAR)
    sections.append("")
    sections.append(
        "The following tools are executed inside isolated Linux containers or are"
    )
    sections.append(
        "installed on demand into `~/.lungfish` via the bundled micromamba bootstrap."
    )
    sections.append("No binary distribution obligations apply to LGE for these.")
    sections.append("")

    for note in bundled_payloads.get("managedToolNotes", []):
        sections.append(f"--- {note['id']} ---")
        sections.append(note["note"])
        sections.append("")

    sections.append(bump.NOTICES_BEGIN)
    sections.append(bump.render_notices_table(tool_lock))
    sections.append(bump.NOTICES_END)
    sections.append("")

    rendered = "\n".join(sections)
    moving = find_moving_branch_urls(rendered)
    if moving:
        raise NoticesGenerationError(
            "notices contain URLs that follow a moving branch instead of a pinned tag or commit: "
            + ", ".join(sorted(set(moving)))
            + ". Use {revision} in notices-overrides.json or {pin:<identity>} in bundled-payloads.json."
        )
    return rendered


def collect_all_identifiers(shipped_deps, excluded_deps, bundled_payloads, tool_lock) -> set[str]:
    identifiers = {entry["identity"] for entry in shipped_deps}
    identifiers |= {entry["identity"] for entry in excluded_deps}
    for entry in bundled_payloads.get("bootstrapBinaries", []):
        identifiers.add(entry["id"])
    for entry in bundled_payloads.get("containerizationPayloads", []):
        identifiers.add(entry["id"])
    return identifiers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=pathlib.Path, default=NOTICES_PATH, help="Where to write the generated notices (default: THIRD-PARTY-NOTICES)")
    parser.add_argument("--check", action="store_true", help="Do not write; fail if the generated content differs from --out's current content")
    args = parser.parse_args()

    try:
        overrides = load_json(OVERRIDES_PATH) if OVERRIDES_PATH.is_file() else {}
        overrides = {k: v for k, v in overrides.items() if not k.startswith("_")}
        tool_lock = load_json(TOOL_LOCK_PATH)
        bundled_payloads = expand_pin_placeholders(load_json(BUNDLED_PAYLOADS_PATH), load_pinned_revisions())
        shipped_deps, excluded_deps = resolve_swiftpm_dependencies(overrides)
        rendered = render_notices(tool_lock, bundled_payloads, shipped_deps, excluded_deps)
    except NoticesGenerationError as error:
        print(f"generate-notices.py: {error}", file=sys.stderr)
        return 64

    if args.check:
        if not args.out.is_file():
            print(f"generate-notices.py --check: {args.out} does not exist", file=sys.stderr)
            return 1
        current = args.out.read_text(encoding="utf-8")
        if current != rendered:
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as handle:
                handle.write(rendered)
                temp_path = handle.name
            print(
                f"generate-notices.py --check: {args.out} is stale. "
                f"Regenerate with 'python3 scripts/release/generate-notices.py'. "
                f"Freshly generated content written to {temp_path} for diffing.",
                file=sys.stderr,
            )
            return 1
        print(f"{args.out} is up to date.")
        return 0

    args.out.write_text(rendered, encoding="utf-8")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
