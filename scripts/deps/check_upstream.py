#!/usr/bin/env python3
"""Report candidate upstream versions for every pinned dependency.

Reads the tool lock manifest, asks each dependency's upstream source what the
newest release is, and reports the delta as JSON and/or a Markdown table. This
is a *reporting* tool: it never edits the manifest (that is ``bump.py``) and it
always exits 0, so a sweep can read the whole picture in one pass even when a
source is down.

Statuses:
    same            the pin already matches the newest upstream release
    update          a newer release exists
    no-arm64-build  upstream has the version, but not for osx-arm64
    dead-url        the URL currently pinned no longer resolves
    manual-check    no machine-readable source; follow the link by hand
    error           the source could not be read (message in ``notes``)

Stdlib only; no third-party imports.
"""

import argparse
import datetime
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import upstream_sources as us  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = (
    ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
)

STATUS_SAME = "same"
STATUS_UPDATE = "update"
STATUS_NO_ARM64 = "no-arm64-build"
STATUS_DEAD_URL = "dead-url"
STATUS_MANUAL = "manual-check"
STATUS_ERROR = "error"

ESVIRITU_ZENODO_RECORD = "17716199"

MARKDOWN_COLUMNS = (
    "id",
    "kind",
    "current",
    "latest",
    "latestSpec/URL",
    "status",
    "notes",
)


# --------------------------------------------------------------------------
# helpers


def _parse_package_spec(spec):
    """``bioconda::samtools=1.23.1=hc612e98_0`` -> (channel, name, version, build)."""
    channel = None
    remainder = spec or ""
    if "::" in remainder:
        channel, remainder = remainder.split("::", 1)
    parts = remainder.split("=")
    name = parts[0] if parts else ""
    version = parts[1] if len(parts) > 1 else ""
    build = parts[2] if len(parts) > 2 else ""
    return channel, name, version, build


def _row(entry_id, kind, current, **extra):
    row = {
        "id": entry_id,
        "kind": kind,
        "current": current,
        "currentBuild": extra.pop("currentBuild", None),
        "latest": None,
        "latestBuild": None,
        "latestSpec": None,
        "subdir": None,
        "status": STATUS_ERROR,
        "notes": "",
        "releaseNotesURL": extra.pop("releaseNotesURL", None),
    }
    row.update(extra)
    return row


def _selected(entry_id, only):
    return only is None or entry_id in only


# --------------------------------------------------------------------------
# conda-backed tools


def _tool_candidate(entry, kind, entry_id, fetcher):
    channel_hint, package_name, spec_version, spec_build = _parse_package_spec(
        entry.get("packageSpec", "")
    )
    current = entry.get("version") or spec_version
    row = _row(
        entry_id,
        kind,
        current,
        currentBuild=spec_build or None,
        releaseNotesURL=entry.get("sourceUrl"),
    )
    package_name = package_name or entry.get("id", "")

    try:
        latest = us.latest_conda(package_name, channel_hint, fetcher, spec_build)
    except us.FetchError as exc:
        row["notes"] = str(exc)
        return row
    except Exception as exc:  # defensive: one bad source must not stop the sweep
        row["notes"] = f"{type(exc).__name__}: {exc}"
        return row

    if latest is None:
        row["notes"] = f"no {package_name} package found on bioconda/conda-forge"
        return row

    # Every published build is on an older Python than the pin. Hold rather than
    # propose an interpreter downgrade: the pin is the newest usable build.
    if latest.get("version") is None and latest.get("lowerABIOnly"):
        row["status"] = STATUS_SAME
        row["latest"] = current
        row["latestSpec"] = entry.get("packageSpec", "")
        row["notes"] = (
            f"newer build only on lower Python ABI: "
            f"{channel_hint or 'bioconda'}::{package_name}={current}={latest['lowerABIOnly']}"
        )
        return row

    row["latest"] = latest["version"]
    row["latestBuild"] = latest["build"]
    row["subdir"] = latest["subdir"]
    row["latestSpec"] = (
        f"{latest['channel']}::{package_name}={latest['version']}={latest['build']}"
    )

    if latest["subdir"] == "noarch" and spec_build and "py" in spec_build:
        row["notes"] = "newest build is noarch; verify it runs on osx-arm64"

    linux_only = latest.get("linuxOnlyVersion")
    same_version = us.compare_versions(current, latest["version"]) == 0

    # A strictly newer version that exists only on linux-64 is worth flagging:
    # the pin cannot move, but the sweep should not read it as "up to date".
    if linux_only and same_version:
        row["status"] = STATUS_NO_ARM64
        row["notes"] = (
            f"bioconda has {linux_only} but publishes no osx-arm64 or noarch build; "
            f"{latest['version']} is the newest installable version"
        )
        return row

    if same_version and (not spec_build or spec_build == latest["build"]):
        row["status"] = STATUS_SAME
        # The pin is already the newest build that keeps the interpreter, but a
        # newer one exists on an older Python. Name it so the hold is visible
        # rather than reading as a plain "nothing to do".
        if latest.get("lowerABIOnly"):
            row["notes"] = row["notes"] or (
                f"newer build only on lower Python ABI: "
                f"{latest['channel']}::{package_name}={latest['version']}="
                f"{latest['lowerABIOnly']}"
            )
    elif same_version:
        row["status"] = STATUS_UPDATE
        row["notes"] = (
            row["notes"] or f"same version, newer build ({spec_build} -> {latest['build']})"
        )
        # A newer build existed but sat on an older interpreter; say so, so the
        # chosen build is not mistaken for the newest published one.
        if latest.get("lowerABIOnly"):
            row["notes"] += (
                f"; skipped {latest['lowerABIOnly']} (lower Python ABI)"
            )
    elif us.compare_versions(latest["version"], current) > 0:
        row["status"] = STATUS_UPDATE
    else:
        row["status"] = STATUS_SAME
        row["notes"] = row["notes"] or "pin is ahead of the newest published build"
    return row


