#!/usr/bin/env python3
"""Upstream version sources for the dependency sweep.

Every network or subprocess access is funnelled through a ``Fetcher``, so the
callers (and the tests) can substitute a fake and stay hermetic. ``LiveFetcher``
is the real implementation: ``urllib`` for HTTP, the locally installed
micromamba for conda repodata queries.

Stdlib only; no third-party imports.
"""

import functools
import json
import os
import pathlib
import re
import subprocess
import urllib.error
import urllib.request

USER_AGENT = "lungfish-dependency-sweep/1.0 (+https://github.com/dhoconno/lungfish)"
HTTP_TIMEOUT = 20

KRAKEN2_BASE = "https://genome-idx.s3.amazonaws.com/kraken"
KRAKEN2_INDEX_PAGE = "https://benlangmead.github.io/aws-indexes/k2"
NCBI_HUMAN_FILTER_DIR = "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/"
NCBI_TAXDUMP_ARCHIVE = "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump_archive/"
MICROMAMBA_RELEASES_LATEST = (
    "https://api.github.com/repos/mamba-org/micromamba-releases/releases/latest"
)
ZENODO_RECORD = "https://zenodo.org/api/records/{record}"

# Kraken2 collections we track, mapped to the S3 filename stem(s) to probe. The
# aws-indexes page lags the bucket for the size-capped collections (it still
# lists ``08gb`` long after the bucket switched to ``08_GB``), so each capped
# collection probes both spellings and keeps whichever answers 200.
KRAKEN2_COLLECTIONS = {
    "standard": ["k2_standard_{date}"],
    "standard-8": ["k2_standard_08_GB_{date}", "k2_standard_08gb_{date}"],
    "standard-16": ["k2_standard_16_GB_{date}", "k2_standard_16gb_{date}"],
    "pluspf": ["k2_pluspf_{date}"],
    "pluspf-8": ["k2_pluspf_08_GB_{date}", "k2_pluspf_08gb_{date}"],
    "pluspf-16": ["k2_pluspf_16_GB_{date}", "k2_pluspf_16gb_{date}"],
    "viral": ["k2_viral_{date}"],
    "minus-b": ["k2_minusb_{date}"],
    "eupathdb46": ["k2_eupathdb48_{date}"],
}

# The newest date advertised for a capped collection is taken from its uncapped
# sibling, because the page's own capped listings go stale.
KRAKEN2_DATE_SOURCE = {
    "standard-8": "standard",
    "standard-16": "standard",
    "pluspf-8": "pluspf",
    "pluspf-16": "pluspf",
}

# EuPathDB has been frozen upstream since 2023; keep the pin unless a probe of a
# newer date actually succeeds.
KRAKEN2_EUPATHDB_PINNED_DATE = "20230407"


class FetchError(RuntimeError):
    """Raised when an upstream source cannot be read."""


# --------------------------------------------------------------------------
# fetchers


class LiveFetcher:
    """Real network + micromamba access."""

    def __init__(self, conda_root=None):
        self.conda_root = pathlib.Path(
            conda_root
            or os.environ.get("LUNGFISH_CONDA_ROOT")
            or (pathlib.Path.home() / ".lungfish" / "conda")
        )
        self._search_cache = {}

    def _request(self, url, method):
        return urllib.request.Request(
            url, method=method, headers={"User-Agent": USER_AGENT}
        )

    def get_text(self, url):
        try:
            with urllib.request.urlopen(
                self._request(url, "GET"), timeout=HTTP_TIMEOUT
            ) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                return response.read().decode(charset, errors="replace")
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise FetchError(f"GET {url}: {exc}") from exc

    def head_ok(self, url):
        try:
            with urllib.request.urlopen(
                self._request(url, "HEAD"), timeout=HTTP_TIMEOUT
            ) as response:
                return 200 <= response.status < 300
        except urllib.error.HTTPError as exc:
            if exc.code in (403, 405, 501):
                return self._ranged_get_ok(url)
            return False
        except (urllib.error.URLError, OSError, ValueError):
            return False

    def _ranged_get_ok(self, url):
        """Fall back to a 1-byte ranged GET when the server refuses HEAD."""
        request = self._request(url, "GET")
        request.add_header("Range", "bytes=0-0")
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
                return 200 <= response.status < 300
        except (urllib.error.URLError, OSError, ValueError):
            return False

    @property
    def micromamba(self):
        return self.conda_root / "bin" / "micromamba"

    def micromamba_search(self, package, platform):
        cached = self._search_cache.get((package, platform))
        if cached is not None:
            return cached
        if not self.micromamba.exists():
            raise FetchError(f"micromamba not found at {self.micromamba}")
        command = [
            str(self.micromamba),
            "search",
            "-c",
            "bioconda",
            "-c",
            "conda-forge",
            "--platform",
            platform,
            package,
            "--json",
        ]
        try:
            completed = subprocess.run(
                command, capture_output=True, text=True, timeout=180, check=False
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise FetchError(f"micromamba search {package}: {exc}") from exc
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout or "").strip()[:300]
            raise FetchError(
                f"micromamba search {package} ({platform}) failed: {detail}"
            )
        try:
            parsed = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise FetchError(f"micromamba search {package}: bad JSON: {exc}") from exc
        self._search_cache[(package, platform)] = parsed
        return parsed


