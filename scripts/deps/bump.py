#!/usr/bin/env python3
"""Apply a candidate set to the tool lock manifest and refresh derived files.

``check_upstream.py`` reports what upstream has; this script is the half that
edits. It reads a candidates JSON, rewrites the pins that are safe to move,
refreshes the files derived from the manifest, and prints a change log so the
sweep can paste the delta into the release notes.

Only candidates whose ``status`` is ``update`` are ever applied. Everything
else (``no-arm64-build``, ``dead-url``, ``error``, ``manual-check``) is
reported as ``skipped: <status>`` and left alone for a human to look at.
Ids passed to ``--hold`` are pinned; a held tool still takes a newer *build*
of the version it is already on unless ``--no-take-builds-for-held`` is given.

Stdlib only; no third-party imports.
"""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import manifest_io  # noqa: E402
import upstream_sources as us  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = (
    ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
)

TOOL_VERSIONS_REL = "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"
VERSIONS_TXT_REL = "Sources/LungfishWorkflow/Resources/Tools/VERSIONS.txt"
NOTICES_REL = "THIRD-PARTY-NOTICES"

NOTICES_BEGIN = "<!-- managed-tools:begin -->"
NOTICES_END = "<!-- managed-tools:end -->"

STATUS_UPDATE = "update"

ESVIRITU_ZENODO_RECORD = "17716199"
MICROMAMBA_ARCH = "osx-arm64"

EXIT_OK = 0
EXIT_INPUT_ERROR = 1
EXIT_USAGE = 64


# --------------------------------------------------------------------------
# spec helpers


def _spec_parts(spec):
    """``bioconda::samtools=1.24=h36b3a25_1`` -> (channel, name, version, build)."""
    channel = None
    remainder = spec or ""
    if "::" in remainder:
        channel, remainder = remainder.split("::", 1)
    parts = remainder.split("=")
    return (
        channel,
        parts[0] if parts else "",
        parts[1] if len(parts) > 1 else "",
        parts[2] if len(parts) > 2 else "",
    )


def spec_version(spec):
    """The version component of a conda package spec."""
    return _spec_parts(spec)[2]


def _candidate_sha(candidate):
    """Pipeline commit sha: ``latestSha`` if present, else check_upstream's ``latestBuild``."""
    return candidate.get("latestSha") or candidate.get("latestBuild")


def _candidate_url(candidate):
    """Database download URL: ``latestURL`` if present, else check_upstream's ``latestSpec``.

    ``check_upstream`` puts the resolved URL in ``latestSpec`` for databases,
    so accept either spelling rather than silently leaving a stale URL pinned.
    """
    url = candidate.get("latestURL")
    if url:
        return url
    spec = candidate.get("latestSpec") or ""
    return spec if spec.startswith(("http://", "https://")) else None


def _candidate_filename(candidate, url):
    """Explicit ``latestFilename``, else the basename of a file-shaped URL."""
    filename = candidate.get("latestFilename")
    if filename:
        return filename
    if url and not url.endswith("/"):
        return url.rsplit("/", 1)[-1]
    return None


def _tool_index(manifest):
    """Map candidate id -> manifest entry for tools and pack tools alike."""
    index = {}
    for entry in manifest.get("tools") or []:
        index[entry.get("id", "")] = entry
    for entry in manifest.get("packTools") or []:
        index[f"{entry.get('packID', '')}/{entry.get('id', '')}"] = entry
    return index


# --------------------------------------------------------------------------
# apply


def _selected(entry_id, only, hold):
    """(selected, reason) - reason is a log suffix when the id is skipped."""
    if only is not None and entry_id not in only:
        return False, "skipped: not in --only"
    if entry_id in hold:
        return False, "held"
    return True, ""