# --------------------------------------------------------------------------
# pipelines


def _pipeline_candidate(entry, fetcher):
    entry_id = entry.get("id", "")
    repo = entry.get("repository", "")
    row = _row(
        entry_id,
        "pipeline",
        entry.get("releaseVersion") or entry.get("revision"),
        currentBuild=entry.get("revision"),
        releaseNotesURL=f"https://github.com/{repo}/releases" if repo else None,
    )
    if not repo:
        row["notes"] = "no repository recorded in the manifest"
        return row

    try:
        latest = us.latest_github_release(repo, fetcher)
    except us.FetchError as exc:
        row["notes"] = str(exc)
        return row
    except Exception as exc:
        row["notes"] = f"{type(exc).__name__}: {exc}"
        return row

    if latest is None:
        row["notes"] = f"no tags or releases found for {repo}"
        return row

    row["latest"] = latest["tag"]
    row["latestBuild"] = latest["sha"]
    row["latestSpec"] = f"{repo}@{latest['sha'] or latest['tag']}"
    current = str(row["current"] or "").lstrip("v")
    if us.compare_versions(latest["tag"].lstrip("v"), current) > 0:
        row["status"] = STATUS_UPDATE
    else:
        row["status"] = STATUS_SAME
    return row


# --------------------------------------------------------------------------
# databases


def _kraken2_candidate(entry, kraken_dates, fetcher):
    entry_id = entry.get("id", "")
    collection = entry.get("collection")
    row = _row(
        entry_id,
        "database",
        entry.get("version"),
        releaseNotesURL=us.KRAKEN2_INDEX_PAGE,
    )

    if collection is None:
        row["status"] = STATUS_MANUAL
        row["latestSpec"] = entry.get("url") or us.KRAKEN2_INDEX_PAGE
        row["notes"] = "special index; rebuild or re-download by hand"
        return row

    if isinstance(kraken_dates, Exception):
        row["notes"] = str(kraken_dates)
        return row

    latest = kraken_dates.get(collection)
    if latest is None:
        row["notes"] = f"no live index found for collection {collection}"
        return row

    row["latest"] = latest["date"]
    row["latestSpec"] = latest["url"]

    current_url = entry.get("url")
    url_dead = bool(current_url) and not fetcher.head_ok(current_url)
    if url_dead:
        row["status"] = STATUS_DEAD_URL
        row["notes"] = "the pinned URL no longer resolves; the index was withdrawn"
    elif str(entry.get("version")) == latest["date"]:
        row["status"] = STATUS_SAME
    else:
        row["status"] = STATUS_UPDATE
    return row


