"""Writes the FASTA and the GFF3 of the W-32 twin exactly as WalkTwinsXCUITests.addExtractionReferences does.

Usage: python3 make_inputs.py <empty output folder>
The generator is the test's referenceBases: state 32, then 6,000 times state = state * 6364136223846793005 +
1442695040888963407 (mod 2**64), and the base is "ACGT"[(state >> 33) % 4].
"""
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

state = 32
bases = []
for _ in range(6000):
    state = (state * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
    bases.append("ACGT"[(state >> 33) % 4])

rows = ["".join(bases[i:i + 60]) for i in range(0, len(bases), 60)]
(out / "reference.fa").write_text(">chrT twin extraction reference\n" + "\n".join(rows) + "\n")

genes = [("GENEA", 201, 600), ("GENEB", 1001, 1400), ("GENEC", 1801, 2200), ("HBB", 4801, 5200)]
gff = "##gff-version 3\n" + "".join(
    f"chrT\ttwin\tgene\t{start}\t{end}\t.\t+\t.\tID=gene{index};Name={name}\n"
    for index, (name, start, end) in enumerate(genes))
(out / "genes.gff3").write_text(gff)
print("wrote", out / "reference.fa", len("".join(bases)), "bases and", out / "genes.gff3")
