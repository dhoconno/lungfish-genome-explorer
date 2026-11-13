"""Turn the two runs of de.R (step A on the deposit, step B with our columns) into claim rows.

Usage: python3 -I de_claims.py <de_dir> <label.txt>
Reads stepA_results.tsv and stepB_results.tsv and the DESeq2 tables of both steps, checks that
the steps agree, and writes claims_de.tsv in the column layout of compare.py's claims.tsv.
"""
import csv, gzip, hashlib, os, sys

d, label_path = sys.argv[1], sys.argv[2]
label = open(label_path).read().strip()


def rows(step):
    with open(os.path.join(d, "step%s_results.tsv" % step)) as fh:
        return [r for r in csv.DictReader(fh, delimiter="\t")]


def body(rs):
    return [tuple(v for k, v in r.items() if k != "step") for r in rs]


def table_md5(step, s):
    with gzip.open(os.path.join(d, "step%s_deseq2_%s.tsv.gz" % (step, s)), "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


a, b = rows("A"), rows("B")
same = body(a) == body(b) and all(table_md5("A", s) == table_md5("B", s)
                                  for s in ("all34", "one_per_patient"))
same_txt = "step B equal to step A on every output: %s" % ("yes" if same else "NO")


def pick(rs, test, s=None):
    return [r for r in rs if r["test"] == test and (s is None or r["set"] == s)]


isg = {s: pick(a, "isg_score", s)[0] for s in ("all34", "one_per_patient")}
isg_ok = all(float(r["value"]) > 0 and float(r["p"]) < 0.05 for r in isg.values())
fc = pick(a, "deseq2_isg", "all34")
tot = {s: pick(a, "deseq2_total", s)[0]["value"] for s in ("all34", "one_per_patient")}
isg_txt = "; ".join("%s: median difference %s, Wilcoxon p %s (n %s)" % (s, r["value"], r["p"], r["n"])
                    for s, r in isg.items())
fc_txt = ", ".join("%s log2FC %s padj %s" % (r["gene"], r["value"], r["p"]) for r in fc)
ifn = pick(a, "ifn_ab_cpm")
ifn_max = max(float(r["value"]) for r in ifn)
ifn_ok = ifn_max < 1
worst = max(ifn, key=lambda r: float(r["value"]))
claims = [
    ["C2-6", "Results and Fig. 4G, the 33-gene CITE-seq ISG signature in bulk PBMC",
     "strong induction of the 33 ISGs in COVID-19 subjects against healthy donors",
     "step A, stand-in set IFI27+IFITM3+ISG15: " + isg_txt + "; DESeq2 ~covid on all34: " + fc_txt
     + "; DESeq2 up/down at padj<0.05: all34 " + tot["all34"] + ", one_per_patient " + tot["one_per_patient"],
     same_txt, "directional",
     "pending",
     ("stand-in set (3 named ISGs, not the 33) higher in COVID-19 in both sample sets: %s. The 33-gene list is "
      "in the supplement, not on the drive, so the claim stays pending as not settleable (ADJ-BULK-4). One try at "
      "PMC's article PDF 369_1210.pdf through Europe PMC on 2026-11-13 at 12:28 CST answered 403 with a Cloudflare "
      "challenge, and the list stays unread. " % ("yes" if isg_ok else "no")) + label],
    ["C2-7", "Results, no IFN-alpha or IFN-beta gene expression detected",
     "no IFNA or IFNB transcripts",
     "step A: %d IFNA genes and IFNB1, highest CPM in any sample %.4g (%s), the bar is under 1 CPM"
     % (len(ifn), ifn_max, worst["gene"]),
     same_txt, "directional", "pass" if ifn_ok else "fail", label],
]
with open(os.path.join(d, "claims_de.tsv"), "w") as fh:
    for c in claims:
        fh.write("\t".join(c) + "\n")
print(same_txt)
for c in claims:
    print(c[0], c[6], c[3][:160])
sys.exit(0 if same else 3)
