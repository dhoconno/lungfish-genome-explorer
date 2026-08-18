#!/usr/bin/env python3
"""Tests for scripts/deps/bump.py and scripts/deps/manifest_io.py."""

import json
import os
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/deps"))

import bump  # noqa: E402
import manifest_io  # noqa: E402
import upstream_sources  # noqa: E402

MANIFEST = ROOT / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"
TOOL_VERSIONS = ROOT / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"
NOTICES = ROOT / "THIRD-PARTY-NOTICES"


def sample_manifest():
    return {
        "packID": "lungfish-tools",
        "version": "0.5.0-beta30",
        "dependencySet": "2026.1",
        "dependencySetDate": "2026-08-17",
        "tools": [
            {
                "id": "samtools",
                "environment": "samtools",
                "packageSpec": "bioconda::samtools=1.23.1=hc612e98_0",
                "executables": ["samtools"],
                "version": "1.23.1",
                "license": "MIT",
                "sourceUrl": "https://github.com/samtools/samtools",
            },
            {
                "id": "seqkit",
                "environment": "seqkit",
                "packageSpec": "bioconda::seqkit=2.13.0=hd5f1084_0",
                "executables": ["seqkit"],
                "version": "2.13.0",
                "license": "MIT",
                "sourceUrl": "https://github.com/shenwei356/seqkit",
            },
        ],
        "packTools": [
            {
                "packID": "read-mapping",
                "id": "minimap2",
                "environment": "minimap2",
                "packageSpec": "bioconda::minimap2=2.30=hba9b596_0",
                "executables": ["minimap2"],
                "version": "2.30",
                "license": "MIT",
                "sourceUrl": "https://github.com/lh3/minimap2",
            }
        ],
        "pipelines": [
            {
                "id": "taxtriage",
                "repository": "jhuapl-bio/taxtriage",
                "revision": "old",
                "releaseVersion": "v3.3.6",
            }
        ],
        "databases": [
            {
                "id": "human-scrubber",
                "tool": "sra-human-scrubber",
                "displayName": "HS",
                "version": "20250916v2",
                "filename": "human_filter.db.20250916v2",
                "url": "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20250916v2",
            },
            {
                "id": "kraken2-standard-8",
                "tool": "kraken2",
                "collection": "standard-8",
                "displayName": "Standard-8",
                "version": "20240904",
                "url": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240904.tar.gz",
            },
        ],
        "bootstrap": {"micromamba": {"version": "2.0.5-0", "sha256": {}}},
        "retiredEnvironments": [],
    }


def sample_candidates():
    return {
        "tools": [
            {
                "id": "samtools",
                "kind": "tool",
                "status": "update",
                "current": "1.23.1",
                "latest": "1.24",
                "latestSpec": "bioconda::samtools=1.24=h36b3a25_1",
            },
            {
                "id": "seqkit",
                "kind": "tool",
                "status": "same",
                "current": "2.13.0",
                "latest": "2.13.0",
                "latestSpec": "bioconda::seqkit=2.13.0=hd5f1084_0",
            },
            {
                "id": "read-mapping/minimap2",
                "kind": "packTool",
                "status": "update",
                "current": "2.30",
                "latest": "2.31",
                "latestSpec": "bioconda::minimap2=2.31=h6bd33b9_0",
            },
        ],
        "pipelines": [
            {
                "id": "taxtriage",
                "status": "update",
                "latest": "v3.3.8",
                "latestSha": "e10bfebda32a62711f38a4e23ab03b61725a9675",
            }
        ],
        "databases": [
            {
                "id": "human-scrubber",
                "status": "update",
                "latest": "20260706v2",
                "latestFilename": "human_filter.db.20260706v2",
                "latestURL": "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20260706v2",
            },
            {
                "id": "kraken2-standard-8",
                "status": "update",
                "latest": "20260626",
                "latestURL": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08_GB_20260626.tar.gz",
            },
        ],
        "bootstrap": {"id": "micromamba", "status": "update", "latest": "2.9.0-0"},
    }


class FakeFetcher:
    """Minimal stand-in for upstream_sources.LiveFetcher.

    Mirrors the live protocol: ``get_text`` (JSON endpoints included) plus
    ``head_ok``, with ``get_bytes`` for the micromamba binary fallback.
    """

    def __init__(self, json_payloads=None, texts=None, binaries=None):
        self.texts = dict(texts or {})
        for url, payload in (json_payloads or {}).items():
            self.texts[url] = json.dumps(payload)
        self.binaries = binaries or {}
        self.requested = []

    def get_text(self, url):
        self.requested.append(url)
        if url not in self.texts:
            raise upstream_sources.FetchError(f"GET {url}: not stubbed")
        return self.texts[url]

    def get_bytes(self, url):
        self.requested.append(url)
        if url not in self.binaries:
            raise upstream_sources.FetchError(f"GET {url}: not stubbed")
        return self.binaries[url]

    def head_ok(self, url):
        return url in self.texts or url in self.binaries


