import Foundation

public struct MultipleSequenceAlignmentActionDescriptor: Codable, Equatable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case navigation
        case selection
        case inspection
        case display
        case rows
        case annotation
        case transform
        case export
        case alignment
        case phylogenetics
    }

    public enum Priority: String, Codable, CaseIterable, Sendable {
        case p0 = "P0"
        case p1 = "P1"
        case p2 = "P2"
    }

    public enum Surface: String, Codable, CaseIterable, Sendable {
        case viewport
        case toolbar
        case inspector
        case drawer
        case contextMenu = "context-menu"
        case menuBar = "menu-bar"
        case commandLine = "command-line"
        case operationCenter = "operation-center"
    }

    public enum ImplementationStatus: String, Codable, CaseIterable, Sendable {
        case implemented
        case planned
        case deferred
    }

    public struct CLIContract: Codable, Equatable, Sendable {
        public let command: String
        public let eventEnvelope: String?
        public let outputContract: String
        public let requiredPluginPackIDs: [String]

        public init(
            command: String,
            eventEnvelope: String? = "msaActionStart|msaActionProgress|msaActionWarning|msaActionFailed|msaActionComplete",
            outputContract: String,
            requiredPluginPackIDs: [String] = []
        ) {
            self.command = command
            self.eventEnvelope = eventEnvelope
            self.outputContract = outputContract
            self.requiredPluginPackIDs = requiredPluginPackIDs
        }
    }

    public let id: String
    public let title: String
    public let category: Category
    public let priority: Priority
    public let summary: String
    public let userIntent: String
    public let surfaces: [Surface]
    public let createsOrModifiesScientificData: Bool
    public let requiresProvenance: Bool
    public let cli: CLIContract?
    public let implementationStatus: ImplementationStatus
    public let accessibilityRequirement: String
    public let testRequirement: String

    public init(
        id: String,
        title: String,
        category: Category,
        priority: Priority,
        summary: String,
        userIntent: String,
        surfaces: [Surface],
        createsOrModifiesScientificData: Bool = false,
        requiresProvenance: Bool = false,
        cli: CLIContract? = nil,
        implementationStatus: ImplementationStatus,
        accessibilityRequirement: String,
        testRequirement: String
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.priority = priority
        self.summary = summary
        self.userIntent = userIntent
        self.surfaces = surfaces
        self.createsOrModifiesScientificData = createsOrModifiesScientificData
        self.requiresProvenance = requiresProvenance
        self.cli = cli
        self.implementationStatus = implementationStatus
        self.accessibilityRequirement = accessibilityRequirement
        self.testRequirement = testRequirement
    }
}

public enum MultipleSequenceAlignmentActionRegistry {
    public static let schemaVersion = 1

    public static let surveyReferences = [
        "https://manual.geneious.com/en/latest/Alignments.html",
        "https://www.jalview.org/help/html/features/annotation.html",
        "https://www.jalview.org/help/html/features/columnFilterByAnnotation.html",
        "https://www.jalview.org/help/html/features/hiddenRegions.html",
        "https://ugene.net/docs/alignment-editor/working-with-alignment/",
        "https://www.ncbi.nlm.nih.gov/tools/msaviewer/tutorial1/",
        "https://ormbunkar.se/aliview/",
        "https://resources.qiagenbioinformatics.com/manuals/clcgenomicsworkbench/2600/index.php?manual=View_alignments.html",
    ]

