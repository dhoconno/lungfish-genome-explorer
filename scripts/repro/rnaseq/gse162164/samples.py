"""Build samples.tsv for GSE162164: one row a run, with its GEO sample, group, age, sex and the
column of GSE162164_counts.txt.gz that holds it.

Usage: python3 -I samples.py <study_dir> <out.tsv>

study_dir holds selected_runs.tsv, geo/GSE162164_series_matrix.txt.gz, geo/GSE162164_RAW.tar
and geo/GSE162164_counts.txt.gz. The matrix names its columns RICC_<id>_<date> and the GEO
titles name samples TB_HIV_<n> or HIV_<n>, so the script pairs them by content: each per-sample
file in GSE162164_RAW.tar must equal exactly one matrix column, gene by gene.
"""
import gzip
import io
import sys
import tarfile

import pandas as pd


def series_fields(path):
    out = {}
    with gzip.open(path, "rt") as fh:
        for line in fh:
            if not line.startswith("!Sample_"):
                continue
            key, *vals = line.rstrip("\n").split("\t")
            vals = [v.strip('"') for v in vals]
            if key == "!Sample_characteristics_ch1":
                tag = vals[0].split(":")[0].strip().lower()
                out[tag] = [v.split(":", 1)[1].strip() for v in vals]
            else:
                out[key[8:]] = vals
    return out


def main(study, out):
    runs = pd.read_csv(f"{study}/selected_runs.tsv", sep="\t", dtype=str)
    f = series_fields(f"{study}/geo/GSE162164_series_matrix.txt.gz")
    geo = pd.DataFrame({"gsm": f["geo_accession"], "age": f["age"], "sex": f["sex"],
                        "title": [t.split()[-1] for t in f["title"]]})
    mat = pd.read_csv(f"{study}/geo/GSE162164_counts.txt.gz", sep="\t", index_col=0)
    col_of = {}
    with tarfile.open(f"{study}/geo/GSE162164_RAW.tar") as tar:
        for m in tar.getmembers():
            gsm = m.name.split("_")[0]
            raw = gzip.decompress(tar.extractfile(m).read()).decode()
            s = pd.read_csv(io.StringIO(raw), sep="\t", index_col=0).iloc[:, 0]
            s = s.reindex(mat.index)
            hits = [c for c in mat.columns if (mat[c] == s).all()]
            if len(hits) != 1:
                raise SystemExit(f"{m.name}: {len(hits)} matrix columns equal it")
            col_of[gsm] = hits[0]
    geo["deposit_column"] = geo["gsm"].map(col_of)
    geo["group"] = ["TB" if t.startswith("TB_HIV") else "HIV" for t in geo["title"]]
    df = runs.merge(geo, left_on="geo_sample", right_on="gsm")
    df = df.rename(columns={"run_accession": "run", "read_count": "spots"})
    df = df[["run", "gsm", "title", "group", "age", "sex", "deposit_column", "spots"]]
    df.to_csv(out, sep="\t", index=False)
    print(len(df), "runs;", df.group.value_counts().to_dict(),
          "; matrix column order equals GSM order:", list(df.deposit_column) == list(mat.columns))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
