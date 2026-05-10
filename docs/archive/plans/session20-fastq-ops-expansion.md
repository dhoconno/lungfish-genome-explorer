# Session 20: FASTQ Operations Expansion Plan

## Phase 1: Refactor SPAdes Assembly Dialog → Classification Template
- Replace AssemblyConfigurationView with a new `AssemblyWizardSheet.swift` following ClassificationWizardSheet pattern
- Header: wrench.circle icon + "SPAdes Assembly" + "De novo genome assembly" + dataset name
- Remove AssemblyConfigurationViewController (no longer needed — SwiftUI sheet in NSPanel)
- Keep AssemblyConfigurationViewModel but refactor to match classification config pattern
- Button: "Run" (not "Start Assembly")
- Size: 520x520 (matching classification dialog)
- Presets as segmented control instead of menu
- Advanced settings in DisclosureGroup

## Phase 2: Add SPAdes to FASTQ Operations + CLI
- Add `.assembleReads` to OperationKind enum in FASTQDatasetViewController
- Add to "ASSEMBLY" category in categories list
- Wire `runOperationClicked` to launch assembly wizard
- Add `AssembleCommand.swift` CLI with ArgumentParser
- Match classify command pattern (input files, mode preset, resources)

## Phase 3: Reference-Sequence Dialog Template
- Create `ReferenceSequencePickerView.swift` — reusable SwiftUI component
- Lists all FASTA sequences in project (scan ProjectStore for .lungfishref bundles)
- Dropdown + "Browse..." button for filesystem FASTA selection
- When user selects from filesystem: auto-import to project and use as reference
- Template: `ReferenceOperationWizardSheet` base pattern

## Phase 4: Refactor Orient Reads → Reference Dialog
- Create `OrientWizardSheet.swift` using reference-sequence dialog template
- Remove inline orient controls from FASTQDatasetViewController toolstrip
- Orient parameters: reference, word length, mask mode, save unoriented
- Wire through AppDelegate like classification ops
- Add `OrientCommand.swift` CLI

## Phase 5: Minimap2 Read Mapping
- Create `Minimap2Pipeline.swift` in LungfishWorkflow
- Uses CondaManager (micromamba) for minimap2 installation
- Bioinformatics expert review for parameter selection:
  - Basic: preset (sr/map-ont/map-hifi), threads
  - Advanced: scoring, seed length, bandwidth
- Output: sorted, indexed BAM → import via BAMImportService
- Create `MapReadsWizardSheet.swift` using reference dialog template
- Add `.mapReads` to OperationKind
- Add `MapCommand.swift` CLI

## Phase 6: Remove Sunburst from EsViritu/TaxTriage
- EsVirituResultViewController: remove sunburst, show alignment view only
- TaxTriageResultViewController: remove sunburst, show alignment/report view only
- Keep sunburst only in TaxonomyViewController (Kraken2)

## Phase 7: NAO-MGS-Workflow Integration
- Results-import approach (pipeline too large for local execution)
- Create `NaoMgsResultParser.swift` — parse virus_hits_final.tsv.gz
- Create `NaoMgsImportCommand.swift` CLI for importing results
- Create `NaoMgsWizardSheet.swift` dialog for importing results
- Display results in alignment format where possible
- Add to CLASSIFICATION category in FASTQ operations

## Phase 8: Memory Updates
- Document reference-sequence dialog template
- Document minimap2 integration
- Document NAO-MGS workflow
- Update session details