# --------------------------------------------------------------------------
# version comparison


_VERSION_SPLIT = re.compile(r"[.\-_+]")


def version_key(version):
    """PEP440-ish sort key: numeric segments compare as numbers, not strings.

    Each segment becomes ``(1, int, "")`` for a pure number or ``(-1, 0, text)``
    for anything else, so ``2.17.1 > 2.1.6`` and ``40.02 > 39.80``. The negative
    rank makes an alphabetic suffix a pre-release marker, sorting below the
    ``_RELEASE_MARKER`` that ``compare_versions`` pads with: ``1.0.0 > 1.0.0rc1``.

    Compare two versions with ``compare_versions``, not by comparing two raw
    keys, since only the padded form handles differing segment counts.
    """
    key = []
    for segment in _VERSION_SPLIT.split(str(version)):
        if not segment:
            continue
        if segment.isdigit():
            key.append((1, int(segment), ""))
            continue
        # Split a mixed segment such as "0rc1" into its numeric head and tail so
        # the numeric part still compares numerically, and the tail sorts below
        # the release marker appended by _padded_key.
        match = re.match(r"^(\d+)(.*)$", segment)
        if match:
            key.append((1, int(match.group(1)), ""))
            key.append((-1, 0, match.group(2).lower()))
        else:
            key.append((-1, 0, segment.lower()))
    return tuple(key)


# Sorts above any pre-release suffix (-1, ...) and below any real segment.
_RELEASE_MARKER = (0, 0, "")


def _padded_key(version, length):
    key = version_key(version)
    return key + (_RELEASE_MARKER,) * (length - len(key))


def compare_versions(left, right):
    """Three-way comparison of two version strings using ``version_key``.

    Keys are padded to equal length so a bare release compares correctly
    against a longer pre-release of the same version.
    """
    length = max(len(version_key(left)), len(version_key(right)))
    left_key = _padded_key(left, length)
    right_key = _padded_key(right, length)
    if left_key < right_key:
        return -1
    return 1 if left_key > right_key else 0


@functools.total_ordering
class ComparableVersion:
    """Wraps a version string so ``max``/``sorted`` use ``compare_versions``."""

    __slots__ = ("value",)

    def __init__(self, value):
        self.value = str(value or "")

    def __eq__(self, other):
        return compare_versions(self.value, other.value) == 0

    def __lt__(self, other):
        return compare_versions(self.value, other.value) < 0


def _package_sort_key(pkg):
    return (
        ComparableVersion(pkg.get("version", "")),
        int(pkg.get("build_number", 0) or 0),
        pkg.get("build", ""),
    )


# --------------------------------------------------------------------------
# conda


def _channel_name(pkg):
    """Reduce a repodata channel URL to its bare channel name."""
    channel = str(pkg.get("channel", "") or "")
    for known in ("bioconda", "conda-forge"):
        if known in channel:
            return known
    return channel.rstrip("/").split("/")[-1] or "bioconda"


