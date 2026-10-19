#!/usr/bin/env python3
"""session_ledger.py - per-agent LLM usage ledger for Claude Code sessions (stdlib only).

usage:
  python3 session_ledger.py [--root ~/.claude/projects] [--md OUT.md] [--json OUT.json]
                            [--now ISO8601] [--top N] SESSION_ID_OR_JSONL [...]

Each argument is a session id (all `<root>/*/<id>.jsonl` main transcripts and all
`<root>/*/<id>/subagents/**/agent-*.jsonl` subagent transcripts are found) or a path to a
transcript (its session id is derived from the file name). Several sessions are reported
one after another and summed in a final "all sessions" section.

Per agent (the main session and each subagent): model, API turns (unique message ids),
input / cache-write / cache-read / output tokens, cache-hit ratio (read / all input),
estimated cost (per-model $/MTok fitted from Claude Code `cost-state` records), wall time
split into model, tool and idle time, tool calls by name, build and test Bash calls with
durations, failed tool results, tool calls with no result (pending; > 15 min flagged),
longest gaps, files read more than once, tool results over 20 KB, cache rebuilds and
context compactions. Also session totals, a grouping by model and by role, a grouping by
role, the model the turns ran on and the effort the spawn asked for (with the thinking tokens
recorded and estimated and the turns that kept no final usage), the spawns that set no model
or no effort, orchestration facts from the main session (spawns, SendMessage, TaskStop, task
notifications, quota readings) and the session's own `cost-state` record when present.

The script never prints message text except short signatures of errors, commands and
agent descriptions. Unknown entry types are counted and otherwise ignored.
"""
import argparse
import bisect
import glob
import json
import os
import re
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime

DEFAULT_ROOT = os.path.expanduser("~/.claude/projects")
# a build or test invocation at the start of a command segment (not a grep pattern naming one)
BUILD_RE = re.compile(
    r"(?:^|[;&|(]\s*|\b(?:then|do|else)\s+)(?:[A-Za-z_]+=\S+\s+)*(?:(?:time|nice|timeout\s+\S+)\s+)*"
    r"(?:swift\s+(?:build|test)\b|(?:\S*/)?full-suite-gate\.sh\b|(?:python3?\s+)?(?:\S*/)?golden\.py\b|xcodebuild\b)")
CHARS_PER_TOKEN = 3.6  # rough size of tool output in tokens, for context-lifetime estimates
CTX_BUCKETS = [(100e3, "<100K"), (200e3, "100-200K"), (400e3, "200-400K"), (600e3, "400-600K"),
               (800e3, "600-800K"), (float("inf"), ">800K")]
COMMIT_RE = re.compile(r"\bgit\s+(?:-C\s+\S+\s+)?commit\b")
BIG_RESULT = 20 * 1024
HANG_SECONDS = 15 * 60
# $ per million tokens. Sonnet 5.5 fits Claude Code cost-state records exactly (in 2, out 10,
# read 0.2, 5m write 2.5; 1h write assumed 2x input). Opus 5.5 is a least-squares fit over 17
# sessions (large sessions within 1%, small main-only sessions about 10-15% low).
PRICES = {
    "opus": {"in": 2.05, "out": 19.2, "read": 0.205, "w5m": 5.05, "w1h": 5.05},
    "sonnet": {"in": 2.0, "out": 10.0, "read": 0.20, "w5m": 2.5, "w1h": 4.0},
    "fable": {"in": 2.05, "out": 19.2, "read": 0.205, "w5m": 5.05, "w1h": 5.05},
    "haiku": {"in": 0.8, "out": 4.0, "read": 0.08, "w5m": 1.0, "w1h": 1.6},
}
ROLE_RULES = [  # first match wins, so fix agents, rulings, landings and monitors stay out of the lane and review rows
    ("fix", re.compile(r"^lane\b.*\breview fix(?:es)?\b|^diagnos", re.I)),  # fix work, so ahead of the "Lane" rule
    ("lane", re.compile(r"^lane\b", re.I)),
    ("fix", re.compile(r"^fix(?:es)?\b|\bfix agent", re.I)),
    ("landing", re.compile(r"^land(?:ing)?\b", re.I)),
    ("llm", re.compile(r"\bllm\b|efficien|\bmonitor\b", re.I)),
    # "ruling" in the first three words ("ARCH ruling ...", "UX words ruling ..."), so a brief writer, a plan commit that
    # mentions one, a review of one and a ruling applied by a lane keep their roles
    ("ruling", re.compile(r"^(?!review\b)(?:\S+\s+){0,2}rulings?\b(?! applied)", re.I)),
    ("review", re.compile(r"\breview|\baudit|\bverif|\bcheck(?:er)?\b|second opinion", re.I)),
    # a release step: the word operator, a label that opens with M1 to M3, package or publish, push main, or "M2 package".
    # M1 to M3 inside a lane label are that lane's milestones, so they do not count
    ("operator", re.compile(r"\boperators?\b|^(?:M[123]|package|publish)\b|\bpush main\b|\bM[123] (?:package|publish)\b", re.I)),
    ("gate", re.compile(r"\bgate\b|golden|full.suite|unit tier|ratchet", re.I)),
    ("walk", re.compile(r"gui walk|\bwalk\b|computer.use|screenshot", re.I)),
    ("design", re.compile(r"inventor|expert|design|memo|\bplan\b|planning|panel|question|survey|scope|research|investigat|triage|diagnos|\bbriefs?\b", re.I)),
    ("lane", re.compile(r"\blane\b|\bfix|implement|\bwave\b|writer|\bland|port|migrat|refactor|add |build", re.I)),
]
UNSET = "unset"  # a spawn setting that neither the Agent call nor the subagent's meta carries
READ_CMD_RES = [  # group 1: range or command form, group 2: file argument(s)
    re.compile(r"\bsed\s+-n\s+('[^']*'|\"[^\"]*\"|\S+)\s+([^\s|;&<>()]+)"),
    re.compile(r"(?:^|[\s;&|(])(cat|nl\s+-ba|nl)\s+((?:[^\s|;&<>()-][^\s|;&<>()]*\s*)+)"),
    re.compile(r"\b((?:head|tail)\s+(?:-[nc]\s*\+?\d+\s+|-\d+\s+)*)([^\s|;&<>()-][^\s|;&<>()]*)"),
]
GUARD_RE = re.compile(r"^This (?:session|agent) is isolated in the worktree")
OWNER_TOOLS = {"AskUserQuestion"}
TAG_RE = {k: re.compile(r"<%s>(.*?)</%s>" % (k, k), re.S) for k in
          ("task-id", "status", "subagent_tokens", "total_tokens", "tool_uses", "duration_ms", "summary")}


def parse_ts(s):
    if not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def hms(sec):
    if sec is None:
        return "-"
    sec = int(round(sec))
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m{sec % 60:02d}s"
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


def tok(n):
    n = n or 0
    if n >= 1e9:
        return f"{n / 1e9:.2f}B"
    if n >= 1e6:
        return f"{n / 1e6:.1f}M"
    if n >= 1e3:
        return f"{n / 1e3:.0f}K"
    return str(int(n))


def local(ts):
    return time.strftime("%m-%d %H:%M", time.localtime(ts)) if ts else "-"


def price_for(model):
    m = (model or "").lower()
    for k, v in PRICES.items():
        if k in m:
            return v
    return None


