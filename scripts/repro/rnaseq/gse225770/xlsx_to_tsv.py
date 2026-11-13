#!/usr/bin/env python3
"""Dump the first worksheet of an .xlsx file to a tab-separated file, with the standard library only.

The main environment has neither openpyxl nor readxl, and an .xlsx file is a zip of XML parts.
Numbers are written exactly as the sheet stores them (the text of the <v> element), so no digit
is lost to a float round trip. Shared strings are looked up. A cell with a number format that
Excel shows as a date is reported on stderr, since a gene symbol turned into a date is a known
damage of passing a gene table through a spreadsheet.

Usage: python3 -I xlsx_to_tsv.py <in.xlsx> <out.tsv>
"""
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
Q = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def col_index(ref):
    """Column letters of a cell reference such as 'AB12' to a zero-based index."""
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def shared_strings(zf):
    out = []
    with zf.open("xl/sharedStrings.xml") as fh:
        for _, el in ET.iterparse(fh, events=("end",)):
            if el.tag == Q + "si":
                # a string item is one <t> or several <r><t> runs
                out.append("".join(t.text or "" for t in el.iter(Q + "t")))
                el.clear()
    return out


def date_style_ids(zf):
    """Cell style ids whose number format is a date or time format."""
    root = ET.fromstring(zf.read("xl/styles.xml"))
    custom = {}
    nf = root.find("m:numFmts", NS)
    if nf is not None:
        for f in nf.findall("m:numFmt", NS):
            custom[int(f.get("numFmtId"))] = f.get("formatCode", "")
    builtin_dates = set(range(14, 23)) | set(range(45, 48))
    ids = set()
    xfs = root.find("m:cellXfs", NS)
    for i, xf in enumerate(xfs.findall("m:xf", NS)):
        fid = int(xf.get("numFmtId", "0"))
        code = custom.get(fid)
        if fid in builtin_dates:
            ids.add(i)
        elif code and re.search(r"[dmyhs]", re.sub(r'"[^"]*"|\[[^\]]*\]|\\.', "", code), re.I):
            ids.add(i)
    return ids


def main(src, dst):
    zf = zipfile.ZipFile(src)
    strings = shared_strings(zf)
    dates = date_style_ids(zf)
    n_rows = n_date_cells = 0
    date_examples = []
    with zf.open("xl/worksheets/sheet1.xml") as fh, open(dst, "w", encoding="utf-8") as out:
        for _, el in ET.iterparse(fh, events=("end",)):
            if el.tag != Q + "row":
                continue
            cells = {}
            for c in el.findall(Q + "c"):
                ref, t, s = c.get("r"), c.get("t"), c.get("s")
                v = c.find(Q + "v")
                if t == "s" and v is not None:
                    text = strings[int(v.text)]
                elif t == "inlineStr":
                    text = "".join(x.text or "" for x in c.iter(Q + "t"))
                elif v is not None:
                    text = v.text or ""
                else:
                    text = ""
                if s is not None and int(s) in dates and v is not None and t != "s":
                    n_date_cells += 1
                    if len(date_examples) < 5:
                        date_examples.append((ref, text))
                cells[col_index(ref)] = text.replace("\t", " ").replace("\n", " ")
            width = max(cells) + 1 if cells else 0
            out.write("\t".join(cells.get(i, "") for i in range(width)) + "\n")
            n_rows += 1
            el.clear()
    sys.stderr.write(f"rows {n_rows}, cells with a date number format {n_date_cells} {date_examples}\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
