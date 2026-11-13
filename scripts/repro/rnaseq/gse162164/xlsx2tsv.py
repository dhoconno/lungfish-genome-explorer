"""Write each sheet of an .xlsx file as a TSV, with the standard library only (the environment
has no openpyxl). Used for the paper's Supplementary Table 2 (Table_2.XLSX).

Usage: python3 -I xlsx2tsv.py <file.xlsx> <out_prefix>
Writes <out_prefix>.<n>.<sheet name>.tsv for each sheet n.
"""
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}


def col_index(ref):
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n - 1


def main(path, prefix):
    z = zipfile.ZipFile(path)
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS):
            shared.append("".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t")))
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    target = {r.get("Id"): r.get("Target") for r in rels}
    for n, sh in enumerate(wb.find("m:sheets", NS), 1):
        rid = sh.get(f"{{{NS['r']}}}id")
        name = re.sub(r"[^A-Za-z0-9]+", "_", sh.get("name")).strip("_")
        part = "xl/" + target[rid].lstrip("/").replace("xl/", "")
        rows = []
        for row in ET.fromstring(z.read(part)).iter(f"{{{NS['m']}}}row"):
            vals = {}
            for c in row.findall("m:c", NS):
                v = c.find("m:v", NS)
                if c.get("t") == "inlineStr":
                    txt = "".join(t.text or "" for t in c.iter(f"{{{NS['m']}}}t"))
                elif v is None:
                    txt = ""
                elif c.get("t") == "s":
                    txt = shared[int(v.text)]
                else:
                    txt = v.text
                vals[col_index(c.get("r"))] = txt.replace("\t", " ").replace("\n", " ")
            if vals:
                rows.append([vals.get(i, "") for i in range(max(vals) + 1)])
        out = f"{prefix}.{n}.{name}.tsv"
        with open(out, "w") as oh:
            for r in rows:
                oh.write("\t".join(r) + "\n")
        print(out, len(rows), "rows")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