def _best_for_platform(pkg_name, channel_hint, platform, fetcher):
    # Any failure for a single platform is treated as "nothing here": a missing
    # subdir must never sink the whole lookup.
    try:
        payload = fetcher.micromamba_search(pkg_name, platform)
    except Exception:
        return None
    packages = ((payload or {}).get("result") or {}).get("pkgs") or []
    packages = [p for p in packages if p.get("name") == pkg_name]
    if channel_hint:
        matching = [p for p in packages if _channel_name(p) == channel_hint]
        packages = matching or packages
    return max(packages, key=_package_sort_key) if packages else None


def latest_conda(pkg_name, channel_hint, fetcher):
    """Newest installable build of ``pkg_name``, preferring osx-arm64 over noarch.

    Returns ``{"version","build","subdir","channel","build_number",
    "linuxOnlyVersion"}`` or None when neither subdir carries the package.

    ``linuxOnlyVersion`` is set when bioconda publishes a strictly newer version
    that has no osx-arm64 or noarch build (bracken 3.x is the live example).
    Without it the sweep would report a comfortable ``same`` while upstream had
    moved several major versions ahead on Linux only.
    """
    by_subdir = {}
    for platform in ("osx-arm64", "noarch"):
        best = _best_for_platform(pkg_name, channel_hint, platform, fetcher)
        if best is not None:
            by_subdir[platform] = best

    if not by_subdir:
        return None

    # Prefer the native build; fall back to noarch only when arm64 has none, or
    # when noarch actually ships a strictly newer version.
    best = by_subdir.get("osx-arm64") or by_subdir["noarch"]
    noarch = by_subdir.get("noarch")
    if noarch is not None and _package_sort_key(noarch) > _package_sort_key(best):
        best = noarch

    linux_only = None
    linux_best = _best_for_platform(pkg_name, channel_hint, "linux-64", fetcher)
    if linux_best is not None and compare_versions(
        linux_best.get("version", ""), best.get("version", "")
    ) > 0:
        linux_only = linux_best.get("version")

    return {
        "version": best.get("version"),
        "build": best.get("build") or best.get("build_string"),
        "build_number": int(best.get("build_number", 0) or 0),
        "subdir": best.get("subdir"),
        "channel": _channel_name(best),
        "linuxOnlyVersion": linux_only,
    }


# --------------------------------------------------------------------------
# github


_SEMVER_TAG = re.compile(r"^v?\d+(\.\d+)*")


def latest_github_release(repo, fetcher):
    """Highest semver tag for ``repo`` with its commit sha.

    Uses the tags API (which carries the sha directly) and falls back to the
    releases API when tags are unavailable.
    """
    url = f"https://api.github.com/repos/{repo}/tags?per_page=20"
    try:
        tags = json.loads(fetcher.get_text(url))
    except (FetchError, KeyError, json.JSONDecodeError):
        tags = None

    if tags:
        semver = [t for t in tags if _SEMVER_TAG.match(str(t.get("name", "")))]
        if semver:
            best = max(semver, key=lambda t: ComparableVersion(t["name"].lstrip("v")))
            return {
                "tag": best["name"],
                "sha": (best.get("commit") or {}).get("sha", ""),
                "published_at": None,
            }

    releases_url = f"https://api.github.com/repos/{repo}/releases/latest"
    try:
        release = json.loads(fetcher.get_text(releases_url))
    except (FetchError, KeyError, json.JSONDecodeError):
        return None
    if not release.get("tag_name"):
        return None
    return {
        "tag": release["tag_name"],
        "sha": "",
        "published_at": release.get("published_at"),
    }


# --------------------------------------------------------------------------
# kraken2


_K2_LINK = re.compile(r"k2_([A-Za-z0-9_]+?)_(\d{8})\.tar\.gz")


def _kraken2_page_dates(fetcher):
    """Newest advertised date per S3 filename stem, from the aws-indexes page."""
    text = fetcher.get_text(KRAKEN2_INDEX_PAGE)
    newest = {}
    for stem, date in _K2_LINK.findall(text):
        key = stem.lower()
        if date > newest.get(key, ""):
            newest[key] = date
    return newest


def _stem_key(template):
    """The lookup key a probe template maps to on the index page."""
    return template.replace("_{date}", "")[len("k2_") :].lower()