    public static let actions: [MultipleSequenceAlignmentActionDescriptor] = [
        descriptor(
            "msa.navigation.overview",
            "Alignment Overview",
            .navigation,
            .p0,
            "Show a compact alignment-wide coverage, gap, conservation, and variable-site overview.",
            "Move quickly across long alignments and understand where biologically interesting regions are concentrated.",
            [.viewport, .toolbar, .inspector],
            status: .implemented,
            accessibility: "Expose a slider-like overview element with visible column range and total aligned length.",
            tests: "Graphical test asserts a nonblank overview, selected window marker, and no overlap with the matrix."
        ),
        descriptor(
            "msa.navigation.goto-column",
            "Go to Column",
            .navigation,
            .p0,
            "Jump to an aligned column, ungapped coordinate, annotation, row, or named feature.",
            "Reach a biologically meaningful site without manual scrolling.",
            [.toolbar, .menuBar, .viewport],
            status: .implemented,
            accessibility: "Search/go-to field reports match count and focused coordinate.",
            tests: "XCUI enters a column and verifies selected-column inspector coordinates."
        ),
        descriptor(
            "msa.navigation.variable-sites",
            "Previous/Next Variable Site",
            .navigation,
            .p0,
            "Navigate among variable, parsimony-informative, high-gap, or low-conservation sites.",
            "Review variants and alignment quality one informative column at a time.",
            [.toolbar, .menuBar, .viewport, .inspector],
            status: .implemented,
            accessibility: "Buttons have stable labels for previous and next variable site; selected column is exposed.",
            tests: "XCUI activates next/previous variable site and asserts inspector site statistics."
        ),
        descriptor(
            "msa.navigation.annotation",
            "Previous/Next Annotation",
            .navigation,
            .p1,
            "Move between visible annotations and center or zoom to the selected feature.",
            "Treat annotations as landmarks during alignment review.",
            [.viewport, .drawer, .contextMenu, .menuBar],
            status: .implemented,
            accessibility: "Annotation tracks expose selectable labels with row, type, and aligned coordinate range.",
            tests: "Graphical test verifies annotation lane hit testing, centering, and zoom."
        ),
        descriptor(
            "msa.selection.cell",
            "Select Cell",
            .selection,
            .p0,
            "Select a single row and aligned column with residue, consensus, and coordinate details.",
            "Inspect one residue in alignment, source, and consensus coordinate systems.",
            [.viewport, .inspector],
            status: .implemented,
            accessibility: "Active cell is announced as row name, alignment column, ungapped coordinate, and residue.",
            tests: "XCUI clicks a matrix cell and asserts selected-item inspector values."
        ),
        descriptor(
            "msa.selection.block",
            "Select Rectangular Block",
            .selection,
            .p0,
            "Select contiguous row and column ranges with mouse and keyboard extension.",
            "Extract, annotate, mask, or analyze a biologically meaningful alignment region.",
            [.viewport, .contextMenu, .inspector],
            status: .implemented,
            accessibility: "Selection summary exposes row count, column range, base count, gap fraction, and consensus.",
            tests: "XCUI shift-selects columns and validates context-menu enablement."
        ),
        descriptor(
            "msa.selection.rows",
            "Select Rows",
            .selection,
            .p0,
            "Select one or more alignment rows from the gutter, row drawer, or search results.",
            "Choose taxa, haplotypes, samples, or contigs for extraction or transformation.",
            [.viewport, .drawer, .contextMenu, .inspector],
            status: .planned,
            accessibility: "Each visible row label is keyboard-focusable and reports selected/hidden/pinned state.",
            tests: "XCUI selects discontiguous rows and verifies row-selection statistics."
        ),
        descriptor(
            "msa.selection.columns-by-annotation",
            "Select Columns by Annotation",
            .selection,
            .p1,
            "Select or hide columns by annotation type, label, numeric threshold, or text pattern.",
            "Use annotation tracks and quantitative rows as filters for downstream analysis.",
            [.drawer, .contextMenu, .menuBar, .inspector],
            status: .planned,
            accessibility: "Filter sheet exposes selected annotation row, threshold, action, and result count.",
            tests: "Unit and XCUI tests cover selecting by text and numeric annotation thresholds."
        ),
        descriptor(
            "msa.inspection.selection-stats",
            "Selection Statistics",
            .inspection,
            .p0,
            "Show row, site, block, gap, consensus, conservation, entropy, and residue-count summaries.",
            "Decide whether a selected region is suitable for extraction, masking, primer design, or tree inference.",
            [.inspector],
            status: .planned,
            accessibility: "Inspector exposes labels and copyable values for all selected-item statistics.",
            tests: "App tests assert statistics for single cell, row range, column range, and block selections."
        ),
        descriptor(
            "msa.inspection.coordinate-map",
            "Coordinate Map",
            .inspection,
            .p0,
            "Display aligned columns, source ungapped coordinates, consensus coordinates, and CDS/codon positions.",
            "Avoid off-by-one errors when moving between alignment, FASTA, annotation, and consensus views.",
            [.inspector, .viewport],
            status: .planned,
            accessibility: "Coordinate rows identify coordinate system and 1-based biological coordinates.",
            tests: "Unit tests cover gap-containing coordinate maps and segmented annotations."
        ),
        descriptor(
            "msa.display.color-scheme",
            "Color Scheme",
            .display,
            .p0,
            "Switch between residue, conservation, difference-from-consensus, difference-from-reference, codon, and no-color modes.",
            "Highlight the biological signal relevant to the current analysis.",
            [.toolbar, .inspector, .menuBar],
            status: .planned,
            accessibility: "Display modes use labels and contrast, not color alone.",
            tests: "Pixel tests assert residue and difference modes render distinct nonblank patterns."
        ),
        descriptor(
            "msa.display.consensus",
            "Consensus Row and Track",
            .display,
            .p0,
            "Show consensus sequence, residue counts, conservation, entropy, and gap fraction tracks.",
            "Use the consensus as a reference for variation review, search, export, and primer design.",
            [.viewport, .inspector, .contextMenu],
            status: .planned,
            accessibility: "Consensus row and per-column metrics are keyboard-inspectable.",
            tests: "Unit tests cover consensus thresholds and ambiguous IUPAC output."
        ),
        descriptor(
            "msa.display.annotations",
            "Annotation Tracks",
            .display,
            .p0,
            "Show source, projected, and manual annotations directly in alignment rows and the bottom drawer.",
            "See genes, domains, primers, and custom features as alignment landmarks.",
            [.viewport, .drawer, .inspector],
            status: .implemented,
            accessibility: "Annotation bars expose name, type, row, source and aligned/source coordinates.",
            tests: "Graphical test asserts annotation tracks are visible and selectable in the matrix."
        ),
        descriptor(
            "msa.display.row-metadata",
            "Row Metadata Columns",
            .display,
            .p1,
            "Show optional row metadata columns such as organism, accession, date, host, country, gap percent, and identity.",
            "Sort and filter rows using sample metadata without losing alignment context.",
            [.drawer, .inspector, .viewport],
            status: .planned,
            accessibility: "Rows drawer exposes sortable columns and selected visible-row count.",
            tests: "XCUI toggles metadata columns and verifies visible row values."
        ),
        descriptor(
            "msa.rows.pin-reference",
            "Pin Reference or Anchor Row",
            .rows,
            .p1,
            "Pin a row as the reference/anchor for coordinate display and difference highlighting.",
            "Compare samples against a biologically meaningful sequence while browsing.",
            [.contextMenu, .drawer, .inspector],
            status: .planned,
            accessibility: "Pinned row state is announced in row labels and inspector.",
            tests: "XCUI pins a row, changes color mode, and verifies reference-dependent labels."
        ),
        descriptor(
            "msa.rows.hide-sort-filter",
            "Hide, Sort, and Filter Rows",
            .rows,
            .p1,
            "Temporarily hide rows and sort/filter by metadata, sequence name, gap fraction, identity, or tree order.",
            "Focus the viewport on relevant taxa or samples without changing the source bundle.",
            [.drawer, .contextMenu, .menuBar],
            status: .planned,
            accessibility: "Hidden-row controls expose current visible and hidden counts.",
            tests: "XCUI hides rows, restores all rows, and confirms exports exclude hidden rows only when requested."
        ),
        descriptor(
            "msa.annotation.add",
            "Add Annotation from Selection",
            .annotation,
            .p0,
            "Create an MSA annotation from selected row/columns and persist it in the MSA SQLite annotation store.",
            "Mark genes, domains, motifs, suspicious regions, or analysis landmarks discovered in the alignment.",
            [.inspector, .contextMenu, .drawer, .commandLine],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa annotate add <bundle.lungfishmsa> --row <row> --columns <start-end> --name <name> --type <type> --format json",
                outputContract: "Updates metadata/annotations.sqlite and metadata/annotation-edit-provenance.json in the input .lungfishmsa bundle."
            ),
            status: .implemented,
            accessibility: "Add sheet exposes name, type, strand, row, aligned columns, and projected source coordinates.",
            tests: "CLI and XCUI tests add an annotation and assert SQLite, drawer, track, and provenance updates."
        ),
        descriptor(
            "msa.annotation.edit",
            "Edit or Delete Annotation",
            .annotation,
            .p1,
            "Edit annotation labels, qualifiers, type, strand, intervals, visibility, or delete an annotation.",
            "Curate feature tracks while preserving edit provenance.",
            [.drawer, .inspector, .contextMenu, .commandLine],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa annotate edit|delete <bundle.lungfishmsa> --annotation <id> [options] --format json",
                outputContract: "Updates MSA annotation SQLite store and writes annotation edit provenance."
            ),
            status: .implemented,
            accessibility: "Annotation editor is keyboard reachable and reports validation errors inline.",
            tests: "CLI tests cover edit, delete, SQLite snapshots, events, and provenance."
        ),
        descriptor(
            "msa.annotation.project",
            "Project Annotation to Rows",
            .annotation,
            .p0,
            "Map a source annotation through alignment columns onto one or more target rows with conflict policies.",
            "Transfer trusted feature landmarks from an annotated sequence to homologous aligned sequences.",
            [.contextMenu, .inspector, .drawer, .commandLine],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa annotate project <bundle.lungfishmsa> --source-annotation <id> --target-rows <rows> --conflict-policy append --format json",
                outputContract: "Appends projected annotations with validation warnings and edit provenance."
            ),
            status: .implemented,
            accessibility: "Projection review sheet lists target rows, skipped rows, warnings, and created annotations.",
            tests: "Fixture tests project across gaps/indels and assert segmented intervals and warnings."
        ),
        descriptor(
            "msa.annotation.import-export",
            "Import and Export Annotation Tracks",
            .annotation,
            .p1,
            "Import compatible GFF/BED/GenBank-like annotation tables and export MSA annotation tracks.",
            "Move feature context in and out of LGE with explicit coordinate semantics.",
            [.commandLine, .drawer, .menuBar, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa annotate import|export <bundle.lungfishmsa> --format gff|bed|tsv --output <path> --format json",
                outputContract: "Imports update annotation SQLite with provenance; exports write requested files plus provenance sidecar."
            ),
            status: .planned,
            accessibility: "Import/export dialogs expose coordinate system and lossiness warnings.",
            tests: "CLI tests cover ID matching, coordinate conversion, and unsupported qualifier warnings."
        ),
        descriptor(
            "msa.transform.extract-selection",
            "Extract Selected Alignment",
            .transform,
            .p0,
            "Create FASTA or derived `.lungfishmsa` outputs from selected rows/columns.",
            "Reuse selected alignment regions in downstream sequence operations while preserving annotations where possible.",
            [.contextMenu, .menuBar, .commandLine, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa extract <bundle.lungfishmsa> --rows <rows> --columns <ranges> --output <path> --output-kind fasta|msa|reference --format json",
                outputContract: "Creates selected FASTA, derived .lungfishmsa, or native .lungfishref output with row/column selection, lifted annotations where representable, coordinate metadata, and provenance."
            ),
            status: .implemented,
            accessibility: "Extraction dialog reports selected rows, columns, output kind, and annotation handling.",
            tests: "CLI tests assert extracted sequences, derived MSA bundle payloads, and provenance."
        ),
        descriptor(
            "msa.transform.mask-columns",
            "Mask Columns",
            .transform,
            .p0,
            "Create a derived bundle with explicit, gap-threshold, low-conservation, parsimony-uninformative, annotation-driven, or CDS codon-position non-destructive column masks.",
            "Exclude unreliable or irrelevant sites before tree inference/export without destroying original alignment data.",
            [.contextMenu, .inspector, .commandLine, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa mask columns <bundle.lungfishmsa> --ranges <ranges>|--gap-threshold <value>|--conservation-below <value>|--parsimony-uninformative|--annotation <id>|--codon-position <1|2|3> --output <path> [--reason <text>] --format json",
                outputContract: "Creates a derived .lungfishmsa bundle containing column mask metadata, selector details including conservation threshold, site class, or CDS codon position when selected, lineage, and provenance."
            ),
            status: .implemented,
            accessibility: "Mask dialog exposes selection source, threshold, previewed column count, and output name.",
            tests: "CLI tests assert mask metadata, derived bundle lineage, Operation Center events, and provenance."
        ),
        descriptor(
            "msa.transform.trim-columns",
            "Trim or Strip Columns",
            .transform,
            .p0,
            "Create derived bundles with gap-only or high-gap columns removed.",
            "Prepare alignments for phylogenetics and reporting with reproducible trimming.",
            [.commandLine, .operationCenter, .contextMenu, .inspector],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa trim columns <bundle.lungfishmsa> --gap-only|--gap-threshold <value> --output <path> --format json",
                outputContract: "Creates a derived .lungfishmsa bundle with removed-column metadata, lineage, and provenance."
            ),
            status: .implemented,
            accessibility: "Trim operation panel exposes thresholds, tool defaults, predicted retained columns, and warnings.",
            tests: "CLI fixture tests assert retained columns, trim metadata, provenance, and no project-external temp paths."
        ),
        descriptor(
            "msa.transform.filter-rows",
            "Filter Rows",
            .transform,
            .p1,
            "Create a derived bundle including or excluding rows by name, selection, metadata, gap fraction, identity, or hidden state.",
            "Build focused datasets for extraction, tree inference, or sharing.",
            [.drawer, .contextMenu, .commandLine, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa filter rows <bundle.lungfishmsa> --include <query>|--exclude <query> --project <project> --format json",
                outputContract: "Creates a derived .lungfishmsa with row lineage, preserved annotations, and provenance."
            ),
            status: .planned,
            accessibility: "Rows filter panel exposes selected row count and output row count.",
            tests: "CLI tests cover include/exclude queries, duplicate labels, and annotation preservation."
        ),
        descriptor(
            "msa.transform.reverse-complement",
            "Reverse Complement Rows",
            .transform,
            .p1,
            "Create a derived nucleotide alignment with selected rows reverse-complemented and coordinate maps updated.",
            "Correct strand orientation for assembled sequences before analysis.",
            [.contextMenu, .commandLine, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa transform reverse-complement <bundle.lungfishmsa> --rows <rows> --project <project> --format json",
                outputContract: "Creates a derived .lungfishmsa with transformed rows, updated coordinate maps, warnings, and provenance."
            ),
            status: .planned,
            accessibility: "Dialog warns when rows are protein or contain incompatible symbols.",
            tests: "Unit tests assert reverse-complemented rows and annotation coordinate updates."
        ),
        descriptor(
            "msa.transform.consensus",
            "Create Consensus Sequence",
            .transform,
            .p0,
            "Create a consensus FASTA from selected rows using explicit thresholds and gap policy.",
            "Use consensus output as a reference, primer target, or reporting artifact.",
            [.contextMenu, .commandLine, .operationCenter, .inspector],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa consensus <bundle.lungfishmsa> [--rows <rows>] --threshold <value> --gap-policy omit|include --output-kind fasta|reference --output <path> --format json",
                outputContract: "Writes consensus FASTA plus provenance sidecar or a native .lungfishref consensus bundle with consensus metadata and provenance."
            ),
            status: .implemented,
            accessibility: "Consensus dialog exposes threshold, gap policy, row subset, and preview sequence.",
            tests: "CLI tests cover threshold, gaps, row subset, events, and provenance."
        ),
        descriptor(
            "msa.alignment.mafft",
            "Align with MAFFT",
            .alignment,
            .p0,
            "Create `.lungfishmsa` bundles from FASTA or explicit FASTQ-as-assembly inputs with MAFFT.",
            "Generate high-quality nucleotide/protein alignments while retaining source metadata and annotations.",
            [.commandLine, .operationCenter, .menuBar],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish align mafft <inputs...> --project <project> [options] --format json",
                outputContract: "Creates a .lungfishmsa bundle with input, external MAFFT, final payload, annotation, and quality-sidecar provenance.",
                requiredPluginPackIDs: ["multiple-sequence-alignment"]
            ),
            status: .implemented,
            accessibility: "Operation panel exposes strategy, output order, sequence type, direction, symbol policy, and advanced options.",
            tests: "Workflow tests assert MAFFT provenance, annotation rehydration, FASTQ warnings, and Operation Center progress."
        ),
        descriptor(
            "msa.alignment.other-aligners",
            "Align with MUSCLE, Clustal Omega, or FAMSA",
            .alignment,
            .p1,
            "Create `.lungfishmsa` bundles with alternate aligners suitable for different dataset sizes and protein/nucleotide workloads.",
            "Choose the aligner that best fits the biological dataset and reproducibility constraints.",
            [.commandLine, .operationCenter, .menuBar],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish align muscle|clustalo|famsa <inputs...> --project <project> [options] --format json",
                outputContract: "Creates a .lungfishmsa bundle with external-tool provenance and source annotation rehydration.",
                requiredPluginPackIDs: ["multiple-sequence-alignment"]
            ),
            status: .planned,
            accessibility: "Aligner operation panels expose tool-specific options and resolved defaults.",
            tests: "Fake-tool tests assert each descriptor builds expected argv/events/provenance."
        ),
        descriptor(
            "msa.export.aligned-fasta",
            "Export Aligned FASTA",
            .export,
            .p0,
            "Export full or selected aligned rows and columns as FASTA with a Lungfish provenance sidecar.",
            "Move alignment regions into external tools while keeping row/column selection and checksums reproducible.",
            [.commandLine, .contextMenu, .menuBar, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa export <bundle.lungfishmsa> --output-format fasta --output <path> [--rows <rows>] [--columns <ranges>] --format json",
                outputContract: "Writes aligned FASTA plus <output>.lungfish-provenance.json with row/column selection, checksums, argv, and runtime identity."
            ),
            status: .implemented,
            accessibility: "Export dialog exposes selected rows, selected columns, output path, overwrite state, and provenance sidecar path.",
            tests: "CLI tests export full and selected alignments and assert FASTA content plus provenance sidecar."
        ),
        descriptor(
            "msa.export.alignment-formats",
            "Export Alignment Formats",
            .export,
            .p0,
            "Export selected or full alignment as aligned FASTA, PHYLIP, NEXUS, CLUSTAL, Stockholm, or A2M/A3M.",
            "Move LGE alignments into external phylogenetic, publication, or exchange workflows.",
            [.commandLine, .contextMenu, .menuBar, .operationCenter],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa export <bundle.lungfishmsa> --output-format fasta|phylip|nexus|clustal|stockholm|a2m|a3m --output <path> [selection options] --format json",
                outputContract: "Writes requested file plus provenance sidecar recording row/column selection and checksums."
            ),
            status: .implemented,
            accessibility: "Export dialog exposes format lossiness, selected rows, selected columns, overwrite state, and provenance sidecar path.",
            tests: "CLI tests cover all supported export formats and provenance sidecar contents."
        ),
        descriptor(
            "msa.export.copy-fasta",
            "Copy FASTA",
            .export,
            .p0,
            "Copy selected rows/columns as FASTA to the clipboard.",
            "Move small regions into notes, tickets, or external tools quickly.",
            [.contextMenu, .menuBar],
            status: .implemented,
            accessibility: "Copy menu item is enabled only when a valid selection exists and announces copied record count.",
            tests: "App tests assert selected FASTA text and disabled state with no selection."
        ),
        descriptor(
            "msa.phylogenetics.build-tree",
            "Build Tree from Alignment",
            .phylogenetics,
            .p1,
            "Launch tree inference from a selected, visible, masked, or full alignment and create `.lungfishtree` output.",
            "Move from curated MSA to reproducible phylogenetic inference.",
            [.commandLine, .operationCenter, .menuBar, .inspector],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish tree infer iqtree <bundle.lungfishmsa> --project <project> --output <path.lungfishtree> [--rows <rows>] [--columns <ranges>] [--name <name>] [--model MFP] [--bootstrap <n>] [--seed <n>] [--iqtree-path <path>] --format json",
                outputContract: "Creates a native .lungfishtree bundle, preserves IQ-TREE outputs under artifacts/iqtree, and writes final .lungfish-provenance.json with wrapper argv, external IQ-TREE argv/version, input alignment checksum, output checksums, runtime identity, exit status, wall time, and stderr.",
                requiredPluginPackIDs: ["phylogenetics"]
            ),
            status: .implemented,
            accessibility: "Tree operation panel exposes input mask/row subset, model, bootstrap, seed, and output bundle.",
            tests: "Fake-tool E2E tests assert Operation Center progress, output tree bundle, and provenance."
        ),
        descriptor(
            "msa.phylogenetics.distance-matrix",
            "Distance or Identity Matrix",
            .phylogenetics,
            .p1,
            "Compute pairwise identity/distance matrices from selected, visible, masked, or full rows.",
            "Assess sample relatedness and alignment quality before tree inference.",
            [.commandLine, .operationCenter, .inspector],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa distance <bundle.lungfishmsa> --model identity|p-distance [selection options] --output <path> --format json",
                outputContract: "Writes matrix output plus provenance sidecar or derived analysis bundle."
            ),
            status: .implemented,
            accessibility: "Matrix result exposes sortable rows and selectable pairwise values.",
            tests: "CLI tests cover identity and p-distance on deterministic fixtures."
        ),
        descriptor(
            "msa.display.linked-tree",
            "Linked Tree and Alignment",
            .display,
            .p2,
            "Synchronize row order, selection, and clade coloring between an MSA and associated tree.",
            "Interpret variation patterns in phylogenetic context.",
            [.viewport, .inspector, .menuBar],
            status: .deferred,
            accessibility: "Linked selections announce tree node and corresponding row set.",
            tests: "XCUI selects a clade and verifies linked alignment row selection."
        ),
        descriptor(
            "msa.transform.manual-edit",
            "Manual Edit Mode",
            .transform,
            .p2,
            "Optional locked editing mode for gap insertion/deletion or local manual correction with undo and derived-bundle save.",
            "Curate alignments by hand only when reproducible automated transformations are insufficient.",
            [.viewport, .menuBar, .commandLine],
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            cli: .init(
                command: "lungfish msa edit apply <bundle.lungfishmsa> --edit-script <json> --project <project> --format json",
                outputContract: "Creates a derived .lungfishmsa from an explicit edit script with complete provenance."
            ),
            status: .deferred,
            accessibility: "Edit mode announces armed state, active edit command, and undo/redo availability.",
            tests: "Deferred until edit script schema and derived-bundle semantics are finalized."
        ),
    ]

    public static var actionsByID: [String: MultipleSequenceAlignmentActionDescriptor] {
        Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    }

    public static var cliBackedActions: [MultipleSequenceAlignmentActionDescriptor] {
        actions.filter { $0.cli != nil }
    }

    public static var scientificDataChangingActions: [MultipleSequenceAlignmentActionDescriptor] {
        actions.filter(\.createsOrModifiesScientificData)
    }

    public static func action(id: String) -> MultipleSequenceAlignmentActionDescriptor? {
        actionsByID[id]
    }

    public static func actions(category: MultipleSequenceAlignmentActionDescriptor.Category) -> [MultipleSequenceAlignmentActionDescriptor] {
        actions.filter { $0.category == category }
    }

    public static func validate() -> [String] {
        var issues: [String] = []
        var seen: Set<String> = []
        for action in actions {
            if seen.contains(action.id) {
                issues.append("Duplicate action ID: \(action.id)")
            }
            seen.insert(action.id)
            if action.createsOrModifiesScientificData && action.requiresProvenance == false {
                issues.append("Scientific data action \(action.id) does not require provenance.")
            }
            if action.createsOrModifiesScientificData && action.cli == nil {
                issues.append("Scientific data action \(action.id) does not declare a CLI contract.")
            }
            if let command = action.cli?.command, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("CLI-backed action \(action.id) has an empty command.")
            }
        }
        return issues
    }

    private static func descriptor(
        _ id: String,
        _ title: String,
        _ category: MultipleSequenceAlignmentActionDescriptor.Category,
        _ priority: MultipleSequenceAlignmentActionDescriptor.Priority,
        _ summary: String,
        _ userIntent: String,
        _ surfaces: [MultipleSequenceAlignmentActionDescriptor.Surface],
        createsOrModifiesScientificData: Bool = false,
        requiresProvenance: Bool = false,
        cli: MultipleSequenceAlignmentActionDescriptor.CLIContract? = nil,
        status: MultipleSequenceAlignmentActionDescriptor.ImplementationStatus,
        accessibility: String,
        tests: String
    ) -> MultipleSequenceAlignmentActionDescriptor {
        MultipleSequenceAlignmentActionDescriptor(
            id: id,
            title: title,
            category: category,
            priority: priority,
            summary: summary,
            userIntent: userIntent,
            surfaces: surfaces,
            createsOrModifiesScientificData: createsOrModifiesScientificData,
            requiresProvenance: requiresProvenance,
            cli: cli,
            implementationStatus: status,
            accessibilityRequirement: accessibility,
            testRequirement: tests
        )
    }
}
