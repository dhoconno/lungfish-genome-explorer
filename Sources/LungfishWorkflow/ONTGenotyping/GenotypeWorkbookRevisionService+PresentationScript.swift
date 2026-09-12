import Foundation
import LungfishIO

extension GenotypeWorkbookRevisionService {
    static func callsFromPresentation(_ payload: GenotypeWorkbookPresentation.Payload) -> [GenotypeWorkbookHaplotypeCall] {
        payload.calls.map { call in
            .init(sample: call.sampleID, locus: call.locus, haplotype1: call.h1.effective, haplotype2: call.h2.effective,
                status: call.h1.status, notes: call.comment ?? "", baselineHaplotype1: call.h1.pipeline, baselineHaplotype2: call.h2.pipeline,
                haplotype1Status: call.h1.status, haplotype2Status: call.h2.status, haplotype1Source: call.h1.source, haplotype2Source: call.h2.source)
        }
    }

    static func callsFromEditableBaseline(_ baseline: GenotypeEditableWorkbookService.Baseline) throws -> [GenotypeWorkbookHaplotypeCall] {
        if let manifestData = baseline.trustedManifest,
           let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
           let targets = manifest["callTargets"] as? [String: [String: Any]] {
            return try targets.keys.sorted().map { key in
                guard let target = targets[key], let sample = target["sampleID"] as? String,
                      let locus = target["locus"] as? String, let h1 = target["h1"] as? [String: Any], let h2 = target["h2"] as? [String: Any],
                      let effective1 = h1["effective"] as? String, let effective2 = h2["effective"] as? String else {
                    throw GenotypeWorkbookRevisionError.workbookOverrideFailed("Invalid trusted call target.")
                }
                return .init(sample: sample, locus: locus, haplotype1: effective1, haplotype2: effective2, status: "unavailable", notes: "",
                    baselineHaplotype1: h1["pipeline"] as? String, baselineHaplotype2: h2["pipeline"] as? String)
            }
        }
        let rows = baseline.document.sheets["Edit Calls"] ?? []
        guard let header = rows.first else { return [] }
        var grouped: [String: [String: String]] = [:]
        for row in rows.dropFirst() {
            let record = Dictionary(uniqueKeysWithValues: zip(header, row))
            guard let sample = record["Sample"], let locus = record["Locus"], let slot = record["Slot"], ["h1", "h2"].contains(slot) else { continue }
            let key = sample + "\u{1f}" + locus
            grouped[key, default: ["sample": sample, "locus": locus]][slot] = record["Effective call"] ?? ""
            if record["Baseline available"] == "yes" { grouped[key]?[slot + "baseline"] = record["Baseline call"] ?? "" }
        }
        return grouped.keys.sorted().compactMap { key in
            guard let value = grouped[key], let sample = value["sample"], let locus = value["locus"] else { return nil }
            return .init(sample: sample, locus: locus, haplotype1: value["h1"] ?? "", haplotype2: value["h2"] ?? "", status: "unavailable", notes: "",
                baselineHaplotype1: value["h1baseline"], baselineHaplotype2: value["h2baseline"])
        }
    }

