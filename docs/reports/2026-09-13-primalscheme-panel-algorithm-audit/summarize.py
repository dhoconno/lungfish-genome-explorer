"""Read existing LGE bundles and retain verified audit metrics with provenance."""
import collections
import datetime
import hashlib
import json
import pathlib
import platform
import re
import shlex
import sys
import time

START = time.monotonic()
STAMP = datetime.datetime.now(datetime.timezone.utc).isoformat()
HERE = pathlib.Path(__file__).resolve().parent
BASE = pathlib.Path('/Users/dho/Desktop/sandbox/HLA-coverage-benchmark-2026-09-13')
AUDIT = pathlib.Path('/Users/dho/Documents/lungfish-genome-explorer/outputs/primalscheme-panel-audit-2026-09-13')
ENGINE = pathlib.Path('/Users/dho/.lungfish/conda/envs/primalscheme3/lib/python3.12/site-packages/primalscheme3')
RUNS = {
    'wide-original': BASE / 'primalscheme-200bp-150-280bp/HLA-combined-200bp.lungfishprimeranalysis',
    'wide-three-pools': BASE / 'primalscheme-coverage-optimization/three-pools/HLA-combined-200bp.lungfishprimeranalysis',
    'wide-high-gc': BASE / 'primalscheme-coverage-optimization/high-gc-two-pools/HLA-combined-200bp.lungfishprimeranalysis',
    'wide-reversed': AUDIT / 'wide-reversed-managed/HLA.lungfishprimeranalysis',
    'narrow-explicit': AUDIT / 'narrow-explicit-managed/HLA.lungfishprimeranalysis',
}


def descriptor(path):
    with path.open('rb') as handle:
        digest = hashlib.file_digest(handle, 'sha256').hexdigest()
    return {'path': str(path), 'sha256': digest, 'sizeBytes': path.stat().st_size}


def union(intervals):
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(end, merged[-1][1])
        else:
            merged.append([start, end])
    return sum(end - start for start, end in merged), merged


def bed(path):
    result = collections.defaultdict(list)
    for line in path.read_text().splitlines():
        if line and not line.startswith('#'):
            fields = line.split('\t')
            result[fields[0]].append((int(fields[1]), int(fields[2])))
    return result


