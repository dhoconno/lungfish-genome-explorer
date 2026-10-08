"""Normalization rules for the Phase 1 golden fixtures.

Rules come in four classes. Tests/Fixtures/golden/README.md lists every rule.

- Binding rules come from the lane brief. They mask wall-clock timestamps,
  wall-clock durations and per-run identifiers, and replace the scratch root
  with RUN_ROOT_TOKEN.
- Ruled rules were approved by the program manager on 2026-10-02. Each one
  carries the row of the two-run volatility catalog it was approved for (R5 to
  R16) or the question it answers (Q3).
- The second ruling round approved N1 and N2, which cover nondeterminism in
  the app and random identifiers in tool output. `golden.py compare --strict`
  leaves them out to show what they hide.
- The owner approved H1 and H2 on 2026-10-08. They mask the macOS version and
  build and the active core count, so the goldens pass on every Mac.

Every rule works on the raw text, so formatting, key order and escaping of
everything a rule does not touch are still compared byte for byte.
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import re
import zipfile
from dataclasses import dataclass, field
from typing import Iterable

RUN_ROOT_TOKEN = "<RUN_ROOT>"
TIMESTAMP_TOKEN = "<TIMESTAMP>"
DURATION_TOKEN = "<DURATION>"
EPOCH_TOKEN = "<EPOCH>"
APP_VERSION_TOKEN = "<APP_VERSION>"
PID_TOKEN = "<PID>"
TRUNCATED_LINE_TOKEN = "<TRUNCATED-LINE>"

HASH_KEYS = ("checksumSHA256", "sha256")
SIZE_KEYS = ("fileSize", "sizeBytes", "size_bytes")

# ---------------------------------------------------------------------------
# Binding rules (lane brief)

# ISO 8601 and RFC 3339 dates and date-times, including the dashed time form
# that appears in folder names (2026-10-02T09-03-00) and the comma fraction
# Python logging writes (2026-10-02 09:13:05,754). A bare date counts, because
# a date written from the wall clock changes from one day to the next.
_ISO_TIMESTAMP = re.compile(
    r"(?<![0-9])"
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}"
    r"(?:[T ][0-9]{2}[:\-][0-9]{2}(?:[:\-][0-9]{2}(?:[.,][0-9]+)?)?"
    r"(?:Z|[+\-][0-9]{2}:?[0-9]{2})?)?"
    r"(?![0-9])"
)

# The same shape with the time part required, for worksheet cells (R14).
_ISO_DATETIME = re.compile(
    r"(?<![0-9])"
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}"
    r"[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:[.,][0-9]+)?)?"
    r"(?:Z|[+\-][0-9]{2}:?[0-9]{2})?"
    r"(?![0-9])"
)

_UUID = re.compile(
    r"(?<![0-9A-Fa-f])"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    r"(?![0-9A-Fa-f])"
)

_NUMBER = r"-?[0-9]+(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?"

# JSON keys whose numeric value is a wall-clock instant. A value is masked only
# when it also falls in a plausible range for a current Unix epoch (seconds or
# milliseconds) or a Foundation reference-date epoch (seconds since 2001), so a
# key reused for something else keeps its value.
EPOCH_KEYS = (
    "createdAt",
    "endTime",
    "endedAt",
    "finishedAt",
    "recordedAt",
    "startTime",
    "startedAt",
    "timestamp",
)

# JSON keys whose value is a duration measured from the wall clock. Some
# writers store the number as a string, so a quoted number is masked too.
DURATION_KEYS = (
    "duration",
    "durationSeconds",
    "elapsedSeconds",
    "runtime",
    "runtimeSeconds",
    "wallClockSeconds",
    "wallTime",
    "wallTimeSeconds",
)


def _key_value_pattern(keys: Iterable[str]) -> re.Pattern[str]:
    alternatives = "|".join(re.escape(key) for key in keys)
    return re.compile(r'("(?:' + alternatives + r')"\s*:\s*)("?)(' + _NUMBER + r")\2(?![0-9.eE])")


_EPOCH_VALUE = _key_value_pattern(EPOCH_KEYS)
_DURATION_VALUE = _key_value_pattern(DURATION_KEYS)

# Wall-clock durations that tools print in their logs. The numbers are elapsed
# time, so they are binding. The neighbouring CPU and memory figures are masked
# by the ruled rules R6 and R7 below.
_TOOL_LOG_DURATIONS = (
    # EsViritu: "Completed trim_filter in 0.29 seconds"
    re.compile(r"(Completed [A-Za-z0-9_]+ in )(" + _NUMBER + r")( seconds)"),
    # EsViritu: "reactable report finished in 1.27 seconds"
    re.compile(r"(finished in )(" + _NUMBER + r")( seconds)"),
    # fastp: "fastp v1.3.7, time used: 0 seconds"
    re.compile(r"(time used: )([0-9]+)( seconds)"),
    # minimap2: "[M::main] Real time: 0.005 sec"
    re.compile(r"(Real time: )(" + _NUMBER + r")( sec)"),
    # kraken2: "55 sequences (0.01 Mbp) processed in 0.003s"
    re.compile(r"(processed in )(" + _NUMBER + r")(s )"),
    # lungfish-cli: "Classification completed in 1.1s" and "  Runtime: 1.1s"
    re.compile(r"(completed in )(" + _NUMBER + r")(s\b)"),
    re.compile(r"(Runtime: )(" + _NUMBER + r")(s\b)"),
)

# minimap2 prefixes progress lines with [M::<function>::<elapsed>*<cpu ratio>].
# The elapsed seconds are binding. The CPU ratio is R6.
_MINIMAP2_STAMP = re.compile(r"(\[M::[A-Za-z0-9_]+::)(" + _NUMBER + r")\*(" + _NUMBER + r")(\])")


def _epoch_in_range(value: float) -> bool:
    unix_seconds = 1_500_000_000 <= value <= 2_100_000_000
    unix_millis = 1_500_000_000_000 <= value <= 2_100_000_000_000
    reference_seconds = 500_000_000 <= value <= 1_100_000_000
    return unix_seconds or unix_millis or reference_seconds


def root_spellings(run_root: str) -> list[str]:
    """Every spelling of the scratch root that tools write.

    Foundation's path standardizing drops a leading /private from /private/var
    and /private/tmp, so both forms appear. JSON writers escape the slashes.
    """
    root = run_root.rstrip("/")
    forms = {root}
    if root.startswith("/private/"):
        forms.add(root[len("/private"):])
    elif root.startswith(("/var/", "/tmp/")):
        forms.add("/private" + root)
    escaped = {form.replace("/", "\\/") for form in forms}
    return sorted(forms | escaped, key=len, reverse=True)


def replace_run_root(text: str, run_root: str) -> str:
    for spelling in root_spellings(run_root):
        text = text.replace(spelling, RUN_ROOT_TOKEN)
    return text


def mask_uuids(text: str) -> str:
    """Replace each distinct UUID with <UUID-n>, numbered by first appearance.

    Numbering keeps the links inside one file (a step that names another step's
    ID still names the same token) without depending on the random values.
    """
    seen: dict[str, int] = {}

    def token(match: re.Match[str]) -> str:
        value = match.group(0).lower()
        if value not in seen:
            seen[value] = len(seen) + 1
        return f"<UUID-{seen[value]}>"

    return _UUID.sub(token, text)


def mask_timestamps(text: str) -> str:
    return _ISO_TIMESTAMP.sub(TIMESTAMP_TOKEN, text)


def mask_epoch_values(text: str) -> str:
    def token(match: re.Match[str]) -> str:
        if _epoch_in_range(float(match.group(3))):
            return match.group(1) + '"' + EPOCH_TOKEN + '"'
        return match.group(0)

    return _EPOCH_VALUE.sub(token, text)


def mask_duration_values(text: str) -> str:
    return _DURATION_VALUE.sub(lambda m: m.group(1) + '"' + DURATION_TOKEN + '"', text)


def mask_tool_log_durations(text: str) -> str:
    for pattern in _TOOL_LOG_DURATIONS:
        text = pattern.sub(lambda m: m.group(1) + DURATION_TOKEN + m.group(3), text)
    return _MINIMAP2_STAMP.sub(lambda m: m.group(1) + DURATION_TOKEN + "*" + m.group(3) + m.group(4), text)


# ---------------------------------------------------------------------------
# Ruled rules (program manager, 2026-10-02)

# R5: the process ID in provenance runtimeIdentity.
_PROCESS_IDENTIFIER = re.compile(r'("processIdentifier"\s*:\s*)([0-9]+)(?![0-9])')

# R6: minimap2 CPU ratio, CPU seconds and peak memory.
_MINIMAP2_CPU_RATIO = re.compile(r"(\[M::[A-Za-z0-9_]+::" + re.escape(DURATION_TOKEN) + r"\*)(" + _NUMBER + r")(\])")
_MINIMAP2_RESOURCES = re.compile(r"(; CPU: )(" + _NUMBER + r")( sec; Peak RSS: )(" + _NUMBER + r")( GB)")

# R7: kraken2 throughput "(1104.0 Kseq/m, 166.19 Mbp/m)", slash escaped in JSON.
_KRAKEN2_RATES = re.compile(r"\((" + _NUMBER + r") Kseq(\\?/)m, (" + _NUMBER + r") Mbp(\\?/)m\)")

# Q3: the LGE version, under the keys that record the app or CLI version, in
# the two shapes LGE writes ("2026.9.78" and "Lungfish 2026.9.78 (dev)").
APP_VERSION_KEYS = ("appVersion", "toolVersion", "version", "workflowVersion")

# R13: ProvenanceStderr.truncated keeps the first 10,240 characters of a tool's
# stderr and appends this marker. The cut lands inside a line whose position
# depends on the length of every masked number before it.
STDERR_TRUNCATION_MARKER = "\n... [truncated]"


def mask_process_identifiers(text: str) -> str:
    return _PROCESS_IDENTIFIER.sub(lambda m: m.group(1) + '"' + PID_TOKEN + '"', text)


def mask_minimap2_resources(text: str) -> str:
    text = _MINIMAP2_CPU_RATIO.sub(lambda m: m.group(1) + "<CPU-RATIO>" + m.group(3), text)
    return _MINIMAP2_RESOURCES.sub(
        lambda m: m.group(1) + "<CPU-SECONDS>" + m.group(3) + "<PEAK-RSS>" + m.group(5), text
    )


def mask_kraken2_rates(text: str) -> str:
    return _KRAKEN2_RATES.sub(lambda m: f"(<RATE> Kseq{m.group(2)}m, <RATE> Mbp{m.group(4)}m)", text)


def mask_app_version(text: str, version: str | None) -> str:
    if not version:
        return text
    pattern = re.compile(
        r'("(?:' + "|".join(APP_VERSION_KEYS) + r')"\s*:\s*")((?:Lungfish )?)'
        + re.escape(version)
        + r'((?: \([^"\\]*\))?")'
    )
    return pattern.sub(lambda m: m.group(1) + m.group(2) + APP_VERSION_TOKEN + m.group(3), text)


# ---------------------------------------------------------------------------
# Host rule (owner ruling, 2026-10-08)

# H1: the macOS version and build, so the goldens pass on every release Mac
# whatever build it runs. Only the numbers are masked, under the keys that
# record them, in the three shapes LGE and Python write:
#   "hostOS" : "macOS 26.6.2 (arm64)" (also operatingSystemVersion)
#   "platform" : "Version 26.6.2 (Build 25G83)"
#   "platform": "macOS-26.6.2-arm64-arm-64bit"
# The architecture and every other part of the value stay compared.
HOST_OS_VERSION_TOKEN = "<HOST-OS-VERSION>"
HOST_OS_BUILD_TOKEN = "<HOST-OS-BUILD>"

_OS_VERSION = r"[0-9]+(?:\.[0-9]+)*"
_HOST_OS_DESCRIPTION = re.compile(
    r'("(?:hostOS|operatingSystemVersion)"\s*:\s*"macOS )(' + _OS_VERSION + r')( \([^"\\]*\)")'
)
_HOST_OS_VERSION_STRING = re.compile(
    r'("platform"\s*:\s*"Version )(' + _OS_VERSION + r')( \(Build )([0-9A-Za-z]+)(\)")'
)
_PYTHON_PLATFORM = re.compile(r'("platform"\s*:\s*"macOS-)(' + _OS_VERSION + r')(-[^"\\]*")')


def mask_host_os(text: str) -> str:
    text = _HOST_OS_DESCRIPTION.sub(lambda m: m.group(1) + HOST_OS_VERSION_TOKEN + m.group(3), text)
    text = _HOST_OS_VERSION_STRING.sub(
        lambda m: m.group(1) + HOST_OS_VERSION_TOKEN + m.group(3) + HOST_OS_BUILD_TOKEN + m.group(5), text
    )
    return _PYTHON_PLATFORM.sub(lambda m: m.group(1) + HOST_OS_VERSION_TOKEN + m.group(3), text)


# H2: the active core count that ArgumentParser prints as the default of an
# option whose help says "(default: active cores)". Every capture pins its
# thread counts in argv, so only this help text records the core count.
ACTIVE_CORES_TOKEN = "<ACTIVE-CORES>"
_ACTIVE_CORES_DEFAULT = re.compile(r"(\(default: active cores\)\s+\(default: )([0-9]+)(\))")


def mask_active_cores(text: str) -> str:
    return _ACTIVE_CORES_DEFAULT.sub(lambda m: m.group(1) + ACTIVE_CORES_TOKEN + m.group(3), text)


# ---------------------------------------------------------------------------
# JSON spans
#
# Record-scoped rules (R8, R10 sizes, R13, R16 and N1 to N3) need to know
# which object a value belongs to. Python's json module drops positions, so this small parser keeps
# the start and end offset of every value. Edits replace exact spans, which
# leaves every other byte as it was.


class NotJSON(ValueError):
    pass


@dataclass
class Node:
    kind: str  # object, array, string, number, literal
    start: int
    end: int
    members: list[tuple[str, "Node"]] = field(default_factory=list)
    key_spans: list[tuple[int, int]] = field(default_factory=list)
    items: list["Node"] = field(default_factory=list)
    value: object = None

    def get(self, key: str) -> "Node | None":
        for member_key, node in self.members:
            if member_key == key:
                return node
        return None

    def walk(self, key: str | None = None) -> Iterable[tuple[str | None, "Node"]]:
        """Every node in document order, with the key it sits under."""
        yield key, self
        for member_key, node in self.members:
            yield from node.walk(member_key)
        for node in self.items:
            yield from node.walk(None)


_WHITESPACE = re.compile(r"[ \t\n\r]*")
_JSON_STRING = re.compile(r'"(?:[^"\\\x00-\x1f]|\\.)*"', re.DOTALL)
_JSON_NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?")
_JSON_LITERAL = re.compile(r"true|false|null")


def _skip(text: str, position: int) -> int:
    return _WHITESPACE.match(text, position).end()


def _parse_value(text: str, position: int) -> Node:
    if position >= len(text):
        raise NotJSON("unexpected end")
    char = text[position]
    if char == "{":
        node = Node("object", position, position)
        position = _skip(text, position + 1)
        if text.startswith("}", position):
            node.end = position + 1
            return node
        while True:
            key_match = _JSON_STRING.match(text, position)
            if not key_match:
                raise NotJSON(f"expected a key at {position}")
            key = json.loads(key_match.group(0))
            position = _skip(text, key_match.end())
            if not text.startswith(":", position):
                raise NotJSON(f"expected ':' at {position}")
            value = _parse_value(text, _skip(text, position + 1))
            node.members.append((key, value))
            node.key_spans.append(key_match.span())
            position = _skip(text, value.end)
            if text.startswith(",", position):
                position = _skip(text, position + 1)
                continue
            if text.startswith("}", position):
                node.end = position + 1
                return node
            raise NotJSON(f"expected ',' or '}}' at {position}")
    if char == "[":
        node = Node("array", position, position)
        position = _skip(text, position + 1)
        if text.startswith("]", position):
            node.end = position + 1
            return node
        while True:
            value = _parse_value(text, position)
            node.items.append(value)
            position = _skip(text, value.end)
            if text.startswith(",", position):
                position = _skip(text, position + 1)
                continue
            if text.startswith("]", position):
                node.end = position + 1
                return node
            raise NotJSON(f"expected ',' or ']' at {position}")
    if char == '"':
        match = _JSON_STRING.match(text, position)
        if not match:
            raise NotJSON(f"unterminated string at {position}")
        return Node("string", position, match.end(), value=json.loads(match.group(0)))
    match = _JSON_NUMBER.match(text, position) or _JSON_LITERAL.match(text, position)
    if not match:
        raise NotJSON(f"unexpected character at {position}")
    kind = "number" if match.re is _JSON_NUMBER else "literal"
    return Node(kind, position, match.end(), value=json.loads(match.group(0)))


def parse_json(text: str) -> Node | None:
    """The span tree of a JSON document, or None when the text is not JSON."""
    try:
        position = _skip(text, 0)
        if position >= len(text) or text[position] not in "{[":
            return None
        node = _parse_value(text, position)
    except (NotJSON, ValueError, RecursionError):
        return None
    if _skip(text, node.end) != len(text):
        return None
    return node


def apply_edits(text: str, edits: dict[tuple[int, int], str]) -> str:
    """Replace each (start, end) span. Spans never overlap."""
    for (start, end), replacement in sorted(edits.items(), reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def escape_like(value: str, original_literal: str) -> str | None:
    """value as a JSON string literal escaped the way original_literal was.

    Foundation escapes '/' as '\\/'. The result is only trusted when the same
    escaping reproduces original_literal from its own decoded value, so any
    other difference in escaping leaves the literal untouched.
    """

    def encode(text: str) -> str:
        literal = json.dumps(text, ensure_ascii=False)
        return literal.replace("/", "\\/") if "\\/" in original_literal else literal

    if encode(json.loads(original_literal)) != original_literal:
        return None
    return encode(value)


# ---------------------------------------------------------------------------
# Record-scoped rules


def file_records(root: Node) -> Iterable[Node]:
    """Objects that describe a file: they carry a path and a SHA-256."""
    for _, node in root.walk():
        if node.kind != "object":
            continue
        path = node.get("path")
        if path is not None and path.kind == "string" and any(node.get(key) for key in HASH_KEYS):
            yield node


@dataclass(frozen=True)
class PathRule:
    """Mask the hash (and optionally size) of file records whose path ends in
    one of the suffixes. Used for files whose bytes change from run to run and
    that are deleted before the capture reads them."""

    rule: str
    suffixes: tuple[str, ...]
    mask_size: bool = True
    strict_skip: bool = False


# R8: minimap2 records the per-run reference staging folder in the @PG CL line,
# so the SAM, the filtered and sorted BAMs and the index change from run to run.
ALIGNMENT_RECORDS = PathRule("R8", (".sam", ".bam", ".bai"))


def mask_records_by_path(root: Node, rules: Iterable[PathRule]) -> dict[tuple[int, int], str]:
    edits = {}
    for record in file_records(root):
        path = str(record.get("path").value)
        rule = next((rule for rule in rules if path.endswith(rule.suffixes)), None)
        if rule is None:
            continue
        for key in HASH_KEYS:
            node = record.get(key)
            if node is not None:
                edits[(node.start, node.end)] = f'"<SHA256-{rule.rule}>"'
        if rule.mask_size:
            for key in SIZE_KEYS:
                node = record.get(key)
                if node is not None:
                    edits[(node.start, node.end)] = f'"<SIZE-{rule.rule}>"'
    return edits


def drop_truncated_partial_lines(text: str, root: Node) -> dict[tuple[int, int], str]:
    """R13: drop the partial last line of a stderr value the app truncated."""
    edits = {}
    for key, node in root.walk():
        if key != "stderr" or node.kind != "string" or not str(node.value).endswith(STDERR_TRUNCATION_MARKER):
            continue
        kept = str(node.value)[: -len(STDERR_TRUNCATION_MARKER)]
        newline = kept.rfind("\n")
        kept = kept[:newline] if newline >= 0 else ""
        literal = escape_like(kept + "\n" + TRUNCATED_LINE_TOKEN + STDERR_TRUNCATION_MARKER, text[node.start:node.end])
        if literal is not None:
            edits[(node.start, node.end)] = literal
    return edits


# ---------------------------------------------------------------------------
# Identity masks
#
# Some files and captured payloads hold a masked field, so their SHA-256 and
# size change from run to run although their normalized content is compared
# elsewhere in the goldens. Such a digest is registered with the rule that
# allows it, and every occurrence of that exact digest is replaced. A record
# that names the file with any other digest keeps its value and shows up in
# the diff.


@dataclass(frozen=True)
class VolatileDigest:
    """A digest masked wherever it appears.

    The token names only the rule. Two files or payloads that hold the same
    second-resolution timestamp can share a digest in one run and not in the
    next, so a token that named the file would depend on that coincidence. The
    record's path or the JSON key next to the token says what it stands for.
    """

    digest: str
    rule: str
    label: str
    mask_size: bool = False
    strict_skip: bool = False

    @property
    def token(self) -> str:
        return f"<SHA256-{self.rule}>"


SHA256_HEX = re.compile(r"(?<![0-9A-Fa-f])[0-9a-f]{64}(?![0-9A-Fa-f])")


def mask_digests(text: str, digests: dict[str, VolatileDigest]) -> str:
    if not digests:
        return text
    return SHA256_HEX.sub(lambda m: digests[m.group(0)].token if m.group(0) in digests else m.group(0), text)


def mask_digest_record_sizes(root: Node, digests: dict[str, VolatileDigest]) -> dict[tuple[int, int], str]:
    """Size fields of the file records whose registered digest masks its size.

    This runs before mask_digests replaces the digests, because the token names
    only the rule and one rule can mask the size of one file and keep the size
    of another (N2 masks a BAM's size but keeps its index's).
    """
    edits = {}
    for record in file_records(root):
        entry = next((digests[node.value] for key in HASH_KEYS
                      if (node := record.get(key)) is not None and node.value in digests), None)
        if entry is None or not entry.mask_size:
            continue
        for key in SIZE_KEYS:
            node = record.get(key)
            if node is not None:
                edits[(node.start, node.end)] = f'"<SIZE-{entry.rule}>"'
    return edits


# ---------------------------------------------------------------------------
# Rules from the second ruling round (program manager, 2026-10-02). They cover
# nondeterminism in the app and random identifiers in tool output, so
# `golden.py compare --strict` leaves them out to show what they hide. N3 needs
# no rule of its own. The run copies the deleted sample manifest while it
# exists, the binding run ID rule masks its bbmerge-<UUID> staging folder, and
# R10 covers its recorded hash.

STRICT_SKIP_RULES = {
    "N1": "stringified JSON under stats.rawMetrics in a captured result.json is written with "
          "per-process key order, so its object members are put in sorted key order",
    "N2": "samtools merge gives colliding @PG IDs a random suffix, so the hash and size of the "
          "merged BAM and the genotyping-evidence BAM are masked where their records hashes are "
          "goldens, with the hash of their indexes and their base64 copies in request.json",
}


def sort_object_members(text: str) -> str | None:
    """The JSON text with the members of every object in sorted key order.

    Each member keeps its raw bytes, only the order changes. Array order is
    kept. Returns None when the text is not compact JSON.
    """
    root = parse_json(text)
    if root is None:
        return None

    def render(node: Node) -> str:
        if node.kind == "object":
            members = sorted(zip(node.members, node.key_spans), key=lambda pair: pair[0][0])
            parts = [f"{text[start:end]}:{render(value)}" for (_, value), (start, end) in members]
            return "{" + ",".join(parts) + "}"
        if node.kind == "array":
            return "[" + ",".join(render(item) for item in node.items) + "]"
        return text[node.start:node.end]

    rendered = render(root)
    return rendered if len(rendered) == len(text) else None


def sort_raw_metric_objects(text: str) -> str:
    """N1: canonical member order of the stringified JSON in stats.rawMetrics.

    ONTGenotypeRunStats.load turns each nested dictionary or array of the run
    stats into a string with JSONSerialization and no sorted keys, so the order
    of object members follows the per-process hash seed. Only those strings are
    rewritten, with their members in sorted key order. Every other byte stays.
    """
    root = parse_json(text)
    if root is None:
        return text
    stats = root.get("stats")
    metrics = stats.get("rawMetrics") if stats is not None else None
    if metrics is None or metrics.kind != "object":
        return text
    edits = {}
    for _, node in metrics.members:
        if node.kind != "string" or not str(node.value).startswith(("{", "[")):
            continue
        canonical = sort_object_members(str(node.value))
        if canonical is None or canonical == node.value:
            continue
        literal = escape_like(canonical, text[node.start:node.end])
        if literal is not None:
            edits[(node.start, node.end)] = literal
    return apply_edits(text, edits)


# ---------------------------------------------------------------------------
# Entry points


@dataclass
class Normalizer:
    """The rule set for one capture."""

    run_root: str
    app_version: str | None = None
    strict: bool = False
    path_rules: list[PathRule] = field(default_factory=list)
    digests: dict[str, VolatileDigest] = field(default_factory=dict)
    # Every file or payload found volatile, even when its digest equals one
    # already registered, so the list does not depend on such coincidences.
    items: set[VolatileDigest] = field(default_factory=set)
    # Timestamps and UUIDs found in the capture's own inputs. They are masked
    # like any other, but a file whose only masked fields are these values (or
    # the app version) has the same bytes in every run, so its digest stays.
    stable_values: set[str] = field(default_factory=set)

    def add_stable_values(self, text: str) -> None:
        self.stable_values.update(_ISO_TIMESTAMP.findall(text))
        self.stable_values.update(match.lower() for match in _UUID.findall(text))
        self.stable_values.update(match.upper() for match in _UUID.findall(text))

    def holds_run_dependent_field(self, text: str) -> bool:
        """True when the text holds a masked field whose value can change from
        run to run, so the SHA-256 of the file or payload changes too."""
        protected = text
        for index, value in enumerate(sorted(self.stable_values, key=len, reverse=True)):
            protected = protected.replace(value, f"STABLE-VALUE-{index}-")
        probe = Normalizer(run_root=self.run_root, app_version=None, strict=self.strict,
                           path_rules=self.path_rules, digests=self.digests)
        return probe.text(protected) != replace_run_root(protected, self.run_root)

    def register(self, entry: VolatileDigest) -> bool:
        """Mask entry.digest. Returns True when the digest was not masked yet."""
        if entry.strict_skip and self.strict:
            return False
        self.items.add(entry)
        existing = self.digests.get(entry.digest)
        if existing is not None:
            if (existing.rule, existing.mask_size) != (entry.rule, entry.mask_size):
                raise ValueError(f"digest {entry.digest} registered for {existing.rule} ({existing.label}) "
                                 f"and {entry.rule} ({entry.label})")
            return False
        self.digests[entry.digest] = entry
        return True

    def add_path_rule(self, rule: PathRule) -> None:
        if rule.strict_skip and self.strict:
            return
        self.path_rules.append(rule)

    def text(self, text: str) -> str:
        # Binding rules.
        text = replace_run_root(text, self.run_root)
        text = mask_uuids(text)
        text = mask_timestamps(text)
        text = mask_epoch_values(text)
        text = mask_duration_values(text)
        text = mask_tool_log_durations(text)
        # Ruled rules.
        text = mask_process_identifiers(text)
        text = mask_minimap2_resources(text)
        text = mask_kraken2_rates(text)
        text = mask_app_version(text, self.app_version)
        # Host rules.
        text = mask_host_os(text)
        text = mask_active_cores(text)
        root = parse_json(text)
        if root is not None:
            edits = drop_truncated_partial_lines(text, root)
            edits.update(mask_records_by_path(root, self.path_rules))
            edits.update(mask_digest_record_sizes(root, self.digests))
            text = apply_edits(text, edits)
        return mask_digests(text, self.digests)

    # Captured scientific inputs (R16) ---------------------------------------

    def payloads_hold_run_dependent_field(self, text: str, container_key: str) -> bool:
        """True when a base64 input of a snapshot (capturedScientificInputs) or
        request (inputs[].data) holds a run-dependent masked field."""
        root = parse_json(text)
        container = root.get(container_key) if root is not None else None
        if container is None:
            return False
        nodes = [node for _, node in container.members] if container.kind == "object" else [
            item.get("data") for item in container.items if item.kind == "object" and item.get("data") is not None]
        for node in nodes:
            raw = base64.b64decode(str(node.value), validate=True)
            try:
                payload_text = raw.decode("utf-8")
            except UnicodeDecodeError:
                if sha256_hex(raw) in self.digests:
                    return True
                continue
            if self.holds_run_dependent_field(payload_text):
                return True
        return False

    def payload(self, name: str, raw: bytes) -> bytes:
        """A captured input of a genotype export, normalized like any file."""
        text = raw.decode("utf-8")
        if name == "result.json" and not self.strict:
            text = sort_raw_metric_objects(text)
        return self.text(text).encode("utf-8")

    def snapshot(self, text: str) -> tuple[str, dict[str, bytes]]:
        """R16: decode, normalize and re-encode the captured inputs of a snapshot.

        Returns the normalized snapshot text and the normalized payloads.
        Payload digests must be registered first (register_payloads).
        """
        normalized = self.text(text)
        root = parse_json(normalized)
        inputs = root.get("capturedScientificInputs") if root is not None else None
        if inputs is None:
            return normalized, {}
        edits, payloads = {}, {}
        for name, node in inputs.members:
            raw = base64.b64decode(str(node.value), validate=True)
            if base64.b64encode(raw).decode("ascii") != node.value:
                raise ValueError(f"snapshot input {name} is not canonical base64")
            payloads[name] = self.payload(name, raw)
            literal = escape_like(base64.b64encode(payloads[name]).decode("ascii"), normalized[node.start:node.end])
            if literal is None:
                raise ValueError(f"snapshot input {name} uses an unexpected JSON escaping")
            edits[(node.start, node.end)] = literal
        return apply_edits(normalized, edits), payloads

    def register_payloads(self, text: str, golden_path: str) -> list[VolatileDigest]:
        """R16: register the digest of every captured input of a snapshot whose
        normalization changes it. The witness and revision hashes in receipts,
        snapshots and workbooks are these digests.

        A payload can hold the digest of another payload, so the caller repeats
        this until nothing new is registered. Request files are skipped, because
        their inputs are bundle files whose digests R10 or N2 cover.
        """
        root = parse_json(text)
        inputs = root.get("capturedScientificInputs") if root is not None else None
        if inputs is None:
            return []
        folder = golden_path.rsplit("/", 2)[-2] if "/" in golden_path else golden_path
        registered: list[VolatileDigest] = []
        for name, node in inputs.members:
            raw = base64.b64decode(str(node.value), validate=True)
            digest = sha256_hex(raw)
            payload_text = raw.decode("utf-8")
            if self.holds_run_dependent_field(payload_text):
                # The payload holds a masked field whose value changes per run.
                entry = VolatileDigest(digest, "R16", f"{folder}:{name}")
            elif not self.strict and sort_raw_metric_objects(payload_text) != payload_text:
                # Only the N1 member reordering changes it.
                entry = VolatileDigest(digest, "N1", f"{folder}:{name}", strict_skip=True)
            else:
                continue
            if self.register(entry):
                registered.append(entry)
        return registered

    def request(self, text: str) -> str:
        """request.json of an export capture folder: each input's base64 data is
        decoded, normalized and re-encoded like a snapshot's captured inputs
        (R16). A binary input whose digest is registered (the BAM and its index,
        N2) is replaced by a token, because its content is compared through the
        alignment goldens."""
        normalized = self.text(text)
        root = parse_json(normalized)
        inputs = root.get("inputs") if root is not None else None
        if inputs is None or inputs.kind != "array":
            return normalized
        edits = {}
        for item in inputs.items:
            data = item.get("data") if item.kind == "object" else None
            if data is None or data.kind != "string":
                continue
            raw = base64.b64decode(str(data.value), validate=True)
            if base64.b64encode(raw).decode("ascii") != data.value:
                raise ValueError("request input is not canonical base64")
            try:
                payload_text = raw.decode("utf-8")
            except UnicodeDecodeError:
                entry = self.digests.get(sha256_hex(raw))
                if entry is not None:
                    edits[(data.start, data.end)] = f'"<BASE64-{entry.rule}>"'
                continue
            encoded = base64.b64encode(self.text(payload_text).encode("utf-8")).decode("ascii")
            literal = escape_like(encoded, normalized[data.start:data.end])
            if literal is None:
                raise ValueError("request input uses an unexpected JSON escaping")
            edits[(data.start, data.end)] = literal
        return apply_edits(normalized, edits)

    # Workbooks ---------------------------------------------------------------

    def xlsx_parts(self, data: bytes, *, relocate_only: bool = False) -> dict[str, bytes]:
        """The XML parts of an .xlsx in canonical (sorted) order.

        Zip entry order and entry timestamps are container details, so they are
        not compared. Part content is normalized only where a rule allows it:
        the times in docProps/core.xml (brief), date-times in worksheet cells
        (R14), registered digests (R15, R16) and the scratch root token, which
        relocates a path rather than masking a value. relocate_only applies the
        token alone, to tell whether a workbook holds a masked field.
        """
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = sorted(info.filename for info in archive.infolist() if not info.is_dir())
            parts = {name: archive.read(name) for name in names}
        canonical: dict[str, bytes] = {}
        for name in names:
            content = parts[name]
            if name == "docProps/core.xml" and not relocate_only:
                content = mask_core_xml_times(content)
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError:
                canonical[name] = content
                continue
            text = replace_run_root(text, self.run_root)
            if not relocate_only:
                if name.startswith("xl/worksheets/") or name == "xl/sharedStrings.xml":
                    text = _ISO_DATETIME.sub(TIMESTAMP_TOKEN, text)
                text = mask_digests(text, self.digests)
            canonical[name] = text.encode("utf-8")
        return canonical


_CORE_XML_TIME = re.compile(
    rb"(<(dcterms:created|dcterms:modified|cp:lastPrinted)\b[^>]*>)([^<]*)(</\2>)"
)


def mask_core_xml_times(data: bytes) -> bytes:
    return _CORE_XML_TIME.sub(lambda m: m.group(1) + TIMESTAMP_TOKEN.encode() + m.group(4), data)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