# Claude Code 2.1.295 writes most subagent assistant messages with stop_reason None and the usage of message_start
# (output_tokens 3 to 8), so their thinking and tool input never reach the transcript's usage. For such a message
# the ledger charges the output estimated from its content instead: thinking text and text at 4 characters a token,
# a thinking block stored without text at SIG_CHARS_PER_TOKEN characters of signature a token (3.03 pooled over the
# messages that do carry a final usage in 2.10, 2.98 on a 128K max_tokens message), tool input JSON at 3.5. The
# estimate ran 6% over the recorded output of 2.9's fully recorded messages, so it is divided by EST_BIAS.
SIG_CHARS_PER_TOKEN = 3.2
EST_BIAS = 1.06


def content_estimate(content):
    """Estimated output tokens of one entry's content blocks, and the thinking part of them."""
    est = think = 0.0
    if not isinstance(content, list):
        return est, think
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "thinking":
            txt = b.get("thinking") or ""
            n = len(txt) / 4 if txt else len(b.get("signature") or "") / SIG_CHARS_PER_TOKEN
            est += n
            think += n
        elif t == "redacted_thinking":
            n = len(b.get("data") or "") / SIG_CHARS_PER_TOKEN
            est += n
            think += n
        elif t == "text":
            est += len(b.get("text") or "") / 4
        elif t == "tool_use":
            est += len(json.dumps(b.get("input") or {})) / 3.5
    return est, think


def cost_of(u, model):
    p = price_for(model)
    if not p:
        return 0.0, {}
    parts = {
        "read": u["cr"] * p["read"] / 1e6,
        "write": (u["w5m"] * p["w5m"] + u["w1h"] * p["w1h"] + max(0, u["cc"] - u["w5m"] - u["w1h"]) * p["w5m"]) / 1e6,
        "out": u["out"] * p["out"] / 1e6,
        "in": u["in"] * p["in"] / 1e6,
    }
    return sum(parts.values()), parts


def role_of(label, kind, agent_type=None):
    if kind == "main":
        return "main"
    if agent_type == "llm-efficiency-monitor":
        return "llm"
    for role, rx in ROLE_RULES:
        if rx.search(label or ""):
            return role
    return "other"


def norm_path(p, cwd):
    p = p.strip().strip("'\"")
    if not p or p.startswith("$") or p.startswith("<"):
        return p
    if not os.path.isabs(p) and cwd:
        p = os.path.join(cwd, p)
    p = os.path.normpath(p)
    p = re.sub(r"^/private/tmp/", "/tmp/", p)
    return p


def repo_key(p):
    """Unify the same repository file across worktrees for cross-agent comparisons."""
    p = re.sub(r"^.*/lungfish-genome-explorer/\.claude/worktrees/[^/]+/", "<repo>/", p)
    p = re.sub(r"^.*/lungfish-genome-explorer/", "<repo>/", p)
    p = re.sub(r"^/tmp/claude-\d+/[^/]+/[0-9a-f-]{36}/scratchpad/", "<scratch>/", p)
    return p


def result_size(content):
    """Bytes of text and number of images in a tool_result content."""
    if isinstance(content, str):
        return len(content.encode("utf-8", "replace")), 0, content
    size, imgs, first = 0, 0, ""
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                t = b.get("text") or ""
                size += len(t.encode("utf-8", "replace"))
                if not first:
                    first = t
            elif b.get("type") == "image":
                imgs += 1
    return size, imgs, first


def err_signature(text):
    t = re.sub(r"\x1b\[[0-9;]*m", "", text or "")
    t = t.replace("<tool_use_error>", "").replace("</tool_use_error>", "").strip()
    line = next((x.strip() for x in t.splitlines() if x.strip()), "")
    line = re.sub(r"/[^\s:'\"]+", "<path>", line)
    line = re.sub(r"\d+", "N", line)
    return line[:90]


def summarize_input(name, inp):
    if not isinstance(inp, dict):
        return ""
    if name == "Bash":
        return " ".join(str(inp.get("command", "")).split())[:110]
    for k in ("file_path", "path", "pattern", "description", "query", "url", "to"):
        if k in inp:
            return f"{k}={str(inp[k])[:100]}"
    return ",".join(list(inp.keys())[:4])


class Agent:
    def __init__(self, key, kind):
        self.key = key
        self.kind = kind  # main | sub | sidechain
        self.paths = []
        self.meta = {}
        self.label = ""
        self.first_prompt = ""
        self.events = []  # (ts, order, kind, payload)
        self.msgs = {}  # message id -> dict(model, ts, usage)
        self.seen_uuid = set()
        self.tool_names = Counter()
        self.tool_uses = {}  # id -> dict
        self.results = {}  # id -> dict
        self.compactions = 0
        self.queued = 0
        self.resume_ts = []  # queued messages that are not task notifications (SendMessage resumes)
        self.stop_types = Counter()
        self.api_errors = Counter()
        self.synthetic = Counter()
        self.other_types = Counter()
        self.agent_results = {}  # tool_use_id -> toolUseResult (Agent/SendMessage)
        self.notifications = []  # main: (ts, task-id, status, tokens, tool_uses, duration_ms, size)
        self.cost_state = None
        self.title = None
        self.order = 0


def load_file(path, agents, default_key, default_kind, sid):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if not isinstance(e, dict):
                continue
            et = e.get("type", "?")
            key, kind = default_key, default_kind
            if e.get("agentId"):
                key, kind = e["agentId"], "sub"
            elif default_kind == "main" and e.get("isSidechain"):
                key, kind = "sidechain", "sidechain"
            ag = agents.get(key)
            if ag is None:
                ag = agents[key] = Agent(key, kind)
            if path not in ag.paths:
                ag.paths.append(path)
            uid = e.get("uuid")
            if uid:
                if uid in ag.seen_uuid:
                    continue
                ag.seen_uuid.add(uid)
            ts = parse_ts(e.get("timestamp"))
            ag.order += 1
            o = ag.order
            if et == "assistant":
                handle_assistant(ag, e, ts, o)
            elif et == "user":
                handle_user(ag, e, ts, o)
            elif et == "attachment":
                a = e.get("attachment") if isinstance(e.get("attachment"), dict) else {}
                at = a.get("type", "?")
                if at == "queued_command":
                    ag.queued += 1
                    pq = a.get("prompt")
                    if ts and not (isinstance(pq, str) and "<task-notification>" in pq):
                        ag.resume_ts.append(ts)
                    pr = a.get("prompt")
                    if ag.kind == "main" and isinstance(pr, str) and "<task-notification>" in pr:
                        note_notification(ag, pr, ts)
                    ag.events.append((ts, o, "U", None))
                else:
                    ag.events.append((ts, o, "O", None))
            elif et == "system":
                st = e.get("subtype", "?")
                if st == "compact_boundary":
                    ag.compactions += 1
                if st in ("api_error",) or e.get("level") == "error":
                    ag.api_errors[f"system:{st}"] += 1
                ag.events.append((ts, o, "O", None))
            elif et == "queue-operation":
                if e.get("operation") == "enqueue":
                    c = e.get("content")
                    if isinstance(c, str) and "<task-notification>" in c and ag.kind == "main":
                        note_notification(ag, c, ts)
            elif et == "cost-state":
                if ag.cost_state is None or (e.get("totalCostUSD") or 0) >= (ag.cost_state.get("totalCostUSD") or 0):
                    ag.cost_state = {k: e.get(k) for k in ("totalCostUSD", "totalAPIDuration", "totalDuration",
                                                           "totalToolDuration", "modelUsage")}
            elif et == "custom-title":
                ag.title = e.get("customTitle") or ag.title
            else:
                ag.other_types[et] += 1
                if ts:
                    ag.events.append((ts, o, "O", None))


