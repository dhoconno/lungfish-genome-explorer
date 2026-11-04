#!/usr/bin/env python3
"""A stand-in of NCBI's BLAST CGI for a person's walk, on this Mac only.

It serves reply bodies recorded from real searches, and a person chooses what each search does, so no walk row counts
on how fast NCBI answers or on which tied records it names. BLAST-STAND-IN.md beside this file says what to run and
which row to read for each state.

Standard library only. It binds to loopback and has no option for another address.

The controls answer on the same port, as `curl -s http://127.0.0.1:<port>/control/<name>`.

  hold                 Searches read WAITING until they are released. This is how it starts.
  release[?rid=WALK2]  Every search, or one, reads READY from its next check on.
  ready                Searches read READY at once.
  expire               Status=UNKNOWN, as NCBI answers for a search it no longer holds.
  fail[?words=...]     Status=FAILED with these words.
  fault?on=put|status|result&kind=503|drop|nostatus|empty|html|damaged[&count=N]
                       The next N contacts of that kind get this fault, and then the search goes on.
  clear                No faults, and a Put answers at once.
  slow-put?seconds=N   A Put waits this long before its answer.
  reply?name=<prefix>  Which recorded replies answer from now on, by the start of their file name.
  state                What has come so far, as JSON.
"""

import argparse
import copy
import http.server
import json
from pathlib import Path
import socket
import sys
import threading
import time
import urllib.parse


DEFAULT_REPLIES = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "blast-replies"
DAMAGED_ZIP = bytes([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF])
WAITING, READY, UNKNOWN, FAILED = "WAITING", "READY", "UNKNOWN", "FAILED"


def block(lines):
    """An information block in the form NCBI writes it."""
    return f"<!--QBlastInfoBegin\n\t{lines}\nQBlastInfoEnd\n-->\n"


def reads_of(form):
    """The read names and lengths of a Put's FASTA query."""
    reads = []
    for line in form.get("QUERY", [""])[0].splitlines():
        if line.startswith(">"):
            reads.append([line[1:].split()[0] if line[1:].split() else f"read_{len(reads) + 1}", 0])
        elif reads:
            reads[-1][1] += len(line.strip())
    return reads


def tailored(recorded, reads):
    """The recorded reply, with one entry for each read of this send under that read's name. The hits stay as recorded."""
    document = json.loads(recorded)
    reports = document["BlastOutput2"]
    if not reads or not reports:
        return recorded
    entries = []
    for index, (name, length) in enumerate(reads):
        entry = copy.deepcopy(reports[index % len(reports)])
        search = entry["report"]["results"]["search"]
        search["query_title"] = name
        search["query_len"] = length
        search.pop("query_id", None)
        entries.append(entry)
    return json.dumps({"BlastOutput2": entries}).encode()