def _human_scrubber_candidate(entry, fetcher):
    row = _row(
        entry.get("id", ""),
        "database",
        entry.get("version"),
        releaseNotesURL=entry.get("releasesUrl"),
    )
    try:
        latest = us.ncbi_human_filter_latest(fetcher)
    except us.FetchError as exc:
        row["notes"] = str(exc)
        return row
    except Exception as exc:
        row["notes"] = f"{type(exc).__name__}: {exc}"
        return row

    row["latest"] = latest
    row["latestSpec"] = f"{us.NCBI_HUMAN_FILTER_DIR}human_filter.db.{latest}"
    row["status"] = (
        STATUS_SAME if str(entry.get("version")) == latest else STATUS_UPDATE
    )
    return row


def _taxonomy_candidate(entry, fetcher):
    row = _row(
        entry.get("id", ""),
        "database",
        entry.get("version"),
        releaseNotesURL=us.NCBI_TAXDUMP_ARCHIVE,
    )
    try:
        latest = us.ncbi_taxdump_latest(fetcher)
    except us.FetchError as exc:
        row["notes"] = str(exc)
        return row
    except Exception as exc:
        row["notes"] = f"{type(exc).__name__}: {exc}"
        return row

    row["latest"] = latest["version"]
    row["latestSpec"] = latest["url"]
    row["notes"] = f"md5: {latest['md5_url']}"
    row["status"] = (
        STATUS_SAME if str(entry.get("version")) == latest["version"] else STATUS_UPDATE
    )
    return row


def _esviritu_db_candidate(entry, fetcher):
    row = _row(
        entry.get("id", ""),
        "database",
        entry.get("version"),
        releaseNotesURL=f"https://zenodo.org/records/{ESVIRITU_ZENODO_RECORD}",
    )
    try:
        files = us.zenodo_record_files(ESVIRITU_ZENODO_RECORD, fetcher)
    except us.FetchError as exc:
        row["notes"] = str(exc)
        return row
    except Exception as exc:
        row["notes"] = f"{type(exc).__name__}: {exc}"
        return row

    tarballs = [
        f
        for f in files
        if f["name"].startswith("esviritu_db_v") and f["name"].endswith(".tar.gz")
    ]
    if not tarballs:
        row["notes"] = f"no esviritu_db_v*.tar.gz on Zenodo record {ESVIRITU_ZENODO_RECORD}"
        return row

    newest = max(
        tarballs,
        key=lambda f: us.ComparableVersion(
            f["name"][len("esviritu_db_v") : -len(".tar.gz")]
        ),
    )
    version = "v" + newest["name"][len("esviritu_db_v") : -len(".tar.gz")]
    row["latest"] = version
    row["latestSpec"] = (
        f"https://zenodo.org/records/{ESVIRITU_ZENODO_RECORD}/files/{newest['name']}"
    )
    row["notes"] = newest["checksum"]
    row["status"] = (
        STATUS_SAME if str(entry.get("version")) == version else STATUS_UPDATE
    )
    return row


def _manual_database_candidate(entry):
    row = _row(
        entry.get("id", ""),
        "database",
        entry.get("version"),
        releaseNotesURL=entry.get("releasesUrl") or entry.get("sourceUrl"),
    )
    row["status"] = STATUS_MANUAL
    row["latestSpec"] = entry.get("releasesUrl") or entry.get("sourceUrl") or ""
    row["notes"] = "manual check: no machine-readable index; follow the releases URL"
    return row


def _database_candidate(entry, kraken_dates, fetcher):
    tool = entry.get("tool")
    entry_id = entry.get("id", "")
    if tool == "kraken2":
        return _kraken2_candidate(entry, kraken_dates, fetcher)
    if tool == "sra-human-scrubber":
        return _human_scrubber_candidate(entry, fetcher)
    if tool == "ncbi-taxonomy":
        return _taxonomy_candidate(entry, fetcher)
    if entry_id.startswith("esviritu"):
        return _esviritu_db_candidate(entry, fetcher)
    return _manual_database_candidate(entry)


# --------------------------------------------------------------------------
# bootstrap


def _bootstrap_candidate(bootstrap, fetcher):
    micromamba = (bootstrap or {}).get("micromamba") or {}
    row = _row(
        "micromamba",
        "bootstrap",
        micromamba.get("version"),
        releaseNotesURL="https://github.com/mamba-org/micromamba-releases/releases",
    )
    try:
        latest = us.micromamba_latest(fetcher)
    except us.FetchError as exc:
        row["notes"] = str(exc)
        return row
    except Exception as exc:
        row["notes"] = f"{type(exc).__name__}: {exc}"
        return row

    row["latest"] = latest["version"]
    row["latestSpec"] = latest["sha256_url"]
    row["status"] = (
        STATUS_SAME
        if str(micromamba.get("version")) == latest["version"]
        else STATUS_UPDATE
    )
    return row


