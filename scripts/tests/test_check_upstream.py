"""Tests for scripts/deps/check_upstream.py and scripts/deps/upstream_sources.py.

Every upstream source is exercised through a ``FakeFetcher`` backed by fixtures
recorded from live responses (``scripts/tests/fixtures/deps/``), so the suite is
hermetic and safe to run in CI.
"""

import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/deps"))

import check_upstream  # noqa: E402
import upstream_sources as us  # noqa: E402

FIX = ROOT / "scripts/tests/fixtures/deps"
K2 = "https://genome-idx.s3.amazonaws.com/kraken"


class FakeFetcher:
    def __init__(self):
        self.texts = {}
        self.heads = set()
        self.repodata = {}

    def get_text(self, url):
        return self.texts[url]

    def head_ok(self, url):
        return url in self.heads

    def micromamba_search(self, package, platform):
        return self.repodata[(package, platform)]


class CheckUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.f = FakeFetcher()
        self.f.repodata[("samtools", "osx-arm64")] = json.loads(
            (FIX / "repodata-samtools.json").read_text(encoding="utf-8")
        )
        self.f.repodata[("samtools", "noarch")] = {"result": {"pkgs": []}}
        self.f.texts[
            "https://api.github.com/repos/jhuapl-bio/taxtriage/tags?per_page=20"
        ] = (FIX / "github-taxtriage-tags.json").read_text(encoding="utf-8")
        self.f.texts["https://benlangmead.github.io/aws-indexes/k2"] = (
            FIX / "kraken2-index-page.html"
        ).read_text(encoding="utf-8")
        self.f.heads |= {
            f"{K2}/k2_standard_20260626.tar.gz",
            f"{K2}/k2_standard_08_GB_20260626.tar.gz",
            f"{K2}/k2_standard_16_GB_20260626.tar.gz",
            f"{K2}/k2_pluspf_20260626.tar.gz",
            f"{K2}/k2_pluspf_08_GB_20260626.tar.gz",
            f"{K2}/k2_pluspf_16_GB_20260626.tar.gz",
            f"{K2}/k2_viral_20260626.tar.gz",
            f"{K2}/k2_minusb_20260626.tar.gz",
            f"{K2}/k2_eupathdb48_20230407.tar.gz",
        }
        self.f.texts["https://ftp.ncbi.nlm.nih.gov/sra/dbs/human_filter/"] = (
            FIX / "ncbi-human-filter.html"
        ).read_text(encoding="utf-8")
        self.f.texts[
            "https://api.github.com/repos/mamba-org/micromamba-releases/releases/latest"
        ] = (FIX / "micromamba-releases-latest.json").read_text(encoding="utf-8")

    # ---------------------------------------------------------------- conda

    def test_latest_conda_prefers_arm64_and_highest_version(self):
        r = us.latest_conda("samtools", "bioconda", self.f)
        self.assertEqual(r["version"], "1.24")
        self.assertEqual(r["subdir"], "osx-arm64")
        self.assertEqual(r["build"], "h36b3a25_1")
        self.assertEqual(r["channel"], "bioconda")

    def _bracken_repodata(self):
        """bracken: 1.0.0 noarch is installable, 3.1 exists on linux-64 only."""
        self.f.repodata[("bracken", "osx-arm64")] = {"result": {"pkgs": []}}
        self.f.repodata[("bracken", "noarch")] = {
            "result": {
                "pkgs": [
                    {
                        "name": "bracken",
                        "version": "1.0.0",
                        "build": "1",
                        "build_number": 1,
                        "subdir": "noarch",
                        "channel": "https://conda.anaconda.org/bioconda/noarch",
                    }
                ]
            }
        }
        self.f.repodata[("bracken", "linux-64")] = {
            "result": {
                "pkgs": [
                    {
                        "name": "bracken",
                        "version": "3.1",
                        "build": "h9948957_0",
                        "build_number": 0,
                        "subdir": "linux-64",
                        "channel": "https://conda.anaconda.org/bioconda/linux-64",
                    }
                ]
            }
        }

    def test_latest_conda_reports_a_linux_only_newer_version(self):
        self._bracken_repodata()
        r = us.latest_conda("bracken", "bioconda", self.f)
        self.assertEqual(r["version"], "1.0.0")
        self.assertEqual(r["subdir"], "noarch")
        self.assertEqual(r["linuxOnlyVersion"], "3.1")

    def test_linux_only_newer_version_is_flagged_not_reported_as_same(self):
        self._bracken_repodata()
        m = self._manifest()
        m["tools"] = [
            {
                "id": "bracken",
                "environment": "bracken",
                "packageSpec": "bioconda::bracken=1.0.0=1",
                "version": "1.0.0",
            }
        ]
        c = check_upstream.build_candidates(m, self.f)
        row = c["tools"][0]
        self.assertEqual(row["status"], "no-arm64-build")
        self.assertEqual(row["latest"], "1.0.0")
        self.assertIn("3.1", row["notes"])

    def test_no_linux_only_flag_when_arm64_is_current(self):
        r = us.latest_conda("samtools", "bioconda", self.f)
        self.assertIsNone(r["linuxOnlyVersion"])

    def test_latest_conda_returns_none_when_no_packages(self):
        self.f.repodata[("ghost", "osx-arm64")] = {"result": {"pkgs": []}}
        self.f.repodata[("ghost", "noarch")] = {"result": {"pkgs": []}}
        self.assertIsNone(us.latest_conda("ghost", "bioconda", self.f))

    def test_version_key_orders_numerically_not_lexically(self):
        key = us.version_key
        self.assertGreater(key("2.17.1"), key("2.1.6"))
        self.assertGreater(key("40.02"), key("39.80"))
        self.assertGreater(key("3.0.1"), key("1.0.0"))
        self.assertGreater(key("1.24"), key("1.23.1"))

    def test_compare_versions_ranks_release_above_prerelease(self):
        self.assertEqual(us.compare_versions("1.0.0", "1.0.0rc1"), 1)
        self.assertEqual(us.compare_versions("1.0.0rc1", "1.0.0"), -1)
        self.assertEqual(us.compare_versions("1.24", "1.23.1"), 1)
        self.assertEqual(us.compare_versions("2.17.1", "2.1.6"), 1)
        self.assertEqual(us.compare_versions("40.02", "39.80"), 1)
        self.assertEqual(us.compare_versions("1.23.1", "1.23.1"), 0)

    # -------------------------------------------------------------- kraken2

    def test_kraken2_probe_uses_new_naming_for_small_collections(self):
        d = us.kraken2_latest_dates(self.f)
        self.assertEqual(d["standard"]["url"], f"{K2}/k2_standard_20260626.tar.gz")
        self.assertEqual(d["standard"]["date"], "20260626")
        self.assertEqual(
            d["standard-8"]["url"], f"{K2}/k2_standard_08_GB_20260626.tar.gz"
        )
        self.assertEqual(
            d["standard-16"]["url"], f"{K2}/k2_standard_16_GB_20260626.tar.gz"
        )
        self.assertEqual(d["pluspf-8"]["url"], f"{K2}/k2_pluspf_08_GB_20260626.tar.gz")

    def test_kraken2_eupathdb_stays_pinned_when_no_newer_probe_succeeds(self):
        d = us.kraken2_latest_dates(self.f)
        self.assertEqual(d["eupathdb46"]["date"], "20230407")
        self.assertEqual(d["eupathdb46"]["url"], f"{K2}/k2_eupathdb48_20230407.tar.gz")

    def test_kraken2_collection_without_a_live_probe_is_omitted(self):
        self.f.heads.discard(f"{K2}/k2_viral_20260626.tar.gz")
        d = us.kraken2_latest_dates(self.f)
        self.assertNotIn("viral", d)

    # --------------------------------------------------------------- github

    def test_taxtriage_latest_tag_and_sha(self):
        r = us.latest_github_release("jhuapl-bio/taxtriage", self.f)
        self.assertEqual(r["tag"], "v3.3.8")
        self.assertTrue(r["sha"].startswith("e10bfeb"))

    # ----------------------------------------------------------------- ncbi

    def test_human_filter_latest(self):
        self.assertEqual(us.ncbi_human_filter_latest(self.f), "20260706v2")

    def test_taxdump_latest_picks_newest_archive_and_md5(self):
        base = "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump_archive/"
        self.f.texts[base] = (
            '<a href="taxdmp_2026-07-01.zip">x</a>'
            '<a href="taxdmp_2026-08-01.zip">x</a>'
            '<a href="taxdmp_2025-12-01.zip">x</a>'
        )
        r = us.ncbi_taxdump_latest(self.f)
        self.assertEqual(r["version"], "2026-08-01")
        self.assertEqual(r["url"], base + "taxdmp_2026-08-01.zip")
        self.assertEqual(r["md5_url"], base + "taxdmp_2026-08-01.zip.md5")

    # ----------------------------------------------------------- micromamba

    def test_micromamba_latest(self):
        r = us.micromamba_latest(self.f)
        self.assertEqual(r["version"], "2.9.0-0")
        self.assertIn("osx-arm64", r["sha256_url"])

    # --------------------------------------------------------------- zenodo

    def test_zenodo_record_files(self):
        self.f.texts["https://zenodo.org/api/records/17716199"] = json.dumps(
            {
                "files": [
                    {
                        "key": "esviritu_db_v3.2.4.tar.gz",
                        "checksum": "md5:24d85c1ec3cbffff12e921d2f39c91b2",
                        "links": {"self": "https://zenodo.org/x/content"},
                    }
                ]
            }
        )
        files = us.zenodo_record_files("17716199", self.f)
        self.assertEqual(files[0]["name"], "esviritu_db_v3.2.4.tar.gz")
        self.assertEqual(files[0]["checksum"], "md5:24d85c1ec3cbffff12e921d2f39c91b2")

    # ---------------------------------------------------------- build/render

    def _manifest(self):
        return {
            "dependencySet": "2026.1",
            "tools": [
                {
                    "id": "samtools",
                    "environment": "samtools",
                    "packageSpec": "bioconda::samtools=1.23.1=hc612e98_0",
                    "version": "1.23.1",
                }
            ],
            "packTools": [],
            "pipelines": [
                {
                    "id": "taxtriage",
                    "repository": "jhuapl-bio/taxtriage",
                    "revision": "8fd1fb5",
                    "releaseVersion": "v3.3.6",
                }
            ],
            "databases": [
                {
                    "id": "human-scrubber",
                    "tool": "sra-human-scrubber",
                    "version": "20250916v2",
                }
            ],
            "bootstrap": {"micromamba": {"version": "2.0.5-0"}},
        }

    def test_build_candidates_marks_update_and_same(self):
        c = check_upstream.build_candidates(self._manifest(), self.f)
        sam = next(t for t in c["tools"] if t["id"] == "samtools")
        self.assertEqual(sam["status"], "update")
        self.assertEqual(sam["latest"], "1.24")
        self.assertEqual(sam["latestSpec"], "bioconda::samtools=1.24=h36b3a25_1")
        self.assertEqual(c["pipelines"][0]["latest"], "v3.3.8")
        self.assertEqual(c["databases"][0]["latest"], "20260706v2")
        self.assertEqual(c["bootstrap"]["latest"], "2.9.0-0")
        self.assertEqual(c["dependencySet"], "2026.1")
        md = check_upstream.render_markdown(c)
        self.assertIn("| samtools |", md)

    def test_build_candidates_marks_same_when_already_current(self):
        m = self._manifest()
        m["tools"][0]["version"] = "1.24"
        m["tools"][0]["packageSpec"] = "bioconda::samtools=1.24=h36b3a25_1"
        c = check_upstream.build_candidates(m, self.f)
        self.assertEqual(c["tools"][0]["status"], "same")

    def test_pack_tool_ids_are_namespaced_by_pack(self):
        m = self._manifest()
        m["tools"] = []
        m["packTools"] = [
            {
                "packID": "read-mapping",
                "id": "samtools",
                "environment": "samtools",
                "packageSpec": "bioconda::samtools=1.23.1=hc612e98_0",
                "version": "1.23.1",
            }
        ]
        c = check_upstream.build_candidates(m, self.f)
        self.assertEqual(c["tools"][0]["id"], "read-mapping/samtools")
        self.assertEqual(c["tools"][0]["kind"], "packTool")

    def test_source_failure_is_recorded_as_error_not_raised(self):
        m = self._manifest()
        m["tools"][0]["id"] = "nonexistent-tool"
        m["tools"][0]["packageSpec"] = "bioconda::nonexistent-tool=1.0=h0_0"
        c = check_upstream.build_candidates(m, self.f)
        self.assertEqual(c["tools"][0]["status"], "error")
        self.assertTrue(c["tools"][0]["notes"])

    def test_only_filter_restricts_the_candidate_set(self):
        m = self._manifest()
        c = check_upstream.build_candidates(m, self.f, only={"samtools"})
        self.assertEqual([t["id"] for t in c["tools"]], ["samtools"])
        self.assertEqual(c["pipelines"], [])
        self.assertEqual(c["databases"], [])
        self.assertIsNone(c["bootstrap"])

    def test_render_markdown_has_the_agreed_columns(self):
        c = check_upstream.build_candidates(self._manifest(), self.f)
        md = check_upstream.render_markdown(c)
        self.assertIn(
            "| id | kind | current | latest | latestSpec/URL | status | notes |", md
        )
        self.assertIn("| taxtriage |", md)
        self.assertIn("| micromamba |", md)

    def test_main_writes_json_and_markdown_and_exits_zero(self):
        import tempfile

        manifest = self._manifest()
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            rc = check_upstream.main(
                [
                    "--manifest",
                    str(tmp / "manifest.json"),
                    "--json",
                    str(tmp / "out.json"),
                    "--markdown",
                    str(tmp / "out.md"),
                    "--only",
                    "samtools",
                ],
                fetcher=self.f,
            )
        self.assertEqual(rc, 0)


class KrakenDeadURLTests(CheckUpstreamTests):
    def test_dead_manifest_url_is_flagged(self):
        m = self._manifest()
        m["tools"] = []
        m["pipelines"] = []
        m["databases"] = [
            {
                "id": "kraken2-standard",
                "tool": "kraken2",
                "collection": "standard",
                "version": "20240904",
                "url": f"{K2}/k2_standard_20240904.tar.gz",
            }
        ]
        c = check_upstream.build_candidates(m, self.f)
        self.assertEqual(c["databases"][0]["status"], "dead-url")
        self.assertEqual(c["databases"][0]["latest"], "20260626")

    def test_live_manifest_url_reports_update(self):
        m = self._manifest()
        m["tools"] = []
        m["pipelines"] = []
        m["databases"] = [
            {
                "id": "kraken2-standard",
                "tool": "kraken2",
                "collection": "standard",
                "version": "20240904",
                "url": f"{K2}/k2_standard_20240904.tar.gz",
            }
        ]
        self.f.heads.add(f"{K2}/k2_standard_20240904.tar.gz")
        c = check_upstream.build_candidates(m, self.f)
        self.assertEqual(c["databases"][0]["status"], "update")


if __name__ == "__main__":
    unittest.main()