def kraken2_latest_dates(fetcher):
    """Collection -> ``{"date","url"}`` for the newest index that really exists.

    The published index page is authoritative for *dates* but not for the
    size-capped filenames, so each candidate URL is HEAD-probed and only a
    responding URL is reported.
    """
    page_dates = _kraken2_page_dates(fetcher)
    latest = {}

    for collection, templates in KRAKEN2_COLLECTIONS.items():
        if collection == "eupathdb46":
            candidate_dates = sorted(
                {
                    page_dates.get(_stem_key(templates[0]), ""),
                    KRAKEN2_EUPATHDB_PINNED_DATE,
                }
                - {""},
                reverse=True,
            )
        else:
            source = KRAKEN2_DATE_SOURCE.get(collection, collection)
            source_templates = KRAKEN2_COLLECTIONS[source]
            dates = {page_dates.get(_stem_key(t), "") for t in source_templates}
            dates |= {page_dates.get(_stem_key(t), "") for t in templates}
            candidate_dates = sorted(dates - {""}, reverse=True)

        for date in candidate_dates:
            url = _probe_kraken2_date(templates, date, fetcher)
            if url:
                latest[collection] = {"date": date, "url": url}
                break

    return latest


def _probe_kraken2_date(templates, date, fetcher):
    for template in templates:
        url = f"{KRAKEN2_BASE}/{template.format(date=date)}.tar.gz"
        if fetcher.head_ok(url):
            return url
    return None


# --------------------------------------------------------------------------
# ncbi


_HUMAN_FILTER = re.compile(r"human_filter\.db\.(\d{8}v\d+)(?![\w.])")


def ncbi_human_filter_latest(fetcher):
    """Newest ``human_filter.db.<date>v<n>`` release, e.g. ``20260706v2``."""
    text = fetcher.get_text(NCBI_HUMAN_FILTER_DIR)
    versions = set(_HUMAN_FILTER.findall(text))
    if not versions:
        raise FetchError("no human_filter.db.<date>v<n> entries in the NCBI listing")
    return max(versions, key=ComparableVersion)


_TAXDMP = re.compile(r"taxdmp_(\d{4}-\d{2}-\d{2})\.zip")


def ncbi_taxdump_latest(fetcher):
    """Newest ``taxdmp_YYYY-MM-DD.zip`` in the taxdump archive, plus its md5."""
    text = fetcher.get_text(NCBI_TAXDUMP_ARCHIVE)
    dates = sorted(set(_TAXDMP.findall(text)))
    if not dates:
        raise FetchError("no taxdmp_YYYY-MM-DD.zip entries in the taxdump archive")
    newest = dates[-1]
    url = f"{NCBI_TAXDUMP_ARCHIVE}taxdmp_{newest}.zip"
    return {"version": newest, "url": url, "md5_url": url + ".md5"}


# --------------------------------------------------------------------------
# micromamba


def micromamba_latest(fetcher):
    """Latest micromamba-releases tag, with the osx-arm64 sha256 sidecar URL."""
    release = json.loads(fetcher.get_text(MICROMAMBA_RELEASES_LATEST))
    tag = release.get("tag_name")
    if not tag:
        raise FetchError("micromamba releases/latest carried no tag_name")
    sha_url = ""
    for asset in release.get("assets") or []:
        name = asset.get("name", "")
        if name.endswith("micromamba-osx-arm64.sha256") or name == "micromamba-osx-arm64.sha256":
            sha_url = asset.get("browser_download_url", "")
            break
    if not sha_url:
        sha_url = (
            "https://github.com/mamba-org/micromamba-releases/releases/download/"
            f"{tag}/micromamba-osx-arm64.sha256"
        )
    return {
        "version": tag,
        "sha256_url": sha_url,
        "published_at": release.get("published_at"),
    }


# --------------------------------------------------------------------------
# zenodo


def zenodo_record_files(record, fetcher):
    """Files attached to a Zenodo record: ``[{"name","checksum","url"}]``."""
    payload = json.loads(fetcher.get_text(ZENODO_RECORD.format(record=record)))
    files = []
    for entry in payload.get("files") or []:
        files.append(
            {
                "name": entry.get("key") or entry.get("filename") or "",
                "checksum": entry.get("checksum") or "",
                "url": (entry.get("links") or {}).get("self")
                or (entry.get("links") or {}).get("download")
                or "",
            }
        )
    return files
