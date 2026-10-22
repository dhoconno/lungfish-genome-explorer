# Developing Lungfish Genome Explorer

Build, packaging, and test notes for people working on the code. Release
operations are covered in more depth under [`docs/release/`](release/).

## Requirements

An Apple Silicon Mac on macOS 26 Tahoe or later with Xcode and the Swift 6.2
toolchain. The hardware and network requirements for running the app are in
the [README](../README.md#getting-the-app).

## Building from source

```bash
git clone https://github.com/dhoconno/lungfish-genome-explorer.git
cd lungfish-genome-explorer
swift build -c release --arch arm64
```

The build, packaging, and release commands are all subcommands of one script:

```text
python3 scripts/release/release.py debug [--portable] [--jobs N]
python3 scripts/release/release.py configure-fork --repository OWNER/REPO --product-name NAME --namespace REVERSE_DNS --sparkle-public-key BASE64 --website URL --documentation URL
python3 scripts/release/release.py configure-machine --signing-identity LABEL --team-id TEAM --notary-profile NAME [--profile PATH]
python3 scripts/release/release.py setup [--profile PATH]
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

### Debug build

Run `python3 scripts/release/release.py debug` for incremental local
development. The script picks a supported Xcode and builds the GUI and CLI
together. The default performs cheap bundle/CLI checks;
add `--portable` for the full relocation and self-containment diagnostic.
`--jobs N` bounds build parallelism. Neither option runs the unit or UI suites.

The result is `build/Debug/Lungfish Debug.app`, displaying
`Lungfish Genome Explorer Debug`, bundle name `Lungfish Debug`, identifier
`com.lungfish.browser.debug`, channel `debug`. Fork names and identifiers come
from `config/release-contract.json`. It is locally ad-hoc signed, not Developer
ID signed, and not notarized. It is self-contained and relocatable with no
checkout or `.build` dependency; use the portable check when validating that
property. Debug is not a release, has no updater or publication path, and must
never be tagged or uploaded as a release.

### Release packaging

On a Mac configured with `configure-machine`, run `package` and then
`publish`. If `publish` fails partway, run it again; it resumes from the
packaged build instead of rebuilding. Sparkle appcast publishing is documented
in [sparkle-updates.md](release/sparkle-updates.md).

### Forks

`configure-fork` rewrites the product name, bundle namespace, Sparkle public
key, and website URLs so a fork can package and publish its own signed builds
without colliding with the upstream app or its update feed.

## Architecture

Lungfish Genome Explorer is organised as SwiftPM products layered from a
small core up to the app. Each row may import the rows above it, never the
rows below; in particular, `LungfishKit` and the feature modules never import
`LungfishApp`.

| Product / module | Purpose |
|------------------|---------|
| **LungfishCore** | Core models, bundle manifests, project storage, metadata |
| **LungfishIO** | File-format parsers, indexes, bundle readers/writers |
| **LungfishWorkflow** | Native tool execution, workflows, provenance, conda/tool management |
| **LungfishKit** | Shared UI kernel: operation center, drawers, pickers, brand colors, and support utilities that every feature module builds on |
| **Feature UI modules** | One SwiftPM target per viewer: Alignment, Assembly, TwelveS, NVD, NAO-MGS, TaxTriage, EsViritu, Genotype, Phylogenetics |
| **LungfishApp** | Composition root: the main window, sidebar, inspector, and app delegate that import the feature modules and wire them to app services |
| **Lungfish** | Graphical app executable |
| **LungfishCLI** | `lungfish-cli` headless interface (does not import `LungfishKit`) |

## Tool-executing tests

A few integration tests run real tools rather than mocks. They are not gated
behind an opt-in variable: each one runs when the tool or database it needs is
present on the machine and skips when it is not.

- `IVarConverterViralReconParityTests` asserts the Swift iVar TSV-to-VCF converter byte-matches the upstream `nf-core/viralrecon` Python script (vendored at `Tests/Fixtures/ivar-converter-parity/ivar_variants_to_vcf.py`) on a real SARS-CoV-2 fixture. Runs under the ivar-oracle Python of the golden environment lock (python3 scripts/golden/environment.py provision builds it), skips with its reason when that Python is not installed and fails when LUNGFISH_REQUIRE_TOOLS=1 is set.
- `ReadsToVariantsEndToEndTests` runs the post-mapping reads-to-variants pipeline against a small SARS-CoV-2 amplicon fixture. Requires the managed conda envs (`samtools`, `ivar`, `lofreq`, `bcftools`, `htslib`) to be provisioned (run the app once and accept the on-demand install, or run `lungfish-cli conda install`).

Setting `LUNGFISH_REQUIRE_TOOLS=1` turns these (and other
tool/database-availability skips across the suite) into hard failures instead
of silent skips, so a conformance run can assert the full toolset is actually
present:

```bash
LUNGFISH_REQUIRE_TOOLS=1 swift test --filter 'IVarConverterViralReconParity|ReadsToVariantsEndToEndTests'
```

The internal conformance gate runs the whole suite this way and additionally
fails if any tool/database skip is recorded within the conformance suites.

### Running the recipe tests against a scratch database root

`RecipeIntegrationTests` and `FASTQBatchImporterRecipeIntegrationTests` run the merged recipe with the real tools and the real Deacon indexes. They read each index and its `.lungfish-provenance.json` receipt from the managed database root. A machine whose installed copy has no receipt fails them in `ConformanceFixtures.swift` with a plain file-not-found error. Do not write a receipt into a real root to get past it. Point the tests at a scratch root and install the databases there.

1. Pick a scratch folder. Its path has no space, it sits in no `*.lungfish` folder or `*.app`, and its nearest existing parent is writable. Never name the golden root (`/Users/Shared/lungfish-golden`) or a user's Stable root (`~/.lungfish-stable`) as the scratch.
2. Set `LUNGFISH_STORAGE_ROOT` to the scratch folder. A valid value wins over the saved preference (`Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift` lines 155 to 166), and the databases go under `<scratch>/databases`. A value that fails validation is ignored with a log line and the process falls back to another root, so read the destination path in the first install's output before you trust the setting.
3. Set `LUNGFISH_CONDA_ROOT` to the managed conda root of an installed channel, for example `~/.lungfish-stable/conda`. Tools follow the storage root to `<scratch>/conda` by default, which is empty, and a valid `LUNGFISH_CONDA_ROOT` wins over that (`ManagedStorageConfigStore.swift` lines 185 to 196). The tests read the tools from this root and write nothing to it.
4. Install the databases into the scratch root with a `lungfish-cli` built at or after the commit under test. `lungfish-cli conda db update deacon-ribokmers --yes` installs the pinned index. `lungfish-cli conda db install-managed deacon-panhuman` clones the index from another channel root on the same volume when that copy matches the pinned SHA-256 and downloads about 3.3 GB otherwise.
5. Run each class with an anchored filter, since `RecipeIntegrationTests` is also a substring of `FASTQBatchImporterRecipeIntegrationTests`. Delete the scratch folder afterwards.

```bash
export LUNGFISH_REQUIRE_TOOLS=1
export LUNGFISH_STORAGE_ROOT=/path/to/scratch
export LUNGFISH_CONDA_ROOT=$HOME/.lungfish-stable/conda
.build/debug/lungfish-cli conda db update deacon-ribokmers --yes
.build/debug/lungfish-cli conda db install-managed deacon-panhuman
swift test --skip-update --filter '(^|\.)RecipeIntegrationTests/'
swift test --skip-update --filter '(^|\.)FASTQBatchImporterRecipeIntegrationTests/'
```

## Landing site

The public landing page at
<https://dhoconno.github.io/lungfish-genome-explorer/> is a Quarto project in
[`docs/site/`](site/). GitHub Actions renders and deploys it on every push to
`main` that touches the site and on every published release, which is what
keeps the download card current. To preview locally, install
[Quarto](https://quarto.org) and run `quarto preview docs/site`.
