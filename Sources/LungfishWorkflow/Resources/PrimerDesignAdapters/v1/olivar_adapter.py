"""Pinned Olivar 1.3.3 invocation and normalization for adapter schema v1."""

from __future__ import annotations

import csv
import hashlib
import importlib.metadata
import inspect
import json
from pathlib import Path
import sys
import textwrap
from typing import Any

from common import (
    AdapterError,
    accept_pair_length,
    deterministic_id,
    native_event,
    sha256_file,
    validate_target_contract,
    write_json,
)


ENGINE_VERSION = "1.3.3"
SOURCE_HASHES = {
    "main.py": "32fe3a1fe007538210cbafe34cc2c37f0881ff47aee822a0767d639c3cf0c269",
    "msa_tools.py": "d65777654e086cb71d9ab98ac8bb3f8ed8b52fc01676fa97ee256b5542562153",
    "tiling_helper.py": "2de15defe24df35b7d3eb1af7b83a621dcbc023d97a58d9a7ebd9403a0d31f74",
    "save_helper.py": "3b95a2bc6f6e598c6236ad90afb3626236b414eb0d37e889cbd64423aa60d758",
}


def verify_runtime() -> dict[str, Any]:
    try:
        import olivar
        import main
        import msa_tools
        import save_helper
        import tiling_helper
    except Exception as error:
        raise AdapterError("runtime_verification_failed", f"cannot import pinned Olivar runtime: {error}") from error
    version = getattr(olivar, "__version__", None)
    try:
        distribution_version = importlib.metadata.version("olivar")
    except importlib.metadata.PackageNotFoundError:
        distribution_version = None
    if version != ENGINE_VERSION or distribution_version != ENGINE_VERSION:
        raise AdapterError(
            "runtime_verification_failed",
            "Olivar runtime version does not match adapter contract",
            {"moduleVersion": version, "distributionVersion": distribution_version, "expected": ENGINE_VERSION},
        )
    modules = {"main.py": main, "msa_tools.py": msa_tools, "tiling_helper.py": tiling_helper, "save_helper.py": save_helper}
    verification = []
    for name, module in modules.items():
        path = Path(module.__file__).resolve()
        actual = sha256_file(path)
        expected = SOURCE_HASHES[name]
        verification.append({
            "path": str(path), "sha256": actual, "expectedSHA256": expected,
            "byteSize": path.stat().st_size,
        })
        if actual != expected:
            raise AdapterError(
                "runtime_verification_failed",
                f"Olivar source hash mismatch for {name}",
                {"path": str(path), "actual": actual, "expected": expected},
            )
    conda_path = Path(sys.prefix) / "conda-meta" / "olivar-1.3.3-pyhdfd78af_3.json"
    if not conda_path.is_file():
        raise AdapterError("runtime_verification_failed", "exact Olivar Conda package record is missing")
    conda_metadata = json.loads(conda_path.read_text(encoding="utf-8"))
    expected_conda = {"name": "olivar", "version": "1.3.3", "build": "pyhdfd78af_3", "channel": "bioconda"}
    actual_conda = {key: conda_metadata.get(key) for key in expected_conda}
    if actual_conda != expected_conda:
        raise AdapterError(
            "runtime_verification_failed", "Olivar Conda package record does not match the pinned distribution",
            {"expected": expected_conda, "actual": actual_conda, "path": str(conda_path.resolve())},
        )
    conda_record = {
        "path": str(conda_path.resolve()),
        "sha256": sha256_file(conda_path),
        "byteSize": conda_path.stat().st_size,
        **actual_conda,
        "subdir": conda_metadata.get("subdir"),
        "url": conda_metadata.get("url"),
    }
    return {
        "version": version,
        "modulePath": str(Path(olivar.__file__).resolve()),
        "sourceVerification": verification,
        "environmentPrefix": str(Path(sys.prefix).resolve()),
        "distribution": "bioconda::olivar=1.3.3=pyhdfd78af_3",
        "condaPackageRecord": conda_record,
        "modules": {"olivar": olivar, "main": main, "msa_tools": msa_tools, "tiling_helper": tiling_helper},
    }