inputs = [descriptor(pathlib.Path(__file__).resolve())]
source_files = [descriptor(p) for p in sorted(ENGINE.rglob('*.py'))]
inputs.extend(source_files)
inputs.append(descriptor(ENGINE / 'lge-build.json'))
results = {}
for name, bundle in RUNS.items():
    if not bundle.exists():
        results[name] = {'status': 'bundle-not-present'}
        continue
    manifest_path = bundle / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    inputs.append(descriptor(manifest_path))
    assert manifest['grouping'] == 'combined' and len(manifest['results']) == 1
    for item in manifest['artifacts'] + [manifest['provenance']]:
        observed = descriptor(bundle / item['relativePath'])
        assert observed['sha256'] == item['sha256'], observed['path']
        assert observed['sizeBytes'] == item['byteSize'], observed['path']
    native = next(bundle.glob('native/*'))
    config = json.loads((native / 'config.json').read_text())
    execution_path = next(bundle.glob('logs/*/execution.json'))
    execution = json.loads(execution_path.read_text())
    assert execution['exitStatus'] == 0
    for item in execution['files']:
        observed = descriptor(pathlib.Path(item['path']))
        assert observed['sha256'] == item['checksumSHA256']
        assert observed['sizeBytes'] == item['fileSize']
    full, trimmed = bed(native / 'amplicon.bed'), bed(native / 'primertrim.amplicon.bed')
    refs = {}
    for line in (native / 'reference.fasta').read_text().splitlines():
        if line.startswith('>'):
            ref = line[1:].split()[0]
            refs[ref] = ''
        else:
            refs[ref] += line
    normalized_log = re.sub(r'\s+', ' ', (native / 'work/file.log').read_text())
    candidate_counts = dict(re.findall(r'(input_\w+): Generated (\d+) possible amplicons', normalized_log))
    rows = []
    for item in manifest['inputs']:
        ref = 'input_' + item['id'].replace('-', '') + '_row_0'
        snapshot = bundle / 'source-inputs' / item['id'] / 'source.lungfishmsa'
        aligned = snapshot / 'alignment/primary.aligned.fasta'
        source_manifest = json.loads((snapshot / 'manifest.json').read_text())
        length = len(refs[ref])
        assert length == source_manifest['alignedLength']
        lengths = [end - start for start, end in full[ref]]
        assert all(config['amplicon_size_min'] <= n <= config['amplicon_size_max'] for n in lengths)
        assert all(0 <= start < end <= length for start, end in full[ref])
        covered, intervals = union(full[ref])
        trimmed_covered, trimmed_intervals = union(trimmed[ref])
        rows.append({'msa': item['label'], 'inputAlignmentSHA256': descriptor(aligned)['sha256'],
                     'referenceLength': length, 'amplicons': len(lengths), 'candidateCount': int(candidate_counts[ref]),
                     'coveredBases': covered, 'coveragePercent': 100 * covered / length,
                     'primerTrimmedCoveredBases': trimmed_covered, 'primerTrimmedCoveragePercent': 100 * trimmed_covered / length,
                     'fullIntervals0BasedHalfOpen': intervals, 'trimmedIntervals0BasedHalfOpen': trimmed_intervals})
    for path in [native / 'config.json', native / 'amplicon.bed', native / 'primertrim.amplicon.bed',
                 native / 'reference.fasta', native / 'work/file.log', execution_path, bundle.parent / 'run.json']:
        inputs.append(descriptor(path))
    results[name] = {'status': 'verified', 'bundle': str(bundle), 'rows': sorted(rows, key=lambda x: x['msa']),
                     'candidateCount': sum(r['candidateCount'] for r in rows), 'amplicons': sum(r['amplicons'] for r in rows),
                     'poolCount': config['n_pools'], 'highGC': config['high_gc'], 'bounds': [config['amplicon_size_min'], config['amplicon_size_max']],
                     'sizingMetric': config['amplicon_size_metric'], 'useMatchDB': config['use_matchdb'],
                     'mismatchProductSize': config['mismatch_product_size'], 'verifiedArtifacts': len(manifest['artifacts']) + 1,
                     'nativeWallTimeSeconds': execution['wallTimeSeconds']}
output = HERE / 'metrics.json'
output.write_text(json.dumps({'engineBuild': json.loads((ENGINE / 'lge-build.json').read_text()), 'runs': results}, indent=2) + '\n')
provenance = {'workflowName': 'lge.primalscheme.panel-algorithm-audit.summary', 'workflowVersion': '1',
              'argv': [sys.executable, str(pathlib.Path(__file__).resolve())],
              'reproducibleCommand': shlex.join([sys.executable, str(pathlib.Path(__file__).resolve())]),
              'options': {'coverage': 'union of BED intervals divided by first-row reference length',
                          'reportBothFullAndPrimerTrimmed': True, 'verifyManifestAndExecutionDescriptors': True},
              'runtime': {'executable': sys.executable, 'python': sys.version, 'platform': platform.platform()},
              'inputs': inputs, 'outputs': [descriptor(output)], 'exitStatus': 0, 'stderr': '',
              'startedAt': STAMP, 'endedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'wallTimeSeconds': time.monotonic() - START}
(HERE / 'metrics.provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
for name, result in results.items():
    print(name, result['status'], result.get('candidateCount'), result.get('amplicons'))
    for row in result.get('rows', []):
        print(' ', row['msa'], round(row['coveragePercent'], 2), round(row['primerTrimmedCoveragePercent'], 2))