def _apply_tool(entry, candidate, entry_id, log, only, hold, take_builds_for_held):
    status = candidate.get("status")
    latest_spec = candidate.get("latestSpec")
    current_spec = entry.get("packageSpec", "")

    if status != STATUS_UPDATE:
        if status and status != "same":
            log.append(f"{entry_id}: skipped: {status}")
        return False

    selected, reason = _selected(entry_id, only, hold)
    if not selected:
        if reason == "held":
            # A held id may still take a newer build of the version it is on.
            if (
                take_builds_for_held
                and latest_spec
                and spec_version(latest_spec) == spec_version(current_spec)
                and latest_spec != current_spec
            ):
                entry["packageSpec"] = latest_spec
                log.append(
                    f"{entry_id}: build only {current_spec} -> {latest_spec} (held at "
                    f"{entry.get('version')})"
                )
                return True
            log.append(
                f"{entry_id}: skipped: held at {entry.get('version')} "
                f"(upstream {candidate.get('latest')})"
            )
        else:
            log.append(f"{entry_id}: {reason} (upstream {candidate.get('latest')})")
        return False

    if not latest_spec:
        log.append(f"{entry_id}: skipped: candidate carried no latestSpec")
        return False

    new_version = candidate.get("latest") or spec_version(latest_spec)
    old_version = entry.get("version")
    if latest_spec == current_spec:
        return False
    entry["packageSpec"] = latest_spec
    entry["version"] = new_version
    if str(old_version) == str(new_version):
        log.append(f"{entry_id}: build only {current_spec} -> {latest_spec}")
    else:
        log.append(f"{entry_id}: {old_version} -> {new_version} ({latest_spec})")
    return True


def _apply_pipeline(entry, candidate, log, only, hold):
    entry_id = entry.get("id", "")
    status = candidate.get("status")
    if status is not None and status != STATUS_UPDATE:
        if status != "same":
            log.append(f"{entry_id}: skipped: {status}")
        return False

    selected, reason = _selected(entry_id, only, hold)
    if not selected:
        suffix = "skipped: held" if reason == "held" else reason
        log.append(f"{entry_id}: {suffix} (upstream {candidate.get('latest')})")
        return False

    latest = candidate.get("latest")
    latest_sha = _candidate_sha(candidate)
    if not latest:
        log.append(f"{entry_id}: skipped: candidate carried no latest tag")
        return False

    old = entry.get("releaseVersion")
    entry["releaseVersion"] = latest
    entry["revision"] = latest_sha or latest
    log.append(f"{entry_id}: {old} -> {latest} (revision {entry['revision']})")
    return True


def release_date_from_version(version):
    """The release date a database version encodes, as ``YYYY-MM-DD``, or ``None``.

    Several database pins are dated builds rather than semantic versions:
    ``20260626`` for a Kraken2 index, ``20260706v2`` for a human-scrubber
    database that was rebuilt the same day, ``2026-07-06`` where upstream
    already writes it out. When the version says when it was built, the
    manifest's ``releaseDate`` should say the same thing.

    Left alone otherwise. A version like ``panhuman-1`` or ``v3.2.4`` carries no
    date, and inventing one would be worse than the stale value it replaced.
    """
    if not isinstance(version, str):
        return None

    text = version.strip()
    # A trailing rebuild counter ("20260706v2") is not part of the date.
    for separator in ("v", "V"):
        head, found, tail = text.partition(separator)
        if found and tail.isdigit() and head:
            text = head
            break

    digits = text.replace("-", "")
    if len(digits) != 8 or not digits.isdigit():
        return None

    try:
        parsed = datetime.date(int(digits[0:4]), int(digits[4:6]), int(digits[6:8]))
    except ValueError:
        # An impossible date (month 13, day 32) is not a date, so it is not one
        # this function should manufacture a releaseDate from.
        return None
    return parsed.isoformat()