_PAIR_BLOCK = """\
                # check amplicon length
                amp_len = fp['primer_len'] + fp['dist'] + insert_len + rp['dist'] + rp['primer_len']
                plex_amp_len.append(amp_len)
                optimize.append([fp, rp])
        plex_info['optimize'] = optimize
"""

_GUARDED_PAIR_BLOCK = """\
                # check final full-span amplicon length (Lungfish adapter v1)
                amp_len = fp['primer_len'] + fp['dist'] + insert_len + rp['dist'] + rp['primer_len']
                plex_amp_len.append(amp_len)
                if _lungfish_accept_pair_length(amp_len, minimum=_lungfish_minimum, maximum=_lungfish_maximum):
                    optimize.append([fp, rp])
        if not optimize:
            raise _LungfishAdapterError(
                'no_feasible_design',
                'Olivar tile has no primer pair inside the requested final-span bounds',
                {'tileID': str(plex_id), 'minimum': _lungfish_minimum, 'maximum': _lungfish_maximum,
                 'candidateLengths': sorted(set(int(value) for value in plex_amp_len))},
            )
        plex_info['optimize'] = optimize
"""


def install_pair_guard(tiling_helper_module: Any, *, minimum: int, maximum: int):
    """Install the version-locked pair-list guard before upstream SADDLE code."""
    accept_pair_length(minimum, minimum=minimum, maximum=maximum)
    original = tiling_helper_module.optimize
    source = textwrap.dedent(inspect.getsource(original))
    if source.count(_PAIR_BLOCK) != 1:
        raise AdapterError(
            "runtime_verification_failed",
            "pinned Olivar optimize pair-construction source did not match the adapter patch",
        )
    patched_source = source.replace(_PAIR_BLOCK, _GUARDED_PAIR_BLOCK)
    globals_dict = original.__globals__
    globals_dict["_lungfish_accept_pair_length"] = accept_pair_length
    globals_dict["_lungfish_minimum"] = minimum
    globals_dict["_lungfish_maximum"] = maximum
    globals_dict["_LungfishAdapterError"] = AdapterError
    namespace: dict[str, Any] = {}
    exec(compile(patched_source, str(getattr(tiling_helper_module, "__file__", "<olivar-pair-guard>")), "exec"), globals_dict, namespace)
    patched = namespace["optimize"]
    patched.__name__ = original.__name__
    patched.__qualname__ = original.__qualname__
    patched.__doc__ = original.__doc__
    tiling_helper_module.optimize = patched
    return patched


def build_msa_projection(gapped_consensus: str, generated_consensus: str) -> list[dict[str, Any]]:
    """Map an Olivar gapless consensus to its exact MSA consensus columns."""
    gapped = gapped_consensus.upper()
    generated = generated_consensus.upper()
    if gapped.replace("-", "") != generated:
        raise AdapterError("native_contract_mismatch", "Olivar gapless consensus does not match MSA consensus columns")
    blocks: list[dict[str, Any]] = []
    source = generated_position = 0
    while source < len(gapped):
        is_gap = gapped[source] == "-"
        start_source = source
        start_generated = generated_position
        while source < len(gapped) and (gapped[source] == "-") == is_gap:
            if not is_gap:
                generated_position += 1
            source += 1
        blocks.append({
            "generatedStart": start_generated,
            "generatedEnd": generated_position,
            "sourceStart": start_source,
            "sourceEnd": source,
            "kind": "collapsed" if is_gap else "mapped",
        })
    return blocks


