"""Sample table and deposited matrices of GSE155673 (Arunachalam 2020).

samples SERIES_MATRIX OUT.tsv
    The 12 RNA libraries from the series matrix (title, GSM, sample name, disease status,
    severity, days since onset, age, sex), each tied to the paper's Table 2 id (cov1 to cov7,
    hd1 to hd5) by disease, severity, day, age and sex. Fails unless every library matches
    exactly one Table 2 row (SC-SUBSET item 8: cov_10's disease state comes from here).

deposits GEO_DIR SAMPLES.tsv OUT_DIR
    One MEX folder a library (OUT_DIR/<covNN>/{matrix.mtx,barcodes.tsv,features.tsv}.gz) as
    symbolic links to the deposited files, so tenx-controls/compare.py read_mex() reads them.

Run with python -I. The series matrix is a downloaded file, read as data only.
"""
import csv
import gzip
import os
import sys

# PMC7665312 Table 2: id, infection, response, ICU, day, age, sex, ethnicity (Results, CITE-seq).
TABLE2 = [
    ("cov1", "COVID-19", "Severe, dec.", "Y", "15", "60", "F"),
    ("cov2", "COVID-19", "Severe", "N", "15", "75", "F"),
    ("cov3", "COVID-19", "Severe", "N", "16", "59", "M"),
    ("cov4", "COVID-19", "Severe", "N", "8", "48", "M"),
    ("cov5", "COVID-19", "Moderate", "N", "9", "53", "F"),
    ("cov6", "COVID-19", "Moderate", "N", "2", "75", "F"),
    ("cov7", "COVID-19", "Moderate", "N", "9", "47", "F"),
    ("hd1", "Healthy", "-", "-", "NA", "84", "F"),
    ("hd2", "Healthy", "-", "-", "NA", "68", "F"),
    ("hd3", "Healthy", "-", "-", "NA", "38", "M"),
    ("hd4", "Healthy", "-", "-", "NA", "90", "M"),
    ("hd5", "Healthy", "-", "-", "NA", "70", "F"),
]


def samples(series, out):
    rows = {}
    with gzip.open(series, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("!Sample_"):
                continue
            f = [x.strip().strip('"') for x in line.rstrip("\n").split("\t")]
            rows.setdefault(f[0], []).append(f[1:])
    titles = rows["!Sample_title"][0]
    gsms = rows["!Sample_geo_accession"][0]
    chars = rows["!Sample_characteristics_ch1"]
    recs = []
    for j, t in enumerate(titles):
        if not t.endswith("_RNA"):
            continue
        d = {"title": t, "gsm": gsms[j], "library": t.replace("_RNA", "").replace("_", "")}
        for c in chars:
            k, _, v = c[j].partition(": ")
            d[k.strip().lower().replace(" ", "_")] = v.strip()
        recs.append(d)
    for d in recs:
        sev = d["disease_severity"]
        hits = [t for t in TABLE2 if t[1] == d["disease_status"] and t[6] == d["sex"] and t[5] == d["age"]
                and t[4] == d["days_since_symptom_onset"]
                and (t[1] == "Healthy" or t[2].split(",")[0] == sev)]
        if len(hits) != 1:
            sys.exit("prep: %s matches %d Table 2 rows" % (d["title"], len(hits)))
        d["paper_id"], d["paper_response"], d["icu"] = hits[0][0], hits[0][2], hits[0][3]
    if len({d["paper_id"] for d in recs}) != len(recs) or len(recs) != 12:
        sys.exit("prep: the Table 2 match is not one to one")
    cols = ["library", "title", "gsm", "sample_name", "disease_status", "disease_severity",
            "days_since_symptom_onset", "age", "sex", "paper_id", "paper_response", "icu"]
    with open(out, "w") as f:
        f.write("\t".join(cols) + "\n")
        for d in recs:
            f.write("\t".join(d.get(c, "") for c in cols) + "\n")
    for d in recs:
        print("%s %s %s %s %s day %s age %s %s -> %s (%s)" % (d["library"], d["gsm"], d["sample_name"],
              d["disease_status"], d["disease_severity"], d["days_since_symptom_onset"], d["age"],
              d["sex"], d["paper_id"], d["paper_response"]))


def deposits(geo, samples_tsv, out):
    feat = os.path.join(geo, "GSE155673_features.tsv.gz")
    for r in csv.DictReader(open(samples_tsv), delimiter="\t"):
        lib = r["library"]
        d = os.path.join(out, lib)
        os.makedirs(d, exist_ok=True)
        for src, dst in ((os.path.join(geo, "GSE155673_%s_matrix.mtx.gz" % lib), "matrix.mtx.gz"),
                         (os.path.join(geo, "GSE155673_%s_barcodes.tsv.gz" % lib), "barcodes.tsv.gz"),
                         (feat, "features.tsv.gz")):
            if not os.path.exists(src):
                sys.exit("prep: missing " + src)
            p = os.path.join(d, dst)
            if os.path.lexists(p):
                os.remove(p)
            os.symlink(os.path.abspath(src), p)
        with gzip.open(os.path.join(d, "barcodes.tsv.gz"), "rt") as fh:
            n = sum(1 for _ in fh)
        print("%s %s: %d deposited barcodes" % (lib, r["gsm"], n))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "samples":
        samples(*sys.argv[2:])
    elif len(sys.argv) == 5 and sys.argv[1] == "deposits":
        deposits(*sys.argv[2:])
    else:
        sys.exit(__doc__)
