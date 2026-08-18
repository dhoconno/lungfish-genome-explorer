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
    def test_fetch_checksums_fills_esviritu_taxonomy_and_micromamba(self):
        manifest = {
            "databases": [
                {
                    "id": "esviritu-viral-v3",
                    "version": "v3.2.4",
                    "url": "https://zenodo.org/records/17716199/files/esviritu_db_v3.2.4.tar.gz",
                },
                {
                    "id": "ncbi-taxonomy",
                    "version": "2025-03",
                    "url": "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz",
                },
            ],
            "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}},
        }
        fetcher = FakeFetcher(
            json_payloads={
                "https://zenodo.org/api/records/17716199": {
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
                            "browser_download_url": "https://example.invalid/micromamba-osx-arm64.sha256",
                        }
                    ],
                },
            },
            texts={
                "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz.md5": "fedcba9876543210fedcba9876543210  taxdump.tar.gz\n",
                "https://example.invalid/micromamba-osx-arm64.sha256": (
                    "a" * 64 + "  micromamba-osx-arm64\n"
                ),
            },
        )
        result = bump.fetch_checksums(manifest, fetcher)
        self.assertEqual(
            result["esviritu-viral-v3"], "0123456789abcdef0123456789abcdef"
        )
        self.assertEqual(result["ncbi-taxonomy"], "fedcba9876543210fedcba9876543210")
        self.assertEqual(result["micromamba"], "a" * 64)
        self.assertEqual(
            manifest["databases"][0]["md5"], "0123456789abcdef0123456789abcdef"
        )
        self.assertEqual(
            manifest["databases"][1]["md5"], "fedcba9876543210fedcba9876543210"
        )
        self.assertEqual(manifest["bootstrap"]["micromamba"]["sha256"]["osx-arm64"], "a" * 64)

    def test_fetch_checksums_hashes_the_binary_when_no_sha256_asset(self):
        import hashlib

        payload = b"micromamba-binary-bytes"
        manifest = {"databases": [], "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}}}
        fetcher = FakeFetcher(
            json_payloads={
                "https://api.github.com/repos/mamba-org/micromamba-releases/releases/latest": {
                    "tag_name": "2.9.0-0",
                    "assets": [
                        {
                            "name": "micromamba-osx-arm64",
                            "browser_download_url": "https://example.invalid/micromamba-osx-arm64",
                        }
                    ],
                }
            },
            binaries={"https://example.invalid/micromamba-osx-arm64": payload},
        )
        result = bump.fetch_checksums(manifest, fetcher)
        self.assertEqual(result["micromamba"], hashlib.sha256(payload).hexdigest())

    def test_fetch_checksums_records_errors_instead_of_raising(self):
        manifest = {
            "databases": [
                {"id": "ncbi-taxonomy", "version": "2025-03", "url": "https://example.invalid/taxdump.tar.gz"}
            ],
            "bootstrap": {"micromamba": {"version": "2.9.0-0", "sha256": {}}},
        }
        result = bump.fetch_checksums(manifest, FakeFetcher())
        self.assertIn("ncbi-taxonomy", result)
        self.assertTrue(str(result["ncbi-taxonomy"]).startswith("error:"))


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


if __name__ == "__main__":
    unittest.main()