def capture_msa_projection(
    msa_path: Path,
    *,
    degenerate: bool,
    workers: int,
    modules: dict[str, Any] | None = None,
    recorder: dict[str, Any] | None = None,
) -> tuple[str, str, list[dict[str, Any]]]:
    if modules is None:
        modules = verify_runtime()["modules"]
    recorder = recorder if recorder is not None else {"nativeEvents": []}
    msa_tools = modules["msa_tools"]
    with native_event(
        recorder, engine="olivar", kind="inProcessAPI", module="msa_tools", function="MSA",
        arguments={"fasta_path": str(msa_path), "n_cpu": workers},
        module_path=str(Path(msa_tools.__file__).resolve()),
    ) as event:
        msa = msa_tools.MSA(str(msa_path), workers)
        event["result"] = {"instanceType": "MSA", "sourcePath": str(msa_path)}
    with native_event(
        recorder, engine="olivar", kind="inProcessAPI", module="msa_tools.MSA", function="_get_consensus",
        arguments={"sourcePath": str(msa_path), "n_cpu": workers, "deg": degenerate, "show_progress": False},
        module_path=str(Path(msa_tools.__file__).resolve()),
    ) as event:
        msa._get_consensus(workers, deg=degenerate, show_progress=False)
        event["result"] = {"consensusLength": len(str(msa.consensus))}
    gapped = "".join(str(base) for base in msa.consensus_array)
    generated = str(msa.consensus)
    return gapped, generated, build_msa_projection(gapped, generated)


def _build_reference(
    modules: dict[str, Any],
    *,
    msa_path: Path,
    out_path: Path,
    title: str,
    workers: int,
    minimum_variant_frequency: float,
    degenerate: bool,
    blast_database: str | None,
    recorder: dict[str, Any],
) -> bool:
    """Use pinned build primitives while accepting an invariant MSA.

    Olivar 1.3.3 writes a header-only variant CSV for an invariant MSA and
    then rejects pandas' object dtype for those empty columns. Passing no
    variant file is the native representation of the same empty variant set.
    """
    main = modules["main"]
    preprocess_arguments = {
        "msa_path": str(msa_path), "msa_filename": msa_path.stem, "prefix": str(out_path),
        "n_cpu": workers, "min_var": minimum_variant_frequency, "deg": degenerate,
    }
    with native_event(
        recorder, engine="olivar", kind="inProcessAPI", module="main", function="run_preprocess",
        arguments=preprocess_arguments,
        module_path=str(Path(main.__file__).resolve()),
    ) as event:
        fasta_path, variant_path = main.run_preprocess(
            str(msa_path), msa_path.stem, str(out_path), workers,
            minimum_variant_frequency, degenerate,
        )
        event["result"] = {"fasta_path": fasta_path, "variant_path": variant_path}
    variant_file = Path(variant_path)
    empty_variant_table = len(variant_file.read_text(encoding="utf-8").splitlines()) <= 1
    if empty_variant_table:
        variant_path = None
    build_arguments = {
        "fasta_path": fasta_path,
        "msa_path": str(msa_path) if degenerate else None,
        "var_path": variant_path,
        "BLAST_db": blast_database,
        "out_path": str(out_path),
        "title": title,
        "threads": workers,
        "deg": degenerate,
    }
    with native_event(
        recorder, engine="olivar", kind="inProcessAPI", module="main", function="run_build",
        arguments=build_arguments,
        module_path=str(Path(main.__file__).resolve()),
    ):
        main.run_build(
            fasta_path,
            str(msa_path) if degenerate else None,
            variant_path,
            blast_database,
            str(out_path),
            title,
            workers,
            deg=degenerate,
        )
    return empty_variant_table


def _read_single_fasta(path: Path) -> tuple[str, str]:
    identifier = None
    sequence: list[str] = []
    records = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith(">"):
            records += 1
            if records > 1:
                raise AdapterError("native_contract_mismatch", f"generated reference contains multiple records: {path}")
            identifier = line[1:].split()[0]
        else:
            if identifier is None:
                raise AdapterError("native_contract_mismatch", f"invalid FASTA: {path}")
            sequence.append(line)
    if records != 1 or not sequence:
        raise AdapterError("native_contract_mismatch", f"invalid generated FASTA: {path}")
    return identifier, "".join(sequence).upper()