class Program:
    """What a person has asked for, and the searches so far. One lock guards all of it."""

    def __init__(self, replies, prefix):
        self.lock = threading.Lock()
        self.replies = Path(replies)
        self.prefix = prefix
        self.mode = WAITING
        self.fail_words = "Error: NCBI could not finish this search"
        self.released = set()
        self.searches = {}
        self.faults = {"put": [], "status": [], "result": []}
        self.put_seconds = 0.0
        self.puts = 0
        self.contacts = []

    def reply_files(self):
        return sorted(self.replies.glob(f"{self.prefix}*.json"))

    def control(self, name, query):
        """Runs one control and returns what to say back, or None for a name it does not know."""
        one = lambda key, default=None: query.get(key, [default])[0]
        with self.lock:
            if name == "hold":
                self.mode = WAITING
                self.released.clear()
            elif name == "release":
                rid = one("rid")
                self.released.update([rid] if rid else list(self.searches))
                if not rid:
                    self.mode = READY
            elif name == "ready":
                self.mode = READY
            elif name == "expire":
                self.mode = UNKNOWN
            elif name == "fail":
                self.mode = FAILED
                self.fail_words = one("words", self.fail_words)
            elif name == "fault":
                self.faults[one("on", "status")] += [one("kind", "503")] * int(one("count", "1"))
            elif name == "clear":
                self.faults = {"put": [], "status": [], "result": []}
                self.put_seconds = 0.0
            elif name == "slow-put":
                self.put_seconds = float(one("seconds", "0"))
            elif name == "reply":
                self.prefix = one("name", self.prefix)
            elif name != "state":
                return None
            return {
                "mode": self.mode,
                "reply": self.prefix,
                "puts": self.puts,
                "searches": sorted(self.searches),
                "released": sorted(self.released),
                "faults": self.faults,
                "contacts": self.contacts[-40:],
            }

    def take_fault(self, kind):
        faults = self.faults[kind]
        return faults.pop(0) if faults else None

    def answer_put(self, form):
        with self.lock:
            fault = self.take_fault("put")
            if fault is None:
                self.puts += 1
                rid = f"WALK{self.puts}"
                files = self.reply_files()
                recorded = files[(self.puts - 1) % len(files)].read_bytes()
                self.searches[rid] = tailored(recorded, reads_of(form))
                self.contacts.append(f"put {rid}")
            else:
                rid = None
                self.contacts.append(f"put refused {fault}")
            seconds = self.put_seconds
        if seconds:
            time.sleep(seconds)
        if fault is not None:
            return fault
        return block(f"RID = {rid}\n\tRTOE = 30")

    def answer_status(self, rid):
        with self.lock:
            self.contacts.append(f"status {rid}")
            fault = self.take_fault("status")
            if fault is not None:
                return fault
            if rid not in self.searches:
                return block(f"Status={UNKNOWN}")
            state = READY if rid in self.released else self.mode
            if state == READY:
                return block(f"Status={READY}") + block("ThereAreHits=yes")
            if state == FAILED:
                return block(f"Status={FAILED}") + f"<p>{self.fail_words}</p>"
            return block(f"Status={state}")

    def answer_result(self, rid):
        with self.lock:
            self.contacts.append(f"result {rid}")
            fault = self.take_fault("result")
            if fault is not None:
                return fault
            return self.searches.get(rid)


def handler_for(program):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            pass

        def send_body(self, body, content_type="text/html; charset=UTF-8", status=200):
            data = body.encode() if isinstance(body, str) else body
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True

        def send_fault(self, fault):
            """Sends a fault by its name, and says whether the value was one."""
            if fault == "drop":
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
            elif fault == "503":
                self.send_body("Service unavailable", status=503)
            elif fault == "nostatus":
                self.send_body("<html><body>Please wait</body></html>")
            elif fault == "empty":
                self.send_body("")
            elif fault == "html":
                self.send_body("<html><body>Results are not available</body></html>")
            elif fault == "damaged":
                self.send_body(DAMAGED_ZIP, content_type="application/zip")
            else:
                return False
            return True

        def do_POST(self):
            path = urllib.parse.urlsplit(self.path).path
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if path != "/blast/Blast.cgi":
                self.send_body("Not found", status=404)
                return
            answer = program.answer_put(urllib.parse.parse_qs(body.decode("utf-8", "replace")))
            if not self.send_fault(answer):
                self.send_body(answer)

        def do_GET(self):
            parts = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(parts.query)
            if parts.path.startswith("/control/"):
                said = program.control(parts.path.removeprefix("/control/"), query)
                if said is None:
                    self.send_body("No such control", status=404)
                else:
                    self.send_body(json.dumps(said, indent=1) + "\n", content_type="application/json")
                return
            if parts.path != "/blast/Blast.cgi":
                self.send_body("Not found", status=404)
                return
            rid = query.get("RID", [None])[0]
            if query.get("FORMAT_OBJECT") == ["SearchInfo"]:
                answer = program.answer_status(rid)
                if not self.send_fault(answer):
                    self.send_body(answer)
                return
            answer = program.answer_result(rid)
            if isinstance(answer, bytes):
                self.send_body(answer, content_type="application/json")
            elif answer is None:
                self.send_body("<html>RID not found</html>")
            else:
                self.send_fault(answer)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=18765, help="the port on 127.0.0.1, or 0 for any free one")
    parser.add_argument("--replies", default=str(DEFAULT_REPLIES), help="the folder of recorded replies")
    parser.add_argument("--reply", default="sars-cov-2-one-read", help="which replies answer, by the start of their file name")
    options = parser.parse_args()

    program = Program(options.replies, options.reply)
    if not program.reply_files():
        sys.exit(f"No recorded reply named {options.reply} in {options.replies}")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", options.port), handler_for(program))
    port = server.server_address[1]
    print(f"BLAST stand-in on http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
