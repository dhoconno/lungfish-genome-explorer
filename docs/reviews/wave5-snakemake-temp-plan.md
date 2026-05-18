# Wave 5 Snakemake DAG Temp File Plan

## Defect

`SnakemakeRunner.convertDotToFormat` writes Graphviz inputs and outputs to fixed names under the shared temporary directory:

- `/tmp/dag.dot`
- `/tmp/dag.svg` or `/tmp/dag.png`

Concurrent DAG conversions can overwrite each other, and successful or failed conversions leave temporary files behind.

## Approach

1. Add a focused failing test for SVG DAG conversion that injects a fake Graphviz process.
2. Extract the conversion into a small composable helper that:
   - creates a unique temporary directory per conversion,
   - writes `dag.dot` and the requested output inside that directory,
   - invokes Graphviz through an injectable runner,
   - removes the temporary directory with `defer` before returning or falling back.
3. Keep `SnakemakeRunner` behavior unchanged for missing or failing Graphviz: return raw DOT data.
4. Run focused workflow tests, `swift build --product lungfish-cli`, and `git diff --check`.

## Notes

This remediation is not a scientific-data-producing workflow and does not add provenance output. It only fixes transient files used while rendering a workflow DAG visualization.
