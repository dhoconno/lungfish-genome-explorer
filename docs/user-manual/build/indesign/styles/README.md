# InDesign style contract

The Lua filter in `build/scripts/icml-filter.lua` emits ICML referencing
paragraph, character, and object style names listed in `style-map.yaml`.
`Lungfish-Manual.indd` MUST define every name in the map.

## Adding a new style

1. Add the entry to `style-map.yaml` first.
2. Update the Lua filter to emit the new style name.
3. Add the style definition in InDesign.
4. Re-export IDML.
5. Commit .indd + .idml together.

## Never do

Never rename a style in InDesign without updating `style-map.yaml`. Never
commit only the .indd without the matching .idml. Never add inline formatting
overrides in a story: use styles.
