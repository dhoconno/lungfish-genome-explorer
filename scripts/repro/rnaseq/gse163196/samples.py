"""Write the sample table of C9 (25 PBL runs of GSE163196 and 8 CSF runs of GSE163195).

Usage: python3 -I samples.py <studies_dir> > samples.tsv

Groups I to III are the paper's PBL against CSF comparisons (PMC9478118, Results, Figure 8C).
same_counts_as names the other GSE163196 run with equal ENA read_count and base_count: twelve
runs submitted in 2024 repeat the read and base counts of twelve runs submitted in 2020.
"""
import csv
import sys

GROUPS = {"B26": "I", "B31": "I", "C95": "I", "C100": "I",
          "B27": "II", "B32": "II", "B35": "II", "C96": "II", "C101": "II", "C106": "II",
          "B23": "III", "B29": "III", "B30": "III", "C89": "III", "C98": "III", "C99": "III"}


def main():
    root = sys.argv[1]
    rows = []
    for study in ("GSE163196", "GSE163195"):
        with open(f"{root}/{study}/samples.tsv") as fh:
            for r in csv.DictReader(fh, delimiter="\t"):
                name = r["geo_title"].split(":")[0].split(",")[0].strip()
                rows.append([r["run_accession"], study, r["geo_sample"], name,
                             "PBL" if study == "GSE163196" else "CSF",
                             r["animal_or_donor"].replace(" ", ""), GROUPS.get(name, "NA"), r["spots"]])
    with open(f"{root}/GSE163196/ena_filereport.tsv") as fh:
        key = {e["run_accession"]: (e["read_count"], e["base_count"]) for e in csv.DictReader(fh, delimiter="\t")}
    print("\t".join(["run", "study", "gsm", "sample", "tissue", "patient", "group", "spots", "same_counts_as"]))
    for row in rows:
        twins = [o[0] for o in rows if o[0] != row[0] and o[1] == row[1] == "GSE163196"
                 and key.get(o[0]) == key.get(row[0])]
        print("\t".join(row + [twins[0] if twins else "NA"]))


if __name__ == "__main__":
    main()