def _apply_database(entry, candidate, log, only, hold):
    entry_id = entry.get("id", "")
    status = candidate.get("status")
    if status is not None and status != STATUS_UPDATE:
        if status != "same":
            log.append(f"{entry_id}: skipped: {status}")
        return False

    selected, reason = _selected(entry_id, only, hold)
    if not selected:
        suffix = "skipped: held" if reason == "held" else reason
        log.append(f"{entry_id}: {suffix} (upstream {candidate.get('latest')})")
        return False

    latest = candidate.get("latest")
    if not latest:
        log.append(f"{entry_id}: skipped: candidate carried no latest version")
        return False

    old = entry.get("version")
    entry["version"] = latest
    url = _candidate_url(candidate)
    if url:
        entry["url"] = url
    # Only entries that already track a filename get one; a bare index URL must
    # not grow a "filename" key it never had.
    if "filename" in entry:
        filename = _candidate_filename(candidate, url)
        if filename:
            entry["filename"] = filename
    if candidate.get("latestMD5"):
        entry["md5"] = candidate["latestMD5"]
    # A dated version pin is the authoritative statement of when the database was
    # built, so it also settles releaseDate. Without this the date was only ever
    # written by hand and drifted: the human-scrubber entry still read 2025-09-16
    # after being bumped to the 20260706v2 build.
    release_date = release_date_from_version(latest)
    if release_date and entry.get("releaseDate") != release_date:
        previous_date = entry.get("releaseDate")
        entry["releaseDate"] = release_date
        log.append(f"{entry_id}: releaseDate {previous_date or 'unset'} -> {release_date}")
    log.append(f"{entry_id}: {old} -> {latest}" + (f" ({url})" if url else ""))
    return True


def _apply_bootstrap(manifest, candidate, log, only, hold):
    if not candidate:
        return False
    entry_id = candidate.get("id") or "micromamba"
    status = candidate.get("status")
    if status is not None and status != STATUS_UPDATE:
        if status != "same":
            log.append(f"{entry_id}: skipped: {status}")
        return False

    selected, reason = _selected(entry_id, only, hold)
    if not selected:
        suffix = "skipped: held" if reason == "held" else reason
        log.append(f"{entry_id}: {suffix} (upstream {candidate.get('latest')})")
        return False

    latest = candidate.get("latest")
    if not latest:
        log.append(f"{entry_id}: skipped: candidate carried no latest version")
        return False

    micromamba = (manifest.setdefault("bootstrap", {})).setdefault("micromamba", {})
    old = micromamba.get("version")
    if old == latest:
        return False
    micromamba["version"] = latest
    # The recorded digest belongs to the old binary; fetch_checksums refills it.
    micromamba["sha256"] = {}
    log.append(f"{entry_id}: {old} -> {latest} (sha256 cleared, refetch required)")
    return True


def apply_bumps(
    manifest,
    candidates,
    *,
    new_set,
    date,
    only,
    hold,
    take_builds_for_held=True,
    force_set=False,
    retire=None,
    changed_ids=None,
):
    """Return ``(new_manifest, change_log_lines)`` without mutating ``manifest``.

    Pass a set as ``changed_ids`` to receive the ids that were actually
    bumped; ``fetch_checksums`` needs exactly that set so it only refetches
    digests for entries whose underlying artifact changed.
    """
    new = json.loads(json.dumps(manifest))
    log = []
    bumped = changed_ids if changed_ids is not None else set()

    index = _tool_index(new)
    for candidate in candidates.get("tools") or []:
        entry_id = candidate.get("id", "")
        entry = index.get(entry_id)
        if entry is None:
            log.append(f"{entry_id}: skipped: no such id in the manifest")
            continue
        if _apply_tool(entry, candidate, entry_id, log, only, hold, take_builds_for_held):
            bumped.add(entry_id)

    pipelines = {entry.get("id", ""): entry for entry in new.get("pipelines") or []}
    for candidate in candidates.get("pipelines") or []:
        entry_id = candidate.get("id", "")
        entry = pipelines.get(entry_id)
        if entry is None:
            log.append(f"{entry_id}: skipped: no such id in the manifest")
            continue
        if _apply_pipeline(entry, candidate, log, only, hold):
            bumped.add(entry_id)

    databases = {entry.get("id", ""): entry for entry in new.get("databases") or []}
    for candidate in candidates.get("databases") or []:
        entry_id = candidate.get("id", "")
        entry = databases.get(entry_id)
        if entry is None:
            log.append(f"{entry_id}: skipped: no such id in the manifest")
            continue
        if _apply_database(entry, candidate, log, only, hold):
            bumped.add(entry_id)

    if _apply_bootstrap(new, candidates.get("bootstrap"), log, only, hold):
        bumped.add("micromamba")

    for environment in sorted(retire or ()):
        retired = new.setdefault("retiredEnvironments", [])
        if environment in retired:
            continue
        retired.append(environment)
        log.append(f"{environment}: retire environment")
        bumped.add(f"retire:{environment}")

    changed = bool(bumped)

    if changed or force_set:
        new["dependencySet"] = new_set
        new["dependencySetDate"] = date
        log.append(f"dependencySet: {manifest.get('dependencySet')} -> {new_set} ({date})")
    else:
        log.append("no changes; dependencySet left at " + str(manifest.get("dependencySet")))

    return new, log