# --------------------------------------------------------------------------
# public API


def build_candidates(manifest, fetcher, only=None):
    """Compare every manifest pin against its upstream source."""
    tools = []
    for entry in manifest.get("tools") or []:
        entry_id = entry.get("id", "")
        if _selected(entry_id, only):
            tools.append(_tool_candidate(entry, "tool", entry_id, fetcher))
    for entry in manifest.get("packTools") or []:
        entry_id = f"{entry.get('packID', '')}/{entry.get('id', '')}"
        if _selected(entry_id, only):
            tools.append(_tool_candidate(entry, "packTool", entry_id, fetcher))

    pipelines = [
        _pipeline_candidate(entry, fetcher)
        for entry in manifest.get("pipelines") or []
        if _selected(entry.get("id", ""), only)
    ]

    database_entries = [
        entry
        for entry in manifest.get("databases") or []
        if _selected(entry.get("id", ""), only)
    ]
    kraken_dates = {}
    if any(entry.get("tool") == "kraken2" for entry in database_entries):
        try:
            kraken_dates = us.kraken2_latest_dates(fetcher)
        except us.FetchError as exc:
            kraken_dates = exc
        except Exception as exc:  # pragma: no cover - defensive
            kraken_dates = us.FetchError(f"{type(exc).__name__}: {exc}")
    databases = [
        _database_candidate(entry, kraken_dates, fetcher) for entry in database_entries
    ]

    bootstrap = None
    if _selected("micromamba", only):
        bootstrap = _bootstrap_candidate(manifest.get("bootstrap"), fetcher)

    return {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "dependencySet": manifest.get("dependencySet"),
        "tools": tools,
        "pipelines": pipelines,
        "databases": databases,
        "bootstrap": bootstrap,
    }


def _all_rows(candidates):
    rows = list(candidates.get("tools") or [])
    rows += list(candidates.get("pipelines") or [])
    rows += list(candidates.get("databases") or [])
    if candidates.get("bootstrap"):
        rows.append(candidates["bootstrap"])
    return rows


def _cell(value):
    if value in (None, ""):
        return "-"
    return str(value).replace("|", "\\|")


def render_markdown(candidates):
    """Render the candidate set as a Markdown report."""
    lines = [
        f"# Upstream candidates for dependency set {candidates.get('dependencySet')}",
        "",
        f"Generated {candidates.get('generatedAt')}.",
        "",
        "| " + " | ".join(MARKDOWN_COLUMNS) + " |",
        "| " + " | ".join(["---"] * len(MARKDOWN_COLUMNS)) + " |",
    ]
    for row in _all_rows(candidates):
        lines.append(
            "| "
            + " | ".join(
                _cell(row.get(key))
                for key in (
                    "id",
                    "kind",
                    "current",
                    "latest",
                    "latestSpec",
                    "status",
                    "notes",
                )
            )
            + " |"
        )

    counts = {}
    for row in _all_rows(candidates):
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    lines += [
        "",
        "Summary: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + ".",
        "",
    ]
    return "\n".join(lines)


def main(argv=None, fetcher=None):
    parser = argparse.ArgumentParser(
        description="Report candidate upstream versions for pinned dependencies."
    )
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--json", dest="json_out", default=None)
    parser.add_argument("--markdown", dest="markdown_out", default=None)
    parser.add_argument(
        "--only",
        default=None,
        help="comma-separated candidate ids to check (pack tools use pack/tool)",
    )
    args = parser.parse_args(argv)

    only = None
    if args.only is not None:
        only = {part.strip() for part in args.only.split(",") if part.strip()}
        if not only:
            parser.error("--only needs at least one candidate id")

    manifest = json.loads(pathlib.Path(args.manifest).read_text(encoding="utf-8"))
    candidates = build_candidates(manifest, fetcher or us.LiveFetcher(), only=only)

    if args.json_out:
        pathlib.Path(args.json_out).write_text(
            json.dumps(candidates, indent=2) + "\n", encoding="utf-8"
        )
    markdown = render_markdown(candidates)
    if args.markdown_out:
        pathlib.Path(args.markdown_out).write_text(markdown, encoding="utf-8")
    if not args.json_out and not args.markdown_out:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