def note_notification(ag, content, ts):
    d = {}
    for k, rx in TAG_RE.items():
        m = rx.search(content)
        d[k] = m.group(1).strip() if m else None
    if not d.get("task-id"):
        return
    key = (d["task-id"], d.get("status"), d.get("duration_ms"))
    if any(n.get("_key") == key for n in ag.notifications):
        return
    d["_key"] = key
    d["ts"] = ts
    d["size"] = len(content.encode("utf-8", "replace"))
    ag.notifications.append(d)


def handle_assistant(ag, e, ts, o):
    m = e.get("message") if isinstance(e.get("message"), dict) else {}
    mid = m.get("id") or e.get("requestId") or e.get("uuid")
    model = m.get("model") or "?"
    u = m.get("usage") if isinstance(m.get("usage"), dict) else {}
    content = m.get("content")
    if model == "<synthetic>":
        txt = ""
        if isinstance(content, list):
            txt = " ".join(str(b.get("text", "")) for b in content if isinstance(b, dict))
        ag.synthetic[txt[:100]] += 1
        ag.events.append((ts, o, "O", None))
        return
    if e.get("isApiErrorMessage"):
        txt = ""
        if isinstance(content, list):
            txt = " ".join(str(b.get("text", "")) for b in content if isinstance(b, dict))
        ag.api_errors[txt[:100]] += 1
    cc_split = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    otd = u.get("output_tokens_details") if isinstance(u.get("output_tokens_details"), dict) else {}
    cur = {
        "in": u.get("input_tokens") or 0,
        "cc": u.get("cache_creation_input_tokens") or 0,
        "cr": u.get("cache_read_input_tokens") or 0,
        "out": u.get("output_tokens") or 0,
        "w5m": cc_split.get("ephemeral_5m_input_tokens") or 0,
        "w1h": cc_split.get("ephemeral_1h_input_tokens") or 0,
        "think": otd.get("thinking_tokens") or 0,
    }
    rec = ag.msgs.get(mid)
    if rec is None:
        ag.msgs[mid] = {"model": model, "ts": ts, "u": cur, "stop": m.get("stop_reason")}
    else:
        for k, v in cur.items():
            if v > rec["u"][k]:
                rec["u"][k] = v
        if m.get("stop_reason"):
            rec["stop"] = m.get("stop_reason")
    est, est_think = content_estimate(content)
    rec = ag.msgs[mid]
    rec["est"] = rec.get("est", 0.0) + est
    rec["est_think"] = rec.get("est_think", 0.0) + est_think
    ids = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                name = b.get("name") or "?"
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                tid = b.get("id")
                ag.tool_names[name] += 1
                d = {"name": name, "ts": ts, "summary": summarize_input(name, inp), "cwd": e.get("cwd"),
                     "bg": bool(inp.get("run_in_background")), "mid": mid}
                if name == "Bash":
                    cmd = str(inp.get("command", ""))
                    d["build"] = bool(BUILD_RE.search(cmd))
                    d["commit"] = bool(COMMIT_RE.search(cmd))
                    d["reads"] = shell_reads(cmd, e.get("cwd"))
                elif name == "Read":
                    d["read"] = (norm_path(str(inp.get("file_path", "")), e.get("cwd")),
                                 inp.get("offset"), inp.get("limit"))
                elif name in ("Agent", "Task"):
                    pr = str(inp.get("prompt", ""))
                    d["spawn"] = {"description": str(inp.get("description", ""))[:80], "model": inp.get("model"),
                                  "effort": inp.get("effort"), "isolation": inp.get("isolation"),
                                  "subagent_type": inp.get("subagent_type"), "prompt_chars": len(pr),
                                  "prompt_head": pr[:4000]}
                elif name == "SendMessage":
                    msg = inp.get("message", inp.get("content", ""))
                    d["send"] = {"to": str(inp.get("to", inp.get("recipient", ""))),
                                 "chars": len(msg if isinstance(msg, str) else json.dumps(msg))}
                if tid:
                    ag.tool_uses[tid] = d
                    ids.append(tid)
    ag.events.append((ts, o, "A", {"ids": ids, "mid": mid}))


def shell_reads(cmd, cwd):
    out = []
    if "<<" in cmd:
        cmd = cmd.split("<<", 1)[0]
    for rx in READ_CMD_RES:
        for m in rx.finditer(cmd):
            rng = " ".join(m.group(1).split())
            for p in m.group(2).split():
                if p.startswith("-") or p in (">", "<", "|") or "=" in p or "*" in p:
                    continue
                if not re.search(r"[/.]", p):
                    continue
                out.append((norm_path(p, cwd), rng))
    return out


def handle_user(ag, e, ts, o):
    m = e.get("message") if isinstance(e.get("message"), dict) else {}
    content = m.get("content")
    tur = e.get("toolUseResult")
    ids = []
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_result":
                tid = b.get("tool_use_id")
                size, imgs, first = result_size(b.get("content"))
                is_err = bool(b.get("is_error"))
                ag.results[tid] = {"ts": ts, "size": size, "imgs": imgs, "err": is_err,
                                   "sig": err_signature(first) if is_err else ""}
                if "get_usage" in (ag.tool_uses.get(tid, {}).get("name") or ""):
                    ag.results[tid]["text"] = " ".join((first or str(b.get("content")))[:600].split())
                if isinstance(tur, dict) and ag.tool_uses.get(tid, {}).get("name") == "TaskStop":
                    ag.stop_types[str(tur.get("task_type"))] += 1
                if isinstance(tur, dict) and ("agentId" in tur or "resumedAgentId" in tur):
                    ag.agent_results[tid] = {k: tur.get(k) for k in ("agentId", "status", "resolvedModel",
                                                                       "resumedAgentId", "success")}
                ids.append(tid)
            elif b.get("type") == "text" and not e.get("isMeta"):
                if not ag.first_prompt:
                    ag.first_prompt = (b.get("text") or "")[:300] or " "
                elif ag.kind == "sub" and ts and ts not in ag.resume_ts:
                    ag.resume_ts.append(ts)  # a SendMessage that resumed a finished agent
    elif isinstance(content, str) and e.get("isMeta") and ag.kind == "sub" and ts and \
            re.match(r"\s*The (?:coordinator|main agent|parent)[^\n]{0,40}sent a message", content):
        ag.resume_ts.append(ts)  # SendMessage delivered to this agent (running or finished)
    elif isinstance(content, str) and not e.get("isMeta"):
        if not ag.first_prompt:
            ag.first_prompt = content[:300] or " "
        elif ag.kind == "sub" and ts and not content.lstrip().startswith("<task-notification>"):
            ag.resume_ts.append(ts)
    ag.events.append((ts, o, "R" if ids else "U", {"ids": ids}))


def discover(arg, root):
    if arg.endswith(".jsonl") and os.path.exists(arg):
        sid = os.path.basename(arg)[:-6]
        mains = {os.path.abspath(arg)}
    else:
        sid = arg
        mains = set()
    mains |= set(glob.glob(os.path.join(root, "*", sid + ".jsonl")))
    subs = set(glob.glob(os.path.join(root, "*", sid, "subagents", "**", "agent-*.jsonl"), recursive=True))
    titles = []
    for t in glob.glob(os.path.join(root, "*", sid, "custom-title.json")):
        try:
            with open(t) as fh:
                titles.append(json.load(fh).get("customTitle"))
        except Exception:
            pass
    return sid, sorted(mains), sorted(subs), titles


