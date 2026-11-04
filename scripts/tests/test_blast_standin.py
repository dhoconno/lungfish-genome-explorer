"""The stand-in a walk's BLAST rows run on. Nothing here leaves 127.0.0.1."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "walk" / "blast_standin.py"
REPLIES = ROOT / "Tests" / "Fixtures" / "blast-replies"


class BlastStandInTests(unittest.TestCase):
    def setUp(self):
        self.server = subprocess.Popen(
            [sys.executable, "-I", str(SCRIPT), "--port", "0"],
            stdout=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.server.stdout.close)
        self.addCleanup(self.server.wait)
        self.addCleanup(self.server.kill)
        ready = self.server.stdout.readline()
        found = re.search(r"http://127\.0\.0\.1:(\d+)", ready)
        self.assertIsNotNone(found, ready)
        self.origin = found.group(0)

    def get(self, path):
        with urllib.request.urlopen(self.origin + path, timeout=30) as reply:
            return reply.read().decode()

    def control(self, path):
        return json.loads(self.get("/control/" + path))

    def put(self, reads="read_a"):
        fasta = "".join(f">{name}\nACGTACGT\n" for name in reads.split(","))
        body = urllib.parse.urlencode({"CMD": "Put", "QUERY": fasta}).encode()
        with urllib.request.urlopen(self.origin + "/blast/Blast.cgi", data=body, timeout=30) as reply:
            page = reply.read().decode()
        found = re.search(r"RID = (\w+)", page)
        self.assertIsNotNone(found, page)
        return found.group(1)

    def status(self, rid):
        page = self.get(f"/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID={rid}")
        found = re.search(r"Status=(\w+)", page)
        return found.group(1) if found else page

    def result(self, rid):
        return json.loads(self.get(f"/blast/Blast.cgi?CMD=Get&FORMAT_TYPE=JSON2_S&RID={rid}"))

    @staticmethod
    def top_record(document):
        return document["BlastOutput2"][0]["report"]["results"]["search"]["hits"][0]["description"][0]["accession"]

    def test_blast_standin_serves_hold_and_release(self):
        first = self.put()
        second = self.put()
        self.assertEqual(self.status(first), "WAITING", "a search stays held until a person releases it")
        self.assertEqual(self.status(second), "WAITING")

        self.control(f"release?rid={second}")

        self.assertEqual(self.status(first), "WAITING", "a release names one search")
        self.assertEqual(self.status(second), "READY")
        self.assertEqual(self.top_record(self.result(second)), self.expected_records()[1])

        self.control("release")
        self.assertEqual(self.status(first), "READY")
        self.assertEqual(self.top_record(self.result(first)), self.expected_records()[0])
        self.assertEqual(self.control("state")["puts"], 2)

    def expected_records(self):
        names = sorted(REPLIES.glob("sars-cov-2-one-read-send-*.json"))
        return [self.top_record(json.loads(name.read_text())) for name in names]

    def test_two_sends_of_one_read_name_other_tied_records(self):
        first, second = self.expected_records()
        self.assertNotEqual(first, second, "the copy's reply must differ for a walk to see which send counted")

    def test_a_reply_answers_the_reads_of_this_send(self):
        self.control("ready")
        rid = self.put("walk_read_1,walk_read_2,walk_read_3")
        self.assertEqual(self.status(rid), "READY")
        reports = self.result(rid)["BlastOutput2"]
        titles = [item["report"]["results"]["search"]["query_title"] for item in reports]
        self.assertEqual(titles, ["walk_read_1", "walk_read_2", "walk_read_3"])
        self.assertEqual(reports[0]["report"]["results"]["search"]["query_len"], 8)

    def test_each_ending_a_row_reads(self):
        self.control("expire")
        self.assertEqual(self.status(self.put()), "UNKNOWN")
        self.control("fail?words=Message%20ID%2099")
        rid = self.put()
        self.assertEqual(self.status(rid), "FAILED")
        self.assertIn("Message ID 99", self.get(f"/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID={rid}"))

    def test_faults_run_out_and_the_search_goes_on(self):
        rid = self.put()
        self.control("fault?on=status&kind=503&count=1")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.status(rid)
        self.assertEqual(caught.exception.code, 503)
        self.assertEqual(self.status(rid), "WAITING")

        self.control("fault?on=put&kind=503&count=1")
        with self.assertRaises(urllib.error.HTTPError):
            self.put()
        self.assertEqual(self.control("state")["puts"], 1, "a refused Put starts nothing")

        self.control("fault?on=status&kind=nostatus&count=1")
        self.assertNotIn("Status=", self.get(f"/blast/Blast.cgi?CMD=Get&FORMAT_OBJECT=SearchInfo&RID={rid}"))

        self.control(f"release?rid={rid}")
        self.control("fault?on=result&kind=html&count=1")
        self.assertIn("<html>", self.get(f"/blast/Blast.cgi?CMD=Get&FORMAT_TYPE=JSON2_S&RID={rid}"))
        self.assertEqual(self.top_record(self.result(rid)), self.expected_records()[0])

    def test_it_never_names_a_host_but_loopback(self):
        source = SCRIPT.read_text()
        for address in re.findall(r"https?://[^\s\"']+", source):
            self.assertTrue(address.startswith("http://127.0.0.1:"), address)
        self.assertNotIn("--host", source)

    def test_the_replies_hold_no_session_or_account(self):
        names = [name for name in REPLIES.iterdir() if name.suffix == ".json"]
        self.assertGreaterEqual(len(names), 4)
        for name in names:
            text = name.read_text()
            for word in ("ncbi_sid", "MYNCBI_USER", "Set-Cookie", "wisc.edu", "EMAIL"):
                self.assertNotIn(word, text, name)
            self.assertIn("BlastOutput2", text)

    @unittest.skipUnless((ROOT / ".build" / "debug" / "lungfish-cli").exists(), "the Debug CLI is not built")
    def test_the_debug_cli_parks_on_a_held_search_and_collects_it_after_a_release(self):
        with tempfile.TemporaryDirectory() as folder:
            place = Path(folder)
            query = place / "query.fasta"
            query.write_text(">walk_read\n" + "ACGTT" * 100 + "\n")
            output = place / "search"
            output.mkdir()
            cli = str(ROOT / ".build" / "debug" / "lungfish-cli")
            environment = {
                **os.environ,
                "LUNGFISH_BLAST_STAND_IN_ORIGIN": self.origin,
                "LUNGFISH_BLAST_STAND_IN_STATE": str(place / "state"),
                "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": "600",
            }
            shared = ["--format", "json", "--no-progress"]
            parked = subprocess.run(
                [cli, "blast", "submit", "--query", str(query), "--output", str(output), "--name", "Walk", "--park", *shared],
                env=environment, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(parked.returncode, 75, parked.stdout + parked.stderr)
            self.assertIn('"waiting"', parked.stdout)
            self.assertEqual(self.control("state")["puts"], 3, "the first send and two copies")

            self.control("release")
            came_back = subprocess.run(
                [cli, "blast", "resume", "--output", str(output), "--once", *shared],
                env=environment, capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(came_back.returncode, 0, came_back.stdout + came_back.stderr)
            record = json.loads((output / "blast-result.json").read_text())
            self.assertIn(record["result"]["rid"], {"WALK1", "WALK2", "WALK3"})
            self.assertEqual(record["result"]["readResults"][0]["id"], "walk_read")


if __name__ == "__main__":
    unittest.main()
