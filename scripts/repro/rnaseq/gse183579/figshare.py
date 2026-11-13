"""Read the per-animal cell shares behind Fig. 3B and 3C from the figshare table
(OvYFigShare.xlsx, sheet "Figure 3") and infer each column's cells-after-QC total.

Fig. 3B gives B, T, dividing, macrophage and pDC shares (% of BALF cells) for every
animal and day, one row an animal, with no age or animal id. Fig. 3C gives T cells,
pneumocytes and ciliated cells split into Old (columns B to I) and Young (J to Q). A 3B
row is tied to its 3C column by its T-cell value, which gives it an age, a 3C position
and two more shares. The total N is the smallest whole number for which every share is
k/N within the table's printed precision.

Usage (python -I): figshare.py OvYFigShare.xlsx OUT.tsv
"""
import sys
import xml.etree.ElementTree as ET
import zipfile

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def sheet(path, name):
    z = zipfile.ZipFile(path)
    ss = ["".join(t.text or "" for t in si.iter("{%s}t" % NS["m"]))
          for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS)]
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    names = [s.get("name") for s in wb.find("m:sheets", NS)]
    sh = ET.fromstring(z.read("xl/worksheets/sheet%d.xml" % (names.index(name) + 1)))
    cell = {}
    for c in sh.iter("{%s}c" % NS["m"]):
        v = c.find("m:v", NS)
        if v is not None:
            cell[c.get("r")] = ss[int(v.text)] if c.get("t") == "s" else v.text
    return cell


def num(cell, ref):
    try:
        return float(cell[ref])
    except (KeyError, ValueError):
        return None


def total(vals, tol=6e-5, top=30000):
    for n in range(1, top):
        if all(abs(v - 100.0 * round(v * n / 100.0) / n) <= tol for v in vals):
            return n
    return None


def main(xlsx, out):
    c = sheet(xlsx, "Figure 3")
    # 3C blocks: T cells rows 22-24, pneumocytes 28-30, ciliated 34-36 (-7, 3, 7 dpi)
    title_rows = {c.get("A%d" % r, ""): r for r in range(19, 60)}
    blocks = {}
    for key, word in (("T", "T cells"), ("pneumocyte", "Pneumocytes"), ("ciliated", "Ciliated")):
        r0 = [r for t, r in title_rows.items() if t.startswith(word)][0]
        blocks[key] = r0 + 2
    pos = {}  # (day, rounded T) -> (age, position)
    for i, day in enumerate(("-7", "3", "7")):
        for j, col in enumerate("BCDEFGHIJKLMNOPQ"):
            v = num(c, "%s%d" % (col, blocks["T"] + i))
            if v is not None:
                age = "old" if j < 8 else "young"
                pos[(day, round(v, 4))] = (age, j % 8 + 1, col)
    rows = []
    groups = (("-7", "A", "E", "I", "M", "Q"), ("3", "B", "F", "J", "N", "R"), ("7", "C", "G", "K", "O", "S"))
    for di, (day, *cols) in enumerate(groups):
        for r in range(3, 19):
            v = [num(c, "%s%d" % (col, r)) for col in cols]
            if any(x is None for x in v):
                continue
            age, p, col3c = pos.get((day, round(v[1], 4)), ("?", 0, "?"))
            extra = [num(c, "%s%d" % (col3c, blocks[k] + di)) if col3c != "?" else None
                     for k in ("pneumocyte", "ciliated")]
            n = total([x for x in v + extra if x is not None])
            rows.append([day, age, p, r, n] + v + extra)
    head = ["day", "age", "pos3c", "row3b", "n_after_qc", "B", "T", "dividing", "macrophage", "pDC",
            "pneumocyte", "ciliated"]
    with open(out, "w") as f:
        f.write("\t".join(head) + "\n")
        for row in rows:
            f.write("\t".join("" if x is None else (("%.6g" % x) if isinstance(x, float) else str(x))
                              for x in row) + "\n")
    print("figshare columns", len(rows), out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
