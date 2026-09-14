#!/Users/dho/.lungfish/conda/envs/primalscheme3/bin/python
"""Interval-only counterexample for PrimalScheme3 Panel's greedy selector.

Uses the installed Panel.add_next_primerpair method and Multiplex bookkeeping.
Only chemistry is stubbed: one named candidate-pair conflict replaces sequence-based
dimer detection, allowing the selection heuristic to be isolated without DNA data.
"""

from __future__ import annotations

import hashlib
import json
import platform
import time
from importlib.metadata import version
from pathlib import Path

STARTED = time.perf_counter()

import numpy as np

from primalscheme3.core.config import Config
from primalscheme3.core.mismatches import MatchDB
from primalscheme3.core.multiplex import PrimerPairCheck
from primalscheme3.panel.panel_classes import Panel, PanelReturn


RUNTIME = Path("/Users/dho/.lungfish/conda/envs/primalscheme3")
PACKAGE = RUNTIME / "lib/python3.12/site-packages/primalscheme3"
COMMAND = (
    "/usr/bin/env MPLCONFIGDIR=/private/tmp/primalscheme-selection-audit/matplotlib "
    "/Users/dho/.lungfish/conda/envs/primalscheme3/bin/python "
    "/private/tmp/primalscheme-selection-audit/counterexample.py"
)
AUDITED_FILES = [
    "panel/panel_main.py",
    "panel/panel_classes.py",
    "core/multiplex.py",
    "core/msa.py",
    "core/digestion.py",
    "core/classes.py",
    "core/config.py",
    "core/mismatches.py",
    "lge-build.json",
]


class EndPoint:
    def __init__(self, position: int):
        self.end = position
        self.start = position

    def region(self) -> tuple[int, int]:
        return (self.start, self.end)


class IntervalCandidate:
    def __init__(self, name: str, msa_index: int, start: int, stop: int):
        self.name = name
        self.msa_index = msa_index
        self.fprimer = EndPoint(start)
        self.rprimer = EndPoint(stop)
        self.pool = -1
        self.amplicon_number = -1

    def all_seqs(self) -> list[str]:
        return []

    def all_seq_bytes(self) -> list[bytes]:
        return []

    def get_score(self) -> float:
        return 0.0

    def find_matches(self, *args, **kwargs) -> set[tuple]:
        return set()


class IntervalMSA:
    def __init__(self, logical_name: str, msa_index: int):
        self.logical_name = logical_name
        self.msa_index = msa_index
        self._mapping_array = np.arange(100)
        self.array = np.zeros((1, 100), dtype=np.uint8)
        self._score_array = np.ones(100, dtype=int)
        self.regions = None
        self.primerpairs: list[IntervalCandidate] = []

    def get_pp_score(self, candidate: IntervalCandidate) -> int:
        return int(self._score_array[candidate.fprimer.end : candidate.rprimer.start].sum())

    def update_score_array(self, candidate: IntervalCandidate, newscore: int = 0) -> None:
        self._score_array[candidate.fprimer.end : candidate.rprimer.start] = newscore


class ChemistryStubPanel(Panel):
    """Real greedy selector with an interval conflict oracle in place of chemistry."""

    def __init__(self, msa_dict, config, matchdb, conflicts):
        self.conflicts = {frozenset(pair) for pair in conflicts}
        super().__init__(msa_dict, config, matchdb)

    def check_primerpair_can_be_added(self, candidate, pool, otherseqs_bytes=None):
        if self.does_overlap(candidate, pool):
            return PrimerPairCheck.OVERLAP
        for existing in self._pools[pool]:
            if frozenset((candidate.name, existing.name)) in self.conflicts:
                return PrimerPairCheck.INTERACTING
        return PrimerPairCheck.OK


def run(input_order: tuple[str, str]) -> dict:
    config = Config(n_pools=1, use_matchdb=False)
    msas = {i: IntervalMSA(name, i) for i, name in enumerate(input_order)}
    by_name = {msa.logical_name: msa for msa in msas.values()}

    a = by_name["A"]
    b = by_name["B"]
    # A_greedy has the highest local score but conflicts with B's only candidate.
    # A_compatible is slightly shorter and can coexist with B_only.
    a.primerpairs = [
        IntervalCandidate("A_greedy", a.msa_index, 0, 100),
        IntervalCandidate("A_compatible", a.msa_index, 0, 90),
    ]
    b.primerpairs = [IntervalCandidate("B_only", b.msa_index, 0, 100)]

    panel = ChemistryStubPanel(
        msas,
        config,
        MatchDB(Path("/private/tmp/primalscheme-selection-audit/unused"), [], config),
        conflicts=[("A_greedy", "B_only")],
    )
    while not all(panel._is_msa_index_finished.values()):
        result = panel.add_next_primerpair()
        assert result in (PanelReturn.ADDED_PRIMERPAIR, PanelReturn.NO_PRIMERPAIRS_IN_MSA)

    coverage = {
        msa.logical_name: int(panel._coverage[msa.msa_index].sum())
        for msa in msas.values()
    }
    return {
        "input_order": list(input_order),
        "selected": [candidate.name for candidate in panel._last_pp_added],
        "coverage": coverage,
        "total_covered_positions": sum(coverage.values()),
    }


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


results = [run(("A", "B")), run(("B", "A"))]
elapsed = time.perf_counter() - STARTED
assert results[0]["total_covered_positions"] == 100
assert results[1]["total_covered_positions"] == 190

build = json.loads((PACKAGE / "lge-build.json").read_text())
report = {
    "provenance": {
        "exact_command": COMMAND,
        "working_directory": "/Users/dho/Documents/lungfish-genome-explorer",
        "python": platform.python_version(),
        "python_executable": str(RUNTIME / "bin/python"),
        "primalscheme3_version": version("primalscheme3"),
        "primalscheme3_source_commit": build["sourceCommit"],
        "primalscheme3_source_hashes_sha256": {
            rel: sha256(PACKAGE / rel) for rel in AUDITED_FILES
        },
        "script_sha256": sha256(Path(__file__)),
        "wall_time_seconds": round(elapsed, 6),
        "exit_status": 0,
    },
    "synthetic_model": {
        "pools": 1,
        "target_positions_per_msa": 100,
        "candidate_intervals": {
            "A_greedy": [0, 100],
            "A_compatible": [0, 90],
            "B_only": [0, 100],
        },
        "stubbed_chemistry_conflicts": [["A_greedy", "B_only"]],
        "dna_sequences_used": False,
    },
    "results": results,
}
print(json.dumps(report, indent=2, sort_keys=True))
