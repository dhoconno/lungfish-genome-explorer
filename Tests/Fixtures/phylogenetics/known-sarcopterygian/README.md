# Known Sarcopterygian IQ-TREE Fixture

This fixture is a synthetic, public-domain DNA alignment for validating tree
rendering and IQ-TREE artifact handling. It is intentionally small and clade
signal is encoded in blocks so the expected topology is visually obvious:

```newick
(Zebrafish_outgroup,(Coelacanth,((Australian_lungfish,African_lungfish),(Human,Frog))));
```

Expected visible clades:

- `Australian_lungfish` + `African_lungfish`
- `Human` + `Frog`
- lungfish + tetrapods
- `Coelacanth` sister to lungfish + tetrapods
- `Zebrafish_outgroup` outside the sarcopterygian clade

For deterministic IQ-TREE smoke runs use a fixed seed, one thread, and a simple
model such as `JC`. Artifact tests should assert topology and provenance, not
exact branch lengths.

IQ-TREE emits an unrooted Newick tree by default, so the root placement can
appear different from `expected.nwk`. The biological expectation for viewport
testing is the visible grouping of the two lungfish tips, the human/frog pair,
and those two pairs as sister clades.