class ManifestIOTests(unittest.TestCase):
    def test_manifest_io_round_trips_current_file_byte_for_byte(self):
        manifest = manifest_io.load(MANIFEST)
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "lock.json"
            manifest_io.dump(manifest, out)
            self.assertEqual(out.read_text(encoding="utf-8"), MANIFEST.read_text(encoding="utf-8"))

    def test_dump_preserves_top_level_key_order_and_new_keys(self):
        manifest = manifest_io.load(MANIFEST)
        manifest["dependencySet"] = "2026.2"
        with tempfile.TemporaryDirectory() as td:
            out = pathlib.Path(td) / "lock.json"
            manifest_io.dump(manifest, out)
            text = out.read_text(encoding="utf-8")
            self.assertIn('"dependencySet": "2026.2"', text)
            keys = [k for k in ("packID", "tools", "packTools", "pipelines", "databases", "bootstrap")]
            positions = [text.index(f'"{k}"') for k in keys]
            self.assertEqual(positions, sorted(positions))
            self.assertEqual(json.loads(text)["tools"], manifest["tools"])


class ApplyBumpsTests(unittest.TestCase):
    def test_apply_bumps_updates_spec_version_and_set(self):
        m = sample_manifest()
        c = sample_candidates()
        new, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold={"read-mapping/minimap2"}
        )
        self.assertEqual(new["dependencySet"], "2026.2")
        self.assertEqual(new["dependencySetDate"], "2026-08-20")
        self.assertEqual(new["tools"][0]["packageSpec"], "bioconda::samtools=1.24=h36b3a25_1")
        self.assertEqual(new["tools"][0]["version"], "1.24")
        self.assertEqual(new["tools"][1]["packageSpec"], "bioconda::seqkit=2.13.0=hd5f1084_0")
        self.assertEqual(new["packTools"][0]["version"], "2.30", "held")
        self.assertEqual(
            new["pipelines"][0]["revision"], "e10bfebda32a62711f38a4e23ab03b61725a9675"
        )
        self.assertEqual(new["pipelines"][0]["releaseVersion"], "v3.3.8")
        self.assertEqual(new["databases"][0]["version"], "20260706v2")
        self.assertEqual(new["databases"][0]["filename"], "human_filter.db.20260706v2")
        self.assertIn("08_GB_20260626", new["databases"][1]["url"])
        self.assertEqual(new["databases"][1]["version"], "20260626")
        self.assertEqual(new["bootstrap"]["micromamba"]["version"], "2.9.0-0")
        self.assertTrue(any("samtools" in line for line in log))

    def test_apply_bumps_does_not_mutate_the_input_manifest(self):
        m = sample_manifest()
        before = json.dumps(m, sort_keys=True)
        bump.apply_bumps(
            m, sample_candidates(), new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertEqual(json.dumps(m, sort_keys=True), before)

    def test_only_filters_to_the_named_ids(self):
        m = sample_manifest()
        new, log = bump.apply_bumps(
            m,
            sample_candidates(),
            new_set="2026.2",
            date="2026-08-20",
            only={"samtools"},
            hold=set(),
        )
        self.assertEqual(new["tools"][0]["version"], "1.24")
        self.assertEqual(new["packTools"][0]["version"], "2.30")
        self.assertEqual(new["pipelines"][0]["releaseVersion"], "v3.3.6")
        self.assertEqual(new["bootstrap"]["micromamba"]["version"], "2.0.5-0")
        self.assertTrue(any("skipped" in line and "minimap2" in line for line in log))

    def test_non_update_statuses_are_skipped_and_logged(self):
        m = sample_manifest()
        c = sample_candidates()
        c["tools"][0]["status"] = "no-arm64-build"
        c["tools"][2]["status"] = "error"
        c["pipelines"][0]["status"] = "manual-check"
        new, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertEqual(new["tools"][0]["version"], "1.23.1")
        self.assertEqual(new["packTools"][0]["version"], "2.30")
        self.assertEqual(new["pipelines"][0]["releaseVersion"], "v3.3.6")
        self.assertTrue(any("skipped: no-arm64-build" in line for line in log))
        self.assertTrue(any("skipped: error" in line for line in log))
        self.assertTrue(any("skipped: manual-check" in line for line in log))

    def test_held_tool_takes_a_newer_build_of_the_same_version(self):
        m = sample_manifest()
        c = sample_candidates()
        c["tools"][0]["latest"] = "1.23.1"
        c["tools"][0]["latestSpec"] = "bioconda::samtools=1.23.1=hc612e98_3"
        new, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold={"samtools"}
        )
        self.assertEqual(new["tools"][0]["packageSpec"], "bioconda::samtools=1.23.1=hc612e98_3")
        self.assertEqual(new["tools"][0]["version"], "1.23.1")
        self.assertTrue(any("build only" in line for line in log))

    def test_held_tool_keeps_its_build_when_take_builds_for_held_is_false(self):
        m = sample_manifest()
        c = sample_candidates()
        c["tools"][0]["latest"] = "1.23.1"
        c["tools"][0]["latestSpec"] = "bioconda::samtools=1.23.1=hc612e98_3"
        new, _ = bump.apply_bumps(
            m,
            c,
            new_set="2026.2",
            date="2026-08-20",
            only=None,
            hold={"samtools"},
            take_builds_for_held=False,
        )
        self.assertEqual(new["tools"][0]["packageSpec"], "bioconda::samtools=1.23.1=hc612e98_0")

    def test_held_tool_never_takes_a_newer_version(self):
        m = sample_manifest()
        new, _ = bump.apply_bumps(
            m,
            sample_candidates(),
            new_set="2026.2",
            date="2026-08-20",
            only=None,
            hold={"samtools"},
            take_builds_for_held=True,
        )
        self.assertEqual(new["tools"][0]["packageSpec"], "bioconda::samtools=1.23.1=hc612e98_0")

    def test_no_changes_leaves_the_dependency_set_alone(self):
        m = sample_manifest()
        c = {"tools": [dict(sample_candidates()["tools"][1])], "pipelines": [], "databases": [], "bootstrap": None}
        new, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertEqual(new["dependencySet"], "2026.1")
        self.assertEqual(new["dependencySetDate"], "2026-08-17")
        self.assertTrue(any("no changes" in line.lower() for line in log))

    def test_force_set_stamps_the_set_even_without_changes(self):
        m = sample_manifest()
        c = {"tools": [], "pipelines": [], "databases": [], "bootstrap": None}
        new, _ = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set(), force_set=True
        )
        self.assertEqual(new["dependencySet"], "2026.2")
        self.assertEqual(new["dependencySetDate"], "2026-08-20")

    def test_retire_appends_environments_without_duplicates(self):
        m = sample_manifest()
        m["retiredEnvironments"] = ["oldtool"]
        c = {"tools": [], "pipelines": [], "databases": [], "bootstrap": None}
        new, log = bump.apply_bumps(
            m,
            c,
            new_set="2026.2",
            date="2026-08-20",
            only=None,
            hold=set(),
            retire={"oldtool", "seqkit"},
        )
        self.assertEqual(new["retiredEnvironments"], ["oldtool", "seqkit"])
        self.assertEqual(new["dependencySet"], "2026.2")
        self.assertTrue(any("retire" in line for line in log))

    def test_accepts_the_key_spellings_check_upstream_actually_writes(self):
        """check_upstream emits latestBuild/latestSpec, not latestSha/latestURL."""
        m = sample_manifest()
        c = {
            "tools": [],
            "pipelines": [
                {
                    "id": "taxtriage",
                    "kind": "pipeline",
                    "status": "update",
                    "latest": "v3.3.8",
                    "latestBuild": "e10bfebda32a62711f38a4e23ab03b61725a9675",
                    "latestSpec": "jhuapl-bio/taxtriage@e10bfebda32a62711f38a4e23ab03b61725a9675",
                }
            ],
            "databases": [
                {
                    "id": "kraken2-standard-8",
                    "kind": "database",
                    "status": "update",
                    "latest": "20260626",
                    "latestSpec": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08_GB_20260626.tar.gz",
                },
                {
                    "id": "human-scrubber",
                    "kind": "database",
                    "status": "update",
                    "latest": "20260706v2",
                    "latestSpec": "https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/human_filter.db.20260706v2",
                },
            ],
            "bootstrap": None,
        }
        new, _ = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertEqual(
            new["pipelines"][0]["revision"], "e10bfebda32a62711f38a4e23ab03b61725a9675"
        )
        self.assertIn("08_GB_20260626", new["databases"][1]["url"])
        self.assertEqual(
            new["databases"][0]["filename"], "human_filter.db.20260706v2"
        )

    def test_database_without_a_filename_key_does_not_gain_one(self):
        m = sample_manifest()
        c = {
            "tools": [],
            "pipelines": [],
            "databases": [
                {
                    "id": "kraken2-standard-8",
                    "status": "update",
                    "latest": "20260626",
                    "latestSpec": "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08_GB_20260626.tar.gz",
                }
            ],
            "bootstrap": None,
        }
        new, _ = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertNotIn("filename", new["databases"][1])

    def test_same_version_newer_build_is_logged_as_build_only(self):
        m = sample_manifest()
        c = {
            "tools": [
                {
                    "id": "seqkit",
                    "kind": "tool",
                    "status": "update",
                    "latest": "2.13.0",
                    "latestSpec": "bioconda::seqkit=2.13.0=hd5f1084_4",
                }
            ],
            "pipelines": [],
            "databases": [],
            "bootstrap": None,
        }
        new, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertEqual(new["tools"][1]["packageSpec"], "bioconda::seqkit=2.13.0=hd5f1084_4")
        self.assertTrue(any("seqkit: build only" in line for line in log))

    def test_update_status_with_an_identical_spec_is_a_no_op(self):
        m = sample_manifest()
        c = {
            "tools": [
                {
                    "id": "seqkit",
                    "kind": "tool",
                    "status": "update",
                    "latest": "2.13.0",
                    "latestSpec": "bioconda::seqkit=2.13.0=hd5f1084_0",
                }
            ],
            "pipelines": [],
            "databases": [],
            "bootstrap": None,
        }
        new, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertEqual(new["dependencySet"], "2026.1")
        self.assertTrue(any("no changes" in line.lower() for line in log))

    def test_unknown_candidate_ids_are_reported(self):
        m = sample_manifest()
        c = {
            "tools": [
                {"id": "not-in-manifest", "kind": "tool", "status": "update", "latest": "9.9", "latestSpec": "bioconda::nope=9.9=h0"}
            ],
            "pipelines": [],
            "databases": [],
            "bootstrap": None,
        }
        _, log = bump.apply_bumps(
            m, c, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertTrue(any("not-in-manifest" in line for line in log))


class DerivedFileTests(unittest.TestCase):
    def _scaffold(self, root):
        (root / "Sources/LungfishWorkflow/Resources/Tools").mkdir(parents=True)
        src = json.loads(TOOL_VERSIONS.read_text(encoding="utf-8"))
        (root / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").write_text(
            json.dumps(src), encoding="utf-8"
        )
        (root / "Sources/LungfishWorkflow/Resources/Tools/VERSIONS.txt").write_text(
            "", encoding="utf-8"
        )
        (root / "THIRD-PARTY-NOTICES").write_text(
            NOTICES.read_text(encoding="utf-8"), encoding="utf-8"
        )

    def test_refresh_derived_files_updates_micromamba_version(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            self._scaffold(root)
            m = {
                "tools": [],
                "packTools": [],
                "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}},
            }
            bump.refresh_derived_files(m, root)
            tv = json.loads(
                (root / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertIn("2.9.0-0", json.dumps(tv))

    def test_refresh_derived_files_honours_source_date_epoch(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            self._scaffold(root)
            m = {
                "tools": [],
                "packTools": [],
                "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}},
            }
            old = os.environ.get("SOURCE_DATE_EPOCH")
            os.environ["SOURCE_DATE_EPOCH"] = "1700000000"
            try:
                written = bump.refresh_derived_files(m, root)
            finally:
                if old is None:
                    os.environ.pop("SOURCE_DATE_EPOCH", None)
                else:
                    os.environ["SOURCE_DATE_EPOCH"] = old
            tv = json.loads(
                (root / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(tv["lastUpdated"], "2023-11-14T22:13:20Z")
            versions = (root / "Sources/LungfishWorkflow/Resources/Tools/VERSIONS.txt").read_text(
                encoding="utf-8"
            )
            self.assertIn("- micromamba: 2.9.0-0 (BSD-3-Clause license)", versions)
            self.assertIn("Build date: 2023-11-14 22:13:20 UTC", versions)
            self.assertIn("Build architecture: arm64", versions)
            self.assertEqual(len(written), 3)

    def test_refresh_derived_files_rewrites_the_notices_table_between_markers(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            self._scaffold(root)
            m = sample_manifest()
            bump.refresh_derived_files(m, root)
            text = (root / "THIRD-PARTY-NOTICES").read_text(encoding="utf-8")
            self.assertIn(bump.NOTICES_BEGIN, text)
            self.assertIn(bump.NOTICES_END, text)
            self.assertIn("samtools", text)
            self.assertIn("read-mapping/minimap2", text)
            self.assertIn("https://github.com/lh3/minimap2", text)
            head = text.split(bump.NOTICES_BEGIN)[0]
            self.assertEqual(head, NOTICES.read_text(encoding="utf-8").split(bump.NOTICES_BEGIN)[0])

    def test_notices_refresh_is_idempotent(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            self._scaffold(root)
            m = sample_manifest()
            bump.refresh_derived_files(m, root)
            once = (root / "THIRD-PARTY-NOTICES").read_text(encoding="utf-8")
            bump.refresh_derived_files(m, root)
            twice = (root / "THIRD-PARTY-NOTICES").read_text(encoding="utf-8")
            self.assertEqual(once, twice)

    def test_repo_notices_already_carries_the_markers(self):
        text = NOTICES.read_text(encoding="utf-8")
        self.assertIn(bump.NOTICES_BEGIN, text)
        self.assertIn(bump.NOTICES_END, text)


class ChecksumTests(unittest.TestCase):
    """Digests must belong to the exact artifact the manifest pins.

    A digest fetched for the wrong version is worse than no digest: every
    install then fails verification against a checksum that was never true.
    """

    ZENODO = "https://zenodo.org/api/records/17716199"
    TAXDUMP = "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz"
    RELEASE = "https://github.com/mamba-org/micromamba-releases/releases/download"

    def _fetcher(self, pinned_digest="a" * 64, latest_digest="b" * 64):
        """Serves TWO micromamba releases so a wrong-version read is visible."""
        return FakeFetcher(
            json_payloads={
                self.ZENODO: {
                    "files": [
                        {
                            "key": "esviritu_db_v3.2.4.tar.gz",
                            "checksum": "md5:0123456789abcdef0123456789abcdef",
                        }
                    ]
                },
                "https://api.github.com/repos/mamba-org/micromamba-releases/releases/latest": {
                    "tag_name": "2.9.0-0",
                    "assets": [
                        {
                            "name": "micromamba-osx-arm64.sha256",
                            "browser_download_url": f"{self.RELEASE}/2.9.0-0/micromamba-osx-arm64.sha256",
                        }
                    ],
                },
            },
            texts={
                self.TAXDUMP + ".md5": "fedcba9876543210fedcba9876543210  taxdump.tar.gz\n",
                f"{self.RELEASE}/2.0.5-0/micromamba-osx-arm64.sha256": (
                    pinned_digest + "  micromamba-osx-arm64\n"
                ),
                f"{self.RELEASE}/2.9.0-0/micromamba-osx-arm64.sha256": (
                    latest_digest + "  micromamba-osx-arm64\n"
                ),
            },
        )

    def _manifest(self, micromamba_version="2.9.0-0", sha256=None):
        return {
            "databases": [
                {
                    "id": "esviritu-viral-v3",
                    "version": "v3.2.4",
                    "url": "https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz",
                },
                {
                    "id": "ncbi-taxonomy",
                    "version": "2025-03",
                    "url": self.TAXDUMP,
                },
            ],
            "bootstrap": {
                "micromamba": {
                    "version": micromamba_version,
                    "sha256": dict(sha256 or {}),
                }
            },
        }

    def test_fills_digests_for_the_entries_that_changed(self):
        manifest = self._manifest()
        result = bump.fetch_checksums(
            manifest,
            self._fetcher(),
            changed={"esviritu-viral-v3", "ncbi-taxonomy", "micromamba"},
        )
        self.assertEqual(result["esviritu-viral-v3"], "0123456789abcdef0123456789abcdef")
        self.assertEqual(result["ncbi-taxonomy"], "fedcba9876543210fedcba9876543210")
        self.assertEqual(result["micromamba"], "b" * 64)
        self.assertEqual(
            manifest["databases"][0]["md5"], "0123456789abcdef0123456789abcdef"
        )
        self.assertEqual(
            manifest["bootstrap"]["micromamba"]["sha256"]["osx-arm64"], "b" * 64
        )

    def test_pinned_version_digest_is_used_when_pin_is_not_the_latest(self):
        """The reported defect: a held 2.0.5-0 must not take 2.9.0-0's digest."""
        manifest = self._manifest(micromamba_version="2.0.5-0")
        result = bump.fetch_checksums(
            manifest, self._fetcher(), changed={"micromamba"}
        )
        self.assertEqual(result["micromamba"], "a" * 64)
        self.assertNotEqual(result["micromamba"], "b" * 64)
        self.assertEqual(
            manifest["bootstrap"]["micromamba"]["sha256"]["osx-arm64"], "a" * 64
        )

    def test_held_entries_keep_their_checksum_fields_byte_identical(self):
        original = "a8d78f72db1bdcd24e7758551006610a15beb40a34006b3e3e176085a0dbc780"
        manifest = self._manifest(
            micromamba_version="2.0.5-0", sha256={"osx-arm64": original}
        )
        manifest["databases"][0]["md5"] = "deadbeefdeadbeefdeadbeefdeadbeef"
        before = json.dumps(manifest, sort_keys=True)
        result = bump.fetch_checksums(manifest, self._fetcher(), changed=set())
        self.assertEqual(result, {})
        self.assertEqual(json.dumps(manifest, sort_keys=True), before)
        self.assertEqual(
            manifest["bootstrap"]["micromamba"]["sha256"]["osx-arm64"], original
        )

    def test_unchanged_database_never_gains_a_checksum_key(self):
        """The rolling ncbi-taxonomy URL must not grow an md5 it never had."""
        manifest = self._manifest()
        bump.fetch_checksums(
            manifest, self._fetcher(), changed={"esviritu-viral-v3"}
        )
        taxonomy = [d for d in manifest["databases"] if d["id"] == "ncbi-taxonomy"][0]
        self.assertNotIn("md5", taxonomy)
        self.assertIn("md5", manifest["databases"][0])

    def test_omitting_changed_fetches_nothing(self):
        manifest = self._manifest()
        before = json.dumps(manifest, sort_keys=True)
        self.assertEqual(bump.fetch_checksums(manifest, self._fetcher()), {})
        self.assertEqual(json.dumps(manifest, sort_keys=True), before)

    def test_hashes_the_binary_when_no_sha256_sidecar(self):
        import hashlib

        payload = b"micromamba-binary-bytes"
        binary = f"{self.RELEASE}/2.9.0-0/micromamba-osx-arm64"
        manifest = {
            "databases": [],
            "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}},
        }
        fetcher = FakeFetcher(binaries={binary: payload})
        result = bump.fetch_checksums(manifest, fetcher, changed={"micromamba"})
        self.assertEqual(result["micromamba"], hashlib.sha256(payload).hexdigest())

    def test_records_errors_instead_of_raising(self):
        manifest = {
            "databases": [
                {
                    "id": "ncbi-taxonomy",
                    "version": "2025-03",
                    "url": "https://example.invalid/taxdump.tar.gz",
                }
            ],
            "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}},
        }
        result = bump.fetch_checksums(
            manifest, FakeFetcher(), changed={"ncbi-taxonomy", "micromamba"}
        )
        self.assertTrue(str(result["ncbi-taxonomy"]).startswith("error:"))
        self.assertTrue(str(result["micromamba"]).startswith("error:"))
        self.assertNotIn("md5", manifest["databases"][0])


class MainTests(unittest.TestCase):
    def _copy_repo(self, root):
        (root / "Sources/LungfishWorkflow/Resources/ManagedTools").mkdir(parents=True)
        (root / "Sources/LungfishWorkflow/Resources/Tools").mkdir(parents=True)
        (root / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json").write_text(
            MANIFEST.read_text(encoding="utf-8"), encoding="utf-8"
        )
        (root / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").write_text(
            TOOL_VERSIONS.read_text(encoding="utf-8"), encoding="utf-8"
        )
        (root / "Sources/LungfishWorkflow/Resources/Tools/VERSIONS.txt").write_text(
            "", encoding="utf-8"
        )
        (root / "THIRD-PARTY-NOTICES").write_text(
            NOTICES.read_text(encoding="utf-8"), encoding="utf-8"
        )
        return root / "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json"

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            candidates = root / "candidates.json"
            candidates.write_text(json.dumps(sample_candidates()), encoding="utf-8")
            before = manifest_path.read_text(encoding="utf-8")
            rc = bump.main(
                [
                    "--manifest",
                    str(manifest_path),
                    "--from",
                    str(candidates),
                    "--set",
                    "2026.2",
                    "--date",
                    "2026-08-20",
                    "--no-checksums",
                    "--dry-run",
                ]
            )
            self.assertEqual(rc, 0)
            self.assertEqual(manifest_path.read_text(encoding="utf-8"), before)

    def test_main_writes_the_manifest_and_derived_files(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            candidates = root / "candidates.json"
            candidates.write_text(json.dumps(sample_candidates()), encoding="utf-8")
            rc = bump.main(
                [
                    "--manifest",
                    str(manifest_path),
                    "--from",
                    str(candidates),
                    "--set",
                    "2026.2",
                    "--date",
                    "2026-08-20",
                    "--no-checksums",
                ]
            )
            self.assertEqual(rc, 0)
            written = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(written["dependencySet"], "2026.2")
            self.assertEqual(written["dependencySetDate"], "2026-08-20")
            samtools = [t for t in written["tools"] if t["id"] == "samtools"][0]
            self.assertEqual(samtools["version"], "1.24")
            self.assertEqual(written["bootstrap"]["micromamba"]["version"], "2.9.0-0")
            tv = json.loads(
                (root / "Sources/LungfishWorkflow/Resources/Tools/tool-versions.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(tv["tools"][0]["version"], "2.9.0-0")

    def test_only_run_leaves_every_other_entry_checksum_untouched(self):
        """--only fastp must not rewrite any other entry's digests."""
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            before = json.loads(manifest_path.read_text(encoding="utf-8"))
            candidates = root / "candidates.json"
            candidates.write_text(
                json.dumps(
                    {
                        "tools": [
                            {
                                "id": "fastp",
                                "kind": "tool",
                                "status": "update",
                                "latest": "1.3.6",
                                "latestSpec": "bioconda::fastp=1.3.6=ha1d0559_0",
                            }
                        ],
                        "pipelines": [],
                        "databases": [],
                        "bootstrap": {
                            "id": "micromamba",
                            "status": "update",
                            "latest": "2.9.0-0",
                        },
                    }
                ),
                encoding="utf-8",
            )
            rc = bump.main(
                [
                    "--manifest",
                    str(manifest_path),
                    "--from",
                    str(candidates),
                    "--set",
                    "2026.2",
                    "--date",
                    "2026-08-18",
                    "--only",
                    "fastp",
                    "--no-checksums",
                ]
            )
            self.assertEqual(rc, 0)
            after = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(
                after["bootstrap"]["micromamba"], before["bootstrap"]["micromamba"]
            )
            self.assertEqual(after["databases"], before["databases"])
            fastp = [t for t in after["tools"] if t["id"] == "fastp"][0]
            self.assertEqual(fastp["version"], "1.3.6")

    def test_dry_run_does_not_fetch_checksums(self):
        """A dry run must never hit the network, even without --no-checksums."""
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            candidates = root / "candidates.json"
            candidates.write_text(json.dumps(sample_candidates()), encoding="utf-8")

            calls = []
            original = bump.fetch_checksums
            bump.fetch_checksums = lambda *a, **k: calls.append(a) or {}
            try:
                rc = bump.main(
                    [
                        "--manifest",
                        str(manifest_path),
                        "--from",
                        str(candidates),
                        "--set",
                        "2026.2",
                        "--dry-run",
                    ]
                )
            finally:
                bump.fetch_checksums = original
            self.assertEqual(rc, 0)
            self.assertEqual(calls, [], "dry run fetched checksums")

    def test_repo_root_is_derived_from_the_manifest_location(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            self.assertEqual(
                bump._repo_root_for(manifest_path).resolve(), root.resolve()
            )

    def test_repo_root_falls_back_for_a_manifest_kept_elsewhere(self):
        with tempfile.TemporaryDirectory() as td:
            stray = pathlib.Path(td) / "lock.json"
            stray.write_text("{}", encoding="utf-8")
            self.assertEqual(bump._repo_root_for(stray), bump.ROOT)

    def test_main_rejects_missing_set(self):
        with self.assertRaises(SystemExit) as ctx:
            bump.main(["--from", "/nonexistent.json"])
        self.assertEqual(ctx.exception.code, 64)

    def test_main_returns_1_when_candidates_unreadable(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            rc = bump.main(
                [
                    "--manifest",
                    str(manifest_path),
                    "--from",
                    str(root / "missing.json"),
                    "--set",
                    "2026.2",
                    "--no-checksums",
                    "--dry-run",
                ]
            )
            self.assertEqual(rc, 1)

    def test_main_defaults_the_date_to_today(self):
        import datetime

        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            candidates = root / "candidates.json"
            candidates.write_text(json.dumps(sample_candidates()), encoding="utf-8")
            bump.main(
                [
                    "--manifest",
                    str(manifest_path),
                    "--from",
                    str(candidates),
                    "--set",
                    "2026.2",
                    "--no-checksums",
                ]
            )
            written = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(
                written["dependencySetDate"], datetime.date.today().isoformat()
            )

    def test_main_supports_hold_only_and_retire(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            manifest_path = self._copy_repo(root)
            candidates = root / "candidates.json"
            candidates.write_text(json.dumps(sample_candidates()), encoding="utf-8")
            rc = bump.main(
                [
                    "--manifest",
                    str(manifest_path),
                    "--from",
                    str(candidates),
                    "--set",
                    "2026.2",
                    "--date",
                    "2026-08-20",
                    "--hold",
                    "samtools",
                    "--retire",
                    "oldenv",
                    "--no-checksums",
                ]
            )
            self.assertEqual(rc, 0)
            written = json.loads(manifest_path.read_text(encoding="utf-8"))
            samtools = [t for t in written["tools"] if t["id"] == "samtools"][0]
            self.assertEqual(samtools["version"], "1.23.1")
            self.assertEqual(written["retiredEnvironments"], ["oldenv"])


class ReleaseDateFromVersionTests(unittest.TestCase):
    """Dated database version pins settle the manifest's ``releaseDate``.

    Several database pins are dated builds, not semantic versions, so the version
    already states when the database was built. Leaving releaseDate to be edited
    by hand let it drift: the shipped human-scrubber entry still read 2025-09-16
    after being bumped to the 20260706v2 build.
    """

    def test_compact_date_version(self):
        self.assertEqual(bump.release_date_from_version("20260626"), "2026-06-26")

    def test_hyphenated_date_version(self):
        self.assertEqual(bump.release_date_from_version("2026-07-06"), "2026-07-06")

    def test_date_with_a_rebuild_counter(self):
        # The human-scrubber form: a database rebuilt the same day it was first
        # published. The counter is not part of the date.
        self.assertEqual(bump.release_date_from_version("20260706v2"), "2026-07-06")
        self.assertEqual(bump.release_date_from_version("2026-07-06v11"), "2026-07-06")

    def test_versions_that_carry_no_date_are_left_alone(self):
        for version in [
            "panhuman-1",
            "v3.2.4",
            "bbmap-ribokmers-k31w15",
            "kraken2-special-v1",
            "2.0.5-0",
            "",
            "2026",
            "202606261",
        ]:
            with self.subTest(version=version):
                self.assertIsNone(bump.release_date_from_version(version))

    def test_impossible_dates_are_not_manufactured(self):
        # An eight-digit string is not automatically a date.
        for version in ["20261301", "20260632", "00000000"]:
            with self.subTest(version=version):
                self.assertIsNone(bump.release_date_from_version(version))

    def test_non_string_versions_are_left_alone(self):
        for version in [None, 20260626, ["20260626"]]:
            with self.subTest(version=version):
                self.assertIsNone(bump.release_date_from_version(version))


class DatabaseReleaseDateBumpTests(unittest.TestCase):
    def test_bumping_a_dated_database_refreshes_its_release_date(self):
        manifest = sample_manifest()
        manifest["databases"][0]["releaseDate"] = "2025-09-16"
        candidates = sample_candidates()

        new, log = bump.apply_bumps(
            manifest, candidates, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )

        scrubber = [d for d in new["databases"] if d["id"] == "human-scrubber"][0]
        self.assertEqual(scrubber["version"], "20260706v2")
        self.assertEqual(scrubber["releaseDate"], "2026-07-06")
        self.assertTrue(
            any("releaseDate 2025-09-16 -> 2026-07-06" in line for line in log),
            f"the change log must report the date move: {log}",
        )

    def test_a_database_without_a_release_date_gains_one(self):
        manifest = sample_manifest()
        self.assertNotIn("releaseDate", manifest["databases"][1])
        new, log = bump.apply_bumps(
            manifest, sample_candidates(), new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        kraken = [d for d in new["databases"] if d["id"] == "kraken2-standard-8"][0]
        self.assertEqual(kraken["releaseDate"], "2026-06-26")
        self.assertTrue(any("releaseDate unset -> 2026-06-26" in line for line in log))

    def test_an_undated_version_leaves_an_existing_release_date_alone(self):
        manifest = sample_manifest()
        manifest["databases"][1]["releaseDate"] = "2025-04-01"
        candidates = sample_candidates()
        # A version that encodes no date must not have one invented for it.
        candidates["databases"][1]["latest"] = "panhuman-2"
        candidates["databases"][1].pop("latestURL", None)

        new, _ = bump.apply_bumps(
            manifest, candidates, new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )

        kraken = [d for d in new["databases"] if d["id"] == "kraken2-standard-8"][0]
        self.assertEqual(kraken["version"], "panhuman-2")
        self.assertEqual(kraken["releaseDate"], "2025-04-01")

    def test_a_held_database_keeps_its_release_date(self):
        manifest = sample_manifest()
        manifest["databases"][0]["releaseDate"] = "2025-09-16"

        new, _ = bump.apply_bumps(
            manifest,
            sample_candidates(),
            new_set="2026.2",
            date="2026-08-20",
            only=None,
            hold={"human-scrubber"},
        )

        scrubber = [d for d in new["databases"] if d["id"] == "human-scrubber"][0]
        self.assertEqual(scrubber["version"], "20250916v2", "held")
        self.assertEqual(scrubber["releaseDate"], "2025-09-16")

    def test_an_already_correct_release_date_is_not_logged_as_a_change(self):
        manifest = sample_manifest()
        manifest["databases"][0]["releaseDate"] = "2026-07-06"
        _, log = bump.apply_bumps(
            manifest, sample_candidates(), new_set="2026.2", date="2026-08-20", only=None, hold=set()
        )
        self.assertFalse(
            any("human-scrubber: releaseDate" in line for line in log),
            f"an unchanged date must not be reported as a move: {log}",
        )


class ShippedManifestReleaseDateTests(unittest.TestCase):
    def test_shipped_dated_database_entries_agree_with_their_versions(self):
        """The committed manifest must not carry a releaseDate its version contradicts.

        Scoped to entries that actually carry the field. Most Kraken2 entries
        omit releaseDate entirely, which is a schema choice rather than drift;
        the failure this guards is a date that is present and wrong, as
        human-scrubber's was after it moved to the 20260706v2 build.

        Effective coverage today is a single entry: human-scrubber is the only
        shipped database that both carries a releaseDate and pins a dated
        version. deacon-panhuman and deacon-ribokmers carry dates but their
        versions encode none, and the Kraken2 entries pin dates but carry no
        releaseDate. The assertion below that at least one entry was checked is
        what keeps this from silently degrading to a no-op if that one entry
        changes shape.
        """
        manifest = json.loads(bump.DEFAULT_MANIFEST.read_text(encoding="utf-8"))
        checked = 0
        for entry in manifest.get("databases", []):
            if "releaseDate" not in entry:
                continue
            derived = bump.release_date_from_version(entry.get("version"))
            if derived is None:
                continue
            checked += 1
            with self.subTest(database=entry.get("id")):
                self.assertEqual(
                    entry.get("releaseDate"),
                    derived,
                    f"{entry.get('id')}: version {entry.get('version')} implies "
                    f"releaseDate {derived}",
                )
        self.assertGreater(
            checked, 0, "no dated database entry carried a releaseDate to check"
        )


if __name__ == "__main__":
    unittest.main()
