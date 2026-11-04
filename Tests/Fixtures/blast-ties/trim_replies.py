#!/usr/bin/env python3
"""Trims saved NCBI BLAST replies to what the tie rule reads (BIO-BLAST-TIES item 16).

It reads each send's result.json2_s and nothing else from a send, so never put.body, meta.json or cookies.txt. Each hit
keeps every defline's accession, sciname and taxid, and its first HSP's bit score, E value, identity, alignment length
and query range, with no qseq, hseq, midline or title. Each search keeps its title, its length and the stat.db_num.

Usage: trim_replies.py <sends folder> <taxonomy folder> <output folder>
"""
import collections
import json
import os
import sys

# Reply folder, claim, and whether to keep only the tie and the next tier (the 5,000 list is 7 MB without them).
REPLIES = [
    ("t1-hiv2-500-a", "hiv", False),
    ("t3-hiv2-5000", "hiv", True),
    ("b01-rota7-lge", "rota", False),
    ("c7a-rota7-curl", "rota", False),
    ("t2-rota7-500-a", "rota", False),
]
CLAIMS = {
    "hiv": ("Human immunodeficiency virus 1", 11676),
    "rota": ("Rotavirus A", 28875),
}
HSP_FIELDS = ("bit_score", "evalue", "identity", "align_len", "query_from", "query_to")
DEFLINE_FIELDS = ("accession", "sciname", "taxid")


def read_taxonomy(folder):
    parent, rank, sci, merged = {}, {}, {}, {}
    with open(os.path.join(folder, "nodes.dmp")) as handle:
        for line in handle:
            fields = line.split("\t|\t")
            parent[int(fields[0])] = int(fields[1])
            rank[int(fields[0])] = fields[2].strip()
    with open(os.path.join(folder, "names.dmp")) as handle:
        for line in handle:
            fields = line.split("\t|\t")
            if fields[3].startswith("scientific name"):
                sci[int(fields[0])] = fields[1]
    merged_path = os.path.join(folder, "merged.dmp")
    if os.path.exists(merged_path):
        with open(merged_path) as handle:
            for line in handle:
                fields = line.replace("\t|\n", "").split("\t|\t")
                merged[int(fields[0])] = int(fields[1])
    return parent, rank, sci, merged


def species_clade(taxid, parent, rank, sci):
    node, path = taxid, []
    while True:
        path.append(node)
        if rank.get(node) == "species" or parent.get(node, node) == node:
            break
        node = parent[node]
    children = collections.defaultdict(list)
    for child, up in parent.items():
        if child != up:
            children[up].append(child)
    seen, stack = set(), [path[-1]]
    while stack:
        current = stack.pop()
        seen.add(current)
        stack.extend(children.get(current, []))
    return seen | set(path), [sci[n] for n in path if n in sci]


def trim_hit(hit):
    hsp = hit["hsps"][0]
    return {
        "description": [{k: d[k] for k in DEFLINE_FIELDS if k in d} for d in hit["description"]],
        "hsps": [{k: hsp[k] for k in HSP_FIELDS}],
    }


def trim_search(search, tiers_only):
    hits = [trim_hit(h) for h in search.get("hits", []) if h.get("hsps")]
    if tiers_only and hits:
        best = hits[0]["hsps"][0]["bit_score"]
        lower = [h["hsps"][0]["bit_score"] for h in hits if h["hsps"][0]["bit_score"] < best]
        kept = {best} | ({max(lower)} if lower else set())
        hits = [h for h in hits if h["hsps"][0]["bit_score"] in kept]
    return {
        "query_title": search.get("query_title", search.get("query_id")),
        "query_len": search.get("query_len"),
        "stat": {"db_num": search.get("stat", {}).get("db_num")},
        "hits": hits,
    }


def main():
    sends, taxonomy, output = sys.argv[1:4]
    parent, rank, sci, merged = read_taxonomy(taxonomy)
    clades = {key: species_clade(value[1], parent, rank, sci) for key, value in CLAIMS.items()}
    seen_ids = collections.defaultdict(set)
    os.makedirs(output, exist_ok=True)
    for name, claim, tiers_only in REPLIES:
        with open(os.path.join(sends, name, "result.json2_s"), errors="replace") as handle:
            reply = json.load(handle)
        entries = []
        for block in reply["BlastOutput2"]:
            results = block["report"]["results"]
            searches = [results["search"]] if "search" in results else [i.get("search", i) for i in results["iterations"]]
            for search in searches:
                entries.append({"report": {"results": {"search": trim_search(search, tiers_only)}}})
        for entry in entries:
            search = entry["report"]["results"]["search"]
            for hit in search["hits"]:
                seen_ids[claim].update(d["taxid"] for d in hit["description"] if d.get("taxid"))
            report(name, search, clades[claim][0], merged)
        path = os.path.join(output, name + ".json")
        with open(path, "w") as handle:
            json.dump({"BlastOutput2": entries}, handle, separators=(",", ":"))
        print(name, "bytes", os.path.getsize(path))
    # Only the clade's IDs these replies name, which judges them the same as the whole clade.
    claims = {}
    for key, (taxon, taxid) in CLAIMS.items():
        members, names = clades[key]
        ids = sorted(t for t in seen_ids[key] if t in members or merged.get(t, t) in members)
        claims[key] = {"taxonName": taxon, "taxId": taxid, "cladeNames": names, "cladeTaxIds": sorted(set(ids) | {taxid})}
    with open(os.path.join(output, "claims.json"), "w") as handle:
        json.dump(claims, handle, indent=1)


def report(name, search, members, merged):
    hits = search["hits"]
    if not hits:
        print(name, search["query_title"], search["query_len"], "no hits")
        return
    best = hits[0]["hsps"][0]["bit_score"]
    tied = [h for h in hits if h["hsps"][0]["bit_score"] == best]
    def inside(taxid):
        return taxid in members or merged.get(taxid, taxid) in members
    first = sum(inside(h["description"][0].get("taxid")) for h in tied)
    anyone = sum(any(inside(d.get("taxid")) for d in h["description"]) for h in tied)
    every = sum(all(inside(d.get("taxid")) for d in h["description"]) for h in tied)
    multi = [h["description"][0]["accession"] for h in tied if len({d.get("taxid") for d in h["description"]}) > 1]
    print(name, search["query_title"], "qlen", search["query_len"], "hits", len(hits), "best", best, "tied", len(tied),
          "clade first", first, "any", anyone, "all", every, "two-taxa records", multi[:8], "db_num", search["stat"]["db_num"])


main()