def _read_bed(path: Path) -> dict[str, dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            fields = raw.rstrip("\n").split("\t")
            if len(fields) != 7:
                raise AdapterError("native_contract_mismatch", f"invalid Olivar BED row {line_number}")
            name = fields[3]
            if name in records:
                raise AdapterError("native_contract_mismatch", f"duplicate Olivar BED oligo {name}")
            records[name] = {
                "reference": fields[0], "start": int(fields[1]), "end": int(fields[2]),
                "name": name, "pool": fields[4], "strand": fields[5], "sequence": fields[6].upper(),
            }
    return records


def normalize_olivar_outputs(
    native_dir: Path,
    *,
    title: str,
    source_input_id: str,
    target_id: str,
    label: str,
    reference_path: str,
    minimum: int,
    maximum: int,
    binding_projection_path: str = "mappings/projection.json",
    reference_name: str | None = None,
    csv_reference_name: str | None = None,
) -> dict[str, Any]:
    csv_path = native_dir / f"{title}.csv"
    bed_path = native_dir / f"{title}.primer.bed"
    reference_file = native_dir / Path(reference_path).name
    if not reference_file.is_file():
        candidates = sorted(native_dir.glob("*_ref.fasta"))
        if reference_name:
            candidates = [candidate for candidate in candidates if candidate.name == f"{reference_name}_ref.fasta"]
        if len(candidates) != 1:
            raise AdapterError("native_contract_mismatch", "cannot identify Olivar generated reference")
        reference_file = candidates[0]
    reference_id, reference_sequence = _read_single_fasta(reference_file)
    bed = _read_bed(bed_path)
    assays: list[dict[str, Any]] = []
    oligos: list[dict[str, Any]] = []
    with csv_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    csv_reference_name = csv_reference_name if csv_reference_name is not None else reference_name
    if csv_reference_name is not None:
        rows = [row for row in rows if row["reference"] == csv_reference_name]
    if not rows:
        raise AdapterError("no_feasible_design", "Olivar produced no assays for target", {"target": label})
    for rank, row in enumerate(rows, 1):
        start = int(row["start"]) - 1
        end = int(row["end"])
        if not accept_pair_length(end - start, minimum=minimum, maximum=maximum):
            raise AdapterError(
                "native_contract_mismatch", "Olivar final assay violates requested span bounds",
                {"ampliconID": row["amplicon_id"], "length": end - start, "minimum": minimum, "maximum": maximum},
            )
        assay_id = deterministic_id(target_id, "assay", row["amplicon_id"])
        member_ids: list[str] = []
        expected = [
            ("forward", "+", start, int(row["insert_start"]) - 1, row["fP"].upper(), "LEFT"),
            ("reverse", "-", int(row["insert_end"]), end, row["rP"].upper(), "RIGHT"),
        ]
        for role, strand, oligo_start, oligo_end, sequence, suffix in expected:
            matching_names = [name for name in bed if name.startswith(f"{row['amplicon_id']}_{suffix}_")]
            if len(matching_names) != 1:
                raise AdapterError("native_contract_mismatch", f"missing or duplicate Olivar BED member for {row['amplicon_id']}")
            native = bed[matching_names[0]]
            if (native["start"], native["end"], native["strand"], native["sequence"]) != (oligo_start, oligo_end, strand, sequence):
                raise AdapterError("native_contract_mismatch", "Olivar CSV/BED coordinates or sequences disagree")
            oligo_id = deterministic_id(target_id, "oligo", native["name"])
            member_ids.append(oligo_id)
            oligos.append({
                "id": oligo_id,
                "name": native["name"],
                "role": role,
                "sequence": sequence,
                "start": oligo_start,
                "end": oligo_end,
                "strand": strand,
                "assayIDs": [assay_id],
                "pool": str(row["pool"]),
                "nativeMetadata": {
                    "fullSequence": row["fP_full"] if role == "forward" else row["rP_full"],
                    "nativeReference": row["reference"],
                },
            })
        assays.append({
            "id": assay_id,
            "start": start,
            "end": end,
            "memberIDs": member_ids,
            "pool": str(row["pool"]),
            "status": "selected",
            "rank": rank,
            "nativeMetadata": {
                "ampliconID": row["amplicon_id"],
                "insertStartOneBased": int(row["insert_start"]),
                "insertEndOneBased": int(row["insert_end"]),
            },
        })
    target = {
        "id": target_id,
        "label": label,
        "referencePath": reference_path,
        "referenceID": reference_id,
        "referenceLength": len(reference_sequence),
        "sourceInputID": source_input_id,
        "bindingProjectionPath": binding_projection_path,
        "assays": assays,
        "oligos": oligos,
    }
    validate_target_contract(target)
    return target


def _invoke_tiling(
    modules: dict[str, Any], ref_input: Path, design_dir: Path, design_title: str,
    options: dict[str, Any], recorder: dict[str, Any], grouping: str, input_ids: list[str],
) -> None:
    design_dir.mkdir(parents=True)
    risk = options["riskWeights"]
    arguments = {
        "ref_path": str(ref_input), "out_path": str(design_dir), "title": design_title,
        "max_amp_len": options["maximumAmpliconLength"], "min_amp_len": options["minimumAmpliconLength"],
        "w_egc": risk["extremeGC"], "w_lc": risk["lowComplexity"], "w_ns": risk["nonSpecificity"],
        "w_var": risk["variation"], "w_sensi": risk["sensitivity"], "w_combi": risk["combination"],
        "temperature": options["temperatureC"], "salinity": options["salinityM"],
        "dG_max": options["maximumDimerDeltaG"], "min_GC": options["minimumGC"],
        "max_GC": options["maximumGC"], "min_complexity": options["minimumComplexity"],
        "max_len": options["maximumPrimerLength"], "check_var": options["checkVariants"],
        "fP_prefix": options["forwardPrefix"], "rP_prefix": options["reversePrefix"],
        "seed": options["seed"], "threads": options["workers"], "iterMul": options["effort"],
        "deg": options["degenerate"],
    }
    with native_event(
        recorder, engine="olivar", kind="inProcessAPI", module="olivar", function="tiling",
        arguments=arguments,
        module_path=str(Path(modules["olivar"].__file__).resolve()),
    ) as event:
        event["adapterContext"] = {"grouping": grouping, "inputIDs": input_ids}
        modules["olivar"].tiling(**arguments)


def run_olivar(
    request: dict[str, Any], stage: Path, recorder: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any]]:
    recorder = recorder if recorder is not None else {"runtime": None, "nativeInvocations": [], "nativeEvents": []}
    with native_event(
        recorder, engine="olivar", kind="runtimeVerification", module="olivar_adapter", function="verify_runtime",
        arguments={"engineVersion": ENGINE_VERSION, "sourceHashes": SOURCE_HASHES},
        module_path=str(Path(__file__).resolve()),
    ) as event:
        runtime = verify_runtime()
        recorder["runtime"] = runtime
        event["result"] = {"distribution": runtime["distribution"], "modulePath": runtime["modulePath"]}
    modules = runtime["modules"]
    options = request["options"]
    with native_event(
        recorder, engine="olivar", kind="adapterTransform", module="olivar_adapter", function="install_pair_guard",
        arguments={
            "verifiedModulePath": str(Path(modules["tiling_helper"].__file__).resolve()),
            "minimum": options["minimumAmpliconLength"], "maximum": options["maximumAmpliconLength"],
        },
        module_path=str(Path(__file__).resolve()),
    ) as event:
        patched = install_pair_guard(
            modules["tiling_helper"],
            minimum=options["minimumAmpliconLength"],
            maximum=options["maximumAmpliconLength"],
        )
        event["result"] = {"patchedFunction": "tiling_helper.optimize", "sourceLocked": True}
    # olivar.main imported optimize by value; update that reference explicitly.
    modules["main"].optimize = patched
    references = stage / "native" / "references"
    references.mkdir(parents=True)
    mapping_records: dict[str, tuple[str, str, list[dict[str, Any]]]] = {}
    reference_titles: dict[str, str] = {}
    empty_variant_inputs: list[str] = []
    for item in request["inputs"]:
        input_id = item["id"]
        title = f"input-{input_id}"
        reference_titles[input_id] = title
        input_build_dir = references / input_id
        input_build_dir.mkdir()
        gapped, generated, blocks = capture_msa_projection(
            Path(item["path"]), degenerate=options["degenerate"], workers=options["workers"],
            modules=modules, recorder=recorder,
        )
        mapping_records[input_id] = (gapped, generated, blocks)
        empty_variant_table = _build_reference(
            modules,
            msa_path=Path(item["path"]),
            out_path=input_build_dir,
            title=title,
            workers=options["workers"],
            minimum_variant_frequency=options["minimumVariantFrequency"],
            degenerate=options["degenerate"],
            blast_database=options["blastDatabasePath"],
            recorder=recorder,
        )
        if empty_variant_table:
            empty_variant_inputs.append(input_id)
    jobs: list[tuple[list[dict[str, Any]], Path, Path, str]] = []
    if request["grouping"] == "combined":
        if len(request["inputs"]) == 1:
            only = request["inputs"][0]
            ref_input = references / only["id"] / f"{reference_titles[only['id']]}.olvr"
        else:
            ref_input = stage / "native" / "combined-references"
            ref_input.mkdir()
            for item in request["inputs"]:
                source = references / item["id"] / f"{reference_titles[item['id']]}.olvr"
                (ref_input / source.name).hardlink_to(source)
        jobs.append((request["inputs"], ref_input, stage / "native" / "design-combined", f"result-{request['resultID']}"))
    else:
        for item in request["inputs"]:
            ref_input = references / item["id"] / f"{reference_titles[item['id']]}.olvr"
            jobs.append(([item], ref_input, stage / "native" / "design" / item["id"], f"result-{item['id']}"))
    targets = []
    for job_items, ref_input, design_dir, design_title in jobs:
        _invoke_tiling(
            modules, ref_input, design_dir, design_title, options, recorder,
            request["grouping"], [item["id"] for item in job_items],
        )
        for item in job_items:
            input_id = item["id"]
            reference_name = reference_titles[input_id]
            native_reference = design_dir / f"{reference_name}_ref.fasta"
            reference_relative = native_reference.relative_to(stage).as_posix()
            target_id = deterministic_id(request["resultID"], "target", input_id)
            map_relative = f"mappings/{input_id}.json"
            _, generated, blocks = mapping_records[input_id]
            native_id, native_sequence = _read_single_fasta(native_reference)
            if native_sequence != generated:
                raise AdapterError("native_contract_mismatch", "captured Olivar consensus differs from saved reference")
            projection = {
                "schemaVersion": 1,
                "coordinateConvention": "zeroBasedHalfOpen",
                "sourceInputID": input_id,
                "sourcePath": item["path"],
                "generatedReferencePath": reference_relative,
                "sourceLength": len(mapping_records[input_id][0]),
                "generatedLength": len(generated),
                "blocks": blocks,
            }
            write_json(stage / map_relative, projection)
            targets.append(normalize_olivar_outputs(
                design_dir,
                title=design_title,
                source_input_id=input_id,
                target_id=target_id,
                label=item["label"],
                reference_path=reference_relative,
                minimum=options["minimumAmpliconLength"],
                maximum=options["maximumAmpliconLength"],
                binding_projection_path=map_relative,
                reference_name=reference_name,
                csv_reference_name=native_id,
            ))
    if request["grouping"] == "combined":
        results = [{"id": request["resultID"], "inputIDs": [item["id"] for item in request["inputs"]], "targets": targets}]
    else:
        results = [
            {"id": deterministic_id(request["resultID"], "result", target["sourceInputID"]), "inputIDs": [target["sourceInputID"]], "targets": [target]}
            for target in targets
        ]
    return results, runtime, {
        "finalPairGuard": "inclusiveBeforeSADDLE",
        "attemptedSeeds": [options["seed"]],
        "nominalAmpliconLengthRole": "displayAndProvenanceOnly",
        "groupingExecution": "singleCombinedInvocation" if request["grouping"] == "combined" else "independentInvocationPerInput",
        "emptyVariantInputsUsingNativeNoVariantPath": empty_variant_inputs,
    }