# --------------------------------------------------------------------------
# checksums


def _first_hex_token(text):
    """First whitespace-delimited hex token in a checksum sidecar."""
    for token in (text or "").split():
        stripped = token.strip()
        if len(stripped) >= 32 and all(c in "0123456789abcdefABCDEF" for c in stripped):
            return stripped.lower()
    return None


def _esviritu_md5(entry, fetcher):
    files = us.zenodo_record_files(ESVIRITU_ZENODO_RECORD, fetcher)
    wanted = (entry.get("url") or "").rsplit("/", 1)[-1]
    for candidate in files:
        if candidate["name"] == wanted:
            checksum = candidate.get("checksum") or ""
            return checksum.split(":", 1)[1] if checksum.startswith("md5:") else checksum
    raise us.FetchError(
        f"Zenodo record {ESVIRITU_ZENODO_RECORD} has no file named {wanted}"
    )


def _taxonomy_md5(entry, fetcher):
    url = entry.get("url") or ""
    if not url:
        raise us.FetchError("ncbi-taxonomy entry carries no url")
    digest = _first_hex_token(fetcher.get_text(url + ".md5"))
    if digest is None:
        raise us.FetchError(f"no md5 token in {url}.md5")
    return digest


MICROMAMBA_DOWNLOAD = (
    "https://github.com/mamba-org/micromamba-releases/releases/download/{version}/"
    "micromamba-{arch}"
)


def _micromamba_sha256(version, fetcher):
    """The osx-arm64 sha256 for the *pinned* ``version``.

    Always addresses that version's release assets by tag. Reading
    ``releases/latest`` here would pair a held pin with a newer binary's
    digest, which is worse than having no digest at all: every install would
    fail verification against a checksum that was never true for that file.
    """
    if not version:
        raise us.FetchError("no micromamba version pinned in the manifest")

    binary_url = MICROMAMBA_DOWNLOAD.format(version=version, arch=MICROMAMBA_ARCH)
    try:
        digest = _first_hex_token(fetcher.get_text(binary_url + ".sha256"))
    except Exception:
        digest = None
    if digest:
        return digest

    get_bytes = getattr(fetcher, "get_bytes", None)
    if get_bytes is None:
        raise us.FetchError("fetcher cannot download binaries; pass --no-checksums")
    return hashlib.sha256(get_bytes(binary_url)).hexdigest()


CHECKSUM_RESOLVERS = {
    "esviritu-viral-v3": _esviritu_md5,
    "ncbi-taxonomy": _taxonomy_md5,
}


def fetch_checksums(manifest, fetcher, changed=None):
    """Refresh digests for the entries this run changed. Returns ``{id: value}``.

    ``changed`` is the set of ids ``apply_bumps`` actually bumped. Only those
    are refetched: a held or untouched pin keeps the digest that belongs to it,
    and an entry that never carried a digest does not grow one. Passing
    ``None`` means "nothing changed", so nothing is fetched -- callers must
    opt in explicitly rather than having every id silently rewritten.

    A source that cannot be read yields ``"error: <message>"`` for that id
    rather than raising, so one dead endpoint does not abort a sweep.
    """
    changed = set(changed or ())
    results = {}

    for entry in manifest.get("databases") or []:
        entry_id = entry.get("id", "")
        resolver = CHECKSUM_RESOLVERS.get(entry_id)
        if resolver is None or entry_id not in changed:
            continue
        try:
            digest = resolver(entry, fetcher)
        except Exception as exc:  # one bad source must not stop the sweep
            results[entry_id] = f"error: {type(exc).__name__}: {exc}"
            continue
        entry["md5"] = digest
        results[entry_id] = digest

    if manifest.get("bootstrap") and "micromamba" in changed:
        micromamba = manifest["bootstrap"].setdefault("micromamba", {})
        try:
            digest = _micromamba_sha256(micromamba.get("version"), fetcher)
        except Exception as exc:
            results["micromamba"] = f"error: {type(exc).__name__}: {exc}"
        else:
            micromamba.setdefault("sha256", {})[MICROMAMBA_ARCH] = digest
            results["micromamba"] = digest

    return results


