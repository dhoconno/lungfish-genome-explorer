"""Small synthetic software checks; no biological input or primer design."""
import datetime
import hashlib
import json
import os
import pathlib
import platform
import shlex
import subprocess
import sys
import time
from types import SimpleNamespace

started = time.monotonic()
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
os.environ['MPLCONFIGDIR'] = '/private/tmp/primalscheme-selection-audit/matplotlib'
import numpy as np
from primalscheme3.core.config import Config
from primalscheme3.core.mismatches import detect_new_products
from primalscheme3.core.multiplex import Multiplex

here = pathlib.Path(__file__).resolve().parent
engine = pathlib.Path('/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3')
config = Config()
assert config.use_matchdb and config.mismatch_product_size == 0
new, old = {(0, 100, '+')}, {(0, 200, '-')}
assert detect_new_products(new, old, 0) is False
assert detect_new_products(new, old, 2000) is True

# Same reference positions covered in different pools; no sequence chemistry.
state = Multiplex.__new__(Multiplex)
state._lookup = {0: None}
state._coverage = {0: np.zeros(100, dtype=bool)}
def candidate(start, end):
    return SimpleNamespace(msa_index=0, fprimer=SimpleNamespace(end=start), rprimer=SimpleNamespace(start=end))
a, b = candidate(10, 50), candidate(30, 70)
state.update_coverage(a, True)
state.update_coverage(b, True)
state.update_coverage(a, False)
observed = int(state._coverage[0].sum())
assert observed == 20  # Remaining b actually covers 40 positions.

# Native constructor signatures are recorded by the standalone reviewer probe.
probe_path = here / 'evidence/nativehash-probe.py'
hashes = [subprocess.check_output([sys.executable, str(probe_path)], text=True).strip() for _ in range(5)]
assert len(set(hashes)) > 1
result = {'matchdbEnabled': config.use_matchdb, 'defaultProductLimit': config.mismatch_product_size,
          'distance100RejectedAtLimit0': False, 'distance100RejectedAtLimit2000': True,
          'coverageAfterRemovingOverlappingOtherPoolCandidate': {'actual': observed, 'expected': 40},
          'identicalNativePrimerObjectHashesAcrossFiveProcesses': hashes}
output = here / 'checks.json'
output.write_text(json.dumps(result, indent=2) + '\n')
def desc(path):
    data = path.read_bytes()
    return {'path': str(path), 'sizeBytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
provenance = {'workflowName': 'lge.primalscheme.algorithm-audit.synthetic-checks', 'workflowVersion': '1',
              'argv': [sys.executable, str(pathlib.Path(__file__).resolve())],
              'reproducibleCommand': shlex.join([sys.executable, str(pathlib.Path(__file__).resolve())]),
              'runtime': {'python': sys.version, 'platform': platform.platform(), 'executable': sys.executable},
              'inputs': [desc(pathlib.Path(__file__).resolve()), desc(probe_path)] + [desc(engine / p) for p in
                         ['lge-build.json', 'core/config.py', 'core/mismatches.py', 'core/multiplex.py']],
              'options': result, 'environment': {'MPLCONFIGDIR': os.environ['MPLCONFIGDIR']},
              'outputs': [desc(output)], 'stderr': '', 'exitStatus': 0,
              'startedAt': stamp, 'endedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'wallTimeSeconds': time.monotonic() - started}
(here / 'checks.provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
print(json.dumps(result))