def analyze_agent(ag, now, top):
    r = {"key": ag.key, "kind": ag.kind, "label": ag.label, "paths": ag.paths}
    msgs = sorted(ag.msgs.values(), key=lambda x: x["ts"] or 0)
    est_n, est_added = 0, 0
    for mrec in msgs:  # charge the content estimate where the transcript kept no final usage
        u = mrec["u"]
        e = mrec.get("est", 0.0) / EST_BIAS
        mrec["think_est"] = 0  # thinking tokens the estimate added to the recorded ones
        if not mrec.get("stop") and e > u["out"]:
            est_added += int(e) - u["out"]
            u["out"] = int(e)
            recorded = u["think"]
            u["think"] = max(recorded, int(mrec.get("est_think", 0.0) / EST_BIAS))
            mrec["think_est"] = u["think"] - recorded
            est_n += 1
    r["est_out"] = {"msgs": est_n, "tokens": est_added}
    # what preceded each API turn: R tool result, U message / notification, O other
    prev_kind = {}
    last_kind = None
    for ts_, o_, kind_, pl_ in sorted([x for x in ag.events if x[0]], key=lambda x: (x[0], x[1])):
        if kind_ == "A" and pl_ and pl_["mid"] not in prev_kind:
            prev_kind[pl_["mid"]] = last_kind
        if kind_ != "O" and not (kind_ == "A" and pl_ and prev_kind.get(pl_["mid"]) is not None and last_kind == "A"):
            last_kind = kind_
    mid_of = {id(v): k for k, v in ag.msgs.items()}
    tot = Counter()
    models = Counter()
    by_model = defaultdict(Counter)
    cost, parts = 0.0, Counter()
    ctxs = []
    rebuilds = []
    buckets = {}  # 10-minute bucket start (epoch) -> estimated $
    ctx_hist = {}  # context-size bucket -> [turns, $]
    prev = None
    for mrec in msgs:
        u = mrec["u"]
        for k, v in u.items():
            tot[k] += v
            by_model[mrec["model"]][k] += v
        by_model[mrec["model"]]["turns"] += 1
        by_model[mrec["model"]]["think_est"] += mrec["think_est"]
        by_model[mrec["model"]]["no_final"] += 0 if mrec.get("stop") else 1  # usage is that of message_start
        models[mrec["model"]] += 1
        c, p = cost_of(u, mrec["model"])
        cost += c
        if mrec["ts"]:
            b = int(mrec["ts"] // 600 * 600)
            buckets[b] = buckets.get(b, 0.0) + c
        by_model[mrec["model"]]["cost_micro"] += int(c * 1e6)
        for k, v in p.items():
            parts[k] += v
        ctx = u["in"] + u["cc"] + u["cr"]
        ctxs.append(ctx)
        cb = next(lab for lim, lab in CTX_BUCKETS if ctx < lim)
        ctx_hist.setdefault(cb, [0, 0.0])
        ctx_hist[cb][0] += 1
        ctx_hist[cb][1] += c
        if prev is not None:
            pctx = prev["u"]["in"] + prev["u"]["cc"] + prev["u"]["cr"]
            if u["cc"] > 30000 and u["cr"] < 0.5 * pctx:
                gap = (mrec["ts"] - prev["ts"]) if (mrec["ts"] and prev["ts"]) else None
                cause = {"R": "tool result", "U": "message", "A": "assistant"}.get(prev_kind.get(mid_of.get(id(mrec))), "other")
                rebuilds.append({"ts": mrec["ts"], "tokens": u["cc"], "gap": gap, "cause": cause})
        prev = mrec
    allin = tot["in"] + tot["cc"] + tot["cr"]
    r.update({
        "models": dict(models), "model": models.most_common(1)[0][0] if models else "-",
        "turns": len(msgs), "tokens": dict(tot), "hit": (tot["cr"] / allin) if allin else 0.0,
        "cost": cost, "cost_parts": dict(parts), "by_model": {k: dict(v) for k, v in by_model.items()},
        "peak_ctx": max(ctxs) if ctxs else 0, "mean_ctx": (sum(ctxs) / len(ctxs)) if ctxs else 0,
        "first_turn": ({"cr": msgs[0]["u"]["cr"], "cc": msgs[0]["u"]["cc"]} if msgs else None),
        "rebuilds": rebuilds, "rebuild_tokens": sum(x["tokens"] for x in rebuilds), "cost_10min": buckets,
        "ctx_hist": ctx_hist,
        "compactions": ag.compactions, "queued": ag.queued,
        "api_errors": dict(ag.api_errors), "synthetic": dict(ag.synthetic),
        "other_types": dict(ag.other_types),
    })
    # time decomposition
    evs = sorted([x for x in ag.events if x[0]], key=lambda x: (x[0], x[1]))
    pending = {}
    acc = Counter()
    gaps = []
    for i, (ts, o, kind, pl) in enumerate(evs):
        if i:
            pts = evs[i - 1][0]
            gap = ts - pts
            if pending:
                cls = "tool"
                what = ", ".join(sorted({ag.tool_uses[t]["name"] for t in pending if t in ag.tool_uses}))[:60]
                tid = next(iter(pending))
                what = (what + ": " + ag.tool_uses.get(tid, {}).get("summary", ""))[:120]
            elif kind == "A":
                cls, what = "model", ""
            else:
                cls, what = "idle", "waiting for input"
            acc[cls] += gap
            gaps.append((gap, pts, cls, what))
        if kind == "A" and pl:
            for t in pl["ids"]:
                pending[t] = ts
        elif kind == "R" and pl:
            for t in pl["ids"]:
                pending.pop(t, None)
    first_ts = evs[0][0] if evs else None
    last_ts = evs[-1][0] if evs else None
    r.update({"first_ts": first_ts, "last_ts": last_ts,
              "wall": (last_ts - first_ts) if evs else 0, "time": dict(acc)})
    gaps.sort(reverse=True)
    r["top_gaps"] = [{"sec": g, "at": a, "class": c, "what": w} for g, a, c, w in gaps[:top]]
    # tools
    r["tools"] = dict(ag.tool_names.most_common())
    builds, fails, longcalls, pend = [], Counter(), [], []
    big = []
    reads = defaultdict(list)
    commits = 0
    mid_ctx = {k: v["u"]["in"] + v["u"]["cc"] + v["u"]["cr"] for k, v in ag.msgs.items()}
    fail_mids, guard = set(), 0
    usage_reads = []
    owner_wait = 0.0
    msg_ts = sorted(m["ts"] for m in msgs if m["ts"])
    pr = price_for(r["model"]) or PRICES["opus"]
    life_by = Counter()
    seen_reads = set()
    for tid, d in ag.tool_uses.items():
        res = ag.results.get(tid)
        dur = (res["ts"] - d["ts"]) if (res and res["ts"] and d["ts"]) else None
        if res and res.get("text"):
            usage_reads.append({"ts": d["ts"], "text": res["text"]})
        if d["name"] in OWNER_TOOLS:
            owner_wait += dur or 0
            continue
        if res and res["err"]:
            fail_mids.add(d.get("mid"))
            if GUARD_RE.search(res["sig"]):
                guard += 1
        if d.get("commit") and res and not res["err"]:
            commits += 1
        if d.get("build"):
            builds.append({"cmd": d["summary"], "sec": dur, "bg": d["bg"], "err": bool(res and res["err"]),
                           "ts": d["ts"], "done": res is not None})
        if res is None:
            ref_end = now if now else last_ts
            age_end = (last_ts - d["ts"]) if (last_ts and d["ts"]) else None
            age_now = (ref_end - d["ts"]) if (ref_end and d["ts"]) else None
            pend.append({"tool": d["name"], "summary": d["summary"], "since": d["ts"],
                         "age_to_last_entry": age_end, "age_to_now": age_now,
                         "hang": bool(age_now and age_now > HANG_SECONDS)})
            continue
        if res["err"]:
            fails[(d["name"], res["sig"])] += 1
        if dur is not None and dur > HANG_SECONDS:
            longcalls.append({"tool": d["name"], "summary": d["summary"], "sec": dur, "build": bool(d.get("build")),
                              "ts": d["ts"]})
        # context-lifetime cost: the result is written to cache once, then re-read on every later turn
        life = 0.0
        if res["ts"] and res["size"]:
            remaining = len(msg_ts) - bisect.bisect_right(msg_ts, res["ts"])
            t_est = res["size"] / CHARS_PER_TOKEN
            life = t_est * (remaining * pr["read"] + pr["w5m"]) / 1e6
            life_by["all"] += life
            life_by["tool:" + d["name"]] += life
        if res["size"] > BIG_RESULT:
            big.append({"tool": d["name"], "summary": d["summary"], "bytes": res["size"], "life_cost": life})
            life_by["big"] += life
        keys = []
        if d.get("read"):
            reads[d["read"][0]].append((d["read"][1], d["read"][2], res["size"]))
            keys.append((d["read"][0], d["read"][1], d["read"][2]))
        for p, rng in d.get("reads", []) or []:
            reads[p].append(("sh", rng, res["size"] / max(1, len(d["reads"]))))
            keys.append((p, "sh", rng))
        if keys and all(k in seen_reads for k in keys):
            life_by["reread"] += life
        seen_reads.update(keys)
    r["builds"] = sorted(builds, key=lambda x: x["ts"] or 0)
    r["fails"] = [{"tool": k[0], "sig": k[1], "n": v} for k, v in fails.most_common()]
    r["fail_count"] = sum(fails.values())
    r["guard_rejections"] = guard
    r["failed_turn_ctx_tokens"] = sum(mid_ctx.get(m, 0) for m in fail_mids)
    r["usage_reads"] = sorted(usage_reads, key=lambda x: x["ts"] or 0)
    r["owner_wait"] = owner_wait
    r["long_calls"] = sorted(longcalls, key=lambda x: -x["sec"])
    r["pending"] = pend
    r["big_results"] = sorted(big, key=lambda x: -x["bytes"])
    r["big_bytes"] = sum(x["bytes"] for x in big)
    r["commits"] = commits
    rr = []
    for p, lst in reads.items():
        if len(lst) > 1:
            ranges = {(a, b) for a, b, _ in lst}
            sizes = [s for _, _, s in lst]
            rr.append({"path": p, "n": len(lst), "ranges": len(ranges), "bytes": sum(sizes),
                       "repeat_bytes": sum(sizes) - max(sizes)})
    rr.sort(key=lambda x: (-x["n"], -x["bytes"]))
    r["rereads"] = rr
    r["reread_calls"] = sum(x["n"] - 1 for x in rr)
    r["reread_bytes"] = sum(x["repeat_bytes"] for x in rr)
    r["read_paths"] = {p: sum(s for _, _, s in lst) for p, lst in reads.items()}
    r["result_bytes"] = sum(x["size"] for x in ag.results.values())
    r["images"] = sum(x["imgs"] for x in ag.results.values())
    r["result_life_cost"] = dict(life_by)
    # cost after resumes (SendMessage to this agent), e.g. review fix rounds
    segs = []
    rts = sorted(ag.resume_ts) if ag.kind == "sub" else []
    tev = sorted([x for x in ag.events if x[0]], key=lambda x: (x[0], x[1]))
    tev_ts = [x[0] for x in tev]
    for i, t0 in enumerate(rts):
        t1 = rts[i + 1] if i + 1 < len(rts) else float("inf")
        seg = [m for m in msgs if m["ts"] and t0 <= m["ts"] < t1]
        if not seg:
            continue
        # was the agent idle (its last turn ended) when the message arrived, and for how long?
        j = bisect.bisect_left(tev_ts, t0) - 1
        prev_a = next((tev[k] for k in range(j, -1, -1) if tev[k][2] == "A" and tev[k][3]), None)
        prev_any = tev[j][0] if j >= 0 else None
        idle = bool(prev_a and (ag.msgs.get(prev_a[3]["mid"]) or {}).get("stop") == "end_turn")
        c = sum(cost_of(m["u"], m["model"])[0] for m in seg)
        first = seg[0]["u"]
        segs.append({"ts": t0, "turns": len(seg), "cost": c, "idle": idle,
                     "idle_gap": (t0 - prev_a[0]) if (idle and prev_a) else None,
                     "since_last_entry": (t0 - prev_any) if prev_any else None,
                     "first_ctx": first["in"] + first["cc"] + first["cr"], "first_cc": first["cc"],
                     "mean_ctx": sum(m["u"]["in"] + m["u"]["cc"] + m["u"]["cr"] for m in seg) / len(seg)})
    r["resume_segments"] = segs
    r["stop_types"] = dict(ag.stop_types)
    # orchestration (main)
    spawns, sends, stops = [], Counter(), 0
    for tid, d in ag.tool_uses.items():
        if "spawn" in d:
            ar = ag.agent_results.get(tid, {})
            s = dict(d["spawn"])
            s["agentId"] = ar.get("agentId")
            s["ts"] = d["ts"]
            spawns.append(s)
        if "send" in d:
            ar = ag.agent_results.get(tid, {})
            sends[ar.get("resumedAgentId") or d["send"]["to"]] += 1
        if d["name"] == "TaskStop":
            stops += 1
    spawns.sort(key=lambda x: x["ts"] or 0)
    # brief prefix sharing: longest common prefix with any earlier brief
    for i, s in enumerate(spawns):
        best = 0
        for q in spawns[:i]:
            a, b = s["prompt_head"], q["prompt_head"]
            n = 0
            for x, y in zip(a, b):
                if x != y:
                    break
                n += 1
            best = max(best, n)
        s["shared_prefix_chars"] = best
    r["spawns"] = [{k: v for k, v in s.items() if k != "prompt_head"} for s in spawns]
    r["sends"] = dict(sends)
    r["task_stops"] = stops
    r["notifications"] = [{k: v for k, v in n.items() if k != "_key"} for n in ag.notifications]
    r["cost_state"] = ag.cost_state
    return r


def request_of(r):
    """The model and effort an agent's spawn asked for, with the model its turns ran on beside them. Each setting comes
    from the Agent call's input, else the subagent's meta, else UNSET. A transcript's own effort field is not used: it
    reads the session's setting on every message, not the spawn's."""
    sp, meta = r.get("spawn") or {}, r.get("meta") or {}
    return {"model": sp.get("model") or meta.get("model") or UNSET,
            "effort": sp.get("effort") or meta.get("effort") or UNSET,
            "agent_type": sp.get("subagent_type") or meta.get("agentType") or UNSET,
            "ran_on": r["model"]}


def role_model_effort_rows(agents):
    """The rows of "By role, model and effort". A turn is grouped under the model it ran on, so an agent that ran on two
    models counts in both of its rows. Thinking is the recorded thinking plus what the content estimate added for turns
    that kept no final usage, and its share is of the output the ledger charges."""
    cells = {}
    for r in agents:
        for model, d in (r["by_model"] or {"-": {}}).items():  # an agent with no turns still gets a row
            c = cells.setdefault((r["role"], model, r["request"]["effort"]), Counter())
            c["agents"] += 1
            for k in ("turns", "out", "think", "think_est", "no_final", "cost_micro"):
                c[k] += d.get(k, 0)
    rows = [{"role": role, "model": model, "effort": effort, "agents": c["agents"], "turns": c["turns"],
             "out": c["out"], "think_recorded": c["think"] - c["think_est"], "think_estimated": c["think_est"],
             "think_share": (c["think"] / c["out"]) if c["out"] else None, "no_final_usage": c["no_final"],
             "cost": c["cost_micro"] / 1e6} for (role, model, effort), c in cells.items()]
    role_cost = Counter()
    for x in rows:
        role_cost[x["role"]] += x["cost"]
    rows.sort(key=lambda x: (-role_cost[x["role"]], x["role"], -x["cost"], x["model"], x["effort"]))
    return rows


def spawns_without_model_or_effort(agents):
    """The rows of "Spawns without model or effort": one per spawned agent whose spawn set no model or no effort. The
    manager's main transcript is not a spawn."""
    rows = []
    for r in agents:
        if r["kind"] != "sub":
            continue
        q = r["request"]
        missing = [k for k in ("model", "effort") if q[k] == UNSET]
        if missing:
            rows.append({"key": r["key"], "label": r["label"], "agent_type": q["agent_type"], "missing": missing,
                         "model": q["model"], "effort": q["effort"], "ran_on": q["ran_on"]})
    return rows


def load_session(arg, root, now, top):
    sid, mains, subs, titles = discover(arg, root)
    agents = {}
    for p in mains:
        load_file(p, agents, "main", "main", sid)
    for p in subs:
        aid = os.path.basename(p)[len("agent-"):-len(".jsonl")]
        load_file(p, agents, aid, "sub", sid)
        ag = agents.get(aid)
        mp = p[:-len(".jsonl")] + ".meta.json"
        if ag is not None and os.path.exists(mp):
            try:
                with open(mp) as fh:
                    ag.meta = json.load(fh)
            except Exception:
                pass
    results = []
    session_last = max((e[0] for ag in agents.values() for e in ag.events if e[0]), default=None)
    live = bool(now and session_last and now - session_last < 1800)
    now = now if live else None  # age pending calls to now only while the session is live
    for key, ag in agents.items():
        if ag.kind == "main":
            ag.label = "main: " + (titles[0] if titles else (ag.title or sid[:8]))
        else:
            desc = ag.meta.get("description") if ag.meta else None
            fp = (ag.first_prompt or "").strip().splitlines()
            ag.label = desc or (fp[0][:80] if fp else key)
        r = analyze_agent(ag, now, top)
        r["meta"] = {k: ag.meta.get(k) for k in ("agentType", "model", "effort", "spawnedWithWorktree",
                                                   "worktreePath", "spawnDepth")} if ag.meta else {}
        r["role"] = role_of(r["label"], ag.kind, (ag.meta or {}).get("agentType"))
        results.append(r)
    # map spawn info onto subagents
    main = next((r for r in results if r["kind"] == "main"), None)
    if main:
        byid = {s.get("agentId"): s for s in main["spawns"] if s.get("agentId")}
        for r in results:
            s = byid.get(r["key"])
            if s:
                r["spawn"] = {k: s.get(k) for k in ("prompt_chars", "shared_prefix_chars", "model", "effort",
                                                     "subagent_type", "isolation", "ts")}
            r["resumes"] = main["sends"].get(r["key"], 0)
    for r in results:
        r["request"] = request_of(r)
    results.sort(key=lambda r: (r["kind"] != "main", r["first_ts"] or 0))
    return {"session": sid, "titles": titles, "mains": mains, "subagent_files": len(subs), "agents": results,
            "live": live, "by_role_model_effort": role_model_effort_rows(results),
            "spawns_without_model_or_effort": spawns_without_model_or_effort(results)}


def aggregate(agents):
    t = Counter()
    for r in agents:
        for k, v in r["tokens"].items():
            t[k] += v
        t["turns"] += r["turns"]
        t["cost"] += r["cost"]
        for k, v in r["cost_parts"].items():
            t["cost_" + k] += v
        t["fails"] += r["fail_count"]
        t["guard"] += r["guard_rejections"]
        t["failed_turn_ctx"] += r["failed_turn_ctx_tokens"]
        t["owner_wait"] += r["owner_wait"]
        t["big_n"] += len(r["big_results"])
        t["big_bytes"] += r["big_bytes"]
        t["reread_calls"] += r["reread_calls"]
        t["reread_bytes"] += r["reread_bytes"]
        t["rebuild_tokens"] += r["rebuild_tokens"]
        t["rebuilds"] += len(r["rebuilds"])
        t["compactions"] += r["compactions"]
        t["builds"] += len(r["builds"])
        t["build_sec"] += sum(b["sec"] or 0 for b in r["builds"])
        t["commits"] += r["commits"]
        t["tool_calls"] += sum(r["tools"].values())
        t["result_bytes"] += r["result_bytes"]
        for k, v in r["time"].items():
            t["time_" + k] += v
    allin = t["in"] + t["cc"] + t["cr"]
    t["hit"] = (t["cr"] / allin) if allin else 0
    return t


def md_session(S, top):
    out = []
    A = S["agents"]
    T = aggregate(A)
    first = min((r["first_ts"] for r in A if r["first_ts"]), default=None)
    last = max((r["last_ts"] for r in A if r["last_ts"]), default=None)
    out.append(f"## Session {S['session']} - {', '.join(t for t in S['titles'] if t) or '(untitled)'}\n")
    out.append(f"- main transcripts: {len(S['mains'])}; subagent transcripts: {S['subagent_files']}; agents: {len(A)}")
    out.append(f"- span: {local(first)} to {local(last)} local ({hms((last - first) if first and last else None)})")
    main = next((r for r in A if r["kind"] == "main"), None)
    if main and main.get("cost_state"):
        cs = main["cost_state"]
        mu = cs.get("modelUsage") or {}
        out.append(f"- Claude Code cost-state: ${cs.get('totalCostUSD', 0):.2f} total, API time "
                   f"{hms((cs.get('totalAPIDuration') or 0) / 1000)}, "
                   + "; ".join(f"{m}: ${d.get('costUSD', 0):.2f}" for m, d in mu.items()))
    out.append(f"- ledger estimate: ${T['cost']:.2f} (read ${T['cost_read']:.2f}, write ${T['cost_write']:.2f}, "
               f"output ${T['cost_out']:.2f}, input ${T['cost_in']:.2f}); cache hit {100 * T['hit']:.1f}%")
    en = sum((r.get("est_out") or {}).get("msgs", 0) for r in A)
    if en:
        et = sum((r.get("est_out") or {}).get("tokens", 0) for r in A)
        out.append(f"- output estimated from content for {en} messages without a final usage: +{tok(et)} tokens")
    out.append("")
    out.append("### Totals\n")
    out.append("| turns | input | cache write | cache read | output | hit % | est $ | tool calls | failed (guard; ctx of failing turns) | >20KB results | re-reads | cache rebuilds | compactions | build/test calls | commits |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    out.append(f"| {T['turns']} | {tok(T['in'])} | {tok(T['cc'])} | {tok(T['cr'])} | {tok(T['out'])} | {100 * T['hit']:.1f} | "
               f"{T['cost']:.2f} | {T['tool_calls']} | {T['fails']} ({T['guard']}; {tok(T['failed_turn_ctx'])}) | "
               f"{T['big_n']} ({T['big_bytes'] / 1024:.0f} KB) | "
               f"{T['reread_calls']} ({T['reread_bytes'] / 1024:.0f} KB) | {T['rebuilds']} ({tok(T['rebuild_tokens'])}) | "
               f"{T['compactions']} | {T['builds']} ({hms(T['build_sec'])}) | {T['commits']} |")
    out.append("")
    # by model
    bym = defaultdict(Counter)
    for r in A:
        for m, d in r["by_model"].items():
            for k, v in d.items():
                bym[m][k] += v
    out.append("### By model\n")
    out.append("| model | turns | input | cache write (5m / 1h) | cache read | output (thinking) | hit % | est $ |")
    out.append("|---|---|---|---|---|---|---|---|")
    for m, d in sorted(bym.items(), key=lambda x: -x[1]["cost_micro"]):
        ai = d["in"] + d["cc"] + d["cr"]
        out.append(f"| {m} | {d['turns']} | {tok(d['in'])} | {tok(d['cc'])} ({tok(d['w5m'])} / {tok(d['w1h'])}) | "
                   f"{tok(d['cr'])} | {tok(d['out'])} ({tok(d['think'])}) | {100 * d['cr'] / ai if ai else 0:.1f} | "
                   f"{d['cost_micro'] / 1e6:.2f} |")
    out.append("")
    # by role
    byr = defaultdict(list)
    for r in A:
        byr[r["role"]].append(r)
    out.append("### By role\n")
    out.append("| role | agents | est $ | $ median | turns median | wall median | active median (model+tool) | peak ctx median | builds | fails |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for role, rs in sorted(byr.items(), key=lambda x: -sum(r["cost"] for r in x[1])):
        med = lambda xs: sorted(xs)[len(xs) // 2] if xs else 0
        out.append(f"| {role} | {len(rs)} | {sum(r['cost'] for r in rs):.2f} | {med([r['cost'] for r in rs]):.2f} | "
                   f"{med([r['turns'] for r in rs])} | {hms(med([r['wall'] for r in rs]))} | "
                   f"{hms(med([r['time'].get('model', 0) + r['time'].get('tool', 0) for r in rs]))} | "
                   f"{tok(med([r['peak_ctx'] for r in rs]))} | {sum(len(r['builds']) for r in rs)} | "
                   f"{sum(r['fail_count'] for r in rs)} |")
    out.append("")
    out.append("### By role, model and effort\n")
    out.append("Effort is what the agent's spawn asked for (the Agent call's, else the subagent meta's, else unset) and the "
               "model is the one its turns ran on. Thinking is recorded where the transcript kept it and estimated from "
               "content for turns that kept no final usage.\n")
    out.append("| role | model | effort | agents | turns | output | thinking recorded | thinking estimated | thinking % of output | turns without final usage | est $ |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for x in S["by_role_model_effort"]:
        share = f"{100 * x['think_share']:.1f}" if x["think_share"] is not None else "-"
        out.append(f"| {x['role']} | {x['model']} | {x['effort']} | {x['agents']} | {x['turns']} | {tok(x['out'])} | "
                   f"{tok(x['think_recorded'])} | {tok(x['think_estimated'])} | {share} | {x['no_final_usage']} | "
                   f"{x['cost']:.2f} |")
    out.append("")
    out.append("### Spawns without model or effort\n")
    if S["spawns_without_model_or_effort"]:
        out.append("| id | agent | agent type | missing | model | effort | ran on |")
        out.append("|---|---|---|---|---|---|---|")
        for x in S["spawns_without_model_or_effort"]:
            out.append(f"| {x['key']} | {x['label'][:48].replace('|', '/')} | {x['agent_type']} | "
                       f"{' and '.join(x['missing'])} | {x['model']} | {x['effort']} | {x['ran_on']} |")
    else:
        out.append("- none")
    out.append("")
    out.append("### Per agent\n")
    out.append("| # | agent | id | role | model | turns | input | cache wr | cache rd | output | hit % | est $ | wall | model / tool / idle | first-turn rd/wr | mean / peak ctx | top tools | builds (n, time) | fails (guard) | >20KB | re-reads | rebuilds | resumes |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for i, r in enumerate(A):
        t = r["tokens"]
        tt = r["time"]
        tools = ", ".join(f"{k} {v}" for k, v in list(r["tools"].items())[:3])
        bs = sum(b["sec"] or 0 for b in r["builds"])
        ft = r["first_turn"] or {}
        eff = (r.get("meta") or {}).get("effort") or ""
        mdl = r["model"].replace("claude-", "") + (f" {eff}" if eff else "")
        out.append(
            f"| {i} | {r['label'][:48].replace('|', '/')} | {r['key'][:8]} | {r['role']} | {mdl} | {r['turns']} | "
            f"{tok(t.get('in'))} | {tok(t.get('cc'))} | {tok(t.get('cr'))} | {tok(t.get('out'))} | {100 * r['hit']:.1f} | "
            f"{r['cost']:.2f} | {hms(r['wall'])} | {hms(tt.get('model'))} / {hms(tt.get('tool'))} / {hms(tt.get('idle'))} | "
            f"{tok(ft.get('cr'))}/{tok(ft.get('cc'))} | {tok(r['mean_ctx'])} / {tok(r['peak_ctx'])} | {tools} | "
            f"{len(r['builds'])}, {hms(bs)} | {r['fail_count']} ({r['guard_rejections']}) | "
            f"{len(r['big_results'])} ({r['big_bytes'] / 1024:.0f}K) | {r['reread_calls']} | "
            f"{len(r['rebuilds'])} ({tok(r['rebuild_tokens'])}) | {r.get('resumes', 0)} |")
    out.append("")
    # flags
    out.append("### Flags\n")
    flags = []
    for r in A:
        for p in r["pending"]:
            tag = "HANG" if p["hang"] else ("pending (live)" if S.get("live") else "unfinished at end")
            flags.append(f"- {tag}: {r['label'][:40]} ({r['key'][:8]}) {p['tool']} since {local(p['since'])}, "
                         f"{hms(p['age_to_now'])} to now/end, {hms(p['age_to_last_entry'])} to last entry: `{p['summary'][:90]}`")
        for c in r["long_calls"]:
            # foreground Bash calls time out after at most 10 minutes, so one over 15 minutes hung
            tag = "HANG (Bash over 15 min)" if c["tool"] == "Bash" else ("long build/test" if c["build"] else "long call")
            flags.append(f"- {tag}: {r['label'][:40]} ({r['key'][:8]}) {c['tool']} {hms(c['sec'])} at {local(c['ts'])}: `{c['summary'][:90]}`")
        if r["compactions"]:
            flags.append(f"- compaction x{r['compactions']}: {r['label'][:40]} ({r['key'][:8]})")
        for k, v in r["api_errors"].items():
            flags.append(f"- API error x{v}: {r['label'][:40]}: {k}")
        for k, v in r["synthetic"].items():
            flags.append(f"- synthetic message x{v}: {r['label'][:40]}: {k[:80]}")
        big_rb = [x for x in r["rebuilds"] if x["tokens"] > 100000]
        if big_rb:
            flags.append(f"- cache rebuilds over 100K tokens: {r['label'][:40]} ({r['key'][:8]}) x{len(big_rb)} = "
                         f"{tok(sum(x['tokens'] for x in big_rb))} (gaps before: "
                         + ", ".join(hms(x['gap']) for x in big_rb[:6]) + ")")
    out.extend(flags or ["- none"])
    out.append("")
    # builds
    allb = [(r, b) for r in A for b in r["builds"]]
    if allb:
        out.append("### Build and test calls (longest first)\n")
        out.append("| agent | when | duration | bg | error | command |")
        out.append("|---|---|---|---|---|---|")
        for r, b in sorted(allb, key=lambda x: -(x[1]["sec"] or 0))[:top]:
            out.append(f"| {r['label'][:36]} | {local(b['ts'])} | {hms(b['sec'])}{'' if b['done'] else ' (no result)'} | "
                       f"{'y' if b['bg'] else ''} | {'y' if b['err'] else ''} | `{b['cmd'][:90].replace('|', '/')}` |")
        out.append("")
    # failures
    fc = Counter()
    for r in A:
        for f in r["fails"]:
            fc[(f["tool"], f["sig"])] += f["n"]
    if fc:
        out.append("### Failed tool results (by signature)\n")
        out.append("| n | tool | signature |")
        out.append("|---|---|---|")
        for (tool, sig), n in fc.most_common(top):
            out.append(f"| {n} | {tool} | `{sig.replace('|', '/')}` |")
        out.append("")
    # re-reads
    rr = [(r, x) for r in A for x in r["rereads"]]
    if rr:
        out.append("### Files read more than once by the same agent (top)\n")
        out.append("| agent | file | reads | ranges | KB total | KB repeated |")
        out.append("|---|---|---|---|---|---|")
        for r, x in sorted(rr, key=lambda y: -y[1]["repeat_bytes"])[:top]:
            out.append(f"| {r['label'][:36]} | `{repo_key(x['path'])[-70:]}` | {x['n']} | {x['ranges']} | "
                       f"{x['bytes'] / 1024:.0f} | {x['repeat_bytes'] / 1024:.0f} |")
        out.append("")
    # cross-agent reads
    xr = defaultdict(lambda: [0, 0.0])
    for r in A:
        for p, b in r["read_paths"].items():
            k = repo_key(p)
            xr[k][0] += 1
            xr[k][1] += b
    multi = [(k, v) for k, v in xr.items() if v[0] >= 3]
    if multi:
        out.append("### Files read by three or more agents\n")
        out.append("| file | agents | KB total |")
        out.append("|---|---|---|")
        for k, v in sorted(multi, key=lambda x: (-x[1][0], -x[1][1]))[:top]:
            out.append(f"| `{k[-80:]}` | {v[0]} | {v[1] / 1024:.0f} |")
        out.append(f"\nAll multi-agent reads: {len(multi)} files, {sum(v[1] for _, v in multi) / 1024:.0f} KB pulled "
                   f"into {sum(v[0] for _, v in multi)} contexts.\n")
    # big results
    bb = [(r, x) for r in A for x in r["big_results"]]
    if bb:
        out.append("### Tool results over 20 KB (largest)\n")
        out.append("| agent | tool | KB | input |")
        out.append("|---|---|---|---|")
        for r, x in sorted(bb, key=lambda y: -y[1]["bytes"])[:top]:
            s = x["summary"]
            s = repo_key(s.split("=", 1)[1]) if s.startswith("file_path=") else s
            s = s if len(s) <= 80 else "..." + s[-77:]
            out.append(f"| {r['label'][:36]} | {x['tool']} | {x['bytes'] / 1024:.0f} | `{s.replace('|', '/')}` |")
        out.append("")
    # gaps
    gg = [(r, g) for r in A for g in r["top_gaps"]]
    if gg:
        out.append("### Longest gaps between entries\n")
        out.append("| agent | at | gap | class | waiting on |")
        out.append("|---|---|---|---|---|")
        for r, g in sorted(gg, key=lambda y: -y[1]["sec"])[:top]:
            out.append(f"| {r['label'][:36]} | {local(g['at'])} | {hms(g['sec'])} | {g['class']} | {g['what'][:90].replace('|', '/')} |")
        out.append("")
    # orchestration
    if main:
        out.append("### Orchestration (main session)\n")
        out.append(f"- spawns {len(main['spawns'])}, SendMessage {sum(main['sends'].values())} "
                   f"(to {len(main['sends'])} agents), TaskStop {main['task_stops']}, "
                   f"task notifications {len(main['notifications'])} "
                   f"({sum(n['size'] for n in main['notifications']) / 1024:.0f} KB into main context)")
        st = Counter(n.get("status") for n in main["notifications"])
        out.append(f"- notification statuses: {dict(st)}; owner waits (AskUserQuestion): {hms(main['owner_wait'])}")
        for u in main["usage_reads"]:
            out.append(f"- quota reading {local(u['ts'])}: {u['text'][:260]}")
        if main["spawns"]:
            out.append("\n| when | description | model | effort | isolation | brief chars | shared prefix | agent |")
            out.append("|---|---|---|---|---|---|---|---|")
            for s in main["spawns"]:
                out.append(f"| {local(s['ts'])} | {s['description'][:50].replace('|', '/')} | {s.get('model') or '-'} | "
                           f"{s.get('effort') or '-'} | {s.get('isolation') or '-'} | {s['prompt_chars']} | "
                           f"{s['shared_prefix_chars']} | {(s.get('agentId') or '-')[:8]} |")
        out.append("")
    return out, T


def main_cli():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("targets", nargs="+")
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--md")
    ap.add_argument("--json")
    ap.add_argument("--now", help="ISO time used to age pending tool calls (default: now for live sessions)")
    ap.add_argument("--top", type=int, default=12)
    a = ap.parse_args()
    now = parse_ts(a.now) if a.now else time.time()
    sessions = [load_session(t, a.root, now, a.top) for t in a.targets]
    lines = [f"# Session ledger ({time.strftime('%Y-%m-%d %H:%M')} local)\n"]
    totals = Counter()
    for S in sessions:
        out, T = md_session(S, a.top)
        lines.extend(out)
        for k, v in T.items():
            if isinstance(v, (int, float)):
                totals[k] += v
    if len(sessions) > 1:
        ai = totals["in"] + totals["cc"] + totals["cr"]
        lines.append("## All sessions\n")
        lines.append(f"- turns {totals['turns']}, cache read {tok(totals['cr'])}, cache write {tok(totals['cc'])}, "
                     f"output {tok(totals['out'])}, hit {100 * totals['cr'] / ai if ai else 0:.1f}%, est ${totals['cost']:.2f}")
    text = "\n".join(lines) + "\n"
    if a.md:
        with open(a.md, "w") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(sessions, fh, indent=1, default=str)


if __name__ == "__main__":
    main_cli()
