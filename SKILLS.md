# Skills

## GitHub Releases

Any GitHub release that includes a Lungfish app build must attach a signed and
notarized `.dmg` asset. Zip archives are useful for debugging, but they are not
enough for end users because unsigned or unnotarized app bundles are difficult
to run on macOS.

The sole operator front door is exactly:

```text
python3 scripts/release/release.py debug [--portable] [--jobs N]
python3 scripts/release/release.py configure-fork --repository OWNER/REPO --product-name NAME --namespace REVERSE_DNS --sparkle-public-key BASE64 --website URL --documentation URL
python3 scripts/release/release.py configure-machine --signing-identity LABEL --team-id TEAM --notary-profile NAME [--profile PATH]
python3 scripts/release/release.py setup [--profile PATH]
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

Re-run `publish` for receipt-bound recovery without rebuilding. Low-level
builders are internal. The full machine, channel, cache, verification, and
side-by-side caveats live in `.codex/skills/releasing-lungfish/SKILL.md` and
`docs/release/sparkle-updates.md`.

## Dependency Sweep

The coordinator validates committed dependency manifests and runs the compact
headless release profile once before creating a candidate receipt. Routine packages
need no managed environment or UI account. Extended, UI and tool-conformance profiles
are opt-in diagnostics. GitHub Actions is advisory and never authorizes or blocks
publication. See `docs/release/dependency-sweep.md` for dependency maintenance.

## Debug build

Run `python3 scripts/release/release.py debug` for incremental local development.
The coordinator selects supported Xcode and assembles the GUI and CLI from one
native build graph. The default performs cheap bundle/CLI checks; add
`--portable` for the full relocation and self-containment diagnostic. `--jobs N`
bounds build parallelism. Neither option runs the unit or UI suites.

The upstream result is `build/Debug/Lungfish Debug.app`, displaying
`Lungfish Genome Explorer Debug`, bundle name `Lungfish Debug`, identifier
`com.lungfish.browser.debug`, channel `debug`. Fork names and identifiers come
from `config/release-contract.json`. It is locally ad-hoc signed, not Developer ID signed,
and not notarized. It is self-contained and relocatable with no checkout or `.build`
dependency; use the portable check when validating that property. Debug is not a release,
has no updater or publication path, and must never be tagged or uploaded as a release.