    /// Consumes only the witnessed scientific snapshots. The source workbook
    /// remains retained evidence, never an authority for new scientific cells.
    var workbookPresentationScript: String {
        GenotypeWorkbookPresentation.pythonScript + #"""

import sys, json, hashlib, platform, os, shutil
from datetime import datetime, timezone
import openpyxl

def read_json(path, default):
    if not path:
        return default
    with open(path) as handle:
        return json.load(handle)

source_path, output_path, calls_path, sidecar_path, configuration_path, catalog_path, semantic_calls_path = sys.argv[1:8]
configuration = read_json(configuration_path, {})
sidecar = read_json(sidecar_path, {})
catalog = read_json(catalog_path, {})
calls_input = read_json(semantic_calls_path, [])
presentation_inputs = read_json(sys.argv[9], {}) if len(sys.argv) > 9 else {}

def identity(target):
    return hashlib.sha256(json.dumps(target, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()

def target_key(target):
    return tuple(target.get(key) or '' for key in ('kind', 'locus', 'genotype', 'sample', 'stableClusterID'))

def parsed_date(value):
    try:
        result = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        return result.replace(tzinfo=timezone.utc) if result.tzinfo is None else result
    except (TypeError, ValueError):
        return None

def resolved(entries):
    result = {}
    for entry in entries:
        key = target_key(entry.get('target', {}))
        old = result.get(key)
        old_date = parsed_date(old.get('timestamp')) if old else None
        new_date = parsed_date(entry.get('timestamp'))
        if old is None or old_date is None or new_date is None or new_date >= old_date:
            result[key] = entry
    return result

comments = resolved(sidecar.get('matrixComments', []))
styles = resolved(sidecar.get('matrixStyles', []))
# Shared Swift eligibility is resolved from the same witnessed inputs and
# retained in presentation-inputs.json with its policy version and checksum.
reviews = {target_key(entry['target']): entry for entry in presentation_inputs.get('eligibleMatrixReviews', [])}

def comment(target):
    return comments.get(target_key(target), {}).get('body')

def fill(target):
    return styles.get(target_key(target), {}).get('style', {}).get('fillColor')

roster = list(catalog.get('samples') or [s['sample'] for s in configuration.get('samples', [])])
scientific_roster = set(roster)
# Established duplicate call semantics are last exact sample/locus wins.
call_map = {}
for call in calls_input:
    call_map[(call['sample'], call['locus'])] = call
for sample, locus in call_map:
    if sample not in roster:
        roster.append(sample)
calls = []
loci = list(dict.fromkeys(presentation_inputs.get('includedLoci', [])))
for (sample, locus), call in call_map.items():
    if locus not in loci:
        loci.append(locus)
    slots = {}
    for index in (1, 2):
        baseline = call.get('baselineHaplotype' + str(index))
        slots['h' + str(index)] = dict(effective=call['haplotype' + str(index)], pipeline=baseline,
            baselineAvailable=baseline is not None, status=call.get('haplotype' + str(index) + 'Status') or call.get('status', ''),
            source=call.get('haplotype' + str(index) + 'Source') or 'unavailable')
    calls.append(dict(id=identity(dict(sampleID=sample,locus=locus)), sampleID=sample, locus=locus,
        h1=slots['h1'], h2=slots['h2'], comment=call.get('notes')))

evidence = catalog.get('rows', [])
if not catalog:
    evidence = [dict(call_id=c['call_id'], display_name=c['call_id'], locus=c['locus'],
        support_by_sample=[dict(sample=s, support=c['reads_by_sample'].get(s)) for s in scientific_roster])
        for c in configuration.get('known_calls', [])]
    # An absent candidate observation is unknown in legacy inputs.
    for row in configuration.get('normalized_unmatched_rows', []):
        evidence.append(dict(call_id=row.get('provisional_allele_name') or row['stable_cluster_id'],
            display_name=row.get('provisional_allele_name') or row['stable_cluster_id'],
            locus=row.get('locus') or '', stable_id=row['stable_cluster_id'],
            support_by_sample=[dict(sample=s, support=n) for s,n in row.get('reads_by_sample', {}).items()]))

rows = []
names = configuration.get('known_allele_display_names', {})
candidate_fills = {}
for candidate in configuration.get('normalized_unmatched_rows', []):
    if candidate.get('record_category') != 'candidate':
        continue
    category = ('shared' if candidate.get('support_class') == 'shared' else 'singleton') + ('Extension' if candidate.get('classification_or_reason') == 'extension' else 'Novel')
    tint = configuration.get('tints', {}).get(category)
    if tint:
        candidate_fills[candidate['stable_cluster_id']] = '#' + ''.join(f'{int(float(tint[c]) * 255 + 0.5):02X}' for c in ('alpha', 'red', 'green', 'blue'))
for row in evidence:
    target = dict(kind='row', locus=row['locus'], genotype=row['call_id'])
    if row.get('stable_id'):
        target['stableClusterID'] = row['stable_id']
    support = {s['sample']: s['support'] for s in row['support_by_sample']}
    cells = []
    for sample in roster:
        cell_target = dict(target, kind='cell', sample=sample)
        raw = support.get(sample)
        review = reviews.get(target_key(cell_target), {}).get('disposition')
        review = {'falsePositive':'false-positive','falseNegative':'false-negative'}.get(review)
        cells.append(dict(sampleID=sample, displayValue=raw, rawSupport=raw, reviewEligible=raw is not None,
            fillHex=fill(cell_target), comment=comment(cell_target), review=review))
    rows.append(dict(id=identity(target), target=target, displayName=names.get(row['call_id'], row['display_name']),
        fillHex=fill(target) or candidate_fills.get(row.get('stable_id')), comment=comment(target), cells=cells))

payload = dict(schemaVersion=2, role='editable-current', sourceRevision=presentation_inputs.get('sourceRevision', {}),
    samples=[dict(id=s, name=s, comment=comment(dict(kind='column',sample=s))) for s in roster],
    loci=loci, rows=rows, calls=calls, colors=presentation_inputs.get('colors', []),
    metadata=[['Scope','All evidence'],['Presentation schema','2']],
    callEditingSupported=configuration.get('haplotype_projection_mode') != 'manual-genotype-only')
with open(os.path.join(os.path.dirname(output_path), 'presentation-payload.json'), 'w') as handle:
    json.dump(payload, handle, sort_keys=True, ensure_ascii=False)
# This must be the final XLSX writer: it injects formula caches after save.
manifest = render_three_sheet_workbook(payload, output_path)
def package_members(path):
    with zipfile.ZipFile(path) as archive:
        result = {}
        for name in archive.namelist():
            content = archive.read(name)
            if name == 'docProps/core.xml':
                content = re.sub(rb'(<dcterms:(?:created|modified)\b[^>]*>).*?(</dcterms:(?:created|modified)>)', rb'\1\2', content)
            result[name] = content
        return result
# Preserve the exact previous cached bytes for a semantic no-op. This is a
# byte copy, never an openpyxl save after formula-cache injection.
if package_members(source_path) == package_members(output_path):
    shutil.copyfile(source_path, output_path)
with open(os.path.join(os.path.dirname(output_path), 'presentation-layout.json'), 'w') as handle:
    json.dump(manifest, handle, sort_keys=True, ensure_ascii=False)
print(json.dumps(dict(python_executable=sys.executable, python_version=platform.python_version(), openpyxl_version=openpyxl.__version__,
    workbook_matrix_adapter_version='three-sheet-v2',
    workbook_adapter_decisions=[dict(adapter='authoritative-catalog' if catalog else 'witnessed-csv', rows=len(rows), samples=len(roster))],
    managed_review_restoration_decisions=[], false_negative_synthesis_decisions=[], false_negative_target_cell_decisions=[],
    matrix_descriptor_scan_count=0, matrix_row_signature_count=len(rows))))
"""#
    }
}