# --------------------------------------------------------------------------
# derived files


def _now():
    """UTC now, honouring ``SOURCE_DATE_EPOCH`` for reproducible output."""
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch:
        try:
            return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc)
        except (TypeError, ValueError):
            pass
    return datetime.datetime.now(datetime.timezone.utc)


def _micromamba_version(manifest):
    return ((manifest.get("bootstrap") or {}).get("micromamba") or {}).get("version") or ""


def _refresh_tool_versions(manifest, path, now):
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["lastUpdated"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    version = _micromamba_version(manifest)
    for tool in payload.get("tools") or []:
        if tool.get("name") == "micromamba":
            tool["version"] = version
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _refresh_versions_txt(manifest, path, now, architecture):
    """Reproduce the file ``scripts/bundle-native-tools.sh`` writes."""
    version = _micromamba_version(manifest)
    path.write_text(
        "Lungfish Bundled Bootstrap Tools\n"
        "=================================\n"
        "\n"
        "This directory contains the bundled bootstrap binary used by Lungfish.\n"
        "Only micromamba remains bundled here; all other bioinformatics tools are\n"
        "managed separately.\n"
        "\n"
        "Versions:\n"
        f"- micromamba: {version} (BSD-3-Clause license)\n"
        "\n"
        f"Build date: {now.strftime('%Y-%m-%d %H:%M:%S')} UTC\n"
        f"Build architecture: {architecture}\n"
        "\n"
        "Source URLs:\n"
        "- micromamba: https://github.com/mamba-org/mamba\n"
        "\n"
        "Licenses:\n"
        "- micromamba: https://github.com/mamba-org/mamba/blob/main/LICENSE\n",
        encoding="utf-8",
    )


def render_notices_table(manifest):
    """The managed-tools block written between the notices markers."""
    rows = []
    for entry in manifest.get("tools") or []:
        rows.append((entry.get("id", ""), entry))
    for entry in manifest.get("packTools") or []:
        rows.append((f"{entry.get('packID', '')}/{entry.get('id', '')}", entry))

    id_width = max([len(row_id) for row_id, _ in rows] + [len("Tool")])
    version_width = max(
        [len(str(entry.get("version", ""))) for _, entry in rows] + [len("Version")]
    )
    license_width = max(
        [len(str(entry.get("license", ""))) for _, entry in rows] + [len("License")]
    )

    lines = [
        "The following managed tools are installed on demand into `~/.lungfish` and",
        "are not bundled with the app. This block is generated by scripts/deps/bump.py.",
        "",
        f"{'Tool'.ljust(id_width)}  {'Version'.ljust(version_width)}  "
        f"{'License'.ljust(license_width)}  Source",
    ]
    for row_id, entry in rows:
        lines.append(
            f"{row_id.ljust(id_width)}  "
            f"{str(entry.get('version', '')).ljust(version_width)}  "
            f"{str(entry.get('license', '')).ljust(license_width)}  "
            f"{entry.get('sourceUrl', '')}".rstrip()
        )
    return "\n".join(lines)


def _refresh_notices(manifest, path):
    text = path.read_text(encoding="utf-8")
    table = render_notices_table(manifest)
    block = f"{NOTICES_BEGIN}\n{table}\n{NOTICES_END}"

    if NOTICES_BEGIN in text and NOTICES_END in text:
        head, rest = text.split(NOTICES_BEGIN, 1)
        _, tail = rest.split(NOTICES_END, 1)
        path.write_text(head + block + tail, encoding="utf-8")
        return

    # No markers yet: append the generated block as a new trailing section,
    # leaving every existing byte of the file untouched.
    separator = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
    path.write_text(
        text
        + separator
        + "================================================================================\n"
        "Managed Tools (Installed On Demand)\n"
        "================================================================================\n"
        "\n"
        + block
        + "\n",
        encoding="utf-8",
    )


def refresh_derived_files(manifest, repo_root, architecture="arm64"):
    """Rewrite the files derived from the manifest. Returns the paths written."""
    repo_root = pathlib.Path(repo_root)
    now = _now()
    written = []

    tool_versions = repo_root / TOOL_VERSIONS_REL
    if tool_versions.exists():
        _refresh_tool_versions(manifest, tool_versions, now)
        written.append(tool_versions)

    versions_txt = repo_root / VERSIONS_TXT_REL
    if versions_txt.parent.exists():
        _refresh_versions_txt(manifest, versions_txt, now, architecture)
        written.append(versions_txt)

    notices = repo_root / NOTICES_REL
    if notices.exists():
        _refresh_notices(manifest, notices)
        written.append(notices)

    return written


# --------------------------------------------------------------------------
# main


def _id_set(raw):
    return {part.strip() for part in (raw or "").split(",") if part.strip()}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Apply upstream candidates to the tool lock manifest."
    )
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--from", dest="candidates", required=True)
    parser.add_argument("--set", dest="new_set", required=True)
    parser.add_argument("--date", default=None)
    parser.add_argument("--only", default=None)
    parser.add_argument("--hold", default=None)
    parser.add_argument("--retire", default=None)
    parser.add_argument("--force-set", action="store_true")
    parser.add_argument("--no-checksums", action="store_true")
    parser.add_argument(
        "--no-take-builds-for-held",
        dest="take_builds_for_held",
        action="store_false",
        help="do not move a held tool onto a newer build of the version it is pinned to",
    )
    parser.add_argument("--dry-run", action="store_true")

    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        raise SystemExit(EXIT_USAGE if exc.code not in (0, None) else exc.code)

    only = _id_set(args.only) if args.only is not None else None
    if only is not None and not only:
        parser.error("--only needs at least one candidate id")
    hold = _id_set(args.hold)
    retire = _id_set(args.retire)
    date = args.date or datetime.date.today().isoformat()

    manifest_path = pathlib.Path(args.manifest)
    try:
        manifest = manifest_io.load(manifest_path)
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"cannot read manifest {manifest_path}: {exc}\n")
        return EXIT_INPUT_ERROR

    try:
        candidates = json.loads(pathlib.Path(args.candidates).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"cannot read candidates {args.candidates}: {exc}\n")
        return EXIT_INPUT_ERROR

    changed_ids = set()
    new_manifest, log = apply_bumps(
        manifest,
        candidates,
        new_set=args.new_set,
        date=date,
        only=only,
        hold=hold,
        take_builds_for_held=args.take_builds_for_held,
        force_set=args.force_set,
        retire=retire,
        changed_ids=changed_ids,
    )

    # A dry run reports and exits before any network access: checksum fetching
    # downloads binaries, which is not something "print what would change"
    # should ever do.
    if args.dry_run:
        for line in log:
            sys.stdout.write(line + "\n")
        sys.stdout.write("dry run: nothing written\n")
        return EXIT_OK

    if not args.no_checksums:
        digests = fetch_checksums(new_manifest, us.LiveFetcher(), changed=changed_ids)
        for entry_id, value in sorted(digests.items()):
            log.append(f"{entry_id}: checksum {value}")

    for line in log:
        sys.stdout.write(line + "\n")

    manifest_io.dump(new_manifest, manifest_path)
    repo_root = _repo_root_for(manifest_path)
    for path in refresh_derived_files(new_manifest, repo_root):
        sys.stdout.write(f"wrote {path}\n")
    sys.stdout.write(f"wrote {manifest_path}\n")
    return EXIT_OK


MANIFEST_REL = "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"


def _repo_root_for(manifest_path):
    """The repo root that owns ``manifest_path``.

    Strips the manifest's canonical relative path when it matches, so a copied
    tree (a temp dir in tests, a sweep sandbox) resolves the same way the real
    checkout does. Falls back to the checked-in ROOT for a manifest kept
    somewhere else entirely.
    """
    resolved = manifest_path.resolve()
    depth = len(pathlib.PurePosixPath(MANIFEST_REL).parts)
    if resolved.as_posix().endswith(MANIFEST_REL):
        return resolved.parents[depth - 1]
    return ROOT


if __name__ == "__main__":
    sys.exit(main())
