#!/usr/bin/env python3
"""Convert the legacy MHC genotyper notebook's haplotype dictionaries into
Lungfish `GenotypeHaplotypeDefinitionSet` JSON files.

The notebook (`mhc_genotyper_for_github.ipynb`) defines two nested dictionaries,
`mcm` (Mauritian cynomolgus macaque, prefix ``Mafa``) and `indian_rhesus`
(Indian rhesus macaque, prefix ``Mamu``). Each has the shape::

    <dict>['PREFIX'] = 'Mafa'
    <dict>['MHC_<LOCUS>_HAPLOTYPES'] = {
        '<haplotype name>': ['<diagnostic allele>', ...],
        ...
    }

A haplotype "requires" its listed diagnostic alleles. We map each to::

    GenotypeHaplotypeDefinitionSet:
      id, assayID, displayName, speciesName, speciesCode, prefix,
      locusDefinitions: [ { locus, sourceLocus,
                            haplotypes: [ { name, diagnosticAlleles: [...] } ] } ]

Diagnostic-allele tokens are kept VERBATIM (including the single token that uses
``|``/``,`` alternation): the Lungfish matcher
(`GenotypeHaplotypeDiagnosticMatcher`) splits on those characters at match time,
so no pre-splitting is needed here. ``minimumMatches`` is intentionally omitted,
which Lungfish interprets as "all listed diagnostic alleles required" — the
strict notebook rule. ``colorTokenIndex`` is omitted so Lungfish derives it from
the haplotype name.

The emitted JSON validates against `lungfish-cli haplotypes validate <file>` and
can be imported with `lungfish-cli haplotypes import <file> --scope project`,
then turned into a `.lungfishmhcref` bundle with `haplotypes bundle-create`.

The output JSON files are derived data and are written to ``~/Downloads`` by
default; they are NOT meant to be committed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


# Species metadata keyed by the notebook variable name.
SPECIES = {
    "mcm": {
        "id": "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
        "assayID": "MHC-exon2-miSeq",
        "displayName": "Mauritian Cynomolgus Macaque MHC (MiSeq)",
        "speciesName": "Mauritian cynomolgus macaque",
        "speciesCode": "MCM",
        "out": "mcm.haplotypes.json",
    },
    "indian_rhesus": {
        "id": "MHC-exon2-miSeq.indian-rhesus-macaques",
        "assayID": "MHC-exon2-miSeq",
        "displayName": "Indian Rhesus Macaque MHC (MiSeq)",
        "speciesName": "Indian rhesus macaque",
        "speciesCode": "Mamu",
        "out": "indian-rhesus.haplotypes.json",
    },
}

# Canonical locus order for stable output.
LOCUS_ORDER = ["A", "B", "DPA", "DPB", "DQA", "DQB", "DRB"]


def _exec_notebook_dicts(notebook_path: Path) -> dict[str, Any]:
    """Execute the notebook code cells that define `mcm` / `indian_rhesus` and
    return the resulting namespace. Only cells that look like the dictionary
    definitions are executed, in a restricted namespace."""
    notebook = json.loads(notebook_path.read_text())
    namespace: dict[str, Any] = {}
    for cell in notebook.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        source = "".join(cell.get("source", []))
        defines_dict = (
            ("mcm" in source or "indian_rhesus" in source)
            and "MHC_A_HAPLOTYPES" in source
        )
        if not defines_dict:
            continue
        try:
            exec(source, namespace)  # noqa: S102 - trusted local notebook
        except Exception as error:  # pragma: no cover - defensive
            print(f"warning: could not exec a notebook cell: {error}", file=sys.stderr)
    return namespace


def _locus_definitions(species_dict: dict[str, Any]) -> list[dict[str, Any]]:
    """Build the `locusDefinitions` array from a notebook species dict."""
    # Map MHC_<LOCUS>_HAPLOTYPES keys to their <LOCUS> token.
    locus_keys = {
        key[len("MHC_") : -len("_HAPLOTYPES")]: key
        for key in species_dict
        if key.startswith("MHC_") and key.endswith("_HAPLOTYPES")
    }
    ordered = [locus for locus in LOCUS_ORDER if locus in locus_keys]
    # Append any loci not in the canonical order (defensive; preserves data).
    ordered += [locus for locus in sorted(locus_keys) if locus not in ordered]

    locus_definitions: list[dict[str, Any]] = []
    for locus in ordered:
        haplotype_map: dict[str, list[str]] = species_dict[locus_keys[locus]]
        haplotypes = [
            {
                "name": name,
                # Keep tokens verbatim; the matcher handles |/, alternation.
                "diagnosticAlleles": list(alleles),
            }
            for name, alleles in haplotype_map.items()
        ]
        locus_definitions.append(
            {
                "locus": f"MHC-{locus}",
                "sourceLocus": locus,
                "haplotypes": haplotypes,
            }
        )
    return locus_definitions


def _definition_set(var_name: str, species_dict: dict[str, Any]) -> dict[str, Any]:
    meta = SPECIES[var_name]
    prefix = species_dict.get("PREFIX", "")
    return {
        "id": meta["id"],
        "assayID": meta["assayID"],
        "displayName": meta["displayName"],
        "speciesName": meta["speciesName"],
        "speciesCode": meta["speciesCode"],
        "prefix": prefix,
        "locusDefinitions": _locus_definitions(species_dict),
        "changeNote": f"Converted from {meta['out']} source notebook dictionary.",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--notebook",
        default=str(Path.home() / "Downloads" / "mhc_genotyper_for_github.ipynb"),
        help="Path to mhc_genotyper_for_github.ipynb",
    )
    parser.add_argument(
        "--out-dir",
        default=str(Path.home() / "Downloads"),
        help="Directory to write the *.haplotypes.json files (default: ~/Downloads)",
    )
    args = parser.parse_args(argv)

    notebook_path = Path(os.path.expanduser(args.notebook))
    out_dir = Path(os.path.expanduser(args.out_dir))
    if not notebook_path.is_file():
        print(f"error: notebook not found: {notebook_path}", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)

    namespace = _exec_notebook_dicts(notebook_path)

    exit_code = 0
    for var_name, meta in SPECIES.items():
        species_dict = namespace.get(var_name)
        if not isinstance(species_dict, dict):
            print(f"error: '{var_name}' dict not found in notebook", file=sys.stderr)
            exit_code = 1
            continue
        definition_set = _definition_set(var_name, species_dict)
        out_path = out_dir / meta["out"]
        out_path.write_text(json.dumps(definition_set, indent=2) + "\n")

        loci = definition_set["locusDefinitions"]
        total_haplotypes = sum(len(locus["haplotypes"]) for locus in loci)
        print(f"wrote {out_path}")
        print(
            f"  id={definition_set['id']} prefix={definition_set['prefix']!r} "
            f"loci={len(loci)} haplotypes={total_haplotypes}"
        )
        for locus in loci:
            print(f"    {locus['locus']}: {len(locus['haplotypes'])} haplotypes")

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
